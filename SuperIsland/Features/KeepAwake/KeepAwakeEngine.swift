import Foundation

/// Pure policy: no IOKit, preferences, UI, filesystem or wall clock side effects.
struct KeepAwakeEngine: Equatable {
    enum Mode: String, Codable { case automatic, manual }
    enum ScreenPolicy: String, Codable, CaseIterable {
        case system, awake, off
        var title: String {
            switch self { case .system: "跟随系统"; case .awake: "保持屏幕常亮"; case .off: "任务运行时熄屏" }
        }
    }
    struct Preferences: Codable, Equatable {
        var acOnly = true
        var minimumBattery = 20
        var respectLowPower = true
        var screen: ScreenPolicy = .system
        var notifyCompletion = true
    }
    struct Environment: Equatable {
        enum Hardware { case notebook, desktop, unknown }
        var hardware: Hardware = .unknown
        var battery: Int?
        var onAC: Bool?
        var lowPower = false
        var thermalUnsafe = false
    }
    enum TaskState: String, Codable {
        case running, waiting, idle, completed, failed, cancelled, ended
        var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled || self == .ended }
    }
    struct Event: Codable, Equatable {
        var source: String
        var session: String
        var sequence: UInt64
        var state: TaskState
        var taskID: String? = nil
        var startsTask: Bool? = nil
        var storageKey: String { source + ":" + session + (taskID.map { ":" + $0 } ?? "") }
    }
    struct Session: Equatable {
        var event: Event
        var lastSeen: TimeInterval
        var releaseAt: TimeInterval?
        // Connection freshness cannot end an established task. A waiting or
        // idle snapshot by itself, however, must not invent work.
        var hasStarted = false
        var isUnfinished: Bool { hasStarted && !event.state.isTerminal }
        func needsVerification(now: TimeInterval) -> Bool {
            isUnfinished && (event.state == .idle || now >= lastSeen + KeepAwakeEngine.staleAfter)
        }
    }
    struct Decision: Equatable {
        var hold: Bool
        var title: String
        var detail: String
        var runningSources: Int = 0
    }
    var preferences = Preferences()
    private(set) var enabled = false
    private(set) var mode: Mode = .automatic
    private(set) var manualDeadline: TimeInterval?
    private(set) var manualStarted = false
    private(set) var pauseDeadline: TimeInterval?
    private(set) var protection: String?
    private(set) var sessions: [String: Session] = [:]
    private(set) var capacityExceededSources: Set<String> = []
    private struct Lifecycle: Equatable { var sequence: UInt64; var closed: Bool }
    private var lifecycles: [String: Lifecycle] = [:]
    // Tombstones remain for the connection lifetime, preventing delayed replay.
    // A new connection resets the source generation and clears its tombstones.
    static let sessionLimit = 1024
    static let releaseDelay: TimeInterval = 30
    static let staleAfter: TimeInterval = 45

    mutating func setAutomatic(_ enabled: Bool) {
        stop(); mode = .automatic; self.enabled = enabled
    }
    mutating func selectMode(_ mode: Mode) {
        self.mode = mode; manualStarted = false; manualDeadline = nil; pauseDeadline = nil
    }
    mutating func setEnabled(_ value: Bool) {
        if value { enabled = true } else { stop() }
    }
    mutating func startManual(minutes: Int, now: TimeInterval) {
        guard [0, 30, 60, 120].contains(minutes) else { return }
        mode = .manual; enabled = true; manualStarted = true
        manualDeadline = minutes == 0 ? nil : now + Double(minutes * 60)
        pauseDeadline = nil
    }
    mutating func togglePause(now: TimeInterval) {
        guard enabled else { return }
        if let deadline = pauseDeadline, deadline > now { pauseDeadline = nil }
        else { pauseDeadline = now + 1800 }
    }
    mutating func stop() {
        enabled = false; manualStarted = false; manualDeadline = nil; pauseDeadline = nil
        // A safety latch is intentionally not cleared by off/on.
    }
    func unsafeReason(_ environment: Environment) -> String? {
        if environment.thermalUnsafe { return "系统热压力过高" }
        switch environment.hardware {
        case .unknown: return "尚不能确认设备电源能力"
        case .desktop: return nil
        case .notebook:
            guard let battery = environment.battery, let onAC = environment.onAC else { return "电源状态未知" }
            if battery < preferences.minimumBattery { return "电量低于 \(preferences.minimumBattery)%" }
            if preferences.acOnly && !onAC { return "已断开电源" }
            if preferences.respectLowPower && environment.lowPower { return "系统处于低电量模式" }
            return nil
        }
    }
    mutating func resume(environment: Environment) -> Bool {
        guard unsafeReason(environment) == nil else { return false }
        protection = nil; enabled = true; return true
    }
    mutating func disconnect(source: String) {
        sessions = sessions.filter { $0.value.event.source != source }
        lifecycles = lifecycles.filter { !$0.key.hasPrefix(source + ":") }
        capacityExceededSources.remove(source)
    }
    @discardableResult
    mutating func receive(_ event: Event, now: TimeInterval) -> Bool {
        guard now.isFinite, KeepAwakeSource.all.contains(where: { $0.id == event.source }),
              !event.session.isEmpty, event.session.utf8.count <= 128,
              !event.session.contains("\n"), !event.session.contains(":") else { return false }
        if let taskID = event.taskID {
            guard !taskID.isEmpty, taskID.utf8.count <= 128,
                  !taskID.contains(":"), !taskID.contains("\n"),
                  !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        }
        let owner = event.source + ":" + event.session
        if let taskID = event.taskID, [KeepAwakeHookContract.codexSessionStarted, KeepAwakeHookContract.codexSessionEnded].contains(taskID) {
            guard KeepAwakeHookContract.codexSources.contains(event.source), event.startsTask == false,
                  event.sequence > (lifecycles[owner]?.sequence ?? 0) else { return false }
            let closed = event.taskID == KeepAwakeHookContract.codexSessionEnded
            guard closed ? event.state == .ended : event.state == .idle else { return false }
            guard lifecycles[owner] != nil || lifecycles.count < Self.sessionLimit else {
                capacityExceededSources.insert(event.source); return false
            }
            lifecycles[owner] = Lifecycle(sequence: event.sequence, closed: closed)
            if closed {
                for key in sessions.keys where sessions[key]?.event.source == event.source && sessions[key]?.event.session == event.session {
                    guard var task = sessions[key], task.isUnfinished, event.sequence > task.event.sequence else { continue }
                    task.event.state = .ended; task.event.sequence = event.sequence; task.event.startsTask = false
                    task.lastSeen = now; task.releaseAt = now + Self.releaseDelay
                    sessions[key] = task
                }
            }
            return true
        }
        guard event.state != .ended else { return false } // Ended is a session boundary, not a claimed result.
        let key = event.storageKey
        if let lifecycle = lifecycles[owner] {
            guard event.sequence > lifecycle.sequence else { return false }
            // A delayed explicit outcome may refine an ended task, but cannot
            // create work or revive any stage in a closed session.
            if lifecycle.closed && (!event.state.isTerminal || sessions[key] == nil) { return false }
        }
        let previous = sessions[key]
        if KeepAwakeHookContract.isAuxiliaryTask(source: event.source, taskID: event.taskID) {
            // Interrupt cleanup must not invent an auxiliary card for every
            // ordinary turn. An interrupted compaction cannot restart later;
            // completed compactions can still repeat in a non-interrupted turn.
            if event.state == .cancelled && previous == nil { return false }
            if previous?.event.state == .cancelled { return false }
        }
        guard previous == nil || event.sequence > previous!.event.sequence else { return false }
        guard previous != nil || sessions.count < Self.sessionLimit else {
            // Missing a newly reported running task must not silently permit
            // sleep. Keep a bounded source-level unknown latch until reconnect.
            if event.state == .running { capacityExceededSources.insert(event.source) }
            return false
        }
        // A late waiting/idle notification cannot revive a finished task.
        // Only an explicit new running event starts the next round.
        if previous?.event.state.isTerminal == true, !event.state.isTerminal,
           event.state != .running || event.startsTask == false { return false }
        let hasStarted = event.state == .running || previous?.hasStarted == true
        let release: TimeInterval?
        if event.state.isTerminal {
            if previous?.event.state.isTerminal == true {
                release = previous?.releaseAt // Repeated terminal events do not extend the hold.
            } else {
                release = previous?.isUnfinished == true ? now + Self.releaseDelay : nil
            }
        } else { release = nil }
        sessions[key] = Session(event: event, lastSeen: now, releaseAt: release, hasStarted: hasStarted)
        return true
    }
    mutating func evaluate(now: TimeInterval, environment: Environment) -> Decision {
        if !enabled { return .init(hold: false, title: "保持唤醒已关闭", detail: protection.map { "保护记录：" + $0 } ?? "打开自动模式或开始手动计时。") }
        // Expiry is evaluated before pause/protection so neither extends a timer.
        if mode == .manual, let end = manualDeadline, now >= end {
            stop(); return .init(hold: false, title: "手动计时已结束", detail: "本次保持已停止。")
        }
        if let reason = unsafeReason(environment) { protection = reason }
        if let reason = protection { return .init(hold: false, title: "保护已停止保持", detail: reason + "；条件恢复后请手动检查并继续。") }
        if let end = pauseDeadline, now < end { return .init(hold: false, title: "已暂停", detail: "剩余约 \(Int(ceil((end - now) / 60))) 分钟。") }
        pauseDeadline = nil
        if mode == .manual {
            return .init(hold: manualStarted, title: manualStarted ? "手动保持唤醒" : "等待开始手动保持",
                         detail: manualStarted ? manualDeadline.map { "剩余约 \(Int(ceil(($0 - now) / 60))) 分钟。" } ?? "直到手动停止。" : "选择时长并点击开始。")
        }
        let unfinished = sessions.values.filter(\.isUnfinished)
        let running = unfinished.filter { $0.event.state == .running && now < $0.lastSeen + Self.staleAfter }
        let waiting = unfinished.filter { $0.event.state == .waiting }
        let grace = sessions.values.contains { $0.event.state.isTerminal && ($0.releaseAt ?? 0) > now }
        let count = Set(running.map { $0.event.source }).count
        if !capacityExceededSources.isEmpty {
            return .init(hold: true, title: "任务状态记录已满 · 继续保持", detail: "有新任务尚未记录，不能确认全部结束。请核实任务后断开并重新接入该来源，或手动停止保持。", runningSources: count)
        }
        if !running.isEmpty { return .init(hold: true, title: "正在保持唤醒", detail: "\(count) 个来源正在运行。", runningSources: count) }
        if !unfinished.isEmpty {
            if waiting.count == unfinished.count {
                return .init(hold: true, title: "等待确认 · 继续保持", detail: "任务尚未结束；处理确认后可以继续，或手动停止保持。")
            }
            return .init(hold: true, title: "任务状态待核实 · 继续保持", detail: "尚未收到明确结束信号；不会因长时间没有新事件而释放，请核实来源或手动停止。")
        }
        if grace { return .init(hold: true, title: "全部任务已结束 · 等待释放", detail: "最后一个任务结束 30 秒后撤回本功能的保持；新任务会取消释放。") }
        return .init(hold: false, title: "等待任务", detail: "已开启自动模式；有效任务开始后才保持。")
    }

    /// Completion is distinct from stopping, disconnecting, pausing or losing a
    /// heartbeat. Only a started task with a trusted terminal can reach ready.
    func completionSleepPhase(now: TimeInterval, environment: Environment) -> KeepAwakeCompletionSleep.Phase {
        guard enabled, mode == .automatic, protection == nil,
              unsafeReason(environment) == nil, environment.hardware == .notebook,
              pauseDeadline.map({ now >= $0 }) ?? true,
              capacityExceededSources.isEmpty else { return .inactive }
        if sessions.values.contains(where: \.isUnfinished) { return .unfinished }
        let deadlines = sessions.values.compactMap { session -> TimeInterval? in
            guard session.hasStarted, session.event.state.isTerminal else { return nil }
            return session.releaseAt
        }
        guard let deadline = deadlines.max() else { return .inactive }
        return now < deadline ? .grace : .ready
    }
}

/// Clock-derived UI state can change without a new task event or an overall
/// decision change (e.g. one stale session while another remains running).
struct KeepAwakeSourceFreshness {
    private(set) var unverifiedSources: Set<String> = []
    mutating func update(engine: KeepAwakeEngine, now: TimeInterval) -> Bool {
        let current = Set(engine.sessions.values.lazy.filter { $0.needsVerification(now: now) }.map { $0.event.source })
        guard current != unverifiedSources else { return false }
        unverifiedSources = current
        return true
    }
}

/// One request for a batch that actually owned a lid hold. Historical terminal
/// tombstones never arm it. Ineligible hardware consumes completion so closing
/// the lid later cannot put an unrelated session to sleep.
struct KeepAwakeCompletionSleep {
    enum Phase: Equatable { case inactive, unfinished, grace, ready }
    struct Snapshot: Equatable {
        var lidClosed: Bool?
        var externalDisplays: Int?
        var sleepDisabled: Bool?
        var isClosedWithoutExternalDisplay: Bool { lidClosed == true && externalDisplays == 0 }
        var permitsRequest: Bool { isClosedWithoutExternalDisplay && sleepDisabled == false }
    }
    enum RequestResult: Equatable { case skipped, accepted, failed(Int32) }
    private(set) var armed = false

    mutating func cancel() { armed = false }

    mutating func update(phase: Phase, ownsLidHold: Bool, releasesConfirmed: Bool, snapshot: Snapshot) -> Bool {
        switch phase {
        case .inactive:
            cancel()
        case .unfinished:
            if ownsLidHold { armed = true }
        case .grace:
            break
        case .ready:
            guard armed else { return false }
            guard snapshot.isClosedWithoutExternalDisplay else { cancel(); return false }
            guard releasesConfirmed else { return false }
            cancel() // Consume before invoking any API; errors are not retried.
            return snapshot.permitsRequest
        }
        return false
    }

    /// Re-read physical/power state immediately before the synchronous request.
    /// A successful API reply means accepted, not verified physical sleep.
    static func attempt(snapshot: () -> Snapshot, request: () -> Int32) -> RequestResult {
        guard snapshot().permitsRequest else { return .skipped }
        let result = request()
        return result == 0 ? .accepted : .failed(result)
    }
}

struct KeepAwakeSource: Identifiable {
    let id: String
    let name: String
    let integration: String
    let hookFamily: String?
    var readsLocalStatus: Bool { id == "kimi-code-desktop" }
    var isDeferred: Bool { id == "kimi-code-desktop" || id == "kimi-code-cli" }
    var canConnect: Bool {
        return !isDeferred && (hookFamily != nil || readsLocalStatus)
    }
    static let all: [Self] = [
        .init(id: "claude-code", name: "Claude Code", integration: "Hook 接入候选；需验证事件与长任务存活", hookFamily: "claude"),
        .init(id: "claude-cowork", name: "Claude Cowork", integration: "待验证：尚无可靠任务状态接口", hookFamily: nil),
        .init(id: "codex-cli", name: "Codex CLI", integration: "官方 hooks 与完成通知接入候选；需在 Codex 审阅信任，新任务收到有效事件后才保持", hookFamily: "codex"),
        .init(id: "codex-desktop", name: "Codex 桌面端", integration: "本地/Worktree 任务使用官方 hooks 与完成通知；有公开本机服务时可只读接入。需在 Codex 审阅信任，云端编排不在此通道内", hookFamily: "codex"),
        .init(id: "opencode", name: "OpenCode", integration: "插件事件与心跳候选；需验证当前 OpenCode 版本", hookFamily: "opencode"),
        .init(id: "gemini-cli", name: "Gemini CLI", integration: "Hook 接入候选；需验证事件与长任务存活", hookFamily: "gemini"),
        .init(id: "pi", name: "Pi", integration: "扩展生命周期候选；需验证等待交互的覆盖", hookFamily: "pi"),
        .init(id: "copilot-cli", name: "Copilot CLI", integration: "待验证：当前 CLI hook 兼容性", hookFamily: nil),
        .init(id: "hermes-cli", name: "Hermes CLI", integration: "待验证：CLI 生命周期", hookFamily: nil),
        .init(id: "hermes-gateway", name: "Hermes Gateway", integration: "待验证：Gateway handler 与本地依赖", hookFamily: nil),
        .init(id: "cursor", name: "Cursor", integration: "待验证：编辑器空闲不能视为工作", hookFamily: nil),
        .init(id: "cursor-agent", name: "Cursor Agent", integration: "待验证：与 Cursor 的重复任务映射", hookFamily: nil),
        .init(id: "cline", name: "Cline", integration: "待验证：扩展常驻不能视为工作", hookFamily: nil),
        .init(id: "aider", name: "Aider", integration: "待验证：交互等待与工作的区分", hookFamily: nil),
        .init(id: "conductor", name: "Conductor", integration: "待验证：多任务接口", hookFamily: nil),
        .init(id: "goose", name: "Goose", integration: "待验证：任务生命周期接口", hookFamily: nil),
        .init(id: "windsurf", name: "Windsurf", integration: "待验证：官网来源与当前版本接口", hookFamily: nil),
        .init(id: "kimi-code-desktop", name: "Kimi Code 桌面端", integration: "暂缓接入；不读取任务状态", hookFamily: nil),
        .init(id: "kimi-code-cli", name: "Kimi Code CLI", integration: "暂缓接入；不安装 hook", hookFamily: nil),
        .init(id: "qoder-desktop", name: "Qoder 桌面端", integration: "官方 hook 接入候选；已开始任务持续保持，停止候选需核实，不保证自动完成识别", hookFamily: "qoder"),
        .init(id: "qoder-cli", name: "Qoder CLI", integration: "官方 hook 已确认；独立 CLI 版本及桌面共享配置去重待核验", hookFamily: nil),
        .init(id: "trae-solo-desktop", name: "TRAE SOLO 桌面端", integration: "本机 CN 0.1.49；尚未确认可靠外部任务状态接口", hookFamily: nil),
        .init(id: "trae-solo-cli", name: "TRAE SOLO CLI", integration: "独立 CLI 形态待核验；不将桌面启动器当作 Agent CLI", hookFamily: nil),
        .init(id: "zcode-desktop", name: "ZCode 桌面端", integration: "官方 hook 接入候选；提问与恢复已实测，最终完成信号尚待核验", hookFamily: "zcode"),
        .init(id: "zcode-cli", name: "ZCode CLI", integration: "已发现内置 Agent 运行时；是否可独立使用及配置边界待核验", hookFamily: nil),
        .init(id: "workbuddy-desktop", name: "WorkBuddy 桌面端", integration: "官方 hook 接入候选；提问与恢复已实测，最终完成信号尚待核验", hookFamily: "workbuddy"),
        .init(id: "workbuddy-cli", name: "WorkBuddy CLI", integration: "已发现 wb 启动入口；独立任务能力与桌面后端关系待核验", hookFamily: nil)
    ]
}
