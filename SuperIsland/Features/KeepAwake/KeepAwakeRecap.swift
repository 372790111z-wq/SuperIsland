import Foundation

/// Read-only projection. This type has no power, task-control, IPC or UI calls.
struct KeepAwakeRecap: Codable, Equatable {
    enum Kind: String, Codable { case user, background, unclassified }
    enum State: String, Codable, CaseIterable { case running, waiting, unknown, completed, failed, cancelled
        var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
        var title: String { switch self { case .running: return "运行中"; case .waiting: return "等待确认"; case .unknown: return "状态未知"; case .completed: return "已完成"; case .failed: return "失败"; case .cancelled: return "已取消" } }
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
    }
    struct TaskInput: Equatable { var id: String; var source: String; var kind: Kind; var state: State; var started: Bool }
    struct Frame: Equatable {
        var stamp: Stamp; var notebook: Bool; var closed: Bool?; var enabled: Bool
        var actualHold: Bool; var lidRequired: Bool; var lidApplied: Bool
        var released: Bool; var protection: Bool; var error: Bool; var automatic: Bool
        var tasks: [TaskInput]; var completeTasks = true; var paused = false
    }
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID(); var wall: Double; var continuous: Double; var title: String
    }
    struct Cycle: Codable, Equatable, Identifiable {
        var id = UUID(); var start: Stamp?; var end: Stamp?; var last: Stamp
        var heldSeconds: Double = 0; var holding = false; var hadHold = false
        var holdComplete = true; var boundaryComplete = true; var interrupted = false
        var tasks: [Task] = []; var issues = Set<String>(); var timeline: [Entry] = []
        var power: Power = .notHeld; var releasedAt: Double?
        var releaseReason: ReleaseReason = .unknown
        var sleepStart: Stamp?; var sleepAt: Double?; var sleepCount = 0; var sleepRequested = false
        var autoEligible: Bool; var shown = false
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
        advance(frame.stamp)
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
                    if input.state.terminal { append("任务 " + String(current!.tasks[i].ordinal) + " · " + input.state.title, at: frame.stamp) }
                }
                // Classification is evidence supplied by an adapter, never inferred from text.
                if current!.tasks[i].kind == .unclassified && input.kind != .unclassified { current!.tasks[i].kind = input.kind }
            } else if input.started && !input.state.terminal {
                guard current!.tasks.count < Self.taskLimit else { current!.issues.insert("任务容量已达上限，统计不完整"); continue }
                current!.tasks.append(Task(id: input.id, source: input.source, kind: input.kind, state: input.state,
                    ordinal: current!.tasks.count + 1, changedAt: frame.stamp.wall))
                taskIndices[input.id] = current!.tasks.count - 1
            }
        }
        if frame.completeTasks {
            let present = Set(frame.tasks.map(\.id))
            for i in current!.tasks.indices where !current!.tasks[i].state.terminal && !present.contains(current!.tasks[i].id) {
                current!.tasks[i].state = .unknown
            }
        }
        if frame.actualHold {
            current!.hadHold = true
            if frame.lidRequired && !frame.lidApplied { current!.holdComplete = false; current!.issues.insert("部分合盖保持时段未确认") }
        }
        current!.holding = frame.actualHold
        let previousPower = current!.power
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
    private mutating func advance(_ stamp: Stamp) {
        guard let previous = current?.last else { return }
        let elapsed = stamp.continuous - previous.continuous
        let suspended = elapsed - (stamp.awake - previous.awake)
        guard elapsed >= 0, stamp.awake >= previous.awake else {
            current!.holdComplete = false; current!.boundaryComplete = false
            current!.issues.insert("时钟记录不连续"); current!.last = stamp; return
        }
        if elapsed > 10 && (suspended < 1 || current!.sleepStart == nil) {
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
        if elapsed >= 0, awake >= 0, elapsed - awake > 1 {
            value!.sleepAt = value!.sleepAt ?? start.wall; value!.sleepCount += 1
            if value!.timeline.count < Self.timelineLimit { value!.timeline.append(Entry(wall: start.wall, continuous: start.continuous, title: "已确认系统实际休眠")) }
        }
        value!.sleepStart = nil; value!.holding = false; value!.last = stamp
        if latestCycle { latest = value } else { current = value }
    }
    mutating func sleepRequestAccepted(_ stamp: Stamp) {
        guard current != nil, stamp.valid else { return }
        current!.sleepRequested = true; append("系统已受理休眠请求（结果待确认）", at: stamp)
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
                  Set(c.tasks.map(\.id)).count == c.tasks.count,
                  c.tasks.allSatisfy({ Self.validTask(TaskInput(id:$0.id,source:$0.source,kind:$0.kind,state:$0.state,started:true)) && $0.changedAt.isFinite && $0.ordinal > 0 }),
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
