import AppKit
import Combine
import UserNotifications

@MainActor
final class KeepAwakeService: ObservableObject {
    enum ConnectionFailure: LocalizedError {
        case cleanupPending
        var errorDescription: String? { "该来源仍有配置待清理，请先重试清理后再接入。" }
    }
    static let shared = KeepAwakeService()
    @Published private(set) var engine = KeepAwakeEngine()
    @Published private(set) var decision = KeepAwakeEngine.Decision(hold: false, title: "保持唤醒已关闭", detail: "打开自动模式或开始手动计时。")
    @Published private(set) var environment = KeepAwakeEngine.Environment()
    @Published private(set) var actualHold = false
    @Published private(set) var runtimeError: String?
    @Published private(set) var connections: Set<String> = []
    @Published private(set) var cleanupPendingSources: Set<String> = []
    @Published private(set) var receivedSources: Set<String> = []
    @Published private(set) var activity: [String] = []
    @Published private(set) var notificationStatus = "尚未检查通知权限"
    @Published private(set) var localSourceStatus = "等待首次只读检查"
    @Published private(set) var recoveryInProgress = false
    @Published private(set) var codexStatus = "当前任务状态通道未接通"
    private var codexTask: Task<Void, Never>?
    private var codexGeneration: UInt64 = 0
    private var nextCodexPoll: TimeInterval = 0
    private var codexSequence: UInt64 = 0
    private var codexLedger = KeepAwakeCodexMonitor.Ledger()
    private let codexSampler: @MainActor () async throws -> KeepAwakeCodexMonitor.Snapshot
    private let codexAvailability: @MainActor () -> Bool
    private let hookUninstaller: @MainActor (KeepAwakeSource) throws -> Void
    private var resumeGeneration: UInt64 = 0
    private var localSourceTask: Task<Void, Never>?
    private var localSourceGeneration = 0
    private var nextLocalPoll: TimeInterval = 0
    private var localPollStarted: TimeInterval?
    private let localSampler: @MainActor () async -> KeepAwakeKimiMonitor.Snapshot
    var openSettings: (() -> Void)?
    private let defaults: UserDefaults
    let lid = KeepAwakeLidClient()
    private var lidObserver: AnyCancellable?
    private let power = KeepAwakePower()
    private var mailbox: KeepAwakeMailbox
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var lastLog = ""
    private static let preferencesKey = "keepAwake.preferences.v1"
    private static let sourcesKey = "keepAwake.sources.v1"
    private static let cleanupKey = "keepAwake.cleanupPending.v1"

    init(defaults: UserDefaults = .standard, root: URL? = nil,
         localSampler: @escaping @MainActor () async -> KeepAwakeKimiMonitor.Snapshot = { await KeepAwakeKimiMonitor.sample() },
         codexSampler: @escaping @MainActor () async throws -> KeepAwakeCodexMonitor.Snapshot = {
             try await Task.detached(priority: .utility) { try KeepAwakeCodexRPC.sample() }.value
         },
         codexAvailability: @escaping @MainActor () -> Bool = { KeepAwakeCodexRPC.endpointAvailable() },
         hookUninstaller: @escaping @MainActor (KeepAwakeSource) throws -> Void = { try KeepAwakeHookInstaller.uninstall(source: $0) }) {
        self.defaults = defaults
        self.localSampler = localSampler
        self.codexSampler = codexSampler
        self.codexAvailability = codexAvailability
        self.hookUninstaller = hookUninstaller
        cleanupPendingSources = Set(defaults.stringArray(forKey: Self.cleanupKey) ?? [])
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland")
            .appendingPathComponent("KeepAwake")
        mailbox = KeepAwakeMailbox(root: support)
        if let data = defaults.data(forKey: Self.preferencesKey),
           let value = try? JSONDecoder().decode(KeepAwakeEngine.Preferences.self, from: data),
           (5...50).contains(value.minimumBattery) { engine.preferences = value }
    }
    func start() {
        guard !started else { return }; started = true
        lidObserver = lid.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        let saved = defaults.stringArray(forKey: Self.sourcesKey) ?? []
        let deferred = Set(KeepAwakeSource.all.filter(\.isDeferred).map(\.id))
        let retained = saved.filter { !deferred.contains($0) && !cleanupPendingSources.contains($0) }
        if retained != saved { defaults.set(retained, forKey: Self.sourcesKey) }
        for source in retained {
            guard let item = KeepAwakeSource.all.first(where: { $0.id == source }),
                  item.id == "codex-desktop" ? codexAvailability() : item.canConnect else { continue }
            do {
                if !item.readsLocalStatus { try mailbox.connect(source: source) }
                connections.insert(source)
            }
            catch { record("来源凭据初始化失败；未启用该来源。") }
        }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if notification.name == NSWorkspace.willSleepNotification {
                        self.power.apply(hold: false, policy: .system, notebook: self.isNotebook)
                        self.actualHold = self.power.isHolding
                    } else { self.tick() }
                }
            })
        }
        refreshNotificationPermission()
    }
    func shutdown() {
        cancelResume()
        codexGeneration &+= 1; codexTask?.cancel(); codexTask = nil
        localSourceGeneration += 1; localSourceTask?.cancel(); localSourceTask = nil
        timer?.invalidate(); timer = nil; engine.stop(); lid.disable()
        power.apply(hold: false, policy: .system, notebook: isNotebook)
        actualHold = power.isHolding
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll(); started = false
        for source in connections { try? mailbox.disconnect(source: source); engine.disconnect(source: source) }
        connections.removeAll(); receivedSources.removeAll()
    }
    var isNotebook: Bool { environment.hardware == .notebook }
    var preferences: KeepAwakeEngine.Preferences { engine.preferences }
    var lidStatus: String {
        guard environment.hardware != .unknown else { return "设备能力待确认" }
        guard isNotebook else { return "桌面 Mac · 无需合盖支持" }
        if lid.applied { return "合盖保持已开启" }
        if lid.busy { return "正在检查合盖状态" }
        if lid.requiresApproval { return "等待系统授权" }
        if lid.enabled { return "合盖已就绪 · 等待任务" }
        return lid.registered ? "合盖保持未开启" : "合盖支持未设置"
    }
    var lidExplanation: String {
        lid.message
    }
    private func cancelResume() { resumeGeneration &+= 1; recoveryInProgress = false }
    func setEnabled(_ enabled: Bool) { cancelResume(); engine.setEnabled(enabled); tick() }
    func automatic(_ enabled: Bool) { cancelResume(); engine.setAutomatic(enabled); tick() }
    func selectMode(_ mode: KeepAwakeEngine.Mode) { cancelResume(); engine.selectMode(mode); tick() }
    func manual(minutes: Int) { cancelResume(); engine.startManual(minutes: minutes, now: KeepAwakeClock.now()); tick() }
    func pause() { cancelResume(); engine.togglePause(now: KeepAwakeClock.now()); tick() }
    func stop() { cancelResume(); engine.stop(); tick() }
    func resume() {
        guard !recoveryInProgress else { return }
        environment = KeepAwakePower.environment()
        guard engine.unsafeReason(environment) == nil else {
            record("恢复检查未通过，保护条件仍然存在。"); tick(); return
        }
        resumeGeneration &+= 1
        let generation = resumeGeneration
        recoveryInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let recovered = await self.lid.recoverAndEnable()
            guard generation == self.resumeGeneration else { return }
            self.recoveryInProgress = false
            self.environment = KeepAwakePower.environment()
            guard recovered else { self.record("合盖恢复尚未确认，请检查辅助程序提示。"); self.tick(); return }
            if !self.engine.resume(environment: self.environment) { self.record("电源条件已变化，恢复检查未通过。") }
            self.tick()
        }
    }
    func updatePreferences(_ edit: (inout KeepAwakeEngine.Preferences) -> Void) {
        cancelResume()
        var value = engine.preferences; edit(&value)
        guard (5...50).contains(value.minimumBattery) else { return }
        engine.preferences = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.preferencesKey) }
        tick()
    }
    func connect(_ source: KeepAwakeSource) throws {
        guard !cleanupPendingSources.contains(source.id) else { throw ConnectionFailure.cleanupPending }
        if source.id == "codex-desktop" {
            // Repeated actions must preserve the ledger's sequence and open
            // guards; resetting only one side could reject the next task.
            guard !connections.contains(source.id) else { return }
            guard codexAvailability() else { throw KeepAwakeCodexRPC.Failure.unavailable }
            engine.disconnect(source: source.id); receivedSources.remove(source.id)
            codexGeneration &+= 1; codexTask?.cancel(); codexTask = nil
            codexLedger = .init(); codexSequence = 0; nextCodexPoll = 0
            codexStatus = "等待官方本机接口的首次只读检查"
            connections.insert(source.id); saveSources()
            record("Codex 本机状态接入已启用；仅监测同一共享服务中的本机任务。")
            tick(); return
        }
        guard source.canConnect else { throw CocoaError(.featureUnsupported) }
        if source.readsLocalStatus {
            connections.insert(source.id); saveSources(); nextLocalPoll = 0
            record("Kimi 桌面端已启用只读检查；总开关独立控制保持。")
            tick(); return
        }
        try mailbox.connect(source: source.id)
        do {
            try KeepAwakeHookInstaller.install(source: source, credential: mailbox.credentialsDirectory.appendingPathComponent(source.id + ".json"))
        } catch {
            try? mailbox.disconnect(source: source.id)
            if source.id == "codex-cli", case KeepAwakeCodexInstaller.Failure.transactionPending = error {
                cleanupPendingSources.insert(source.id); saveCleanup()
            }
            throw error
        }
        engine.disconnect(source: source.id); receivedSources.remove(source.id)
        connections.insert(source.id); saveSources()
        record(source.name + " 配置已写入，等待真实事件验证；结束信号不明时会继续保持。")
        tick()
    }
    func disconnect(_ source: KeepAwakeSource) throws {
        // Stop accepting events first, even if external configuration restoration fails.
        engine.disconnect(source: source.id); connections.remove(source.id); receivedSources.remove(source.id)
        saveSources()
        if source.id == "codex-desktop" {
            codexGeneration &+= 1; codexTask?.cancel(); codexTask = nil
            codexLedger = .init(); codexStatus = "当前任务状态通道未接通"
            tick(); return
        }
        if source.readsLocalStatus {
            localSourceGeneration += 1; localSourceTask?.cancel(); localSourceTask = nil
            localSourceStatus = "未接入"; tick(); return
        }
        defer { tick() }
        // Persist the cleanup obligation before external writes. A failed
        // uninstall stays retryable while incoming events remain rejected.
        cleanupPendingSources.insert(source.id); saveCleanup()
        try mailbox.disconnect(source: source.id)
        try hookUninstaller(source)
        cleanupPendingSources.remove(source.id); saveCleanup()
        record(source.name + " 已断开；其他 hook 配置保持不变。")
    }
    private func saveSources() { defaults.set(connections.sorted(), forKey: Self.sourcesKey) }
    private func saveCleanup() { defaults.set(cleanupPendingSources.sorted(), forKey: Self.cleanupKey) }
    func sourceStatus(_ source: KeepAwakeSource) -> String {
        if cleanupPendingSources.contains(source.id) { return "已停止接收 · 配置清理待重试" }
        if source.isDeferred { return "暂缓接入" }
        if source.id == "codex-desktop" {
            return connections.contains(source.id) ? codexStatus :
                (source.canConnect ? "检测到本机接口 · 尚未核验接入" : "当前任务状态通道未接通")
        }
        guard connections.contains(source.id) else { return source.canConnect ? "未接入" : "待验证接口" }
        if source.readsLocalStatus { return localSourceStatus }
        if engine.capacityExceededSources.contains(source.id) { return "任务记录已满 · 继续保持，请核实后重新接入" }
        guard receivedSources.contains(source.id) else {
            return source.id == "codex-cli" ? "配置已写入 · 请在 Codex 审阅信任，等待真实事件" : "配置已写入 · 等待事件"
        }
        let sessions = engine.sessions.values.filter { $0.event.source == source.id }
        let now = KeepAwakeClock.now()
        if sessions.contains(where: { $0.isUnfinished && ($0.event.state == .idle || now >= $0.lastSeen + KeepAwakeEngine.staleAfter) }) { return "状态待核实 · 任务未结束，继续保持" }
        if sessions.contains(where: { $0.event.state == .running }) { return "已收到运行事件 · 适配待验收" }
        if sessions.contains(where: { $0.isUnfinished && $0.event.state == .waiting }) { return "等待确认 · 继续保持" }
        return "最近事件：未开始或已明确结束"
    }
    func tick() {
        environment = KeepAwakePower.environment()
        let now = KeepAwakeClock.now()
        pollLocalSource(now: now)
        pollCodexSource(now: now)
        for event in mailbox.read() where connections.contains(event.source) {
            let previous = engine.sessions[event.storageKey]
            if engine.receive(event, now: now) {
                receivedSources.insert(event.source)
                if previous?.isUnfinished == true && event.state == .completed && engine.enabled &&
                    !KeepAwakeHookContract.isAuxiliaryTask(source: event.source, taskID: event.taskID) {
                    notifyCompletion(source: event.source, session: event.session, sequence: event.sequence)
                }
            }
        }
        let next = engine.evaluate(now: now, environment: environment)
        power.apply(hold: next.hold, policy: preferences.screen, notebook: isNotebook)
        actualHold = power.isHolding; runtimeError = power.error
        lid.apply(hold: next.hold && actualHold && isNotebook, preferences: preferences)
        decision = next
        if next.hold && !actualHold {
            decision.title = "保持请求未生效"
            decision.detail = power.error ?? "系统尚未确认保持断言。"
        } else if !next.hold && actualHold {
            decision.title = "正在重试释放"
            decision.detail = "系统尚未确认释放，不能显示已恢复。"
        }
        let stateKey = decision.title + (runtimeError ?? "")
        if lastLog != stateKey { lastLog = stateKey; record(decision.title) }
    }
    private func pollCodexSource(now: TimeInterval) {
        let source = "codex-desktop"
        guard started, connections.contains(source), codexTask == nil, now >= nextCodexPoll else { return }
        let generation = codexGeneration
        nextCodexPoll = now + 5
        codexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot: KeepAwakeCodexMonitor.Snapshot
            let status: String
            do {
                snapshot = try await self.codexSampler()
                let active = snapshot.threads.filter { $0.status == "active" }
                let waiting = active.filter { !$0.activeFlags.isEmpty }
                status = active.isEmpty ? "官方本机接口已连接 · 没有已知运行任务" :
                    "本机运行 \(active.count) 个线程，其中 \(waiting.count) 个等待交互或状态确认"
            } catch {
                snapshot = .init(threads: [])
                // Transport errors contain no raw server response, path, or message body.
                status = (error as? KeepAwakeCodexRPC.Failure)?.localizedDescription ?? "Codex 状态读取失败；已开始任务继续保持。"
            }
            guard !Task.isCancelled, generation == self.codexGeneration, self.connections.contains(source) else { return }
            self.codexTask = nil
            let arrived = KeepAwakeClock.now()
            self.nextCodexPoll = arrived + 5
            self.codexSequence &+= 1
            for event in self.codexLedger.consume(snapshot: snapshot, now: arrived, sequence: self.codexSequence) {
                let previous = self.engine.sessions[event.storageKey]
                if self.engine.receive(event, now: arrived) {
                    self.receivedSources.insert(source)
                    if previous?.isUnfinished == true && event.state == .completed && self.engine.enabled &&
                        !KeepAwakeHookContract.isAuxiliaryTask(source: event.source, taskID: event.taskID) {
                        self.notifyCompletion(source: source, session: event.session, sequence: event.sequence)
                    }
                }
            }
            let unfinished = self.engine.sessions.values.filter { $0.event.source == source && $0.isUnfinished }
            let unknown = self.engine.capacityExceededSources.contains(source) || unfinished.contains { $0.event.state == .idle }
            self.codexStatus = unknown || (!unfinished.isEmpty && snapshot.threads.allSatisfy({ $0.status != "active" })) ?
                "任务状态待核实 · 继续保持；" + status : status
            self.tick()
        }
    }
    func pollLocalSource(now: TimeInterval) {
        let source = KeepAwakeKimiMonitor.sourceID
        guard KeepAwakeSource.all.first(where: { $0.id == source })?.canConnect == true else { return }
        if let began = localPollStarted, localSourceTask != nil, now >= began + 20 {
            // A stalled adapter must neither display a successful old snapshot
            // forever nor apply its result after a replacement request starts.
            localSourceGeneration += 1; localSourceTask?.cancel(); localSourceTask = nil
            localPollStarted = nil; nextLocalPoll = now + 5
            localSourceStatus = "本机检查超时；状态未知"
        }
        guard started, connections.contains(source), localSourceTask == nil, now >= nextLocalPoll else { return }
        nextLocalPoll = now + 5
        localPollStarted = now
        let generation = localSourceGeneration
        let sample = localSampler
        localSourceTask = Task { @MainActor [weak self] in
            let snapshot = await sample()
            guard !Task.isCancelled, let self, self.started,
                  generation == self.localSourceGeneration, self.connections.contains(source) else { return }
            self.localSourceStatus = snapshot.message
            if let state = snapshot.state {
                let event = KeepAwakeEngine.Event(source: source, session: "desktop-aggregate",
                    sequence: mach_continuous_time(), state: state)
                if self.engine.receive(event, now: KeepAwakeClock.now()) { self.receivedSources.insert(source) }
            }
            self.localSourceTask = nil
            self.localPollStarted = nil
            self.tick()
        }
    }
    private func record(_ message: String) {
        activity.insert(Date().formatted(date: .omitted, time: .standard) + " · " + message, at: 0)
        if activity.count > 40 { activity.removeLast(activity.count - 40) }
    }
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshNotificationPermission() }
        }
    }
    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] value in
            Task { @MainActor [weak self] in
                self?.notificationStatus = value.authorizationStatus == .authorized ? "系统已允许通知" : "系统尚未允许通知；不影响保持唤醒"
            }
        }
    }
    private func notifyCompletion(source: String, session: String, sequence: UInt64) {
        guard preferences.notifyCompletion, let name = KeepAwakeSource.all.first(where: { $0.id == source })?.name else { return }
        let content = UNMutableNotificationContent()
        content.title = "SuperIsland · 任务完成"
        content.body = name + " 的本次任务已完成。"
        content.categoryIdentifier = "superisland.keep-awake.completion"
        // NotificationManager does not turn notifications into new source events.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka1.\(source).\(session).\(sequence)", content: content, trigger: nil))
    }
}
