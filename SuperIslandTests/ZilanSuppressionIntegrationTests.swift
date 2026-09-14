import AppKit
import XCTest
@testable import SuperIsland

/// Hidden AppKit panels and isolated state only: no app bootstrap, real socket,
/// application activation, menu-bar movement, or persisted setting changes.
@MainActor
final class ZilanSuppressionIntegrationTests: XCTestCase {
    func testCompactLeaseBlocksEveryPresentationEntryWithoutChangingModuleData() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.activeModule = .builtIn(.battery)
        let request = lease()
        XCTAssertTrue(state.beginZilanSuppression(request))

        state.handleHoverChange(true)
        state.toggleExpansion()
        state.expand()
        state.open()
        state.fullyExpand()
        state.showHUD(module: ModuleType.nowPlaying)
        state.presentShelfAfterDrop()
        state.beginShelfDragPresentation()
        state.presentNotificationsFullExpanded()
        state.cycleModule(forward: true)

        XCTAssertEqual(state.currentState, .compact)
        XCTAssertFalse(state.isHovering)
        XCTAssertFalse(state.isShelfDragActive)
        XCTAssertEqual(state.activeModule, .builtIn(.battery))
        XCTAssertEqual(state.fullExpandedSelectedTab, .home)
        state.endZilanSuppression(requestID: request.requestID)
        XCTAssertFalse(state.isZilanInteractionSuppressed)
        XCTAssertEqual(state.currentState, .compact)
    }

    func testBusyPresentationHoverEmojiAndHoldRejectInsteadOfInterrupting() {
        let expanded = AppState(synchronizesRuntimeEnergyState: false)
        expanded.expand()
        XCTAssertEqual(expanded.currentState, .expanded)
        XCTAssertFalse(expanded.beginZilanSuppression(lease()))
        XCTAssertEqual(expanded.currentState, .expanded)
        expanded.cancelAutoDismiss()

        let hovered = AppState(synchronizesRuntimeEnergyState: false)
        hovered.isHovering = true
        XCTAssertFalse(hovered.beginZilanSuppression(lease()))
        XCTAssertTrue(hovered.isHovering)

        let emoji = AppState(synchronizesRuntimeEnergyState: false)
        emoji.beginSystemEmojiInteraction()
        XCTAssertFalse(emoji.beginZilanSuppression(lease()))
        XCTAssertTrue(emoji.isSystemEmojiInteractionActive)
        emoji.endSystemEmojiInteraction()

        let held = AppState(synchronizesRuntimeEnergyState: false)
        held.holdPresentation(for: .builtIn(.teleprompter))
        XCTAssertFalse(held.beginZilanSuppression(lease()))
        XCTAssertTrue(held.isTeleprompterPresentationHeld)
        held.releasePresentationHold(for: .builtIn(.teleprompter))

        let animating = AppState(synchronizesRuntimeEnergyState: false)
        animating.suppressDismissScheduling = true
        XCTAssertFalse(animating.beginZilanSuppression(lease()))
    }

    func testStaleReleaseCannotClearCurrentLeaseAndOldInputNeverReplays() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        let oldGeneration = state.islandInputGeneration
        let first = lease()
        XCTAssertTrue(state.beginZilanSuppression(first))
        let duringLease = state.islandInputGeneration
        XCTAssertFalse(state.beginZilanSuppression(lease()))
        state.endZilanSuppression(requestID: "unrelated")
        XCTAssertTrue(state.isZilanInteractionSuppressed)
        XCTAssertFalse(state.canHandleIslandInput(generation: duringLease))

        state.endZilanSuppression(requestID: first.requestID)
        XCTAssertFalse(state.canHandleIslandInput(generation: oldGeneration))
        XCTAssertFalse(state.canHandleIslandInput(generation: duringLease))
        XCTAssertTrue(state.canHandleIslandInput(generation: state.islandInputGeneration))
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertFalse(state.isHovering)

        let second = lease()
        XCTAssertTrue(state.beginZilanSuppression(second))
        state.endZilanSuppression(requestID: first.requestID)
        XCTAssertEqual(state.zilanSuppressionRequestID, second.requestID)
        state.endZilanSuppression(requestID: second.requestID)
    }

    func testExpiredAndOverlongLeasesCannotReachPresentationState() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        let now = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(state.beginZilanSuppression(lease(expiry: now - 1)))
        XCTAssertFalse(state.beginZilanSuppression(lease(expiry: now + 20_000_000_000)))
        XCTAssertFalse(state.isZilanInteractionSuppressed)
        XCTAssertEqual(state.islandInputGeneration, 0)
    }

    func testRestoringInputUnderStationaryPointerDoesNotReplayHover() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        let request = lease()
        XCTAssertTrue(state.beginZilanSuppression(request))
        state.endZilanSuppression(requestID: request.requestID, requiresHoverExit: true)
        state.handleHoverChange(true)
        XCTAssertFalse(state.isHovering)
        XCTAssertEqual(state.currentState, .compact)
        state.handleHoverChange(false)
        state.handleHoverChange(true)
        XCTAssertTrue(state.isHovering)
        state.cancelHoverActivation()
    }

    func testEveryExistingAndNewPanelRestoresItsOwnMousePolicy() {
        let interactive = makePanel(ignoresMouseEvents: false)
        let alreadyTransparent = makePanel(ignoresMouseEvents: true)
        let newPanel = makePanel(ignoresMouseEvents: false)
        defer { [interactive, alreadyTransparent, newPanel].forEach { $0.close() } }
        let routing = IslandPanelInputSuppression()
        XCTAssertTrue(routing.begin(requestID: "first", panels: [interactive, alreadyTransparent]))
        XCTAssertTrue(interactive.ignoresMouseEvents)
        XCTAssertTrue(alreadyTransparent.ignoresMouseEvents)

        routing.include(newPanel)
        routing.include(interactive)
        XCTAssertTrue(newPanel.ignoresMouseEvents)
        XCTAssertFalse(routing.begin(requestID: "second", panels: [interactive]))
        routing.release(requestID: "stale")
        XCTAssertTrue(interactive.ignoresMouseEvents)

        routing.release(requestID: "first")
        XCTAssertFalse(interactive.ignoresMouseEvents)
        XCTAssertTrue(alreadyTransparent.ignoresMouseEvents)
        XCTAssertFalse(newPanel.ignoresMouseEvents)
        routing.release(requestID: "first")
        XCTAssertFalse(interactive.ignoresMouseEvents)
        XCTAssertTrue([interactive, alreadyTransparent, newPanel].allSatisfy { !$0.isVisible })
    }

    func testMultipleOrUnverifiedSuperIslandInstancesAreRejected() {
        XCTAssertTrue(AppDelegate.isSoleZilanSuppressionInstance(processIdentifiers: [42], ownPID: 42))
        XCTAssertFalse(AppDelegate.isSoleZilanSuppressionInstance(processIdentifiers: [42, 43], ownPID: 42))
        XCTAssertFalse(AppDelegate.isSoleZilanSuppressionInstance(processIdentifiers: [43], ownPID: 42))
        XCTAssertFalse(AppDelegate.isSoleZilanSuppressionInstance(processIdentifiers: [], ownPID: 42))
    }

    private func lease(expiry: UInt64? = nil) -> ZilanSuppressionLease {
        ZilanSuppressionLease(requestID: UUID().uuidString, targetIdentityHash: "test-hash",
            expiresAtUptimeNanoseconds: expiry ?? DispatchTime.now().uptimeNanoseconds + 1_900_000_000)
    }

    private func makePanel(ignoresMouseEvents: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.ignoresMouseEvents = ignoresMouseEvents
        return panel
    }
}
