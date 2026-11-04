import Foundation

enum BatteryControlMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, discharge, topUp, paused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .discharge: return "放电"
        case .topUp: return "充满"
        case .paused: return "暂停"
        }
    }
}

enum BatterySleepPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case unchanged, pause, untilLimit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unchanged: return "照原样继续"
        case .pause: return "睡眠时暂停充电"
        case .untilLimit: return "上限前保持唤醒"
        }
    }
}

enum BatteryEnergyScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case never, always, battery, adapter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: return "从不"
        case .always: return "始终"
        case .battery: return "仅电池"
        case .adapter: return "仅适配器"
        }
    }
    func applies(onAC: Bool) -> Bool {
        self == .always || (self == .adapter && onAC) || (self == .battery && !onAC)
    }
}

enum BatteryLED: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, green, orange, off, atLimit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .green: return "绿色"
        case .orange: return "橙色"
        case .off: return "关闭"
        case .atLimit: return "达到上限时绿色"
        }
    }
    // AlDente 1.39.4's packaged enum and arm64 handler 0x10008c200
    // agree on green=2, orange=4 and Off(index4)=1. These mappings do
    // not themselves establish physical lamp behavior on another device.
    func controlValue(reachedLimit: Bool) -> Int? {
        switch self {
        case .system: return nil
        case .green: return 2
        case .orange: return 4
        case .off: return 1
        case .atLimit: return reachedLimit ? 2 : 4
        }
    }
}

struct BatteryControlPreferences: Codable, Equatable {
    var limit = 80
    var allowLowLimit = false
    var automaticDischarge = false
    var sailing = false
    var sailingLower = 70
    var heatProtection = false
    // A configurable SuperIsland safety policy, not an inferred AlDente default.
    var maximumTemperature = 35.0
    var sleep = BatterySleepPolicy.unchanged
    var lowPower = BatteryEnergyScope.never
    // Optional preserves preferences written before high-power support.
    var highPower: BatteryEnergyScope?
    var highPowerScope: BatteryEnergyScope {
        get { highPower ?? .never }
        set { highPower = newValue == .never ? nil : newValue }
    }
    var led = BatteryLED.system
    var blinkWhileDischarging = false

    func validate() throws {
        guard (20...100).contains(limit), allowLowLimit || limit >= 80 else {
            throw BatteryControlError.invalid("上限需为80–100%；低值需先开启允许低于80%。")
        }
        guard !sailing || ((20..<limit).contains(sailingLower)) else {
            throw BatteryControlError.invalid("航海下限必须不低于20%，且小于充电上限。")
        }
        guard maximumTemperature.isFinite, (25...50).contains(maximumTemperature) else {
            throw BatteryControlError.invalid("温度阈值需为25–50°C。")
        }
        guard ![false, true].contains(where: { lowPower.applies(onAC: $0) && highPowerScope.applies(onAC: $0) }) else {
            throw BatteryControlError.invalid("同一电源范围不能同时使用低功耗和高功率模式，请先调整其中一项。")
        }
    }
}

struct BatteryControlRequest: Codable, Equatable {
    var owner: UUID
    var preferences: BatteryControlPreferences
    var mode: BatteryControlMode = .automatic
    var dischargeTarget: Int?
    var sleeping = false
    var calibration: BatteryCalibrationCommand?
    // Stable across renewals, new for each explicit mode action. Without this,
    // a late heartbeat and a deliberate repeat of the same target are identical.
    var operationID = UUID()
    var controlEpoch: UUID?
    var acknowledgedFaultID: UUID?
    var withoutFaultAcknowledgment: Self {
        var value = self; value.acknowledgedFaultID = nil; return value
    }

    func validateEpoch(_ expected: UUID?) throws {
        guard let expected, controlEpoch == expected else {
            throw BatteryControlError.recovery("辅助程序运行实例已变化，旧控制请求已拒绝；请重新读取状态。")
        }
    }
    func validate() throws {
        try preferences.validate()
        guard calibration == nil || mode == .automatic else { throw BatteryControlError.invalid("校准命令不能与临时充电模式混用。") }
        if mode == .discharge {
            guard let dischargeTarget, (20...99).contains(dischargeTarget) else {
                throw BatteryControlError.invalid("放电目标需为20–99%。")
            }
        }
    }
}

/// An automatic completion can precede the client's next heartbeat. Fold only
/// that exact completed operation into its successor; never replay its cutoff
/// or absorb a deliberate new action. Kept in memory only: restart restores.
#if BATTERY_HELPER || DEBUG
struct BatteryCompletedRequest {
    let original: BatteryControlRequest
    let automatic: BatteryControlRequest

    init(_ request: BatteryControlRequest) {
        original = request
        var next = request; next.mode = .automatic; next.dischargeTarget = nil
        automatic = next
    }

    func normalize(_ request: BatteryControlRequest) -> BatteryControlRequest {
        request == original ? automatic : request
    }
}

#endif

enum BatteryControlError: LocalizedError {
    case invalid(String), unavailable(String), conflict(String), recovery(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .conflict(let s), .recovery(let s): return s
        }
    }
}

#if BATTERY_HELPER || DEBUG
struct BatteryControlDecision: Equatable {
    var target: Int
    var inhibit = false
    var forceDischarge = false
    var reason: String
    var completed = false
    var nativeHoldTarget: Int?
    var protectiveHold = false
    var completionReason: BatteryOperationCompletionReason?
    func nativeTarget(currentLevel: Int) -> Int {
        // Adapter-cutoff planning historically neutralizes MCL before cutoff.
        // The native-only planner instead uses the logical discharge target
        // directly and never uses this forceDischarge neutralization branch.
        if forceDischarge { return 100 }
        return inhibit ? max(20, nativeHoldTarget ?? currentLevel) : target
    }
}

/// Pure policy. It never substitutes a user target for the measured battery level.
struct BatteryControlPolicy {
    private(set) var sailingWaiting = false
    private(set) var thermalHold = false
    private var nextThermalEvaluation: TimeInterval?
    private var automaticCeiling: Int?
    private var pauseCeiling: Int?
    private var protectiveCeiling: Int?

    mutating func resumeAfterCalibration(limit: Int) {
        automaticCeiling = limit; pauseCeiling = nil; protectiveCeiling = nil
        sailingWaiting = false; thermalHold = false; nextThermalEvaluation = nil
    }

    mutating func configure(previous: BatteryControlRequest?, next: BatteryControlRequest) {
        guard let previous else { return }
        let old = previous.preferences, new = next.preferences
        if previous.mode != next.mode || old.limit != new.limit || old.sailing != new.sailing || old.sailingLower != new.sailingLower || old.automaticDischarge != new.automaticDischarge {
            automaticCeiling = nil; sailingWaiting = false
        }
        if previous.mode != next.mode { pauseCeiling = nil }
        if old.heatProtection != new.heatProtection || old.maximumTemperature != new.maximumTemperature {
            thermalHold = false; nextThermalEvaluation = nil; protectiveCeiling = nil
        }
    }

    mutating func decide(request: BatteryControlRequest, snapshot: BatteryTelemetry, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                         ownsAdapterCutoff: Bool = false) throws -> BatteryControlDecision {
        try request.validate()
        guard let level = snapshot.level, snapshot.hasBattery, (0...100).contains(level) else {
            throw BatteryControlError.unavailable("没有可确认的内置电池读数。")
        }
        if !snapshot.adapterPresent && !ownsAdapterCutoff && snapshot.powerSupplyObservation == nil {
            throw BatteryControlError.unavailable("供电状态未知，未将未知读数当成拔电完成。")
        }
        guard snapshot.adapterPresent || ownsAdapterCutoff else {
            sailingWaiting = false; thermalHold = false
            nextThermalEvaluation = nil
            automaticCeiling = nil; pauseCeiling = nil; protectiveCeiling = nil
            return .init(target: request.preferences.limit, reason: "电池供电；等待接入适配器", completed: request.mode != .automatic,
                         completionReason: request.mode != .automatic ? .powerDisconnected : nil)
        }
        let p = request.preferences
        if p.heatProtection {
            guard let temperature = snapshot.temperature else {
                // A missing sensor cannot authorize resuming charging.
                thermalHold = true
                nextThermalEvaluation = now + 300
                protectiveCeiling = min(protectiveCeiling ?? level, level)
                return .init(target: level, inhibit: true, reason: "温度读数不可用；充电保护暂停", nativeHoldTarget: protectiveCeiling, protectiveHold: true)
            }
            if nextThermalEvaluation.map({ now >= $0 }) ?? true {
                if temperature >= p.maximumTemperature { thermalHold = true; nextThermalEvaluation = now + 300 }
                else if thermalHold { thermalHold = false; nextThermalEvaluation = now + 300 }
                else { nextThermalEvaluation = nil }
            }
        } else { thermalHold = false; nextThermalEvaluation = nil }
        if thermalHold {
            protectiveCeiling = min(protectiveCeiling ?? level, level)
            return .init(target: level, inhibit: true, reason: "过热保护；等待降温", nativeHoldTarget: protectiveCeiling, protectiveHold: true)
        }
        if request.sleeping && p.sleep == .pause {
            protectiveCeiling = min(protectiveCeiling ?? level, level)
            return .init(target: level, inhibit: true, reason: "睡眠期间暂停充电", nativeHoldTarget: protectiveCeiling, protectiveHold: true)
        }
        protectiveCeiling = nil
        switch request.mode {
        case .paused:
            guard level >= 20 else { throw BatteryControlError.unavailable("当前电量低于20%，不允许临时暂停充电。") }
            sailingWaiting = false
            pauseCeiling = min(pauseCeiling ?? level, level)
            return .init(target: pauseCeiling!, inhibit: true, reason: "临时暂停目标\(pauseCeiling!)%；长期上限仍为\(p.limit)%", nativeHoldTarget: pauseCeiling)
        case .topUp:
            sailingWaiting = false
            return .init(target: 100, reason: level >= 100 ? "已充满；保持至断开电源" : "临时充至100%")
        case .discharge:
            sailingWaiting = false
            let target = request.dischargeTarget!
            if level <= target { return .init(target: p.limit, reason: "已到放电目标；恢复自动", completed: true, completionReason: .targetReached) }
            return .init(target: target, inhibit: true, forceDischarge: level > 20, reason: "放电至\(target)%")
        case .automatic:
            // An already-high battery can be held without requesting a drain.
            // Once we have charged from below the goal, however, a delayed
            // gauge update must never ratchet the native target upward.
            if automaticCeiling == nil { automaticCeiling = max(p.limit, level) }
            if level < p.limit || p.automaticDischarge { automaticCeiling = p.limit }
            if level >= p.limit { automaticCeiling = min(automaticCeiling ?? level, level) }
            if p.sailing {
                if level >= p.limit { sailingWaiting = true }
                if level <= p.sailingLower || level < 20 { sailingWaiting = false }
            } else { sailingWaiting = false }
            if sailingWaiting { automaticCeiling = min(automaticCeiling ?? level, level) }
            let discharge = p.automaticDischarge && level > p.limit && level > 20
            return .init(target: p.limit, inhibit: level >= p.limit || sailingWaiting,
                         forceDischarge: discharge,
                         reason: discharge ? "自动放电至\(p.limit)%" : sailingWaiting ? "航海等待；\(p.sailingLower)%后充电" : level > p.limit ? automaticCeiling == p.limit ? "实际电量超过目标；等待系统收敛至\(p.limit)%" : "当前高于上限\(p.limit)%；未开启自动放电，保持当前电量" : level == p.limit ? "达到上限\(p.limit)%" : "按上限\(p.limit)%充电", nativeHoldTarget: automaticCeiling)
        }
    }
}

#endif

enum BatteryOperationCompletionReason: String, Codable, Equatable {
    case targetReached, powerDisconnected
}

enum BatteryDischargeMechanism: String, Codable, Equatable {
    case nativeLimit, adapterCutoff
}

struct BatteryControlReport: Codable, Equatable {
    // Optional read-only receipts preserve old report decoding. A receipt
    // records why a policy ended; recovery/physical supply remain separate.
    var completedOperationID: UUID?
    var completionReason: BatteryOperationCompletionReason?
    var completionReceiptsSupported: Bool? = true
    static let currentProtocolVersion = 17
    // Optional so older helpers can be decoded and rejected before any renew.
    var protocolVersion: Int? = currentProtocolVersion
    var controlEpoch: UUID? = UUID()
    var nativeCutoffReviewTrial: Bool? = false
    var available = false
    var mechanism = "尚未检测"
    var message = "尚未检测"
    /// First error survives recovery progress. A new accepted retry clears it.
    var lastFailure: String?
    mutating func preserveFailure(stage: String, detail: String) {
        guard lastFailure == nil else { return }
        let clean = detail.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        lastFailure = String(stage.prefix(80)) + "：" + String(String.UnicodeScalarView(clean)).prefix(768)
    }
    var registeredTarget: Int?
    // Saved manual limit from getMCLLimitWithError:, distinct from powerd
    // registration and actual charging. The optimization getter is not MCL.
    var nativeSavedLimit: Int?
    var systemCalibration = false
    var mode = BatteryControlMode.automatic
    var dischargeSupported = false
    var minimumDischargeTarget: Int?
    var dischargeMechanism: BatteryDischargeMechanism?
    var ledSupported = false
    var highPowerSupported: Bool?
    var calibrationSupported: Bool?
    var calibration: BatteryCalibrationStatus?
    var diagnosticOnly: Bool?
    #if BATTERY_REVIEW || DEBUG
    var preferences79Review: Bool?
    // The production app never calls the diagnostic RPC; optional extra JSON
    // fields are ignored there. Helper and diagnostic tools retain all rows.
    var smcDiscovery: BatterySMCDiscovery?
    var nativeReadDiagnostics: [BatteryNativeReadDiagnostic]?
    var smcDirectReadDiagnostics: String?
    var smcDirectReadError: String?
    #endif
    var ownedAdapterCutoff: Bool?
    var cutoffPhase: BatteryCutoffSession.Phase?
    var recoveryPending = false
    var requiresManualRetry: Bool? = false
    var manualRetryID: UUID?
    var exitHoldReady: Bool?
    var leaseHeldByRequester: Bool?
    var timestamp = Date()
    var usesNativeLimit: Bool { mechanism == "macOS Charge Limit" || mechanism == "macOS Preferences Limit" }
    var capabilities: BatteryControlCapabilities { .init(report: self) }
    var minimumSupportedLimit: Int { capabilities.minimumLimit ?? 80 }
}
