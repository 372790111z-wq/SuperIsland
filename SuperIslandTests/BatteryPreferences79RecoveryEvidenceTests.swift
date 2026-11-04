import XCTest
@testable import SuperIsland

#if (BATTERY_HELPER && BATTERY_REVIEW) || DEBUG
final class BatteryPreferences79DischargeEvidenceTests: XCTestCase {
    private typealias E = BatteryPreferences79DischargeEvidence
    private typealias S = BatteryPreferences79Transaction.Observation
    private let wall = Date(timeIntervalSince1970: 10_000)
    private func make() throws -> E { try E(startedWall: wall, startedContinuous: 100) }
    private func observe(_ e: inout E, _ elapsed: Double, update: Double?,
                         change: (inout S) -> Void = { _ in }) throws -> Bool {
        var sample = S(nativeLimit: 79, nativeEnabled: 1, registrations: [79, 79], level: 80,
                       adapterPresent: true, batteryCurrent: -3.6, adapterPower: 0.4,
                       wallDate: wall.addingTimeInterval(elapsed), rawPreferenceLimit: 79, rawPreferenceEnabled: 1)
        change(&sample)
        return try e.observe(sample, updateTime: update.map { wall.addingTimeInterval($0) }, now: 100 + elapsed)
    }
    func testMinuteCadenceRequiresSecondPostSubmissionContext() throws {
        var e = try make()
        // Actual native response can be later than the old 30-second window.
        for t in stride(from: 0.0, through: 120, by: 3) {
            let update = t < 60 ? -1.0 : t < 120 ? 60.0 : 120.0
            XCTAssertEqual(try observe(&e, t, update: update), t == 120)
        }
    }
    func testLowAdapterInputDoesNotNeedNativeGetterButNeedsSavedAndRegisteredTarget() throws {
        var e = try make()
        for t in stride(from: 0.0, through: 120, by: 3) {
            XCTAssertEqual(try observe(&e, t, update: t < 60 ? -1 : t < 120 ? 60 : 120) {
                $0.nativeLimit = nil; $0.nativeEnabled = nil
                $0.adapterPower = 0.4
            }, t == 120)
        }
    }
    func testTypedPreferenceParsingRejectsMissingBooleanFractionalOrMalformedLimit() {
        typealias V = BatteryPreferences79Transaction.Value
        for v: V in [.absent, .bool(true), .string("79"), .real(79.5), .real(.nan), .integer(19), .integer(101)] {
            XCTAssertNil(BatteryPreferences79IO.observedPreferenceLimit(v))
        }
        XCTAssertEqual(BatteryPreferences79IO.observedPreferenceLimit(.integer(79)), 79)
        XCTAssertEqual(BatteryPreferences79IO.observedPreferenceLimit(.real(79)), 79)
        for v: V in [.absent, .integer(2), .string("1"), .real(.infinity)] {
            XCTAssertNil(BatteryPreferences79IO.observedPreferenceEnabled(v))
        }
        XCTAssertEqual(BatteryPreferences79IO.observedPreferenceEnabled(.bool(true)), 1)
        XCTAssertEqual(BatteryPreferences79IO.observedPreferenceEnabled(.real(1)), 1)
        XCTAssertEqual(BatteryPreferences79IO.observedPreferenceEnabled(.integer(0)), 0)
    }
    func testCachedNegativeCurrentAndMissingFutureOrRolledBackContextsCannotPass() throws {
        for update: Double? in [-1, nil, 200] {
            var e = try make()
            for t in stride(from: 0.0, through: 140, by: 4) {
                XCTAssertFalse(try observe(&e, t, update: update))
            }
        }
        var e = try make()
        for t in stride(from: 0.0, through: 80, by: 4) {
            XCTAssertFalse(try observe(&e, t, update: 0))
        }
        XCTAssertFalse(try observe(&e, 84, update: -1))
        XCTAssertFalse(try observe(&e, 88, update: 0))
    }
    func testTwoContextsAloneCannotSkipStableSegmentOrBridgeGap() throws {
        var e = try make()
        XCTAssertFalse(try observe(&e, 0, update: 0))
        XCTAssertFalse(try observe(&e, 4, update: 4))
        XCTAssertFalse(try observe(&e, 8, update: 4))
        XCTAssertFalse(try observe(&e, 20, update: 20))
        for t in [24.0, 28, 32, 36] { XCTAssertFalse(try observe(&e, t, update: 20)) }
        XCTAssertTrue(try observe(&e, 40, update: 40))
    }
    func testInvalidTelemetryBreaksSegmentEvenWhenNegativeCurrentIsPresent() throws {
        let changes: [(inout S) -> Void] = [
            { $0.nativeLimit = 80 }, { $0.nativeEnabled = 0 }, { $0.registrations = [79, 80] },
            { $0.nativeLimit = nil }, { $0.rawPreferenceLimit = nil },
            { $0.rawPreferenceLimit = 80 }, { $0.rawPreferenceEnabled = nil },
            { $0.rawPreferenceEnabled = 0 },
            { $0.registrations = [] }, { $0.level = 78 }, { $0.level = 86 },
            { $0.adapterPresent = false }, { $0.batteryCurrent = -.infinity },
            { $0.batteryCurrent = -0.05 }, { $0.adapterPower = .nan },
            { $0.competingController = true }, { $0.calibrationActive = true }
        ]
        for change in changes {
            var e = try make()
            XCTAssertFalse(try observe(&e, 0, update: 0))
            XCTAssertFalse(try observe(&e, 4, update: 4, change: change))
            for t in [8.0, 12, 16, 20] { XCTAssertFalse(try observe(&e, t, update: 8)) }
            XCTAssertTrue(try observe(&e, 24, update: 24))
        }
    }
    func testDeadlineAndClockFaultsAreTerminal() throws {
        var expired = try make()
        XCTAssertThrowsError(try observe(&expired, 150, update: 150))
        XCTAssertThrowsError(try observe(&expired, 151, update: 151))
        for rollback in [true, false] {
            var e = try make()
            XCTAssertFalse(try observe(&e, 4, update: 4))
            XCTAssertThrowsError(try observe(&e, rollback ? 3 : 8, update: 8) {
                if !rollback { $0.wallDate = self.wall.addingTimeInterval(20) }
            })
            XCTAssertThrowsError(try observe(&e, 24, update: 24))
        }
        XCTAssertThrowsError(try E(startedWall: wall, startedContinuous: .nan))
        XCTAssertThrowsError(try E(startedWall: Date(timeIntervalSince1970: .nan), startedContinuous: 0))
    }
}

final class BatteryPreferences79RecoveryEvidenceTests: XCTestCase {
    private typealias Evidence = BatteryPreferences79RecoveryEvidence
    private typealias Sample = BatteryPreferences79Transaction.Observation
    private let wall = Date(timeIntervalSinceReferenceDate: 10_000)
    private let continuous: TimeInterval = 1_000

    private func make() throws -> Evidence { try Evidence(startedWall: wall, startedContinuous: continuous) }
    private func sample(_ elapsed: TimeInterval) -> Sample {
        .init(nativeLimit: 80, nativeEnabled: 1, registrations: [80], level: 80,
              adapterPresent: true, batteryCurrent: 0, adapterPower: 20, wallDate: wall.addingTimeInterval(elapsed))
    }
    private func observe(_ evidence: inout Evidence, _ elapsed: TimeInterval,
                         update: TimeInterval? = nil, change: (inout Sample) -> Void = { _ in }) throws -> Bool {
        var value = sample(elapsed); change(&value)
        return try evidence.observe(value, updateTime: wall.addingTimeInterval(update ?? elapsed), now: continuous + elapsed)
    }
    private func failure(_ error: Error, _ expected: Evidence.Failure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? Evidence.Failure, expected, file: file, line: line)
    }

    func testTwoIncreasingUpdatesAndFifteenSecondsAreBothRequired() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        XCTAssertFalse(try observe(&evidence, 7.5))
        XCTAssertFalse(try observe(&evidence, 14.999))
        XCTAssertTrue(try observe(&evidence, 15))
    }

    func testDuplicateRegistrationsAreAllowedButRepeatedUpdatesCannotComplete() throws {
        var evidence = try make()
        for elapsed in stride(from: 0.0, through: 90.0, by: 5.0) {
            XCTAssertFalse(try observe(&evidence, elapsed, update: 0) { $0.registrations = [80, 80, 80] })
        }
        XCTAssertTrue(try observe(&evidence, 90.5, update: 0.5) { $0.registrations = [80, 80] })
    }

    func testPhysicalMismatchAndEveryUnknownNativeGetterRestartTheStableSegment() throws {
        let changes: [(inout Sample) -> Void] = [
            { $0.nativeLimit = 79 }, { $0.nativeLimit = nil }, { $0.nativeEnabled = 0 }, { $0.nativeEnabled = nil },
            { $0.nativeLimit = nil; $0.nativeEnabled = nil }, { $0.registrations = [] },
            { $0.registrations = [79] }, { $0.registrations = [80, 79] }, { $0.registrations = [80, 85, 80] },
            { $0.adapterPresent = false }, { $0.adapterPower = 1 }, { $0.batteryCurrent = -0.050001 },
            { $0.level = -0.0001 }, { $0.level = 100.0001 }, { $0.competingController = true }, { $0.calibrationActive = true }
        ]
        for change in changes {
            var evidence = try make()
            XCTAssertFalse(try observe(&evidence, 0))
            XCTAssertFalse(try observe(&evidence, 5, change: change))
            XCTAssertFalse(try observe(&evidence, 6))
            XCTAssertFalse(try observe(&evidence, 14))
            XCTAssertFalse(try observe(&evidence, 20.999))
            XCTAssertTrue(try observe(&evidence, 21))
        }
    }

    func testNaNAndEitherInfinityInPhysicalNumbersNeverCountAsEvidence() throws {
        for invalid in [Double.nan, .infinity, -.infinity] {
            let changes: [(inout Sample) -> Void] = [
                { $0.level = invalid }, { $0.adapterPower = invalid }, { $0.batteryCurrent = invalid }
            ]
            for change in changes {
                var evidence = try make()
                XCTAssertFalse(try observe(&evidence, 0))
                XCTAssertFalse(try observe(&evidence, 5, change: change))
                XCTAssertFalse(try observe(&evidence, 6))
                XCTAssertFalse(try observe(&evidence, 13.5))
                XCTAssertTrue(try observe(&evidence, 21))
            }
        }
    }

    func testFiniteLevelAndPowerThresholdBoundaries() throws {
        for level in [0.0, 100] {
            var evidence = try make()
            let boundary: (inout Sample) -> Void = { $0.level = level; $0.batteryCurrent = -0.05; $0.adapterPower = 1.000001 }
            XCTAssertFalse(try observe(&evidence, 0, change: boundary))
            XCTAssertFalse(try observe(&evidence, 8, change: boundary))
            XCTAssertTrue(try observe(&evidence, 15, change: boundary))
        }
    }

    func testMissingUpdateRestartsRatherThanReusingEarlierDistinctUpdates() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        XCTAssertFalse(try observe(&evidence, 7))
        XCTAssertFalse(try evidence.observe(sample(8), updateTime: nil, now: continuous + 8))
        XCTAssertFalse(try observe(&evidence, 9))
        XCTAssertFalse(try observe(&evidence, 17, update: 9))
        XCTAssertFalse(try observe(&evidence, 23, update: 9))
        XCTAssertTrue(try observe(&evidence, 24))
    }

    func testOldFutureAndNonfiniteUpdateDatesResetEvidence() throws {
        let invalidDates: [Date] = [wall.addingTimeInterval(-0.001), wall.addingTimeInterval(7.001),
                                   Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity),
                                   Date(timeIntervalSinceReferenceDate: -.infinity)]
        for date in invalidDates {
            var evidence = try make()
            XCTAssertFalse(try observe(&evidence, 0))
            XCTAssertFalse(try evidence.observe(sample(5), updateTime: date, now: continuous + 5))
            XCTAssertFalse(try observe(&evidence, 6))
            XCTAssertFalse(try observe(&evidence, 14))
            XCTAssertTrue(try observe(&evidence, 21))
        }
    }

    func testFreshnessNinetySecondsAndFutureTwoSecondsAreInclusive() throws {
        var boundary = try make()
        for elapsed in stride(from: 0.0, through: 84.0, by: 7.0) {
            XCTAssertFalse(try observe(&boundary, elapsed, update: 0))
        }
        XCTAssertTrue(try observe(&boundary, 91, update: 1))
        var stale = try make()
        for elapsed in stride(from: 0.0, through: 84.0, by: 7.0) {
            XCTAssertFalse(try observe(&stale, elapsed, update: 0))
        }
        XCTAssertFalse(try observe(&stale, 91, update: 0.999))
        XCTAssertFalse(try observe(&stale, 92))
        XCTAssertFalse(try observe(&stale, 100))
        XCTAssertTrue(try observe(&stale, 107))
        var future = try make()
        XCTAssertFalse(try observe(&future, 0, update: 2))
        XCTAssertFalse(try observe(&future, 8, update: 2))
        XCTAssertTrue(try observe(&future, 15, update: 17))
    }

    func testUpdateRegressionCannotLowerTheWatermarkOrReuseAnOldSegment() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        XCTAssertFalse(try observe(&evidence, 7, update: 0))
        XCTAssertFalse(try observe(&evidence, 10))
        XCTAssertFalse(try observe(&evidence, 11, update: 9))
        XCTAssertFalse(try observe(&evidence, 12, update: 9.5))
        XCTAssertFalse(try observe(&evidence, 13, update: 10))
        XCTAssertFalse(try observe(&evidence, 21, update: 10))
        XCTAssertFalse(try observe(&evidence, 28, update: 10))
        XCTAssertTrue(try observe(&evidence, 29))
    }

    func testAValidTimestampOnBadPhysicalDataStillPreventsLaterReplays() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        XCTAssertFalse(try observe(&evidence, 7, update: 0))
        XCTAssertFalse(try observe(&evidence, 10) { $0.batteryCurrent = -1 })
        XCTAssertFalse(try observe(&evidence, 11, update: 9))
        XCTAssertFalse(try observe(&evidence, 12, update: 10))
        XCTAssertFalse(try observe(&evidence, 20, update: 10))
        XCTAssertFalse(try observe(&evidence, 27, update: 10))
        XCTAssertTrue(try observe(&evidence, 28))
    }

    func testClockInitializationAndNonfiniteObservationTimesAreRejected() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try Evidence(startedWall: wall, startedContinuous: value)) { self.failure($0, .invalidClock) }
            XCTAssertThrowsError(try Evidence(startedWall: Date(timeIntervalSinceReferenceDate: value), startedContinuous: continuous)) { self.failure($0, .invalidClock) }
            var now = try make()
            XCTAssertThrowsError(try now.observe(sample(0), updateTime: wall, now: value)) { self.failure($0, .invalidClock) }
            var date = try make(), bad = sample(0); bad.wallDate = Date(timeIntervalSinceReferenceDate: value)
            XCTAssertThrowsError(try date.observe(bad, updateTime: wall, now: continuous)) { self.failure($0, .invalidClock) }
        }
        XCTAssertThrowsError(try Evidence(startedWall: wall, startedContinuous: -1))
    }
    func testWallOrContinuousRollbackIsTerminalEvenAfterOtherwiseValidSamples() throws {
        for wallRollback in [true, false] {
            var evidence = try make()
            XCTAssertFalse(try observe(&evidence, 10))
            let value = sample(wallRollback ? 9.999 : 11)
            XCTAssertThrowsError(try evidence.observe(value, updateTime: value.wallDate, now: continuous + (wallRollback ? 11 : 9.999))) { self.failure($0, .clockChanged) }
            XCTAssertThrowsError(try observe(&evidence, 30)) { self.failure($0, .clockChanged) }
        }
        var first = try make()
        XCTAssertThrowsError(try first.observe(sample(-0.001), updateTime: wall, now: continuous)) { self.failure($0, .clockChanged) }
    }
    func testWallJumpOverFiveSecondsIsTerminalAndExactFiveIsAllowed() throws {
        for shift in [-5.0001, 5.0001] {
            var evidence = try make()
            let value = sample(10 + shift)
            XCTAssertThrowsError(try evidence.observe(value, updateTime: value.wallDate, now: continuous + 10)) { self.failure($0, .clockChanged) }
            XCTAssertThrowsError(try observe(&evidence, 40)) { self.failure($0, .clockChanged) }
        }
        var exact = try make()
        let first = sample(5), middle = sample(13), second = sample(20)
        XCTAssertFalse(try exact.observe(first, updateTime: first.wallDate, now: continuous))
        XCTAssertFalse(try exact.observe(middle, updateTime: middle.wallDate, now: continuous + 8))
        XCTAssertTrue(try exact.observe(second, updateTime: second.wallDate, now: continuous + 15))
    }
    func testDeadlineIsExclusiveAndCannotBeExtendedByResetsOrSleep() throws {
        var atDeadline = try make()
        XCTAssertFalse(try observe(&atDeadline, 165))
        XCTAssertThrowsError(try observe(&atDeadline, 180)) { self.failure($0, .expired) }
        XCTAssertThrowsError(try observe(&atDeadline, 180.001)) { self.failure($0, .expired) }
        var beforeDeadline = try make()
        XCTAssertFalse(try observe(&beforeDeadline, 164.999))
        XCTAssertFalse(try observe(&beforeDeadline, 172.999))
        XCTAssertTrue(try observe(&beforeDeadline, 179.999))
        var slept = try make()
        XCTAssertFalse(try observe(&slept, 0))
        XCTAssertThrowsError(try observe(&slept, 181)) { self.failure($0, .expired) }
        var reset = try make()
        XCTAssertFalse(try observe(&reset, 160) { $0.registrations = [] })
        XCTAssertThrowsError(try observe(&reset, 180)) { self.failure($0, .expired) }
    }

    func testClockCannotBeRebasedToHideSleepFromTheContinuousDeadline() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        let slept = sample(60)
        XCTAssertThrowsError(try evidence.observe(slept, updateTime: slept.wallDate, now: continuous + 1)) { self.failure($0, .clockChanged) }
    }
    func testEightSecondGapIsAllowedButReadinessCannotSurviveALongerGap() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        XCTAssertFalse(try observe(&evidence, 8))
        XCTAssertTrue(try observe(&evidence, 15))
        XCTAssertFalse(try observe(&evidence, 23.001))
        XCTAssertFalse(try observe(&evidence, 30))
        XCTAssertFalse(try observe(&evidence, 38))
        XCTAssertTrue(try observe(&evidence, 39))
    }
    func testSleepOrLongQueuedWorkerCannotBridgeMissingPhysicalObservations() throws {
        for gap in [8.001, 15.0, 46.0] {
            var evidence = try make()
            XCTAssertFalse(try observe(&evidence, 0))
            // Both clocks and fresh UpdateTime advanced normally. This must
            // still start over instead of treating the empty interval as stable.
            XCTAssertFalse(try observe(&evidence, gap))
            XCTAssertFalse(try observe(&evidence, gap + 7))
            XCTAssertFalse(try observe(&evidence, gap + 14))
            XCTAssertTrue(try observe(&evidence, gap + 16))
        }
    }
    func testGapResetPreservesTheUpdateWatermarkAndOriginalDeadline() throws {
        var evidence = try make()
        XCTAssertFalse(try observe(&evidence, 0))
        XCTAssertFalse(try observe(&evidence, 7))
        XCTAssertFalse(try observe(&evidence, 20, update: 6))
        XCTAssertFalse(try observe(&evidence, 21, update: 6.5))
        XCTAssertFalse(try observe(&evidence, 22, update: 7))
        XCTAssertFalse(try observe(&evidence, 30, update: 7))
        XCTAssertFalse(try observe(&evidence, 37, update: 7))
        XCTAssertTrue(try observe(&evidence, 38))
        var bounded = try make()
        XCTAssertFalse(try observe(&bounded, 160))
        XCTAssertFalse(try observe(&bounded, 168))
        XCTAssertFalse(try observe(&bounded, 177))
        XCTAssertFalse(try observe(&bounded, 179.999))
        XCTAssertThrowsError(try observe(&bounded, 180)) { self.failure($0, .expired) }
    }
    func testRetainedSixtySecondContextCadenceCompletesWithOneToThreeSecondPolling() throws {
        // Actual distinctBatteryUpdateTimes from the retained r22 read-only
        // post-release continuation; no fixture file or hardware is read here.
        let first = Date(timeIntervalSince1970: 1_793_541_125)
        let second = Date(timeIntervalSince1970: 1_793_541_185)
        XCTAssertEqual(second.timeIntervalSince(first), 60)
        let began = first.addingTimeInterval(-30)
        var evidence = try Evidence(startedWall: began, startedContinuous: continuous)
        var elapsed = 0.0, index = 0
        while elapsed <= 90 {
            var value = sample(elapsed); value.wallDate = began.addingTimeInterval(elapsed)
            let update = elapsed < 30 ? first.addingTimeInterval(-60) : elapsed < 90 ? first : second
            let ready = try evidence.observe(value, updateTime: update, now: continuous + elapsed)
            XCTAssertEqual(ready, elapsed == 90)
            elapsed += [1.0, 2.0, 3.0][index % 3]; index += 1
        }
    }
    func testFirstPostRestoreContextAtSixtyAndSecondAtOneTwentyCanComplete() throws {
        var evidence = try make()
        for elapsed in stride(from: 0.0, through: 120.0, by: 3.0) {
            let update = elapsed < 60 ? -1.0 : elapsed < 120 ? 60.0 : 120.0
            let ready = try observe(&evidence, elapsed, update: update)
            XCTAssertEqual(ready, elapsed == 120)
        }
    }
}
#endif
