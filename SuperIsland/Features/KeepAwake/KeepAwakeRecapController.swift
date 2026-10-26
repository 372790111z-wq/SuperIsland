import AppKit
import Combine
import CoreGraphics

@MainActor final class KeepAwakeRecapController: ObservableObject {
    static let preferenceKey = "keepAwake.recap.autoShow.v1"
    @Published private(set) var latest: KeepAwakeRecap.Cycle?
    @Published private(set) var autoShow: Bool
    @Published private(set) var notebook = false
    @Published private(set) var engineEnabled = false
    @Published private(set) var storageError: String?
    @Published private(set) var preferenceError: String?
    private var generation: UInt64 = 0
    private(set) var ledger = KeepAwakeRecap()
    private let repository: KeepAwakeRecapStore
    private let defaults: UserDefaults
    private let locked: () -> Bool
    private let savePreference: (Bool) -> Bool
    private let presenter: ((KeepAwakeRecap.Cycle, Bool) -> Bool)?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var pendingWrites = 0
    var hasPendingPersistence: Bool { (loading && loadTask != nil) || pendingWrites > 0 }
    private var revision: UInt64 = 0
    private var loading = true
    private var stopped = false
    private var buffered: [KeepAwakeRecap.Frame] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var uiEnabled = false
    private var nextCheckpoint = 0.0
    private var panel: KeepAwakeRecapPanel?
    private(set) var lidIsClosed: Bool?
    var canOpen: Bool { notebook && latest != nil && lidIsClosed == false && !locked() }
    init(defaults: UserDefaults, root: URL,
         isLocked: @escaping () -> Bool = KeepAwakeRecapController.sessionLocked,
         preferenceWriter: ((Bool) -> Bool)? = nil,
         presenter: ((KeepAwakeRecap.Cycle, Bool) -> Bool)? = nil) {
        self.presenter = presenter
        self.defaults = defaults; repository = KeepAwakeRecapStore(root: root); locked = isLocked
        autoShow = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        savePreference = preferenceWriter ?? { value in defaults.set(value, forKey: Self.preferenceKey); return defaults.object(forKey: Self.preferenceKey) as? Bool == value }
    }
    static func stamp() -> KeepAwakeRecap.Stamp {
        .init(continuous: KeepAwakeClock.now(), awake: ProcessInfo.processInfo.systemUptime, wall: Date().timeIntervalSince1970)
    }
    nonisolated static func sessionLocked() -> Bool {
        sessionLocked(CGSessionCopyCurrentDictionary() as? [String: Any])
    }
    nonisolated static func sessionLocked(_ session: [String: Any]?) -> Bool {
        guard let session,
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, onConsole else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    func start(installUI: Bool = true) {
        guard loadTask == nil else { return }; uiEnabled = installUI; stopped = false
        generation &+= 1
        let expectedGeneration = generation
        let repository = repository
        loadTask = Task { [weak self] in
            let result: Result<KeepAwakeRecap, Error>
            do { result = .success(try await repository.load()) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, !self.stopped, self.generation == expectedGeneration else { return }
            switch result {
            case .success(var restored): restored.resumeAfterRelaunch(); self.ledger = restored
            case .failure: self.storageError = "先前回顾记录无法读取；本次将保留不完整标记。"
            }
            self.loading = false
            let pending = self.buffered; self.buffered.removeAll()
            for frame in pending { self.observe(frame) }
            self.latest = self.ledger.latest
        }
        if installUI {
            for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
                distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.sessionChanged() }
                })
            }
            for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.sessionChanged() }
                })
            }
        }
    }
    func observe(_ frame: KeepAwakeRecap.Frame) {
        guard !stopped else { return }
        notebook = frame.notebook; engineEnabled = frame.enabled; lidIsClosed = frame.closed
        if frame.closed != false || locked() { panel?.dismiss() }
        if loading {
            if buffered.count < 32 { buffered.append(frame) }
            else { buffered.removeFirst(); buffered.append(frame); storageError = "回顾启动期间部分记录未能保留" }
            return
        }
        let previousLedger = ledger
        let oldCurrent = ledger.current?.id, oldLatest = ledger.latest?.id
        ledger.observe(frame)
        if storageError != nil { ledger.markStorageFailure() }
        if !autoShow || !frame.enabled { ledger.suppressAutomatic() }
        if latest != ledger.latest { latest = ledger.latest; panel?.updateSummary(latest) }
        if ledger != previousLedger && (oldCurrent != ledger.current?.id || oldLatest != ledger.latest?.id || frame.stamp.continuous >= nextCheckpoint) {
            nextCheckpoint = frame.stamp.continuous + 15; persist()
        }
        panel?.updatePreference(autoShow, editable: engineEnabled)
        attemptAutomatic()
    }
    func willSleep(_ supplied: KeepAwakeRecap.Stamp? = nil) {
        guard !loading, !stopped else { return }; ledger.willSleep(supplied ?? Self.stamp()); persist()
    }
    func didWake(_ supplied: KeepAwakeRecap.Stamp? = nil) {
        guard !loading, !stopped else { return }; ledger.didWake(supplied ?? Self.stamp()); latest = ledger.latest; panel?.updateSummary(latest); persist()
    }
    func sleepAccepted(_ supplied: KeepAwakeRecap.Stamp? = nil) {
        guard !loading, !stopped else { return }; ledger.sleepRequestAccepted(supplied ?? Self.stamp()); persist()
    }
    @discardableResult func setAutoShow(_ value: Bool) -> Bool {
        guard engineEnabled, notebook else { return false }
        guard savePreference(value) else { preferenceError = "自动显示偏好未保存，原选择仍生效。"; return false }
        preferenceError = nil
        autoShow = value
        if !value { ledger.suppressAutomatic(); persist() }
        panel?.updatePreference(value, editable: engineEnabled); return true
    }
    private func sessionChanged() {
        if locked() { panel?.dismiss() } else { attemptAutomatic() }
    }
    private func attemptAutomatic() {
        guard uiEnabled, autoShow, engineEnabled, canOpen,
              let summary = latest, summary.autoEligible, !summary.shown, summary.hasReasonToShow else { return }
        show(summary, manual: false)
    }
    func openLatest() {
        guard canOpen, let latest else { return }; show(latest, manual: true)
    }
    private func show(_ summary: KeepAwakeRecap.Cycle, manual: Bool) {
        guard !locked(), !stopped else { return }
        if let presenter {
            if presenter(summary, manual) { ledger.markShown(summary.id); latest = ledger.latest; persist() }
            return
        }
        panel?.dismiss()
        let next = KeepAwakeRecapPanel(summary: summary, autoShow: autoShow, editable: engineEnabled,
            toggle: { [weak self] value in self?.setAutoShow(value) ?? false })
        panel = next
        if next.present(manual: manual) { ledger.markShown(summary.id); latest = ledger.latest; persist() }
    }
    private func persist() {
        guard !loading else { return }
        revision &+= 1
        let data = ledger, revision = revision, repository = repository, expectedGeneration = generation
        pendingWrites += 1
        saveTask = Task { [weak self] in
            defer { self?.pendingWrites -= 1 }
            do {
                let saved = try await repository.save(data, revision: revision)
                if saved, let self, self.generation == expectedGeneration, self.revision == revision, !self.stopped {
                    self.storageError = nil; self.panel?.showPersistenceError(nil)
                }
            }
            catch {
                guard let self, !self.stopped, self.generation == expectedGeneration, self.revision == revision else { return }
                self.storageError = "回顾记录保存失败，不能保证重启后可恢复。"
                self.ledger.markStorageFailure(); self.latest = self.ledger.latest
                self.panel?.showPersistenceError(self.storageError)
            }
        }
    }
    func flush() async { await loadTask?.value; await saveTask?.value }
    func prepareForTermination() async {
        shutdown()
        guard let pending = saveTask else { return }
        // Metadata must never indefinitely delay power release or app termination.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var returned = false
            Task { @MainActor in
                await pending.value
                if !returned { returned = true; continuation.resume() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !returned { returned = true; continuation.resume() }
            }
        }
    }
    func shutdown() {
        guard !stopped else { return }
        if !loading { ledger.resumeAfterRelaunch(); persist() }
        stopped = true; generation &+= 1; loadTask?.cancel(); loadTask = nil; loading = true; buffered.removeAll(); panel?.dismiss(); panel = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        workspaceObservers.removeAll(); distributedObservers.removeAll()
    }
}
