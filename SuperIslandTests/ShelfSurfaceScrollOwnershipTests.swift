import AppKit
import XCTest
@testable import SuperIsland

final class ShelfSurfaceScrollOwnershipTests: XCTestCase {
    private func route(
        _ state: inout IslandSurfaceScrollOwnership,
        phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = [],
        time: TimeInterval = 1, shelf: Bool = true, child: Bool = true
    ) -> Bool {
        state.allowsSurfaceSwipe(
            phase: phase, momentumPhase: momentum, timestamp: time,
            givesNestedScrollViewsPriority: shelf, isOverNestedScrollView: child
        )
    }

    func testOnlyShelfOptInGivesChildScrollViewsPriority() {
        var shelf = IslandSurfaceScrollOwnership()
        XCTAssertFalse(route(&shelf, phase: .began))
        XCTAssertEqual(shelf.owner, .nestedScrollView)

        var otherModule = IslandSurfaceScrollOwnership()
        XCTAssertTrue(route(&otherModule, phase: .began, shelf: false))
        XCTAssertEqual(otherModule.owner, .surface)
    }

    func testChildKeepsOwnershipWhenPointerLeavesOrSelectedPageChanges() {
        var state = IslandSurfaceScrollOwnership()
        XCTAssertFalse(route(&state, phase: .began))
        XCTAssertFalse(route(&state, time: 1.1, child: false))
        XCTAssertFalse(route(&state, time: 1.2, shelf: false, child: false))
        XCTAssertEqual(state.owner, .nestedScrollView)
    }

    func testSurfaceGestureKeepsItsOriginalOwner() {
        var state = IslandSurfaceScrollOwnership()
        XCTAssertTrue(route(&state, phase: .began, child: false))
        XCTAssertTrue(route(&state, time: 1.1, child: true))
        XCTAssertEqual(state.owner, .surface)
    }

    func testNewBeganReleasesPreviousChildOwnershipWithoutWaitingForTimeout() {
        var state = IslandSurfaceScrollOwnership()
        XCTAssertFalse(route(&state, phase: .began))
        XCTAssertTrue(route(&state, phase: .began, time: 1.01, child: false))
    }

    func testEndedAndCancelledClearOwnership() {
        for end: NSEvent.Phase in [.ended, .cancelled] {
            var state = IslandSurfaceScrollOwnership()
            XCTAssertFalse(route(&state, phase: .began))
            XCTAssertFalse(route(&state, phase: end, time: 1.1))
            XCTAssertNil(state.owner)
            XCTAssertTrue(route(&state, time: 1.11, child: false))
        }
    }

    func testUnphasedGestureResetsAfterTimeout() {
        var state = IslandSurfaceScrollOwnership()
        XCTAssertFalse(route(&state, phase: []))
        XCTAssertFalse(route(&state, phase: [], time: 1.2, child: false))
        XCTAssertTrue(route(&state, phase: [], time: 1.6, child: false))
    }

    func testMomentumNeverBecomesASurfaceSwipe() {
        var state = IslandSurfaceScrollOwnership()
        XCTAssertTrue(route(&state, phase: .began, child: false))
        XCTAssertFalse(route(&state, phase: .ended, time: 1.1, child: false))
        for (index, phase) in [NSEvent.Phase.began, .changed, .ended].enumerated() {
            XCTAssertFalse(route(
                &state, phase: [], momentum: phase, time: 1.2 + Double(index) * 0.1,
                child: false
            ))
        }
        XCTAssertTrue(route(&state, phase: .began, time: 1.5, child: false))
    }

    func testExplicitResetClearsThePreviousGesture() {
        var state = IslandSurfaceScrollOwnership()
        XCTAssertFalse(route(&state, phase: .began))
        state.reset()
        XCTAssertNil(state.owner)
        XCTAssertTrue(route(&state, time: 1.01, child: false))
    }

    @MainActor
    private func makeScrollTree(documentWidth: CGFloat = 480) -> (NSView, NSView, NSScrollView) {
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        let root = NSView(frame: NSRect(x: 17, y: 23, width: 320, height: 160))
        outer.addSubview(root)
        let scroll = NSScrollView(frame: NSRect(x: 40, y: 20, width: 200, height: 100))
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: 100))
        root.addSubview(scroll)
        return (outer, root, scroll)
    }

    @MainActor
    func testAppKitHitTestFindsNestedDocumentAtBothScrollBoundaries() {
        let (outer, root, scroll) = makeScrollTree()
        withExtendedLifetime(outer) {
            for offset: CGFloat in [0, 280] {
                scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertTrue(IslandSurfaceScrollHitTest.isOverNestedScrollView(
                    at: NSPoint(x: 60, y: 60), in: root
                ))
            }
        }
    }

    @MainActor
    func testAppKitHitTestKeepsNonOverflowingAndEmptyScrollViewsOwned() {
        for width: CGFloat in [40, 0] {
            let (outer, root, _) = makeScrollTree(documentWidth: width)
            withExtendedLifetime(outer) {
                XCTAssertTrue(IslandSurfaceScrollHitTest.isOverNestedScrollView(
                    at: NSPoint(x: 180, y: 60), in: root
                ))
            }
        }
    }

    @MainActor
    func testAppKitHitTestLeavesOutsideSurfaceAndHiddenChildUnclaimed() {
        let (outer, root, scroll) = makeScrollTree()
        withExtendedLifetime(outer) {
            XCTAssertFalse(IslandSurfaceScrollHitTest.isOverNestedScrollView(
                at: NSPoint(x: 10, y: 60), in: root
            ))
            scroll.isHidden = true
            XCTAssertFalse(IslandSurfaceScrollHitTest.isOverNestedScrollView(
                at: NSPoint(x: 60, y: 60), in: root
            ))
        }
    }

    @MainActor
    func testObservationOverlayDoesNotMaskTheActualScrollView() {
        let (outer, root, _) = makeScrollTree()
        root.addSubview(TrackpadSwipeView(frame: root.bounds))
        withExtendedLifetime(outer) {
            XCTAssertTrue(IslandSurfaceScrollHitTest.isOverNestedScrollView(
                at: NSPoint(x: 60, y: 60), in: root
            ))
        }
    }
}
