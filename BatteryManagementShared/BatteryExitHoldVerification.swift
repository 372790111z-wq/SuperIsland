import Foundation
#if BATTERY_HELPER || DEBUG
/// Two independent hardware update contexts after the hold request. The
/// observed battery cadence is about60s, so a30s total gate was insufficient.
struct BatteryExitHoldVerification {
    let target: Int
    let started: TimeInterval
    let submittedAt: Date
    private(set) var firstUpdate: Date?
    private(set) var lastUpdate: Date?
    private(set) var count = 0
    mutating func observe(_ telemetry: BatteryTelemetry, registered: Set<Int>?, saved: Int?,
                          input: Bool?, now: TimeInterval, date: Date) throws -> Bool {
        guard now.isFinite, now >= started, now - started <= 150 else {
            throw BatteryControlError.recovery("退出暂停确认超时，需恢复后重试；程序尚未退出。")
        }
        guard let update = telemetry.reportedPower?.batteryUpdateTimeContext,
              update >= submittedAt, date.timeIntervalSince(update) >= -2, date.timeIntervalSince(update) <= 90,
              telemetry.powerSupplyObservation == true, input == true,
              telemetry.chargingObservation == false,
              telemetry.current.map({ $0.isFinite && $0 <= 0.05 }) == true,
              registered == [target], saved == target else {
            count = 0; firstUpdate = nil; lastUpdate = nil; return false
        }
        guard lastUpdate.map({ update > $0 }) ?? true else { return false }
        if firstUpdate == nil { firstUpdate = update }
        lastUpdate = update; count += 1
        return count >= 2 && update.timeIntervalSince(firstUpdate!) >= 2
    }
}
#endif
