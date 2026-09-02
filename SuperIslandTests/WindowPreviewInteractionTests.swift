import AppKit
import XCTest
@testable import SuperIsland

@MainActor
final class WindowPreviewInteractionTests: XCTestCase {
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

    private func cmdItem(_ identities: [WindowPreviewIdentity], selected: Int = 0, canClose: Bool = true) -> CommandTabDisplayItem {
        CommandTabDisplayItem(id: 0, appName: "Test", icon: nil, isLoading: false,
                              windows: identities.enumerated().map { index, identity in
            CommandTabWindowDisplayItem(id: index, identity: identity, title: "Test", isMinimized: false,
                                        canClose: canClose, isSelected: index == selected, thumbnailResult: nil)
        })
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
