import AppKit
import SwiftUI
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
        model.update(items: [cmdItem([a, b], thumbnails: [.fresh(freshImage), .fresh(freshImage)])],
                     selectedID: 0, previewTileWidth: 100, reduceMotion: true)

        XCTAssertEqual(model.selectedItem?.windows.map(\.identity), [a, b])
        XCTAssertTrue(model.selectedItem?.windows[1].thumbnailResult?.image === freshImage)
        XCTAssertEqual(model.handlePointer(.leftMouseUp, at: bodyB), .activate(target))
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
