import Foundation

/// Local preference editing and task admission. Hardware admission remains in
/// the helper; this policy never grants a control capability.
enum BatteryPreferenceCompatibility {
    typealias Issue = BatteryControlCapabilities.Issue

    static func issues(_ p: BatteryControlPreferences, report: BatteryControlReport) -> [Issue] {
        report.capabilities.issues(p)
    }

    static func validate(_ p: BatteryControlPreferences, report: BatteryControlReport) throws {
        if report.nativeCutoffReviewTrial == true { try BatteryNativeCutoffTrial.validatePreferences(p) }
        if let issue = issues(p, report: report).first { throw BatteryControlError.unavailable(issue.message) }
    }

    /// Only fully resolved incompatible fields may change. Remaining invalid
    /// fields and every unrelated preference must retain the user's values.
    static func isPartialRepair(from old: BatteryControlPreferences, to next: BatteryControlPreferences,
                                report: BatteryControlReport) -> Bool {
        let before = issues(old, report: report), after = issues(next, report: report)
        guard !after.isEmpty, after.count < before.count,
              after.allSatisfy({ before.contains($0) }), (try? next.validate()) != nil else { return false }
        var repaired = old
        for issue in before where !after.contains(issue) {
            switch issue {
            case .highPower: repaired.highPower = next.highPower
            case .automaticDischarge: repaired.automaticDischarge = next.automaticDischarge
            case .sailing: repaired.sailing = next.sailing; repaired.sailingLower = next.sailingLower
            case .led: repaired.led = next.led
            case .blinking: repaired.blinkWhileDischarging = next.blinkWhileDischarging
            case .limitRange: repaired.limit = next.limit
            case .heat: repaired.heatProtection = next.heatProtection
            case .sleep: repaired.sleep = next.sleep
            case .lowLimitPermission: repaired.allowLowLimit = next.allowLowLimit
            case .lowPower: repaired.lowPower = next.lowPower
            }
        }
        return repaired == next
    }

    static func taskWarning(_ task: BatteryScheduledTask, report r: BatteryControlReport,
                            preferences: BatteryControlPreferences? = nil) -> String? {
        // Unknown capability permits saving future plans; execution still has
        // to obtain a fresh helper response. A known rejection is shown now.
        if r.nativeCutoffReviewTrial == true {
            switch task.action {
            case .topUp, .calibrate: return "本验证包仅开放79–85%范围，不执行充满或完整校准。"
            case .limit where !(80...85).contains(task.target): return "本验证包的充电上限需为80–85%。"
            case .discharge where task.target != 80: return "本验证包的放电目标固定为80%。"
            default: break
            }
        }
        switch task.action {
        case .limit:
            if let minimum = r.capabilities.minimumLimit, task.target < minimum { return "当前原生通道的充电上限最低80%；原任务目标已保留，尚未执行。" }
            if task.target < 80 && preferences?.allowLowLimit == false { return "请先在充电设置中允许低于80%，再启用此任务。" }
        case .discharge:
            if let minimum = r.capabilities.minimumDischargeTarget, task.target < minimum { return "当前控制通道的放电目标不能低于\(minimum)%；原任务目标已保留。" }
            if r.capabilities.minimumDischargeTarget == nil && (r.available || r.mechanism != "尚未检测") { return "当前控制通道不支持主动放电；任务不会执行。" }
        case .calibrate:
            if r.calibrationSupported == false || (r.capabilities.backend != nil && !r.capabilities.calibration) { return "当前控制通道不支持完整校准；可保留为未启用任务。" }
        case .pause, .automatic, .topUp: break
        }
        return nil
    }
}
