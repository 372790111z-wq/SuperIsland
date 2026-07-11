import AppKit
import SwiftUI
import Combine

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container that keeps the hosting view centered horizontally and
/// pinned to the top, regardless of the container/window size.
/// Unlike autoresizingMask, this handles the 0-margin edge case correctly.
private final class CenteringContainerView: NSView {
    override func layout() {
        super.layout()
        guard let hostingView = subviews.first else { return }
        hostingView.frame.origin.x = (bounds.width - hostingView.frame.width) / 2
        // AppKit coords: y=0 at bottom. Pin hosting view top to container top.
        hostingView.frame.origin.y = bounds.height - hostingView.frame.height
    }
}

@MainActor
final class IslandWindowController {
    /// Panels keyed by the display id string they live on.
    private var panels: [String: IslandPanel] = [:]
    /// Screens currently hidden because a fullscreen app is covering them.
    private var hiddenForFullscreen: Set<String> = []
    private let appState = AppState.shared
    private var screenObserver: Any?
    private var defaultsObserver: Any?
    private var activeSpaceObserver: Any?
    private var presentationHoldObserver: Any?
    private var fullscreenPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var shrinkWorkItem: DispatchWorkItem?
    private var isShowing = false

    func showIsland() {
        isShowing = true
        syncPanels(display: true)

        setupDidChangeStateHook()
        observeScreenChanges()
        observeSettingsChanges()
        observePresentationHoldChanges()
        observeStateChanges()
        observeCompactLayoutChanges()
        observeFullscreenChanges()
        updateFullscreenVisibility()
    }

    func hideIsland() {
        isShowing = false
        for panel in panels.values {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel lifecycle

    /// Reconciles the set of panels with the set of target screens.
    /// Creates new panels for screens that don't have one yet and tears
    /// down panels for screens that are no longer in the target set.
    private func syncPanels(display: Bool) {
        guard isShowing else { return }

        let targets = targetScreens()
        let targetIDs = Set(targets.compactMap { ScreenDetector.displayIDString(for: $0) })

        // Remove panels for screens that are no longer targeted (or disconnected).
        for (id, panel) in panels where !targetIDs.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
            hiddenForFullscreen.remove(id)
        }

        // Pick the screen that drives the shared SwiftUI presentation context.
        // Preference order: user-picked single display → primary screen if targeted
        // → first notched target → first target.
        let primary = preferredPresentationScreen(from: targets)
        if let primary {
            appState.updatePresentationContext(screen: primary)
        }

        // Create or update a panel for each target screen.
        for screen in targets {
            guard let id = ScreenDetector.displayIDString(for: screen) else { continue }
            let panel = panels[id] ?? makePanel()
            if panels[id] == nil {
                panels[id] = panel
            }
            applyFrame(size: appState.windowSize, to: panel, screen: screen, display: display)
            panel.setVisibleInScreenRecordings(appState.showInScreenRecordings)
            if !hiddenForFullscreen.contains(id) {
                panel.orderFrontRegardless()
            }
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel()

        // The hosting view is set to the MAXIMUM possible size and
        // NEVER resizes. The window acts as a clipping viewport:
        // compact window → only the notch area is visible/clickable,
        // expanded window → the full surface is revealed.
        // Because the hosting view never changes size, SwiftUI never
        // re-layouts from window changes — no "jump left" on expand.
        let maxSize = maxWindowSize
        let hostingView = FirstMouseHostingView(
            rootView: IslandContainerView()
                .environmentObject(appState)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: maxSize.width, height: maxSize.height)
        hostingView.autoresizingMask = [] // Never resize — container handles positioning.

        let containerView = CenteringContainerView()
        containerView.addSubview(hostingView)
        panel.contentView = containerView

        return panel
    }

    /// The set of screens the island should currently be visible on,
    /// derived from the user's display setting.
    private func targetScreens() -> [NSScreen] {
        let id = appState.displayIdentifier

        if id == ScreenDetector.allDisplaysIdentifier {
            return NSScreen.screens
        }

        if !id.isEmpty, let chosen = ScreenDetector.screen(withIDString: id) {
            return [chosen]
        }

        // Automatic: cursor screen → primary → first connected.
        let fallback = ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first
        return fallback.map { [$0] } ?? []
    }

    private func preferredPresentationScreen(from targets: [NSScreen]) -> NSScreen? {
        if targets.count == 1 { return targets.first }
        // Prefer a notched screen when one is in the target set. The notched
        // shape is the more constrained of the two — rendering as "notched"
        // on a non-notched display shows a pill at the top, which is tolerable;
        // rendering as "non-notched" on a notched display leaves the pill
        // floating away from the camera housing, which is visually broken.
        if let notched = targets.first(where: { ScreenDetector.hasNotch(screen: $0) }) {
            return notched
        }
        if let main = ScreenDetector.primaryScreen,
           targets.contains(where: { $0 == main }) {
            return main
        }
        return targets.first
    }

    // MARK: - Positioning

    private var maxWindowSize: CGSize {
        let full = appState.windowSize(for: .fullExpanded)
        let expanded = appState.windowSize(for: .expanded)
        return CGSize(
            width: max(full.width, expanded.width),
            height: max(full.height, expanded.height)
        )
    }

    private func applyFrame(size: CGSize, to panel: IslandPanel, screen: NSScreen, display: Bool = true) {
        let screenFrame = screen.frame
        let hasNotch = ScreenDetector.hasNotch(screen: screen)
        let notchRect = ScreenDetector.notchRect(screen: screen)

        let anchorX: CGFloat
        let anchorY: CGFloat
        if hasNotch, let notch = notchRect {
            anchorX = notch.midX
            anchorY = notch.maxY - Constants.expandedTopInset
        } else {
            anchorX = screenFrame.midX
            anchorY = screenFrame.maxY - Constants.expandedTopInset
        }

        let x = anchorX - size.width / 2
        let y = anchorY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: display)
    }

    /// Apply the given size to every active panel, each sized against its own screen.
    private func applyFrameToAll(size: CGSize, display: Bool = true) {
        for (id, panel) in panels {
            guard let screen = ScreenDetector.screen(withIDString: id) else { continue }
            applyFrame(size: size, to: panel, screen: screen, display: display)
        }
    }

    // MARK: - Window resize via didSet hook
    //
    // Fires from AppState.didSet — AFTER currentState has changed,
    // still INSIDE the withAnimation() block. No GeometryReader exists,
    // so the resize is invisible to SwiftUI. The surface stays centered
    // on the notch because both the window and surface are notch-centered.

    private func setupDidChangeStateHook() {
        appState.didChangeState = { [weak self] oldState, newState in
            guard let self else { return }
            let oldSize = self.appState.windowSize(for: oldState)
            let newSize = self.appState.windowSize(for: newState)

            if newSize.width > oldSize.width || newSize.height > oldSize.height {
                // The hosting view is fixed-size, so this resize only
                // changes the visible viewport — no SwiftUI re-layout.
                self.applyFrameToAll(size: self.maxWindowSize)

                // Refresh tracking areas after the viewport change so
                // .onContinuousHover picks up the correct hover state.
                for panel in self.panels.values {
                    panel.contentView?.subviews.forEach { $0.updateTrackingAreas() }
                }
            }
            // SHRINKING: keep window large during animation.
            // It's snapped to compact in observeStateChanges after 0.55s.
        }
    }

    // MARK: - State observation (dismiss scheduling + delayed shrink)

    private func observeStateChanges() {
        appState.$currentState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self, !self.panels.isEmpty else { return }

                self.shrinkWorkItem?.cancel()
                self.shrinkWorkItem = nil

                switch newState {
                case .expanded, .fullExpanded:
                    self.appState.suppressDismissScheduling = true
                    self.appState.cancelAutoDismiss()
                    self.appState.cancelFullExpandedDismiss()

                    // After the animation settles, re-enable dismiss and
                    // schedule it if the user isn't hovering. The 0.8s
                    // delay gives tracking areas time to stabilize after
                    // the window resize.
                    let expectedState = newState
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self else { return }
                        self.appState.suppressDismissScheduling = false

                        // Refresh tracking areas so hover state is accurate.
                        for panel in self.panels.values {
                            panel.contentView?.subviews.forEach { $0.updateTrackingAreas() }
                        }

                        guard self.appState.currentState == expectedState,
                              !self.appState.isHovering else { return }
                        if expectedState == .expanded {
                            self.appState.scheduleAutoDismiss()
                        } else {
                            self.appState.scheduleFullExpandedDismiss()
                        }
                    }

                case .compact:
                    self.appState.suppressDismissScheduling = false
                    // Shrink window AFTER the animation finishes.
                    // This releases the expanded click area.
                    let work = DispatchWorkItem { [weak self] in
                        guard let self,
                              self.appState.currentState == .compact else { return }
                        self.applyFrameToAll(size: self.appState.windowSize)
                        // Force tracking area recalculation so the next
                        // hover on the compact notch is detected.
                        for panel in self.panels.values {
                            panel.contentView?.subviews.forEach { $0.updateTrackingAreas() }
                        }
                    }
                    self.shrinkWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Compact layout changes

    private func observeCompactLayoutChanges() {
        appState.$activeModule
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCompactFrameIfNeeded()
            }
            .store(in: &cancellables)

        NowPlayingManager.shared.$title
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCompactFrameIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func updateCompactFrameIfNeeded() {
        guard appState.currentState == .compact else { return }
        applyFrameToAll(size: appState.windowSize)
    }

    // MARK: - Screen & Settings

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Screen topology may have changed (display added/removed) —
                // reconcile the panel set, then re-apply sizes.
                self.syncPanels(display: true)
                let size = self.appState.currentState == .compact
                    ? self.appState.windowSize : self.maxWindowSize
                self.applyFrameToAll(size: size)
            }
        }
    }

    private func observeSettingsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for panel in self.panels.values {
                    panel.setVisibleInScreenRecordings(self.appState.showInScreenRecordings)
                }
                // The display identifier may have changed — reconcile the
                // panel set (handles switching to/from All Displays and
                // moving between single screens). Also keeps compact frame
                // in sync with size-affecting settings like "Hide side slots".
                self.syncPanels(display: true)
                self.updateCompactFrameIfNeeded()
                self.updateFullscreenVisibility()
            }
        }
    }

    private func observePresentationHoldChanges() {
        presentationHoldObserver = NotificationCenter.default.addObserver(
            forName: .islandPresentationHoldDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }
    }

    // MARK: - Fullscreen hiding
    //
    // When the user opts in via Settings we hide each panel individually
    // while a non-SuperIsland window exactly covers its screen (the classic
    // signature of a native macOS fullscreen app). Each screen is evaluated
    // independently so an external monitor running fullscreen video doesn't
    // pull down the island on the MacBook's built-in display.

    private func observeFullscreenChanges() {
        // activeSpaceDidChange fires when the user enters/exits fullscreen
        // (each fullscreen app gets its own space) or switches spaces.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }

        // Low-frequency safety net: some fullscreen transitions (e.g. the
        // native video player going fullscreen in-place) don't always fire
        // a space change notification, so re-check every 2s while the
        // controller is alive. The check is cheap (CGWindowListCopyWindowInfo
        // with bounds only) and only runs as long as the app is up.
        fullscreenPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }
    }

    private func updateFullscreenVisibility() {
        let shouldConsider = appState.hideOnFullscreen && !appState.isTeleprompterPresentationHeld

        for (id, panel) in panels {
            guard let screen = ScreenDetector.screen(withIDString: id) else { continue }

            let wasHidden = hiddenForFullscreen.contains(id)
            let fullscreen = shouldConsider && Self.isFullscreenWindowPresent(on: screen)

            if fullscreen && !wasHidden {
                hiddenForFullscreen.insert(id)
                panel.orderOut(nil)
            } else if !fullscreen && wasHidden {
                hiddenForFullscreen.remove(id)
                panel.orderFrontRegardless()
            }
        }
    }

    /// Returns true when another process effectively covers the given screen.
    ///
    /// Most fullscreen apps expose one layer-0 window that covers the display.
    /// Some browsers and video players split fullscreen content across several
    /// layer-0 windows from the same process, so we also evaluate per-process
    /// combined coverage.
    private static func isFullscreenWindowPresent(on screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        let screenFrame = cgDisplayBounds(for: screen) ?? screen.frame
        let screenArea = max(screenFrame.width * screenFrame.height, 1)
        let edgeTolerance: CGFloat = 3
        let coverageThreshold: CGFloat = 0.985
        let frontmostPID = NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
        var windowsByOwner: [Int: [CGRect]] = [:]

        for window in info {
            // Skip windows owned by SuperIsland itself.
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, pid != ourPID else {
                continue
            }
            // Only consider windows in the normal content layer. The menu
            // bar, Dock, and status items live on non-zero layers.
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            if let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0.05 {
                continue
            }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let clipped = rect.intersection(screenFrame)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }

            let coverage = (clipped.width * clipped.height) / screenArea
            if coverage >= coverageThreshold && touchesAllEdges(clipped, of: screenFrame, tolerance: edgeTolerance) {
                return true
            }
            if pid == frontmostPID && coversFullscreenLikeArea(clipped, of: screenFrame, tolerance: edgeTolerance) {
                return true
            }
            if coverage >= 0.02 {
                windowsByOwner[pid, default: []].append(clipped)
            }
        }

        for (pid, rects) in windowsByOwner where rects.count > 1 {
            let union = rects.reduce(CGRect.null) { $0.union($1) }
            let coverage = coveredArea(rects, within: screenFrame) / screenArea

            if pid == frontmostPID,
               coverage >= 0.93,
               coversFullscreenLikeArea(union, of: screenFrame, tolerance: edgeTolerance) {
                return true
            }

            guard touchesAllEdges(union, of: screenFrame, tolerance: edgeTolerance) else {
                continue
            }
            let largestWindowCoverage = rects
                .map { ($0.width * $0.height) / screenArea }
                .max() ?? 0
            let hasDominantTopSurface = rects.contains { rect in
                let rectCoverage = (rect.width * rect.height) / screenArea
                return rectCoverage >= 0.5
                    && touchesHorizontalEdges(rect, of: screenFrame, tolerance: edgeTolerance)
                    && abs(rect.minY - screenFrame.minY) <= edgeTolerance
            }

            if coverage >= coverageThreshold && largestWindowCoverage >= 0.5 && hasDominantTopSurface {
                return true
            }
        }
        return false
    }

    private static func cgDisplayBounds(for screen: NSScreen) -> CGRect? {
        guard let id = ScreenDetector.displayIDString(for: screen),
              let displayID = CGDirectDisplayID(id) else {
            return nil
        }
        return CGDisplayBounds(displayID)
    }

    private static func touchesAllEdges(_ rect: CGRect, of screen: CGRect, tolerance: CGFloat) -> Bool {
        abs(rect.minX - screen.minX) <= tolerance
            && abs(rect.maxX - screen.maxX) <= tolerance
            && abs(rect.minY - screen.minY) <= tolerance
            && abs(rect.maxY - screen.maxY) <= tolerance
    }

    private static func touchesHorizontalEdges(_ rect: CGRect, of screen: CGRect, tolerance: CGFloat) -> Bool {
        abs(rect.minX - screen.minX) <= tolerance
            && abs(rect.maxX - screen.maxX) <= tolerance
    }

    private static func coversFullscreenLikeArea(_ rect: CGRect, of screen: CGRect, tolerance: CGFloat) -> Bool {
        let topInset = rect.minY - screen.minY
        let maximumMenuBarInset = min(max(screen.height * 0.08, 56), 96)
        let heightCoverage = rect.height / max(screen.height, 1)

        return touchesHorizontalEdges(rect, of: screen, tolerance: tolerance)
            && abs(rect.maxY - screen.maxY) <= tolerance
            && topInset >= -tolerance
            && topInset <= maximumMenuBarInset
            && heightCoverage >= 0.93
    }

    private static func coveredArea(_ rects: [CGRect], within screen: CGRect) -> CGFloat {
        let clipped = rects
            .map { $0.intersection(screen) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !clipped.isEmpty else { return 0 }

        let xs = Set(clipped.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard xs.count > 1 else { return 0 }

        var area: CGFloat = 0
        for index in 0..<(xs.count - 1) {
            let x0 = xs[index]
            let x1 = xs[index + 1]
            guard x1 > x0 else { continue }

            var intervals: [(CGFloat, CGFloat)] = []
            for rect in clipped where rect.minX < x1 && rect.maxX > x0 {
                intervals.append((rect.minY, rect.maxY))
            }
            guard !intervals.isEmpty else { continue }

            intervals.sort { $0.0 < $1.0 }
            var coveredHeight: CGFloat = 0
            var current = intervals[0]
            for interval in intervals.dropFirst() {
                if interval.0 <= current.1 {
                    current.1 = max(current.1, interval.1)
                } else {
                    coveredHeight += current.1 - current.0
                    current = interval
                }
            }
            coveredHeight += current.1 - current.0
            area += (x1 - x0) * coveredHeight
        }
        return area
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = presentationHoldObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        fullscreenPollTimer?.invalidate()
        cancellables.removeAll()
    }
}
