import AppKit
import ApplicationServices
import SwiftUI

/// Identity must survive thumbnail completion/reordering. Array indexes are
/// presentation coordinates, never the identity of a click target.
struct WindowPreviewIdentity: Hashable {
    let processID: pid_t
    let windowID: CGWindowID
}

enum WindowPreviewPointerAction<Target: Hashable>: Equatable {
    case activate(Target)
    case close(Target)
}

/// One event-driven state machine for both previews. No timers or AX calls.
/// A release can act only on the same target AND action as its own press.
struct WindowPreviewPointerState<Target: Hashable> {
    private(set) var hovered: Target?
    private var pressed: WindowPreviewPointerAction<Target>?
    private var frames: [Target: CGRect] = [:]
    private var closable: Set<Target> = []
    private var activatable: Set<Target> = []
    var closeButtonSize: CGFloat = 20

    init(closeButtonSize: CGFloat = 20) { self.closeButtonSize = closeButtonSize }

    mutating func update(
        frames: [Target: CGRect],
        activatable: Set<Target>,
        closable: Set<Target>
    ) {
        // Never let an in-flight click follow a card as it moves/reorders.
        if self.frames != frames || self.activatable != activatable || self.closable != closable {
            pressed = nil
        }
        self.frames = frames.filter {
            $0.value.width > 0 && $0.value.height > 0 && !$0.value.isInfinite && !$0.value.isNull
        }
        self.activatable = activatable
        self.closable = closable
        if let hovered, self.frames[hovered] == nil { self.hovered = nil }
    }

    mutating func handle(_ type: NSEvent.EventType, at point: CGPoint) -> WindowPreviewPointerAction<Target>? {
        if type == .mouseExited {
            resetPointer()
            return nil
        }
        let hits = frames.filter { $0.value.contains(point) }
        // Overlap during animation is ambiguous, not an arbitrary dictionary hit.
        guard hits.count == 1, let hit = hits.first else {
            resetPointer()
            return nil
        }
        hovered = hit.key
        let closeFrame = CGRect(
            x: hit.value.minX + 5, y: hit.value.minY + 5,
            width: closeButtonSize, height: closeButtonSize
        )
        let action: WindowPreviewPointerAction<Target>? = closable.contains(hit.key) && closeFrame.contains(point)
            ? .close(hit.key)
            : (activatable.contains(hit.key) ? .activate(hit.key) : nil)
        switch type {
        case .leftMouseDown:
            pressed = action
        case .leftMouseUp:
            let started = pressed
            pressed = nil
            if started == action { return started }
        default:
            break
        }
        return nil
    }

    mutating func resetPointer() {
        hovered = nil
        pressed = nil
    }
}

/// A real AppKit hit view, above the hosting tree, owns the first click and
/// tracks even when the nonactivating panel's App is in the background.
/// Accessibility buttons remain in the hosting tree; wheel input is forwarded
/// to its actual hit view so horizontal multi-window scrolling still works.
final class WindowPreviewTrackingView: NSView {
    var onPointer: (NSEvent.EventType, CGPoint, TimeInterval) -> Void = { _, _, _ in }
    weak var scrollingView: NSView?
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { deliver(event, as: .mouseMoved) }
    override func mouseMoved(with event: NSEvent) { deliver(event) }
    override func mouseExited(with event: NSEvent) { deliver(event) }
    override func mouseDown(with event: NSEvent) { deliver(event) }
    override func mouseDragged(with event: NSEvent) { deliver(event) }
    override func mouseUp(with event: NSEvent) { deliver(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollingView, let parent = scrollingView.superview else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        scrollingView.hitTest(point)?.scrollWheel(with: event)
    }

    private func deliver(_ event: NSEvent, as type: NSEvent.EventType? = nil) {
        onPointer(type ?? event.type, convert(event.locationInWindow, from: nil), event.timestamp)
    }
}

/// The preview stays non-key so it cannot steal focus from Dock or the native
/// Cmd-Tab switcher. Pointer delivery is owned by the explicit tracking view
/// and the feature monitors rather than by changing application focus.
final class WindowPreviewInteractionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A genuinely blank document is not a phantom. Only strong AX document or
/// normal window-control evidence permits a uniform content image; a title,
/// main/focused flag, or one close dot alone does not prove a document window.
enum WindowPreviewCaptureEvidence {
    static func hasDocument(of window: AXUIElement) -> Bool {
        // Only the minimized-dialog admission path needs this extra read.
        // Unknown/error values cannot authorize that exception.
        AXUIElementSetMessagingTimeout(window, 0.075)
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXDocumentAttribute as CFString, &document
        ) == .success else { return false }
        return (document as? String)?.isEmpty == false || document is URL
    }

    static func allowsUniformContent(hasDocument: Bool, hasClose: Bool, hasMinimize: Bool, hasZoom: Bool) -> Bool {
        hasDocument || (hasClose && (hasMinimize || hasZoom))
    }

    static func allowsUniformContent(of window: AXUIElement) -> Bool {
        // One bounded IPC, not four extra synchronous calls per hover/window.
        AXUIElementSetMessagingTimeout(window, 0.075)
        let names = [kAXDocumentAttribute, kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, names as CFArray, [], &rawValues) == .success,
              let values = rawValues as? [AnyObject], values.count == names.count else { return false }
        let document = values[0]
        let hasDocument = (document as? String)?.isEmpty == false || document is URL
        func hasControl(_ index: Int) -> Bool {
            CFGetTypeID(values[index]) == AXUIElementGetTypeID()
        }
        return allowsUniformContent(
            hasDocument: hasDocument, hasClose: hasControl(1), hasMinimize: hasControl(2), hasZoom: hasControl(3)
        )
    }
}

/// Chooses the AX proxy used for operations after WindowServer has supplied
/// the canonical identity. Focused/main proxies are often sparse; AXWindows
/// can vend a second proxy for the same real window with the close button and
/// document metadata. Window identity and operation capability are therefore
/// ranked independently instead of allowing the first proxy to win forever.
struct WindowAXOperationProxyEvidence: Equatable {
    let hasWindowID: Bool
    let hasTitle: Bool
    let hasBounds: Bool
    let isPreferredWindow: Bool
    let canClose: Bool
    let allowsUniformContent: Bool
}

enum WindowAXOperationProxyPolicy {
    static func prefersCandidate(
        existing: WindowAXOperationProxyEvidence,
        candidate: WindowAXOperationProxyEvidence
    ) -> Bool {
        score(candidate) > score(existing)
    }

    private static func score(_ evidence: WindowAXOperationProxyEvidence) -> Int {
        var result = 0
        // Operation capability must outweigh a sparse proxy's direct ID. The
        // caller retains that canonical ID while adopting the richer element.
        if evidence.canClose { result += 32 }
        if evidence.allowsUniformContent { result += 16 }
        if evidence.hasWindowID { result += 8 }
        if evidence.hasBounds { result += 4 }
        if evidence.hasTitle { result += 2 }
        if evidence.isPreferredWindow { result += 1 }
        return result
    }
}

@MainActor
private enum WindowPreviewFrameReporterOwner {
    private static var lastIssued: UInt64 = 0

    static func issue() -> UInt64 {
        lastIssued += 1
        return lastIssued
    }
}

/// An AppKit-backed frame reporter for cards drawn by SwiftUI. PreferenceKey
/// propagation is not a reliable interaction boundary inside a nonactivating
/// NSPanel: the card can be visible before its preference reaches the model.
/// This view reports its actual laid-out rectangle in the panel content view's
/// top-left coordinate system, exactly matching WindowPreviewTrackingView.
@MainActor
final class WindowPreviewFrameReportingView<Target: Hashable>: NSView {
    private(set) var target: Target
    let frameOwner = WindowPreviewFrameReporterOwner.issue()
    private var generation: UInt64
    private var onOwnedChange: (Target, CGRect?, UInt64) -> Void
    private var lastReportedFrame: CGRect?
    private var frameObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var isDetached = false

    convenience init(target: Target, generation: UInt64 = 0, onChange: @escaping (Target, CGRect?) -> Void) {
        self.init(target: target, generation: generation, onOwnedChange: { target, frame, _ in
            onChange(target, frame)
        })
    }

    init(target: Target, generation: UInt64 = 0, onOwnedChange: @escaping (Target, CGRect?, UInt64) -> Void) {
        self.target = target
        self.generation = generation
        self.onOwnedChange = onOwnedChange
        super.init(frame: .zero)
        postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFrame() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func update(target: Target, generation: UInt64 = 0, onChange: @escaping (Target, CGRect?) -> Void) {
        update(target: target, generation: generation, onOwnedChange: { target, frame, _ in
            onChange(target, frame)
        })
    }

    func update(target: Target, generation: UInt64 = 0, onOwnedChange: @escaping (Target, CGRect?, UInt64) -> Void) {
        isDetached = false
        if self.target != target {
            self.onOwnedChange(self.target, nil, frameOwner)
        }
        // The owner can invalidate its hit-test table while SwiftUI retains
        // this view at the same target and rectangle. A new generation needs
        // a fresh report even when AppKit has no geometry change to announce.
        if self.target != target || self.generation != generation {
            lastReportedFrame = nil
        }
        self.target = target
        self.generation = generation
        self.onOwnedChange = onOwnedChange
        scheduleReport()
    }

    func detach() {
        isDetached = true
        onOwnedChange(target, nil, frameOwner)
        lastReportedFrame = nil
        stopObservingScroll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshScrollObservation()
        scheduleReport()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshScrollObservation()
        scheduleReport()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    private func scheduleReport() {
        DispatchQueue.main.async { [weak self] in self?.reportFrame() }
    }

    private func refreshScrollObservation() {
        stopObservingScroll()
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFrame() }
        }
    }

    private func stopObservingScroll() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
    }

    private func reportFrame() {
        guard !isDetached,
              let contentView = window?.contentView,
              bounds.width > 0,
              bounds.height > 0 else {
            if lastReportedFrame != nil {
                lastReportedFrame = nil
                onOwnedChange(target, nil, frameOwner)
            }
            return
        }
        let contentRect = convert(bounds, to: contentView)
        let reported = CGRect(
            x: contentRect.minX,
            y: contentView.isFlipped
                ? contentRect.minY
                : contentView.bounds.height - contentRect.maxY,
            width: contentRect.width,
            height: contentRect.height
        )
        guard reported.width.isFinite,
              reported.height.isFinite,
              reported.minX.isFinite,
              reported.minY.isFinite,
              reported.width > 0,
              reported.height > 0,
              reported != lastReportedFrame else { return }
        lastReportedFrame = reported
        onOwnedChange(target, reported, frameOwner)
    }
}

struct WindowPreviewFrameReporter<Target: Hashable>: NSViewRepresentable {
    let target: Target
    var generation: UInt64 = 0
    private let onOwnedChange: (Target, CGRect?, UInt64) -> Void

    init(target: Target, generation: UInt64 = 0, onChange: @escaping (Target, CGRect?) -> Void) {
        self.init(target: target, generation: generation, onOwnedChange: { target, frame, _ in
            onChange(target, frame)
        })
    }

    init(target: Target, generation: UInt64 = 0, onOwnedChange: @escaping (Target, CGRect?, UInt64) -> Void) {
        self.target = target
        self.generation = generation
        self.onOwnedChange = onOwnedChange
    }

    func makeNSView(context: Context) -> WindowPreviewFrameReportingView<Target> {
        WindowPreviewFrameReportingView(target: target, generation: generation, onOwnedChange: onOwnedChange)
    }

    func updateNSView(
        _ nsView: WindowPreviewFrameReportingView<Target>,
        context: Context
    ) {
        nsView.update(target: target, generation: generation, onOwnedChange: onOwnedChange)
    }

    static func dismantleNSView(
        _ nsView: WindowPreviewFrameReportingView<Target>,
        coordinator: ()
    ) {
        nsView.detach()
    }
}
