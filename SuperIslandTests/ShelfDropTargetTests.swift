import XCTest
@testable import SuperIsland

final class ShelfDropTargetTests: XCTestCase {
    func testExpandedShelfOnlyPermitsTheExplicitDropAction() {
        XCTAssertFalse(ShelfDropDestination.surface.canReceive(shelfPanesVisible: true))
        for destination in [ShelfDropDestination.tray, .airDrop, .zip] {
            XCTAssertTrue(destination.canReceive(shelfPanesVisible: true))
        }
        XCTAssertTrue(ShelfDropDestination.surface.canReceive(shelfPanesVisible: false))
    }

    func testThirdPanePreservesTheExistingTrayWidthOnNormalDisplays() {
        let previousTrayWidth = Constants.fullExpandedSize.width - 80 - 142 - 12
        let width = ShelfLayoutMetrics.contentWidth(screenWidth: 1440, windowOverhead: 104)
        let side = ShelfLayoutMetrics.sidePaneWidth(contentWidth: width)
        XCTAssertEqual(side, 142)
        XCTAssertEqual(width - 80 - side * 2 - 24, previousTrayWidth)
    }

    func testShelfSurfaceAndInputViewportFitNarrowDisplays() {
        for screenWidth: CGFloat in [640, 800, 900] {
            for overhead: CGFloat in [104, 168] {
                let content = ShelfLayoutMetrics.contentWidth(screenWidth: screenWidth, windowOverhead: overhead)
                XCTAssertLessThanOrEqual(content + overhead + 24, screenWidth)
                let side = ShelfLayoutMetrics.sidePaneWidth(contentWidth: content)
                XCTAssertGreaterThan(side, 0)
                XCTAssertLessThanOrEqual(side * 2 + 24, content - 80)
            }
        }
    }

    func testChildEntryInvalidatesPendingParentExit() {
        var state = ShelfDropTargetState()
        let surface = UUID(), tray = UUID()
        state.setTarget(surface, inside: true)
        state.setTarget(surface, inside: false)
        let pendingExit = state.generation
        state.setTarget(tray, inside: true)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.canEnd(generation: pendingExit))
    }

    func testParentExitAfterChildEntryKeepsDragActive() {
        var state = ShelfDropTargetState()
        let surface = UUID(), sharing = UUID()
        state.setTarget(surface, inside: true)
        state.setTarget(sharing, inside: true)
        state.setTarget(surface, inside: false)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.canEnd(generation: state.generation))
        state.setTarget(sharing, inside: false)
        XCTAssertTrue(state.canEnd(generation: state.generation))
    }

    func testRapidReentryCannotBeEndedByOldExitEvenAfterLeavingAgain() {
        var state = ShelfDropTargetState()
        let pane = UUID()
        state.setTarget(pane, inside: true)
        state.setTarget(pane, inside: false)
        let oldExit = state.generation
        state.setTarget(pane, inside: true)
        state.setTarget(pane, inside: false)
        XCTAssertFalse(state.canEnd(generation: oldExit))
        XCTAssertTrue(state.canEnd(generation: state.generation))
    }

    func testDropClearsAllOverlappingTargetsWithoutWaitingForNativeExits() {
        var state = ShelfDropTargetState()
        let surface = UUID(), pane = UUID()
        state.setTarget(surface, inside: true)
        state.setTarget(pane, inside: true)
        state.completeDrop()
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.targets.isEmpty)
        let next = UUID()
        state.setTarget(next, inside: true)
        state.setTarget(surface, inside: false)
        state.setTarget(pane, inside: false)
        XCTAssertEqual(state.targets, [next])
    }

    func testIslandsOnDifferentDisplaysHaveIndependentTargets() {
        var state = ShelfDropTargetState()
        let firstTray = UUID(), secondTray = UUID()
        state.setTarget(firstTray, inside: true)
        state.setTarget(secondTray, inside: true)
        state.setTarget(firstTray, inside: false)
        XCTAssertEqual(state.targets, [secondTray])
    }

    @MainActor
    func testPresentationStaysOpenWhilePointerMovesFromSurfaceToPane() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        let surface = UUID(), pane = UUID()
        state.setShelfDropTarget(surface, inside: true)
        state.setShelfDropTarget(surface, inside: false)
        state.setShelfDropTarget(pane, inside: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(state.isShelfDragActive)
        state.dismiss()
        XCTAssertEqual(state.currentState, .fullExpanded)
        state.completeShelfDropTargets()
        XCTAssertFalse(state.isShelfDragActive)
        state.cancelFullExpandedDismiss()
    }

    @MainActor
    func testLeavingAllDestinationsReleasesPresentationHold() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        let pane = UUID()
        state.setShelfDropTarget(pane, inside: true)
        state.setShelfDropTarget(pane, inside: false)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(state.isShelfDragActive)
        state.cancelFullExpandedDismiss()
    }

    @MainActor
    func testInternalDragKeepsPresentationOpenBetweenPanesUntilRelease() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        var dragging = true
        let session = ShelfInternalDragSession(isDragging: { dragging })
        defer {
            session.end()
            state.completeShelfDropTargets()
            state.cancelFullExpandedDismiss()
        }
        session.begin(appState: state)
        let pane = UUID()
        state.setShelfDropTarget(pane, inside: true)
        state.setShelfDropTarget(pane, inside: false)
        try await Task.sleep(nanoseconds: 450_000_000)
        state.dismiss()
        XCTAssertTrue(state.isShelfDragActive)
        XCTAssertEqual(state.currentState, .fullExpanded)

        dragging = false
        session.poll()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(state.isShelfDragActive)
    }

    @MainActor
    func testCompletedInternalDragCannotClearANewDestination() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        let session = ShelfInternalDragSession(isDragging: { true })
        defer {
            session.end()
            state.completeShelfDropTargets()
            state.cancelFullExpandedDismiss()
        }
        session.begin(appState: state)
        state.completeShelfDropTargets()
        session.poll()

        let nextPane = UUID()
        state.setShelfDropTarget(nextPane, inside: true)
        session.end()
        XCTAssertTrue(state.isShelfDragActive)
    }
}
