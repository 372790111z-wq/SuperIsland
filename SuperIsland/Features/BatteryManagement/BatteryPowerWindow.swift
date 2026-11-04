import Foundation

/// Signed battery watts, integrated over observed time. No extrapolation across
/// sleep, missing sensors or stale samples, and no fabricated full-minute data.
struct BatteryPowerWindow {
    struct Summary: Equatable {
        let watts: Double
        let coverage: TimeInterval
        var dischargeOnly = false
    }
    private struct Sample { let time: Date; let watts: Double }
    private var samples: [Sample] = []
    private let window: TimeInterval
    private let maximumGap: TimeInterval
    init(window: TimeInterval = 60, maximumGap: TimeInterval = 15) {
        self.window = min(3600, max(10, window.isFinite ? window : 60))
        self.maximumGap = min(45, max(1, maximumGap.isFinite ? maximumGap : 15))
    }

    mutating func record(_ snapshot: BatteryTelemetry) {
        let time = snapshot.timestamp
        guard time.timeIntervalSinceReferenceDate.isFinite else { samples.removeAll(); return }
        if let last = samples.last {
            if time == last.time { return }
            if time < last.time { samples.removeAll() }
        }
        guard snapshot.hasBattery, let power = snapshot.power, power.isFinite else {
            samples.removeAll(); return
        }
        if let last = samples.last {
            let gap = time.timeIntervalSince(last.time)
            if gap > maximumGap { samples.removeAll() }
            else if gap < 1 { return }
        }
        samples.append(Sample(time: time, watts: power))
        let cutoff = time.addingTimeInterval(-window)
        // Retain one sample before the boundary for interpolation only.
        while samples.count > 1 && samples[1].time <= cutoff { samples.removeFirst() }
    }

    func summary(at now: Date, window requestedWindow: TimeInterval? = nil) -> Summary? {
        guard samples.count >= 2, let first = samples.first, let last = samples.last,
              now >= last.time, now.timeIntervalSince(last.time) <= maximumGap else { return nil }
        let duration = min(window, max(10, requestedWindow ?? window))
        let start = max(first.time, now.addingTimeInterval(-duration))
        let end = last.time
        let coverage = end.timeIntervalSince(start)
        guard coverage >= 10 else { return nil }
        var joules = 0.0
        var dischargeOnly = true
        for (a, b) in zip(samples, samples.dropFirst()) {
            let left = max(start, a.time), right = min(end, b.time)
            guard right > left else { continue }
            let interval = b.time.timeIntervalSince(a.time)
            let leftPower = a.watts + (b.watts - a.watts) * left.timeIntervalSince(a.time) / interval
            let rightPower = a.watts + (b.watts - a.watts) * right.timeIntervalSince(a.time) / interval
            dischargeOnly = dischargeOnly && leftPower < -0.1 && rightPower < -0.1
            joules += (leftPower + rightPower) / 2 * right.timeIntervalSince(left)
        }
        let watts = joules / coverage
        guard watts.isFinite else { return nil }
        return Summary(watts: watts, coverage: coverage, dischargeOnly: dischargeOnly)
    }
}

/// Approximate remaining energy from the measured gauge charge and voltage.
/// Never extrapolate runtime while on AC, charging, or across mixed power signs.
enum BatteryRuntimeEstimate {
    static func minutes(snapshot s: BatteryTelemetry, mode: BatteryRuntimeMode, average: BatteryPowerWindow.Summary?) -> Int? {
        guard s.hasBattery else { return nil }
        if s.charging { return s.minutesRemaining.flatMap { $0 > 0 ? $0 : nil } }
        guard s.powerSupplyObservation == false, let instantaneous = s.power, instantaneous.isFinite, instantaneous < -0.1,
              let charge = s.remainingCapacity, charge > 0, let full = s.fullCapacity, charge <= full,
              let voltage = s.voltage, voltage.isFinite, voltage > 0 else { return nil }
        if mode == .average, average?.dischargeOnly != true { return nil }
        let watts = mode == .instant ? instantaneous : average?.watts
        guard let watts, watts.isFinite, watts < -0.1 else { return nil }
        let minutes = Double(charge) / 1000 * voltage / -watts * 60
        guard minutes.isFinite, minutes >= 1, minutes < Double(Int.max) else { return nil }
        return Int(minutes.rounded(.down))
    }
}
