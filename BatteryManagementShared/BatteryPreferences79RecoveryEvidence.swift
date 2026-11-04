import Foundation

#if (BATTERY_HELPER && BATTERY_REVIEW) || DEBUG
/// A 79 registration and a cached negative current do not prove that the new
/// request caused discharge. Require a fresh, stable segment after submission.
struct BatteryPreferences79DischargeEvidence {
    private let startedWall: Date
    private let startedContinuous: TimeInterval
    private var lastWall: Date
    private var lastContinuous: TimeInterval
    private var latestUpdate: Date?
    private var firstUpdate: Date?
    private var segmentStarted: TimeInterval?
    private var failed = false

    init(startedWall: Date, startedContinuous: TimeInterval) throws {
        guard startedWall.timeIntervalSinceReferenceDate.isFinite,
              startedContinuous.isFinite, startedContinuous >= 0 else {
            throw BatteryPreferences79Transaction.Failure.invalid
        }
        self.startedWall = startedWall; self.startedContinuous = startedContinuous
        lastWall = startedWall; lastContinuous = startedContinuous
    }

    mutating func observe(_ sample: BatteryPreferences79Transaction.Observation,
                          updateTime: Date?, now: TimeInterval) throws -> Bool {
        guard !failed, now.isFinite, sample.wallDate.timeIntervalSinceReferenceDate.isFinite,
              now >= lastContinuous, sample.wallDate >= lastWall,
              abs(sample.wallDate.timeIntervalSince(startedWall) - (now - startedContinuous)) <= 5 else {
            failed = true; throw BatteryPreferences79Transaction.Failure.invalid
        }
        guard now - startedContinuous < BatteryPreferences79Transaction.observationDuration else {
            failed = true; throw BatteryPreferences79Transaction.Failure.expired
        }
        if now - lastContinuous > 8 { reset() }
        lastContinuous = now; lastWall = sample.wallDate
        guard let updateTime, updateTime.timeIntervalSinceReferenceDate.isFinite,
              updateTime >= startedWall,
              (-2...90).contains(sample.wallDate.timeIntervalSince(updateTime)),
              latestUpdate.map({ updateTime >= $0 }) != false else { reset(); return false }
        latestUpdate = updateTime
        // Native queries remain disabled at low adapter input; do not forge a
        // getter value from preferences or require an unsafe getter to succeed.
        let nativeConsistent = (sample.nativeLimit == nil && sample.nativeEnabled == nil)
            || (sample.nativeLimit == 79 && sample.nativeEnabled == 1)
        guard nativeConsistent, sample.rawPreferenceLimit == 79, sample.rawPreferenceEnabled == 1,
              !sample.registrations.isEmpty, sample.registrations.allSatisfy({ $0 == 79 }),
              sample.level.isFinite, (79...85).contains(sample.level), sample.adapterPresent,
              sample.batteryCurrent.isFinite, sample.batteryCurrent < -0.05,
              sample.adapterPower.isFinite, sample.adapterPower >= 0,
              !sample.competingController, !sample.calibrationActive else { reset(); return false }
        if segmentStarted == nil { segmentStarted = now; firstUpdate = updateTime }
        return segmentStarted.map { now - $0 >= 15 } == true
            && firstUpdate.map { updateTime > $0 } == true
    }
    private mutating func reset() { segmentStarted = nil; firstUpdate = nil }
}

/// Pure, bounded recovery evidence. A true result authorizes no writes and
/// clears no journal; the transaction owner must still confirm restoration.
struct BatteryPreferences79RecoveryEvidence {
    enum Failure: LocalizedError, Equatable {
        case invalidClock, clockChanged, expired
        var errorDescription: String? {
            switch self {
            case .invalidClock: return "恢复观察的时间读数无效；结果未知，恢复记录保留。"
            case .clockChanged: return "恢复观察期间时间倒退或系统时钟变化；结果未知，恢复记录保留。"
            case .expired: return "恢复观察已达180秒界限；恢复尚未确认，记录保留。"
            }
        }
    }

    private let startedWall: Date
    private let startedContinuous: TimeInterval
    private var lastWall: Date
    private var lastContinuous: TimeInterval
    // Retain the highest valid update across interruptions. An older update
    // cannot become trustworthy merely because the stable segment was reset.
    private var latestUpdate: Date?
    private var stableStarted: TimeInterval?
    private var stableLatestUpdate: Date?
    private var distinctUpdates = 0
    private var terminalFailure: Failure?

    init(startedWall: Date, startedContinuous: TimeInterval) throws {
        guard startedWall.timeIntervalSinceReferenceDate.isFinite,
              startedContinuous.isFinite, startedContinuous >= 0 else { throw Failure.invalidClock }
        self.startedWall = startedWall; self.startedContinuous = startedContinuous
        lastWall = startedWall; lastContinuous = startedContinuous
    }

    /// `now` is an externally supplied continuous clock, including sleep.
    /// Invalid telemetry/update dates reset the segment; clock faults and the
    /// original deadline are terminal for this evidence instance.
    mutating func observe(_ sample: BatteryPreferences79Transaction.Observation,
                          updateTime: Date?, now: TimeInterval) throws -> Bool {
        if let terminalFailure { throw terminalFailure }
        guard now.isFinite, sample.wallDate.timeIntervalSinceReferenceDate.isFinite else {
            throw fail(.invalidClock)
        }
        guard now >= lastContinuous, sample.wallDate >= lastWall else { throw fail(.clockChanged) }
        let elapsed = now - startedContinuous
        let wallElapsed = sample.wallDate.timeIntervalSince(startedWall)
        guard elapsed.isFinite, wallElapsed.isFinite else { throw fail(.invalidClock) }
        guard elapsed >= 0, wallElapsed >= 0, abs(wallElapsed - elapsed) <= 5 else {
            throw fail(.clockChanged)
        }
        guard elapsed < 180 else { throw fail(.expired) }
        // UpdateTime freshness describes the sample's context, not continuous
        // physical observation. Sleep or a queued worker must not bridge a
        // hole in the stable segment, even when both clocks advanced equally.
        if now - lastContinuous > 8 { reset() }
        lastContinuous = now; lastWall = sample.wallDate

        guard let updateTime, updateTime.timeIntervalSinceReferenceDate.isFinite else { return reset() }
        // Retained r22 read-only evidence has 60 seconds between battery
        // UpdateTime values. This is context, not every getter/sensor's sampling
        // instant; its 90-second freshness is separate from the 8-second poll gap.
        let age = sample.wallDate.timeIntervalSince(updateTime)
        guard age.isFinite, updateTime >= startedWall, age >= -2, age <= 90,
              latestUpdate.map({ updateTime >= $0 }) != false else { return reset() }
        latestUpdate = updateTime

        guard sample.nativeLimit == 80, sample.nativeEnabled == 1,
              !sample.registrations.isEmpty, sample.registrations.allSatisfy({ $0 == 80 }),
              sample.level.isFinite, (0...100).contains(sample.level),
              sample.adapterPresent, sample.adapterPower.isFinite, sample.adapterPower > 1,
              sample.batteryCurrent.isFinite, sample.batteryCurrent >= -0.05,
              !sample.competingController, !sample.calibrationActive else { return reset() }
        if stableStarted == nil {
            stableStarted = now; stableLatestUpdate = updateTime; distinctUpdates = 1
        } else if stableLatestUpdate.map({ updateTime > $0 }) == true {
            stableLatestUpdate = updateTime
            distinctUpdates = 2 // Only the threshold matters; no unbounded set.
        }
        return stableStarted.map({ now - $0 >= 15 && distinctUpdates >= 2 }) == true
    }

    @discardableResult
    private mutating func reset() -> Bool {
        stableStarted = nil; stableLatestUpdate = nil; distinctUpdates = 0
        return false
    }
    private mutating func fail(_ failure: Failure) -> Failure {
        terminalFailure = failure
        reset()
        return failure
    }
}
#endif
