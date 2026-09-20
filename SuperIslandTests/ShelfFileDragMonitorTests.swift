import XCTest
@testable import SuperIsland

final class ShelfFileDragMonitorTests: XCTestCase {
    func testOldFilePasteboardDoesNotOpenDuringOrdinaryWindowDrag() {
        var state = ShelfFileDragState()
        state.begin(changeCount: 4, inputGeneration: 0)
        XCTAssertEqual(state.update(changeCount: 4, hasFileURL: true, nearCompactIsland: true,
                                    insidePresentation: false, inputAllowed: true), .none)
        XCTAssertFalse(state.ownsTarget)
    }

    func testFreshNonFileDragAndFileAwayFromIslandDoNotOpen() {
        var state = ShelfFileDragState()
        state.begin(changeCount: 4, inputGeneration: 0)
        XCTAssertEqual(state.update(changeCount: 5, hasFileURL: false, nearCompactIsland: true,
                                    insidePresentation: false, inputAllowed: true), .none)
        XCTAssertEqual(state.update(changeCount: 5, hasFileURL: true, nearCompactIsland: false,
                                    insidePresentation: false, inputAllowed: true), .none)
    }

    func testFreshFileActivatesOnceThenWithdrawalCannotReopenSameGesture() {
        var state = ShelfFileDragState()
        state.begin(changeCount: 4, inputGeneration: 0)
        XCTAssertEqual(state.update(changeCount: 5, hasFileURL: true, nearCompactIsland: true,
                                    insidePresentation: true, inputAllowed: true), .enter)
        XCTAssertEqual(state.update(changeCount: 5, hasFileURL: true, nearCompactIsland: false,
                                    insidePresentation: true, inputAllowed: true), .none)
        XCTAssertEqual(state.update(changeCount: 5, hasFileURL: true, nearCompactIsland: false,
                                    insidePresentation: false, inputAllowed: true), .leave)
        XCTAssertEqual(state.update(changeCount: 6, hasFileURL: true, nearCompactIsland: true,
                                    insidePresentation: true, inputAllowed: true), .none)
    }

    func testReleaseOrInvalidatedInputRequiresNewDownBeforeActivation() {
        for invalidate in [false, true] {
            var state = ShelfFileDragState()
            state.begin(changeCount: 4, inputGeneration: 7)
            XCTAssertEqual(state.update(changeCount: 5, hasFileURL: true, nearCompactIsland: true,
                                        insidePresentation: true, inputAllowed: true), .enter)
            if invalidate {
                XCTAssertEqual(state.update(changeCount: 5, hasFileURL: true, nearCompactIsland: true,
                                            insidePresentation: true, inputAllowed: false), .leave)
            } else { XCTAssertEqual(state.end(), .leave) }
            XCTAssertEqual(state.update(changeCount: 6, hasFileURL: true, nearCompactIsland: true,
                                        insidePresentation: true, inputAllowed: true), .none)
            XCTAssertFalse(state.isTracking)
        }
    }

    func testNoObservedDownCannotUseFreshPasteboard() {
        var state = ShelfFileDragState()
        XCTAssertEqual(state.update(changeCount: 8, hasFileURL: true, nearCompactIsland: true,
                                    insidePresentation: true, inputAllowed: true), .none)
    }

    func testWithdrawingApproachDoesNotClearRealReceiver() {
        var targets = ShelfDropTargetState()
        let approach = UUID(), tray = UUID()
        targets.setTarget(approach, inside: true)
        targets.setTarget(tray, inside: true)
        targets.setTarget(approach, inside: false)
        XCTAssertEqual(targets.targets, [tray])
    }

    func testApproachUsesActualPanelFrameAndAllowsCoalescedCrossing() {
        let frame = CGRect(x: 616, y: 950, width: 280, height: 32)
        XCTAssertEqual(ShelfFileDragGeometry.approachBand(below: frame),
                       CGRect(x: 616, y: 918, width: 280, height: 32))
        XCTAssertTrue(ShelfFileDragGeometry.approaches(frame, from: nil, to: CGPoint(x: 700, y: 930)))
        XCTAssertTrue(ShelfFileDragGeometry.approaches(frame, from: CGPoint(x: 700, y: 900),
                                                      to: CGPoint(x: 700, y: 960)))
        XCTAssertFalse(ShelfFileDragGeometry.approaches(frame, from: CGPoint(x: 600, y: 900),
                                                       to: CGPoint(x: 600, y: 960)))
        XCTAssertFalse(ShelfFileDragGeometry.approaches(frame, from: CGPoint(x: 700, y: 800),
                                                       to: CGPoint(x: 700, y: 900)))
    }

    func testApproachOnOtherDisplayUsesItsOwnOrigin() {
        let frame = CGRect(x: -1400, y: -100, width: 240, height: 32)
        XCTAssertTrue(ShelfFileDragGeometry.approaches(frame, from: nil, to: CGPoint(x: -1300, y: -116)))
        XCTAssertFalse(ShelfFileDragGeometry.approaches(frame, from: nil, to: CGPoint(x: 700, y: 930)))
    }
}
