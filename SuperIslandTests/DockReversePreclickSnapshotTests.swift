import Foundation
import XCTest
@testable import SuperIsland

final class DockReversePreclickSnapshotTests: XCTestCase {
    private let launch = Date(timeIntervalSinceReferenceDate: 8_000)

    private func context(
        pid: Int32 = 10,
        startedAt: TimeInterval = 10,
        completedAt: TimeInterval = 10.05,
        launchDate: Date? = nil
    ) -> DockReversePreclickContext {
        DockReversePreclickContext(
            processIdentifier: pid, launchDate: launchDate ?? launch,
            startedAt: startedAt, completedAt: completedAt
        )
    }

    private func allows(
        _ evidence: DockReversePreclickContext?,
        targetPID: Int32 = 10,
        targetLaunch: Date? = nil,
        down: TimeInterval = 10.15,
        now: TimeInterval = 10.20
    ) -> Bool {
        DockReversePreclickPolicy.canMinimize(
            context: evidence,
            targetProcessIdentifier: targetPID,
            targetLaunchDate: targetLaunch ?? launch,
            mouseDownAt: down,
            now: now
        )
    }

    private func windowsToMinimize(
        before: [Int],
        after: [Int],
        evidence: DockReversePreclickContext? = nil
    ) -> [Int] {
        DockReversePreclickPolicy.windowsToMinimize(
            context: evidence ?? context(),
            visibleBefore: before,
            visibleNow: after,
            targetProcessIdentifier: 10,
            targetLaunchDate: launch,
            mouseDownAt: 10.15,
            now: 10.20,
            matches: ==
        )
    }

    func testDockRestoringPreviouslyMinimizedWindowDoesNotMakeItMinimizable() {
        XCTAssertEqual(windowsToMinimize(before: [], after: [1]), [])
    }

    func testBackgroundTargetCannotBorrowVisibleWindowsFromPriorForegroundProcess() {
        XCTAssertEqual(windowsToMinimize(before: [1], after: [1], evidence: context(pid: 20)), [])
    }

    func testOriginalForegroundWindowsStillVisibleRemainEligible() {
        XCTAssertEqual(windowsToMinimize(before: [1, 2], after: [1, 2]), [1, 2])
    }

    func testWindowAppearingAfterClickIsNotAddedToMinimizeBatch() {
        XCTAssertEqual(windowsToMinimize(before: [1, 2], after: [1, 2, 3]), [1, 2])
    }

    func testWindowNoLongerVisibleIsNotReturnedFromOldEvidence() {
        XCTAssertEqual(windowsToMinimize(before: [1, 2], after: [2]), [2])
    }

    func testWindowIntersectionRejectsEvidenceCapturedAfterClick() {
        XCTAssertEqual(windowsToMinimize(
            before: [1], after: [1],
            evidence: context(startedAt: 10.16, completedAt: 10.18)
        ), [])
    }

    func testOriginalFrontmostApplicationWithCompletedPreclickEvidenceCanMinimize() {
        XCTAssertTrue(allows(context()))
    }

    func testBackgroundApplicationActivatedByDockCannotBorrowPreviousFrontmostEvidence() {
        XCTAssertFalse(allows(context(pid: 20), targetPID: 10))
    }

    func testRestoreObservedDuringOrAfterClickCannotBecomeMinimizeEvidence() {
        // Dock has restored the target before delayed AX enumeration completes.
        XCTAssertFalse(allows(context(startedAt: 10.14, completedAt: 10.17)))
        XCTAssertFalse(allows(context(startedAt: 10.17, completedAt: 10.19)))
        XCTAssertFalse(allows(context(startedAt: 10.10, completedAt: 10.15)))
    }

    func testNoPreclickEvidencePreservesNativeClick() {
        XCTAssertFalse(allows(nil))
    }

    func testReusedProcessIdentifierWithDifferentLaunchCannotBorrowEvidence() {
        XCTAssertFalse(allows(context(), targetLaunch: launch.addingTimeInterval(1)))
    }

    func testMissingLaunchIdentityCannotAuthorizeMinimization() {
        XCTAssertFalse(DockReversePreclickPolicy.canMinimize(
            context: context(), targetProcessIdentifier: 10, targetLaunchDate: nil,
            mouseDownAt: 10.15, now: 10.20
        ))
    }

    func testInvalidProcessIdentifiersFailClosed() {
        for pid: Int32 in [0, -1] {
            XCTAssertFalse(allows(context(pid: pid), targetPID: pid))
        }
    }

    func testSlowQueryAndOldEvidenceCannotAuthorizeMinimization() {
        XCTAssertFalse(allows(context(completedAt: 10.120_001)))
        XCTAssertFalse(allows(context(), down: 10.450_001, now: 10.46))
        XCTAssertFalse(allows(context(), now: 10.550_001))
    }

    func testInclusiveAgeAndQueryDurationBoundaries() {
        let completed = 10.0 + 0.12
        let down = completed + 0.40
        XCTAssertTrue(allows(
            context(completedAt: completed), down: down, now: down + 0.40
        ))
        XCTAssertFalse(allows(
            context(completedAt: completed), down: down, now: (down + 0.40).nextUp
        ))
        XCTAssertFalse(allows(
            context(completedAt: completed), down: down.nextUp, now: down.nextUp
        ))
        XCTAssertFalse(allows(context(completedAt: completed.nextUp)))
    }

    func testReversedAndFutureTimelineCannotAuthorizeMinimization() {
        XCTAssertFalse(allows(context(startedAt: 10.06, completedAt: 10.05)))
        XCTAssertFalse(allows(context(), down: 10.15, now: 10.14))
        XCTAssertFalse(allows(context(startedAt: -1, completedAt: 0)))
        XCTAssertFalse(allows(context(), down: -1))
        XCTAssertFalse(allows(context(), now: -1))
    }

    func testNonfiniteTimesAndLaunchDatesFailClosed() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(allows(context(startedAt: value)))
            XCTAssertFalse(allows(context(completedAt: value)))
            XCTAssertFalse(allows(context(), down: value))
            XCTAssertFalse(allows(context(), now: value))
            XCTAssertFalse(allows(context(launchDate: Date(timeIntervalSinceReferenceDate: value))))
            XCTAssertFalse(allows(context(), targetLaunch: Date(timeIntervalSinceReferenceDate: value)))
        }
    }

}
