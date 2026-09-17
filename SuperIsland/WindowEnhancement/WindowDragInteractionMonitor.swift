import AppKit
import ApplicationServices
import QuartzCore
import SwiftUI

private enum WindowSnapIslandMetrics {
    static let padding: CGFloat = 10
    static let itemWidth: CGFloat = 135
    static let itemSpacing: CGFloat = 8
    /// Keep the AppKit panel, SwiftUI content and pointer hit regions on one
    /// geometry source. The four cards render at exactly this total width.
    static let width: CGFloat = padding * 2 + itemWidth * 4 + itemSpacing * 3
    static let height: CGFloat = 112
    static let topInset: CGFloat = 34
    static let markerWidth: CGFloat = 42
    static let markerHeight: CGFloat = 26
    static let markerTopInset: CGFloat = 4
    static let activationWidth: CGFloat = 112
    static let activationHeight: CGFloat = 34
    static let expansionDelay: TimeInterval = 0.14
    static let retentionPadding: CGFloat = 24
}

private enum WindowSnapPreset: Int, CaseIterable, Identifiable {
    case verticalHalves
    case horizontalHalves
    case primaryAndStack
    case quarters

    var id: Int { rawValue }

    var slots: [WindowLayout] {
        switch self {
        case .verticalHalves: [.leftHalf, .rightHalf]
        case .horizontalHalves: [.topHalf, .bottomHalf]
        case .primaryAndStack: [.leftHalf, .topRightQuarter, .bottomRightQuarter]
        case .quarters: [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]
        }
    }

    func layout(normalizedX x: CGFloat, normalizedY y: CGFloat) -> WindowLayout {
        switch self {
        case .verticalHalves:
            x < 0.5 ? .leftHalf : .rightHalf
        case .horizontalHalves:
            y >= 0.5 ? .topHalf : .bottomHalf
        case .primaryAndStack:
            x < 0.5 ? .leftHalf : (y >= 0.5 ? .topRightQuarter : .bottomRightQuarter)
        case .quarters:
            if x < 0.5 {
                y >= 0.5 ? .topLeftQuarter : .bottomLeftQuarter
            } else {
                y >= 0.5 ? .topRightQuarter : .bottomRightQuarter
            }
        }
    }
}

@MainActor
final class WindowDragInteractionMonitor {
    private static let resizeDetectionTolerance: CGFloat = 2
    /// `windowSpacingEnabled` uses an 8pt inner split gap in the real layout
    /// geometry below. Keep the linked-resize detector on the same value so a
    /// configured tile is not rejected as "not adjacent".
    fileprivate static let configuredWindowSpacing: CGFloat = 8
    private static let sharedBoundaryGapTolerance: CGFloat = 2
    private static let displayBoundsTolerance: CGFloat = 6
    private static let geometryReadbackTolerance: CGFloat = 1.5
    private static let minimumOrthogonalOverlap: CGFloat = 0.70
    private static let minimumDisplayContainment: CGFloat = 0.80

    private weak var controller: WindowEnhancementController?
    private let preferences = WindowEnhancementPreferences.shared
    private let preview = WindowSnapPreviewController()
    private var globalMonitor: Any?
    private var dragState: DragState?
    private var monitorGeneration: UInt64 = 0
    private var dragSequenceGeneration: UInt64 = 0
    private var islandExpansionGeneration: UInt64 = 0
    private var pendingIslandExpansion: DispatchWorkItem?
    private var isApplyingLinkedResize = false
    private var isSuppressingMainIslandHover = false
    private var releaseRecoveryTimer: Timer?
    private var releaseRecovery = WindowDragReleaseRecovery()

    private enum MonitoredMouseEvent: Sendable {
        case down
        case dragged
        case up
    }

    private struct DragState {
        let generation: UInt64
        let applicationPID: pid_t
        let primaryWindow: WindowSnapshot
        let adjacentWindowSnapshots: [WindowSnapshot]
        let initialWindowFrame: CGRect
        var lastWindowFrame: CGRect
        var lastMouseLocation: CGPoint
        var candidate: WindowLayout?
        var targetDisplayID: CGDirectDisplayID?
        var islandPhase: SnapIslandPhase = .inactive
        var islandDisplayID: CGDirectDisplayID?
        var isMovingWindow = false
        var isResizingWindow = false
        var linkedResizeDetectionFinished = false
        var linkedResizeSession: LinkedResizeSession?
        var shakeDirections: [ShakeDirection] = []
        var shakeStartedAt = Date()
    }

    private struct WindowSnapshot {
        let applicationPID: pid_t
        let element: AXUIElement
        let windowID: CGWindowID?
        let frame: CGRect
        let displayID: CGDirectDisplayID?
    }

    private enum SharedBoundary {
        /// The primary window's left edge touches the neighbour's right edge.
        case primaryLeft
        /// The primary window's right edge touches the neighbour's left edge.
        case primaryRight
        /// AX window coordinates are top-down: minY is the primary top edge.
        case primaryTop
        /// AX window coordinates are top-down: maxY is the primary bottom edge.
        case primaryBottom
    }

    private struct AdjacentWindowMatch {
        let neighbour: WindowSnapshot
        let boundary: SharedBoundary
        /// Signed distance from the primary edge to the neighbour edge at
        /// mouse-down. A positive value is a gap; a negative value is overlap.
        let initialSignedGap: CGFloat
    }

    private struct LinkedResizeSession {
        let primary: WindowSnapshot
        let neighbour: WindowSnapshot
        let boundary: SharedBoundary
        let displayID: CGDirectDisplayID
        let initialNeighbourFrame: CGRect
        let initialSignedGap: CGFloat
        var lastNeighbourFrame: CGRect
    }

    private enum SnapIslandPhase: Equatable {
        case inactive
        case marker
        case expanded
    }

    private enum ShakeDirection: Equatable {
        case left
        case right
    }

    init(controller: WindowEnhancementController) {
        self.controller = controller
#if DEBUG
        _ = Self.linkedResizeGeometryChecks
#endif
    }

    func start() {
        updateEnabledState()
    }

    func stop() {
        removeMonitor()
        cancelDrag()
    }

    func updateEnabledState() {
        let needsMonitoring = preferences.isEnabled && (
            preferences.edgeSnapEnabled ||
            preferences.snapIslandEnabled ||
            preferences.aeroShakeEnabled
        )
        if needsMonitoring {
            installMonitorIfNeeded()
        } else {
            removeMonitor()
            cancelDrag()
        }
    }

    private func installMonitorIfNeeded() {
        guard globalMonitor == nil else { return }
        monitorGeneration &+= 1
        let generation = monitorGeneration
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let kind: MonitoredMouseEvent
            switch event.type {
            case .leftMouseDown: kind = .down
            case .leftMouseDragged: kind = .dragged
            case .leftMouseUp: kind = .up
            default: return
            }
            let location = NSEvent.mouseLocation
            // AppKit delivers monitor callbacks serially. Enqueuing every
            // compact event on the same main queue preserves that FIFO order;
            // unlike independent Tasks, mouseUp cannot overtake dragged.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.monitorGeneration == generation,
                      self.globalMonitor != nil else { return }
                self.handle(kind, at: location)
            }
        }
    }

    private func removeMonitor() {
        // Invalidate already-enqueued callbacks before removing the AppKit
        // monitor so stop/disable/re-enable cannot replay an old drag stream.
        monitorGeneration &+= 1
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
    }

    private func handle(_ event: MonitoredMouseEvent, at location: CGPoint) {
        switch event {
        case .down:
            beginDrag(at: location)
        case .dragged:
            continueDrag(at: location)
        case .up:
            endDrag(at: location)
        }
    }

    private func beginDrag(at mouseLocation: CGPoint) {
        cancelDrag()
        guard AXIsProcessTrusted() else {
            controller?.reportAccessibilityRequirement()
            dragState = nil
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.activationPolicy == .regular,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(application),
              let primaryWindow = focusedStandardWindowSnapshot(for: application.processIdentifier) else {
            dragState = nil
            return
        }
        let adjacentWindows = preferences.snapIslandEnabled
            ? tiledWindowSnapshots(adjacentTo: primaryWindow)
            : []
        dragState = DragState(
            generation: dragSequenceGeneration,
            applicationPID: application.processIdentifier,
            primaryWindow: primaryWindow,
            adjacentWindowSnapshots: adjacentWindows,
            initialWindowFrame: primaryWindow.frame,
            lastWindowFrame: primaryWindow.frame,
            lastMouseLocation: mouseLocation
        )
    }

    private func continueDrag(at mouseLocation: CGPoint) {
        guard var state = dragState,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == state.applicationPID,
              let focusedWindow = focusedWindowElement(for: state.applicationPID),
              CFEqual(focusedWindow, state.primaryWindow.element),
              let currentFrame = windowFrame(of: state.primaryWindow.element) else {
            cancelDrag()
            return
        }

        let sizeDelta = max(
            abs(currentFrame.width - state.initialWindowFrame.width),
            abs(currentFrame.height - state.initialWindowFrame.height)
        )
        if sizeDelta >= Self.resizeDetectionTolerance {
            state.isResizingWindow = true
            setMainIslandHoverSuppressed(false)
            cancelPendingIslandExpansion()
            state.islandPhase = .inactive
            state.islandDisplayID = nil
            state.candidate = nil
            state.targetDisplayID = nil
            preview.hide()
            updateLinkedResize(currentPrimaryFrame: currentFrame, state: &state)
            state.lastWindowFrame = currentFrame
            state.lastMouseLocation = mouseLocation
            dragState = state
            return
        }

        // Once a drag stream has been identified as a resize, never reinterpret
        // a later clamped frame as a move and accidentally trigger snap UI.
        if state.isResizingWindow {
            state.lastWindowFrame = currentFrame
            state.lastMouseLocation = mouseLocation
            dragState = state
            return
        }

        let windowDelta = hypot(
            currentFrame.minX - state.initialWindowFrame.minX,
            currentFrame.minY - state.initialWindowFrame.minY
        )
        state.isMovingWindow = state.isMovingWindow || windowDelta >= 4
        guard state.isMovingWindow else {
            state.lastWindowFrame = currentFrame
            state.lastMouseLocation = mouseLocation
            dragState = state
            return
        }

        // Mouse movement alone also includes file drags and text selection.
        // Begin only after this exact window has actually moved.
        setMainIslandHoverSuppressed(true)

        if preferences.aeroShakeEnabled {
            detectShake(mouseLocation: mouseLocation, state: &state)
            if dragState == nil { return }
        }

        let selection = snapSelection(at: mouseLocation, state: &state)
        state.candidate = selection?.layout
        state.targetDisplayID = selection?.displayID
        if let selection {
            if let preset = selection.preset {
                preview.showIslandSelection(
                    layout: selection.layout,
                    screen: selection.screen,
                    preset: preset,
                    preferences: preferences
                )
            } else {
                preview.showEdgeSelection(
                    layout: selection.layout,
                    screen: selection.screen,
                    preferences: preferences
                )
            }
        } else if state.islandPhase == .expanded {
            preview.hideTargetPreview()
        } else if state.islandPhase == .inactive {
            preview.hide()
        }

        state.lastWindowFrame = currentFrame
        state.lastMouseLocation = mouseLocation
        dragState = state
    }

    private func endDrag(at releaseLocation: CGPoint) {
        defer { setMainIslandHoverSuppressed(false) }
        guard let state = dragState else { return }
        // The island expands asynchronously and intentionally clears the old
        // candidate. A user can therefore release over a card without another
        // `leftMouseDragged` callback. Resolve the release point one final time
        // without starting/cancelling island state, and let that result replace
        // any stale candidate captured earlier in the drag.
        let finalSelection = state.isMovingWindow
            ? finalSnapSelection(at: releaseLocation, state: state)
            : nil
        cancelPendingIslandExpansion()
        dragSequenceGeneration &+= 1
        dragState = nil
        preview.hide()
        guard state.isMovingWindow,
              let finalSelection else { return }
        controller?.performDraggedLayout(
            finalSelection.layout,
            targetDisplayID: finalSelection.displayID,
            applicationPID: state.primaryWindow.applicationPID,
            windowID: state.primaryWindow.windowID,
            window: state.primaryWindow.element
        )
    }

    private func cancelDrag() {
        cancelPendingIslandExpansion()
        dragSequenceGeneration &+= 1
        dragState = nil
        preview.hide()
        setMainIslandHoverSuppressed(false)
    }

    private func setMainIslandHoverSuppressed(_ suppressed: Bool) {
        guard isSuppressingMainIslandHover != suppressed else { return }
        isSuppressingMainIslandHover = suppressed
        releaseRecoveryTimer?.invalidate()
        releaseRecoveryTimer = nil
        releaseRecovery.reset()
        AppState.shared.setWindowDragging(suppressed)
        guard suppressed else { return }

        let generation = dragSequenceGeneration
        // A global AppKit monitor can miss a release delivered to our own app.
        // Recover only after the physical button stays released; long drags
        // must never expire. The grace period lets a queued mouseUp commit first.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSuppressingMainIslandHover,
                      self.dragSequenceGeneration == generation else { return }
                if self.releaseRecovery.shouldCancel(
                    buttonIsDown: NSEvent.pressedMouseButtons & 1 != 0,
                    now: ProcessInfo.processInfo.systemUptime
                ) {
                    self.cancelDrag()
                }
            }
        }
        releaseRecoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateLinkedResize(currentPrimaryFrame: CGRect, state: inout DragState) {
        guard preferences.snapIslandEnabled else {
            state.linkedResizeSession = nil
            state.linkedResizeDetectionFinished = true
            return
        }

        if var session = state.linkedResizeSession {
            if applyLinkedResize(currentPrimaryFrame: currentPrimaryFrame, session: &session) {
                state.linkedResizeSession = session
            } else {
                // Never retry a failed AX mutation in the same mouse sequence.
                // The user's primary resize continues normally.
                state.linkedResizeSession = nil
                state.linkedResizeDetectionFinished = true
            }
            return
        }

        guard !state.linkedResizeDetectionFinished else { return }
        state.linkedResizeDetectionFinished = true
        guard isAttributeSettable(kAXPositionAttribute, of: state.primaryWindow.element),
              isAttributeSettable(kAXSizeAttribute, of: state.primaryWindow.element),
              let displayID = state.primaryWindow.displayID,
              displayIDForAXFrame(currentPrimaryFrame) == displayID else { return }

        let changedBoundaries = resizedBoundaries(
            initial: state.initialWindowFrame,
            current: currentPrimaryFrame
        )
        guard !changedBoundaries.isEmpty else { return }

        var matches: [AdjacentWindowMatch] = []
        for boundary in changedBoundaries {
            for candidate in state.adjacentWindowSnapshots {
                guard let initialSignedGap = matchingBoundaryGap(
                    boundary,
                    primaryFrame: state.initialWindowFrame,
                    neighbourFrame: candidate.frame
                ) else { continue }
                matches.append(
                    AdjacentWindowMatch(
                        neighbour: candidate,
                        boundary: boundary,
                        initialSignedGap: initialSignedGap
                    )
                )
            }
        }

        // More than one neighbouring window on a changed edge is ambiguous
        // (for example, one full-height tile beside two stacked tiles).
        guard matches.count == 1 else { return }
        let match = matches[0]
        var session = LinkedResizeSession(
            primary: state.primaryWindow,
            neighbour: match.neighbour,
            boundary: match.boundary,
            displayID: displayID,
            initialNeighbourFrame: match.neighbour.frame,
            initialSignedGap: match.initialSignedGap,
            lastNeighbourFrame: match.neighbour.frame
        )
        guard applyLinkedResize(currentPrimaryFrame: currentPrimaryFrame, session: &session) else {
            return
        }
        state.linkedResizeSession = session
    }

    private func resizedBoundaries(initial: CGRect, current: CGRect) -> [SharedBoundary] {
        let tolerance = Self.resizeDetectionTolerance
        let leftDelta = current.minX - initial.minX
        let rightDelta = current.maxX - initial.maxX
        let topDelta = current.minY - initial.minY
        let bottomDelta = current.maxY - initial.maxY
        var result: [SharedBoundary] = []

        if abs(current.width - initial.width) >= tolerance {
            if abs(leftDelta) >= tolerance, abs(rightDelta) < tolerance {
                result.append(.primaryLeft)
            } else if abs(rightDelta) >= tolerance, abs(leftDelta) < tolerance {
                result.append(.primaryRight)
            }
        }
        if abs(current.height - initial.height) >= tolerance {
            if abs(topDelta) >= tolerance, abs(bottomDelta) < tolerance {
                result.append(.primaryTop)
            } else if abs(bottomDelta) >= tolerance, abs(topDelta) < tolerance {
                result.append(.primaryBottom)
            }
        }
        return result
    }

    private func matchingBoundaryGap(
        _ boundary: SharedBoundary,
        primaryFrame: CGRect,
        neighbourFrame: CGRect
    ) -> CGFloat? {
        let signedGap = Self.signedBoundaryGap(
            boundary,
            primaryFrame: primaryFrame,
            neighbourFrame: neighbourFrame
        )
        let overlap: CGFloat
        let requiredOverlap: CGFloat
        switch boundary {
        case .primaryLeft:
            overlap = orthogonalOverlap(
                primaryFrame.minY...primaryFrame.maxY,
                neighbourFrame.minY...neighbourFrame.maxY
            )
            requiredOverlap = max(primaryFrame.height, neighbourFrame.height) * Self.minimumOrthogonalOverlap
        case .primaryRight:
            overlap = orthogonalOverlap(
                primaryFrame.minY...primaryFrame.maxY,
                neighbourFrame.minY...neighbourFrame.maxY
            )
            requiredOverlap = max(primaryFrame.height, neighbourFrame.height) * Self.minimumOrthogonalOverlap
        case .primaryTop:
            overlap = orthogonalOverlap(
                primaryFrame.minX...primaryFrame.maxX,
                neighbourFrame.minX...neighbourFrame.maxX
            )
            requiredOverlap = max(primaryFrame.width, neighbourFrame.width) * Self.minimumOrthogonalOverlap
        case .primaryBottom:
            overlap = orthogonalOverlap(
                primaryFrame.minX...primaryFrame.maxX,
                neighbourFrame.minX...neighbourFrame.maxX
            )
            requiredOverlap = max(primaryFrame.width, neighbourFrame.width) * Self.minimumOrthogonalOverlap
        }
        let configuredGap = preferences.windowSpacingEnabled
            ? Self.configuredWindowSpacing
            : 0
        guard abs(signedGap - configuredGap) <= Self.sharedBoundaryGapTolerance,
              overlap >= requiredOverlap else { return nil }
        return signedGap
    }

    /// Signed gap for all four AX-coordinate boundaries. Positive means that
    /// the two windows are separated; negative means they overlap.
    private static func signedBoundaryGap(
        _ boundary: SharedBoundary,
        primaryFrame: CGRect,
        neighbourFrame: CGRect
    ) -> CGFloat {
        switch boundary {
        case .primaryLeft:
            primaryFrame.minX - neighbourFrame.maxX
        case .primaryRight:
            neighbourFrame.minX - primaryFrame.maxX
        case .primaryTop:
            primaryFrame.minY - neighbourFrame.maxY
        case .primaryBottom:
            neighbourFrame.minY - primaryFrame.maxY
        }
    }

    private func orthogonalOverlap(
        _ first: ClosedRange<CGFloat>,
        _ second: ClosedRange<CGFloat>
    ) -> CGFloat {
        max(0, min(first.upperBound, second.upperBound) - max(first.lowerBound, second.lowerBound))
    }

    private func applyLinkedResize(
        currentPrimaryFrame: CGRect,
        session: inout LinkedResizeSession
    ) -> Bool {
        let visibleWindowIDs = onScreenWindowIDs()
        guard !isApplyingLinkedResize,
              session.primary.applicationPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primaryApplication = NSRunningApplication(processIdentifier: session.primary.applicationPID),
              !primaryApplication.isTerminated,
              !preferences.isExcluded(primaryApplication),
              let primaryWindowID = session.primary.windowID,
              visibleWindowIDs.contains(primaryWindowID),
              isStandardMutableWindow(session.primary.element),
              let neighbourApplication = NSRunningApplication(processIdentifier: session.neighbour.applicationPID),
              neighbourApplication.activationPolicy == .regular,
              !neighbourApplication.isTerminated,
              neighbourApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(neighbourApplication),
              let neighbourWindowID = session.neighbour.windowID,
              visibleWindowIDs.contains(neighbourWindowID),
              displayIDForAXFrame(currentPrimaryFrame) == session.displayID,
              let currentNeighbourFrame = windowFrame(of: session.neighbour.element),
              displayIDForAXFrame(currentNeighbourFrame) == session.displayID,
              framesMatch(currentNeighbourFrame, session.lastNeighbourFrame),
              isStandardMutableWindow(session.neighbour.element) else { return false }

        let target = Self.linkedNeighbourTarget(
            currentPrimaryFrame: currentPrimaryFrame,
            initialNeighbourFrame: session.initialNeighbourFrame,
            boundary: session.boundary,
            signedGap: session.initialSignedGap
        )

        let minimumSize = minimumSafeSize(
            for: session.neighbour.element,
            initialSize: session.initialNeighbourFrame.size
        )
        guard target.width >= minimumSize.width,
              target.height >= minimumSize.height,
              let displayBounds = displayBounds(for: session.displayID),
              displayBounds.insetBy(dx: -Self.displayBoundsTolerance, dy: -Self.displayBoundsTolerance)
                .contains(target) else { return false }

        isApplyingLinkedResize = true
        defer { isApplyingLinkedResize = false }
        guard writeFrameExactly(
            target,
            rollbackFrame: currentNeighbourFrame,
            to: session.neighbour.element
        ), let readback = windowFrame(of: session.neighbour.element),
           framesMatch(readback, target) else { return false }
        session.lastNeighbourFrame = readback
        return true
    }

    private static func linkedNeighbourTarget(
        currentPrimaryFrame: CGRect,
        initialNeighbourFrame: CGRect,
        boundary: SharedBoundary,
        signedGap: CGFloat
    ) -> CGRect {
        switch boundary {
        case .primaryLeft:
            CGRect(
                x: initialNeighbourFrame.minX,
                y: initialNeighbourFrame.minY,
                width: currentPrimaryFrame.minX - signedGap - initialNeighbourFrame.minX,
                height: initialNeighbourFrame.height
            )
        case .primaryRight:
            CGRect(
                x: currentPrimaryFrame.maxX + signedGap,
                y: initialNeighbourFrame.minY,
                width: initialNeighbourFrame.maxX - currentPrimaryFrame.maxX - signedGap,
                height: initialNeighbourFrame.height
            )
        case .primaryTop:
            CGRect(
                x: initialNeighbourFrame.minX,
                y: initialNeighbourFrame.minY,
                width: initialNeighbourFrame.width,
                height: currentPrimaryFrame.minY - signedGap - initialNeighbourFrame.minY
            )
        case .primaryBottom:
            CGRect(
                x: initialNeighbourFrame.minX,
                y: currentPrimaryFrame.maxY + signedGap,
                width: initialNeighbourFrame.width,
                height: initialNeighbourFrame.maxY - currentPrimaryFrame.maxY - signedGap
            )
        }
    }

#if DEBUG
    /// Pure geometry checks cover every boundary with both supported layout
    /// gaps. They run once in Debug builds and catch a future formula change
    /// that collapses the configured gap or reverses its sign.
    private static let linkedResizeGeometryChecks: Void = {
        let primary = CGRect(x: 300, y: 300, width: 400, height: 300)
        for gap: CGFloat in [0, configuredWindowSpacing] {
            let cases: [(SharedBoundary, CGRect, CGRect)] = [
                (
                    .primaryLeft,
                    CGRect(x: 100, y: 300, width: 200 - gap, height: 300),
                    CGRect(x: 340, y: 300, width: 360, height: 300)
                ),
                (
                    .primaryRight,
                    CGRect(x: 700 + gap, y: 300, width: 300 - gap, height: 300),
                    CGRect(x: 300, y: 300, width: 440, height: 300)
                ),
                (
                    .primaryTop,
                    CGRect(x: 300, y: 100, width: 400, height: 200 - gap),
                    CGRect(x: 300, y: 340, width: 400, height: 260)
                ),
                (
                    .primaryBottom,
                    CGRect(x: 300, y: 600 + gap, width: 400, height: 300 - gap),
                    CGRect(x: 300, y: 300, width: 400, height: 340)
                )
            ]

            for (boundary, neighbour, movedPrimary) in cases {
                let initialGap = signedBoundaryGap(
                    boundary,
                    primaryFrame: primary,
                    neighbourFrame: neighbour
                )
                assert(abs(initialGap - gap) < 0.001)
                let target = linkedNeighbourTarget(
                    currentPrimaryFrame: movedPrimary,
                    initialNeighbourFrame: neighbour,
                    boundary: boundary,
                    signedGap: initialGap
                )
                let preservedGap = signedBoundaryGap(
                    boundary,
                    primaryFrame: movedPrimary,
                    neighbourFrame: target
                )
                assert(abs(preservedGap - initialGap) < 0.001)
            }
        }
    }()
#endif

    private func detectShake(mouseLocation: CGPoint, state: inout DragState) {
        let deltaX = mouseLocation.x - state.lastMouseLocation.x
        guard abs(deltaX) >= 16 else { return }
        let direction: ShakeDirection = deltaX < 0 ? .left : .right
        let now = Date()
        if now.timeIntervalSince(state.shakeStartedAt) > 0.9 {
            state.shakeStartedAt = now
            state.shakeDirections.removeAll()
        }
        if state.shakeDirections.last != direction {
            state.shakeDirections.append(direction)
        }
        guard state.shakeDirections.count >= 5 else { return }
        cancelDrag()
        controller?.performAeroShake()
    }

    private struct SnapSelection {
        let layout: WindowLayout
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let preset: WindowSnapPreset?
    }

    private func snapSelection(at location: CGPoint, state: inout DragState) -> SnapSelection? {
        guard let pointerScreen = screen(at: location),
              let pointerDisplayID = displayID(for: pointerScreen) else {
            cancelSnapIsland(in: &state)
            return nil
        }

        if state.islandPhase != .inactive {
            guard preferences.snapIslandEnabled,
                  state.islandDisplayID == pointerDisplayID,
                  let islandScreen = screen(for: pointerDisplayID) else {
                cancelSnapIsland(in: &state)
                return edgeSnapSelection(at: location, screen: pointerScreen, displayID: pointerDisplayID)
            }

            switch state.islandPhase {
            case .marker:
                if markerRetentionFrame(for: islandScreen).contains(location) {
                    return nil
                }
                cancelSnapIsland(in: &state)
            case .expanded:
                if expandedRetentionFrame(for: islandScreen).contains(location) {
                    return islandSelection(at: location, screen: islandScreen, displayID: pointerDisplayID)
                }
                cancelSnapIsland(in: &state)
            case .inactive:
                break
            }
        }

        if preferences.snapIslandEnabled,
           activationFrame(for: pointerScreen).contains(location) {
            beginSnapIsland(on: pointerScreen, displayID: pointerDisplayID, state: &state)
            return nil
        }

        return edgeSnapSelection(at: location, screen: pointerScreen, displayID: pointerDisplayID)
    }

    private func beginSnapIsland(
        on screen: NSScreen,
        displayID: CGDirectDisplayID,
        state: inout DragState
    ) {
        guard state.islandPhase == .inactive else { return }
        state.islandPhase = .marker
        state.islandDisplayID = displayID
        state.candidate = nil
        state.targetDisplayID = nil
        preview.showIslandMarker(
            screen: screen,
            preferences: preferences,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        scheduleIslandExpansion(
            dragGeneration: state.generation,
            applicationPID: state.applicationPID,
            displayID: displayID
        )
    }

    private func scheduleIslandExpansion(
        dragGeneration: UInt64,
        applicationPID: pid_t,
        displayID: CGDirectDisplayID
    ) {
        cancelPendingIslandExpansion()
        islandExpansionGeneration &+= 1
        let expansionGeneration = islandExpansionGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expandSnapIslandIfCurrent(
                expansionGeneration: expansionGeneration,
                dragGeneration: dragGeneration,
                applicationPID: applicationPID,
                displayID: displayID
            )
        }
        pendingIslandExpansion = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WindowSnapIslandMetrics.expansionDelay,
            execute: item
        )
    }

    private func expandSnapIslandIfCurrent(
        expansionGeneration: UInt64,
        dragGeneration: UInt64,
        applicationPID: pid_t,
        displayID: CGDirectDisplayID
    ) {
        guard islandExpansionGeneration == expansionGeneration,
              dragSequenceGeneration == dragGeneration,
              var state = dragState,
              state.generation == dragGeneration,
              state.applicationPID == applicationPID,
              state.isMovingWindow,
              state.islandPhase == .marker,
              state.islandDisplayID == displayID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID,
              let focusedWindow = focusedWindowElement(for: applicationPID),
              CFEqual(focusedWindow, state.primaryWindow.element),
              windowFrame(of: state.primaryWindow.element) != nil,
              let screen = screen(for: displayID),
              markerRetentionFrame(for: screen).contains(state.lastMouseLocation) else { return }

        pendingIslandExpansion = nil
        state.islandPhase = .expanded
        state.candidate = nil
        state.targetDisplayID = nil
        dragState = state
        preview.showExpandedIsland(
            screen: screen,
            preferences: preferences,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func cancelSnapIsland(in state: inout DragState) {
        guard state.islandPhase != .inactive else { return }
        cancelPendingIslandExpansion()
        state.islandPhase = .inactive
        state.islandDisplayID = nil
        state.candidate = nil
        state.targetDisplayID = nil
        preview.hide()
    }

    private func cancelPendingIslandExpansion() {
        islandExpansionGeneration &+= 1
        pendingIslandExpansion?.cancel()
        pendingIslandExpansion = nil
    }

    private func islandSelection(
        at location: CGPoint,
        screen: NSScreen,
        displayID: CGDirectDisplayID
    ) -> SnapSelection? {
        let frame = islandFrame(for: screen)
        let itemHeight = frame.height - WindowSnapIslandMetrics.padding * 2
        for (index, preset) in WindowSnapPreset.allCases.enumerated() {
            let itemFrame = CGRect(
                x: frame.minX + WindowSnapIslandMetrics.padding + CGFloat(index) * (
                    WindowSnapIslandMetrics.itemWidth + WindowSnapIslandMetrics.itemSpacing
                ),
                y: frame.minY + WindowSnapIslandMetrics.padding,
                width: WindowSnapIslandMetrics.itemWidth,
                height: itemHeight
            )
            guard itemFrame.contains(location) else { continue }
            let x = min(1, max(0, (location.x - itemFrame.minX) / itemFrame.width))
            let y = min(1, max(0, (location.y - itemFrame.minY) / itemFrame.height))
            return SnapSelection(
                layout: preset.layout(normalizedX: x, normalizedY: y),
                screen: screen,
                displayID: displayID,
                preset: preset
            )
        }
        return nil
    }

    /// Resolve only the current release point. Unlike `snapSelection`, this
    /// helper must never create a marker, schedule expansion, or mutate the
    /// drag state after the button has already been released.
    private func finalSnapSelection(
        at location: CGPoint,
        state: DragState
    ) -> SnapSelection? {
        guard let pointerScreen = screen(at: location),
              let pointerDisplayID = displayID(for: pointerScreen) else { return nil }

        switch state.islandPhase {
        case .expanded:
            guard preferences.snapIslandEnabled,
                  state.islandDisplayID == pointerDisplayID,
                  let islandScreen = screen(for: pointerDisplayID),
                  expandedRetentionFrame(for: islandScreen).contains(location) else { return nil }
            return islandSelection(
                at: location,
                screen: islandScreen,
                displayID: pointerDisplayID
            )
        case .marker:
            // Releasing before the island has actually expanded is a cancel,
            // not permission to guess a hidden card from its future position.
            return nil
        case .inactive:
            return edgeSnapSelection(
                at: location,
                screen: pointerScreen,
                displayID: pointerDisplayID
            )
        }
    }

    private func edgeSnapSelection(
        at location: CGPoint,
        screen: NSScreen,
        displayID: CGDirectDisplayID
    ) -> SnapSelection? {
        guard preferences.edgeSnapEnabled else { return nil }
        let frame = screen.frame
        let distanceFromTop = frame.maxY - location.y
        let threshold: CGFloat = 18
        if location.x - frame.minX <= threshold {
            return SnapSelection(layout: .leftHalf, screen: screen, displayID: displayID, preset: nil)
        }
        if frame.maxX - location.x <= threshold {
            return SnapSelection(layout: .rightHalf, screen: screen, displayID: displayID, preset: nil)
        }
        if distanceFromTop <= threshold {
            return SnapSelection(layout: .maximize, screen: screen, displayID: displayID, preset: nil)
        }
        if location.y - frame.minY <= threshold {
            return SnapSelection(layout: .bottomHalf, screen: screen, displayID: displayID, preset: nil)
        }
        return nil
    }

    private func activationFrame(for screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.midX - WindowSnapIslandMetrics.activationWidth / 2,
            y: screen.frame.maxY - WindowSnapIslandMetrics.activationHeight,
            width: WindowSnapIslandMetrics.activationWidth,
            height: WindowSnapIslandMetrics.activationHeight
        )
    }

    private func markerRetentionFrame(for screen: NSScreen) -> CGRect {
        // During the short marker -> expanded transition, allow the pointer to
        // travel toward any of the four future cards. Restricting retention to
        // the tiny center marker made the first/last card unreachable before
        // the 140ms expansion completed.
        expandedRetentionFrame(for: screen)
    }

    private func expandedRetentionFrame(for screen: NSScreen) -> CGRect {
        let island = islandFrame(for: screen)
        let minY = island.minY - WindowSnapIslandMetrics.retentionPadding
        return CGRect(
            x: island.minX - WindowSnapIslandMetrics.retentionPadding,
            y: minY,
            width: island.width + WindowSnapIslandMetrics.retentionPadding * 2,
            height: screen.frame.maxY - minY
        )
    }

    private func islandFrame(for screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.midX - WindowSnapIslandMetrics.width / 2,
            y: screen.frame.maxY - WindowSnapIslandMetrics.height - WindowSnapIslandMetrics.topInset,
            width: WindowSnapIslandMetrics.width,
            height: WindowSnapIslandMetrics.height
        )
    }

    private func screen(at location: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(location) })
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { self.displayID(for: $0) == displayID })
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func focusedStandardWindowSnapshot(for pid: pid_t) -> WindowSnapshot? {
        guard let window = focusedWindowElement(for: pid),
              isStandardWindow(window),
              isAttributeSettable(kAXPositionAttribute, of: window),
              let frame = windowFrame(of: window) else { return nil }
        return WindowSnapshot(
            applicationPID: pid,
            element: window,
            windowID: windowIDAttribute(window),
            frame: frame,
            displayID: displayIDForAXFrame(frame)
        )
    }

    private func focusedWindowElement(for pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(windowValue, to: AXUIElement.self)
    }

    private func tiledWindowSnapshots(adjacentTo primary: WindowSnapshot) -> [WindowSnapshot] {
        guard let primaryWindowID = primary.windowID,
              let displayID = primary.displayID,
              isAttributeSettable(kAXPositionAttribute, of: primary.element),
              isAttributeSettable(kAXSizeAttribute, of: primary.element) else { return [] }
        let onScreenIDs = onScreenWindowIDs()
        guard onScreenIDs.contains(primaryWindowID) else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seenWindowIDs = Set<CGWindowID>()
        var snapshots: [WindowSnapshot] = []
        for application in NSWorkspace.shared.runningApplications where
            application.activationPolicy == .regular &&
            !application.isTerminated &&
            application.processIdentifier != ownPID &&
            !preferences.isExcluded(application) {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success, let windows = windowsValue as? [AXUIElement] else { continue }

            for window in windows {
                guard !CFEqual(window, primary.element),
                      isStandardMutableWindow(window),
                      let windowID = windowIDAttribute(window),
                      windowID != primaryWindowID,
                      onScreenIDs.contains(windowID),
                      seenWindowIDs.insert(windowID).inserted,
                      let frame = windowFrame(of: window),
                      displayIDForAXFrame(frame) == displayID else { continue }
                snapshots.append(
                    WindowSnapshot(
                        applicationPID: application.processIdentifier,
                        element: window,
                        windowID: windowID,
                        frame: frame,
                        displayID: displayID
                    )
                )
            }
        }
        return snapshots
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole as String &&
            stringAttribute(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole as String &&
            boolAttribute("AXModal", of: window) != true &&
            boolAttribute("AXFullScreen", of: window) != true &&
            boolAttribute(kAXMinimizedAttribute, of: window) != true
    }

    private func isStandardMutableWindow(_ window: AXUIElement) -> Bool {
        isStandardWindow(window) &&
            isAttributeSettable(kAXPositionAttribute, of: window) &&
            isAttributeSettable(kAXSizeAttribute, of: window)
    }

    private func windowFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func windowIDAttribute(_ window: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            "AXWindowNumber" as CFString,
            &value
        ) == .success, let number = value as? NSNumber else { return nil }
        return CGWindowID(number.uint32Value)
    }

    /// WindowServer's on-screen flag is the Space boundary. Requiring both the
    /// primary and neighbour IDs to appear here prevents mutating an AX window
    /// that belongs to another Space even when AX still enumerates it.
    private func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return Set(windowInfo.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return CGWindowID(number.uint32Value)
        })
    }

    private func displayIDForAXFrame(_ frame: CGRect) -> CGDirectDisplayID? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let frameArea = frame.width * frame.height
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for screen in NSScreen.screens {
            guard let id = displayID(for: screen) else { continue }
            let intersection = frame.intersection(CGDisplayBounds(id))
            let area = intersection.isNull || intersection.isEmpty
                ? 0
                : intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (id, area)
            }
        }
        guard let best,
              best.area / frameArea >= Self.minimumDisplayContainment else { return nil }
        return best.id
    }

    private func displayBounds(for displayID: CGDirectDisplayID) -> CGRect? {
        guard NSScreen.screens.contains(where: { self.displayID(for: $0) == displayID }) else {
            return nil
        }
        return CGDisplayBounds(displayID)
    }

    private func minimumSafeSize(for window: AXUIElement, initialSize: CGSize) -> CGSize {
        // AX does not guarantee a minimum-size attribute for windows. Use it
        // when exposed, otherwise a conservative floor no larger than the
        // already-valid initial frame; exact readback still detects a larger
        // app-specific clamp.
        let fallback = CGSize(
            width: min(120, initialSize.width),
            height: min(96, initialSize.height)
        )
        for attribute in ["AXMinimumSize", "AXMinSize"] {
            if let reported = sizeAttribute(attribute, of: window),
               reported.width > 0,
               reported.height > 0,
               reported.width <= initialSize.width + Self.geometryReadbackTolerance,
               reported.height <= initialSize.height + Self.geometryReadbackTolerance {
                return CGSize(
                    width: max(fallback.width, reported.width),
                    height: max(fallback.height, reported.height)
                )
            }
        }
        return fallback
    }

    private func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func writeFrameExactly(
        _ target: CGRect,
        rollbackFrame: CGRect,
        to window: AXUIElement
    ) -> Bool {
        guard target.width > 0,
              target.height > 0,
              isAttributeSettable(kAXPositionAttribute, of: window),
              isAttributeSettable(kAXSizeAttribute, of: window) else { return false }

        let sizeWritten = sizesMatch(rollbackFrame.size, target.size) || writeSize(target.size, to: window)
        let positionWritten = originsMatch(rollbackFrame.origin, target.origin) ||
            writePosition(target.origin, to: window)
        if sizeWritten, positionWritten,
           let readback = windowFrame(of: window),
           framesMatch(readback, target) {
            return true
        }

        // Best-effort rollback prevents a constrained half-write from leaving
        // the neighbour detached. A failed rollback still ends the session and
        // never touches the primary window.
        _ = writeSize(rollbackFrame.size, to: window)
        _ = writePosition(rollbackFrame.origin, to: window)
        return false
    }

    private func writePosition(_ target: CGPoint, to window: AXUIElement) -> Bool {
        var target = target
        guard let value = AXValueCreate(.cgPoint, &target) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    private func writeSize(_ target: CGSize, to window: AXUIElement) -> Bool {
        var target = target
        guard let value = AXValueCreate(.cgSize, &target) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            value
        ) == .success
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        originsMatch(lhs.origin, rhs.origin) && sizesMatch(lhs.size, rhs.size)
    }

    private func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= Self.geometryReadbackTolerance &&
            abs(lhs.y - rhs.y) <= Self.geometryReadbackTolerance
    }

    private func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= Self.geometryReadbackTolerance &&
            abs(lhs.height - rhs.height) <= Self.geometryReadbackTolerance
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func isAttributeSettable(_ name: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            name as CFString,
            &settable
        ) == .success && settable.boolValue
    }
}

@MainActor
private final class WindowSnapPreviewController {
    private let previewPanel: NSPanel
    private let islandPanel: NSPanel
    private var islandTransitionGeneration: UInt64 = 0
    private var pendingIslandHide: DispatchWorkItem?

    init() {
        previewPanel = Self.makePanel(level: .floating)
        previewPanel.contentView = Self.fixedFrameHostingView(
            rootView: WindowLayoutPreviewShape()
        )

        islandPanel = Self.makePanel(level: .popUpMenu)
        islandPanel.hasShadow = true
        islandPanel.contentView = Self.fixedFrameHostingView(
            rootView: WindowSnapIslandView(selectedLayout: nil, selectedPreset: nil, accent: .blue)
        )
    }

    func showEdgeSelection(
        layout: WindowLayout,
        screen: NSScreen,
        preferences: WindowEnhancementPreferences
    ) {
        showTargetPreview(layout: layout, screen: screen, preferences: preferences)
        hideIsland()
    }

    func showIslandSelection(
        layout: WindowLayout,
        screen: NSScreen,
        preset: WindowSnapPreset,
        preferences: WindowEnhancementPreferences
    ) {
        showTargetPreview(layout: layout, screen: screen, preferences: preferences)
        showIsland(
            screen: screen,
            selectedLayout: layout,
            selectedPreset: preset,
            preferences: preferences,
            animateExpansion: false,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    func showIslandMarker(
        screen: NSScreen,
        preferences: WindowEnhancementPreferences,
        reduceMotion: Bool
    ) {
        hideTargetPreview()
        prepareIslandForPresentation()
        let accent = accentColor(preferences.accentName)
        islandPanel.contentView = Self.fixedFrameHostingView(
            rootView: WindowSnapIslandMarkerView(accent: accent)
        )
        islandPanel.setFrame(markerFrame(for: screen), display: true)
        islandPanel.alphaValue = reduceMotion ? 1 : 0
        islandPanel.orderFrontRegardless()
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            islandPanel.animator().alphaValue = 1
        }
    }

    func showExpandedIsland(
        screen: NSScreen,
        preferences: WindowEnhancementPreferences,
        reduceMotion: Bool
    ) {
        hideTargetPreview()
        showIsland(
            screen: screen,
            selectedLayout: nil,
            selectedPreset: nil,
            preferences: preferences,
            animateExpansion: true,
            reduceMotion: reduceMotion
        )
    }

    func hideTargetPreview() {
        previewPanel.orderOut(nil)
    }

    func hide() {
        hideTargetPreview()
        hideIsland()
    }

    private func showTargetPreview(
        layout: WindowLayout,
        screen: NSScreen,
        preferences: WindowEnhancementPreferences
    ) {
        let accent = accentColor(preferences.accentName)
        previewPanel.contentView = Self.fixedFrameHostingView(
            rootView: WindowLayoutPreviewShape(accent: accent)
        )
        previewPanel.setFrame(previewFrame(for: layout, screen: screen, preferences: preferences), display: true)
        previewPanel.orderFrontRegardless()
    }

    private func showIsland(
        screen: NSScreen,
        selectedLayout: WindowLayout?,
        selectedPreset: WindowSnapPreset?,
        preferences: WindowEnhancementPreferences,
        animateExpansion: Bool,
        reduceMotion: Bool
    ) {
        prepareIslandForPresentation()
        let accent = accentColor(preferences.accentName)
        islandPanel.contentView = Self.fixedFrameHostingView(
            rootView: WindowSnapIslandView(
                selectedLayout: selectedLayout,
                selectedPreset: selectedPreset,
                accent: accent
            )
        )
        let targetFrame = islandFrame(for: screen)
        let shouldAnimateFrame = animateExpansion && islandPanel.isVisible && !reduceMotion
        islandPanel.alphaValue = 1
        islandPanel.orderFrontRegardless()
        islandPanel.setFrame(targetFrame, display: true, animate: shouldAnimateFrame)
    }

    private func hideIsland() {
        islandTransitionGeneration &+= 1
        let generation = islandTransitionGeneration
        pendingIslandHide?.cancel()
        pendingIslandHide = nil
        guard islandPanel.isVisible else {
            islandPanel.alphaValue = 1
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            islandPanel.orderOut(nil)
            islandPanel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            islandPanel.animator().alphaValue = 0
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.islandTransitionGeneration == generation else { return }
            self.islandPanel.orderOut(nil)
            self.islandPanel.alphaValue = 1
            self.pendingIslandHide = nil
        }
        pendingIslandHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: item)
    }

    private func prepareIslandForPresentation() {
        islandTransitionGeneration &+= 1
        pendingIslandHide?.cancel()
        pendingIslandHide = nil
        islandPanel.alphaValue = 1
    }

    private func markerFrame(for screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.midX - WindowSnapIslandMetrics.markerWidth / 2,
            y: screen.frame.maxY - WindowSnapIslandMetrics.markerHeight - WindowSnapIslandMetrics.markerTopInset,
            width: WindowSnapIslandMetrics.markerWidth,
            height: WindowSnapIslandMetrics.markerHeight
        )
    }

    private func islandFrame(for screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.midX - WindowSnapIslandMetrics.width / 2,
            y: screen.frame.maxY - WindowSnapIslandMetrics.height - WindowSnapIslandMetrics.topInset,
            width: WindowSnapIslandMetrics.width,
            height: WindowSnapIslandMetrics.height
        )
    }

    private static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private static func fixedFrameHostingView<Content: View>(
        rootView: Content
    ) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        // These transient panels are always framed by the controller. Keeping
        // SwiftUI out of window min/max sizing prevents AppKit constraint
        // feedback loops while a panel changes Space or screen.
        hostingView.sizingOptions = []
        return hostingView
    }

    private func previewFrame(
        for layout: WindowLayout,
        screen: NSScreen,
        preferences: WindowEnhancementPreferences
    ) -> CGRect {
        var available = screen.visibleFrame
        if preferences.reserveStageManagerSpace {
            available.origin.x += 72
            available.size.width = max(200, available.width - 72)
        }
        let gap: CGFloat = preferences.windowSpacingEnabled
            ? WindowDragInteractionMonitor.configuredWindowSpacing
            : 0
        let inset = available.insetBy(dx: gap, dy: gap)
        let halfWidth = (inset.width - gap) / 2
        let halfHeight = (inset.height - gap) / 2
        let thirdWidth = (inset.width - gap * 2) / 3
        switch layout {
        case .leftHalf:
            return CGRect(x: inset.minX, y: inset.minY, width: halfWidth, height: inset.height)
        case .rightHalf:
            return CGRect(x: inset.maxX - halfWidth, y: inset.minY, width: halfWidth, height: inset.height)
        case .maximize:
            return inset
        case .leftThird:
            return CGRect(x: inset.minX, y: inset.minY, width: thirdWidth, height: inset.height)
        case .centerThird:
            return CGRect(x: inset.minX + thirdWidth + gap, y: inset.minY, width: thirdWidth, height: inset.height)
        case .rightThird:
            return CGRect(x: inset.maxX - thirdWidth, y: inset.minY, width: thirdWidth, height: inset.height)
        case .topHalf:
            return CGRect(x: inset.minX, y: inset.midY + gap / 2, width: inset.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: halfHeight)
        case .leftTwoThirds:
            return CGRect(x: inset.minX, y: inset.minY, width: thirdWidth * 2 + gap, height: inset.height)
        case .rightTwoThirds:
            return CGRect(x: inset.maxX - thirdWidth * 2 - gap, y: inset.minY, width: thirdWidth * 2 + gap, height: inset.height)
        case .topLeftQuarter:
            return CGRect(x: inset.minX, y: inset.midY + gap / 2, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: inset.maxX - halfWidth, y: inset.midY + gap / 2, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: inset.minX, y: inset.minY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: inset.maxX - halfWidth, y: inset.minY, width: halfWidth, height: halfHeight)
        }
    }

    private func accentColor(_ name: String) -> Color {
        switch name {
        case "purple": .purple
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "gray": .gray
        default: .blue
        }
    }
}

private struct WindowLayoutPreviewShape: View {
    var accent: Color = .blue

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(accent.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(0.9), lineWidth: 3)
            )
            .padding(5)
    }
}

private struct WindowSnapIslandMarkerView: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .shadow(color: accent.opacity(0.75), radius: 5)
            Image(systemName: "rectangle.split.2x2.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 8, y: 4)
    }
}

private struct WindowSnapIslandView: View {
    let selectedLayout: WindowLayout?
    let selectedPreset: WindowSnapPreset?
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WindowSnapPreset.allCases) { preset in
                WindowSnapPresetGlyph(
                    preset: preset,
                    selectedLayout: selectedPreset == preset ? selectedLayout : nil,
                    accent: accent
                )
                .padding(7)
                .frame(width: WindowSnapIslandMetrics.itemWidth, height: 92)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(selectedPreset == preset ? 0.20 : 0.10), lineWidth: 1)
                )
            }
        }
        .padding(WindowSnapIslandMetrics.padding)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.52), radius: 18, y: 9)
    }
}

private struct WindowSnapPresetGlyph: View {
    let preset: WindowSnapPreset
    let selectedLayout: WindowLayout?
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                ForEach(preset.slots, id: \.self) { layout in
                    let frame = slotFrame(layout, in: bounds)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(layout == selectedLayout ? Color.white.opacity(0.22) : Color.white.opacity(0.075))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white.opacity(layout == selectedLayout ? 0.34 : 0.13), lineWidth: 1)
                        )
                        .frame(width: max(0, frame.width - 2), height: max(0, frame.height - 2))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    private func slotFrame(_ layout: WindowLayout, in bounds: CGRect) -> CGRect {
        let gap: CGFloat = 4
        let halfWidth = (bounds.width - gap) / 2
        let halfHeight = (bounds.height - gap) / 2
        switch layout {
        case .leftHalf:
            return CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        case .rightHalf:
            return CGRect(x: halfWidth + gap, y: 0, width: halfWidth, height: bounds.height)
        case .topHalf:
            return CGRect(x: 0, y: 0, width: bounds.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: 0, y: halfHeight + gap, width: bounds.width, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: halfWidth + gap, y: 0, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: halfWidth + gap, y: halfHeight + gap, width: halfWidth, height: halfHeight)
        case .topLeftQuarter:
            return CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: 0, y: halfHeight + gap, width: halfWidth, height: halfHeight)
        default:
            return bounds
        }
    }
}

struct WindowLayoutGlyph: View {
    let layout: WindowLayout
    var accent: Color = .blue

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent.opacity(0.92))
                    .frame(width: highlightedFrame(in: bounds).width, height: highlightedFrame(in: bounds).height)
                    .offset(x: highlightedFrame(in: bounds).minX, y: highlightedFrame(in: bounds).minY)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func highlightedFrame(in bounds: CGRect) -> CGRect {
        switch layout {
        case .leftHalf:
            return CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        case .rightHalf:
            return CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
        case .maximize:
            return bounds
        case .leftThird:
            return CGRect(x: 0, y: 0, width: bounds.width / 3, height: bounds.height)
        case .centerThird:
            return CGRect(x: bounds.width / 3, y: 0, width: bounds.width / 3, height: bounds.height)
        case .rightThird:
            return CGRect(x: bounds.width * 2 / 3, y: 0, width: bounds.width / 3, height: bounds.height)
        case .topHalf:
            return CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
        case .bottomHalf:
            return CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2)
        case .leftTwoThirds:
            return CGRect(x: 0, y: 0, width: bounds.width * 2 / 3, height: bounds.height)
        case .rightTwoThirds:
            return CGRect(x: bounds.width / 3, y: 0, width: bounds.width * 2 / 3, height: bounds.height)
        case .topLeftQuarter:
            return CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height / 2)
        case .topRightQuarter:
            return CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height / 2)
        case .bottomLeftQuarter:
            return CGRect(x: 0, y: bounds.height / 2, width: bounds.width / 2, height: bounds.height / 2)
        case .bottomRightQuarter:
            return CGRect(x: bounds.width / 2, y: bounds.height / 2, width: bounds.width / 2, height: bounds.height / 2)
        }
    }
}
