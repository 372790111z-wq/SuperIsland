import Foundation

#if BATTERY_HELPER || DEBUG

/// Native manual limits can drain to a target without disconnecting the
/// adapter. This pure planner never generates an SMC cutoff or a neutralizing
/// 85/100% pre-step. Physical outcome remains the helper's separate verifier.
enum BatteryNativeDischargePlanner {
    static let minimumTarget = 80

    static func targets(decision: BatteryControlDecision, request: BatteryControlRequest,
                        currentLevel: Int?) throws -> [String: Int] {
        // The native planner shares admission semantics with UI, tasks and
        // the daemon. LED/energy facts are checked separately by the driver.
        try BatteryControlCapabilities(backend: .native, dischargeSupported: true,
            minimumDischargeTarget: minimumTarget, led: true, highPower: true,
            calibration: false, reviewTrial: false).validate(request, currentLevel: currentLevel)
        guard let currentLevel, (0...100).contains(currentLevel) else {
            throw BatteryControlError.unavailable("没有可确认的实际电量；未用目标值代替读数。")
        }
        // forceDischarge is the policy's logical drain request, independent of
        // the older adapter-cutoff nativeTarget() neutralization contract.
        let target = decision.forceDischarge ? decision.target : decision.nativeTarget(currentLevel: currentLevel)
        guard (minimumTarget...100).contains(target) else {
            throw BatteryControlError.unavailable("本机原生充电限值仅支持80–100%；低值和低于80%时的暂停尚未接通受控路径。")
        }
        return ["nativeAPIEnabled": 1, "nativeAPILimit": target]
    }
}

#endif
