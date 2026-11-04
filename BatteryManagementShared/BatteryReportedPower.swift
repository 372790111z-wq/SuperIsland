import Foundation
import CoreFoundation

/// One system-published dictionary, kept separate from V×I and rated capacity.
/// The /1000 scale is corroborated by captured power/V/I values, not a public
/// Apple schema. No channel sample time or instantaneous window is known.
struct BatteryReportedPower: Codable, Equatable {
    enum Channel { case input, load, battery }
    struct Identity: Equatable {
        var input: Double?
        var load: Double?
        var battery: Double?
        var counters: [String: Int64]
    }
    var readAt: Date
    var batteryUpdateTimeContext: Date?
    var inputWatts: Double?
    var loadWatts: Double?
    var batteryWatts: Double?
    var counters: [String: Int64]
    var cumulativeErrorCount: Int64?
    var identity: Identity { .init(input: inputWatts, load: loadWatts, battery: batteryWatts, counters: counters) }
    var complete: Bool { inputWatts != nil && loadWatts != nil && batteryWatts != nil }
    var inconsistent: Bool {
        guard let inputWatts, let loadWatts, let batteryWatts else { return false }
        // Presentation warning only; never repair or fill a corner by subtraction.
        return abs(inputWatts - loadWatts - batteryWatts) > max(0.5, max(inputWatts, max(loadWatts, abs(batteryWatts))) * 0.05)
    }
    func contradictsSupply(_ supply: Bool?) -> Bool { supply == false && (inputWatts ?? 0) > 0.5 }
    func readExpired(at now: Date) -> Bool { !(0...120).contains(now.timeIntervalSince(readAt)) }
    func formatted(_ channel: Channel, at now: Date = Date()) -> String {
        let value: Double?
        switch channel { case .input: value = inputWatts; case .load: value = loadWatts; case .battery: value = batteryWatts }
        guard let value else { return "—" }
        return (readExpired(at: now) ? "上次约" : "约") + String(format: channel == .battery && abs(value) >= 0.05 ? "%+.1f W" : "%.1f W", value == 0 ? 0 : value)
    }
    static func decode(_ value: Any?, readAt: Date, batteryUpdateTime: Any?) -> Self? {
        guard readAt.timeIntervalSince1970.isFinite, let dictionary = value as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func watts(_ key: String, signed: Bool = false) -> Double? {
            guard let raw = number(dictionary[key]), (signed ? -1_000_000...1_000_000 : 0...1_000_000).contains(raw) else { return nil }
            return raw / 1000
        }
        func counter(_ key: String) -> Int64? {
            guard let value = number(dictionary[key]), value >= 0, value < Double(Int64.max), value.rounded(.towardZero) == value else { return nil }
            return Int64(value)
        }
        var counters: [String: Int64] = [:]
        for key in ["SystemPowerInAccumulatorCount", "SystemLoadAccumulatorCount", "BatteryPowerAccumulatorCount"] { counters[key] = counter(key) }
        // This is context for the parent battery properties, NOT measuredAt.
        let updated = number(batteryUpdateTime).flatMap { $0 > 0 && $0 < 100_000_000_000 ? Date(timeIntervalSince1970: $0) : nil }
        return .init(readAt: readAt, batteryUpdateTimeContext: updated,
            inputWatts: watts("SystemPowerIn"), loadWatts: watts("SystemLoad"), batteryWatts: watts("BatteryPower", signed: true),
            counters: counters, cumulativeErrorCount: counter("PowerTelemetryErrorCount"))
    }
}

/// Observing a different report is not observing its physical sampling time.
/// Repeated reads, parent UpdateTime, and an inactive channel's unchanged count
/// must not turn into a fabricated fresh measurement.
struct BatteryReportedPowerWindow {
    struct State: Equatable {
        var report: BatteryReportedPower?
        var firstObservedAt: Date?
        var lastNewReportObservedAt: Date?
    }
    private(set) var state = State()
    mutating func record(_ report: BatteryReportedPower?) {
        guard let report, report.readAt.timeIntervalSince1970.isFinite else { state = .init(); return }
        let previous = state.report
        let gap = previous.map { report.readAt.timeIntervalSince($0.readAt) }
        let counterReset = previous.map { previous in
            previous.counters.contains { key, value in report.counters[key].map { $0 < value } ?? true }
        } ?? false
        if previous == nil || gap.map({ !(0...120).contains($0) }) == true || counterReset {
            state = .init(report: report, firstObservedAt: report.readAt)
            return
        }
        if previous?.identity != report.identity { state.lastNewReportObservedAt = report.readAt }
        state.report = report
    }
}
