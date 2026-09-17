import XCTest
@testable import SuperIsland

final class WindowDragHoverGateTests: XCTestCase {
    func testHeldHoverBeforeWindowMovementInvalidatesQueuedActivation() {
        var gate = WindowDragHoverGate()
        gate.recordHover(true)
        let queued = gate.generation
        gate.suppressUntilPointerExit()
        XCTAssertFalse(gate.isDragging)
        XCTAssertFalse(gate.permitsActivation(generation: queued))
        XCTAssertFalse(gate.recordHover(true))
        XCTAssertFalse(gate.setDragging(false))
        XCTAssertTrue(gate.requiresPointerExit)
        gate.recordHover(false)
        XCTAssertTrue(gate.recordHover(true))
        XCTAssertTrue(gate.permitsActivation(generation: gate.generation))
    }

    func testClampedDragMayBecomeAConfirmedMoveWithoutReplayingHover() {
        var gate = WindowDragHoverGate()
        gate.suppressUntilPointerExit()
        let clamped = gate.generation
        gate.setDragging(true)
        XCTAssertTrue(gate.isSuppressed)
        gate.recordHover(false)
        gate.setDragging(false)
        XCTAssertFalse(gate.isSuppressed)
        XCTAssertFalse(gate.permitsActivation(generation: clamped))
        XCTAssertTrue(gate.recordHover(true))
    }

    func testQueuedHoverCannotActivateAfterDragStarts() {
        var gate = WindowDragHoverGate()
        XCTAssertTrue(gate.recordHover(true))
        let queued = gate.generation
        XCTAssertTrue(gate.permitsActivation(generation: queued))

        XCTAssertTrue(gate.setDragging(true))
        XCTAssertTrue(gate.isSuppressed)
        XCTAssertFalse(gate.permitsActivation(generation: queued))
        XCTAssertFalse(gate.permitsActivation(generation: gate.generation))
    }

    func testHoverQueuedBeforeOrDuringDragCannotReplayAfterReleaseOutside() {
        var gate = WindowDragHoverGate()
        let beforeDrag = gate.generation
        gate.setDragging(true)
        let duringDrag = gate.generation
        gate.setDragging(false)

        XCTAssertFalse(gate.isSuppressed)
        XCTAssertFalse(gate.permitsActivation(generation: beforeDrag))
        XCTAssertFalse(gate.permitsActivation(generation: duringDrag))
        XCTAssertTrue(gate.recordHover(true))
        XCTAssertTrue(gate.permitsActivation(generation: gate.generation))
    }

    func testPointerEnteringAndLeavingDuringDragNeverEnablesHover() {
        var gate = WindowDragHoverGate()
        gate.setDragging(true)
        XCTAssertFalse(gate.recordHover(true))
        XCTAssertTrue(gate.isPointerInside)
        XCTAssertFalse(gate.recordHover(false))
        XCTAssertFalse(gate.isPointerInside)
        XCTAssertFalse(gate.requiresPointerExit)
        XCTAssertTrue(gate.isDragging)
        XCTAssertFalse(gate.recordHover(true))
        XCTAssertFalse(gate.permitsActivation(generation: gate.generation))
    }

    func testReleaseInsideNeedsExitAndFreshEntry() {
        var gate = WindowDragHoverGate()
        gate.setDragging(true)
        gate.recordHover(true)
        gate.setDragging(false)

        XCTAssertTrue(gate.isPointerInside)
        XCTAssertTrue(gate.requiresPointerExit)
        XCTAssertTrue(gate.isSuppressed)
        XCTAssertFalse(gate.recordHover(true), "Repeated inside notifications are not a fresh entry")
        let releasedInside = gate.generation
        XCTAssertFalse(gate.permitsActivation(generation: releasedInside))

        XCTAssertTrue(gate.recordHover(false))
        XCTAssertFalse(gate.requiresPointerExit)
        XCTAssertFalse(gate.permitsActivation(generation: releasedInside))
        XCTAssertTrue(gate.recordHover(true))
        XCTAssertTrue(gate.permitsActivation(generation: gate.generation))
    }

    func testReleaseOutsideAllowsNormalNextEntry() {
        var gate = WindowDragHoverGate()
        gate.setDragging(true)
        gate.recordHover(true)
        gate.recordHover(false)
        gate.setDragging(false)

        XCTAssertFalse(gate.isPointerInside)
        XCTAssertFalse(gate.requiresPointerExit)
        XCTAssertTrue(gate.recordHover(true))
        XCTAssertTrue(gate.permitsActivation(generation: gate.generation))
    }

    func testDuplicateDragTransitionsDoNotResetReleaseBarrier() {
        var gate = WindowDragHoverGate()
        XCTAssertFalse(gate.setDragging(false))
        XCTAssertEqual(gate.generation, 0)
        XCTAssertTrue(gate.setDragging(true))
        let draggingGeneration = gate.generation
        XCTAssertFalse(gate.setDragging(true))
        XCTAssertEqual(gate.generation, draggingGeneration)

        gate.recordHover(true)
        XCTAssertTrue(gate.setDragging(false))
        let releaseGeneration = gate.generation
        XCTAssertFalse(gate.setDragging(false))
        XCTAssertEqual(gate.generation, releaseGeneration)
        XCTAssertTrue(gate.requiresPointerExit)
        XCTAssertTrue(gate.isPointerInside)
    }

    func testNewDragClearsOldExitBarrierButRetainsPointerLocation() {
        var gate = WindowDragHoverGate()
        gate.recordHover(true)
        gate.setDragging(true)
        gate.setDragging(false)
        XCTAssertTrue(gate.requiresPointerExit)

        gate.setDragging(true)
        XCTAssertFalse(gate.requiresPointerExit)
        XCTAssertTrue(gate.isPointerInside)
        XCTAssertTrue(gate.isSuppressed)
        gate.setDragging(false)
        XCTAssertTrue(gate.requiresPointerExit)
    }

    func testPointerExitInvalidatesQueuedOrdinaryHover() {
        var gate = WindowDragHoverGate()
        gate.recordHover(true)
        let queued = gate.generation
        gate.recordHover(false)
        gate.recordHover(true)

        XCTAssertFalse(gate.permitsActivation(generation: queued))
        XCTAssertTrue(gate.permitsActivation(generation: gate.generation))
    }
}

final class WindowDragReleaseRecoveryTests: XCTestCase {
    func testHeldButtonNeverTimesOutEvenForLongDrags() {
        var recovery = WindowDragReleaseRecovery()
        for time: TimeInterval in [0, 1, 30, 300, 3_600, 86_400] {
            XCTAssertFalse(recovery.shouldCancel(buttonIsDown: true, now: time))
        }
    }

    func testShortReleaseGapDoesNotCancel() {
        var recovery = WindowDragReleaseRecovery()
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0.1))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0.299))
    }

    func testContinuouslyReleasedButtonCancelsAfterGrace() {
        var recovery = WindowDragReleaseRecovery()
        XCTAssertEqual(recovery.releaseGraceInterval, 0.3)
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0))
        XCTAssertTrue(recovery.shouldCancel(buttonIsDown: false, now: 0.3))
        XCTAssertTrue(recovery.shouldCancel(buttonIsDown: false, now: 1))
    }

    func testNewButtonDownStartsANewReleaseGracePeriod() {
        var recovery = WindowDragReleaseRecovery()
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0.2))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: true, now: 0.25))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0.4))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0.6))
        XCTAssertTrue(recovery.shouldCancel(buttonIsDown: false, now: 0.71))
    }

    func testExplicitResetDoesNotCarryReleaseTimeToNextDrag() {
        var recovery = WindowDragReleaseRecovery()
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 0))
        XCTAssertTrue(recovery.shouldCancel(buttonIsDown: false, now: 1))
        recovery.reset()
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 10))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 10.2))
        XCTAssertTrue(recovery.shouldCancel(buttonIsDown: false, now: 10.31))
    }

    func testLongDragDoesNotConsumeTheReleaseGracePeriod() {
        var recovery = WindowDragReleaseRecovery()
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: true, now: 0))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: true, now: 3_600))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 3_601))
        XCTAssertFalse(recovery.shouldCancel(buttonIsDown: false, now: 3_601.2))
        XCTAssertTrue(recovery.shouldCancel(buttonIsDown: false, now: 3_601.31))
    }
}
