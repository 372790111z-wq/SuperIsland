import AppKit
import SwiftUI

enum IslandSurfaceSwipeSuppression {
    private static var suppressedUntil: TimeInterval = 0

    static func suppress(for duration: TimeInterval = 0.6, eventTimestamp: TimeInterval? = nil) {
        let baseline = max(eventTimestamp ?? 0, ProcessInfo.processInfo.systemUptime)
        suppressedUntil = max(suppressedUntil, baseline + duration)
    }

    static func isActive(at eventTimestamp: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return eventTimestamp <= suppressedUntil || now <= suppressedUntil
    }
}

struct SwipeDetector: ViewModifier {
    let onSwipe: (SwipeDirection) -> Void
    var minimumDistance: CGFloat = 20
    var velocityThreshold: CGFloat = 100

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: minimumDistance)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    let velocity = sqrt(
                        pow(value.velocity.width, 2) + pow(value.velocity.height, 2)
                    )

                    guard velocity > velocityThreshold else { return }

                    if abs(horizontal) > abs(vertical) {
                        onSwipe(horizontal > 0 ? .right : .left)
                    } else {
                        onSwipe(vertical > 0 ? .down : .up)
                    }
                }
        )
    }
}

extension View {
    func onSwipe(
        minimumDistance: CGFloat = 20,
        velocityThreshold: CGFloat = 100,
        perform action: @escaping (SwipeDirection) -> Void
    ) -> some View {
        modifier(SwipeDetector(
            onSwipe: action,
            minimumDistance: minimumDistance,
            velocityThreshold: velocityThreshold
        ))
    }

    func onTrackpadSwipe(
        givesNestedScrollViewsPriority: Bool = false,
        perform action: @escaping (SwipeDirection) -> Void
    ) -> some View {
        overlay {
            TrackpadSwipeOverlay(
                onSwipe: action, givesNestedScrollViewsPriority: givesNestedScrollViewsPriority
            )
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Trackpad Two-Finger Swipe

/// The view where a gesture begins owns its entire sequence, including at a
/// scroll view's boundary. A child must not hand a partly consumed swipe to
/// the island just because the pointer moves out or its content cannot scroll.
struct IslandSurfaceScrollOwnership {
    enum Owner: Equatable { case surface, nestedScrollView }
    static let gestureTimeout: TimeInterval = 0.35
    private(set) var owner: Owner?
    private var lastEventTime: TimeInterval?

    mutating func allowsSurfaceSwipe(
        phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, timestamp: TimeInterval,
        givesNestedScrollViewsPriority: Bool, isOverNestedScrollView: Bool
    ) -> Bool {
        if let lastEventTime, timestamp - lastEventTime > Self.gestureTimeout {
            reset()
        }
        lastEventTime = timestamp
        if phase.contains(.began) { owner = nil }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            reset()
            return false
        }
        guard momentumPhase.isEmpty else { return false }
        if owner == nil {
            owner = givesNestedScrollViewsPriority && isOverNestedScrollView
                ? .nestedScrollView : .surface
        }
        return owner == .surface
    }

    mutating func reset() {
        owner = nil
        lastEventTime = nil
    }
}

enum IslandSurfaceScrollHitTest {
    /// `point` is in the root's coordinates. NSView.hitTest takes coordinates
    /// in its superview, which also matters for windows with inset content.
    @MainActor
    static func isOverNestedScrollView(at point: NSPoint, in root: NSView) -> Bool {
        var candidate = root.hitTest(root.convert(point, to: root.superview))
        while let view = candidate {
            if view is NSScrollView { return true }
            if view === root { break }
            candidate = view.superview
        }
        return false
    }
}

/// Transparent overlay that uses a local event monitor to capture two-finger
/// horizontal trackpad scroll gestures without blocking clicks or taps.
struct TrackpadSwipeOverlay: NSViewRepresentable {
    let onSwipe: (SwipeDirection) -> Void
    let givesNestedScrollViewsPriority: Bool

    func makeNSView(context: Context) -> TrackpadSwipeView {
        let view = TrackpadSwipeView()
        view.onSwipe = onSwipe
        view.givesNestedScrollViewsPriority = givesNestedScrollViewsPriority
        return view
    }

    func updateNSView(_ nsView: TrackpadSwipeView, context: Context) {
        nsView.onSwipe = onSwipe
        nsView.givesNestedScrollViewsPriority = givesNestedScrollViewsPriority
    }
}

final class TrackpadSwipeView: NSView {
    var onSwipe: ((SwipeDirection) -> Void)?
    var givesNestedScrollViewsPriority = false
    private var scrollOwnership = IslandSurfaceScrollOwnership()

    private enum ScrollAxis {
        case undecided
        case horizontal
        case vertical
    }

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var totalAbsDeltaX: CGFloat = 0
    private var totalAbsDeltaY: CGFloat = 0
    private var lockedAxis: ScrollAxis = .undecided
    private var hasFired = false
    private let horizontalLockThreshold: CGFloat = 12
    private let horizontalTriggerThreshold: CGFloat = 22
    private let verticalLockThreshold: CGFloat = 16
    private let horizontalDominanceRatio: CGFloat = 1.25
    private let verticalDominanceRatio: CGFloat = 1.35
    private let gestureTimeout = IslandSurfaceScrollOwnership.gestureTimeout
    private var lastScrollEventTime: TimeInterval = 0

    // The observation overlay must never hide the actual child from hitTest.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        } else if window == nil {
            removeMonitor()
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard let window, event.window == window,
              event.hasPreciseScrollingDeltas else { return }

        if IslandSurfaceSwipeSuppression.isActive(at: event.timestamp) {
            resetGesture()
            scrollOwnership.reset()
            return
        }

        let isOverNestedScrollView: Bool
        if givesNestedScrollViewsPriority, let contentView = window.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            isOverNestedScrollView = IslandSurfaceScrollHitTest.isOverNestedScrollView(
                at: point, in: contentView
            )
        } else {
            isOverNestedScrollView = false
        }
        let allowsSurfaceSwipe = scrollOwnership.allowsSurfaceSwipe(
            phase: event.phase, momentumPhase: event.momentumPhase, timestamp: event.timestamp,
            givesNestedScrollViewsPriority: givesNestedScrollViewsPriority,
            isOverNestedScrollView: isOverNestedScrollView
        )

        let now = event.timestamp
        if now - lastScrollEventTime > gestureTimeout {
            resetGesture()
        }
        lastScrollEventTime = now

        switch event.phase {
        case .began:
            resetGesture()

        case .ended, .cancelled:
            return

        default:
            break
        }

        // Momentum scrolls can arrive after the primary gesture has already
        // switched tabs. Ignore them so one physical swipe moves exactly once.
        guard event.momentumPhase == [] else { return }
        guard allowsSurfaceSwipe else {
            resetGesture()
            return
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        guard deltaX != 0 || deltaY != 0 else { return }

        accumulatedDeltaX += deltaX
        accumulatedDeltaY += deltaY
        totalAbsDeltaX += abs(deltaX)
        totalAbsDeltaY += abs(deltaY)

        updateLockedAxis()
        guard !hasFired, lockedAxis != .vertical else { return }

        if lockedAxis == .horizontal,
           abs(accumulatedDeltaX) >= horizontalTriggerThreshold {
            hasFired = true
            let direction: SwipeDirection = accumulatedDeltaX < 0 ? .left : .right
            DispatchQueue.main.async { [weak self] in
                self?.onSwipe?(direction)
            }
        }
    }

    private func updateLockedAxis() {
        guard lockedAxis == .undecided else { return }

        if totalAbsDeltaX >= horizontalLockThreshold,
           totalAbsDeltaX > totalAbsDeltaY * horizontalDominanceRatio {
            lockedAxis = .horizontal
            return
        }

        if totalAbsDeltaY >= verticalLockThreshold,
           totalAbsDeltaY > totalAbsDeltaX * verticalDominanceRatio {
            lockedAxis = .vertical
        }
    }

    private func resetGesture() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        totalAbsDeltaX = 0
        totalAbsDeltaY = 0
        lockedAxis = .undecided
        hasFired = false
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        scrollOwnership.reset()
        resetGesture()
    }

    deinit {
        removeMonitor()
    }
}
