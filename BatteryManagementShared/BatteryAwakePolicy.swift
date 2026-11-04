import Foundation

enum BatteryAwakePolicy {
    static func needed(enabled: Bool, telemetry: BatteryTelemetry, preferences: BatteryControlPreferences,
                       mode: BatteryControlMode, calibrationActive: Bool) -> Bool {
        guard enabled, preferences.sleep == .untilLimit, telemetry.adapterPresent else { return false }
        // Calibration has its own100/10/100/hold/return cycle. The saved80%
        // ceiling must not release this feature's assertion halfway through it.
        if calibrationActive { return true }
        return telemetry.onAC && (telemetry.level ?? 100) < (mode == .topUp ? 100 : preferences.limit)
            && mode != .paused && mode != .discharge
    }
}
