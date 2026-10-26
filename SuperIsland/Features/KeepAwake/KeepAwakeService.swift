import AppKit
import Combine
import UserNotifications
import Darwin

/// Explicit opt-in, app-owned acceptance recording. It never controls power,
/// invokes Codex, consumes IPC, or records prompts, paths, titles, or credentials.
/// The recorder lives in this App rather than a tool worker that can be reaped
/// when the very Codex turn under test ends.
@MainActor
final class KeepAwakeAcceptanceRecorder {
    struct Request: Codable { var id: UUID; var expiresAt: TimeInterval }
    let root: URL
    private let wall: () -> TimeInterval
    private let continuous: () -> TimeInterval
    private let awake: () -> TimeInterval
    private var handle: FileHandle?
    private var request: Request?
    private var lastRequest: UUID?
    private var bytes = 0
    private var nextSample: TimeInterval = 0
    private var continuousDeadline: TimeInterval = 0
    static let byteLimit = 2_097_152
    var sampleDue: Bool { handle != nil && continuous() >= nextSample }
    var requestURL: URL { root.appendingPathComponent("acceptance-request.json") }

    init(root: URL, wall: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         continuous: @escaping () -> TimeInterval = { KeepAwakeClock.now() },
         awake: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.root = root; self.wall = wall; self.continuous = continuous; self.awake = awake
    }
    func poll() {
        if let request, wall() >= request.expiresAt || continuous() >= continuousDeadline { finish("deadline"); return }
        guard handle == nil else { return }
        do {
            var info = stat()
            guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return }
            let fd = open(requestURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 1024 else { return }
            let value = try JSONDecoder().decode(Request.self, from: input.read(upToCount: 1025) ?? Data())
            guard value.id != lastRequest, value.expiresAt.isFinite,
                  value.expiresAt > wall(), value.expiresAt <= wall() + 900 else { return }
            lastRequest = value.id
            let output = root.appendingPathComponent("acceptance-\(value.id.uuidString)-\(getpid()).jsonl")
            let file = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard file >= 0 else { return }
            handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            request = value; bytes = 0; nextSample = 0
            continuousDeadline = continuous() + min(900, value.expiresAt - wall())
            append("recorder-started", fields: ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "pid": getpid(), "expiresAt": value.expiresAt])
        } catch { finish("recorder-error") }
    }
    func append(_ event: String, fields: [String: Any] = [:]) {
        guard let handle else { return }
        var row = fields
        row["event"] = event; row["epoch"] = wall(); row["continuous"] = continuous(); row["awake"] = awake()
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            if event != "recorder-finished", bytes + data.count > Self.byteLimit - 2048 {
                finish("byte-limit"); return
            }
            guard bytes + data.count <= Self.byteLimit else { return }
            try handle.write(contentsOf: data); try handle.synchronize(); bytes += data.count
            if event == "power-sample" { nextSample = continuous() + 2 }
        } catch {
            try? handle.close(); self.handle = nil; request = nil
        }
    }
    func finish(_ reason: String) {
        append("recorder-finished", fields: ["reason": reason])
        try? handle?.close(); handle = nil; request = nil
    }
}

@MainActor
final class KeepAwakeService: ObservableObject {
    enum ConnectionFailure: LocalizedError {
        case cleanupPending, bindingMissing, overlappingCodexChannels
        var errorDescription: String? {
            switch self {
            case .cleanupPending: "该来源仍有配置待清理，请先重试清理后再接入。"
            case .bindingMissing: "旧接入缺少配置位置记录，未改动任何 Codex 配置；请重新接入以确认目标环境。"
            case .overlappingCodexChannels: "同一 Codex 环境不能同时通过共享服务和独立来源重复监测。请先断开旧的共享服务接入，再使用本地 hooks 接入。"
            }
        }
    }
    static let shared = KeepAwakeService()
    @Published private(set) var engine = KeepAwakeEngine()
    @Published private(set) var decision = KeepAwakeEngine.Decision(hold: false, title: "保持唤醒已关闭", detail: "打开自动模式或开始手动计时。")
    @Published private(set) var environment = KeepAwakeEngine.Environment()
    @Published private(set) var actualHold = false
    @Published private(set) var runtimeError: String?
    @Published private(set) var connections: Set<String> = []
    @Published private(set) var cleanupPendingSources: Set<String> = []
    @Published private(set) var sourceRestorationIssues: Set<String> = []
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
    private let codexSampler: (@MainActor () async throws -> KeepAwakeCodexMonitor.Snapshot)?
    private let codexAvailability: @MainActor () -> Bool
    private let codexResolver: @MainActor () throws -> KeepAwakeCodexEnvironment.Profile
    private let codexHookInstaller: (@MainActor (KeepAwakeSource, URL, KeepAwakeCodexEnvironment.Profile) throws -> Void)?
    private let hookUninstaller: (@MainActor (KeepAwakeSource) throws -> Void)?
    private let codexHookUninstaller: (@MainActor (KeepAwakeSource, URL, KeepAwakeCodexEnvironment.Profile) throws -> Void)?
    private var codexConnections: [String: KeepAwakeCodexConnection] = [:]
    private var resumeGeneration: UInt64 = 0
    private var localSourceTask: Task<Void, Never>?
    private var localSourceGeneration = 0
    private var nextLocalPoll: TimeInterval = 0
    private var localPollStarted: TimeInterval?
    private let localSampler: @MainActor () async -> KeepAwakeKimiMonitor.Snapshot
    var openSettings: (() -> Void)?
    private let defaults: UserDefaults
    let lid: KeepAwakeLidClient
    private var lidObserver: AnyCancellable?
    private let power = KeepAwakePower()
    private var completionSleep = KeepAwakeCompletionSleep()
    private var completionSleepError: String?
    private var mailbox: KeepAwakeMailbox
    private let acceptance: KeepAwakeAcceptanceRecorder
    let recap: KeepAwakeRecapController
    private var recapPhysical: KeepAwakeCompletionSleep.Snapshot?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var lastLog = ""
    private static let preferencesKey = "keepAwake.preferences.v1"
    private static let sourcesKey = "keepAwake.sources.v1"
    private static let cleanupKey = "keepAwake.cleanupPending.v1"

    init(defaults: UserDefaults = .standard, root: URL? = nil,
         localSampler: @escaping @MainActor () async -> KeepAwakeKimiMonitor.Snapshot = { await KeepAwakeKimiMonitor.sample() },
         codexSampler: (@MainActor () async throws -> KeepAwakeCodexMonitor.Snapshot)? = nil,
         codexAvailability: @escaping @MainActor () -> Bool = { KeepAwakeCodexRPC.endpointAvailable() },
         hookUninstaller: (@MainActor (KeepAwakeSource) throws -> Void)? = nil,
         codexResolver: @escaping @MainActor () throws -> KeepAwakeCodexEnvironment.Profile = { try KeepAwakeCodexEnvironment.discover() },
         codexHookInstaller: (@MainActor (KeepAwakeSource, URL, KeepAwakeCodexEnvironment.Profile) throws -> Void)? = nil,
         codexHookUninstaller: (@MainActor (KeepAwakeSource, URL, KeepAwakeCodexEnvironment.Profile) throws -> Void)? = nil,
         lidClient: KeepAwakeLidClient? = nil) {
        self.defaults = defaults
        lid = lidClient ?? KeepAwakeLidClient(
            readEnabledIntent: { defaults.bool(forKey: KeepAwakeLidClient.enabledIntentKey) },
            saveEnabledIntent: { defaults.set($0, forKey: KeepAwakeLidClient.enabledIntentKey) })
        self.localSampler = localSampler
        self.codexSampler = codexSampler
        self.codexAvailability = codexAvailability
        self.hookUninstaller = hookUninstaller
        self.codexResolver = codexResolver
        self.codexHookInstaller = codexHookInstaller
        self.codexHookUninstaller = codexHookUninstaller
        codexConnections = KeepAwakeCodexConnection.load(defaults.data(forKey: KeepAwakeCodexConnection.defaultsKey))
        cleanupPendingSources = Set(defaults.stringArray(forKey: Self.cleanupKey) ?? [])
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland")
            .appendingPathComponent("KeepAwake")
        mailbox = KeepAwakeMailbox(root: support)
        acceptance = KeepAwakeAcceptanceRecorder(root: support)
        recap = KeepAwakeRecapController(defaults: defaults, root: support)
        if let data = defaults.data(forKey: Self.preferencesKey),
           let value = try? JSONDecoder().decode(KeepAwakeEngine.Preferences.self, from: data),
           (5...50).contains(value.minimumBattery) { engine.preferences = value }
    }
    func start() {
        guard !started else { return }; started = true
        recap.start()
        lidObserver = lid.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        let saved = defaults.stringArray(forKey: Self.sourcesKey) ?? []
        // A crash after recording the selected home but before committing the
        // connection may leave external writes behind. Retain its cleanup path.
        for (source, binding) in codexConnections where binding.mode == .hooks && !saved.contains(source) {
            cleanupPendingSources.insert(source)
        }
        saveCleanup()
        let deferred = Set(KeepAwakeSource.all.filter(\.isDeferred).map(\.id))
        let retained = saved.filter { !deferred.contains($0) && !cleanupPendingSources.contains($0) }
        if retained != saved { defaults.set(retained, forKey: Self.sourcesKey) }
        for source in retained {
            guard let item = KeepAwakeSource.all.first(where: { $0.id == source }), item.canConnect else { continue }
            do {
                if source.hasPrefix("codex-") {
                    guard let binding = codexConnections[source] else {
                        sourceRestorationIssues.insert(source)
                        record("Codex 旧接入未恢复：缺少环境绑定，请重新确认接入。")
                        continue
                    }
                    if source == "codex-desktop", binding.mode == .rpc,
                       retained.contains("codex-cli"), let cli = codexConnections["codex-cli"],
                       cli.profile.codexHome.standardizedFileURL.resolvingSymlinksInPath().path == binding.profile.codexHome.standardizedFileURL.resolvingSymlinksInPath().path {
                        codexConnections.removeValue(forKey: source); saveCodexConnections()
                        sourceRestorationIssues.insert(source)
                        record("Codex 旧共享服务接入与 CLI 重叠，未恢复重复监测；请重新确认桌面来源。")
                        continue
                    }
                    if binding.mode == .hooks {
                        try KeepAwakeCodexInstaller.refreshOwnedLifecycleHooks(codexHome: binding.profile.codexHome)
                        try mailbox.connect(source: source)
                    }
                } else if !item.readsLocalStatus { try mailbox.connect(source: source) }
                connections.insert(source)
            }
            catch { record("来源凭据初始化失败；未启用该来源。") }
        }
        tick()
        if isNotebook { lid.restoreAuthorizedIntent() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.completionSleep.cancel()
                    self.acceptance.append(notification.name == NSWorkspace.willSleepNotification ? "system-will-sleep" : "system-did-wake")
                    if notification.name == NSWorkspace.willSleepNotification {
                        self.recap.willSleep()
                        self.power.apply(hold: false, policy: .system, notebook: self.isNotebook)
                        self.actualHold = self.power.isHolding
                    } else { self.recap.didWake(); self.tick() }
                }
            })
        }
        refreshNotificationPermission()
    }
    func shutdown() {
        recap.shutdown()
        acceptance.finish("app-shutdown")
        completionSleep.cancel()
        cancelResume()
        codexGeneration &+= 1; codexTask?.cancel(); codexTask = nil
        localSourceGeneration += 1; localSourceTask?.cancel(); localSourceTask = nil
        timer?.invalidate(); timer = nil; engine.stop(); lid.suspendForShutdown()
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
    var releasePending: Bool { !engine.enabled && (power.hasPendingAssertions || lid.hasPendingRelease) }
    var canEnable: Bool { engine.enabled || (!releasePending && !recoveryInProgress) }
    func setEnabled(_ enabled: Bool) {
        guard !enabled || canEnable else { return }
        cancelResume()
        if !enabled { completionSleep.cancel(); completionSleepError = nil }
        else if isNotebook { lid.restoreAuthorizedIntent() }
        engine.setEnabled(enabled); tick()
    }
    func automatic(_ enabled: Bool) {
        guard !enabled || canEnable else { return }
        cancelResume(); completionSleep.cancel()
        if enabled && isNotebook { lid.restoreAuthorizedIntent() }
        engine.setAutomatic(enabled); tick()
    }
    func selectMode(_ mode: KeepAwakeEngine.Mode) { cancelResume(); engine.selectMode(mode); tick() }
    func manual(minutes: Int) {
        guard canEnable else { return }
        cancelResume(); completionSleep.cancel()
        if isNotebook { lid.restoreAuthorizedIntent() }
        engine.startManual(minutes: minutes, now: KeepAwakeClock.now()); tick()
    }
    func pause() { cancelResume(); engine.togglePause(now: KeepAwakeClock.now()); tick() }
    func stop() { setEnabled(false) }
    func retryRelease() {
        guard !engine.enabled else { return }
        completionSleep.cancel()
        lid.retryOwnedRelease()
        tick()
    }
    func resume() {
        guard engine.enabled, !recoveryInProgress else { return }
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
    func prepareCodexConnection(_ source: KeepAwakeSource) throws -> KeepAwakeCodexConnection? {
        guard source.hookFamily == "codex" else { return nil }
        let profile = try codexConnections[source.id]?.profile ?? codexResolver()
        // Hooks share one router and attribute each event once. Automatically
        // selecting all-loaded RPC based on socket presence would duplicate
        // CLI turns when both sources are enabled on another computer.
        let mode = codexConnections[source.id]?.mode ?? .hooks
        return .init(profile: profile, mode: mode)
    }
    func connect(_ source: KeepAwakeSource, codexConnection proposed: KeepAwakeCodexConnection? = nil) throws {
        completionSleep.cancel()
        guard !cleanupPendingSources.contains(source.id) else { throw ConnectionFailure.cleanupPending }
        if source.id.hasPrefix("codex-"), connections.contains(source.id) { return }
        let codex = try proposed ?? prepareCodexConnection(source)
        let previousBinding = codexConnections[source.id]
        if let codex {
            let other = source.id == "codex-cli" ? "codex-desktop" : "codex-cli"
            if connections.contains(other), let existing = codexConnections[other],
               existing.profile.codexHome.standardizedFileURL.resolvingSymlinksInPath().path == codex.profile.codexHome.standardizedFileURL.resolvingSymlinksInPath().path,
               existing.mode == .rpc || codex.mode == .rpc { throw ConnectionFailure.overlappingCodexChannels }
        }
        if source.id == "codex-desktop", codex?.mode == .rpc {
            // Repeated actions must preserve the ledger's sequence and open
            // guards; resetting only one side could reject the next task.
            guard !connections.contains(source.id) else { return }
            guard codexAvailability(), let codex else { throw KeepAwakeCodexRPC.Failure.unavailable }
            codexConnections[source.id] = codex; saveCodexConnections()
            engine.disconnect(source: source.id); receivedSources.remove(source.id)
            codexGeneration &+= 1; codexTask?.cancel(); codexTask = nil
            codexLedger = .init(); codexSequence = 0; nextCodexPoll = 0
            codexStatus = "等待官方本机接口的首次只读检查"
            connections.insert(source.id); saveSources()
            sourceRestorationIssues.remove(source.id)
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
            let credential = mailbox.credentialsDirectory.appendingPathComponent(source.id + ".json")
            if source.hookFamily == "codex" {
                guard let codex, codex.mode == .hooks else { throw ConnectionFailure.bindingMissing }
                let profile = codex.profile
                // Persist intent before the first external write, including a
                // partial transaction which may need cleanup after a restart.
                codexConnections[source.id] = .init(profile: profile, mode: .hooks); saveCodexConnections()
                if let codexHookInstaller { try codexHookInstaller(source, credential, profile) }
                else {
                    try KeepAwakeCodexInstaller.install(source: source, credential: credential,
                        home: FileManager.default.homeDirectoryForCurrentUser,
                        tool: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool"),
                        codexHome: profile.codexHome, cli: profile.executableURL, allowNotifyForwarding: true)
                }
            } else { try KeepAwakeHookInstaller.install(source: source, credential: credential) }
        } catch {
            try? mailbox.disconnect(source: source.id)
            if source.hookFamily == "codex", case KeepAwakeCodexInstaller.Failure.transactionPending = error {
                cleanupPendingSources.insert(source.id); saveCleanup()
            } else if source.hookFamily == "codex" {
                codexConnections[source.id] = previousBinding; saveCodexConnections()
            }
            throw error
        }
        engine.disconnect(source: source.id); receivedSources.remove(source.id)
        connections.insert(source.id); saveSources()
        sourceRestorationIssues.remove(source.id)
        record(source.name + " 配置已写入，等待真实事件验证；结束信号不明时会继续保持。")
        tick()
    }
    func disconnect(_ source: KeepAwakeSource) throws {
        completionSleep.cancel()
        // Stop accepting events first, even if external configuration restoration fails.
        engine.disconnect(source: source.id); connections.remove(source.id); receivedSources.remove(source.id)
        saveSources()
        sourceRestorationIssues.remove(source.id)
        if source.id == "codex-desktop", codexConnections[source.id]?.mode == .rpc {
            codexGeneration &+= 1; codexTask?.cancel(); codexTask = nil
            codexLedger = .init(); codexStatus = "当前任务状态通道未接通"
            codexConnections.removeValue(forKey: source.id); saveCodexConnections()
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
        tick() // Release this source's hold before a slow config editor runs.
        if let hookUninstaller { try hookUninstaller(source) }
        else if source.hookFamily == "codex" {
            guard let binding = codexConnections[source.id] else { throw ConnectionFailure.bindingMissing }
            let credential = mailbox.credentialsDirectory.appendingPathComponent(source.id + ".json")
            if let codexHookUninstaller { try codexHookUninstaller(source, credential, binding.profile) }
            else {
                let profile = try codexEditingProfile(binding.profile)
                try KeepAwakeCodexInstaller.uninstall(source: source, home: FileManager.default.homeDirectoryForCurrentUser,
                    credential: credential, codexHome: profile.codexHome, cli: profile.executableURL)
            }
        } else { try KeepAwakeHookInstaller.uninstall(source: source) }
        cleanupPendingSources.remove(source.id); saveCleanup()
        codexConnections.removeValue(forKey: source.id); saveCodexConnections()
        record(source.name + " 已断开；其他 hook 配置保持不变。")
    }
    private func saveSources() { defaults.set(connections.sorted(), forKey: Self.sourcesKey) }
    private func saveCleanup() { defaults.set(cleanupPendingSources.sorted(), forKey: Self.cleanupKey) }
    private func saveCodexConnections() {
        if let data = try? JSONEncoder().encode(codexConnections) { defaults.set(data, forKey: KeepAwakeCodexConnection.defaultsKey) }
    }
    private func codexEditingProfile(_ bound: KeepAwakeCodexEnvironment.Profile) throws -> KeepAwakeCodexEnvironment.Profile {
        guard !KeepAwakeCodexRPC.isOfficialExecutable(bound.executableURL) else { return bound }
        // An application move may invalidate the editor's old location. Only
        // replace the signed editor, never the home or endpoint being cleaned.
        let editor = try codexResolver().executableURL
        guard KeepAwakeCodexRPC.isOfficialExecutable(editor) else { throw KeepAwakeCodexInstaller.Failure.unavailable }
        return .init(executableURL: editor, codexHome: bound.codexHome, socketURL: bound.socketURL)
    }
    func sourceStatus(_ source: KeepAwakeSource) -> String {
        if cleanupPendingSources.contains(source.id) { return "已停止接收 · 配置清理待重试" }
        if sourceRestorationIssues.contains(source.id) { return "旧接入位置待确认 · 请重新接入" }
        if source.isDeferred { return "暂缓接入" }
        if source.id == "codex-desktop", codexConnections[source.id]?.mode == .rpc {
            return connections.contains(source.id) ? codexStatus :
                (source.canConnect ? "检测到本机接口 · 尚未核验接入" : "当前任务状态通道未接通")
        }
        guard connections.contains(source.id) else { return source.canConnect ? "未接入" : "待验证接口" }
        if source.readsLocalStatus { return localSourceStatus }
        if engine.capacityExceededSources.contains(source.id) { return "任务记录已满 · 继续保持，请核实后重新接入" }
        guard receivedSources.contains(source.id) else {
            return source.hookFamily == "codex" ? "配置已写入 · 请在 Codex 审阅信任，并用本地新任务验证" : "配置已写入 · 等待事件"
        }
        let sessions = engine.sessions.values.filter { $0.event.source == source.id }
        let now = KeepAwakeClock.now()
        if sessions.contains(where: { $0.isUnfinished && ($0.event.state == .idle || now >= $0.lastSeen + KeepAwakeEngine.staleAfter) }) { return "状态待核实 · 任务未结束，继续保持" }
        if sessions.contains(where: { $0.event.state == .running }) { return "已收到运行事件 · 适配待验收" }
        if sessions.contains(where: { $0.isUnfinished && $0.event.state == .waiting }) { return "等待确认 · 继续保持" }
        return "最近事件：未开始或已明确结束"
    }
    func tick() {
        acceptance.poll()
        let currentEnvironment = KeepAwakePower.environment()
        if environment != currentEnvironment { environment = currentEnvironment }
        lid.refreshRegistrationStatus()
        let now = KeepAwakeClock.now()
        recapPhysical = KeepAwakeSystemSleep.snapshot()
        defer { recapPhysical = nil }
        updateRecap()
        pollLocalSource(now: now)
        pollCodexSource(now: now)
        for event in mailbox.read() where connections.contains(event.source) {
            let previous = engine.sessions[event.storageKey]
            if engine.receive(event, now: now) {
                if let session = engine.sessions[event.storageKey] { updateRecap(sessions: [session], complete: false) }
                acceptance.append("accepted-task-event", fields: ["source": event.source,
                    "sessionHash": KeepAwakeHookContract.anonymousIdentity(event.session),
                    "taskHash": event.taskID.map(KeepAwakeHookContract.anonymousIdentity) ?? "legacy",
                    "state": event.state.rawValue, "startsTask": event.startsTask ?? false])
                receivedSources.insert(event.source)
                if previous?.isUnfinished == true && event.state == .completed && engine.enabled &&
                    !KeepAwakeHookContract.isAuxiliaryTask(source: event.source, taskID: event.taskID) {
                    notifyCompletion(source: event.source, session: event.session, sequence: event.sequence)
                }
            }
        }
        // Evaluating an unchanged value through @Published's modifying accessor
        // used to invalidate settings and menus on every timer tick.
        var evaluatedEngine = engine
        let next = evaluatedEngine.evaluate(now: now, environment: environment)
        if evaluatedEngine != engine { engine = evaluatedEngine }
        power.apply(hold: next.hold, policy: preferences.screen, notebook: isNotebook)
        if actualHold != power.isHolding { actualHold = power.isHolding }
        let currentError = power.error ?? completionSleepError
        if runtimeError != currentError { runtimeError = currentError }
        lid.apply(hold: next.hold && actualHold && isNotebook, preferences: preferences)
        var currentDecision = next
        if next.hold && !actualHold {
            currentDecision.title = "保持请求未生效"
            currentDecision.detail = power.error ?? "系统尚未确认保持断言。"
        } else if !next.hold && actualHold {
            currentDecision.title = "正在重试释放"
            currentDecision.detail = "系统尚未确认释放，不能显示已恢复。"
        }
        if !engine.enabled && power.hasPendingAssertions {
            currentDecision.title = "功能已关闭 · 系统保持释放未确认"
            currentDecision.detail = power.error ?? "正在重试释放本功能的保持断言。"
        }
        if !engine.enabled && lid.hasPendingRelease {
            currentDecision.title = lid.releaseFailed ? "功能已关闭 · 系统设置恢复失败" : "功能已关闭 · 正在恢复系统设置"
            currentDecision.detail = lid.message
        }
        if decision != currentDecision { decision = currentDecision }
        updateRecap() // Capture release acknowledgement before a system sleep can suspend the app.
        finishCompletedLidTasks(now: now)
        updateRecap()
        let stateKey = decision.title + (runtimeError ?? "")
        if lastLog != stateKey { lastLog = stateKey; record(decision.title) }
        if acceptance.sampleDue {
            let physical = KeepAwakeSystemSleep.snapshot()
            let pending = engine.sessions.values.filter(\.isUnfinished)
            acceptance.append("power-sample", fields: ["requestedHold": decision.hold, "actualHold": actualHold,
                "lidApplied": lid.applied, "lidReleaseConfirmed": lid.releasedForCompletionSleep,
                "lidClosed": physical.lidClosed.map { $0 as Any } ?? NSNull(),
                "sleepDisabled": physical.sleepDisabled.map { $0 as Any } ?? NSNull(),
                "externalDisplays": physical.externalDisplays.map { $0 as Any } ?? NSNull(),
                "unfinishedCount": pending.count, "pendingTruncated": pending.count > 64,
                "pending": pending.prefix(64).map { ["source": $0.event.source,
                    "sessionHash": KeepAwakeHookContract.anonymousIdentity($0.event.session),
                    "taskHash": $0.event.taskID.map(KeepAwakeHookContract.anonymousIdentity) ?? "legacy",
                    "state": $0.event.state.rawValue] }])
        }
    }
    /// One-way metadata projection; this function never feeds the power policy.
    private func updateRecap(sessions: [KeepAwakeEngine.Session]? = nil, complete: Bool = true) {
        let physical = recapPhysical ?? KeepAwakeSystemSleep.snapshot()
        let now = KeepAwakeClock.now()
        let values = (sessions ?? Array(engine.sessions.values)).sorted { $0.event.storageKey < $1.event.storageKey }
        let inputs = values.map { session -> KeepAwakeRecap.TaskInput in
            let event = session.event
            let state: KeepAwakeRecap.State
            if event.state.isTerminal { state = KeepAwakeRecap.State(rawValue: event.state.rawValue) ?? .unknown }
            else if event.state == .idle || now >= session.lastSeen + KeepAwakeEngine.staleAfter { state = .unknown }
            else { state = KeepAwakeRecap.State(rawValue: event.state.rawValue) ?? .unknown }
            // Existing authenticated compaction IDs explicitly identify auxiliary work.
            // Other legacy events do not prove human/background classification.
            let kind: KeepAwakeRecap.Kind = KeepAwakeHookContract.isAuxiliaryTask(source: event.source, taskID: event.taskID) ? .background : .unclassified
            return .init(id: KeepAwakeHookContract.anonymousIdentity(event.storageKey), source: event.source,
                         kind: kind, state: state, started: session.hasStarted)
        }
        recap.observe(.init(stamp: KeepAwakeRecapController.stamp(), notebook: isNotebook,
            closed: physical.lidClosed, enabled: engine.enabled, actualHold: actualHold,
            lidRequired: lid.enabled, lidApplied: lid.applied,
            released: !actualHold && !lid.applied && !lid.hasPendingRelease && physical.sleepDisabled == false,
            protection: engine.protection != nil, error: runtimeError != nil || lid.releaseFailed,
            automatic: engine.mode == .automatic, tasks: inputs, completeTasks: complete,
            paused: engine.pauseDeadline.map { $0 > now } ?? false))
    }
    private func finishCompletedLidTasks(now: TimeInterval) {
        let phase = engine.completionSleepPhase(now: now, environment: environment)
        if phase == .inactive || phase == .unfinished { completionSleepError = nil }
        if phase == .inactive { completionSleep.cancel(); return }
        // A failed/disabled helper must never be interpreted as a release ack.
        guard lid.enabled, !recoveryInProgress, power.error == nil else {
            completionSleep.cancel(); return
        }
        if phase == .unfinished {
            // Arming only needs ownership. Physical/release checks are relevant
            // at ready, and are still re-read immediately before requesting sleep.
            _ = completionSleep.update(phase: phase, ownsLidHold: actualHold && lid.applied,
                                       releasesConfirmed: false, snapshot: .init())
            return
        }
        if phase == .grace { return }
        // Let an in-flight source snapshot publish any new task before deciding
        // that a previously completed batch is still the last work.
        if phase == .ready && (codexTask != nil || localSourceTask != nil) { return }
        let released = !actualHold && power.displayID == 0 && lid.releasedForCompletionSleep
        guard completionSleep.update(phase: phase, ownsLidHold: actualHold && lid.applied,
                                     releasesConfirmed: released, snapshot: KeepAwakeSystemSleep.snapshot()) else { return }
        acceptance.append("completion-sleep-request", fields: ["ownAssertionsReleased": released])
        // No await between the final policy evaluation and the physical recheck.
        // Newly received work cancels ready before a later tick can request sleep.
        switch KeepAwakeCompletionSleep.attempt(snapshot: KeepAwakeSystemSleep.snapshot,
                                               request: KeepAwakeSystemSleep.request) {
        case .skipped:
            acceptance.append("completion-sleep-skipped")
            break
        case .accepted:
            recap.sleepAccepted()
            acceptance.append("completion-sleep-accepted")
            record("全部任务已结束；系统已接受合盖休眠请求，实际休眠仍由系统确认。")
        case .failed(let code):
            acceptance.append("completion-sleep-rejected", fields: ["code": code])
            completionSleepError = "保持已释放，但系统未接受合盖休眠请求（\(code)）。"
            runtimeError = completionSleepError
        }
    }
    private func pollCodexSource(now: TimeInterval) {
        let source = "codex-desktop"
        guard started, connections.contains(source), codexConnections[source]?.mode == .rpc,
              codexTask == nil, now >= nextCodexPoll else { return }
        let generation = codexGeneration
        nextCodexPoll = now + 5
        codexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot: KeepAwakeCodexMonitor.Snapshot
            let status: String
            do {
                if let sampler = self.codexSampler { snapshot = try await sampler() }
                else if let profile = self.codexConnections[source]?.profile {
                    snapshot = try await Task.detached(priority: .utility) { try KeepAwakeCodexRPC.sample(profile: profile) }.value
                } else { throw ConnectionFailure.bindingMissing }
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
                    if let session = self.engine.sessions[event.storageKey] { self.updateRecap(sessions: [session], complete: false) }
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
                if self.engine.receive(event, now: KeepAwakeClock.now()) {
                    if let session = self.engine.sessions[event.storageKey] { self.updateRecap(sessions: [session], complete: false) }
                    self.receivedSources.insert(source)
                }
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
