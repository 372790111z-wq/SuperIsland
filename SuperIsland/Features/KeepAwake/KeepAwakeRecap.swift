import Foundation

/// Read-only projection. This type has no power, task-control, IPC or UI calls.
struct KeepAwakeRecap: Codable, Equatable {
    enum Kind: String, Codable { case user, background, unclassified }
    enum State: String, Codable, CaseIterable { case running, waiting, unknown, completed, failed, cancelled, ended
        var terminal: Bool { [.completed, .failed, .cancelled, .ended].contains(self) }
        var title: String { switch self { case .running: return "运行中"; case .waiting: return "等待确认"; case .unknown: return "状态未知"; case .completed: return "已完成"; case .failed: return "失败"; case .cancelled: return "已取消"; case .ended: return "会话已结束" } }
    }
    enum Power: String, Codable { case holding, waitingRelease, released, unconfirmed, notHeld, protectedStop
        var title: String { switch self { case .holding: return "继续保持"; case .waitingRelease: return "等待释放（开盖时）"; case .released: return "已确认释放"; case .unconfirmed: return "释放尚未确认"; case .notHeld: return "本次未启用保持"; case .protectedStop: return "保护已停止保持" } }
    }
    enum ReleaseReason: String, Codable { case tasksEnded, manual, timer, pause, unknown }
    struct Stamp: Codable, Equatable {
        var continuous: Double; var awake: Double; var wall: Double
        var valid: Bool { [continuous, awake, wall].allSatisfy { $0.isFinite && $0 >= 0 } }
    }
    struct Task: Codable, Equatable, Identifiable {
        var id: String; var source: String; var kind: Kind; var state: State
        var ordinal: Int; var changedAt: Double
        var chat: KeepAwakeChatGrouping.Identity? = nil
    }
    struct TaskInput: Equatable { var id: String; var source: String; var kind: Kind; var state: State; var started: Bool; var chat: KeepAwakeChatGrouping.Identity? = nil }
    struct Frame: Equatable {
        var stamp: Stamp; var notebook: Bool; var closed: Bool?; var enabled: Bool
        var actualHold: Bool; var lidRequired: Bool; var lidApplied: Bool
        var released: Bool; var protection: Bool; var error: Bool; var automatic: Bool
        var tasks: [TaskInput]; var completeTasks = true; var paused = false
        var thermalProtection = false; var thermalLevel: Int?
        var lowPowerProtection = false
        var chatTitles: [String: String] = [:]
        var kernelSleepTime: Double? = nil
        var kernelWakeTime: Double? = nil
    }
    struct ThermalObservation: Codable, Equatable {
        var stamp: Stamp; var level: Int?
    }
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID(); var wall: Double; var continuous: Double; var title: String
    }
    struct SleepEvidence: Codable, Equatable {
        var start: Double; var end: Double; var kernel: Bool; var entryID: UUID
        var valid: Bool { start.isFinite && end.isFinite && start > 0 && end > start }
    }
    struct Cycle: Codable, Equatable, Identifiable {
        var id = UUID(); var start: Stamp?; var end: Stamp?; var last: Stamp
        var heldSeconds: Double = 0; var holding = false; var hadHold = false
        var holdComplete = true; var boundaryComplete = true; var interrupted = false
        var tasks: [Task] = []; var issues = Set<String>(); var timeline: [Entry] = []
        var power: Power = .notHeld; var releasedAt: Double?
        var releaseReason: ReleaseReason = .unknown
        var sleepStart: Stamp?; var sleepAt: Double?; var sleepCount = 0; var sleepRequested = false
        // One bounded deduplication record. Old summaries decode without it;
        // a restored/frozen cycle is never reconstructed from today's kernel pair.
        var lastSleepEvidence: SleepEvidence? = nil
        var autoEligible: Bool; var shown = false
        // First observation in this cycle, not a temperature reading or an
        // inferred onset. Optional so existing persisted summaries still decode.
        var firstThermalProtection: ThermalObservation?
        var firstLowPowerProtection: Stamp?
        // Deliberately omitted from CodingKeys: titles never reach disk.
        var displayTitles: [String: String] = [:]
        private enum CodingKeys: String, CodingKey {
            case id, start, end, last, heldSeconds, holding, hadHold, holdComplete, boundaryComplete, interrupted
            case tasks, issues, timeline, power, releasedAt, releaseReason, sleepStart, sleepAt, sleepCount, sleepRequested
            case autoEligible, shown, firstThermalProtection, firstLowPowerProtection
            case lastSleepEvidence
        }
        var chatProjection: KeepAwakeChatGrouping.Projection { KeepAwakeChatGrouping.project(tasks) }
        var duration: Double? {
            guard boundaryComplete, !interrupted, let start, let end, end.continuous >= start.continuous else { return nil }
            return end.continuous - start.continuous
        }
        var holdDuration: Double? { holdComplete && duration != nil ? min(heldSeconds, duration!) : nil }
        var userTasks: [Task] { tasks.filter { $0.kind == .user } }
        var auxiliary: [Task] { tasks.filter { $0.kind != .user } }
        var hasReasonToShow: Bool { hadHold || !userTasks.isEmpty || tasks.contains { $0.kind == .unclassified } || !issues.isEmpty }
        var incomplete: Bool { !issues.isEmpty || holdDuration == nil || tasks.contains { $0.kind == .unclassified || $0.state == .unknown } }
    }
    var version = 1
    private(set) var current: Cycle?
    private(set) var latest: Cycle?
    private var lastClosed: Bool?
    private var hasObserved = false
    static let taskLimit = 1024
    static let timelineLimit = 48
    private static let sourceIDs = Set(KeepAwakeSource.all.map(\.id))
    private mutating func append(_ text: String, at stamp: Stamp) {
        guard current != nil else { return }
        if current!.timeline.last?.title == text { return }
        if current!.timeline.count >= Self.timelineLimit {
            current!.issues.insert("部分时间线已合并，记录不完整")
            current!.timeline.remove(at: 1) // Preserve the first boundary; keep the most recent facts.
        }
        current!.timeline.append(Entry(wall: stamp.wall, continuous: stamp.continuous, title: text))
    }
    mutating func resumeAfterRelaunch() {
        hasObserved = false; lastClosed = nil
        if current != nil {
            current!.interrupted = true; current!.boundaryComplete = false; current!.holdComplete = false
            current!.holding = false; current!.autoEligible = false
            current!.sleepStart = nil; current!.issues.insert("App 曾中断，本次部分记录无法确认")
        }
        // A restored summary is available manually but can never replay an old popup.
        if latest != nil { latest!.autoEligible = false }
    }
    mutating func redactChatTitles() {
        current?.displayTitles.removeAll(); latest?.displayTitles.removeAll()
    }
    mutating func suppressAutomatic() {
        if current != nil { current!.autoEligible = false }
        if latest != nil { latest!.autoEligible = false }
    }
    mutating func markShown(_ id: UUID) { if latest?.id == id { latest!.shown = true } }
    mutating func markStorageFailure() {
        if current != nil { current!.issues.insert("回顾记录未能保存") }
        if latest != nil { latest!.issues.insert("回顾记录未能保存") }
    }
    mutating func observe(_ frame: Frame) {
        guard frame.stamp.valid else { if current != nil { current!.holdComplete = false }; return }
        guard frame.notebook else { lastClosed = nil; hasObserved = false; return }
        guard let closed = frame.closed else {
            if current != nil { current!.boundaryComplete = false; current!.holdComplete = false; current!.issues.insert("机盖状态有记录缺口") }
            return
        }
        if !hasObserved {
            hasObserved = true; lastClosed = closed
            if closed && current == nil {
                current = Cycle(start: nil, last: frame.stamp, boundaryComplete: false, autoEligible: false)
                current!.issues.insert("未记录到本次关盖起点")
            } else if !closed && current != nil {
                current!.end = nil; current!.holding = false; current!.autoEligible = false
                current!.issues.insert("实际开盖时间未记录")
                latest = current; current = nil
            }
        } else if lastClosed == false && closed {
            current = Cycle(start: frame.stamp, last: frame.stamp, autoEligible: frame.enabled)
            append("合盖", at: frame.stamp)
        }
        lastClosed = closed
        guard current != nil else { return }
        let kernelConfirmed = observeKernelSleep(frame)
        advance(frame.stamp, kernelConfirmed: kernelConfirmed)
        if !frame.enabled { current!.autoEligible = false }
        // Snapshot at the lid-open boundary BEFORE admitting any post-open task changes.
        if !closed {
            current!.end = frame.stamp; current!.holding = false
            append("开盖（统计截止）", at: frame.stamp)
            latest = current; current = nil; return
        }
        var taskIndices = Dictionary(uniqueKeysWithValues: current!.tasks.enumerated().map { ($0.element.id, $0.offset) })
        for input in frame.tasks {
            guard Self.validTask(input) else { current!.issues.insert("部分任务身份无法确认"); continue }
            if let i = taskIndices[input.id] {
                if current!.tasks[i].state != input.state {
                    current!.tasks[i].state = input.state; current!.tasks[i].changedAt = frame.stamp.wall
                    if input.state.terminal {
                        append(terminalTimelineTitle(current!.tasks[i]), at: frame.stamp)
                    }
                }
                if let chat = input.chat, chat.valid { current!.tasks[i].chat = chat }
                else if current!.tasks[i].chat != nil {
                    current!.tasks[i].chat?.sessionRuntime = .unknown
                    current!.tasks[i].chat?.rootRuntime = .unknown
                    current!.tasks[i].chat?.observedAt = frame.stamp.wall
                }
                // Classification is evidence supplied by an adapter, never inferred from text.
                if current!.tasks[i].kind == .unclassified && input.kind != .unclassified { current!.tasks[i].kind = input.kind }
            } else if input.started && !input.state.terminal {
                guard current!.tasks.count < Self.taskLimit else { current!.issues.insert("任务容量已达上限，统计不完整"); continue }
                current!.tasks.append(Task(id: input.id, source: input.source, kind: input.kind, state: input.state,
                    ordinal: current!.tasks.count + 1, changedAt: frame.stamp.wall, chat: input.chat?.valid == true ? input.chat : nil))
                taskIndices[input.id] = current!.tasks.count - 1
            }
        }
        if frame.completeTasks {
            let present = Set(frame.tasks.map(\.id))
            for i in current!.tasks.indices where !current!.tasks[i].state.terminal && !present.contains(current!.tasks[i].id) {
                current!.tasks[i].state = .unknown
                current!.tasks[i].chat?.sessionRuntime = .unknown
                current!.tasks[i].chat?.rootRuntime = .unknown
                current!.tasks[i].chat?.observedAt = frame.stamp.wall
            }
        }
        let keys = Set(current!.tasks.compactMap { $0.chat?.titleKey })
        current!.displayTitles = current!.displayTitles.filter { keys.contains($0.key) }
        for (key, title) in frame.chatTitles where keys.contains(key) {
            if let title = KeepAwakeChatGrouping.safeTitle(title) { current!.displayTitles[key] = title }
        }
        if frame.actualHold {
            current!.hadHold = true
            if frame.lidRequired && !frame.lidApplied { current!.holdComplete = false; current!.issues.insert("部分合盖保持时段未确认") }
        }
        current!.holding = frame.actualHold
        let previousPower = current!.power
        if frame.lowPowerProtection && current!.firstLowPowerProtection == nil {
            current!.firstLowPowerProtection = frame.stamp
        }
        if frame.thermalProtection && current!.firstThermalProtection == nil {
            current!.firstThermalProtection = .init(stamp: frame.stamp,
                level: frame.thermalLevel.flatMap { (0...3).contains($0) ? $0 : nil })
        }
        if frame.protection { current!.power = .protectedStop }
        else if frame.actualHold {
            current!.power = frame.automatic && !current!.tasks.contains(where: { !$0.state.terminal }) ? .waitingRelease : .holding
        } else if current!.hadHold {
            current!.power = frame.released ? .released : .unconfirmed
        } else { current!.power = .notHeld }
        if current!.power == .released && previousPower != .released {
            current!.releaseReason = frame.paused ? .pause : !frame.enabled ? .manual : !frame.automatic ? .timer : current!.tasks.allSatisfy({ $0.state.terminal }) && !current!.tasks.isEmpty ? .tasksEnded : .unknown
            current!.releasedAt = frame.stamp.wall; append("保持已确认释放", at: frame.stamp)
        }
        if frame.error { current!.issues.insert("本次保持或恢复曾出现异常，请检查保护与恢复") }
    }
    private func terminalTimelineTitle(_ task: Task) -> String {
        let outcome = KeepAwakeChatGrouping.roundTitle(task.state)
        guard let group = current?.chatProjection.groups.first(where: { $0.tasks.contains(where: { $0.id == task.id }) }),
              let member = group.members.first(where: { $0.tasks.contains(where: { $0.id == task.id }) }),
              let index = member.tasks.firstIndex(where: { $0.id == task.id }) else { return "执行记录 \(task.ordinal) · " + outcome }
        return "主聊天 \(group.ordinal) / " + (member.id == group.root ? "自身" : "子任务 \(member.ordinal)") + " / 第 \(index + 1) 轮 · " + outcome
    }
    private static func evidenceEntry(_ title: String, wall: Double, continuous: Double, cycle: inout Cycle) -> UUID {
        if cycle.timeline.count >= timelineLimit {
            cycle.issues.insert("部分时间线已合并，记录不完整")
            cycle.timeline.remove(at: 1)
        }
        let entry = Entry(wall: wall, continuous: continuous, title: title)
        cycle.timeline.append(entry)
        return entry.id
    }
    /// DarkWake does not promise an NSWorkspace didWake callback. Count a new,
    /// in-cycle public kernel pair even if the screen/session never woke. A
    /// notification may arrive before or after the same pair, so they share one
    /// confirmation rather than incrementing two unrelated counters.
    @discardableResult private mutating func observeKernelSleep(_ frame: Frame) -> Bool {
        guard current?.interrupted == false, let boundary = current?.start,
              let slept = frame.kernelSleepTime, let woke = frame.kernelWakeTime,
              slept.isFinite, woke.isFinite, slept >= boundary.wall, slept > 0,
              woke > slept, woke <= frame.stamp.wall else { return false }
        let startContinuous = frame.stamp.continuous - (frame.stamp.wall - slept)
        let wakeContinuous = frame.stamp.continuous - (frame.stamp.wall - woke)
        guard startContinuous >= boundary.continuous, wakeContinuous >= startContinuous,
              wakeContinuous <= frame.stamp.continuous else { return false }
        var cycle = current!
        let previous = cycle.lastSleepEvidence
        if let previous, previous.kernel && (woke <= previous.end || slept < previous.end) { return false }
        let sameNotification = previous.map { !$0.kernel && slept < $0.end && woke > $0.start } ?? false
        let entryID: UUID
        if sameNotification, let previous {
            entryID = previous.entryID
            if let index = cycle.timeline.firstIndex(where: { $0.id == entryID }) {
                cycle.timeline[index].wall = slept; cycle.timeline[index].continuous = startContinuous
            }
            if cycle.sleepAt == previous.start { cycle.sleepAt = slept }
        } else {
            cycle.sleepCount += 1
            cycle.sleepAt = cycle.sleepAt ?? slept
            entryID = Self.evidenceEntry("已确认系统实际休眠", wall: slept, continuous: startContinuous, cycle: &cycle)
        }
        cycle.lastSleepEvidence = .init(start: slept, end: woke, kernel: true, entryID: entryID)
        _ = Self.evidenceEntry(frame.closed == true ? "系统唤醒（仍合盖，内核已确认）" : "系统唤醒（内核已确认）",
            wall: woke, continuous: wakeContinuous, cycle: &cycle)
        if cycle.sleepStart.map({ $0.wall < woke }) == true { cycle.sleepStart = nil }
        let coversCurrentGap = woke > cycle.last.wall
        if coversCurrentGap && cycle.holding {
            cycle.holdComplete = false
            cycle.issues.insert("保持期间检测到休眠，部分保持时段未确认")
        }
        if coversCurrentGap { cycle.holding = false }
        current = cycle
        return coversCurrentGap
    }
    private mutating func advance(_ stamp: Stamp, kernelConfirmed: Bool = false) {
        guard let previous = current?.last else { return }
        let elapsed = stamp.continuous - previous.continuous
        let suspended = elapsed - (stamp.awake - previous.awake)
        guard elapsed >= 0, stamp.awake >= previous.awake else {
            current!.holdComplete = false; current!.boundaryComplete = false
            current!.issues.insert("时钟记录不连续"); current!.last = stamp; return
        }
        if elapsed > 10 && (suspended < 1 || (current!.sleepStart == nil && !kernelConfirmed)) {
            current!.holdComplete = false; current!.issues.insert("部分保持时段记录缺失")
        }
        if current!.holding && current!.sleepStart == nil {
            current!.heldSeconds += elapsed
        }
        current!.last = stamp
    }
    mutating func willSleep(_ stamp: Stamp) {
        guard current != nil, stamp.valid, current!.sleepStart == nil else { return }
        advance(stamp); current!.holding = false; current!.sleepStart = stamp
        append("系统准备休眠（尚待核验）", at: stamp)
    }
    mutating func didWake(_ stamp: Stamp) {
        guard stamp.valid else { return }
        if current != nil { confirmSleep(stamp, latestCycle: false) }
        else if let end = latest?.end, stamp.continuous >= end.continuous, stamp.continuous - end.continuous <= 2 {
            // A queued wake notification can follow the first open-lid poll. Use
            // the already frozen open stamp, never extend the old cycle into new work.
            confirmSleep(end, latestCycle: true)
        }
    }
    private mutating func confirmSleep(_ stamp: Stamp, latestCycle: Bool) {
        var value = latestCycle ? latest : current
        guard let start = value?.sleepStart else { return }
        let elapsed = stamp.continuous - start.continuous, awake = stamp.awake - start.awake
        let alreadyConfirmed = value?.lastSleepEvidence.map { $0.kernel && start.wall < $0.end } ?? false
        if elapsed >= 0, awake >= 0, elapsed - awake > 1, !alreadyConfirmed {
            value!.sleepAt = value!.sleepAt ?? start.wall; value!.sleepCount += 1
            let id = Self.evidenceEntry("已确认系统实际休眠", wall: start.wall, continuous: start.continuous, cycle: &value!)
            if stamp.wall > start.wall {
                value!.lastSleepEvidence = .init(start: start.wall, end: stamp.wall, kernel: false, entryID: id)
            } else {
                value!.lastSleepEvidence = nil
                value!.issues.insert("休眠期间系统时间发生变化，起止时间未确认")
            }
        }
        value!.sleepStart = nil; value!.holding = false; value!.last = stamp
        if latestCycle { latest = value } else { current = value }
    }
    mutating func sleepRequestAccepted(_ stamp: Stamp) {
        guard current != nil, stamp.valid else { return }
        current!.sleepRequested = true; append("系统已受理休眠请求（结果待确认）", at: stamp)
    }
    mutating func sleepRequestDeferred(_ stamp: Stamp, cpuBlocked: Bool?, blockingTypes: [String]? = nil) {
        guard current != nil, stamp.valid else { return }
        let names = ["BackgroundTask": "后台维护", "KernelCPU": "内核驱动", "PreventSystemSleep": "系统保持",
                     "ApplePushServiceTask": "推送服务", "InteractivePushServiceTask": "交互推送",
                     "InternalPreventSleep": "系统电源维护", "NetworkClientActive": "网络活动", "SoftwareUpdateTask": "系统更新"]
        let labels = Set((blockingTypes ?? []).compactMap { names[$0] }).sorted()
        let detail = labels.isEmpty ? "" : "（" + labels.joined(separator: "、") + "）"
        append(cpuBlocked == true ? "系统 CPU 保持尚未释放" + detail + "，休眠请求暂缓" : "系统 CPU 保持状态未知，休眠请求暂缓", at: stamp)
    }
    static func validTask(_ input: TaskInput) -> Bool {
        input.id.utf8.count == 64 && input.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && sourceIDs.contains(input.source)
    }
    func validate() -> Bool {
        guard version == 1 else { return false }
        for c in [current, latest].compactMap({ $0 }) {
            guard c.tasks.count <= Self.taskLimit, c.timeline.count <= Self.timelineLimit,
                  c.heldSeconds.isFinite, c.heldSeconds >= 0, c.last.valid,
                  c.start?.valid != false, c.end?.valid != false, c.sleepStart?.valid != false,
                  c.lastSleepEvidence?.valid != false,
                  c.firstLowPowerProtection?.valid != false,
                  c.firstThermalProtection.map({ $0.stamp.valid && ($0.level.map { (0...3).contains($0) } ?? true) }) ?? true,
                  Set(c.tasks.map(\.id)).count == c.tasks.count,
                  c.tasks.allSatisfy({ Self.validTask(TaskInput(id:$0.id,source:$0.source,kind:$0.kind,state:$0.state,started:true)) && $0.changedAt.isFinite && $0.ordinal > 0 && ($0.chat?.valid != false) }),
                  c.timeline.allSatisfy({ $0.wall.isFinite && $0.continuous.isFinite && $0.title.utf8.count < 256 }),
                  c.issues.count <= 16, c.issues.allSatisfy({ $0.utf8.count < 256 }) else { return false }
        }
        return true
    }
    static func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds, 315_360_000)), minutes = total / 60, rest = total % 60
        if minutes >= 60 { return "\(minutes / 60)小时\(minutes % 60)分" }
        return rest == 0 ? "\(minutes)分" : "\(minutes)分\(rest)秒"
    }
}
