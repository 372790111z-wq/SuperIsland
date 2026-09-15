import XCTest
@testable import SuperIsland

final class MissionControlRecoveryTests: XCTestCase {
    func testMissingSceneRootRemainsOutsideThroughRealResolverRouting() {
        let reason = "scene-marker-not-found-mc-root-v2"
        XCTAssertEqual(MissionControlSceneResolverFixture.resolve(.outside(reason)),
                       .init(state: "outside", reason: reason))
    }

    func testAmbiguousSceneRootCannotBecomeAnOrdinaryApplicationTarget() {
        let reason = "scene-marker-not-found-ambiguous-mc-root-v3"
        XCTAssertEqual(MissionControlSceneResolverFixture.resolve(.outside(reason)),
                       .init(state: "outside", reason: reason))
    }

    func testPresentButIncompleteSceneKeepsItsResolverOutcome() {
        XCTAssertEqual(MissionControlSceneResolverFixture.resolve(
            .indeterminate("scene-mc-root-stabilizing")),
            .init(state: "indeterminate", reason: "scene-mc-root-stabilizing"))
        XCTAssertEqual(MissionControlSceneResolverFixture.resolve(
            .unresolved("scene-no-exact-target")),
            .init(state: "unresolved", reason: "scene-no-exact-target"))
    }

    @MainActor
    func testOutsideCompletionClearsSessionTargetsAndEveryPendingTask() throws {
        let fixture = try XCTUnwrap(MissionControlInteractionMonitor.TestFixture())
        defer { fixture.clearSession() }
        fixture.seedSession()
        let before = fixture.snapshot
        XCTAssertEqual(before.targetWindow, 41)
        XCTAssertEqual(before.pendingKeyboardWindow, 41)
        XCTAssertEqual(fixture.closeClickDecision(), .consumeAndTrigger)
        XCTAssertEqual(fixture.trackedWorkCancellation, Array(repeating: false, count: 6))

        fixture.finishOutside(generation: before.generation)

        let after = fixture.snapshot
        XCTAssertFalse(after.observed)
        XCTAssertFalse(after.hasEvidence)
        XCTAssertNil(after.targetWindow)
        XCTAssertNil(after.pendingKeyboardWindow)
        XCTAssertNil(after.inFlightGeneration)
        XCTAssertEqual(after.generation, before.generation + 1)
        XCTAssertEqual(after.closeGeneration, before.closeGeneration + 1)
        XCTAssertEqual(after.keyboardGeneration, before.keyboardGeneration + 1)
        XCTAssertFalse(after.inspectionPending)
        XCTAssertFalse(after.inspectionScheduled)
        XCTAssertFalse(after.rootRecoveryScheduled)
        XCTAssertFalse(after.validationScheduled)
        XCTAssertFalse(after.keyboardExpirationScheduled)
        XCTAssertEqual(after.postActionCount, 0)
        XCTAssertEqual(fixture.trackedWorkCancellation, Array(repeating: true, count: 6))
        XCTAssertEqual(fixture.closeClickDecision(), .passThrough)
    }

    @MainActor
    func testLateValidCompletionDrainsOldSlotWithoutReopeningExitedSession() throws {
        let fixture = try XCTUnwrap(MissionControlInteractionMonitor.TestFixture())
        defer { fixture.clearSession() }
        fixture.seedSession()
        let generation = fixture.snapshot.generation
        fixture.clearSession()
        XCTAssertEqual(fixture.snapshot.inFlightGeneration, generation)

        fixture.finishValid(generation: generation)

        XCTAssertNil(fixture.snapshot.inFlightGeneration)
        XCTAssertFalse(fixture.snapshot.observed)
        XCTAssertFalse(fixture.snapshot.hasEvidence)
        XCTAssertNil(fixture.snapshot.targetWindow)
        XCTAssertNil(fixture.snapshot.pendingKeyboardWindow)
        XCTAssertFalse(fixture.snapshot.inspectionScheduled)
        XCTAssertEqual(fixture.closeClickDecision(), .passThrough)
    }

    @MainActor
    func testRepeatedAwakeKeepsLatestSessionWhenOldOutsideCompletionArrives() throws {
        let fixture = try XCTUnwrap(MissionControlInteractionMonitor.TestFixture())
        defer { fixture.clearSession() }
        fixture.seedSession()
        let oldGeneration = fixture.snapshot.generation

        fixture.enterScene()
        fixture.enterScene()
        let newGeneration = fixture.snapshot.generation
        XCTAssertEqual(newGeneration, oldGeneration + 2)
        XCTAssertEqual(fixture.snapshot.inFlightGeneration, oldGeneration)
        XCTAssertTrue(fixture.snapshot.inspectionPending)
        XCTAssertFalse(fixture.snapshot.inspectionScheduled)
        fixture.installTarget(windowNumber: 42)

        fixture.finishOutside(generation: oldGeneration)

        XCTAssertEqual(fixture.snapshot.generation, newGeneration)
        XCTAssertTrue(fixture.snapshot.observed)
        XCTAssertTrue(fixture.snapshot.hasEvidence)
        XCTAssertTrue(fixture.snapshot.validationScheduled)
        XCTAssertEqual(fixture.snapshot.targetWindow, 42)
        XCTAssertEqual(fixture.snapshot.pendingKeyboardWindow, 42)
        XCTAssertNil(fixture.snapshot.inFlightGeneration)
        XCTAssertFalse(fixture.snapshot.inspectionPending)
        XCTAssertTrue(fixture.snapshot.inspectionScheduled)
        XCTAssertEqual(fixture.closeClickDecision(), .consumeAndTrigger)

        // The fresh session must still accept its own terminal result.
        fixture.beginCurrentInspection()
        fixture.finishOutside(generation: newGeneration)
        XCTAssertFalse(fixture.snapshot.observed)
        XCTAssertNil(fixture.snapshot.targetWindow)
        XCTAssertEqual(fixture.closeClickDecision(), .passThrough)
    }

    @MainActor
    func testDuplicateOldRepliesCannotReleaseNewInspectionOrClearNewTarget() throws {
        let fixture = try XCTUnwrap(MissionControlInteractionMonitor.TestFixture())
        defer { fixture.clearSession() }
        fixture.seedSession()
        let oldGeneration = fixture.snapshot.generation
        fixture.enterScene()
        fixture.finishOutside(generation: oldGeneration)
        fixture.beginCurrentInspection()
        fixture.installTarget(windowNumber: 42)
        let before = fixture.snapshot

        fixture.finishOutside(generation: oldGeneration)
        XCTAssertEqual(fixture.snapshot, before)
        fixture.finishValid(generation: oldGeneration)
        XCTAssertEqual(fixture.snapshot, before)
        XCTAssertEqual(fixture.closeClickDecision(), .consumeAndTrigger)
    }

    @MainActor
    func testOldCloseValidationReplyCannotClearNewSceneAffordanceOrKeyboardTarget() throws {
        let fixture = try XCTUnwrap(MissionControlInteractionMonitor.TestFixture())
        defer { fixture.clearSession() }
        fixture.seedSession()
        let oldCloseGeneration = fixture.snapshot.closeGeneration
        fixture.enterScene()
        fixture.installTarget(windowNumber: 42)
        let before = fixture.snapshot
        XCTAssertGreaterThan(before.closeGeneration, oldCloseGeneration)

        fixture.finishClose(generation: oldCloseGeneration)

        XCTAssertEqual(fixture.snapshot, before)
        XCTAssertEqual(fixture.closeClickDecision(), .consumeAndTrigger)
    }

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
