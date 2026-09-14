import XCTest
@testable import SuperIsland

final class MissionControlRecoveryTests: XCTestCase {
    func testMissedNotificationCanRecoverWithoutSchedulingFullDesktopInspection() throws {
        XCTAssertFalse(MissionControlInspectionPolicy.shouldSchedule(
            force: false, missionControlHierarchyObserved: false
        ))
        var recovery = MissionControlRootRecovery()
        let request = try XCTUnwrap(recovery.begin(now: 0))
        XCTAssertTrue(recovery.finish(
            request, result: .present, now: 10_000_000,
            elapsedNanoseconds: 10_000_000, canPublish: true
        ))
    }

    func testNegativeAndIncompleteProbesCannotEstablishMissionControl() throws {
        for result in [MissionControlRootPresence.absent, .unavailable] {
            var recovery = MissionControlRootRecovery()
            let request = try XCTUnwrap(recovery.begin(now: 0))
            XCTAssertFalse(recovery.finish(
                request, result: result, now: 10_000_000,
                elapsedNanoseconds: 10_000_000, canPublish: true
            ))
            XCTAssertNil(recovery.inFlight)
            XCTAssertNil(recovery.begin(now: 249_999_999))
        }
    }

    func testProbeThrottleStartsAfterCompletionAndFailureBacksOff() throws {
        var recovery = MissionControlRootRecovery()
        let first = try XCTUnwrap(recovery.begin(now: 0))
        XCTAssertFalse(recovery.finish(
            first, result: .absent, now: 20_000_000,
            elapsedNanoseconds: 20_000_000, canPublish: true
        ))
        XCTAssertNil(recovery.begin(now: 269_999_999))
        let second = try XCTUnwrap(recovery.begin(now: 270_000_000))
        XCTAssertFalse(recovery.finish(
            second, result: .unavailable, now: 290_000_000,
            elapsedNanoseconds: 20_000_000, canPublish: true
        ))
        XCTAssertEqual(recovery.delayNanoseconds(now: 290_000_000), 1_000_000_000)
        XCTAssertNil(recovery.begin(now: 1_289_999_999))
        XCTAssertNotNil(recovery.begin(now: 1_290_000_000))
    }

    func testSlowPositiveProbeCannotArmTargetResolverAndUsesLongerCooldown() throws {
        var recovery = MissionControlRootRecovery()
        let request = try XCTUnwrap(recovery.begin(now: 0))
        XCTAssertFalse(recovery.finish(
            request, result: .present, now: 121_000_000,
            elapsedNanoseconds: 121_000_000, canPublish: true
        ))
        XCTAssertEqual(recovery.delayNanoseconds(now: 121_000_000), 2_000_000_000)
    }

    func testInvalidationKeepsSingleFlightUntilOldReplyDrains() throws {
        var recovery = MissionControlRootRecovery()
        let request = try XCTUnwrap(recovery.begin(now: 0))
        recovery.invalidate()
        // Stop, Space changes and suppression all invalidate the same session
        // token; none can create a queue of new probes behind a stalled AX call.
        XCTAssertNil(recovery.begin(now: 5_000_000_000))
        XCTAssertFalse(recovery.finish(
            request, result: .present, now: 5_000_000_000,
            elapsedNanoseconds: 20_000_000, canPublish: true
        ))
        XCTAssertNil(recovery.inFlight)
        let fresh = try XCTUnwrap(recovery.begin(now: 5_250_000_000))
        XCTAssertTrue(recovery.finish(
            fresh, result: .present, now: 5_260_000_000,
            elapsedNanoseconds: 10_000_000, canPublish: true
        ))
    }

    func testDisabledOrSuppressedPublisherCannotAcceptPositiveReply() throws {
        var recovery = MissionControlRootRecovery()
        let request = try XCTUnwrap(recovery.begin(now: 0))
        XCTAssertFalse(recovery.finish(
            request, result: .present, now: 10_000_000,
            elapsedNanoseconds: 10_000_000, canPublish: false
        ))
        XCTAssertNil(recovery.inFlight)
    }

    func testDuplicateOldReplyCannotReleaseOrDelayNewProbe() throws {
        var recovery = MissionControlRootRecovery()
        let first = try XCTUnwrap(recovery.begin(now: 0))
        _ = recovery.finish(
            first, result: .absent, now: 10_000_000,
            elapsedNanoseconds: 10_000_000, canPublish: true
        )
        let second = try XCTUnwrap(recovery.begin(now: 260_000_000))
        let priorDeadline = recovery.nextAllowedNanoseconds
        XCTAssertFalse(recovery.finish(
            first, result: .present, now: 300_000_000,
            elapsedNanoseconds: 200_000_000, canPublish: true
        ))
        XCTAssertEqual(recovery.inFlight, second)
        XCTAssertEqual(recovery.nextAllowedNanoseconds, priorDeadline)
        XCTAssertTrue(recovery.finish(
            second, result: .present, now: 300_000_000,
            elapsedNanoseconds: 40_000_000, canPublish: true
        ))
    }
}
