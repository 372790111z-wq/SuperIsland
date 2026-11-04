import Foundation

/// Measured values remain separate: the displayed OS percentage is not the
/// selected current-percentage source. No target value may fill a missing read.
#if BATTERY_HELPER || DEBUG
struct BatteryCalibrationSample {
    var uptime: TimeInterval
    var currentPercentage: Float?
    var osPercentage: Float?
    var adapterConnected: Bool
    var systemCharging: Bool
    var voltage: Float?
    var current: Float?
    var power: Float?

    var validPower: Bool {
        guard let voltage, voltage.isFinite, voltage > 0,
              let current, current.isFinite, let power, power.isFinite else { return false }
        return !systemCharging || power > Float(0.1)
    }
    var fullWithoutInflow: Bool {
        adapterConnected && Self.validPercentage(osPercentage).map { $0 >= 98 } == true
            && validPower && power.map { $0 <= Float(0.1) } == true
    }
    static func validPercentage(_ value: Float?) -> Float? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

#endif

/// Pure calibration lifecycle. This does not authorize hardware writes or start
/// a timer. A driver must support the entire 100→10→100→hold→saved-limit cycle
/// and durable restoration before exposing a start action.
///
/// Numeric phase predicates come from AlDente1.39.4 arm64 monitor0x1000df8ac.
/// Freshness/cadence guards and explicit restoration acknowledgement are
/// SuperIsland safety rules, not claims about the reference application's code.
struct BatteryCalibrationSession {
    enum Phase: String, Codable {
        case firstCharge, discharge, secondCharge, hold, returnToLimit
        case restoring, completed, interrupted
    }
    enum EndReason: String, Codable {
        case cycleFinished, cancelled, unplugged, protection, permissionLost, exit, timeout
    }
    #if BATTERY_HELPER || DEBUG
    let originalLimit: Int
    private(set) var phase = Phase.firstCharge
    private(set) var endReason: EndReason?
    private(set) var completedAt: TimeInterval?
    private(set) var noInflowSamples = 0
    private(set) var unreadablePowerSamples = 0
    private(set) var waitingForSystemCalibration = false
    private var lastSample: TimeInterval?
    private var holdStarted: TimeInterval?

    init(originalLimit: Int) throws {
        guard (20...100).contains(originalLimit) else {
            throw BatteryControlError.invalid("校准前需有可恢复的原充电上限。")
        }
        self.originalLimit = originalLimit
    }

    mutating func interrupt(_ reason: EndReason) {
        guard reason != .cycleFinished else { return }
        beginRestoration(reason)
    }

    private mutating func beginRestoration(_ reason: EndReason) {
        guard phase != .completed, phase != .interrupted else { return }
        // A later exit/cancel cannot turn an interrupted cycle into success.
        if phase == .restoring {
            if endReason == .cycleFinished, reason != .cycleFinished { endReason = reason }
            return
        }
        endReason = reason; phase = .restoring
        waitingForSystemCalibration = false
        resetSamples()
    }

    /// The caller may acknowledge only after restoring and reading back the
    /// saved limit and all owned overrides. A failed restore remains retryable.
    mutating func acknowledgeRestoration(verified: Bool, now: TimeInterval) {
        guard phase == .restoring, verified, now.isFinite, now >= 0 else { return }
        if endReason == .cycleFinished {
            phase = .completed; completedAt = now
        } else { phase = .interrupted }
    }

    mutating func observe(_ sample: BatteryCalibrationSample, now: TimeInterval,
                          systemCalibration: Bool = false, maximumSampleGap: TimeInterval = 15) {
        guard phase != .restoring, phase != .completed, phase != .interrupted else { return }
        guard maximumSampleGap.isFinite, (15...90).contains(maximumSampleGap) else { resetSamples(); return }
        guard sample.adapterConnected else { interrupt(.unplugged); return }
        guard now.isFinite, now >= 0, sample.uptime.isFinite, sample.uptime >= 0 else { resetSamples(); return }
        if let lastSample, now < lastSample {
            // Uptime rollback/restart cannot earn hold time or consecutive reads.
            self.lastSample = nil
            if phase == .hold { holdStarted = now }
            resetSamples()
        }
        guard sample.uptime <= now, now - sample.uptime <= 15 else { resetSamples(); return }
        if let lastSample {
            guard sample.uptime > lastSample else { return }
            // Never count repeated fast polling as multiple independent reads.
            guard sample.uptime - lastSample >= 2 else { return }
            if sample.uptime - lastSample > maximumSampleGap { resetSamples() }
        }
        lastSample = sample.uptime
        waitingForSystemCalibration = systemCalibration
        if systemCalibration {
            // Yield all phase changes while macOS owns the full-charge override.
            // Do not let that interval satisfy the unreadable-power fallback.
            if phase == .hold { holdStarted = now }
            resetSamples(); return
        }
        switch phase {
        case .firstCharge:
            noInflowSamples = sample.fullWithoutInflow ? min(3, noInflowSamples + 1) : 0
            if BatteryCalibrationSample.validPercentage(sample.osPercentage) == 100 || noInflowSamples >= 3 {
                transition(to: .discharge)
            }
        case .discharge:
            if let value = BatteryCalibrationSample.validPercentage(sample.currentPercentage), Int(value) <= 10 {
                transition(to: .secondCharge)
            }
        case .secondCharge:
            if let value = BatteryCalibrationSample.validPercentage(sample.osPercentage), value >= 98 {
                transition(to: .hold); holdStarted = now
            }
        case .hold:
            if sample.validPower {
                unreadablePowerSamples = 0
                noInflowSamples = sample.fullWithoutInflow ? min(3, noInflowSamples + 1) : 0
            } else {
                noInflowSamples = 0
                unreadablePowerSamples = min(3, unreadablePowerSamples + 1)
            }
            let fallback = holdStarted.map { now - $0 >= 3601 } ?? false
            if noInflowSamples >= 3 || (unreadablePowerSamples >= 3 && fallback) {
                transition(to: .returnToLimit)
            }
        case .returnToLimit:
            if let value = BatteryCalibrationSample.validPercentage(sample.currentPercentage), Int(value) <= originalLimit {
                beginRestoration(.cycleFinished)
            }
        case .restoring, .completed, .interrupted: break
        }
    }

    private mutating func transition(to next: Phase) {
        phase = next; resetSamples()
    }
    private mutating func resetSamples() {
        noInflowSamples = 0; unreadablePowerSamples = 0
    }
    #endif
}
