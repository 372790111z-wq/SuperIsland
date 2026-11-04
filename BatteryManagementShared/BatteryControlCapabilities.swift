import Foundation

/// Operation requirements are independent: a readable discharge key does not
/// prove an immediate charge hold, and a native limit does not prove calibration.
/// This describes only implemented routes, never a physical device guarantee.
struct BatteryControlCapabilities {
    enum Backend: String {
        case nativePreferences = "macOS Preferences Limit"
        case native = "macOS Charge Limit", modern = "SMC CHTE"
        case legacy = "SMC CH0B/CH0C", intel = "Intel BCLM"
    }
    let backend: Backend?
    let reviewTrial: Bool
    let minimumDischargeTarget: Int?
    let led: Bool
    let highPower: Bool
    let calibration: Bool

    init(backend: Backend?, dischargeSupported: Bool, minimumDischargeTarget declared: Int?,
         led: Bool, highPower: Bool, calibration: Bool, reviewTrial: Bool) {
        // A sealed cutoff review only implements the native route. A mixed
        // report must not borrow capabilities from a different implementation.
        let backend = reviewTrial && backend != .native ? nil : backend
        self.backend = backend; self.reviewTrial = reviewTrial
        self.led = led && !reviewTrial; self.highPower = highPower && !reviewTrial
        let floor = backend == .native ? 80 : 20
        // Intersect declarations with the implemented route. Invalid or unknown
        // declarations cannot grant a capability; old reports may omit the floor.
        if let backend, backend != .intel, dischargeSupported,
           declared.map({ (floor...99).contains($0) }) ?? true {
            minimumDischargeTarget = max(floor, declared ?? floor)
        } else { minimumDischargeTarget = nil }
        self.calibration = calibration && !reviewTrial
            && (backend == .modern || backend == .legacy || backend == .nativePreferences) && minimumDischargeTarget == 20
    }
    init(report: BatteryControlReport) {
        self.init(backend: Backend(rawValue: report.mechanism), dischargeSupported: report.dischargeSupported,
            minimumDischargeTarget: report.minimumDischargeTarget, led: report.ledSupported,
            highPower: report.highPowerSupported == true, calibration: report.calibrationSupported == true,
            reviewTrial: report.nativeCutoffReviewTrial == true)
    }
    var minimumLimit: Int? { backend.map { $0 == .native || reviewTrial ? 80 : 20 } }
    var maximumLimit: Int { reviewTrial ? 85 : 100 }
    var minimumPauseLevel: Int? { backend.map { $0 == .native ? 80 : 20 } }
    var immediatePause: Bool { !reviewTrial && (backend == .modern || backend == .legacy) }
    var exitHoldSupported: Bool { !reviewTrial && backend == .nativePreferences }
    var thermalPause: Bool { immediatePause || (!reviewTrial && backend == .nativePreferences) }
    var lowLimits: Bool { minimumLimit.map { $0 < 80 } == true && !reviewTrial }
    func canPause(at level: Int?) -> Bool {
        guard let minimumPauseLevel, let level, (minimumPauseLevel...100).contains(level) else { return false }
        return true
    }
    func canSail(lower: Int, upper: Int) -> Bool {
        guard !reviewTrial, let minimumLimit, let minimumDischargeTarget else { return false }
        return lower >= max(minimumLimit, minimumDischargeTarget) && lower < upper && upper <= maximumLimit
    }

    enum Issue: CaseIterable {
        case highPower, automaticDischarge, sailing, led, blinking
        case limitRange, heat, sleep, lowLimitPermission, lowPower
        var title: String {
            switch self {
            case .highPower: return "高功率模式"
            case .automaticDischarge: return "自动放电"
            case .sailing: return "航海区间"
            case .led: return "MagSafe灯色"
            case .blinking: return "放电闪灯"
            case .limitRange: return "充电上限"
            case .heat: return "即时过热停充"
            case .sleep: return "睡眠策略"
            case .lowLimitPermission: return "低限值许可"
            case .lowPower: return "低功耗模式"
            }
        }
        var message: String {
            switch self {
            case .highPower: return "当前设备没有可确认的高功率控制与恢复能力，未修改偏好。"
            case .automaticDischarge: return "当前设备无法确认主动放电能力，未开启自动放电。"
            case .sailing: return "当前设备无法确认完整航海区间的放电与保持能力，未开启航海模式。"
            case .led: return "没有可确认的MagSafe LED控制能力，未更改灯色。"
            case .blinking: return "当前设备无法确认放电闪烁能力，未开启。"
            case .limitRange: return "当前控制通道不支持所选充电上限；原值保持不变。"
            case .heat, .sleep: return "当前控制通道不能确认即时停充，热保护和睡眠停充暂不可用。"
            case .lowLimitPermission, .lowPower: return "本验证包未开放该充电规则。"
            }
        }
    }

    func issues(_ p: BatteryControlPreferences) -> [Issue] {
        var result: [Issue] = []
        if p.highPowerScope != .never && !highPower { result.append(.highPower) }
        if p.automaticDischarge && (reviewTrial || minimumDischargeTarget.map({ p.limit < $0 }) ?? true) { result.append(.automaticDischarge) }
        if p.sailing && !canSail(lower: p.sailingLower, upper: p.limit) { result.append(.sailing) }
        if p.led != .system && !led { result.append(.led) }
        if p.blinkWhileDischarging && (!led || minimumDischargeTarget == nil) { result.append(.blinking) }
        if let minimumLimit, !(minimumLimit...maximumLimit).contains(p.limit) { result.append(.limitRange) }
        if p.heatProtection && !thermalPause { result.append(.heat) }
        if (reviewTrial && p.sleep != .unchanged) || (p.sleep == .pause && !immediatePause) { result.append(.sleep) }
        if reviewTrial && p.allowLowLimit { result.append(.lowLimitPermission) }
        if reviewTrial && p.lowPower != .never { result.append(.lowPower) }
        return result
    }
    #if BATTERY_HELPER || DEBUG
    func validate(_ request: BatteryControlRequest, currentLevel: Int?) throws {
        try request.validate()
        guard backend != nil else { throw BatteryControlError.unavailable("尚无已识别的控制通道，未提交控制请求。") }
        if reviewTrial { try BatteryNativeCutoffTrial.validatePreferences(request.preferences) }
        if let issue = issues(request.preferences).first { throw BatteryControlError.unavailable(issue.message) }
        if case .start = request.calibration, !calibration {
            throw BatteryControlError.unavailable("当前控制通道不支持完整校准，未开始部分校准。")
        }
        if request.mode == .topUp && reviewTrial {
            throw BatteryControlError.unavailable("本验证包未开放临时充满；未提交控制请求。")
        }
        if request.mode == .paused && !canPause(at: currentLevel) {
            throw BatteryControlError.unavailable("当前电量或控制通道无法确认临时暂停充电，未执行。")
        }
        if request.mode == .discharge {
            guard let minimumDischargeTarget else {
                throw BatteryControlError.unavailable("当前控制通道不支持主动放电；未提交控制请求。")
            }
            guard let target = request.dischargeTarget, (minimumDischargeTarget...99).contains(target) else {
                throw BatteryControlError.unavailable("当前控制通道的放电目标需为\(minimumDischargeTarget)–99%；未提交控制请求。")
            }
            if reviewTrial && target != 80 {
                throw BatteryControlError.unavailable("本验证包的放电目标固定80%；未提交控制请求。")
            }
        }
    }
    #endif
}

#if BATTERY_HELPER || DEBUG
/// All rejection-prone planning precedes a lease renewal. There are no writes,
/// saves, policy mutations, or fallback hardware choices in this stage.
enum BatteryControlAdmission {
    static func preflight(_ request: BatteryControlRequest, previous: BatteryControlRequest?,
                          policy: BatteryControlPolicy, capabilities: BatteryControlCapabilities,
                          telemetry: BatteryTelemetry, calibrationActive: Bool,
                          ownsAdapterCutoff: () throws -> Bool,
                          validateTargets: (BatteryControlDecision) throws -> Void) throws {
        try capabilities.validate(request, currentLevel: telemetry.level)
        guard !calibrationActive else { return }
        var proposedPolicy = policy
        proposedPolicy.configure(previous: previous, next: request)
        let proposed = try proposedPolicy.decide(request: request, snapshot: telemetry,
            ownsAdapterCutoff: ownsAdapterCutoff())
        try validateTargets(proposed)
    }
}
#endif
