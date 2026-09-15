import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import SuperIsland

@MainActor
final class WindowPreviewInteractionTests: XCTestCase {
    func testAXLifecycleAdmitsOnlyAConfirmedRootForTheExactOwnerAndWindow() {
        XCTAssertTrue(WindowAXLifecycleAdmissionPolicy.allowsTracking(
            expectedOwnerPID: 568, reportedOwnerPID: 568, windowID: 130,
            roleReadResult: .success, role: kAXWindowRole as String
        ))
        // AXWindow is the root role even for document/dialog subroles; this
        // identity gate must not duplicate the later presentation policy.
        XCTAssertTrue(WindowAXLifecycleAdmissionPolicy.allowsTracking(
            expectedOwnerPID: 568, reportedOwnerPID: 568, windowID: 24636,
            roleReadResult: .success, role: "AXWindow"
        ))
    }

    func testAXLifecycleRejectsForeignOwnerAndMissingOrZeroWindowIdentity() {
        let identities: [(pid_t, pid_t, CGWindowID?)] = [
            (568, 569, 130), (568, 0, 130), (0, 0, 130),
            (-1, -1, 130), (568, 568, nil), (568, 568, 0)
        ]
        for (expectedOwner, reportedOwner, windowID) in identities {
            XCTAssertFalse(WindowAXLifecycleAdmissionPolicy.allowsTracking(
                expectedOwnerPID: expectedOwner, reportedOwnerPID: reportedOwner,
                windowID: windowID, roleReadResult: .success, role: "AXWindow"
            ), "A root role alone cannot establish a different or missing identity")
        }
    }

    func testSameWindowNumberOnNonRootProxyCannotReplaceAnExistingWindow() {
        let roles: [String?] = ["AXApplication", "AXGroup", "AXUnknown", "AXButton", "AXSheet", "", nil]
        for role in roles {
            XCTAssertFalse(WindowAXLifecycleAdmissionPolicy.allowsTracking(
                expectedOwnerPID: 568, reportedOwnerPID: 568, windowID: 130,
                roleReadResult: .success, role: role
            ), "An inherited WID must not admit a non-window proxy")
        }
    }

    func testFailedOrTimedOutRootReadCannotAdmitAReplacementWithAStaleRoleValue() {
        let failures: [AXError] = [
            .invalidUIElement, .cannotComplete, .apiDisabled, .noValue,
            .attributeUnsupported, .failure, .illegalArgument
        ]
        for failure in failures {
            XCTAssertFalse(WindowAXLifecycleAdmissionPolicy.allowsTracking(
                expectedOwnerPID: 568, reportedOwnerPID: 568, windowID: 130,
                roleReadResult: failure, role: "AXWindow"
            ), "Only a successful role read permits a new or replacement binding")
        }
    }

    private let a = WindowPreviewIdentity(processID: 10, windowID: 100)
    private let b = WindowPreviewIdentity(processID: 10, windowID: 200)
    private let bodyA = CGPoint(x: 60, y: 60)
    private let bodyB = CGPoint(x: 170, y: 60)
    private let closeA = CGPoint(x: 12, y: 12)

    private func state() -> WindowPreviewPointerState<WindowPreviewIdentity> {
        var state = WindowPreviewPointerState<WindowPreviewIdentity>()
        state.update(frames: [a: CGRect(x: 0, y: 0, width: 100, height: 100),
                              b: CGRect(x: 110, y: 0, width: 100, height: 100)],
                     activatable: [a, b], closable: [a, b])
        return state
    }

    func testHoverMovesBetweenWindowsWithoutKeyboardOrClick() {
        var state = state()
        XCTAssertNil(state.handle(.mouseMoved, at: bodyA))
        XCTAssertEqual(state.hovered, a)
        XCTAssertNil(state.handle(.mouseMoved, at: bodyB))
        XCTAssertEqual(state.hovered, b)
    }

    func testFirstClickActivatesExactlyOnce() {
        var state = state()
        XCTAssertNil(state.handle(.leftMouseDown, at: bodyA))
        XCTAssertEqual(state.handle(.leftMouseUp, at: bodyA), .activate(a))
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyA))
    }

    func testCloseFirstClickDoesNotRequireEarlierHoverFrame() {
        var state = state()
        XCTAssertNil(state.handle(.leftMouseDown, at: closeA))
        XCTAssertEqual(state.hovered, a)
        XCTAssertEqual(state.handle(.leftMouseUp, at: closeA), .close(a))
        XCTAssertNil(state.handle(.leftMouseUp, at: closeA))
    }

    func testReleaseWithoutOwnPressDoesNotActivateOrClose() {
        var state = state()
        XCTAssertNil(state.handle(.leftMouseUp, at: closeA))
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyA))
    }

    func testPendingGestureRemainsOwnedUntilItsReleaseEventIsDelivered() {
        var state = state()
        XCTAssertFalse(state.hasPendingPress)
        _ = state.handle(.leftMouseDown, at: bodyA)
        XCTAssertTrue(state.hasPendingPress)
        _ = state.handle(.mouseMoved, at: bodyA)
        XCTAssertTrue(state.hasPendingPress, "Physical button state cannot finish an undelivered event pair")
        XCTAssertEqual(state.handle(.leftMouseUp, at: bodyA), .activate(a))
        XCTAssertFalse(state.hasPendingPress)
        _ = state.handle(.leftMouseDown, at: closeA)
        XCTAssertTrue(state.hasPendingPress)
        _ = state.handle(.mouseExited, at: closeA)
        XCTAssertFalse(state.hasPendingPress)
        XCTAssertNil(state.handle(.leftMouseUp, at: closeA))
    }

    func testDockExposesUnfinishedClickToRecoveryUntilReleaseOrGeometryReset() {
        let model = DockWindowPreviewModel()
        var activated = 0
        let row = DockPreviewRow(id: 100, title: "Test", isMinimized: false, canActivate: true,
                                 isPreviewOnly: false, canClose: true, thumbnailResult: nil,
                                 action: { activated += 1 }, closeAction: {})
        model.update(appName: "Test", icon: nil, rows: [row], canManageWindows: true)
        model.setPreviewFrames([100: CGRect(x: 0, y: 0, width: 100, height: 100)])
        model.handlePointer(.leftMouseDown, at: bodyA)
        XCTAssertTrue(model.hasPendingPointerPress)
        model.handlePointer(.leftMouseUp, at: bodyA)
        XCTAssertEqual(activated, 1)
        XCTAssertFalse(model.hasPendingPointerPress)
        model.handlePointer(.leftMouseDown, at: closeA)
        XCTAssertTrue(model.hasPendingPointerPress)
        model.resetPointerGeometry()
        XCTAssertFalse(model.hasPendingPointerPress)
    }

    func testDraggingFromBodyIntoCloseDoesNotClose() {
        var state = state()
        _ = state.handle(.leftMouseDown, at: bodyA)
        XCTAssertNil(state.handle(.leftMouseUp, at: closeA))
    }

    func testPressOnOneWindowCannotActivateAnother() {
        var state = state()
        _ = state.handle(.leftMouseDown, at: bodyA)
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyB))
    }

    func testLayoutChangeCancelsPendingClick() {
        var state = state()
        _ = state.handle(.leftMouseDown, at: bodyA)
        state.update(frames: [a: CGRect(x: 1, y: 0, width: 100, height: 100)], activatable: [a], closable: [a])
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyA))
    }

    func testSameLayoutRefreshPreservesPendingFirstClick() {
        var state = state()
        _ = state.handle(.leftMouseDown, at: bodyA)
        state.update(frames: [a: CGRect(x: 0, y: 0, width: 100, height: 100),
                              b: CGRect(x: 110, y: 0, width: 100, height: 100)],
                     activatable: [a, b], closable: [a, b])
        XCTAssertEqual(state.handle(.leftMouseUp, at: bodyA), .activate(a))
    }

    func testSameIndexWithDifferentWindowIdentityCancelsClick() {
        var state = state()
        _ = state.handle(.leftMouseDown, at: bodyA)
        state.update(frames: [b: CGRect(x: 0, y: 0, width: 100, height: 100)], activatable: [b], closable: [b])
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyA))
    }

    func testSameWindowNumberInDifferentProcessIsDifferentTarget() {
        XCTAssertNotEqual(a, WindowPreviewIdentity(processID: 11, windowID: 100))
    }

    func testExitClearsHoverAndPendingClick() {
        var state = state()
        _ = state.handle(.leftMouseDown, at: bodyA)
        _ = state.handle(.mouseExited, at: .zero)
        XCTAssertNil(state.hovered)
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyA))
    }

    func testOverlappingAnimationFramesAreRejected() {
        var state = state()
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        state.update(frames: [a: frame, b: frame], activatable: [a, b], closable: [a, b])
        _ = state.handle(.leftMouseDown, at: bodyA)
        XCTAssertNil(state.hovered)
        XCTAssertNil(state.handle(.leftMouseUp, at: bodyA))
    }

    func testPreviewOnlyCardCanHoverButCannotOperate() {
        var state = state()
        state.update(frames: [a: CGRect(x: 0, y: 0, width: 100, height: 100)], activatable: [], closable: [])
        _ = state.handle(.leftMouseDown, at: closeA)
        XCTAssertEqual(state.hovered, a)
        XCTAssertNil(state.handle(.leftMouseUp, at: closeA))
    }

    func testTrackingViewAcceptsFirstClickWithoutActivation() {
        let view = WindowPreviewTrackingView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.needsPanelToBecomeKey)
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(view.trackingAreas[0].options.contains(.activeAlways))
        XCTAssertTrue(view.trackingAreas[0].options.contains(.mouseMoved))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
    }

    func testNonactivatingPreviewPanelNeverStealsSystemFocus() {
        let panel = WindowPreviewInteractionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testFrameReporterUsesTrackingViewsTopLeftCoordinateSpace() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        panel.contentView = container
        var reports: [(Int, CGRect?)] = []
        let reporter = WindowPreviewFrameReportingView<Int>(target: 7) {
            reports.append(($0, $1))
        }
        reporter.frame = CGRect(x: 20, y: 30, width: 100, height: 80)
        container.addSubview(reporter)
        reporter.layout()
        XCTAssertEqual(
            reports.last?.1,
            CGRect(x: 20, y: 70, width: 100, height: 80)
        )
        reporter.detach()
        XCTAssertEqual(reports.last?.0, 7)
        XCTAssertNil(reports.last?.1)
        let reportCountAfterDetach = reports.count
        reporter.layout()
        XCTAssertEqual(reports.count, reportCountAfterDetach)
    }

    func testSwiftUIBackgroundReporterReceivesActualCardSize() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var reportedFrame: CGRect?
        let card = Color.clear
            .frame(width: 120, height: 80)
            .background(WindowPreviewFrameReporter(target: 7) { _, frame in
                if let frame { reportedFrame = frame }
            })
        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = CGRect(x: 30, y: 40, width: 120, height: 80)
        panel.contentView = hostingView

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(reportedFrame?.width ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(reportedFrame?.height ?? 0, 80, accuracy: 0.5)
    }

    func testRicherNoIDProxyBeatsSparseExactIDProxyForOperations() {
        let sparseExact = WindowAXOperationProxyEvidence(
            hasWindowID: true,
            hasTitle: true,
            hasBounds: true,
            isPreferredWindow: true,
            canClose: false,
            allowsUniformContent: false
        )
        let actionableProxy = WindowAXOperationProxyEvidence(
            hasWindowID: false,
            hasTitle: true,
            hasBounds: true,
            isPreferredWindow: false,
            canClose: true,
            allowsUniformContent: true
        )
        XCTAssertTrue(WindowAXOperationProxyPolicy.prefersCandidate(
            existing: sparseExact,
            candidate: actionableProxy
        ))
        XCTAssertFalse(WindowAXOperationProxyPolicy.prefersCandidate(
            existing: actionableProxy,
            candidate: sparseExact
        ))
    }

    func testActualAppKitViewConvertsCoordinatesAndDeliversFirstClick() {
        // A hidden test-owned panel: no desktop events, AX operations, or user
        // windows are touched. Exercise the actual NSView delivery methods.
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        panel.contentView = container
        let view = WindowPreviewTrackingView(frame: CGRect(x: 20, y: 30, width: 100, height: 100))
        container.addSubview(view)
        var state = state()
        var actions: [WindowPreviewPointerAction<WindowPreviewIdentity>] = []
        var points: [CGPoint] = []
        view.onPointer = { type, point, _ in
            points.append(point)
            if let action = state.handle(type, at: point) { actions.append(action) }
        }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: 80, y: 90), modifierFlags: [.command],
                               timestamp: 1, windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        view.mouseMoved(with: event(.mouseMoved))
        XCTAssertEqual(state.hovered, a)
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(points, Array(repeating: CGPoint(x: 60, y: 40), count: 3))
        XCTAssertEqual(actions, [.activate(a)])
        XCTAssertFalse(panel.isVisible)
    }

    private func cmdItem(_ identities: [WindowPreviewIdentity], selected: Int = 0, canClose: Bool = true,
                         thumbnails: [WindowThumbnailResult?] = []) -> CommandTabDisplayItem {
        CommandTabDisplayItem(id: 0, appName: "Test", icon: nil, isLoading: false,
                              windows: identities.enumerated().map { index, identity in
            CommandTabWindowDisplayItem(id: index, identity: identity, title: "Test", isMinimized: false,
                                        canClose: canClose, isSelected: index == selected,
                                        thumbnailResult: thumbnails.indices.contains(index) ? thumbnails[index] : nil)
        })
    }

    private func makeCommandTabFrameReporter(
        model: CommandTabOverlayModel,
        target: CommandTabPreviewTarget
    ) -> (NSPanel, WindowPreviewFrameReportingView<CommandTabPreviewTarget>) {
        // Exercise the real NSView rectangle reporter in a hidden test-owned
        // panel; no desktop input or application window is touched.
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        panel.contentView = container
        let reporter = addCommandTabFrameReporter(to: panel, model: model, target: target,
                                                  frame: CGRect(x: 0, y: 80, width: 100, height: 100))
        return (panel, reporter)
    }

    private func addCommandTabFrameReporter(
        to panel: NSPanel,
        model: CommandTabOverlayModel,
        target: CommandTabPreviewTarget,
        frame: CGRect
    ) -> WindowPreviewFrameReportingView<CommandTabPreviewTarget> {
        let generation = model.previewFrameGeneration
        let reporter = WindowPreviewFrameReportingView(target: target, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        reporter.frame = frame
        panel.contentView!.addSubview(reporter)
        reporter.layout()
        return reporter
    }

    func testRetainedAppKitReporterRestoresHoverAfterOtherWindowRemoved() {
        let model = CommandTabOverlayModel()
        let third = WindowPreviewIdentity(processID: 10, windowID: 300)
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        model.update(items: [cmdItem([a, b, third])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let (panel, reporter) = makeCommandTabFrameReporter(model: model, target: target)
        defer { panel.close() }
        let oldGeneration = model.previewFrameGeneration
        _ = model.handlePointer(.leftMouseDown, at: closeA)
        XCTAssertEqual(model.pointerHoveredTarget, target)

        // ForEach keeps the first card at the same identity and rectangle,
        // although removal of another card invalidates the model's frames.
        model.update(items: [cmdItem([a, b])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let generation = model.previewFrameGeneration
        XCTAssertNotEqual(generation, oldGeneration)
        _ = model.handlePointer(.mouseMoved, at: closeA)
        XCTAssertNil(model.pointerHoveredTarget)
        reporter.update(target: target, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        reporter.layout()
        _ = model.handlePointer(.mouseMoved, at: closeA)
        XCTAssertEqual(model.pointerHoveredTarget, target)
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: closeA), "Old presses must remain invalidated")
        _ = model.handlePointer(.leftMouseDown, at: closeA)
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: closeA), .close(target))

        // A delayed detach from the prior view generation cannot erase the
        // new frame, even if that generation used the identical window ID.
        model.setPreviewFrame(nil, for: target, generation: oldGeneration)
        _ = model.handlePointer(.mouseMoved, at: closeA)
        XCTAssertEqual(model.pointerHoveredTarget, target)
    }

    func testRetainedAppKitReporterRestoresFramesAfterLoadingSameWindow() {
        let model = CommandTabOverlayModel()
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let (panel, reporter) = makeCommandTabFrameReporter(model: model, target: target)
        defer { panel.close() }
        let oldGeneration = model.previewFrameGeneration
        // Model updates can outpace a view refresh. Retain the actual NSView
        // while the owner passes through its empty loading presentation.
        model.update(items: [cmdItem([])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let generation = model.previewFrameGeneration
        XCTAssertNotEqual(generation, oldGeneration)
        reporter.update(target: target, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        reporter.layout()
        _ = model.handlePointer(.mouseMoved, at: bodyA)
        XCTAssertEqual(model.pointerHoveredTarget, target)

        let fresh = WindowThumbnailResult.fresh(NSImage(size: NSSize(width: 20, height: 20)))
        _ = model.handlePointer(.leftMouseDown, at: bodyA)
        model.update(items: [cmdItem([a], thumbnails: [fresh])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        XCTAssertEqual(model.previewFrameGeneration, generation, "Pixels do not invalidate hit geometry")
        reporter.update(target: target, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        reporter.layout()
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: bodyA), .activate(target))
    }

    func testReplacementReporterPreservesRealWindowHitFrameWhenSharedFallbackArrives() {
        let model = CommandTabOverlayModel()
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        let fallbackIdentity = WindowPreviewIdentity(processID: 20, windowID: 200)
        let fallbackTarget = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 1, identity: fallbackIdentity)
        let realItem = cmdItem([a])
        model.update(items: [realItem], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let (panel, retiring) = makeCommandTabFrameReporter(model: model, target: target)
        defer { panel.close() }

        // Appending the other owner's preview changes the single-card SwiftUI
        // branch to the scrolling branch. Both NSViews can briefly report the
        // real window under the same current frame generation.
        let fallback = CommandTabWindowDisplayItem(
            id: 1, identity: fallbackIdentity, title: "应用预览", isMinimized: false,
            canClose: false, isSelected: false, thumbnailResult: nil, canActivate: false
        )
        model.update(items: [realItem.replacingWindows(realItem.windows + [fallback])],
                     selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let generation = model.previewFrameGeneration
        retiring.update(target: target, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        retiring.layout()
        let replacement = addCommandTabFrameReporter(
            to: panel, model: model, target: target,
            frame: CGRect(x: 0, y: 80, width: 100, height: 100)
        )
        let fallbackReporter = addCommandTabFrameReporter(
            to: panel, model: model, target: fallbackTarget,
            frame: CGRect(x: 110, y: 80, width: 100, height: 100)
        )
        XCTAssertLessThan(retiring.frameOwner, replacement.frameOwner)

        // Force a positive old report; an unchanged rectangle would be
        // deduplicated and would not exercise the ownership race.
        retiring.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        retiring.layout()
        XCTAssertNil(model.handlePointer(.leftMouseDown, at: bodyA))
        retiring.detach()
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: bodyA), .activate(target))
        XCTAssertEqual(model.diagnosticMetadata()["frameCount"], .integer(2))
        _ = model.handlePointer(.mouseMoved, at: closeA)
        XCTAssertEqual(model.pointerHoveredTarget, target)
        _ = model.handlePointer(.leftMouseDown, at: closeA)
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: closeA), .close(target))
        _ = model.handlePointer(.mouseMoved, at: bodyB)
        XCTAssertEqual(model.pointerHoveredTarget, fallbackTarget)
        _ = model.handlePointer(.leftMouseDown, at: bodyB)
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: bodyB))
        let fallbackClose = CGPoint(x: 122, y: 12)
        _ = model.handlePointer(.leftMouseDown, at: fallbackClose)
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: fallbackClose))
        XCTAssertEqual(model.previewFrameGeneration, generation)
        XCTAssertEqual(fallbackReporter.window, panel)
        XCTAssertFalse(panel.isVisible)
    }

    func testRetiredFrameOwnerCannotResurrectUntilGenerationChanges() {
        let model = CommandTabOverlayModel()
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let (panel, older) = makeCommandTabFrameReporter(model: model, target: target)
        defer { panel.close() }
        let replacement = addCommandTabFrameReporter(
            to: panel, model: model, target: target,
            frame: CGRect(x: 0, y: 80, width: 100, height: 100)
        )
        let oldGeneration = model.previewFrameGeneration
        _ = model.handlePointer(.leftMouseDown, at: bodyA)
        replacement.detach()
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: bodyA))
        XCTAssertEqual(model.diagnosticMetadata()["frameCount"], .integer(0))

        older.frame = CGRect(x: 1, y: 80, width: 100, height: 100)
        older.layout()
        _ = model.handlePointer(.mouseMoved, at: bodyA)
        XCTAssertNil(model.pointerHoveredTarget)
        XCTAssertEqual(model.diagnosticMetadata()["frameCount"], .integer(0))

        model.clear()
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let generation = model.previewFrameGeneration
        XCTAssertNotEqual(generation, oldGeneration)
        older.update(target: target, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        older.layout()
        // The newer token belongs to an obsolete generation and must not
        // replace or erase the retained NSView's registration in this one.
        replacement.update(target: target, generation: oldGeneration, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: oldGeneration, owner: $2)
        })
        replacement.frame = CGRect(x: 110, y: 0, width: 100, height: 100)
        replacement.layout()
        replacement.detach()
        _ = model.handlePointer(.mouseMoved, at: bodyA)
        XCTAssertEqual(model.pointerHoveredTarget, target)
        _ = model.handlePointer(.leftMouseDown, at: bodyA)
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: bodyA), .activate(target))
        older.detach()
        XCTAssertEqual(model.diagnosticMetadata()["frameCount"], .integer(0))
        XCTAssertFalse(panel.isVisible)
    }

    func testCmdTabPartialCacheThenFreshPreservesOrderAndPendingFirstClick() {
        let model = CommandTabOverlayModel()
        let cachedImage = NSImage(size: NSSize(width: 20, height: 20))
        let freshImage = NSImage(size: NSSize(width: 24, height: 24))
        let capturedAt = Date().addingTimeInterval(-2)
        let cached: WindowThumbnailResult = .recentCache(cachedImage, timestamp: capturedAt)
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 1, identity: b)
        model.update(items: [cmdItem([a, b], thumbnails: [cached, nil])],
                     selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        model.setPreviewFrames([target: CGRect(x: 110, y: 0, width: 100, height: 100)])
        XCTAssertEqual(model.selectedItem?.windows.map(\.identity), [a, b])
        XCTAssertEqual(model.selectedItem?.windows[0].thumbnailResult?.cachedAt, capturedAt)
        XCTAssertNil(model.selectedItem?.windows[1].thumbnailResult)

        _ = model.handlePointer(.leftMouseDown, at: bodyB)
        XCTAssertTrue(model.hasPendingPointerPress)
        model.update(items: [cmdItem([a, b], thumbnails: [.fresh(freshImage), .fresh(freshImage)])],
                     selectedID: 0, previewTileWidth: 100, reduceMotion: true)

        XCTAssertEqual(model.selectedItem?.windows.map(\.identity), [a, b])
        XCTAssertTrue(model.selectedItem?.windows[1].thumbnailResult?.image === freshImage)
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: bodyB), .activate(target))
        XCTAssertFalse(model.hasPendingPointerPress)
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: bodyB))
    }

    func testDockLoadingCacheAndFreshUpdatesPreservePendingClose() {
        let model = DockWindowPreviewModel()
        let image = NSImage(size: NSSize(width: 20, height: 20))
        var closes = 0
        func row(_ result: WindowThumbnailResult?) -> DockPreviewRow {
            DockPreviewRow(id: 100, ownerProcessIdentifier: 10, ownerProcessLifetimeKey: "launch-a",
                           title: "Test", isMinimized: false, canActivate: true, isPreviewOnly: false,
                           canClose: true, thumbnailResult: result, action: {}, closeAction: { closes += 1 })
        }
        model.update(appName: "Test", icon: nil, rows: [row(nil)], canManageWindows: true)
        model.setPreviewFrames([100: CGRect(x: 0, y: 0, width: 100, height: 100)])
        model.handlePointer(.leftMouseDown, at: closeA)
        model.update(appName: "Test", icon: nil,
                     rows: [row(.recentCache(image, timestamp: Date().addingTimeInterval(-2)))],
                     canManageWindows: true)
        model.update(appName: "Test", icon: nil, rows: [row(.fresh(image))], canManageWindows: true)
        XCTAssertTrue(model.content.rows[0].thumbnailResult?.image === image)
        model.handlePointer(.leftMouseUp, at: closeA)
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertEqual(closes, 1)
    }

    func testFailedRefreshReplacesCachedPixelsWithoutRemovingRealWindow() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let cached: WindowThumbnailResult = .recentCache(image, timestamp: Date())
        let commandTab = CommandTabOverlayModel()
        commandTab.update(items: [cmdItem([a], thumbnails: [cached])],
                          selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        commandTab.update(items: [cmdItem([a], thumbnails: [.captureFailed])],
                          selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        XCTAssertEqual(commandTab.selectedItem?.windows.map(\.identity), [a])
        XCTAssertNil(commandTab.selectedItem?.windows[0].thumbnailResult?.image)

        let dock = DockWindowPreviewModel()
        func row(_ result: WindowThumbnailResult) -> DockPreviewRow {
            DockPreviewRow(id: 100, ownerProcessIdentifier: 10, ownerProcessLifetimeKey: "launch-a",
                           title: "Test", isMinimized: false, canActivate: true, isPreviewOnly: false,
                           canClose: true, thumbnailResult: result, action: {}, closeAction: {})
        }
        dock.update(appName: "Test", icon: nil, rows: [row(cached)], canManageWindows: true)
        dock.update(appName: "Test", icon: nil, rows: [row(.captureFailed)], canManageWindows: true)
        XCTAssertEqual(dock.content.rows.map(\.id), [100])
        XCTAssertNil(dock.content.rows[0].thumbnailResult?.image)
        XCTAssertTrue(dock.content.rows[0].canActivate)
    }

    func testCmdTabModelHoverThenPublishedSelectionDoesNotLoseFirstClick() {
        let model = CommandTabOverlayModel()
        let targetA = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        let targetB = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 1, identity: b)
        model.update(items: [cmdItem([a, b])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let frames = [targetA: CGRect(x: 0, y: 0, width: 100, height: 100),
                      targetB: CGRect(x: 110, y: 0, width: 100, height: 100)]
        model.setPreviewFrames(frames)
        _ = model.handlePointer(.leftMouseDown, at: bodyB)
        XCTAssertEqual(model.pointerHoveredTarget, targetB)
        model.update(items: [cmdItem([a, b], selected: 1)], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        model.setPreviewFrames(frames)
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: bodyB), .activate(targetB))
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: bodyB))
    }

    func testCmdTabModelRejectsOldFramesAfterWindowIdentityReplacement() {
        let model = CommandTabOverlayModel()
        let old = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let frames = [old: CGRect(x: 0, y: 0, width: 100, height: 100)]
        model.setPreviewFrames(frames)
        _ = model.handlePointer(.leftMouseDown, at: closeA)
        model.update(items: [cmdItem([b])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        model.setPreviewFrames(frames)
        XCTAssertFalse(model.isCurrent(old))
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: closeA))
        XCTAssertNil(model.pointerHoveredTarget)
    }

    func testCmdTabTransientLayoutChangeCancelsPressEvenIfFrameReturns() {
        let model = CommandTabOverlayModel()
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        let frames = [target: CGRect(x: 0, y: 0, width: 100, height: 100)]
        model.setPreviewFrames(frames)
        _ = model.handlePointer(.leftMouseDown, at: bodyA)
        model.setPreviewFrames([target: CGRect(x: 1, y: 0, width: 100, height: 100)])
        model.setPreviewFrames(frames)
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: bodyA))
    }

    func testCmdTabCapabilityRevocationCancelsPendingClose() {
        let model = CommandTabOverlayModel()
        let target = CommandTabPreviewTarget(applicationIndex: 0, windowIndex: 0, identity: a)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        model.setPreviewFrames([target: CGRect(x: 0, y: 0, width: 100, height: 100)])
        _ = model.handlePointer(.leftMouseDown, at: closeA)
        model.update(items: [cmdItem([a], canClose: false)], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        model.update(items: [cmdItem([a])], selectedID: 0, previewTileWidth: 100, reduceMotion: true)
        XCTAssertNil(model.handlePointer(.leftMouseUp, at: closeA))
    }

    private func addDockFrameReporter(
        to panel: NSPanel,
        model: DockWindowPreviewModel,
        id: Int,
        frame: CGRect
    ) -> WindowPreviewFrameReportingView<Int> {
        let generation = model.previewFrameGeneration
        let reporter = WindowPreviewFrameReportingView(target: id, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        reporter.frame = frame
        panel.contentView!.addSubview(reporter)
        reporter.layout()
        return reporter
    }

    func testDockRetainedReporterRestoresSameRectangleAfterGeometryReset() {
        let model = DockWindowPreviewModel()
        var activated = 0
        var closed = 0
        let row = DockPreviewRow(id: 100, title: "Test", isMinimized: false, canActivate: true,
                                 isPreviewOnly: false, canClose: true, thumbnailResult: nil,
                                 action: { activated += 1 }, closeAction: { closed += 1 })
        model.update(appName: "Test", icon: nil, rows: [row], canManageWindows: true)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        defer { panel.close() }
        let reporter = addDockFrameReporter(to: panel, model: model, id: row.id,
                                            frame: CGRect(x: 0, y: 80, width: 100, height: 100))
        let oldGeneration = model.previewFrameGeneration
        model.handlePointer(.leftMouseDown, at: bodyA)
        XCTAssertEqual(model.hoveredRowID, row.id)

        // The same NSView can survive a hide/re-show or a neighboring row's
        // removal. Its unchanged rectangle must be registered in the new table.
        model.resetPointerGeometry()
        let generation = model.previewFrameGeneration
        XCTAssertNotEqual(generation, oldGeneration)
        model.handlePointer(.mouseMoved, at: bodyA)
        XCTAssertNil(model.hoveredRowID)
        reporter.update(target: row.id, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        reporter.layout()
        model.handlePointer(.mouseMoved, at: bodyA)
        XCTAssertEqual(model.hoveredRowID, row.id)
        model.handlePointer(.leftMouseUp, at: bodyA)
        XCTAssertEqual(activated, 0, "Reset must not carry an earlier press into this presentation")
        model.setPreviewFrame(nil, for: row.id, generation: oldGeneration, owner: reporter.frameOwner)
        model.handlePointer(.leftMouseDown, at: bodyA)
        model.handlePointer(.leftMouseUp, at: bodyA)
        XCTAssertEqual(activated, 1)
        model.handlePointer(.leftMouseDown, at: closeA)
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testDockRetiringReporterCannotEraseOrRestoreReplacementFrame() {
        let model = DockWindowPreviewModel()
        var closed = 0
        let row = DockPreviewRow(id: 100, title: "Test", isMinimized: false, canActivate: true,
                                 isPreviewOnly: false, canClose: true, thumbnailResult: nil,
                                 action: {}, closeAction: { closed += 1 })
        model.update(appName: "Test", icon: nil, rows: [row], canManageWindows: true)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 180),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        defer { panel.close() }
        let old = addDockFrameReporter(to: panel, model: model, id: row.id,
                                      frame: CGRect(x: 0, y: 80, width: 100, height: 100))
        let replacement = addDockFrameReporter(to: panel, model: model, id: row.id,
                                              frame: CGRect(x: 0, y: 80, width: 100, height: 100))
        XCTAssertLessThan(old.frameOwner, replacement.frameOwner)
        model.handlePointer(.leftMouseDown, at: closeA)
        old.frame = CGRect(x: 110, y: 80, width: 100, height: 100)
        old.layout()
        old.detach()
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(model.hoveredRowID, row.id)

        replacement.detach()
        let generation = model.previewFrameGeneration
        old.update(target: row.id, generation: generation, onOwnedChange: {
            model.setPreviewFrame($1, for: $0, generation: generation, owner: $2)
        })
        old.frame = CGRect(x: 0, y: 80, width: 100, height: 100)
        old.layout()
        model.handlePointer(.mouseMoved, at: closeA)
        XCTAssertNil(model.hoveredRowID, "The retired owner cannot resurrect its old rectangle")
        model.handlePointer(.leftMouseDown, at: closeA)
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testDockRecoveryKeepsHealthyOwnerAndRestoresOnlyExactOwnerPixelsAndActions() {
        var activated: [pid_t] = []
        let healthyImage = NSImage(size: NSSize(width: 20, height: 20))
        let recoveredImage = NSImage(size: NSSize(width: 30, height: 20))
        let healthy = DockPreviewRow(
            id: 100, ownerProcessIdentifier: 10, ownerProcessLifetimeKey: "10-first",
            title: "Healthy", isMinimized: false, canActivate: true, isPreviewOnly: false,
            canClose: true, thumbnailResult: .fresh(healthyImage),
            action: { activated.append(10) }, closeAction: {}
        )
        let previewOnly = DockPreviewRow(
            id: 200, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-first",
            title: "Preview", isMinimized: false, canActivate: false, isPreviewOnly: true,
            canClose: false, thumbnailResult: .fresh(recoveredImage), action: {}, closeAction: {}
        )
        let restored = DockPreviewRow(
            id: 200, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-first",
            title: "Restored", isMinimized: false, canActivate: true, isPreviewOnly: false,
            canClose: true, thumbnailResult: nil, action: { activated.append(20) }, closeAction: {}
        )
        let current = [healthy, previewOnly]
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: current, requestedOwners: [20: "20-first"]
        )
        let rows = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: current, refreshed: [restored], request: request
        )!.rows
        XCTAssertEqual(rows.map(\.id), [100, 200])
        XCTAssertTrue(rows[0].thumbnailResult?.image === healthyImage)
        XCTAssertTrue(rows[1].thumbnailResult?.image === recoveredImage)
        XCTAssertTrue(rows[1].canActivate)
        XCTAssertTrue(rows[1].canClose)
        rows[0].action()
        rows[1].action()
        XCTAssertEqual(activated, [10, 20])

        let model = DockWindowPreviewModel()
        model.update(appName: "Test", icon: nil, rows: current, canManageWindows: true)
        let generation = model.previewFrameGeneration
        model.update(appName: "Test", icon: nil, rows: rows, canManageWindows: true)
        XCTAssertEqual(model.previewFrameGeneration, generation, "Capability restoration does not move unchanged cards")
        model.setPreviewFrames([100: CGRect(x: 0, y: 0, width: 100, height: 100)])
        model.handlePointer(.leftMouseDown, at: bodyA)
        model.update(appName: "Test", icon: nil,
                     rows: [rows[0], rows[1].replacingThumbnailResult(.captureFailed)], canManageWindows: true)
        model.handlePointer(.leftMouseUp, at: bodyA)
        XCTAssertEqual(activated, [10, 20, 10], "Another owner's image completion must not cancel this click")
    }

    func testDockRecoveryRejectsPixelsWithoutOperationsAndWrongProcessLaunch() {
        let previewOnly = DockPreviewRow(
            id: 200, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-first",
            title: "Preview", isMinimized: false, canActivate: false, isPreviewOnly: true,
            canClose: false, thumbnailResult: .fresh(NSImage(size: NSSize(width: 20, height: 20))),
            action: {}, closeAction: {}
        )
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: [previewOnly], requestedOwners: [20: "20-first"]
        )
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [previewOnly], refreshed: [previewOnly], request: request
        ))
        let differentLaunch = DockPreviewRow(
            id: 200, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-second",
            title: "Wrong launch", isMinimized: false, canActivate: true, isPreviewOnly: false,
            canClose: true, thumbnailResult: nil, action: {}, closeAction: {}
        )
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [previewOnly], refreshed: [differentLaunch], request: request
        ))
    }

    func testDockRecoveryRejectsDifferentWindowAndDuplicateTargets() {
        let old = DockPreviewRow(
            id: 200, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-first",
            title: "Old", isMinimized: false, canActivate: false, isPreviewOnly: true,
            canClose: false, thumbnailResult: .fresh(NSImage(size: NSSize(width: 20, height: 20))),
            action: {}, closeAction: {}
        )
        let new = DockPreviewRow(
            id: 201, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-first",
            title: "New", isMinimized: false, canActivate: true, isPreviewOnly: false,
            canClose: true, thumbnailResult: nil, action: {}, closeAction: {}
        )
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: [old], requestedOwners: [20: "20-first"]
        )
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [old], refreshed: [new], request: request
        ))
        let exact = DockPreviewRow(
            id: 200, ownerProcessIdentifier: 20, ownerProcessLifetimeKey: "20-first",
            title: "Exact", isMinimized: false, canActivate: true, isPreviewOnly: false,
            canClose: true, thumbnailResult: nil, action: {}, closeAction: {}
        )
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [old], refreshed: [exact, exact], request: request
        ))
    }

    private func recoveryRow(
        id: Int,
        owner: pid_t = 10,
        lifetime: String = "10-first",
        actionable: Bool,
        image: NSImage? = nil,
        action: @escaping () -> Void = {},
        close: @escaping () -> Void = {}
    ) -> DockPreviewRow {
        DockPreviewRow(
            id: id, ownerProcessIdentifier: owner, ownerProcessLifetimeKey: lifetime,
            title: "Test", isMinimized: false, canActivate: actionable, isPreviewOnly: !actionable,
            canClose: actionable, thumbnailResult: image.map(WindowThumbnailResult.fresh),
            action: action, closeAction: close
        )
    }

    func testDockPartialRecoveryRequiresEachMissingWindowAndKeepsHealthySibling() {
        var actions: [String] = []
        var closed: [String] = []
        let images = (0..<3).map { _ in NSImage(size: NSSize(width: 20, height: 20)) }
        let a = recoveryRow(id: 100, actionable: true, image: images[0],
                            action: { actions.append("A-original") }, close: { closed.append("A-original") })
        let b = recoveryRow(id: 200, actionable: false, image: images[1])
        let c = recoveryRow(id: 300, actionable: false, image: images[2])
        let current = [a, b, c]
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: current, requestedOwners: [10: "10-first"]
        )
        XCTAssertEqual(request.missingTargets, [
            WindowPreviewIdentity(processID: 10, windowID: 200),
            WindowPreviewIdentity(processID: 10, windowID: 300)
        ])
        let refreshedA = recoveryRow(id: 100, actionable: true,
                                     action: { actions.append("A-new") }, close: { closed.append("A-new") })
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: current, refreshed: [refreshedA], request: request
        ), "An already healthy sibling is not recovery progress")

        let refreshedB = recoveryRow(id: 200, actionable: true,
                                     action: { actions.append("B") }, close: { closed.append("B") })
        let afterB = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: current,
            refreshed: [recoveryRow(id: 100, actionable: false), refreshedB],
            request: request
        )!
        XCTAssertEqual(afterB.rows.map(\.id), [100, 200, 300])
        XCTAssertEqual(afterB.rows.map(\.canActivate), [true, true, false])
        XCTAssertEqual(afterB.recoveredTargets, [WindowPreviewIdentity(processID: 10, windowID: 200)])
        XCTAssertEqual(afterB.remainingRequest.missingTargets, [WindowPreviewIdentity(processID: 10, windowID: 300)])
        XCTAssertEqual(afterB.remainingRequest.pendingOwners, [10])
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: afterB.rows, refreshed: [refreshedA, refreshedB], request: afterB.remainingRequest
        ), "C remains pending even when both healthy siblings reappear")

        let afterC = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: afterB.rows,
            refreshed: [recoveryRow(id: 300, actionable: true,
                                    action: { actions.append("C") }, close: { closed.append("C") })],
            request: afterB.remainingRequest
        )!
        XCTAssertEqual(afterC.rows.map(\.id), [100, 200, 300])
        XCTAssertTrue(afterC.rows.allSatisfy(\.canActivate))
        XCTAssertTrue(afterC.remainingRequest.pendingOwners.isEmpty)
        for index in afterC.rows.indices {
            XCTAssertTrue(afterC.rows[index].thumbnailResult?.image === images[index])
            afterC.rows[index].action()
            afterC.rows[index].closeAction()
        }
        XCTAssertEqual(actions, ["A-original", "B", "C"])
        XCTAssertEqual(closed, ["A-original", "B", "C"])
    }

    func testDockPartialRecoveryIgnoresForeignOrUnrequestedWindows() {
        let current = [recoveryRow(id: 100, actionable: true), recoveryRow(id: 200, actionable: false)]
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: current, requestedOwners: [10: "10-first"]
        )
        let foreign = recoveryRow(id: 200, owner: 20, lifetime: "20-first", actionable: true)
        let wrongLifetime = recoveryRow(id: 200, lifetime: "10-second", actionable: true)
        let differentWindow = recoveryRow(id: 300, actionable: true)
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: current, refreshed: [foreign, wrongLifetime, differentWindow], request: request
        ))
        let update = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: current,
            refreshed: [foreign, wrongLifetime, differentWindow, recoveryRow(id: 200, actionable: true)],
            request: request
        )!
        XCTAssertEqual(update.rows.map(\.id), [100, 200])
        XCTAssertEqual(update.recoveredTargets, [WindowPreviewIdentity(processID: 10, windowID: 200)])
        XCTAssertTrue(update.remainingRequest.pendingOwners.isEmpty)
    }

    func testDockPartialRecoveryCannotResurrectAWindowMissingFromCurrentPresentation() {
        let a = recoveryRow(id: 100, actionable: true)
        let b = recoveryRow(id: 200, actionable: false)
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: [a, b], requestedOwners: [10: "10-first"]
        )
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [a], refreshed: [recoveryRow(id: 200, actionable: true)], request: request
        ))
    }

    func testDockEmptyOwnerDiscoveryAcceptsRealTargetsAndRemovesOnlySyntheticPlaceholder() {
        let placeholder = recoveryRow(id: -21, actionable: false)
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: [placeholder], requestedOwners: [10: "10-first"], discoveryOwners: [10]
        )
        XCTAssertTrue(request.missingTargets.isEmpty)
        XCTAssertEqual(request.pendingOwners, [10])
        let update = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [placeholder], refreshed: [recoveryRow(id: 100, actionable: true)], request: request
        )!
        XCTAssertEqual(update.rows.map(\.id), [100])
        XCTAssertNil(update.rows[0].thumbnailResult)
        XCTAssertTrue(update.remainingRequest.pendingOwners.isEmpty)
    }

    func testDockDiscoveryKeepsPositiveUnboundWindowWhenAnotherWindowIsFound() {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let old = recoveryRow(id: 200, actionable: false, image: image)
        let request = DockPreviewOperationRecoveryPolicy.makeRequest(
            current: [old], requestedOwners: [10: "10-first"], discoveryOwners: [10]
        )
        let discovered = recoveryRow(id: 201, actionable: true)
        let first = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: [old], refreshed: [discovered], request: request
        )!
        XCTAssertEqual(first.rows.map(\.id), [200, 201])
        XCTAssertFalse(first.rows[0].canActivate)
        XCTAssertTrue(first.rows[0].thumbnailResult?.image === image)
        XCTAssertNil(first.rows[1].thumbnailResult)
        XCTAssertEqual(first.remainingRequest.missingTargets, [WindowPreviewIdentity(processID: 10, windowID: 200)])
        XCTAssertTrue(first.remainingRequest.discoveryOwners.isEmpty)
        XCTAssertNil(DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: first.rows, refreshed: [discovered], request: first.remainingRequest
        ))
        let second = DockPreviewOperationRecoveryPolicy.recoverMissingWindows(
            current: first.rows, refreshed: [recoveryRow(id: 200, actionable: true)], request: first.remainingRequest
        )!
        XCTAssertEqual(second.rows.map(\.id), [200, 201])
        XCTAssertTrue(second.rows.allSatisfy(\.canActivate))
        XCTAssertTrue(second.rows[0].thumbnailResult?.image === image)
        XCTAssertTrue(second.remainingRequest.pendingOwners.isEmpty)
    }

    func testDockModelHoverAndCloseUseSameTargetAndDispatchExactlyOnce() {
        let model = DockWindowPreviewModel()
        var activated = 0
        var closed = 0
        let row = DockPreviewRow(id: 100, title: "Test", isMinimized: false, canActivate: true,
                                 isPreviewOnly: false, canClose: true, thumbnailResult: nil,
                                 action: { activated += 1 }, closeAction: { closed += 1 })
        model.update(appName: "Test", icon: nil, rows: [row], canManageWindows: true)
        model.setPreviewFrames([100: CGRect(x: 0, y: 0, width: 100, height: 100)])
        model.handlePointer(.mouseMoved, at: closeA)
        XCTAssertEqual(model.hoveredRowID, 100)
        model.handlePointer(.leftMouseDown, at: closeA)
        model.update(appName: "Test", icon: nil, rows: [row], canManageWindows: true)
        model.handlePointer(.leftMouseUp, at: closeA)
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(activated, 0)
        model.resetPointerGeometry()
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertNil(model.hoveredRowID)
        XCTAssertEqual(closed, 1)
    }

    func testDockModelKeepsCanonicalWindowWhenThumbnailCaptureFails() {
        let model = DockWindowPreviewModel()
        let row = DockPreviewRow(
            id: 100,
            title: "Real window",
            isMinimized: false,
            canActivate: true,
            isPreviewOnly: false,
            canClose: true,
            thumbnailResult: .captureFailed,
            action: {},
            closeAction: {}
        )
        model.update(appName: "Test", icon: nil, rows: [row], canManageWindows: true)
        XCTAssertEqual(model.content.rows.map(\.id), [100])
    }

    func testDockSharedPreviewSecondInstanceDispatchesItsOwnActivationAndClose() {
        let model = DockWindowPreviewModel()
        var activated: [pid_t] = []
        var closed: [pid_t] = []
        let rows = [(100, pid_t(10)), (200, pid_t(20))].map { id, owner in
            DockPreviewRow(
                id: id,
                ownerProcessIdentifier: owner,
                title: "Chrome",
                isMinimized: false,
                canActivate: true,
                isPreviewOnly: false,
                canClose: true,
                thumbnailResult: nil,
                action: { activated.append(owner) },
                closeAction: { closed.append(owner) }
            )
        }
        model.update(appName: "Chrome", icon: nil, rows: rows, canManageWindows: true)
        model.setPreviewFrames([
            100: CGRect(x: 0, y: 0, width: 100, height: 100),
            200: CGRect(x: 110, y: 0, width: 100, height: 100)
        ])

        model.handlePointer(.leftMouseDown, at: bodyB)
        model.handlePointer(.leftMouseUp, at: bodyB)
        model.handlePointer(.leftMouseUp, at: bodyB)
        let closeB = CGPoint(x: 122, y: 12)
        model.handlePointer(.leftMouseDown, at: closeB)
        model.handlePointer(.leftMouseUp, at: closeB)
        model.handlePointer(.leftMouseUp, at: closeB)

        XCTAssertEqual(activated, [20])
        XCTAssertEqual(closed, [20])
        XCTAssertEqual(model.hoveredRowID, 200)
    }

    func testDockModelOwnerReplacementCancelsPendingActivationAndClose() {
        for point in [bodyA, closeA] {
            let model = DockWindowPreviewModel()
            var operations: [pid_t] = []
            func row(owner: pid_t) -> DockPreviewRow {
                DockPreviewRow(
                    id: 100,
                    ownerProcessIdentifier: owner,
                    title: "Chrome",
                    isMinimized: false,
                    canActivate: true,
                    isPreviewOnly: false,
                    canClose: true,
                    thumbnailResult: nil,
                    action: { operations.append(owner) },
                    closeAction: { operations.append(owner) }
                )
            }
            let frames = [100: CGRect(x: 0, y: 0, width: 100, height: 100)]
            model.update(appName: "Chrome", icon: nil, rows: [row(owner: 10)], canManageWindows: true)
            model.setPreviewFrames(frames)
            model.handlePointer(.leftMouseDown, at: point)

            // WindowServer may reuse the numeric ID after its former owner
            // exits. A fresh layout for the replacement must not revive a press.
            model.update(appName: "Chrome", icon: nil, rows: [row(owner: 20)], canManageWindows: true)
            XCTAssertNil(model.hoveredRowID)
            model.setPreviewFrames(frames)
            model.handlePointer(.leftMouseUp, at: point)
            XCTAssertTrue(operations.isEmpty)

            model.handlePointer(.leftMouseDown, at: point)
            model.handlePointer(.leftMouseUp, at: point)
            XCTAssertEqual(operations, [20])
        }
    }

    func testDockModelProcessLifetimeReplacementCancelsPendingClick() {
        let model = DockWindowPreviewModel()
        var operations: [String] = []
        func row(lifetime: String) -> DockPreviewRow {
            DockPreviewRow(
                id: 100,
                ownerProcessIdentifier: 10,
                ownerProcessLifetimeKey: lifetime,
                title: "Chrome",
                isMinimized: false,
                canActivate: true,
                isPreviewOnly: false,
                canClose: true,
                thumbnailResult: nil,
                action: { operations.append(lifetime) },
                closeAction: { operations.append(lifetime) }
            )
        }
        let frames = [100: CGRect(x: 0, y: 0, width: 100, height: 100)]
        model.update(appName: "Chrome", icon: nil, rows: [row(lifetime: "old-launch")], canManageWindows: true)
        model.setPreviewFrames(frames)
        model.handlePointer(.leftMouseDown, at: bodyA)

        // A new process can reuse both PID and window ID; its launch identity
        // must prevent a press intended for the old process from reaching it.
        model.update(appName: "Chrome", icon: nil, rows: [row(lifetime: "new-launch")], canManageWindows: true)
        XCTAssertNil(model.hoveredRowID)
        model.setPreviewFrames(frames)
        model.handlePointer(.leftMouseUp, at: bodyA)
        XCTAssertTrue(operations.isEmpty)

        model.handlePointer(.leftMouseDown, at: bodyA)
        model.handlePointer(.leftMouseUp, at: bodyA)
        XCTAssertEqual(operations, ["new-launch"])
    }

    func testDockThumbnailExpirationPreservesOwnerAndPendingClick() {
        let model = DockWindowPreviewModel()
        var activated: [pid_t] = []
        var closed: [pid_t] = []
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let row = DockPreviewRow(
            id: 200,
            ownerProcessIdentifier: 20,
            ownerProcessLifetimeKey: "second-launch",
            title: "Second Chrome instance",
            isMinimized: false,
            canActivate: true,
            isPreviewOnly: false,
            canClose: true,
            thumbnailResult: .recentCache(NSImage(size: NSSize(width: 80, height: 60)), timestamp: capturedAt),
            action: { activated.append(20) },
            closeAction: { closed.append(20) }
        )
        model.update(appName: "Chrome", icon: nil, rows: [row], canManageWindows: true)
        model.setPreviewFrames([200: CGRect(x: 0, y: 0, width: 100, height: 100)])
        model.handlePointer(.leftMouseDown, at: bodyA)
        XCTAssertNil(model.expireRecentCaches(
            now: capturedAt.addingTimeInterval(WindowThumbnailProvider.recentCacheTTL)
        ))

        let replacement = model.content.rows[0]
        XCTAssertEqual(replacement.id, 200)
        XCTAssertEqual(replacement.ownerProcessIdentifier, 20)
        XCTAssertEqual(replacement.ownerProcessLifetimeKey, "second-launch")
        XCTAssertEqual(replacement.title, row.title)
        guard case .notEnumerated? = replacement.thumbnailResult else {
            return XCTFail("Expired thumbnail must be replaced without changing its window owner")
        }
        model.handlePointer(.leftMouseUp, at: bodyA)
        model.handlePointer(.leftMouseDown, at: closeA)
        model.handlePointer(.leftMouseUp, at: closeA)
        XCTAssertEqual(activated, [20])
        XCTAssertEqual(closed, [20])
    }

    private func dockCandidate(
        _ processIdentifier: pid_t,
        bundleIdentifier: String? = "com.google.Chrome",
        bundlePath: String? = "/Applications/Google Chrome.app",
        localizedName: String? = "Google Chrome",
        isRegular: Bool = true
    ) -> DockApplicationIdentityCandidate {
        DockApplicationIdentityCandidate(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            localizedName: localizedName,
            isRegular: isRegular
        )
    }

    func testDockSharedChromePreviewUsesSortedUniqueProcessesAtCanonicalPath() {
        let canonicalPath = DockApplicationIdentityPolicy.normalizedApplicationURL(
            from: "/Applications/./Google Chrome.app"
        )?.path
        XCTAssertEqual(canonicalPath, "/Applications/Google Chrome.app")
        let candidates = [
            dockCandidate(20),
            dockCandidate(10, bundlePath: canonicalPath),
            dockCandidate(20)
        ]
        XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
            targetBundleIdentifier: "com.google.Chrome",
            targetBundlePath: "/Applications/Google Chrome.app",
            title: "Google Chrome",
            candidates: candidates
        ), [10, 20])
    }

    func testDockSharedPreviewDoesNotCombineSameBundleAtDifferentPaths() {
        let candidates = [
            dockCandidate(10),
            dockCandidate(20, bundlePath: "/Applications/Other Chrome.app")
        ]
        for (path, expectedPID) in [
            ("/Applications/Google Chrome.app", pid_t(10)),
            ("/Applications/Other Chrome.app", pid_t(20))
        ] {
            XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
                targetBundleIdentifier: "com.google.Chrome",
                targetBundlePath: path,
                title: "Google Chrome",
                candidates: candidates
            ), [expectedPID])
        }
    }

    func testDockSharedPreviewMissingTargetPathCannotBorrowBundleOrTitleMatch() {
        XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
            targetBundleIdentifier: "com.google.Chrome",
            targetBundlePath: "/Applications/Stopped Chrome.app",
            title: "Google Chrome",
            candidates: [dockCandidate(10)]
        ), [])
    }

    func testDockSharedPreviewKeepsTwoWechatInstallationsSeparate() {
        let paths = ["/Applications/WeChat.app", "/Applications/WeChat-Work2.app"]
        let candidates = paths.enumerated().map { index, path in
            dockCandidate(
                pid_t(index + 10),
                bundleIdentifier: "com.tencent.xinWeChat",
                bundlePath: path,
                localizedName: "微信"
            )
        }
        for (index, path) in paths.enumerated() {
            XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
                targetBundleIdentifier: "com.tencent.xinWeChat",
                targetBundlePath: path,
                title: "微信",
                candidates: candidates
            ), [pid_t(index + 10)])
        }
    }

    func testDockSharedPreviewExcludesHelpersAndInvalidProcessesBeforeGrouping() {
        let candidates = [
            dockCandidate(10),
            dockCandidate(40, bundleIdentifier: "com.example.helper", isRegular: false),
            dockCandidate(0, bundleIdentifier: nil),
            dockCandidate(-1, bundleIdentifier: "com.example.other")
        ]
        XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
            targetBundleIdentifier: "com.google.Chrome",
            targetBundlePath: "/Applications/Google Chrome.app",
            title: "Google Chrome",
            candidates: candidates
        ), [10])
    }

    func testDockSharedPreviewRejectsWholeGroupWithConflictingOrMissingBundle() {
        let targetIdentifiers: [String?] = ["com.google.Chrome", nil]
        let uncertainIdentifiers: [String?] = ["com.example.other", nil]
        for targetIdentifier in targetIdentifiers {
            for uncertainIdentifier in uncertainIdentifiers {
                XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
                    targetBundleIdentifier: targetIdentifier,
                    targetBundlePath: "/Applications/Google Chrome.app",
                    title: "Google Chrome",
                    candidates: [dockCandidate(10), dockCandidate(20, bundleIdentifier: uncertainIdentifier)]
                ), [])
            }
        }
    }

    func testDockPreviewWithoutURLStillRequiresUniqueProcess() {
        let bundleIdentifiers: [String?] = [nil, "com.google.Chrome"]
        for bundleIdentifier in bundleIdentifiers {
            XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
                targetBundleIdentifier: bundleIdentifier,
                targetBundlePath: nil,
                title: "Google Chrome",
                candidates: [dockCandidate(10), dockCandidate(20)]
            ), [])
            XCTAssertEqual(DockApplicationIdentityPolicy.previewProcessIdentifiers(
                targetBundleIdentifier: bundleIdentifier,
                targetBundlePath: nil,
                title: "Google Chrome",
                candidates: [dockCandidate(10)]
            ), [10])
        }
    }

    func testDockReverseSelectionStillRejectsMultipleProcessesAtOnePath() {
        XCTAssertNil(DockApplicationIdentityPolicy.selectProcessIdentifier(
            targetBundleIdentifier: "com.google.Chrome",
            targetBundlePath: "/Applications/Google Chrome.app",
            title: "Google Chrome",
            candidates: [dockCandidate(10), dockCandidate(20)]
        ))
    }

    func testDockIdentityUsesExactPathForSameNamedApplications() {
        let candidates = [
            DockApplicationIdentityCandidate(
                processIdentifier: 10,
                bundleIdentifier: "com.example.chat",
                bundlePath: "/Applications/Chat.app",
                localizedName: "Chat",
                isRegular: true
            ),
            DockApplicationIdentityCandidate(
                processIdentifier: 20,
                bundleIdentifier: "com.example.chat.work",
                bundlePath: "/Applications/Chat-Work.app",
                localizedName: "Chat",
                isRegular: true
            )
        ]
        XCTAssertEqual(
            DockApplicationIdentityPolicy.selectProcessIdentifier(
                targetBundleIdentifier: "com.example.chat.work",
                targetBundlePath: "/Applications/Chat-Work.app",
                title: "Chat",
                candidates: candidates
            ),
            20
        )
    }

    func testDockIdentityRejectsAmbiguousSameNameWithoutURL() {
        let candidates = [10, 20].map {
            DockApplicationIdentityCandidate(
                processIdentifier: pid_t($0),
                bundleIdentifier: "com.example.chat.\($0)",
                bundlePath: "/Applications/Chat-\($0).app",
                localizedName: "Chat",
                isRegular: true
            )
        }
        XCTAssertNil(DockApplicationIdentityPolicy.selectProcessIdentifier(
            targetBundleIdentifier: nil,
            targetBundlePath: nil,
            title: "Chat",
            candidates: candidates
        ))
    }

    func testDockIdentityNormalizesPlainFilesystemPath() {
        XCTAssertEqual(
            DockApplicationIdentityPolicy.normalizedApplicationURL(
                from: "/Applications/Chat-Work.app"
            )?.path,
            "/Applications/Chat-Work.app"
        )
    }

    func testPreviewOnlySelectionNeverManufacturesMultipleWindowCards() {
        let small = WindowThumbnailDiscoveredWindow(
            request: WindowThumbnailRequest(
                title: "",
                occurrence: 0,
                bounds: CGRect(x: 0, y: 0, width: 120, height: 80),
                windowID: 11
            ),
            result: .fresh(NSImage(size: NSSize(width: 12, height: 8)))
        )
        let document = WindowThumbnailDiscoveredWindow(
            request: WindowThumbnailRequest(
                title: "Document",
                occurrence: 0,
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                windowID: 22
            ),
            result: .fresh(NSImage(size: NSSize(width: 90, height: 70)))
        )
        let selected = WindowPreviewOnlySelectionPolicy.selectOne(
            from: [small, document]
        )
        XCTAssertEqual(selected?.request.windowID, 22)
    }

    func testPreviewOnlySelectionRejectsUnusableSurfaces() {
        let unavailable = WindowThumbnailDiscoveredWindow(
            request: WindowThumbnailRequest(
                title: "Helper",
                occurrence: 0,
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                windowID: 33
            ),
            result: .captureFailed
        )
        XCTAssertNil(WindowPreviewOnlySelectionPolicy.selectOne(
            from: [unavailable]
        ))
    }

    func testEmptyShellWithShadowAndCloseDotIsNotContent() {
        let image = makeImage { context in
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            context.setFillColor(CGColor(gray: 0.94, alpha: 1))
            context.fill(CGRect(x: 4, y: 4, width: 72, height: 72))
            context.setFillColor(CGColor(gray: 0.25, alpha: 1))
            context.fillEllipse(in: CGRect(x: 7, y: 70, width: 4, height: 4))
        }
        XCTAssertFalse(WindowThumbnailProvider.hasMeaningfulVisualContent(image))
    }

    func testRealDocumentMayHaveUniformContent() {
        let image = makeImage { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        XCTAssertFalse(WindowThumbnailProvider.hasMeaningfulVisualContent(image))
        XCTAssertTrue(WindowThumbnailProvider.hasMeaningfulVisualContent(image, allowsUniformContent: true))
    }

    func testTransparentSurfaceIsNeverAValidDocumentImage() {
        XCTAssertFalse(WindowThumbnailProvider.hasMeaningfulVisualContent(makeImage { _ in }, allowsUniformContent: true))
    }

    func testActualContentSurvivesFiltering() {
        let image = makeImage { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 12, y: 30, width: 55, height: 4))
            context.fill(CGRect(x: 12, y: 45, width: 40, height: 4))
        }
        XCTAssertTrue(WindowThumbnailProvider.hasMeaningfulVisualContent(image))
    }

    func testOneCloseDotIsNotDocumentEvidence() {
        XCTAssertFalse(WindowPreviewCaptureEvidence.allowsUniformContent(hasDocument: false, hasClose: true, hasMinimize: false, hasZoom: false))
        XCTAssertTrue(WindowPreviewCaptureEvidence.allowsUniformContent(hasDocument: true, hasClose: false, hasMinimize: false, hasZoom: false))
        XCTAssertTrue(WindowPreviewCaptureEvidence.allowsUniformContent(hasDocument: false, hasClose: true, hasMinimize: true, hasZoom: false))
    }

    func testXCTestHostDoesNotBootstrapBusinessServices() {
        XCTAssertTrue(AppDelegate.isRunningUnitTests)
    }

    private func makeImage(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }
}
