import CoreGraphics
import XCTest
@testable import SuperIsland

@MainActor
final class WindowFullScreenDisplayMoveTests: XCTestCase {
    private typealias Readiness = WindowFullScreenDisplayReadiness
    private let targetBounds = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    private let movedFrame = CGRect(x: 1612, y: 100, width: 1000, height: 700)
    private let sourceFrame = CGRect(x: 100, y: 100, width: 1000, height: 700)

    func testExitWaitsForActionableWindowAndRestoredGeometry() async {
        let result = await run(placement: .stableWindowed) { time in
            let frame = time < 0.24 ? self.targetBounds : self.movedFrame
            return self.observation(frame: frame, actionable: time >= 0.16)
        }
        XCTAssertEqual(result.outcome, .ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.24 + Readiness.preparationQuietDuration)
        XCTAssertLessThan(result.elapsed, 1)
    }

    func testMoveDoesNotAdvanceOnOneEarlyTargetFrameBeforeChromeRestoresSource() async {
        let result = await run { time in
            if time > 0 && time < 0.40 {
                return self.observation(frame: self.sourceFrame, displayID: 1)
            }
            return self.observation()
        }
        XCTAssertEqual(result.outcome, .ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.40 + Readiness.preparationQuietDuration)
    }

    func testEnteredFullScreenAllowsOldSourceFrameToCatchUpBeforeFinalVerification() async {
        let result = await run(fullScreen: true, finalStage: true) { time in
            self.observation(
                fullScreen: true,
                frame: time < 0.24 ? self.sourceFrame : self.targetBounds,
                displayID: time < 0.24 ? 1 : 2
            )
        }
        XCTAssertEqual(result.outcome, .ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 4.24)
        XCTAssertLessThan(result.elapsed, 5)
    }

    func testPersistentWrongDisplayTimesOutWithoutAdmittingNextStage() async {
        let result = await run { _ in self.observation(frame: self.sourceFrame, displayID: 1) }
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(result.elapsed, Readiness.preparationMaximumDuration)
        XCTAssertLessThan(result.elapsed, Readiness.preparationMaximumDuration + 0.09)
    }

    func testTargetCenterAloneDoesNotAcceptWindowStraddlingTwoDisplays() async {
        let result = await run(fullScreen: true, finalStage: true) { _ in
            self.observation(fullScreen: true, frame: CGRect(x: 1450, y: 100, width: 1000, height: 700))
        }
        XCTAssertEqual(result.outcome, .timedOut)
    }

    func testTargetDisconnectedDuringQuietIntervalStopsBeforeReenteringFullScreen() async {
        let result = await run(targetAvailable: { $0 < 0.24 }) { _ in self.observation() }
        XCTAssertEqual(result.outcome, .targetUnavailable)
        XCTAssertLessThan(result.elapsed, 0.4)
    }

    func testRecoveryRequestTakesPrecedenceOverAReadyFrame() async {
        let result = await run(shouldRecover: { $0 >= 0.16 }) { _ in self.observation() }
        XCTAssertEqual(result.outcome, .recoveryRequested)
        XCTAssertEqual(result.elapsed, 0.16, accuracy: 0.001)
    }

    func testReplacedGenerationStopsWithoutAllowingNextMutation() async {
        let result = await run(isCurrent: { $0 < 0.16 }) { _ in self.observation() }
        XCTAssertEqual(result.outcome, .interrupted)
        XCTAssertEqual(result.elapsed, 0.16, accuracy: 0.001)
    }

    func testCancelledPauseDoesNotBecomeAStableResult() async {
        let result = await run(pauseSucceeds: false) { _ in self.observation() }
        XCTAssertEqual(result.outcome, .interrupted)
        XCTAssertEqual(result.elapsed, 0)
    }

    func testMissingExactObservationResetsWholeQuietInterval() async {
        let result = await run { time in
            time >= 0.24 && time < 0.40 ? nil : self.observation()
        }
        XCTAssertEqual(result.outcome, .ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.40 + Readiness.preparationQuietDuration)
    }

    func testSlowCumulativeFrameDriftCannotPassByStayingWithinPreviousSampleTolerance() async {
        let result = await run { time in
            self.observation(frame: self.movedFrame.offsetBy(dx: CGFloat(Int(time / 0.08)), dy: 0))
        }
        XCTAssertEqual(result.outcome, .timedOut)
    }

    func testExitAllowsRestoredOversizedFrameBeforeDestinationClampsIt() async {
        // The pre-fullscreen window may have straddled displays. Exit readiness
        // must not require destination placement before the move is attempted.
        let result = await run(placement: .stableWindowed, targetAvailable: { _ in false }) { _ in
            self.observation(frame: CGRect(x: -100, y: -50, width: 2200, height: 1200), displayID: 1)
        }
        XCTAssertEqual(result.outcome, .ready)
        XCTAssertLessThan(result.elapsed, 1)
    }

    func testLateFullScreenFlagReversalRestartsFinalFourSecondVerification() async {
        let result = await run(fullScreen: true, finalStage: true) { time in
            self.observation(fullScreen: !(time >= 2 && time < 2.24), frame: self.targetBounds)
        }
        XCTAssertEqual(result.outcome, .ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 6.24)
    }

    func testMinimumSizeWindowCanEnterTargetFullScreenButMustNormalizeBeforeCommit() async {
        let oversized = CGRect(x: 1512, y: 0, width: 4000, height: 1200)
        let moved = await run { _ in self.observation(frame: oversized, displayID: nil) }
        XCTAssertEqual(moved.outcome, .ready)

        let entered = await run(fullScreen: true, finalStage: true) { time in
            self.observation(fullScreen: true,
                             frame: time < 0.24 ? oversized : self.targetBounds,
                             displayID: time < 0.24 ? nil : 2)
        }
        XCTAssertEqual(entered.outcome, .ready)
        XCTAssertGreaterThanOrEqual(entered.elapsed, 4.24)

        let stillOversized = await run(fullScreen: true, finalStage: true) { _ in
            self.observation(fullScreen: true, frame: oversized, displayID: nil)
        }
        XCTAssertEqual(stillOversized.outcome, .timedOut)
    }

    private func observation(
        fullScreen: Bool = false,
        frame: CGRect? = nil,
        displayID: CGDirectDisplayID? = 2,
        actionable: Bool = true
    ) -> Readiness.Observation {
        .init(isFullScreen: fullScreen, displayID: displayID,
              frame: frame ?? movedFrame, isActionable: actionable)
    }

    private func run(
        fullScreen: Bool = false,
        finalStage: Bool = false,
        placement: Readiness.PlacementRequirement? = nil,
        targetAvailable: (TimeInterval) -> Bool = { _ in true },
        shouldRecover: (TimeInterval) -> Bool = { _ in false },
        isCurrent: (TimeInterval) -> Bool = { _ in true },
        pauseSucceeds: Bool = true,
        observations: (TimeInterval) -> Readiness.Observation?
    ) async -> (outcome: Readiness.Outcome, elapsed: TimeInterval) {
        var elapsed: TimeInterval = 0
        let outcome = await Readiness.wait(
            expectedFullScreen: fullScreen, expectedDisplayID: 2,
            placement: placement ?? (finalStage ? .targetContained : .targetAnchored),
            maximumDuration: finalStage ? 8 : Readiness.preparationMaximumDuration,
            quietDuration: finalStage ? 4 : Readiness.preparationQuietDuration,
            isCurrent: { isCurrent(elapsed) },
            shouldRecover: { shouldRecover(elapsed) },
            targetBounds: { targetAvailable(elapsed) ? self.targetBounds : nil },
            observe: { observations(elapsed) },
            now: { elapsed },
            pause: {
                if pauseSucceeds { elapsed += 0.08 }
                return pauseSucceeds
            }
        )
        return (outcome, elapsed)
    }
}
