import AppKit
import CoreGraphics

/// A fresh drag pasteboard belongs to an observed mouse gesture. An old file
/// pasteboard must never turn an ordinary window drag into a Shelf presentation.
struct ShelfFileDragState {
    enum Action: Equatable { case none, enter, leave }

    private(set) var baselineChangeCount: Int?
    private(set) var inputGeneration: UInt64 = 0
    private(set) var didEnter = false
    private(set) var ownsTarget = false
    var isTracking: Bool { baselineChangeCount != nil }

    mutating func begin(changeCount: Int, inputGeneration: UInt64) {
        baselineChangeCount = changeCount
        self.inputGeneration = inputGeneration
        didEnter = false
        ownsTarget = false
    }

    mutating func update(changeCount: Int, hasFileURL: Bool, nearCompactIsland: Bool,
                         insidePresentation: Bool, inputAllowed: Bool) -> Action {
        guard let baselineChangeCount else { return .none }
        guard inputAllowed else { return end() }
        if ownsTarget && !insidePresentation {
            ownsTarget = false
            return .leave
        }
        guard !didEnter, changeCount != baselineChangeCount,
              hasFileURL, nearCompactIsland else { return .none }
        didEnter = true
        ownsTarget = true
        return .enter
    }

    mutating func end() -> Action {
        let action: Action = ownsTarget ? .leave : .none
        baselineChangeCount = nil
        ownsTarget = false
        return action
    }
}

enum ShelfFileDragGeometry {
    static func approachBand(below frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY - 32, width: frame.width, height: 32)
    }

    /// Include a segment crossing so a coalesced drag event cannot simply skip
    /// the narrow approach band. Coordinates are AppKit screen coordinates.
    static func approaches(_ frame: CGRect, from previous: CGPoint?, to point: CGPoint) -> Bool {
        let band = approachBand(below: frame)
        if band.contains(point) { return true }
        guard let previous, !band.isEmpty else { return false }
        var start: CGFloat = 0
        var end: CGFloat = 1
        for (origin, delta, lower, upper) in [
            (previous.x, point.x - previous.x, band.minX, band.maxX),
            (previous.y, point.y - previous.y, band.minY, band.maxY)
        ] {
            if delta == 0 {
                if origin < lower || origin > upper { return false }
            } else {
                let first = (lower - origin) / delta
                let second = (upper - origin) / delta
                start = max(start, min(first, second))
                end = min(end, max(first, second))
                if start > end { return false }
            }
        }
        return true
    }
}

/// Opens the real drop destinations before a Finder file reaches the system's
/// top-edge drag region. It never accepts files or alters the observed events.
@MainActor
final class ShelfFileDragMonitor {
    private let appState: AppState
    private let visiblePanels: () -> [IslandPanel]
    private let targetID = UUID()
    private var state = ShelfFileDragState()
    private var previousPoint: CGPoint?
    private var approachedPanelID: ObjectIdentifier?
    private var recordedFreshPasteboard = false
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var releaseTimer: Timer?
    private var sessionActive = true
    private var awake = true

    init(appState: AppState, visiblePanels: @escaping () -> [IslandPanel]) {
        self.appState = appState
        self.visiblePanels = visiblePanels
    }

    func start() {
        guard globalMonitor == nil else { return }
        guard let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown], handler: { [weak self] event in
            // AppKit delivers global monitor callbacks on the main thread.
            // Capture the down pasteboard generation here, before queuing work
            // would allow the source app to publish the new drag pasteboard.
            MainActor.assumeIsolated { self?.observe(event) }
        }) else { return }
        globalMonitor = monitor
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch notice.name {
                    case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                    case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionActive = true
                    case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification: self.awake = false
                    case NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification: self.awake = true
                    default: break
                    }
                    // Wake/unlock starts with no saved gesture to replay.
                    self.finish()
                }
            })
        }
    }

    func stop() {
        finish()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private var inputAllowed: Bool {
        guard sessionActive, awake, appState.shelfEnabled,
              appState.canHandleIslandInput(generation: state.inputGeneration) else { return false }
        let panels = visiblePanels()
        guard !panels.isEmpty else { return false }
        if let approachedPanelID {
            return panels.contains { ObjectIdentifier($0) == approachedPanelID }
        }
        return true
    }

    private func observe(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            finish()
            guard sessionActive, awake, appState.shelfEnabled,
                  !appState.isZilanInteractionSuppressed, !visiblePanels().isEmpty else { return }
            state.begin(changeCount: NSPasteboard(name: .drag).changeCount,
                        inputGeneration: appState.islandInputGeneration)
            ShelfDropDiagnostics.record("approach.down", values: ["changeCount": Int64(state.baselineChangeCount ?? 0)])
            previousPoint = NSEvent.mouseLocation
            beginReleaseChecks()
        case .leftMouseDragged:
            guard state.isTracking else { return }
            guard inputAllowed, NSEvent.pressedMouseButtons & 1 != 0 else { finish(); return }
            let point = NSEvent.mouseLocation
            let panels = visiblePanels()
            let frames = panels.map(\.frame)
            let nearPanel = appState.currentState == .compact ? panels.first {
                ShelfFileDragGeometry.approaches($0.frame, from: previousPoint, to: point)
            } : nil
            let inside = frames.contains { $0.union(ShelfFileDragGeometry.approachBand(below: $0)).contains(point) }
            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            // Only inspect type metadata after this gesture changed the drag
            // pasteboard; never load URLs, file names, or provider payloads.
            let hasFileURL = changeCount != state.baselineChangeCount &&
                (pasteboard.types?.contains(.fileURL) ?? false)
            if hasFileURL && !recordedFreshPasteboard {
                recordedFreshPasteboard = true
                ShelfDropDiagnostics.record("approach.file", values: ["changeCount": Int64(changeCount)])
            }
            let action = state.update(changeCount: changeCount, hasFileURL: hasFileURL,
                                      nearCompactIsland: nearPanel != nil, insidePresentation: inside,
                                      inputAllowed: true)
            previousPoint = point
            if action == .enter, let nearPanel { approachedPanelID = ObjectIdentifier(nearPanel) }
            apply(action)
        case .leftMouseUp:
            finish()
        case .keyDown:
            if event.keyCode == 53, state.isTracking { finish() }
        default: break
        }
    }

    private func beginReleaseChecks() {
        // Native drag/drop can route mouseUp to this app, outside a global
        // monitor. This timer exists only while a down gesture is being tracked.
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.inputAllowed || NSEvent.pressedMouseButtons & 1 == 0 ||
                    CGEventSource.keyState(.combinedSessionState, key: 53) {
                    self.finish()
                }
            }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finish() {
        apply(state.end())
        previousPoint = nil
        approachedPanelID = nil
        recordedFreshPasteboard = false
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    private func apply(_ action: ShelfFileDragState.Action) {
        switch action {
        case .none: break
        case .enter:
            ShelfDropDiagnostics.record("approach.enter")
            appState.setShelfDropTarget(targetID, inside: true)
        case .leave:
            ShelfDropDiagnostics.record("approach.leave")
            // DropDelegate owns its own IDs and the final performDrop. Removing
            // this one ID preserves its normal 350ms destination handoff.
            appState.setShelfDropTarget(targetID, inside: false)
        }
    }
}
