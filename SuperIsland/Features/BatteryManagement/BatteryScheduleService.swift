import Foundation
import Combine

enum BatteryScheduleRepeat: String, Codable, CaseIterable, Identifiable {
    case once, daily, weekly, fortnightly, monthly, yearly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: return "一次"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .fortnightly: return "每两周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }
}
enum BatteryScheduledAction: String, Codable, CaseIterable, Identifiable {
    case topUp, pause, discharge, limit, automatic, calibrate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topUp: return "充满"
        case .pause: return "暂停充电"
        case .discharge: return "放电"
        case .limit: return "设置上限"
        case .automatic: return "恢复自动"
        case .calibrate: return "校准"
        }
    }
}

struct BatteryScheduledTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "充电任务"
    var action = BatteryScheduledAction.topUp
    var target = 80
    var anchor = Date().addingTimeInterval(3600)
    var timeZoneID = "Asia/Shanghai"
    var repetition = BatteryScheduleRepeat.once
    var enabled = true
    var catchUp = false
    var nextDue: Date?

    /// Use the original local day for each recurrence. Jan 31 -> Feb's last
    /// day -> Mar 31, rather than drifting permanently to the 28th.
    func next(after date: Date) -> Date? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        if anchor > date { return anchor }
        if repetition == .once { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let source = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: anchor)
        let unit: Calendar.Component
        let step: Int
        switch repetition {
        case .once: return nil
        case .daily: unit = .day; step = 1
        case .weekly: unit = .day; step = 7
        case .fortnightly: unit = .day; step = 14
        case .monthly: unit = .month; step = 1
        case .yearly: unit = .year; step = 1
        }
        let distance = max(0, calendar.dateComponents([unit], from: anchor, to: date).value(for: unit) ?? 0)
        let first = max(1, distance / step)
        for i in first...(first + 3) {
            guard let advanced = calendar.date(byAdding: unit, value: i * step, to: anchor) else { continue }
            var c = calendar.dateComponents([.year, .month, .day], from: advanced)
            c.hour = source.hour; c.minute = source.minute; c.second = 0
            if repetition == .monthly || repetition == .yearly {
                if repetition == .yearly { c.month = source.month }
                c.day = 1
                guard let start = calendar.date(from: c), let days = calendar.range(of: .day, in: .month, for: start) else { continue }
                c.day = min(source.day ?? 1, days.count)
            }
            // Calendar resolves missing DST times forward and chooses the first
            // repeated local time; each occurrence has one absolute fire date.
            guard let day = calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)),
                  let occurrence = calendar.nextDate(after: day.addingTimeInterval(-1), matching: DateComponents(hour: c.hour, minute: c.minute, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first), occurrence > date else { continue }
            return occurrence
        }
        return nil
    }
    func latestDue(at now: Date) -> Date? {
        guard var candidate = nextDue, candidate <= now else { return nil }
        if repetition == .once { return candidate }
        if let recent = next(after: max(candidate, now.addingTimeInterval(-86_400)).addingTimeInterval(-0.001)), recent <= now {
            candidate = recent
            for _ in 0..<2 {
                guard let following = next(after: candidate), following <= now else { break }
                candidate = following
            }
        }
        return candidate
    }
}

struct BatteryScheduleRun: Codable, Identifiable, Equatable {
    var id: String
    var taskID: UUID
    var name: String
    var due: Date
    var timestamp: Date
    var status: String
    var detail: String
    var verification: BatteryScheduleVerification?
}

struct BatteryScheduleVerification: Codable, Equatable {
    var action: BatteryScheduledAction
    var target: Int
    var operationID: UUID
    var calibrationID: UUID?
    var observedFull = false
}

struct BatteryScheduleObservation {
    var operationID: UUID
    var preferences: BatteryControlPreferences
    var telemetry: BatteryTelemetry
    var report: BatteryControlReport
    var enabled: Bool
}

@MainActor
final class BatteryScheduleService: ObservableObject {
    static let shared = BatteryScheduleService()
    @Published private(set) var tasks: [BatteryScheduledTask]
    @Published private(set) var runs: [BatteryScheduleRun]
    @Published private(set) var configurationError: String?
    private let defaults: UserDefaults
    private let nowProvider: () -> Date
    private let execution: @MainActor (BatteryScheduledTask) async throws -> String
    private let observation: (@MainActor () -> BatteryScheduleObservation)?
    private var token: ModuleRefreshToken?
    private var executing = false

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         execution: (@MainActor (BatteryScheduledTask) async throws -> String)? = nil,
         observation: (@MainActor () -> BatteryScheduleObservation)? = nil) {
        self.defaults = defaults
        self.nowProvider = now
        self.execution = execution ?? Self.execute
        if let observation { self.observation = observation }
        else if execution == nil { self.observation = { BatteryManagementService.shared.scheduleObservation } }
        else { self.observation = nil }
        let stored = defaults.data(forKey: "batteryManagement.scheduleStore").flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        tasks = stored?.tasks ?? []
        runs = stored?.runs ?? []
        // A process killed after claiming a run cannot know whether hardware
        // accepted it. Preserve that uncertainty and never replay it silently.
        for i in runs.indices where runs[i].status == "请求中" || runs[i].verification != nil {
            runs[i].status = "结果未确认"; runs[i].detail = "上次运行中断；没有自动重放该实例"
            runs[i].verification = nil
        }
    }
    func start() {
        guard token == nil else { return }
        token = ModuleRefreshScheduler.shared.register(id: "battery.management.schedules", name: "Battery scheduled tasks", module: nil, policy: .interval(60, tolerance: 5), enabled: { true }) { [weak self] in self?.evaluate() }
        evaluate()
    }
    func save(_ task: BatteryScheduledTask) throws {
        configurationError = nil
        guard !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.name.count <= 80, task.anchor.timeIntervalSince1970.isFinite,
              TimeZone(identifier: task.timeZoneID) != nil,
              (20...100).contains(task.target), task.action != .discharge || task.target < 100 else {
            throw BatteryControlError.invalid("请检查任务名称、时区和目标；放电目标为20–99%，上限为20–100%。")
        }
        if task.enabled { try validateTaskCapability(task) }
        guard tasks.count < 100 || tasks.contains(where: { $0.id == task.id }) else { throw BatteryControlError.invalid("最多保存100项电池任务。") }
        var saved = task
        let now = nowProvider()
        saved.nextDue = task.anchor > now ? task.anchor : task.next(after: now)
        if task.enabled, task.repetition == .once, saved.nextDue == nil { throw BatteryControlError.invalid("一次任务请选择未来时间。") }
        let originalTasks = tasks
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = saved } else { tasks.append(saved) }
        guard persist() else {
            tasks = originalTasks
            throw BatteryControlError.unavailable("无法保存任务，没有修改原有任务。")
        }
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        do {
            if enabled {
                var task = tasks[i]; task.enabled = true
                try save(task)
            } else {
                // Disabling a legacy task must remain possible even when its
                // old capability, timezone or one-shot date is now invalid.
                let original = tasks
                tasks[i].enabled = false
                guard persist() else {
                    tasks = original
                    throw BatteryControlError.unavailable("无法保存停用状态，原任务保持不变。")
                }
            }
            configurationError = nil
        } catch { configurationError = error.localizedDescription }
    }
    func delete(_ id: UUID) {
        let original = tasks
        tasks.removeAll { $0.id == id }
        if persist() { configurationError = nil }
        else {
            tasks = original
            configurationError = "删除任务未确认保存，已保留界面中的原任务；请重试。"
        }
    }
    func clearHistory() {
        let original = runs
        runs.removeAll()
        if persist() { configurationError = nil }
        else {
            runs = original
            configurationError = "清空历史未确认保存，已保留界面中的原记录；请重试。"
        }
    }

    @discardableResult func evaluate(now: Date? = nil) -> Task<Void, Never>? {
        let now = now ?? nowProvider()
        verifyPending(now: now)
        guard !executing else { return nil }
        let due = tasks.filter { $0.enabled && ($0.nextDue.map { $0 <= now } ?? false) }
        guard !due.isEmpty else { return nil }
        executing = true
        return Task {
            defer { executing = false }
            for task in due {
                // Earlier requests may suspend while the user edits, disables
                // or deletes a later task. Only dispatch the still-current
                // occurrence; never advance or execute an outdated snapshot.
                guard !Task.isCancelled else { break }
                guard let current = tasks.first(where: { $0.id == task.id }),
                      current.enabled, current == task else { continue }
                let dispatchTime = max(now, nowProvider())
                guard let fire = task.catchUp ? task.latestDue(at: dispatchTime) : task.nextDue else { continue }
                let id = task.id.uuidString + ":" + String(fire.timeIntervalSince1970)
                guard !runs.contains(where: { $0.id == id }) else { advance(task, after: dispatchTime); continue }
                var run = BatteryScheduleRun(id: id, taskID: task.id, name: task.name, due: fire, timestamp: dispatchTime, status: "请求中", detail: "控制尚未确认")
                let late = dispatchTime.timeIntervalSince(fire)
                if late > 90 && (!task.catchUp || late > 86_400) {
                    run.status = "已跳过"; run.detail = "错过计划时间；未开启24小时内补做或已超期"
                }
                runs.insert(run, at: 0); advance(task, after: dispatchTime)
                guard persist() else { updateRun(id, status: "未执行", detail: "无法保存执行实例；没有提交硬件请求"); continue }
                guard run.status == "请求中" else { continue }
                do { _ = try await submit(task, runID: id) }
                catch { recordFailure(id, error: error) }
            }
        }
    }
    func runNow(_ task: BatteryScheduledTask) async throws -> String {
        guard !executing else { throw BatteryControlError.conflict("已有任务正在提交，请稍后运行。") }
        guard (20...100).contains(task.target), task.action != .discharge || task.target < 100 else {
            throw BatteryControlError.invalid("放电目标需为20–99%，上限需为20–100%。")
        }
        executing = true
        defer { executing = false }
        let now = nowProvider(), id = "manual:" + UUID().uuidString
        runs.insert(.init(id: id, taskID: task.id, name: task.name, due: now, timestamp: now,
                          status: "请求中", detail: "手动运行；控制尚未确认"), at: 0)
        guard persist() else {
            updateRun(id, status: "未执行", detail: "无法保存执行实例；没有提交硬件请求")
            throw BatteryControlError.unavailable("无法保存执行记录，未运行任务。")
        }
        do { return try await submit(task, runID: id) }
        catch { recordFailure(id, error: error); throw error }
    }

    private func validateTaskCapability(_ task: BatteryScheduledTask) throws {
        guard let state = observation?() else { return }
        if let warning = BatteryPreferenceCompatibility.taskWarning(task, report: state.report, preferences: state.preferences) {
            throw BatteryControlError.unavailable(warning)
        }
    }
    private func submit(_ task: BatteryScheduledTask, runID: String) async throws -> String {
        do { try validateTaskCapability(task) }
        catch {
            updateRun(runID, status: "未执行", detail: error.localizedDescription)
            throw error
        }
        if task.action == .discharge, let state = observation?(), state.report.completionReceiptsSupported != true {
            let detail = "当前辅助程序不能回报放电结束原因；需更新辅助程序。未提交本次放电任务。"
            updateRun(runID, status: "未执行", detail: detail)
            return detail
        }
        let detail = try await execution(task)
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return detail + "；执行历史已清除，实际结果待确认" }
        runs[index].status = "已提交"; runs[index].detail = detail + "；实际结果待回读"
        if let state = observation?() {
            runs[index].verification = .init(action: task.action, target: task.target,
                operationID: state.operationID, calibrationID: state.report.calibration?.id)
        }
        persist()
        verifyPending(now: nowProvider())
        if let result = runs.first(where: { $0.id == runID }) { return result.status + "；" + result.detail }
        return detail + "；实际结果待回读"
    }

    private func recordFailure(_ id: String, error: Error) {
        if runs.first(where: { $0.id == id })?.status == "未执行" { return }
        if case BatteryControlError.conflict = error {
            updateRun(id, status: "待确认", detail: error.localizedDescription + "；未自动停止已有控制")
        } else {
            updateRun(id, status: "结果未确认", detail: error.localizedDescription)
        }
    }

    /// Reconcile accepted requests with current controller and sensor facts.
    /// A request receipt alone never becomes a completed charge/discharge.
    func verifyPending(now: Date? = nil) {
        guard runs.contains(where: { $0.verification != nil }), let state = observation?() else { return }
        let now = now ?? nowProvider()
        var changed = false
        for index in runs.indices {
            guard var proof = runs[index].verification else { continue }
            func finish(_ status: String, _ detail: String) {
                runs[index].status = status; runs[index].detail = detail
                runs[index].verification = nil; changed = true
            }
            guard state.report.timestamp >= runs[index].timestamp,
                  now.timeIntervalSince(state.report.timestamp) <= 60,
                  state.report.timestamp.timeIntervalSince(now) <= 5 else { continue }
            if state.report.recoveryPending {
                runs[index].status = "恢复中"; runs[index].detail = state.report.message; changed = true; continue
            }
            if !state.enabled || !state.report.available {
                finish("已中止", state.report.message); continue
            }
            if proof.action == .calibrate {
                guard let calibration = state.report.calibration, calibration.id == proof.calibrationID else {
                    finish("结果未确认", "原校准会话已不可追踪；未记录完成"); continue
                }
                if calibration.state == .completed { finish("已完成", calibration.title) }
                else if calibration.state == .interrupted { finish("已中止", calibration.title) }
                continue
            }
            guard proof.operationID == state.operationID else {
                finish("已中止", "已被新的控制操作替代；未记录目标完成"); continue
            }
            let freshTelemetry = state.telemetry.hasBattery && state.telemetry.timestamp >= runs[index].timestamp
                && now.timeIntervalSince(state.telemetry.timestamp) <= 60 && state.telemetry.timestamp.timeIntervalSince(now) <= 5
            let registered = state.report.registeredTarget
            switch proof.action {
            case .limit:
                if state.preferences.limit != proof.target { finish("已中止", "长期上限已被更改") }
                else if registered == proof.target && (!state.report.usesNativeLimit || state.report.nativeSavedLimit == proof.target) {
                    finish("已应用", "长期上限\(proof.target)%已由辅助程序读回；不代表当前电量已达到目标")
                }
            case .automatic:
                if state.report.mode == .automatic && state.report.ownedAdapterCutoff != true && state.report.cutoffPhase == nil {
                    finish("已应用", "辅助程序已确认自动模式；实际充放电以当前读数为准")
                }
            case .pause:
                if freshTelemetry, state.report.mode == .paused, state.telemetry.adapterConnectionObservation == true,
                   state.telemetry.chargingObservation == false, let current = state.telemetry.current,
                   current.isFinite, current <= 0 {
                    finish("已应用", "已观察到暂停模式且电池无充电流入；长期上限保持不变")
                } else if state.report.mode != .paused { finish("已中止", "暂停模式已结束") }
            case .discharge:
                if state.report.completedOperationID == proof.operationID, state.report.completionReason == .powerDisconnected {
                    finish("已中止", "辅助程序已确认电源断开，未将自然掉电记为到达放电目标")
                } else if freshTelemetry, let level = state.telemetry.level, level <= proof.target,
                   state.report.completedOperationID == proof.operationID, state.report.completionReason == .targetReached,
                   state.report.mode == .automatic, state.report.ownedAdapterCutoff != true, state.report.cutoffPhase == nil,
                   state.telemetry.onAC {
                    if state.report.dischargeMechanism == .nativeLimit {
                        if state.telemetry.chargingObservation == false, let current = state.telemetry.current,
                           current.isFinite, abs(current) <= 0.05 {
                            finish("已完成", "已观察到电量\(level)%达到目标\(proof.target)%，原生目标操作已结束，当前电池读数已停止放电")
                        } else {
                            let waiting = "已到放电目标，等待实际电流确认停止放电；尚未记录完成"
                            if runs[index].detail != waiting { runs[index].detail = waiting; changed = true }
                        }
                    } else {
                        finish("已完成", "已观察到电量\(level)%达到目标\(proof.target)%，辅助程序已确认目标结束、释放断供并恢复适配器供电")
                    }
                } else if state.report.mode != .discharge && state.report.mode != .automatic {
                    finish("已中止", "放电已被其他模式替代")
                } else if freshTelemetry && state.telemetry.adapterConnectionObservation == false && state.report.ownedAdapterCutoff != true {
                    finish("已中止", "电源已断开；未记录目标完成")
                }
            case .topUp:
                if freshTelemetry && state.telemetry.level == 100 && !proof.observedFull {
                    proof.observedFull = true; runs[index].verification = proof
                    runs[index].status = "保持满电"; runs[index].detail = "已观察到系统电量100%；等待拔电后结束临时充满"; changed = true
                }
                if freshTelemetry && state.telemetry.adapterConnectionObservation == false && state.report.mode == .automatic {
                    if state.report.completedOperationID == proof.operationID && state.report.completionReason == .powerDisconnected {
                        finish(proof.observedFull ? "已完成" : "已中止", proof.observedFull ? "已观察满电并断开电源，临时充满已结束" : "满电前已断开电源")
                    } else { finish("结果未确认", "当前未接电，但缺少本次充满的结束回执；未记录完成") }
                } else if state.report.mode != .topUp {
                    if state.telemetry.adapterConnectionObservation == nil {
                        let waiting = "供电读数未知；等待确认临时充满的结束原因"
                        if runs[index].detail != waiting || runs[index].status != "待确认" {
                            runs[index].status = "待确认"; runs[index].detail = waiting; changed = true
                        }
                    } else { finish("已中止", "临时充满已被其他模式替代") }
                }
            case .calibrate: break
            }
        }
        if changed { persist() }
    }
    private static func execute(_ task: BatteryScheduledTask) async throws -> String {
        let service = BatteryManagementService.shared
        switch task.action {
        case .topUp: return try await service.execute(mode: .topUp)
        case .pause: return try await service.execute(mode: .paused)
        case .discharge: return try await service.execute(mode: .discharge, target: task.target)
        case .limit: return try await service.setLimitFromAutomation(task.target)
        case .automatic: return try await service.execute(mode: .automatic)
        case .calibrate: return try await service.startCalibration()
        }
    }
    private func advance(_ task: BatteryScheduledTask, after date: Date) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i].nextDue = task.next(after: date)
            if tasks[i].nextDue == nil { tasks[i].enabled = false }
        }
    }
    private func updateRun(_ id: String, status: String, detail: String) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].status = status; runs[i].detail = detail; persist()
    }
    @discardableResult private func persist() -> Bool {
        runs = Array(runs.prefix(200))
        // Claim, next occurrence and history are one persisted envelope, so a
        // crash cannot resurrect a claimed occurrence from a separate key.
        guard let encoded = try? JSONEncoder().encode(Stored(tasks: tasks, runs: runs)) else { return false }
        let previous = defaults.data(forKey: "batteryManagement.scheduleStore")
        defaults.set(encoded, forKey: "batteryManagement.scheduleStore")
        guard defaults.synchronize() else {
            // A failed flush does not prove that disk stayed unchanged. Restore
            // the cached envelope too, so later writes cannot silently persist
            // an operation that the interface has reported as unconfirmed.
            if let previous { defaults.set(previous, forKey: "batteryManagement.scheduleStore") }
            else { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
            _ = defaults.synchronize()
            return false
        }
        return true
    }
    private struct Stored: Codable { var tasks: [BatteryScheduledTask]; var runs: [BatteryScheduleRun] }
}
