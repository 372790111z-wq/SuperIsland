import Foundation

#if BATTERY_HELPER || DEBUG

/// Native MCL drain has no adapter-cutoff ownership. A registered target is
/// insufficient: retain the deadline while waiting for a real discharge sample.
struct BatteryNativeDrainVerification {
    private var operation: UUID?
    private var began: TimeInterval?
    private var waitingSince: TimeInterval?
    private var lastTime: TimeInterval?
    let responseTimeout: TimeInterval
    init(responseTimeout: TimeInterval = 90) { self.responseTimeout = responseTimeout }

    /// Called before any MCL mutation, so a slow write cannot move the start.
    mutating func prepare(active: Bool, operationID: UUID, now: TimeInterval,
                          maximumDuration: TimeInterval? = nil) throws {
        guard active else { reset(); return }
        guard now.isFinite, now >= 0, responseTimeout.isFinite, responseTimeout > 0,
              lastTime.map({ now >= $0 }) ?? true else {
            throw BatteryControlError.recovery("原生放电观察时钟无效；停止控制并恢复原设置。")
        }
        if operation != operationID { reset(); operation = operationID; began = now; waitingSince = now }
        lastTime = now
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0,
                  now - (began ?? now) < maximumDuration else {
                throw BatteryControlError.recovery("原生放电复测期限已到；停止控制并恢复原设置。")
            }
        }
    }

    mutating func observe(active: Bool, operationID: UUID, current: Double?,
                          registered: Bool?, now: TimeInterval, suspended: Bool = false,
                          maximumDuration: TimeInterval? = nil) throws -> Bool {
        try prepare(active: active, operationID: operationID, now: now, maximumDuration: maximumDuration)
        guard active else { return false }
        // The OS may temporarily override the target. Pause only the response
        // window, never the operation's overall review deadline.
        if suspended { waitingSince = now; return false }
        let draining = registered == true && current.map { $0.isFinite && $0 < -0.05 } == true
        if draining { waitingSince = nil; return true }
        if waitingSince == nil { waitingSince = now }
        guard now - waitingSince! < responseTimeout else {
            throw BatteryControlError.recovery("原生放电未得到一致的Drain登记及实际负电流确认；停止控制并恢复原设置。")
        }
        return false
    }

    mutating func reset() { operation = nil; began = nil; waitingSince = nil; lastTime = nil }
}

#endif
