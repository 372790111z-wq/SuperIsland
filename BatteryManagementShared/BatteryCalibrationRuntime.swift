import Foundation

enum BatteryCalibrationCommand: Codable, Equatable {
    case start(UUID), cancel(UUID)
}

struct BatteryCalibrationStatus: Codable, Equatable {
    enum State: String, Codable { case active, restoring, completed, interrupted }
    var id: UUID
    var state: State
    var phase: BatteryCalibrationSession.Phase
    var originalLimit: Int
    var startedAt: Date
    var endReason: BatteryCalibrationSession.EndReason?
    var lastCompletedAt: Date?
    var waitingForSystem = false
    var isActive: Bool { state == .active || state == .restoring }
    var title: String {
        if state == .restoring { return "校准：正在恢复原设置" }
        if state == .completed { return "校准完成，原设置已恢复" }
        if state == .interrupted { return "校准已中止，控制变更已恢复" }
        if waitingForSystem { return "校准：等待macOS系统校准结束" }
        switch phase {
        case .firstCharge: return "校准1/5：充至100%"
        case .discharge: return "校准2/5：放电至10%"
        case .secondCharge: return "校准3/5：再次充至100%"
        case .hold: return "校准4/5：确认满电完成"
        case .returnToLimit: return "校准5/5：返回原上限\(originalLimit)%"
        default: return "校准：等待恢复确认"
        }
    }
}

/// One privileged lifecycle for all entry points. Register originals remain in
/// BatteryOverrideLease only; this journal holds intent and lifecycle metadata.
/// Restart deliberately restores/interrupts rather than resuming deep discharge.
#if BATTERY_HELPER || DEBUG
final class BatteryCalibrationRuntime {
    struct Record: Codable, Equatable {
        var schemaVersion = 1
        var owner: UUID
        var preferences: BatteryControlPreferences
        var status: BatteryCalibrationStatus
        var retiredIDs: [UUID] = []
        func validate() throws {
            try preferences.validate()
            guard schemaVersion == 1, preferences.limit == status.originalLimit,
                  status.startedAt.timeIntervalSince1970.isFinite,
                  status.lastCompletedAt?.timeIntervalSince1970.isFinite != false,
                  retiredIDs.count <= 100 else {
                throw BatteryControlError.recovery("校准恢复记录无效，已停止控制并保留记录。")
            }
            let consistent: Bool
            switch status.state {
            case .active: consistent = [.firstCharge, .discharge, .secondCharge, .hold, .returnToLimit].contains(status.phase) && status.endReason == nil
            case .restoring: consistent = status.phase == .restoring && status.endReason != nil
            case .completed: consistent = status.phase == .completed && status.endReason == .cycleFinished && status.lastCompletedAt != nil
            case .interrupted: consistent = status.phase == .interrupted && status.endReason != nil && status.endReason != .cycleFinished
            }
            guard consistent else { throw BatteryControlError.recovery("校准记录阶段与结果不一致，已保留并停止控制。") }
        }
    }
    enum Action {
        case drive(BatteryControlDecision), yieldToSystem, restorePreferences
    }
    private(set) var record: Record?
    private var session: BatteryCalibrationSession?
    private var phaseApplied = false
    private var lastStrictUpdate: Date?
    private var strictPhase: BatteryCalibrationSession.Phase?
    private var strictPhaseStarted: TimeInterval?
    private let save: (Record) throws -> Void
    var isActive: Bool { record?.status.isActive == true }

    init(record: Record? = nil, save: @escaping (Record) throws -> Void) throws {
        try record?.validate()
        self.record = record; self.save = save
    }
    /// Call only after the hardware lease has been successfully recovered.
    func recoveredAfterRestart() throws {
        guard var next = record, next.status.isActive else { return }
        next.status.state = .interrupted; next.status.endReason = .exit
        next.status.phase = .interrupted; next.status.waitingForSystem = false
        try checkpoint(next); session = nil; phaseApplied = false
    }
    func accept(_ command: BatteryCalibrationCommand?, owner: UUID,
                preferences: BatteryControlPreferences, supported: Bool, date: Date) throws {
        guard let command else {
            guard !isActive else { throw BatteryControlError.conflict("校准正在进行，请先停止校准并确认恢复。") }
            return
        }
        if isActive, record?.owner != owner { throw BatteryControlError.conflict("不能操作其他实例的校准。") }
        switch command {
        case .start(let id):
            if record?.retiredIDs.contains(id) == true { throw BatteryControlError.conflict("该校准请求已结束，不能重复启动。") }
            if record?.status.id == id {
                guard record?.owner == owner else { throw BatteryControlError.conflict("校准身份不匹配。") }
                // The same command can be retried after a lost reply, including
                // after completion. It must never start a second deep cycle.
                if isActive, record?.preferences != preferences {
                    throw BatteryControlError.conflict("校准期间不能修改控制偏好，请先停止校准。")
                }
                return
            }
            guard !isActive else { throw BatteryControlError.conflict("已有校准会话，请先停止并恢复。") }
            guard supported else { throw BatteryControlError.unavailable("设备缺少完整校准所需的充电、放电或恢复能力。") }
            try preferences.validate()
            let created = try BatteryCalibrationSession(originalLimit: preferences.limit)
            let retired = record.map { Array(($0.retiredIDs + [$0.status.id]).suffix(100)) } ?? []
            let next = Record(owner: owner, preferences: preferences,
                status: .init(id: id, state: .active, phase: .firstCharge,
                              originalLimit: preferences.limit, startedAt: date,
                              lastCompletedAt: record?.status.lastCompletedAt), retiredIDs: retired)
            try checkpoint(next) // Durable intent before the first override.
            session = created; phaseApplied = false
            lastStrictUpdate = nil; strictPhase = nil; strictPhaseStarted = nil
        case .cancel(let id):
            guard record?.owner == owner, record?.status.id == id else {
                throw BatteryControlError.conflict("取消的校准会话不存在或不属于本实例。")
            }
            if isActive { try interrupt(.cancelled) }
        }
    }
    func interrupt(_ reason: BatteryCalibrationSession.EndReason) throws {
        guard var session, var next = record, isActive else { return }
        session.interrupt(reason)
        next.status.state = .restoring; next.status.phase = .restoring
        next.status.endReason = session.endReason; next.status.waitingForSystem = false
        try checkpoint(next); self.session = session; phaseApplied = false
    }
    /// Normal release/watchdog has restored ALL owned hardware values. This is
    /// always an interrupted run, even if a phase was about to finish.
    func released(reason: BatteryCalibrationSession.EndReason = .permissionLost) throws {
        guard var next = record, isActive else { return }
        next.status.state = .interrupted; next.status.phase = .interrupted
        next.status.endReason = reason; next.status.waitingForSystem = false
        try checkpoint(next); session = nil; phaseApplied = false
    }
    /// apply must persist originals and read back writes. Return true only once
    /// native registration/current target also agree; false means still settling.
    func tick(telemetry: BatteryTelemetry, sleeping: Bool, systemCalibration: Bool,
              now: TimeInterval, date: Date,
              ownsAdapterCutoff: Bool = false, strictTelemetry: Bool = false,
              apply: (Action, BatteryControlPreferences) throws -> Bool) throws {
        guard var session, var next = record, isActive else { return }
        guard telemetry.hasBattery, let level = telemetry.level, (0...100).contains(level) else {
            throw BatteryControlError.unavailable("校准缺少可信电量读数，已停止控制并尝试恢复。")
        }
        var freshStrictSample = true
        if strictTelemetry {
            guard telemetry.chargingObservation != nil, telemetry.powerSupplyObservation != nil,
                  let current = telemetry.current, current.isFinite, let voltage = telemetry.voltage, voltage.isFinite, voltage > 0,
                  let update = telemetry.reportedPower?.batteryUpdateTimeContext,
                  date.timeIntervalSince(update) >= -2, date.timeIntervalSince(update) <= 90 else {
                throw BatteryControlError.unavailable("校准遥测缺失或过期，停止本次校准并恢复。")
            }
            freshStrictSample = lastStrictUpdate.map({ update > $0 }) ?? true
            if freshStrictSample { lastStrictUpdate = update }
            if strictPhase != session.phase { strictPhase = session.phase; strictPhaseStarted = now }
            let maximum: TimeInterval = session.phase == .discharge ? 12 * 3600 : 8 * 3600
            if let started = strictPhaseStarted, !now.isFinite || now < started || now - started >= maximum {
                session.interrupt(.timeout)
            }
        }
        let connectionKnownOrIntentionallyCut = telemetry.adapterPresent || ownsAdapterCutoff
        if !connectionKnownOrIntentionallyCut { session.interrupt(.unplugged) }
        if sleeping { session.interrupt(.protection) }
        if next.preferences.heatProtection,
           telemetry.temperature.map({ !$0.isFinite || $0 >= next.preferences.maximumTemperature }) ?? true {
            session.interrupt(.protection)
        }
        let oldPhase = session.phase
        if (phaseApplied || systemCalibration) && freshStrictSample {
            session.observe(.init(uptime: now, currentPercentage: Float(level), osPercentage: Float(level),
                adapterConnected: connectionKnownOrIntentionallyCut, systemCharging: telemetry.charging,
                voltage: telemetry.voltage.map(Float.init), current: telemetry.current.map(Float.init),
                power: telemetry.power.map(Float.init)), now: now, systemCalibration: systemCalibration,
                maximumSampleGap: strictTelemetry ? 90 : 15)
        }
        // A charge-limit acknowledgement can lag while adapter cutoff already
        // drains the battery. Neither that lag nor the minimum sample cadence
        // may keep cutoff active after the measured10% floor is reached.
        if !systemCalibration, session.phase == .discharge, level <= 10 {
            session.interrupt(.protection)
        }
        if session.phase != oldPhase { phaseApplied = false }
        next.status.phase = session.phase
        next.status.state = session.phase == .restoring ? .restoring : .active
        next.status.endReason = session.endReason
        next.status.waitingForSystem = systemCalibration && next.status.state == .active
        if record != next { try checkpoint(next) }
        self.session = session
        if session.phase == .restoring {
            if try apply(.restorePreferences, next.preferences) {
                session.acknowledgeRestoration(verified: true, now: now)
                next.status.phase = session.phase
                next.status.state = session.phase == .completed ? .completed : .interrupted
                if session.phase == .completed { next.status.lastCompletedAt = date }
                try checkpoint(next); self.session = session
            }
            return
        }
        if systemCalibration {
            _ = try apply(.yieldToSystem, next.preferences)
            phaseApplied = false; return
        }
        let decision: BatteryControlDecision
        switch session.phase {
        case .firstCharge, .secondCharge, .hold:
            decision = .init(target: 100, reason: next.status.title)
        case .discharge:
            // This fixed10% target is available ONLY inside the privileged
            // calibration session. Ordinary discharge validation stays20–99.
            decision = .init(target: 10, inhibit: true, forceDischarge: true, reason: next.status.title)
        case .returnToLimit:
            decision = .init(target: next.preferences.limit, inhibit: level > next.preferences.limit,
                forceDischarge: level > next.preferences.limit, reason: next.status.title)
        default: return
        }
        phaseApplied = try apply(.drive(decision), next.preferences)
    }
    private func checkpoint(_ next: Record) throws {
        try next.validate(); try save(next); record = next
    }
}

#endif
