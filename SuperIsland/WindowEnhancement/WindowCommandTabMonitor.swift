import AppKit
import ApplicationServices
import Darwin
import OSLog
import SwiftUI

/// One inclusion policy for every window-preview entry point. Dock and
/// Cmd-Tab deliberately share these semantics so an App's background AX shell
/// cannot appear in one preview while being filtered from the other.
enum WindowAXCandidatePolicy {
    static func shouldInclude(
        role: String,
        subrole: String,
        isModal: Bool?,
        title: String,
        isMinimized: Bool,
        isPreferredWindow: Bool,
        isHidden: Bool?,
        isVisible: Bool?
    ) -> Bool {
        guard role == kAXWindowRole as String,
              subrole == kAXStandardWindowSubrole as String,
              isModal != true else { return false }
        // AX can expose hidden helper windows as focused/main proxies. Hidden
        // state is authoritative even when that proxy is also marked minimized.
        guard isHidden != true else { return false }
        if isMinimized { return true }
        guard isVisible != false else { return false }

        // Title and focused/main status are ranking metadata, not proof that an
        // AX proxy represents a user window. Canonical admission happens later
        // against WindowServer identity, placement and surface properties.
        _ = title
        _ = isPreferredWindow
        return true
    }

    static func areExactProxies(
        lhsPID: pid_t,
        lhsTitle: String,
        lhsBounds: CGRect?,
        lhsIsMinimized: Bool,
        rhsPID: pid_t,
        rhsTitle: String,
        rhsBounds: CGRect?,
        rhsIsMinimized: Bool
    ) -> Bool {
        guard lhsPID == rhsPID,
              !lhsTitle.isEmpty,
              lhsTitle == rhsTitle,
              lhsIsMinimized == rhsIsMinimized,
              let lhsBounds,
              let rhsBounds else { return false }
        return abs(lhsBounds.minX - rhsBounds.minX) <= 1
            && abs(lhsBounds.minY - rhsBounds.minY) <= 1
            && abs(lhsBounds.width - rhsBounds.width) <= 1
            && abs(lhsBounds.height - rhsBounds.height) <= 1
    }
}

typealias WindowAXWindowNumberResolver = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Tahoe can omit both public WindowServer number attributes on the focused
/// and main AX proxies even though the underlying window has an exact ID. Use
/// the same fail-closed resolver path as Mission Control: public and private
/// identities must agree whenever both are present.
let windowPrivateWindowNumberResolver: WindowAXWindowNumberResolver? = {
    let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    let handles = [
        dlopen(nil, RTLD_LAZY),
        dlopen(frameworkPath, RTLD_LAZY)
    ].compactMap { $0 }
    for handle in handles {
        if let symbol = dlsym(handle, "_AXUIElementGetWindow") {
            return unsafeBitCast(symbol, to: WindowAXWindowNumberResolver.self)
        }
    }
    return nil
}()

func windowDirectWindowNumber(
    of element: AXUIElement
) -> CGWindowID? {
    var numbers = Set<CGWindowID>()
    for name in ["AXWindowNumber", "AXWindowID"] {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber,
        number.uint32Value > 0 {
            numbers.insert(CGWindowID(number.uint32Value))
        }
    }
    if let resolver = windowPrivateWindowNumberResolver {
        var number: CGWindowID = 0
        if resolver(element, &number) == .success, number > 0 {
            numbers.insert(number)
        }
    }
    guard numbers.count == 1 else { return nil }
    return numbers.first
}

@MainActor
final class WindowCommandTabMonitor {
    private let preferences = WindowEnhancementPreferences.shared
    private let overlay = CommandTabOverlayController()
    private let nativeSwitcher = NativeProcessSwitcherBridge()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.superisland.app",
        category: "CmdTabPlus"
    )
    private var eventTap: CFMachPort?
    private var nativePointerClickCaptured = false
    private var nativePointerReleaseCleanup: DispatchWorkItem?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRetryTask: Task<Void, Never>?
    private var eventTapInstallAttempts = 0
    private var reportedEventTapFailure = false
    private var accessibilityTrustRetryTask: Task<Void, Never>?
    private var accessibilityTrustRetryAttempt = 0
    private var activationObserver: NSObjectProtocol?
    private var previewInvalidationObserver: NSObjectProtocol?
    private var thumbnailCaptureTask: Task<Void, Never>?
    private var postCloseRefreshTask: Task<Void, Never>?
    private var closeWindowRetryTask: Task<Void, Never>?
    private var selectedApplicationRefreshTask: Task<Void, Never>?
    private var concreteWindowActivationTask: Task<Void, Never>?
    private var nativeSwitcherSyncTask: Task<Void, Never>?
    private var nativePointerSyncWorkItem: DispatchWorkItem?
    private var nativePointerEventTap: CFMachPort?
    private var nativePointerRunLoopSource: CFRunLoopSource?
    private var pendingNativePointerLocation: CGPoint?
    private var loggedNativePointerActivity = false
    private var thumbnailCaptureGeneration = 0
    private var currentThumbnailResults: [WindowThumbnailResult?] = []
    private var previewOnlyWindows: [CommandTabWindowDisplayItem] = []
    private var previewLoading = false
    private var nativeSwitcherAnchorFrame: CGRect?
    private var hasExplicitWindowSelection = false
    private var reportedAccessibilityUnavailable = false
    private struct PrewarmJob: Sendable {
        let applicationIdentity: WindowThumbnailApplicationIdentity
        let requests: [WindowThumbnailRequest]
    }

    /// Prewarming is intentionally serialized. Starting one ScreenCaptureKit
    /// enumeration per visible App at launch can retain hundreds of decoded
    /// window images at once and overwhelm WindowServer before Cmd-Tab is ever
    /// used. The active App is still refreshed on every activation, while a
    /// small MRU seed keeps inactive-fullscreen previews useful after launch.
    private var pendingPrewarmJobs: [pid_t: PrewarmJob] = [:]
    private var pendingPrewarmOrder: [pid_t] = []
    private var activePrewarmPID: pid_t?
    private var activePrewarmTask: Task<Void, Never>?
    private var candidates: [Candidate] = []
    private var selectedIndex = 0
    private var selectedWindowIndex = 0
    private var isPresenting = false
    private var commandSequenceActive = false
    private var eventSequenceID = 0
    private var queuedEventActions: [QueuedEventAction] = []
    private var eventActionDrainTask: Task<Void, Never>?
    private var eventActionGeneration = 0

    private enum QueuedEventAction {
        case syncNativeSelection(sequenceID: Int)
        case moveWindowSelection(reverse: Bool, sequenceID: Int)
        case selectWindow(index: Int, sequenceID: Int)
        case commitWindow(applicationIndex: Int, windowIndex: Int, sequenceID: Int)
        case closeWindow(applicationIndex: Int, windowIndex: Int, sequenceID: Int)
        case closeSelectedWindow(sequenceID: Int)
        case quitSelectedApplication(sequenceID: Int)
        case finish(sequenceID: Int)

        var sequenceID: Int {
            switch self {
            case let .syncNativeSelection(sequenceID),
                 let .moveWindowSelection(_, sequenceID),
                 let .selectWindow(_, sequenceID),
                 let .commitWindow(_, _, sequenceID),
                 let .closeWindow(_, _, sequenceID),
                 let .closeSelectedWindow(sequenceID),
                 let .quitSelectedApplication(sequenceID),
                 let .finish(sequenceID):
                sequenceID
            }
        }
    }

    private struct WindowCandidate {
        let application: NSRunningApplication
        let element: AXUIElement
        let title: String
        let bounds: CGRect?
        let windowID: CGWindowID?
        let isMinimized: Bool
        let isPreferredWindow: Bool
        let canClose: Bool
        var allowsUniformContent = false
    }

    private struct Candidate {
        let applications: [NSRunningApplication]
        let windows: [WindowCandidate]

        var application: NSRunningApplication {
            applications[0]
        }

        var processIdentifiers: [pid_t] {
            applications.map(\.processIdentifier).sorted()
        }
    }

    private struct IndexedThumbnailRequest: Sendable {
        let index: Int
        let request: WindowThumbnailRequest
    }

    private struct ThumbnailCaptureBatch: Sendable {
        let applicationIdentity: WindowThumbnailApplicationIdentity
        let requests: [IndexedThumbnailRequest]
    }

    func start() {
        WindowThumbnailProvider.beginLifecycleMonitoring()
        observePreviewInvalidationIfNeeded()
        observeApplicationActivationIfNeeded()
        updateEnabledState()
    }

    func stop() {
        accessibilityTrustRetryTask?.cancel()
        accessibilityTrustRetryTask = nil
        accessibilityTrustRetryAttempt = 0
        uninstallTap()
        cancel()
        removeNativePointerTap(force: true)
        nativeSwitcher.reset()
        cancelPrewarmTasks()
        WindowThumbnailProvider.clearAllCache()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let previewInvalidationObserver {
            NotificationCenter.default.removeObserver(previewInvalidationObserver)
            self.previewInvalidationObserver = nil
        }
    }

    func updateEnabledState() {
        let anyPreviewEnabled = preferences.isEnabled && (
            preferences.cmdTabPlusEnabled || preferences.dockPreviewEnabled
        )
        if !anyPreviewEnabled {
            cancelPrewarmTasks()
            WindowThumbnailProvider.clearAllCache()
        } else if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            schedulePrewarm(for: frontmostApplication)
        }
        guard preferences.isEnabled,
              preferences.cmdTabPlusEnabled else {
            accessibilityTrustRetryTask?.cancel()
            accessibilityTrustRetryTask = nil
            accessibilityTrustRetryAttempt = 0
            uninstallTap()
            cancel()
            return
        }
        guard AXIsProcessTrusted() else {
            uninstallTap()
            cancel()
            if !reportedAccessibilityUnavailable {
                reportedAccessibilityUnavailable = true
                logger.notice("Cmd-Tab Plus is disabled because live Accessibility trust is unavailable")
                preferences.publishFeedback("Cmd-Tab Plus 未启动：请为当前 SuperIsland 测试版重新开启辅助功能权限")
            }
            scheduleAccessibilityTrustRetryIfNeeded()
            return
        }
        accessibilityTrustRetryTask?.cancel()
        accessibilityTrustRetryTask = nil
        accessibilityTrustRetryAttempt = 0
        reportedAccessibilityUnavailable = false
        installTapIfNeeded()
    }

    /// TCC can relaunch the App before its new Accessibility grant is visible
    /// to the process. Retry for a short, bounded window so Cmd-Tab recovers
    /// automatically instead of requiring the user to toggle the feature.
    private func scheduleAccessibilityTrustRetryIfNeeded() {
        guard accessibilityTrustRetryTask == nil,
              accessibilityTrustRetryAttempt < 6,
              preferences.isEnabled,
              preferences.cmdTabPlusEnabled else { return }
        let delays: [UInt64] = [250, 500, 1_000, 2_000, 3_000, 4_000]
        let delay = delays[accessibilityTrustRetryAttempt]
        accessibilityTrustRetryAttempt += 1
        accessibilityTrustRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.accessibilityTrustRetryTask = nil
            self.updateEnabledState()
        }
    }

    private func installTapIfNeeded() {
        guard eventTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        // The tap is active only so extension keys such as Up/Down, number-row,
        // Command-W and Command-Q can be consumed while the native Process
        // Switcher is confirmed on screen. Base Cmd-Tab, arrows, Escape and
        // Command release are always passed through to Dock; SuperIsland no
        // longer replaces the native App switcher.
        let locations: [CGEventTapLocation] = [.cgSessionEventTap, .cgAnnotatedSessionEventTap]
        var installedLocation: CGEventTapLocation?
        let tap = locations.lazy.compactMap { location -> CFMachPort? in
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.eventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { return nil }
            installedLocation = location
            return tap
        }.first

        guard let tap else {
            eventTapInstallationFailed()
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard CGEvent.tapIsEnabled(tap: tap) else {
            tearDownTap()
            eventTapInstallationFailed()
            return
        }

        eventTapRetryTask?.cancel()
        eventTapRetryTask = nil
        eventTapInstallAttempts = 0
        reportedEventTapFailure = false
        logger.info("Cmd-Tab event tap installed at location \(String(describing: installedLocation), privacy: .public)")
    }

    private func uninstallTap() {
        eventTapRetryTask?.cancel()
        eventTapRetryTask = nil
        eventTapInstallAttempts = 0
        reportedEventTapFailure = false
        tearDownTap()
    }

    private func tearDownTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        eventTap = nil
    }

    private func eventTapInstallationFailed() {
        eventTapInstallAttempts += 1
        logger.error("Cmd-Tab event tap installation failed (attempt \(self.eventTapInstallAttempts, privacy: .public))")

        if !reportedEventTapFailure {
            reportedEventTapFailure = true
            preferences.publishFeedback("Cmd-Tab Plus 未能启动：系统拒绝键盘事件监听，请重新授权辅助功能并重启 SuperIsland")
        }

        guard eventTapInstallAttempts < 3,
              eventTapRetryTask == nil,
              preferences.isEnabled,
              preferences.cmdTabPlusEnabled,
              AXIsProcessTrusted() else { return }
        eventTapRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.eventTapRetryTask = nil
            self.installTapIfNeeded()
        }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<WindowCommandTabMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        // This tap is attached to CFRunLoopGetMain(), so the callback is on the
        // main run loop. Handling it synchronously keeps Escape/arrow events
        // from leaking into the foreground app while the switcher is visible.
        return MainActor.assumeIsolated {
            monitor.handleEvent(type: type, event: event)
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("Cmd-Tab event tap was disabled by the system (type \(type.rawValue, privacy: .public)); re-enabling")
            // A disabled tap can miss the physical Command release. Tear down
            // the transient preview before re-enabling so stale state can
            // never swallow a later Up/Down/number key in the foreground App.
            cancel()
            reenableTap()
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if keyCode == 48, event.flags.contains(.maskCommand) {
                if !commandSequenceActive {
                    logger.debug("Observed a new native Cmd-Tab sequence")
                    commandSequenceActive = true
                    hasExplicitWindowSelection = false
                    loggedNativePointerActivity = false
                    nativeSwitcher.reset()
                    eventSequenceID &+= 1
                    installNativePointerTapIfNeeded()
                }
                let sequenceID = eventSequenceID
                enqueueEventAction(.syncNativeSelection(sequenceID: sequenceID))
                return Unmanaged.passUnretained(event)
            }

            if isPresenting || commandSequenceActive {
                switch keyCode {
                case 53: // Escape cancels without activating the selection.
                    cancel()
                    return Unmanaged.passUnretained(event)
                case 13 where event.flags.contains(.maskCommand): // Command-W
                    // Keep the event swallowed while the physical key is held,
                    // but never let keyboard auto-repeat close the next window
                    // after the first close updates the current selection.
                    guard isPresenting else {
                        return Unmanaged.passUnretained(event)
                    }
                    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                        return nil
                    }
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.closeSelectedWindow(sequenceID: sequenceID))
                    return nil
                case 12 where event.flags.contains(.maskCommand): // Command-Q
                    guard isPresenting else {
                        return Unmanaged.passUnretained(event)
                    }
                    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                        return nil
                    }
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.quitSelectedApplication(sequenceID: sequenceID))
                    return nil
                case 123: // Left arrow
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.syncNativeSelection(sequenceID: sequenceID))
                    return Unmanaged.passUnretained(event)
                case 124: // Right arrow
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.syncNativeSelection(sequenceID: sequenceID))
                    return Unmanaged.passUnretained(event)
                case 126: // Up arrow selects the previous concrete window.
                    guard isPresenting else {
                        return Unmanaged.passUnretained(event)
                    }
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.moveWindowSelection(reverse: true, sequenceID: sequenceID))
                    return nil
                case 125: // Down arrow selects the next concrete window.
                    guard isPresenting else {
                        return Unmanaged.passUnretained(event)
                    }
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.moveWindowSelection(reverse: false, sequenceID: sequenceID))
                    return nil
                default:
                    if isPresenting,
                       let windowIndex = Self.numberWindowIndex(for: keyCode) {
                        let sequenceID = eventSequenceID
                        enqueueEventAction(.selectWindow(index: windowIndex, sequenceID: sequenceID))
                        return nil
                    }
                    break
                }
            }
        }

        if type == .flagsChanged,
           (commandSequenceActive || isPresenting),
           !event.flags.contains(.maskCommand) {
            commandSequenceActive = false
            let sequenceID = eventSequenceID
            enqueueEventAction(.finish(sequenceID: sequenceID))
        }
        return Unmanaged.passUnretained(event)
    }

    private func enqueueEventAction(_ action: QueuedEventAction) {
        queuedEventActions.append(action)
        guard eventActionDrainTask == nil else { return }
        let generation = eventActionGeneration
        eventActionDrainTask = Task { @MainActor [weak self] in
            // Yield once so the event tap can return promptly. Every event that
            // arrives before this task runs appends to the same FIFO, so a
            // Command release can never overtake its preceding Tab presses.
            await Task.yield()
            self?.drainEventActions(generation: generation)
        }
    }

    private func drainEventActions(generation: Int) {
        guard eventActionGeneration == generation else { return }
        while !queuedEventActions.isEmpty {
            guard eventActionGeneration == generation else { return }
            let action = queuedEventActions.removeFirst()
            guard action.sequenceID == eventSequenceID else { continue }
            switch action {
            case .syncNativeSelection:
                scheduleNativeSwitcherSync()
            case let .moveWindowSelection(reverse, _):
                moveWindowSelection(reverse: reverse)
            case let .selectWindow(index, _):
                selectWindow(index: index)
            case let .commitWindow(applicationIndex, windowIndex, _):
                commit(applicationIndex: applicationIndex, windowIndex: windowIndex)
            case let .closeWindow(applicationIndex, windowIndex, _):
                closeWindow(applicationIndex: applicationIndex, windowIndex: windowIndex)
            case .closeSelectedWindow:
                closeSelectedWindow()
            case .quitSelectedApplication:
                confirmQuitSelectedApplication()
            case .finish:
                finishCommandSequence()
            }
        }
        guard eventActionGeneration == generation else { return }
        eventActionDrainTask = nil
    }

    private func cancelQueuedEventActions() {
        eventActionDrainTask?.cancel()
        eventActionDrainTask = nil
        queuedEventActions.removeAll()
        eventActionGeneration &+= 1
    }

    private func finishCommandSequence() {
        let explicitSelection: (Candidate, WindowCandidate)? = {
            guard !nativePointerClickCaptured,
                  hasExplicitWindowSelection,
                  isPresenting,
                  candidates.indices.contains(selectedIndex),
                  candidates[selectedIndex].windows.indices.contains(selectedWindowIndex) else {
                return nil
            }
            return (
                candidates[selectedIndex],
                candidates[selectedIndex].windows[selectedWindowIndex]
            )
        }()
        cancel()
        if let explicitSelection {
            focusAfterNativeCommit(
                candidate: explicitSelection.0,
                window: explicitSelection.1
            )
        }
    }

    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    private static func numberWindowIndex(for keyCode: Int64) -> Int? {
        // Hardware key codes for the number row. Keypad digits intentionally
        // remain untouched so foreground applications keep their own input.
        let numberRow: [Int64: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4,
            22: 5, 26: 6, 28: 7, 25: 8
        ]
        return numberRow[keyCode]
    }

    private func scheduleNativeSwitcherSync() {
        guard preferences.isEnabled,
              preferences.cmdTabPlusEnabled,
              commandSequenceActive else {
            cancel()
            return
        }
        nativeSwitcherSyncTask?.cancel()
        let sequenceID = eventSequenceID
        nativeSwitcherSyncTask = Task { @MainActor [weak self] in
            // Dock publishes the Process Switcher AX hierarchy after it has
            // consumed the same key event. Use a short bounded retry rather
            // than blocking the event-tap callback or polling continuously.
            var sawAmbiguousSelection = false
            for delay in [12_000_000, 24_000_000, 48_000_000, 80_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.commandSequenceActive,
                      self.eventSequenceID == sequenceID else { return }
                switch self.nativeSwitcher.snapshot() {
                case let .visible(snapshot):
                    self.applyNativeSwitcherSnapshot(snapshot)
                    self.nativeSwitcherSyncTask = nil
                    return
                case .notVisible:
                    continue
                case .ambiguous:
                    sawAmbiguousSelection = true
                    continue
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.commandSequenceActive,
                  self.eventSequenceID == sequenceID else { return }
            self.nativeSwitcherSyncTask = nil
            // Fail open: the system switcher already received every base key.
            // If its AX representation is unavailable, show no custom UI.
            self.logger.debug(
                "Native Process Switcher preview unavailable; ambiguousSelection=\(sawAmbiguousSelection, privacy: .public)"
            )
            self.overlay.hide()
            self.isPresenting = false
            self.candidates.removeAll(keepingCapacity: false)
        }
    }

    private func applyNativeSwitcherSnapshot(
        _ snapshot: NativeProcessSwitcherBridge.Snapshot
    ) {
        let applications = snapshot.applications.filter {
            !$0.isTerminated
                && !preferences.isExcluded($0)
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard !applications.isEmpty,
              applications.count == snapshot.applications.count else {
            overlay.hide()
            isPresenting = false
            candidates.removeAll(keepingCapacity: false)
            return
        }
        let processIdentifiers = applications.map(\.processIdentifier).sorted()
        let didChangeApplication = candidates.first?.processIdentifiers != processIdentifiers
        let nextAnchorFrame = snapshot.selectedItemFrame ?? snapshot.listFrame
        let didChangeAnchor = nativeSwitcherAnchorFrame != nextAnchorFrame
        if !didChangeApplication,
           !didChangeAnchor,
           isPresenting {
            return
        }
        let windows = didChangeApplication
            ? windowCandidates(for: applications)
            : (candidates.first?.windows ?? windowCandidates(for: applications))
        candidates = [Candidate(applications: applications, windows: windows)]
        selectedIndex = 0
        nativeSwitcherAnchorFrame = nextAnchorFrame
        if didChangeApplication {
            selectedWindowIndex = 0
            hasExplicitWindowSelection = false
            currentThumbnailResults.removeAll(keepingCapacity: false)
        }
        isPresenting = true
        if didChangeApplication {
            renderOverlay()
        } else {
            presentOverlay(thumbnails: currentThumbnailResults, for: selectedIndex)
        }
    }

    private func scheduleNativePointerSync() {
        guard commandSequenceActive,
              preferences.isEnabled,
              preferences.cmdTabPlusEnabled,
              nativePointerSyncWorkItem == nil else { return }
        let sequenceID = eventSequenceID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.nativePointerSyncWorkItem = nil
            guard self.commandSequenceActive,
                  self.eventSequenceID == sequenceID else { return }
            // Dock does not update AXSelected/AXFocused when the pointer merely
            // hovers a native Cmd-Tab tile. Query the actual global pointer and
            // hit-test Dock's Process Switcher instead of re-reading the
            // keyboard selection. This stays coalesced by the existing 45ms
            // work item and does not add polling.
            guard let pointer = self.pendingNativePointerLocation
                    ?? CGEvent(source: nil)?.location else { return }
            self.pendingNativePointerLocation = nil
            if case let .visible(snapshot) = self.nativeSwitcher.snapshot(at: pointer) {
                self.applyNativeSwitcherSnapshot(snapshot)
            }
        }
        nativePointerSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: workItem)
    }

    /// Observe native switcher pointer movement independently of the custom
    /// preview panel. The tap exists only during a Command sequence (plus a
    /// bounded paired-release drain); only clicks begun in our panel are
    /// consumed. All native AX hit-testing remains coalesced to 45 ms.
    private func installNativePointerTapIfNeeded() {
        nativePointerReleaseCleanup?.cancel()
        nativePointerReleaseCleanup = nil
        guard nativePointerEventTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let locations: [CGEventTapLocation] = [
            .cgSessionEventTap,
            .cgAnnotatedSessionEventTap
        ]
        let tap = locations.lazy.compactMap { location in
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.nativePointerEventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }.first
        guard let tap else {
            logger.error("Native Cmd-Tab pointer event tap could not be installed")
            return
        }
        nativePointerEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        nativePointerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let nativePointerEventCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<WindowCommandTabMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return MainActor.assumeIsolated {
            monitor.handleNativePointerEvent(type: type, event: event)
                ? nil : Unmanaged.passUnretained(event)
        }
    }

    private func handleNativePointerEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            overlay.clearPointerSelection()
            if let nativePointerEventTap { CGEvent.tapEnable(tap: nativePointerEventTap, enable: true) }
            return false
        }
        // Consume both halves only for a click that began in our visible
        // panel. A listen-only release used to race Dock's own selection and
        // dismiss the preview before the specific window action ran.
        if type == .leftMouseUp, nativePointerClickCaptured {
            nativePointerClickCaptured = false
            _ = overlay.handleExternalPointer(
                type: .leftMouseUp,
                at: NSEvent.mouseLocation,
                deferAction: true
            )
            if !commandSequenceActive {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.commandSequenceActive else { return }
                    self.removeNativePointerTap(force: true)
                }
            }
            return true
        }
        guard commandSequenceActive else { return false }
        if type == .leftMouseDown, overlay.containsPointer(NSEvent.mouseLocation) {
            nativePointerClickCaptured = true
            _ = overlay.handleExternalPointer(type: .leftMouseDown, at: NSEvent.mouseLocation, deferAction: true)
            return true
        }
        guard type == .mouseMoved || type == .leftMouseDragged else { return false }
        // Reuse the event source already proven to work while Command is held.
        // If the pointer is inside SuperIsland's concrete-window panel, select
        // that exact window and do not reinterpret the same point as a native
        // Dock application tile.
        if overlay.handleExternalPointer(
            type: type == .leftMouseDragged ? .leftMouseDragged : .mouseMoved,
            at: NSEvent.mouseLocation,
            deferAction: true
        ) {
            pendingNativePointerLocation = nil
            return nativePointerClickCaptured
        }
        pendingNativePointerLocation = event.location
        if !loggedNativePointerActivity {
            loggedNativePointerActivity = true
            logger.debug("Observed pointer activity during native Cmd-Tab sequence")
        }
        scheduleNativePointerSync()
        return nativePointerClickCaptured
    }

    private func removeNativePointerTap(force: Bool = false) {
        if nativePointerClickCaptured, !force {
            // Command can be released while the mouse is still down. Retain
            // the paired-up consumer until the physical release. The watchdog
            // only runs during that held gesture and removes a lost-up tap
            // once the button is no longer down; a long press must not leak
            // its release into Dock or a different foreground window.
            nativePointerReleaseCleanup?.cancel()
            let cleanup = DispatchWorkItem { [weak self] in
                guard let self, !self.commandSequenceActive else { return }
                self.removeNativePointerTap(force: !CGEventSource.buttonState(.combinedSessionState, button: .left))
            }
            nativePointerReleaseCleanup = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: cleanup)
            return
        }
        nativePointerReleaseCleanup?.cancel()
        nativePointerReleaseCleanup = nil
        nativePointerClickCaptured = false
        if let nativePointerEventTap {
            CGEvent.tapEnable(tap: nativePointerEventTap, enable: false)
        }
        if let nativePointerRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                nativePointerRunLoopSource,
                .commonModes
            )
        }
        nativePointerRunLoopSource = nil
        nativePointerEventTap = nil
        pendingNativePointerLocation = nil
        loggedNativePointerActivity = false
    }

    private func moveWindowSelection(reverse: Bool) {
        guard isPresenting,
              candidates.indices.contains(selectedIndex),
              !candidates[selectedIndex].windows.isEmpty else { return }
        let windowCount = candidates[selectedIndex].windows.count
        let delta = reverse ? -1 : 1
        overlay.clearPointerSelection()
        selectedWindowIndex = (selectedWindowIndex + delta + windowCount) % windowCount
        hasExplicitWindowSelection = true
        presentOverlay(thumbnails: currentThumbnailResults, for: selectedIndex)
    }

    private func selectWindow(index: Int) {
        guard isPresenting,
              candidates.indices.contains(selectedIndex),
              candidates[selectedIndex].windows.indices.contains(index) else { return }
        overlay.clearPointerSelection()
        selectedWindowIndex = index
        hasExplicitWindowSelection = true
        presentOverlay(thumbnails: currentThumbnailResults, for: selectedIndex)
    }

    private func renderOverlay() {
        guard isPresenting, candidates.indices.contains(selectedIndex) else { return }
        selectedApplicationRefreshTask?.cancel()
        selectedApplicationRefreshTask = nil
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCaptureGeneration &+= 1

        currentThumbnailResults = []
        previewOnlyWindows = []
        previewLoading = true
        // Do not render AX placeholders while the WindowServer/ScreenCapture
        // proof is still pending. A stale helper proxy must never flash as a
        // real selectable window, even briefly.
        overlay.hide()
        // Show one explicit loading state, never fake selectable window cards.
        // AX-less helpers must not leave Cmd-Tab with no feedback at all.
        presentOverlay(thumbnails: [], for: selectedIndex)

        let selectedWindows = candidates[selectedIndex].windows
        guard !selectedWindows.isEmpty else {
            scheduleSelectedApplicationWindowRefresh()
            return
        }
        let candidate = candidates[selectedIndex]
        var batchIndexByPID: [pid_t: Int] = [:]
        var batches: [ThumbnailCaptureBatch] = []
        var titleOccurrencesByPID: [pid_t: [String: Int]] = [:]
        var unavailableThumbnailIndexes: [Int] = []
        for (index, window) in selectedWindows.enumerated() {
            let processIdentifier = window.application.processIdentifier
            var titleOccurrences = titleOccurrencesByPID[processIdentifier] ?? [:]
            let occurrence = titleOccurrences[window.title, default: 0]
            titleOccurrences[window.title] = occurrence + 1
            titleOccurrencesByPID[processIdentifier] = titleOccurrences
            guard let applicationIdentity = WindowThumbnailApplicationIdentity(
                application: window.application
            ) else {
                unavailableThumbnailIndexes.append(index)
                continue
            }
            let indexedRequest = IndexedThumbnailRequest(
                index: index,
                request: WindowThumbnailRequest(
                    title: window.title,
                    occurrence: occurrence,
                    bounds: window.bounds,
                    windowID: window.windowID,
                    allowsUniformContent: window.allowsUniformContent
                )
            )
            if let batchIndex = batchIndexByPID[processIdentifier] {
                let existing = batches[batchIndex]
                batches[batchIndex] = ThumbnailCaptureBatch(
                    applicationIdentity: existing.applicationIdentity,
                    requests: existing.requests + [indexedRequest]
                )
            } else {
                batchIndexByPID[processIdentifier] = batches.count
                batches.append(ThumbnailCaptureBatch(
                    applicationIdentity: applicationIdentity,
                    requests: [indexedRequest]
                ))
            }
        }
        guard !batches.isEmpty else {
            previewLoading = false
            currentThumbnailResults = [WindowThumbnailResult?](
                repeating: .notEnumerated,
                count: selectedWindows.count
            )
            presentOverlay(
                thumbnails: currentThumbnailResults,
                for: selectedIndex
            )
            return
        }
        let captureIndex = selectedIndex
        let captureProcessIdentifiers = candidate.processIdentifiers
        let captureApplicationIdentities = batches
            .map(\.applicationIdentity)
            .sorted { $0.processIdentifier < $1.processIdentifier }
        let sequenceID = eventSequenceID
        let captureGeneration = thumbnailCaptureGeneration
        let thumbnailCount = selectedWindows.count

        thumbnailCaptureTask = Task.detached(priority: .userInitiated) {
            var thumbnails = [WindowThumbnailResult?](
                repeating: nil,
                count: thumbnailCount
            )
            for index in unavailableThumbnailIndexes {
                thumbnails[index] = .notEnumerated
            }
            // Multiple processes can legitimately represent the same Dock App
            // identity. Capture one process at a time to keep ScreenCaptureKit
            // work bounded, then restore the aggregate window order.
            for batch in batches {
                guard !Task.isCancelled else { return }
                let results = await WindowThumbnailProvider.captureWindows(
                    applicationIdentity: batch.applicationIdentity,
                    requests: batch.requests.map(\.request)
                )
                for (indexedRequest, result) in zip(batch.requests, results) {
                    thumbnails[indexedRequest.index] = result
                }
            }
            guard !Task.isCancelled else { return }
            let completedThumbnails = thumbnails
            await MainActor.run { [weak self] in
                guard let self,
                      self.isPresenting,
                      self.eventSequenceID == sequenceID,
                      self.selectedIndex == captureIndex,
                      self.candidates.indices.contains(captureIndex),
                      self.candidates[captureIndex].processIdentifiers
                        == captureProcessIdentifiers,
                      self.thumbnailApplicationIdentities(
                        for: self.candidates[captureIndex]
                      ) == captureApplicationIdentities,
                      self.thumbnailCaptureGeneration == captureGeneration else { return }
                let (validatedWindows, validatedThumbnails) = self
                    .removingStaleUncorroboratedWindows(
                        from: self.candidates[captureIndex].windows,
                        thumbnails: completedThumbnails
                    )
                self.candidates[captureIndex] = Candidate(
                    applications: self.candidates[captureIndex].applications,
                    windows: validatedWindows
                )
                self.selectedWindowIndex = min(
                    self.selectedWindowIndex,
                    max(0, validatedWindows.count - 1)
                )
                self.currentThumbnailResults = validatedThumbnails
                self.previewLoading = false
                self.presentOverlay(
                    thumbnails: self.currentThumbnailResults,
                    for: captureIndex
                )
                self.thumbnailCaptureTask = nil
            }
        }
    }

    private func removingStaleUncorroboratedWindows(
        from windows: [WindowCandidate],
        thumbnails: [WindowThumbnailResult?]
    ) -> ([WindowCandidate], [WindowThumbnailResult?]) {
        guard windows.count == thumbnails.count else {
            return (windows, thumbnails)
        }
        var validatedWindows: [WindowCandidate] = []
        var validatedThumbnails: [WindowThumbnailResult?] = []
        for (window, thumbnail) in zip(windows, thumbnails) {
            guard thumbnail?.isEligibleForWindowCard == true else { continue }
            validatedWindows.append(window)
            validatedThumbnails.append(thumbnail)
        }
        return (validatedWindows, validatedThumbnails)
    }

    /// AXFocusedWindow/AXMainWindow/AXWindows can all be transiently empty
    /// while an App or Space is activating. Refresh only the selected App with
    /// a small bounded retry; never re-enumerate every desktop App or start
    /// screenshot work until real windows are available.
    private func scheduleSelectedApplicationWindowRefresh() {
        guard isPresenting,
              candidates.indices.contains(selectedIndex) else { return }
        let applicationIndex = selectedIndex
        let candidate = candidates[applicationIndex]
        let processIdentifiers = candidate.processIdentifiers
        let sequenceID = eventSequenceID
        let applicationIdentities = thumbnailApplicationIdentities(
            for: candidate.applications
        )
        guard applicationIdentities.count == candidate.applications.count else {
            previewLoading = false
            presentOverlay(thumbnails: [], for: applicationIndex)
            return
        }

        selectedApplicationRefreshTask = Task { @MainActor [weak self] in
            for delay in [60_000_000, 120_000_000, 220_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.isPresenting,
                      self.eventSequenceID == sequenceID,
                      self.selectedIndex == applicationIndex,
                      self.candidates.indices.contains(applicationIndex),
                      self.candidates[applicationIndex].processIdentifiers
                        == processIdentifiers else { return }

                let currentApplications = processIdentifiers.compactMap {
                    NSRunningApplication(processIdentifier: $0)
                }.filter { !$0.isTerminated }
                guard currentApplications.count == processIdentifiers.count,
                      self.thumbnailApplicationIdentities(
                        for: currentApplications
                      ) == applicationIdentities else { return }

                let refreshedWindows = self.windowCandidates(for: currentApplications)
                guard !refreshedWindows.isEmpty else { continue }
                self.candidates[applicationIndex] = Candidate(
                    applications: currentApplications,
                    windows: refreshedWindows
                )
                self.selectedWindowIndex = 0
                self.selectedApplicationRefreshTask = nil
                self.renderOverlay()
                return
            }
            self?.selectedApplicationRefreshTask = nil
            self?.discoverPreviewOnlyWindows()
        }
    }

    private func discoverPreviewOnlyWindows() {
        guard isPresenting, candidates.indices.contains(selectedIndex),
              candidates[selectedIndex].windows.isEmpty else { return }
        let index = selectedIndex
        let sequence = eventSequenceID
        let generation = thumbnailCaptureGeneration
        let identities = thumbnailApplicationIdentities(for: candidates[index].applications)
        thumbnailCaptureTask = Task { @MainActor [weak self] in
            var discovered: [(
                identity: WindowThumbnailApplicationIdentity,
                window: WindowThumbnailDiscoveredWindow
            )] = []
            for identity in identities {
                guard !Task.isCancelled else { return }
                let result = await WindowThumbnailProvider.discoverAndCaptureWindows(applicationIdentity: identity)
                if case let .windows(windows) = result {
                    discovered.append(contentsOf: windows.map { (identity, $0) })
                }
            }
            let selectedDiscovery = WindowPreviewOnlySelectionPolicy.selectOne(
                from: discovered.map(\.window)
            )
            let selected = selectedDiscovery.flatMap { selected in
                discovered.first { candidate in
                    candidate.window.request.windowID == selected.request.windowID
                        && candidate.window.request.title == selected.request.title
                        && candidate.window.request.bounds == selected.request.bounds
                }
            }
            let items: [CommandTabWindowDisplayItem]
            if let selected,
               let windowID = selected.window.request.windowID {
                let rawTitle = selected.window.request.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                items = [CommandTabWindowDisplayItem(
                    id: 0,
                    identity: WindowPreviewIdentity(
                        processID: selected.identity.processIdentifier,
                        windowID: windowID
                    ),
                    title: rawTitle.isEmpty ? "应用预览" : rawTitle,
                    isMinimized: false,
                    canClose: false,
                    isSelected: false,
                    thumbnailResult: selected.window.result,
                    canActivate: false
                )]
            } else {
                items = []
            }
            guard let self, !Task.isCancelled, self.isPresenting,
                  self.eventSequenceID == sequence,
                  self.thumbnailCaptureGeneration == generation,
                  self.selectedIndex == index,
                  self.candidates.indices.contains(index),
                  self.thumbnailApplicationIdentities(for: self.candidates[index].applications) == identities,
                  identities.allSatisfy({ $0.matchesCurrentProcess() }) else { return }
            self.previewOnlyWindows = items
            self.previewLoading = false
            self.thumbnailCaptureTask = nil
            self.presentOverlay(thumbnails: [], for: index)
        }
    }

    private func presentOverlay(
        thumbnails: [WindowThumbnailResult?],
        for presentedIndex: Int
    ) {
        guard isPresenting,
              selectedIndex == presentedIndex,
              candidates.indices.contains(presentedIndex),
              let nativeSwitcherAnchorFrame else { return }
        let items = candidates.enumerated().map { index, candidate in
            CommandTabDisplayItem(
                id: index,
                appName: candidate.application.localizedName ?? "App",
                icon: candidate.application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                isLoading: previewLoading,
                windows: previewLoading ? [] : candidate.windows.isEmpty ? previewOnlyWindows : candidate.windows.enumerated().map { windowIndex, window in
                    CommandTabWindowDisplayItem(
                        id: windowIndex,
                        identity: WindowPreviewIdentity(processID: window.application.processIdentifier, windowID: window.windowID ?? 0),
                        title: window.title,
                        isMinimized: window.isMinimized,
                        canClose: window.canClose,
                        isSelected: index == presentedIndex && windowIndex == selectedWindowIndex,
                        thumbnailResult: index == presentedIndex && thumbnails.indices.contains(windowIndex)
                            ? thumbnails[windowIndex]
                            : nil
                    )
                }
            )
        }
        let sequence = eventSequenceID
        overlay.showNativePreview(
            items: items,
            selectedIndex: selectedIndex,
            anchorAXFrame: nativeSwitcherAnchorFrame,
            onCommitWindow: { [weak self] applicationIndex, windowIndex in
                guard let self, self.eventSequenceID == sequence else { return }
                self.logger.debug(
                    "Mouse committed Cmd-Tab window appIndex=\(applicationIndex, privacy: .public) windowIndex=\(windowIndex, privacy: .public)"
                )
                self.enqueueEventAction(.commitWindow(
                    applicationIndex: applicationIndex,
                    windowIndex: windowIndex,
                    sequenceID: sequence
                ))
            },
            onHoverWindow: { [weak self] applicationIndex, windowIndex in
                guard self?.eventSequenceID == sequence else { return }
                self?.logger.debug(
                    "Mouse hovered Cmd-Tab window appIndex=\(applicationIndex, privacy: .public) windowIndex=\(windowIndex, privacy: .public)"
                )
                self?.selectWindow(applicationIndex: applicationIndex, windowIndex: windowIndex)
            },
            onCloseWindow: { [weak self] applicationIndex, windowIndex in
                guard let self, self.eventSequenceID == sequence else { return }
                self.enqueueEventAction(.closeWindow(
                    applicationIndex: applicationIndex,
                    windowIndex: windowIndex,
                    sequenceID: sequence
                ))
            }
        )
    }

    private func selectWindow(applicationIndex: Int, windowIndex: Int) {
        guard isPresenting,
              selectedIndex == applicationIndex,
              candidates.indices.contains(applicationIndex),
              candidates[applicationIndex].windows.indices.contains(windowIndex) else { return }
        hasExplicitWindowSelection = true
        guard selectedWindowIndex != windowIndex else { return }
        selectedWindowIndex = windowIndex
        presentOverlay(thumbnails: currentThumbnailResults, for: applicationIndex)
    }

    private func commit(applicationIndex: Int, windowIndex: Int) {
        guard isPresenting,
              candidates.indices.contains(applicationIndex),
              candidates[applicationIndex].windows.indices.contains(windowIndex) else { return }
        selectedIndex = applicationIndex
        selectedWindowIndex = windowIndex
        activate(
            candidate: candidates[applicationIndex],
            window: candidates[applicationIndex].windows[windowIndex]
        )
    }

    private func closeSelectedWindow() {
        guard isPresenting, candidates.indices.contains(selectedIndex) else { return }
        let windowIndex = candidates[selectedIndex].windows.indices.contains(selectedWindowIndex)
            ? selectedWindowIndex
            : 0
        closeWindow(applicationIndex: selectedIndex, windowIndex: windowIndex)
    }

    private func closeWindow(applicationIndex: Int, windowIndex: Int) {
        guard isPresenting,
              candidates.indices.contains(applicationIndex),
              candidates[applicationIndex].windows.indices.contains(windowIndex) else {
            preferences.publishFeedback("当前预览没有可关闭的窗口")
            return
        }
        let candidate = candidates[applicationIndex]
        let window = candidate.windows[windowIndex]
        guard let applicationIdentity = WindowThumbnailApplicationIdentity(
            application: window.application
        ) else {
            preferences.publishFeedback("当前预览 App 状态已变化，请重新选择")
            return
        }
        closeWindowRetryTask?.cancel()
        closeWindowRetryTask = nil
        attemptCloseWindow(
            applicationIndex: applicationIndex,
            expectedApplicationIdentity: applicationIdentity,
            expectedWindow: window,
            remainingRetries: 1,
            sequenceID: eventSequenceID
        )
    }

    private func attemptCloseWindow(
        applicationIndex: Int,
        expectedApplicationIdentity: WindowThumbnailApplicationIdentity,
        expectedWindow: WindowCandidate,
        remainingRetries: Int,
        sequenceID: Int
    ) {
        guard isPresenting,
              eventSequenceID == sequenceID,
              candidates.indices.contains(applicationIndex) else { return }
        let candidate = candidates[applicationIndex]
        guard candidate.applications.contains(where: {
            $0.processIdentifier == expectedWindow.application.processIdentifier
        }),
              WindowThumbnailApplicationIdentity(
                application: expectedWindow.application
              ) == expectedApplicationIdentity,
              let currentWindow = freshWindow(
                  matching: expectedWindow,
                  application: expectedWindow.application
              ) else {
            preferences.publishFeedback("当前预览窗口状态已变化，请重新选择")
            return
        }
        guard currentWindow.canClose,
              let closeButton = elementAttribute(
                  kAXCloseButtonAttribute,
                  of: currentWindow.element
              ) else {
            preferences.publishFeedback("当前预览窗口没有可用的关闭按钮")
            return
        }

        let result = AXUIElementPerformAction(
            closeButton,
            kAXPressAction as CFString
        )
        if result == .success {
            finishClosingWindow(
                applicationIndex: applicationIndex,
                expectedApplicationIdentity: expectedApplicationIdentity,
                closedWindow: currentWindow
            )
            return
        }

        if result == .cannotComplete, remainingRetries > 0 {
            closeWindowRetryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 60_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.closeWindowRetryTask = nil
                self.attemptCloseWindow(
                    applicationIndex: applicationIndex,
                    expectedApplicationIdentity: expectedApplicationIdentity,
                    expectedWindow: expectedWindow,
                    remainingRetries: remainingRetries - 1,
                    sequenceID: sequenceID
                )
            }
            return
        }

        logger.error(
            "Failed to close selected preview window after fresh resolution: AX error \(result.rawValue, privacy: .public)"
        )
        preferences.publishFeedback("关闭预览窗口失败")
    }

    private func finishClosingWindow(
        applicationIndex: Int,
        expectedApplicationIdentity: WindowThumbnailApplicationIdentity,
        closedWindow: WindowCandidate
    ) {
        guard isPresenting,
              candidates.indices.contains(applicationIndex),
              WindowThumbnailApplicationIdentity(
                  application: closedWindow.application
              ) == expectedApplicationIdentity,
              candidates[applicationIndex].applications.contains(where: {
                $0.processIdentifier == closedWindow.application.processIdentifier
              }) else { return }
        let candidate = candidates[applicationIndex]
        let currentWindowIndex: Int? = {
            if let expectedWindowID = closedWindow.windowID {
                let matches = candidate.windows.indices.filter {
                    candidate.windows[$0].windowID == expectedWindowID
                }
                return matches.count == 1 ? matches[0] : nil
            }
            let matches = candidate.windows.indices.filter {
                CFEqual(candidate.windows[$0].element, closedWindow.element)
            }
            return matches.count == 1 ? matches[0] : nil
        }()
        guard let windowIndex = currentWindowIndex else {
            preferences.publishFeedback("窗口已关闭，预览正在刷新")
            refreshCandidatesAfterClosing(
                selectedApplicationPID: closedWindow.application.processIdentifier,
                applicationIdentity: expectedApplicationIdentity
            )
            return
        }

        let window = candidate.windows[windowIndex]
        let occurrence = candidate.windows[..<windowIndex].filter {
            $0.application.processIdentifier == window.application.processIdentifier
                && $0.title == window.title
        }.count
        WindowThumbnailProvider.clearCache(
            applicationIdentity: expectedApplicationIdentity,
            request: WindowThumbnailRequest(
                title: window.title,
                occurrence: occurrence,
                bounds: window.bounds,
                windowID: window.windowID
            )
        )

        // Remove the acknowledged window immediately so Command-W cannot be
        // repeated against the same stale AX element while the target app is
        // still processing the close action. A delayed AX refresh below then
        // reconciles apps that replace or reopen a window during close.
        var remainingWindows = candidate.windows
        remainingWindows.remove(at: windowIndex)
        candidates[applicationIndex] = Candidate(
            applications: candidate.applications,
            windows: remainingWindows
        )
        selectedIndex = applicationIndex
        selectedWindowIndex = min(windowIndex, max(0, remainingWindows.count - 1))
        // Update the visible model immediately from the thumbnails already in
        // memory, but do not start a second capture round. The bounded AX
        // reconciliation below performs the single authoritative refresh.
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCaptureGeneration &+= 1
        if currentThumbnailResults.indices.contains(windowIndex) {
            currentThumbnailResults.remove(at: windowIndex)
        }
        presentOverlay(thumbnails: currentThumbnailResults, for: applicationIndex)
        refreshCandidatesAfterClosing(
            selectedApplicationPID: closedWindow.application.processIdentifier,
            applicationIdentity: expectedApplicationIdentity
        )
    }

    private func confirmQuitSelectedApplication() {
        guard isPresenting, candidates.indices.contains(selectedIndex) else { return }
        let candidate = candidates[selectedIndex]
        let application: NSRunningApplication
        if candidate.applications.count == 1 {
            application = candidate.application
        } else if hasExplicitWindowSelection,
                  candidate.windows.indices.contains(selectedWindowIndex) {
            application = candidate.windows[selectedWindowIndex].application
        } else {
            cancel()
            preferences.publishFeedback("这个 App 有多个运行实例，请先选择具体窗口再退出")
            return
        }
        let processIdentifier = application.processIdentifier
        let applicationName = application.localizedName ?? "这个 App"
        guard let selectedApplicationIdentity = WindowThumbnailApplicationIdentity(
            application: application
        ) else {
            cancel()
            preferences.publishFeedback("所选 App 状态已变化，请重新打开 Cmd-Tab Plus")
            return
        }

        // Tear down the switcher before showing a modal confirmation. This
        // also invalidates the queued Command-release commit so Cmd-Q can never
        // fall through and activate/quit the app that was foreground before
        // the switcher opened.
        cancel()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出“\(applicationName)”？"
        alert.informativeText = "只会退出当前在 Cmd-Tab Plus 中选中的 App。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let currentApplication = NSRunningApplication(
                processIdentifier: processIdentifier
              ),
              !currentApplication.isTerminated,
              WindowThumbnailApplicationIdentity(
                application: currentApplication
              ) == selectedApplicationIdentity else { return }
        WindowThumbnailProvider.clearCache(processIdentifier: processIdentifier)
        _ = currentApplication.terminate()
    }

    private func refreshCandidatesAfterClosing(
        selectedApplicationPID: pid_t,
        applicationIdentity: WindowThumbnailApplicationIdentity?
    ) {
        postCloseRefreshTask?.cancel()
        let sequenceID = eventSequenceID
        postCloseRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.isPresenting,
                  self.eventSequenceID == sequenceID else { return }
            self.postCloseRefreshTask = nil

            // Reconcile only the App whose window was closed. Re-enumerating
            // every running App synchronously on the main actor after each
            // Command-W made repeated closes increasingly sluggish on busy
            // desktops and could reorder unrelated Cmd-Tab candidates.
            guard let applicationIndex = self.candidates.firstIndex(where: {
                $0.applications.contains(where: {
                    $0.processIdentifier == selectedApplicationPID
                })
            }) else { return }
            // A few regular Apps do not expose a stable bundle identifier, so
            // the thumbnail identity cannot be constructed for them. Keep the
            // immediately updated in-memory candidate instead of guessing that
            // the process exited and removing it from the switcher.
            guard let applicationIdentity else { return }
            let currentApplication = NSRunningApplication(
                processIdentifier: selectedApplicationPID
            )
            let validatedCurrentApplication: NSRunningApplication? = {
                guard let currentApplication,
                      !currentApplication.isTerminated,
                      WindowThumbnailApplicationIdentity(
                        application: currentApplication
                      ) == applicationIdentity else { return nil }
                return currentApplication
            }()
            let refreshedWindows: [WindowCandidate]
            if let validatedCurrentApplication {
                refreshedWindows = self.windowCandidates(
                    for: validatedCurrentApplication
                )
            } else {
                refreshedWindows = []
            }

            let candidate = self.candidates[applicationIndex]
            let firstOwnedWindowIndex = candidate.windows.firstIndex(where: {
                $0.application.processIdentifier == selectedApplicationPID
            }) ?? candidate.windows.count
            var reconciledWindows = candidate.windows.filter {
                $0.application.processIdentifier != selectedApplicationPID
            }
            reconciledWindows.insert(
                contentsOf: refreshedWindows,
                at: min(firstOwnedWindowIndex, reconciledWindows.count)
            )
            var reconciledApplications = candidate.applications.filter {
                $0.processIdentifier != selectedApplicationPID
            }
            if let validatedCurrentApplication {
                reconciledApplications.append(validatedCurrentApplication)
                reconciledApplications.sort {
                    $0.processIdentifier < $1.processIdentifier
                }
            }
            guard !reconciledApplications.isEmpty else {
                self.cancel()
                return
            }
            self.candidates[applicationIndex] = Candidate(
                applications: reconciledApplications,
                windows: reconciledWindows
            )
            self.selectedIndex = applicationIndex
            let windowCount = self.candidates[self.selectedIndex].windows.count
            self.selectedWindowIndex = min(self.selectedWindowIndex, max(0, windowCount - 1))
            self.renderOverlay()
        }
    }

    private func activate(candidate: Candidate, window: WindowCandidate?) {
        concreteWindowActivationTask?.cancel()
        concreteWindowActivationTask = nil
        let application = window?.application ?? candidate.application
        let processIdentifier = application.processIdentifier
        let applicationIdentity = WindowThumbnailApplicationIdentity(
            application: application
        )
        if let windowID = window?.windowID {
            WindowServerPrivateBridge.activate(
                processIdentifier: processIdentifier,
                windowID: windowID
            )
        }
        _ = application.activate(options: [])
        if let window,
           let currentWindow = freshWindow(
                matching: window,
                application: application
           ) {
            _ = focusExactWindow(
                currentWindow,
                application: application,
                expectedWindowID: currentWindow.windowID
            )
        }
        cancel()

        guard let window, let applicationIdentity else { return }
        // App activation can restore its previous main window after the first
        // AXFocusedWindow write. Re-assert the exact selected AX window for a
        // short bounded period, but stop immediately if the user has already
        // moved to another App.
        concreteWindowActivationTask = Task { @MainActor [weak self] in
            for delay in [80_000_000, 140_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      let currentApplication = NSRunningApplication(
                        processIdentifier: processIdentifier
                      ),
                      !currentApplication.isTerminated,
                      currentApplication.isActive,
                      WindowThumbnailApplicationIdentity(
                        application: currentApplication
                      ) == applicationIdentity else { return }
                guard let currentWindow = self.freshWindow(
                    matching: window,
                    application: currentApplication
                ) else { return }
                _ = self.focusExactWindow(
                    currentWindow,
                    application: currentApplication,
                    expectedWindowID: currentWindow.windowID
                )
            }
            self?.concreteWindowActivationTask = nil
        }
    }

    private func focusAfterNativeCommit(
        candidate: Candidate,
        window: WindowCandidate
    ) {
        concreteWindowActivationTask?.cancel()
        concreteWindowActivationTask = nil
        let application = window.application
        let processIdentifier = application.processIdentifier
        guard let applicationIdentity = WindowThumbnailApplicationIdentity(
            application: application
        ) else { return }
        concreteWindowActivationTask = Task { @MainActor [weak self] in
            for delay in [45_000_000, 90_000_000, 160_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      let currentApplication = NSRunningApplication(
                        processIdentifier: processIdentifier
                      ),
                      !currentApplication.isTerminated,
                      WindowThumbnailApplicationIdentity(
                        application: currentApplication
                      ) == applicationIdentity else { return }
                // The native switcher owns App activation. Never steal focus
                // before it has committed the same application.
                guard currentApplication.isActive else { continue }
                guard let currentWindow = self.freshWindow(
                    matching: window,
                    application: currentApplication
                ) else { return }
                if self.focusExactWindow(
                    currentWindow,
                    application: currentApplication,
                    expectedWindowID: currentWindow.windowID
                ) {
                    self.concreteWindowActivationTask = nil
                    return
                }
            }
            self?.concreteWindowActivationTask = nil
        }
    }

    private func freshWindow(
        matching original: WindowCandidate,
        application: NSRunningApplication
    ) -> WindowCandidate? {
        let currentWindows = windowCandidates(for: application)
        if let expectedWindowID = original.windowID {
            let matches = currentWindows.filter { $0.windowID == expectedWindowID }
            return matches.count == 1 ? matches[0] : nil
        }
        let retainedMatches = currentWindows.filter { CFEqual($0.element, original.element) }
        return retainedMatches.count == 1 ? retainedMatches[0] : nil
    }

    @discardableResult
    private func focusExactWindow(
        _ window: WindowCandidate,
        application: NSRunningApplication,
        expectedWindowID: CGWindowID?
    ) -> Bool {
        var ownerPID: pid_t = 0
        guard !application.isTerminated,
              AXUIElementGetPid(window.element, &ownerPID) == .success,
              ownerPID == application.processIdentifier else { return false }
        if let expectedWindowID,
           windowIDAttribute(window.element) != expectedWindowID {
            return false
        }
        if boolAttribute(kAXMinimizedAttribute, of: window.element) == true {
            AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        let applicationElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        let focusResult = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            window.element
        )
        AXUIElementSetAttributeValue(
            window.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let raiseResult = AXUIElementPerformAction(
            window.element,
            kAXRaiseAction as CFString
        )
        guard focusResult == .success, raiseResult == .success,
              let focusedWindow = elementAttribute(
                kAXFocusedWindowAttribute,
                of: applicationElement
              ) else { return false }
        return CFEqual(focusedWindow, window.element)
    }

    private func cancel() {
        cancelQueuedEventActions()
        nativeSwitcherSyncTask?.cancel()
        nativeSwitcherSyncTask = nil
        nativePointerSyncWorkItem?.cancel()
        nativePointerSyncWorkItem = nil
        removeNativePointerTap()
        nativeSwitcher.reset()
        postCloseRefreshTask?.cancel()
        postCloseRefreshTask = nil
        closeWindowRetryTask?.cancel()
        closeWindowRetryTask = nil
        selectedApplicationRefreshTask?.cancel()
        selectedApplicationRefreshTask = nil
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCaptureGeneration &+= 1
        commandSequenceActive = false
        hasExplicitWindowSelection = false
        nativeSwitcherAnchorFrame = nil
        eventSequenceID &+= 1
        isPresenting = false
        candidates.removeAll()
        selectedWindowIndex = 0
        currentThumbnailResults.removeAll()
        overlay.hide()
    }

    /// Some applications omit a fullscreen window from AXWindows while its
    /// Space is inactive but continue exposing it as focused or main. Merge all
    /// three public AX sources, then collapse distinct proxies only when their
    /// exact WindowServer identity proves that they represent the same window.
    private func windowCandidates(
        for applications: [NSRunningApplication]
    ) -> [WindowCandidate] {
        var result: [WindowCandidate] = []
        var indexByWindowID: [CGWindowID: Int] = [:]
        for application in applications where !application.isTerminated {
            for candidate in windowCandidates(for: application) {
                guard let windowID = candidate.windowID else {
                    if !result.contains(where: {
                        $0.application.processIdentifier
                            == candidate.application.processIdentifier
                            && $0.windowID == nil
                            && CFEqual($0.element, candidate.element)
                    }) {
                        result.append(candidate)
                    }
                    continue
                }
                if let existingIndex = indexByWindowID[windowID] {
                    if windowCandidateQuality(candidate)
                        > windowCandidateQuality(result[existingIndex]) {
                        result[existingIndex] = candidate
                    }
                } else {
                    indexByWindowID[windowID] = result.count
                    result.append(candidate)
                }
            }
        }
        return result
    }

    private func windowCandidates(
        for application: NSRunningApplication
    ) -> [WindowCandidate] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, of: appElement)
        let mainWindow = elementAttribute(kAXMainWindowAttribute, of: appElement)
        var collectedWindows: [AXUIElement] = []
        for preferredWindow in [focusedWindow, mainWindow].compactMap({ $0 })
        where !collectedWindows.contains(where: { CFEqual($0, preferredWindow) }) {
            collectedWindows.append(preferredWindow)
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
           let availableWindows = windowsValue as? [AXUIElement] {
            for window in availableWindows
            where !collectedWindows.contains(where: { CFEqual($0, window) }) {
                collectedWindows.append(window)
            }
        }

        let resolvedCandidates = collectedWindows.compactMap { window -> WindowCandidate? in
            var ownerPID: pid_t = 0
            let role = stringAttribute(kAXRoleAttribute, of: window) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, of: window) ?? ""
            guard AXUIElementGetPid(window, &ownerPID) == .success,
                  ownerPID == application.processIdentifier else {
                return nil
            }
            let title = (stringAttribute(kAXTitleAttribute, of: window) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isMinimized = boolAttribute(
                kAXMinimizedAttribute,
                of: window
            ) ?? false
            let isPreferredWindow = [focusedWindow, mainWindow]
                .compactMap { $0 }
                .contains { CFEqual($0, window) }
            let isExplicitlyHidden = boolAttribute(
                kAXHiddenAttribute,
                of: window
            ) == true
            let isExplicitlyInvisible = boolAttribute(
                "AXVisible",
                of: window
            ) == false
            // Electron Apps can publish background standard-window shells.
            // Preserve a real focused/main or minimized untitled window, but
            // reject an otherwise hidden/invisible or untitled background
            // shell before it becomes an unavailable preview card.
            guard WindowAXCandidatePolicy.shouldInclude(
                role: role,
                subrole: subrole,
                isModal: boolAttribute("AXModal", of: window),
                title: title,
                isMinimized: isMinimized,
                isPreferredWindow: isPreferredWindow,
                isHidden: isExplicitlyHidden,
                isVisible: isExplicitlyInvisible ? false : nil
            ) else { return nil }
            return WindowCandidate(
                application: application,
                element: window,
                title: title,
                bounds: windowBounds(window),
                windowID: windowIDAttribute(window),
                isMinimized: isMinimized,
                isPreferredWindow: isPreferredWindow,
                canClose: elementAttribute(kAXCloseButtonAttribute, of: window) != nil,
                allowsUniformContent: WindowPreviewCaptureEvidence.allowsUniformContent(of: window)
            )
        }

        // AXFocusedWindow, AXMainWindow and AXWindows may vend distinct AX
        // proxy objects for the same underlying Chrome window. Prefer an exact
        // WindowServer ID; when one proxy has no ID, merge only an exact
        // same-PID/title/minimized-state/geometry match. Keep the richest proxy
        // so title, geometry and close behavior are not lost.
        var deduplicated: [WindowCandidate] = []
        var indexByWindowID: [CGWindowID: Int] = [:]
        for candidate in resolvedCandidates {
            guard let windowID = candidate.windowID else {
                if let proxyIndex = deduplicated.firstIndex(where: {
                    $0.windowID != nil
                        && windowCandidatesAreExactProxies($0, candidate)
                }) {
                    deduplicated[proxyIndex] = mergedWindowCandidate(
                        existing: deduplicated[proxyIndex],
                        candidate: candidate,
                        canonicalWindowID: deduplicated[proxyIndex].windowID
                    )
                    continue
                }
                if !deduplicated.contains(where: {
                    $0.windowID == nil && CFEqual($0.element, candidate.element)
                }) {
                    deduplicated.append(candidate)
                }
                continue
            }
            if let proxyIndex = deduplicated.firstIndex(where: {
                $0.windowID == nil
                    && windowCandidatesAreExactProxies($0, candidate)
            }) {
                deduplicated[proxyIndex] = mergedWindowCandidate(
                    existing: deduplicated[proxyIndex],
                    candidate: candidate,
                    canonicalWindowID: windowID
                )
                indexByWindowID[windowID] = proxyIndex
                continue
            }
            if let existingIndex = indexByWindowID[windowID] {
                deduplicated[existingIndex] = mergedWindowCandidate(
                    existing: deduplicated[existingIndex],
                    candidate: candidate,
                    canonicalWindowID: windowID
                )
            } else {
                indexByWindowID[windowID] = deduplicated.count
                deduplicated.append(candidate)
            }
        }
        let snapshot = WindowServerInventoryService.shared.snapshot(
            for: [application.processIdentifier]
        )
        let reconciliation = WindowInventoryReconciler.reconcile(
            candidates: deduplicated.enumerated().map { index, candidate in
                WindowInventoryCandidate(
                    token: index,
                    ownerPID: application.processIdentifier,
                    windowID: candidate.windowID,
                    title: candidate.title,
                    bounds: candidate.bounds,
                    isMinimized: candidate.isMinimized,
                    isPreferredWindow: candidate.isPreferredWindow
                )
            },
            snapshot: snapshot
        )
        logger.debug(
            "Cmd-Tab inventory pid=\(application.processIdentifier, privacy: .public) mode=\(snapshot.mode.rawValue, privacy: .public) ax=\(resolvedCandidates.count, privacy: .public) proxies=\(deduplicated.count, privacy: .public) matched=\(reconciliation.matches.count, privacy: .public) rejected=\(reconciliation.rejections.count, privacy: .public)"
        )
        let canonicalWindowIDByIndex = Dictionary(
            uniqueKeysWithValues: reconciliation.matches.map {
                ($0.token, $0.windowID)
            }
        )
        return deduplicated.enumerated().compactMap { index, candidate in
            guard let canonicalWindowID = canonicalWindowIDByIndex[index] else {
                return nil
            }
            return WindowCandidate(
                application: candidate.application,
                element: candidate.element,
                title: candidate.title,
                bounds: candidate.bounds,
                windowID: canonicalWindowID,
                isMinimized: candidate.isMinimized,
                isPreferredWindow: candidate.isPreferredWindow,
                canClose: candidate.canClose,
                allowsUniformContent: candidate.allowsUniformContent
            )
        }
    }

    private func windowCandidatesAreExactProxies(
        _ lhs: WindowCandidate,
        _ rhs: WindowCandidate
    ) -> Bool {
        WindowAXCandidatePolicy.areExactProxies(
            lhsPID: lhs.application.processIdentifier,
            lhsTitle: lhs.title,
            lhsBounds: lhs.bounds,
            lhsIsMinimized: lhs.isMinimized,
            rhsPID: rhs.application.processIdentifier,
            rhsTitle: rhs.title,
            rhsBounds: rhs.bounds,
            rhsIsMinimized: rhs.isMinimized
        )
    }

    private func mergedWindowCandidate(
        existing: WindowCandidate,
        candidate: WindowCandidate,
        canonicalWindowID: CGWindowID?
    ) -> WindowCandidate {
        let useCandidate = WindowAXOperationProxyPolicy.prefersCandidate(
            existing: proxyEvidence(for: existing),
            candidate: proxyEvidence(for: candidate)
        )
        let operationProxy = useCandidate ? candidate : existing
        let metadataProxy = !candidate.title.isEmpty ? candidate : existing
        return WindowCandidate(
            application: operationProxy.application,
            element: operationProxy.element,
            title: metadataProxy.title,
            bounds: candidate.bounds ?? existing.bounds,
            windowID: canonicalWindowID,
            isMinimized: operationProxy.isMinimized,
            isPreferredWindow: existing.isPreferredWindow || candidate.isPreferredWindow,
            canClose: operationProxy.canClose,
            allowsUniformContent: existing.allowsUniformContent
                || candidate.allowsUniformContent
        )
    }

    private func proxyEvidence(
        for candidate: WindowCandidate
    ) -> WindowAXOperationProxyEvidence {
        WindowAXOperationProxyEvidence(
            hasWindowID: candidate.windowID != nil,
            hasTitle: !candidate.title.isEmpty,
            hasBounds: candidate.bounds != nil,
            isPreferredWindow: candidate.isPreferredWindow,
            canClose: candidate.canClose,
            allowsUniformContent: candidate.allowsUniformContent
        )
    }

    private func thumbnailApplicationIdentities(
        for candidate: Candidate
    ) -> [WindowThumbnailApplicationIdentity] {
        var applicationsByPID: [pid_t: NSRunningApplication] = [:]
        for window in candidate.windows {
            applicationsByPID[window.application.processIdentifier] = window.application
        }
        return thumbnailApplicationIdentities(
            for: applicationsByPID.values.sorted {
                $0.processIdentifier < $1.processIdentifier
            }
        )
    }

    private func thumbnailApplicationIdentities(
        for applications: [NSRunningApplication]
    ) -> [WindowThumbnailApplicationIdentity] {
        applications.compactMap(WindowThumbnailApplicationIdentity.init)
            .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private func windowCandidateQuality(_ candidate: WindowCandidate) -> Int {
        var score = 0
        if !candidate.title.isEmpty { score += 4 }
        if let bounds = candidate.bounds,
           bounds.width > 1,
           bounds.height > 1 {
            score += 2
        }
        if candidate.canClose { score += 1 }
        return score
    }

    private func observeApplicationActivationIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                // Returning from System Settings is a reliable low-frequency
                // opportunity to observe a newly granted TCC permission. Do
                // not poll continuously; only retry configuration while the
                // event tap is absent.
                if self?.eventTap == nil {
                    self?.updateEnabledState()
                }
                self?.schedulePrewarm(for: application)
            }
        }
        // Do not prewarm background Apps at launch. The native switcher path
        // enumerates only its selected App, and subsequent activations refresh
        // that App opportunistically. This keeps the always-on footprint low.
    }

    private func observePreviewInvalidationIfNeeded() {
        guard previewInvalidationObserver == nil else { return }
        previewInvalidationObserver = NotificationCenter.default.addObserver(
            forName: WindowThumbnailProvider.didInvalidatePreviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPrewarmTasks()
                self?.cancel()
            }
        }
    }

    private func schedulePrewarm(for application: NSRunningApplication) {
        guard preferences.isEnabled,
              preferences.cmdTabPlusEnabled || preferences.dockPreviewEnabled,
              application.activationPolicy == .regular,
              !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(application),
              let applicationIdentity = WindowThumbnailApplicationIdentity(
                application: application
              ) else { return }
        // Prewarming protects the focused/main fullscreen preview. Capturing
        // every background tab/window here would retain a large result array
        // even though the interactive Cmd-Tab path captures all windows on
        // demand. The candidate order already prioritizes focused/main.
        let windows = Array(windowCandidates(for: application).prefix(4))
        guard !windows.isEmpty else { return }
        var titleOccurrences: [String: Int] = [:]
        let requests = windows.map { window in
            let occurrence = titleOccurrences[window.title, default: 0]
            titleOccurrences[window.title] = occurrence + 1
            return WindowThumbnailRequest(
                title: window.title,
                occurrence: occurrence,
                bounds: window.bounds,
                windowID: window.windowID,
                allowsUniformContent: window.allowsUniformContent
            )
        }
        let processIdentifier = application.processIdentifier
        let job = PrewarmJob(
            applicationIdentity: applicationIdentity,
            requests: requests
        )
        pendingPrewarmJobs[processIdentifier] = job
        if !pendingPrewarmOrder.contains(processIdentifier) {
            // New activations should prewarm before older startup seeds.
            pendingPrewarmOrder.insert(processIdentifier, at: 0)
        }
        drainPrewarmQueueIfNeeded()
    }

    private func cancelPrewarmTasks() {
        activePrewarmTask?.cancel()
        activePrewarmTask = nil
        activePrewarmPID = nil
        pendingPrewarmJobs.removeAll(keepingCapacity: false)
        pendingPrewarmOrder.removeAll(keepingCapacity: false)
    }

    private func drainPrewarmQueueIfNeeded() {
        guard activePrewarmTask == nil else { return }
        while let processIdentifier = pendingPrewarmOrder.first {
            pendingPrewarmOrder.removeFirst()
            guard let job = pendingPrewarmJobs.removeValue(
                forKey: processIdentifier
            ) else { continue }

            activePrewarmPID = processIdentifier
            activePrewarmTask = Task.detached(priority: .utility) { [weak self] in
                _ = await WindowThumbnailProvider.captureWindows(
                    applicationIdentity: job.applicationIdentity,
                    requests: job.requests
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.activePrewarmPID == processIdentifier else { return }
                    self.activePrewarmTask = nil
                    self.activePrewarmPID = nil
                    self.drainPrewarmQueueIfNeeded()
                }
            }
            return
        }
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func windowIDAttribute(_ element: AXUIElement) -> CGWindowID? {
        windowDirectWindowNumber(of: element)
    }

    private func windowBounds(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &origin),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

}

/// Read-only adapter over Dock's native Process Switcher accessibility tree.
/// `AXProcessSwitcherList` remains declared by the current macOS SDK. All
/// discovery is bounded and active only while Command is held; if the hierarchy
/// is absent or ambiguous the caller leaves native Cmd-Tab untouched.
@MainActor
private final class NativeProcessSwitcherBridge {
    private typealias ApplicationIdentityValues = (
        strings: [String],
        urls: [URL],
        processIdentifiers: [pid_t]
    )

    struct Snapshot {
        let applications: [NSRunningApplication]
        let listFrame: CGRect
        let selectedItemFrame: CGRect?

        var application: NSRunningApplication {
            applications[0]
        }
    }

    enum SnapshotResult {
        case visible(Snapshot)
        case notVisible
        case ambiguous
    }

    private let maximumTraversalDepth = 9
    private let maximumTraversalNodes = 420
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.superisland.app",
        category: "CmdTabPlus"
    )
    private var cachedDockPID: pid_t?
    private var cachedList: AXUIElement?
    private var lastIdentityAmbiguityLogTime: TimeInterval = 0
    private var extendedIdentityCache: [(
        element: AXUIElement,
        values: ApplicationIdentityValues
    )] = []

    private struct ProcessSwitcherContext {
        let dockElement: AXUIElement
        let list: AXUIElement
        let listFrame: CGRect
    }

    func reset() {
        cachedDockPID = nil
        cachedList = nil
        extendedIdentityCache.removeAll(keepingCapacity: false)
    }

    func snapshot() -> SnapshotResult {
        guard let context = processSwitcherContext() else {
            return .notVisible
        }
        let list = context.list
        let listFrame = context.listFrame
        let resolvedSelectedElement: AXUIElement
        switch selectedElement(in: list) {
        case let .found(element):
            resolvedSelectedElement = element
        case .notFound:
            return .notVisible
        case .ambiguous:
            logger.debug(
                "Native Process Switcher selected element is structurally ambiguous: \(self.selectionStructureSummary(in: list), privacy: .public)"
            )
            return .ambiguous
        }
        return snapshot(
            resolving: resolvedSelectedElement,
            list: list,
            listFrame: listFrame
        )
    }

    /// Resolves the concrete native App tile under a Quartz/AX global point.
    /// This path is intentionally independent of Dock's selected state so
    /// mouse hover can update the preview before a click or key press.
    func snapshot(at pointer: CGPoint) -> SnapshotResult {
        guard let context = processSwitcherContext(),
              context.listFrame.insetBy(dx: -2, dy: -2).contains(pointer) else {
            return .notVisible
        }

        var hitElement: AXUIElement?
        var directHitWasAmbiguous = false
        if AXUIElementCopyElementAtPosition(
            context.dockElement,
            Float(pointer.x),
            Float(pointer.y),
            &hitElement
        ) == .success,
        let hitElement,
        !CFEqual(hitElement, context.list),
        isDescendant(hitElement, of: context.list) {
            switch snapshot(
                resolving: hitElement,
                list: context.list,
                listFrame: context.listFrame
            ) {
            case let .visible(snapshot):
                return .visible(snapshot)
            case .ambiguous:
                directHitWasAmbiguous = true
            case .notVisible:
                break
            }
        }

        // Some Dock builds expose the entire icon row as the accessibility hit
        // target. In that case inspect only descendant branches whose frames
        // contain the pointer. The bounded fallback rejects overlapping Apps
        // and never derives identity from list order or approximate titles.
        switch applicationAtPointer(pointer, in: context.list) {
        case let .success(selection):
            return .visible(Snapshot(
                applications: selection.applications,
                listFrame: context.listFrame,
                selectedItemFrame: frame(of: selection.anchorElement)
            ))
        case .ambiguous:
            return .ambiguous
        case .notFound:
            return directHitWasAmbiguous ? .ambiguous : .notVisible
        }
    }

    private func processSwitcherContext() -> ProcessSwitcherContext? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
              ).first,
              !dock.isTerminated else {
            reset()
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.12)

        let list: AXUIElement
        if cachedDockPID == dock.processIdentifier,
           let cachedList,
           stringAttribute(kAXSubroleAttribute, of: cachedList)
                == kAXProcessSwitcherListSubrole as String {
            list = cachedList
        } else if let discovered = findProcessSwitcherList(from: dockElement) {
            cachedDockPID = dock.processIdentifier
            cachedList = discovered
            list = discovered
        } else {
            cachedList = nil
            return nil
        }

        guard let listFrame = frame(of: list),
              listFrame.width > 20,
              listFrame.height > 20 else {
            return nil
        }
        return ProcessSwitcherContext(
            dockElement: dockElement,
            list: list,
            listFrame: listFrame
        )
    }

    private func snapshot(
        resolving element: AXUIElement,
        list: AXUIElement,
        listFrame: CGRect
    ) -> SnapshotResult {
        switch resolveApplication(from: element, in: list) {
        case let .success(selection):
            return .visible(
                Snapshot(
                    applications: selection.applications,
                    listFrame: listFrame,
                    selectedItemFrame: frame(of: selection.anchorElement)
                )
            )
        case .notFound:
            return .notVisible
        case .ambiguous:
            return .ambiguous
        }
    }

    private func findProcessSwitcherList(from root: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var cursor = 0
        while cursor < queue.count, visited.count < maximumTraversalNodes {
            let current = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, current.element) }) {
                continue
            }
            visited.append(current.element)
            if stringAttribute(kAXSubroleAttribute, of: current.element)
                == kAXProcessSwitcherListSubrole as String {
                return current.element
            }
            guard current.depth < maximumTraversalDepth else { continue }
            for child in children(of: current.element) {
                queue.append((child, current.depth + 1))
            }
        }
        return nil
    }

    private enum SelectedElementResolution {
        case found(AXUIElement)
        case notFound
        case ambiguous
    }

    private func selectedElement(in list: AXUIElement) -> SelectedElementResolution {
        // Tahoe can expose one shared row through AXSelectedChildren while the
        // concrete application tile is the focused descendant. Prefer that
        // unique focus path, but only when it is actually inside this list.
        if let focused = elementAttribute(kAXFocusedUIElementAttribute, of: list),
           !CFEqual(focused, list),
           isDescendant(focused, of: list) {
            return .found(mostSpecificSelectedElement(from: focused))
        }

        let selectedChildren = uniqueElements(elementArrayAttribute(
            kAXSelectedChildrenAttribute,
            of: list
        ))
        if selectedChildren.count == 1, let selected = selectedChildren.first {
            return .found(mostSpecificSelectedElement(from: selected))
        }
        if selectedChildren.count > 1 {
            let refined = uniqueElements(selectedChildren.map {
                mostSpecificSelectedElement(from: $0)
            })
            if refined.count == 1 { return .found(refined[0]) }
            if let commonAncestor = nearestCommonAncestor(
                of: refined,
                below: list
            ) {
                return .found(mostSpecificSelectedElement(from: commonAncestor))
            }
            return .ambiguous
        }

        switch uniquelyMarkedDescendant(in: list) {
        case let .found(element):
            return .found(mostSpecificSelectedElement(from: element))
        case .notFound:
            return .notFound
        case .ambiguous:
            return .ambiguous
        }
    }

    /// Dock may report a selected row/container before it reports the concrete
    /// icon or label. Follow only an unambiguous selected/focused descendant;
    /// never canonicalize to the direct list child because Tahoe can use one
    /// direct row for several application tiles.
    private func mostSpecificSelectedElement(
        from element: AXUIElement
    ) -> AXUIElement {
        var current = element
        var visited: [AXUIElement] = []
        selectionLoop: for _ in 0..<8 {
            if visited.contains(where: { CFEqual($0, current) }) {
                break
            }
            visited.append(current)

            let selectedChildren = uniqueElements(elementArrayAttribute(
                kAXSelectedChildrenAttribute,
                of: current
            ))
            if selectedChildren.count == 1,
               let selectedChild = selectedChildren.first,
               !CFEqual(selectedChild, current) {
                current = selectedChild
                continue
            }
            if selectedChildren.count > 1 {
                if let commonAncestor = nearestCommonAncestor(
                    of: selectedChildren,
                    below: current
                ), !CFEqual(commonAncestor, current) {
                    current = commonAncestor
                    continue
                }
                break
            }

            if let focused = elementAttribute(
                kAXFocusedUIElementAttribute,
                of: current
            ), !CFEqual(focused, current), isDescendant(focused, of: current) {
                current = focused
                continue
            }

            switch uniquelyMarkedDescendant(in: current) {
            case let .found(markedElement):
                guard !CFEqual(markedElement, current) else { break selectionLoop }
                current = markedElement
            case .notFound, .ambiguous:
                break selectionLoop
            }
        }
        return current
    }

    /// Find the one selected/focused branch without scanning the whole Dock
    /// tree. Multiple marked nodes are acceptable only when they all live under
    /// the same immediate branch (for example an icon and its label).
    private func uniquelyMarkedDescendant(
        in root: AXUIElement
    ) -> SelectedElementResolution {
        struct Entry {
            let element: AXUIElement
            let depth: Int
            let branch: AXUIElement
        }

        var queue: [Entry] = children(of: root).map {
            Entry(element: $0, depth: 1, branch: $0)
        }
        var visited: [AXUIElement] = []
        var marked: [Entry] = []
        var cursor = 0
        while cursor < queue.count, visited.count < 64 {
            let current = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, current.element) }) {
                continue
            }
            visited.append(current.element)
            if boolAttribute(kAXSelectedAttribute, of: current.element) == true
                || boolAttribute(kAXFocusedAttribute, of: current.element) == true {
                marked.append(current)
            }
            guard current.depth < 4 else { continue }
            for child in children(of: current.element) {
                queue.append(Entry(
                    element: child,
                    depth: current.depth + 1,
                    branch: current.branch
                ))
            }
        }

        let markedElements = uniqueElements(marked.map(\.element))
        guard !markedElements.isEmpty else { return .notFound }
        if markedElements.count == 1, let element = markedElements.first {
            return .found(element)
        }
        let markedBranches = uniqueElements(marked.map(\.branch))
        guard markedBranches.count == 1, let branch = markedBranches.first else {
            return .ambiguous
        }
        return .found(branch)
    }

    private func uniqueElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for element in elements where !result.contains(where: { CFEqual($0, element) }) {
            result.append(element)
        }
        return result
    }

    private func isDescendant(
        _ element: AXUIElement,
        of ancestor: AXUIElement
    ) -> Bool {
        var current: AXUIElement? = element
        var visited: [AXUIElement] = []
        for _ in 0..<10 {
            guard let candidate = current,
                  !visited.contains(where: { CFEqual($0, candidate) }) else {
                return false
            }
            if CFEqual(candidate, ancestor) { return true }
            visited.append(candidate)
            current = elementAttribute(kAXParentAttribute, of: candidate)
        }
        return false
    }

    private func nearestCommonAncestor(
        of elements: [AXUIElement],
        below boundary: AXUIElement
    ) -> AXUIElement? {
        guard let first = elements.first else { return nil }
        var ancestry: [AXUIElement] = []
        var current: AXUIElement? = first
        var visited: [AXUIElement] = []
        for _ in 0..<10 {
            guard let candidate = current,
                  !CFEqual(candidate, boundary),
                  !visited.contains(where: { CFEqual($0, candidate) }) else {
                break
            }
            ancestry.append(candidate)
            visited.append(candidate)
            current = elementAttribute(kAXParentAttribute, of: candidate)
        }
        return ancestry.first(where: { candidate in
            elements.allSatisfy { isDescendant($0, of: candidate) }
        })
    }

    private func selectionStructureSummary(in list: AXUIElement) -> String {
        let selectedCount = uniqueElements(elementArrayAttribute(
            kAXSelectedChildrenAttribute,
            of: list
        )).count
        let focusedInside: Bool
        if let focused = elementAttribute(kAXFocusedUIElementAttribute, of: list) {
            focusedInside = !CFEqual(focused, list) && isDescendant(focused, of: list)
        } else {
            focusedInside = false
        }
        let markedState: String
        switch uniquelyMarkedDescendant(in: list) {
        case .found:
            markedState = "unique"
        case .notFound:
            markedState = "none"
        case .ambiguous:
            markedState = "multiple"
        }
        return "selectedChildren=\(selectedCount) focusedInside=\(focusedInside) directChildren=\(children(of: list).count) markedBranches=\(markedState)"
    }

    private struct SelectedApplication {
        let applications: [NSRunningApplication]
        let anchorElement: AXUIElement

        var application: NSRunningApplication {
            applications[0]
        }
    }

    private enum ApplicationResolution {
        case success(SelectedApplication)
        case notFound
        case ambiguous
    }

    private enum IdentityResolution {
        case success([NSRunningApplication])
        case notFound
        case ambiguous
    }

    private func applicationAtPointer(
        _ pointer: CGPoint,
        in list: AXUIElement
    ) -> ApplicationResolution {
        struct PointerCandidate {
            let element: AXUIElement
            let depth: Int
            let area: CGFloat
        }

        var queue: [(element: AXUIElement, depth: Int)] = children(of: list).map {
            ($0, 1)
        }
        var visited: [AXUIElement] = []
        var candidates: [PointerCandidate] = []
        var cursor = 0
        while cursor < queue.count, visited.count < 96 {
            let current = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, current.element) }) {
                continue
            }
            visited.append(current.element)

            if let elementFrame = frame(of: current.element) {
                guard elementFrame.insetBy(dx: -1, dy: -1).contains(pointer) else {
                    continue
                }
                if elementFrame.width > 8, elementFrame.height > 8 {
                    candidates.append(PointerCandidate(
                        element: current.element,
                        depth: current.depth,
                        area: elementFrame.width * elementFrame.height
                    ))
                }
            }
            guard current.depth < maximumTraversalDepth else { continue }
            for child in children(of: current.element) {
                queue.append((child, current.depth + 1))
            }
        }

        candidates.sort {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.area < $1.area
        }

        var selectionsByIdentity: [String: SelectedApplication] = [:]
        var sawAmbiguousCandidate = false
        for candidate in candidates.prefix(12) {
            switch resolveApplication(from: candidate.element, in: list) {
            case let .success(selection):
                guard let identity = applicationGroupIdentity(
                    for: selection.applications
                ) else { return .ambiguous }
                if let existing = selectionsByIdentity[identity] {
                    guard let mergedApplications = mergeApplications(
                        existing.applications,
                        selection.applications
                    ) else { return .ambiguous }
                    selectionsByIdentity[identity] = SelectedApplication(
                        applications: mergedApplications,
                        anchorElement: existing.anchorElement
                    )
                } else {
                    selectionsByIdentity[identity] = selection
                }
                if selectionsByIdentity.count > 1 { return .ambiguous }
            case .ambiguous:
                sawAmbiguousCandidate = true
            case .notFound:
                continue
            }
        }
        if let selection = selectionsByIdentity.values.first {
            return .success(selection)
        }
        return sawAmbiguousCandidate ? .ambiguous : .notFound
    }

    private func resolveApplication(
        from selectedElement: AXUIElement,
        in list: AXUIElement
    ) -> ApplicationResolution {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var lineage: [AXUIElement] = []
        var current: AXUIElement? = selectedElement
        var visited: [AXUIElement] = []
        for _ in 0..<8 {
            guard let element = current,
                  !CFEqual(element, list),
                  !visited.contains(where: { CFEqual($0, element) }) else {
                break
            }
            visited.append(element)
            lineage.append(element)
            current = elementAttribute(kAXParentAttribute, of: element)
        }

        var selectedApplications: [NSRunningApplication]?
        var selectedIdentity: String?
        var anchorElement = selectedElement
        var sawAmbiguousScope = false
        scopeLoop: for scope in lineage {
            switch resolveApplication(
                in: scope,
                maximumDepth: 3,
                applications: applications
            ) {
            case let .success(resolvedApplications):
                guard let identity = applicationGroupIdentity(
                    for: resolvedApplications
                ) else { return .ambiguous }
                if let selectedIdentity, selectedIdentity != identity {
                    return .ambiguous
                }
                if let existingApplications = selectedApplications {
                    guard let merged = mergeApplications(
                        existingApplications,
                        resolvedApplications
                    ) else { return .ambiguous }
                    selectedApplications = merged
                } else {
                    selectedApplications = resolvedApplications
                }
                selectedIdentity = identity
                if let scopeFrame = frame(of: scope),
                   scopeFrame.width > 8,
                   scopeFrame.height > 8 {
                    anchorElement = scope
                }
            case .ambiguous:
                sawAmbiguousScope = true
                // Once a narrower descendant has identified exactly one App,
                // the first ambiguous ancestor is the shared row/container.
                // Stop before identities from adjacent tiles can contaminate
                // the selected application.
                if selectedApplications != nil { break scopeLoop }
            case .notFound:
                continue
            }
        }

        if let selectedApplications {
            return .success(SelectedApplication(
                applications: selectedApplications,
                anchorElement: anchorElement
            ))
        }
        return sawAmbiguousScope ? .ambiguous : .notFound
    }

    private func resolveApplication(
        in root: AXUIElement,
        maximumDepth: Int,
        applications: [NSRunningApplication]
    ) -> IdentityResolution {
        let maximumIdentityNodes = 48
        var currentLevel = [root]
        var currentLevelWasTruncated = false
        var visited: [AXUIElement] = []
        var ambiguousMatchCount = 0
        var ambiguousMatchDepth = 0
        var ambiguousEvidence = ""
        for depth in 0...maximumDepth where !currentLevel.isEmpty {
            var matchesByPID: [pid_t: NSRunningApplication] = [:]
            var nextLevel: [AXUIElement] = []
            var nextLevelWasTruncated = false

            for element in currentLevel {
                guard visited.count < maximumIdentityNodes else {
                    currentLevelWasTruncated = true
                    break
                }
                if visited.contains(where: { CFEqual($0, element) }) {
                    continue
                }
                visited.append(element)

                let identityValues = directIdentityValues(from: element)
                var identityMatches = matchingApplications(
                    identityValues: identityValues,
                    applications: applications
                )
                if identityMatches.count != 1 {
                    let extendedValues = directIdentityValues(
                        from: element,
                        includeCustomIdentityAttributes: true
                    )
                    let extendedMatches = matchingApplications(
                        identityValues: extendedValues,
                        applications: applications
                    )
                    if !extendedMatches.isEmpty {
                        identityMatches = extendedMatches
                    }
                }
                for application in identityMatches {
                    matchesByPID[application.processIdentifier] = application
                }

                guard depth < maximumDepth else { continue }
                for child in children(of: element) {
                    guard visited.count + nextLevel.count < maximumIdentityNodes else {
                        nextLevelWasTruncated = true
                        break
                    }
                    if visited.contains(where: { CFEqual($0, child) })
                        || nextLevel.contains(where: { CFEqual($0, child) }) {
                        continue
                    }
                    nextLevel.append(child)
                }
            }

            if currentLevelWasTruncated && !matchesByPID.isEmpty {
                let evidence = currentLevel.prefix(4).map {
                    identityMatchSummary(from: $0, applications: applications)
                }.joined(separator: " | ")
                logger.debug(
                    "Native Process Switcher identity is ambiguous at nearest depth \(depth, privacy: .public); matches=\(matchesByPID.count, privacy: .public); truncated=\(currentLevelWasTruncated, privacy: .public); evidence=\(evidence, privacy: .public)"
                )
                return .ambiguous
            }
            if !matchesByPID.isEmpty {
                let matches = matchesByPID.values.sorted {
                    $0.processIdentifier < $1.processIdentifier
                }
                if let groupedApplications = validatedApplicationGroup(matches) {
                    if groupedApplications.count > 1 {
                        logger.debug(
                            "Native Process Switcher grouped same-identity application instances; processes=\(groupedApplications.count, privacy: .public)"
                        )
                    }
                    return .success(groupedApplications)
                }
                // A Dock switcher tile can expose a generic localized App
                // name on its outer button (for example two distinct Apps
                // both named "WeChat") while a descendant carries the
                // concrete identity. Do not fail on that shallow collision:
                // keep traversing for stronger URL/bundle evidence and only
                // report ambiguity after the bounded search is exhausted.
                if ambiguousMatchCount == 0 {
                    ambiguousMatchCount = matchesByPID.count
                    ambiguousMatchDepth = depth
                    ambiguousEvidence = currentLevel.prefix(4).map {
                        identityMatchSummary(from: $0, applications: applications)
                    }.joined(separator: " | ")
                }
            }
            if currentLevelWasTruncated {
                logger.debug(
                    "Native Process Switcher identity search was truncated at depth \(depth, privacy: .public)"
                )
                return .ambiguous
            }
            if nextLevelWasTruncated && nextLevel.isEmpty {
                logger.debug(
                    "Native Process Switcher identity search exhausted its node budget before depth \(depth + 1, privacy: .public)"
                )
                return .ambiguous
            }

            currentLevel = nextLevel
            currentLevelWasTruncated = nextLevelWasTruncated
        }
        if ambiguousMatchCount > 0 {
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastIdentityAmbiguityLogTime >= 2 {
                lastIdentityAmbiguityLogTime = now
                logger.debug(
                    "Native Process Switcher identity remains ambiguous after bounded descendant search; firstDepth=\(ambiguousMatchDepth, privacy: .public); matches=\(ambiguousMatchCount, privacy: .public); evidence=\(ambiguousEvidence, privacy: .public)"
                )
            }
            return .ambiguous
        }
        return .notFound
    }

    /// Dock's public Process Switcher AX tile identifies an App, not a unique
    /// process. Multiple regular processes are one safe group only when their
    /// concrete bundle locations are identical. This deliberately rejects
    /// same-name Apps from different bundles and never falls back to launch or
    /// window-count heuristics.
    private func validatedApplicationGroup(
        _ applications: [NSRunningApplication]
    ) -> [NSRunningApplication]? {
        var applicationsByPID: [pid_t: NSRunningApplication] = [:]
        for application in applications where !application.isTerminated {
            applicationsByPID[application.processIdentifier] = application
        }
        let uniqueApplications = applicationsByPID.values.sorted {
            $0.processIdentifier < $1.processIdentifier
        }
        guard applicationGroupIdentity(for: uniqueApplications) != nil else {
            return nil
        }
        return uniqueApplications
    }

    private func applicationGroupIdentity(
        for applications: [NSRunningApplication]
    ) -> String? {
        guard !applications.isEmpty else { return nil }
        let bundlePaths = applications.compactMap {
            $0.bundleURL?.standardizedFileURL.path.lowercased()
        }
        if bundlePaths.count == applications.count,
           Set(bundlePaths).count == 1,
           let path = bundlePaths.first {
            return "url:\(path)"
        }
        // Missing a bundle path is tolerable only if every instance lacks it
        // and every non-empty bundle identifier is exactly the same. Mixing a
        // known path with an unknown path is intentionally ambiguous.
        if bundlePaths.isEmpty {
            let bundleIdentifiers = applications.compactMap {
                $0.bundleIdentifier?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).lowercased()
            }.filter { !$0.isEmpty }
            if bundleIdentifiers.count == applications.count,
               Set(bundleIdentifiers).count == 1,
               let bundleIdentifier = bundleIdentifiers.first {
                return "bundle:\(bundleIdentifier)"
            }
        }
        guard applications.count == 1,
              let name = applications[0].localizedName?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ), !name.isEmpty else { return nil }
        return "name:\(name.lowercased())"
    }

    private func mergeApplications(
        _ lhs: [NSRunningApplication],
        _ rhs: [NSRunningApplication]
    ) -> [NSRunningApplication]? {
        guard applicationGroupIdentity(for: lhs)
                == applicationGroupIdentity(for: rhs) else { return nil }
        return validatedApplicationGroup(lhs + rhs)
    }

    /// Log only the AX attribute name and the application identities it
    /// matches. Never include the raw attribute value because titles/help can
    /// contain user content.
    private func identityMatchSummary(
        from element: AXUIElement,
        applications: [NSRunningApplication]
    ) -> String {
        let stringAttributes: [(label: String, name: String)] = [
            ("title", kAXTitleAttribute),
            ("description", kAXDescriptionAttribute),
            ("identifier", kAXIdentifierAttribute),
            ("help", kAXHelpAttribute),
            ("value", kAXValueAttribute)
        ]
        var evidence: [String] = []
        for attribute in stringAttributes {
            guard let value = stringAttribute(attribute.name, of: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let matches = matchingApplications(
                identityValues: (
                    strings: [value],
                    urls: [],
                    processIdentifiers: []
                ),
                applications: applications
            )
            if !matches.isEmpty {
                evidence.append("\(attribute.label)=[\(applicationMatchLabels(matches))]")
            }
        }
        if let url = urlAttribute(of: element)?.standardizedFileURL {
            let matches = matchingApplications(
                identityValues: (
                    strings: [],
                    urls: [url],
                    processIdentifiers: []
                ),
                applications: applications
            )
            if !matches.isEmpty {
                evidence.append("url=[\(applicationMatchLabels(matches))]")
            }
        }
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? "?"
        let subrole = stringAttribute(kAXSubroleAttribute, of: element) ?? "?"
        return "role=\(role),subrole=\(subrole),\(evidence.joined(separator: ","))"
    }

    private func applicationMatchLabels(
        _ applications: [NSRunningApplication]
    ) -> String {
        applications.map {
            "\($0.bundleIdentifier ?? "no.bundle")#\($0.processIdentifier)"
        }.sorted().joined(separator: "+")
    }

    private func matchingApplications(
        identityValues: ApplicationIdentityValues,
        applications: [NSRunningApplication]
    ) -> [NSRunningApplication] {
        let processMatches = applications.filter {
            identityValues.processIdentifiers.contains($0.processIdentifier)
        }
        if !processMatches.isEmpty { return processMatches }

        let urlMatches = applications.filter { application in
            guard let bundleURL = application.bundleURL?.standardizedFileURL else {
                return false
            }
            return identityValues.urls.contains(bundleURL)
        }
        if !urlMatches.isEmpty { return urlMatches }

        let pathMatches = applications.filter { application in
            guard let bundleURL = application.bundleURL?.standardizedFileURL else {
                return false
            }
            let path = bundleURL.path
            let absoluteString = bundleURL.absoluteString
            return identityValues.strings.contains {
                $0.caseInsensitiveCompare(path) == .orderedSame
                    || $0.caseInsensitiveCompare(absoluteString) == .orderedSame
            }
        }
        if !pathMatches.isEmpty { return pathMatches }

        let bundleMatches = applications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return false
            }
            return identityValues.strings.contains {
                $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
        }
        if !bundleMatches.isEmpty { return bundleMatches }

        return applications.filter { application in
            guard let name = application.localizedName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !name.isEmpty else { return false }
            return identityValues.strings.contains {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    private func directIdentityValues(
        from element: AXUIElement,
        includeCustomIdentityAttributes: Bool = false
    ) -> ApplicationIdentityValues {
        let stringAttributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXIdentifierAttribute,
            kAXHelpAttribute,
            kAXValueAttribute
        ]
        var strings: [String] = []
        var urls: [URL] = []
        var processIdentifiers: [pid_t] = []
        for attribute in stringAttributes {
            if let value = stringAttribute(attribute, of: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty,
               !strings.contains(where: {
                   $0.caseInsensitiveCompare(value) == .orderedSame
               }) {
                strings.append(value)
            }
        }
        if let url = urlAttribute(of: element)?.standardizedFileURL {
            urls.append(url)
        }

        guard includeCustomIdentityAttributes else {
            return (strings, urls, processIdentifiers)
        }
        if let cached = extendedIdentityCache.first(where: {
            CFEqual($0.element, element)
        }) {
            return cached.values
        }

        // Dock may expose its concrete switcher identity through a private
        // accessibility attribute even when the public title is only a
        // localized App name. Inspect only attribute names with identity
        // semantics and accept only scalar strings, URLs or numeric PIDs.
        // Never traverse arbitrary values or user-content attributes.
        var attributeNamesValue: CFArray?
        if AXUIElementCopyAttributeNames(
            element,
            &attributeNamesValue
        ) == .success,
           let attributeNames = attributeNamesValue as? [String] {
            let identityKeywords = [
                "bundle", "identifier", "url", "path",
                "application", "process", "pid"
            ]
            let standardAttributes = Set(stringAttributes)
            let identityAttributeNames = attributeNames.filter { attributeName in
                let normalizedName = attributeName.lowercased()
                return !standardAttributes.contains(attributeName)
                    && identityKeywords.contains(where: {
                        normalizedName.contains($0)
                    })
            }
            // Bound actual IPC reads, but do not discard a concrete identity
            // merely because it appears after the first 48 unrelated AX
            // attributes in an AppKit-private attribute list.
            for attributeName in identityAttributeNames.prefix(24) {
                let normalizedName = attributeName.lowercased()
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    element,
                    attributeName as CFString,
                    &value
                ) == .success,
                      let value else { continue }
                if CFGetTypeID(value) == CFStringGetTypeID(),
                   let string = value as? String {
                    let trimmed = string.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    if !trimmed.isEmpty,
                       !strings.contains(where: {
                           $0.caseInsensitiveCompare(trimmed) == .orderedSame
                       }) {
                        strings.append(trimmed)
                    }
                } else if CFGetTypeID(value) == CFURLGetTypeID(),
                          let url = value as? URL {
                    let normalizedURL = url.standardizedFileURL
                    if !urls.contains(normalizedURL) {
                        urls.append(normalizedURL)
                    }
                } else if normalizedName.contains("pid")
                            || normalizedName.contains("processidentifier"),
                          CFGetTypeID(value) == CFNumberGetTypeID(),
                          let number = value as? NSNumber {
                    let processIdentifier = number.int32Value
                    if processIdentifier > 0,
                       !processIdentifiers.contains(processIdentifier) {
                        processIdentifiers.append(processIdentifier)
                    }
                } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let representedApplication = unsafeBitCast(
                        value,
                        to: AXUIElement.self
                    )
                    var processIdentifier: pid_t = 0
                    if AXUIElementGetPid(
                        representedApplication,
                        &processIdentifier
                    ) == .success,
                       processIdentifier > 0,
                       !processIdentifiers.contains(processIdentifier) {
                        processIdentifiers.append(processIdentifier)
                    }
                } else if CFGetTypeID(value) == CFArrayGetTypeID(),
                          let representedApplications = value as? [AXUIElement] {
                    for representedApplication in representedApplications.prefix(4) {
                        var processIdentifier: pid_t = 0
                        if AXUIElementGetPid(
                            representedApplication,
                            &processIdentifier
                        ) == .success,
                           processIdentifier > 0,
                           !processIdentifiers.contains(processIdentifier) {
                            processIdentifiers.append(processIdentifier)
                        }
                    }
                }
            }
        }
        let result: ApplicationIdentityValues = (
            strings,
            urls,
            processIdentifiers
        )
        if extendedIdentityCache.count < 24 {
            extendedIdentityCache.append((element, result))
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for attribute in [kAXVisibleChildrenAttribute, kAXChildrenAttribute] {
            for child in elementArrayAttribute(attribute, of: element)
            where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return result
    }

    private func elementArrayAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func elementAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value as? Bool
    }

    private func urlAttribute(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXURLAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? URL
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAX = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

@MainActor
private final class CommandTabOverlayController {
    private enum Metrics {
        static let emptyPreviewWidth: CGFloat = 260
        static let previewHeight: CGFloat = 218
        static let previewTileWidth: CGFloat = 220
        static let previewTileSpacing: CGFloat = 10
        static let previewHorizontalPadding: CGFloat = 10
        static let previewGap: CGFloat = 14
        static let screenInset: CGFloat = 12
    }

    private struct PreviewLayout {
        let size: CGSize
        let tileWidth: CGFloat
    }

    private let model: CommandTabOverlayModel
    private let previewPanel: CommandTabInteractionPanel
    private let previewContentView: CommandTabPanelContentView<CommandTabPreviewView>
    private var presentationScreen: NSScreen?
    private var hoveredWindowSelection: CommandTabPreviewTarget?
    private var interactionGeneration: UInt64 = 0
    private var recentCacheExpirationGeneration = 0
    private var recentCacheExpirationWorkItem: DispatchWorkItem?

    init() {
        let model = CommandTabOverlayModel()
        let previewContentView = CommandTabPanelContentView(
            rootView: CommandTabPreviewView(model: model)
        )
        let previewPanel = CommandTabInteractionPanel(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(width: Metrics.emptyPreviewWidth, height: Metrics.previewHeight)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.model = model
        self.previewPanel = previewPanel
        self.previewContentView = previewContentView

        configure(panel: previewPanel, acceptsMouseEvents: true)

        previewPanel.identifier = NSUserInterfaceItemIdentifier("SuperIsland.CmdTab.PreviewPanel")
        previewPanel.contentView = previewContentView
        previewPanel.acceptsMouseMovedEvents = true
        previewContentView.pointerView.onPointer = { [weak self] type, point, _ in
            self?.handlePointer(type: type, point: point, deferAction: false)
        }
    }

    func showNativePreview(
        items: [CommandTabDisplayItem],
        selectedIndex: Int,
        anchorAXFrame: CGRect,
        onCommitWindow: @escaping (Int, Int) -> Void,
        onHoverWindow: @escaping (Int, Int) -> Void,
        onCloseWindow: @escaping (Int, Int) -> Void
    ) {
        guard !items.isEmpty,
              let selectedItemIndex = items.firstIndex(where: { $0.id == selectedIndex }),
              let convertedAnchor = appKitFrame(fromAXFrame: anchorAXFrame) else {
            hide()
            return
        }
        let screen = convertedAnchor.screen
        let anchorFrame = convertedAnchor.frame
        presentationScreen = screen
        let previewLayout = fittingPreviewLayout(
            windowCount: items[selectedItemIndex].windows.count,
            in: screen.visibleFrame
        )
        let previewSize = previewLayout.size
        let previewX = clamp(
            anchorFrame.midX - previewSize.width / 2,
            lower: screen.visibleFrame.minX + Metrics.screenInset,
            upper: screen.visibleFrame.maxX - Metrics.screenInset - previewSize.width
        )
        let preferredAboveY = anchorFrame.maxY + Metrics.previewGap
        let fallbackBelowY = anchorFrame.minY - Metrics.previewGap - previewSize.height
        let previewY = clamp(
            preferredAboveY + previewSize.height <= screen.visibleFrame.maxY - Metrics.screenInset
                ? preferredAboveY
                : fallbackBelowY,
            lower: screen.visibleFrame.minY + Metrics.screenInset,
            upper: screen.visibleFrame.maxY - Metrics.screenInset - previewSize.height
        )
        previewPanel.setFrame(
            CGRect(origin: CGPoint(x: previewX, y: previewY), size: previewSize),
            display: true
        )

        model.onCommitWindow = { [weak self] applicationIndex, windowIndex in
            self?.hoveredWindowSelection = nil
            onCommitWindow(applicationIndex, windowIndex)
        }
        model.onHoverWindow = { applicationIndex, windowIndex in
            onHoverWindow(applicationIndex, windowIndex)
        }
        model.onCloseWindow = { [weak self] applicationIndex, windowIndex in
            self?.hoveredWindowSelection = nil
            onCloseWindow(applicationIndex, windowIndex)
        }
        model.update(
            items: items,
            selectedID: selectedIndex,
            previewTileWidth: previewLayout.tileWidth,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        rescheduleRecentCacheExpiration()

        // Dock owns and draws the native application strip. SuperIsland adds
        // only the selected application's window preview above it.
        previewPanel.orderFrontRegardless()
    }

    func hide() {
        interactionGeneration &+= 1
        cancelRecentCacheExpiration()
        previewPanel.orderOut(nil)
        presentationScreen = nil
        hoveredWindowSelection = nil
        model.clear()
    }

    /// Hit-test a pointer event supplied by the Cmd-Tab CGEvent tap. Global
    /// AppKit's hit view is used outside that route; both feed the same paired
    /// press/release state machine, so a duplicate release cannot act twice.
    func handleExternalPointer(
        type: NSEvent.EventType,
        at screenLocation: CGPoint,
        deferAction: Bool = false
    ) -> Bool {
        guard previewPanel.isVisible else { return false }
        guard previewPanel.frame.contains(screenLocation) else {
            handlePointer(type: .mouseExited, point: .zero, deferAction: deferAction)
            return false
        }
        let panelPoint = previewPanel.convertPoint(fromScreen: screenLocation)
        handlePointer(type: type, point: CGPoint(
            x: panelPoint.x,
            y: (previewPanel.contentView?.bounds.height ?? 0) - panelPoint.y
        ), deferAction: deferAction)
        return true
    }

    func containsPointer(_ point: CGPoint) -> Bool {
        previewPanel.isVisible && previewPanel.frame.contains(point)
    }

    func clearPointerSelection() {
        hoveredWindowSelection = nil
        model.clearPointerSelection()
    }

    private func handlePointer(type: NSEvent.EventType, point: CGPoint, deferAction: Bool) {
        let action = model.handlePointer(type, at: point)
        let hovered = model.pointerHoveredTarget
        let changed = hoveredWindowSelection != hovered
        hoveredWindowSelection = hovered
        guard action != nil || (changed && hovered != nil) else { return }
        let generation = interactionGeneration
        // Commit and close callbacks only enqueue immutable target identities.
        // Do that synchronously so the following physical Command release is
        // ordered behind the click in the monitor's FIFO. AX work still runs
        // after the event tap returns when the queue drains.
        if let action {
            switch action {
            case let .activate(target) where model.isCurrent(target):
                model.onCommitWindow(target.applicationIndex, target.windowIndex)
            case let .close(target) where model.isCurrent(target):
                model.onCloseWindow(target.applicationIndex, target.windowIndex)
            default: break
            }
        }

        // Hover may refresh presentation state, so it remains deferred for the
        // native event-tap route and cannot invalidate the paired click first.
        let dispatchHover: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.previewPanel.isVisible,
                  self.interactionGeneration == generation else { return }
            if changed, let hovered, self.model.pointerHoveredTarget == hovered,
               self.model.isCurrent(hovered) {
                self.model.onHoverWindow(hovered.applicationIndex, hovered.windowIndex)
            }
        }
        if changed, hovered != nil {
            if deferAction {
                DispatchQueue.main.async(execute: dispatchHover)
            } else {
                dispatchHover()
            }
        }
    }

    private func rescheduleRecentCacheExpiration() {
        recentCacheExpirationWorkItem?.cancel()
        recentCacheExpirationGeneration &+= 1
        let generation = recentCacheExpirationGeneration
        guard let expiration = model.expireRecentCaches(now: Date()) else {
            recentCacheExpirationWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.recentCacheExpirationGeneration == generation else { return }
            self.recentCacheExpirationWorkItem = nil
            self.rescheduleRecentCacheExpiration()
        }
        recentCacheExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, expiration.timeIntervalSinceNow) + 0.02,
            execute: workItem
        )
    }

    private func cancelRecentCacheExpiration() {
        recentCacheExpirationGeneration &+= 1
        recentCacheExpirationWorkItem?.cancel()
        recentCacheExpirationWorkItem = nil
    }

    private func configure(panel: NSPanel, acceptsMouseEvents: Bool) {
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = !acceptsMouseEvents
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        // The explicit AppKit hit view accepts the first mouse without taking
        // keyboard focus from the native switcher or activating SuperIsland.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func fittingPreviewLayout(windowCount: Int, in visibleFrame: CGRect) -> PreviewLayout {
        let maximumHeight = max(
            96,
            visibleFrame.height - Metrics.screenInset * 2
        )
        let height = min(Metrics.previewHeight, maximumHeight)
        let availableWidth = max(1, visibleFrame.width - Metrics.screenInset * 2)
        guard windowCount > 0 else {
            return PreviewLayout(
                size: CGSize(width: min(Metrics.emptyPreviewWidth, availableWidth), height: height),
                tileWidth: max(
                    1,
                    min(Metrics.previewTileWidth, availableWidth - Metrics.previewHorizontalPadding * 2)
                )
            )
        }

        let tileWidth = min(
            Metrics.previewTileWidth,
            max(64, availableWidth - Metrics.previewHorizontalPadding * 2)
        )
        let idealWidth = Metrics.previewHorizontalPadding * 2
            + CGFloat(windowCount) * tileWidth
            + CGFloat(max(0, windowCount - 1)) * Metrics.previewTileSpacing
        let width = min(availableWidth, idealWidth)
        return PreviewLayout(
            size: CGSize(width: width, height: height),
            tileWidth: tileWidth
        )
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }

    private func appKitFrame(
        fromAXFrame frame: CGRect
    ) -> (frame: CGRect, screen: NSScreen)? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)
            guard quartzBounds.intersects(frame)
                    || quartzBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
                continue
            }
            return (
                CGRect(
                    x: screen.frame.minX + (frame.minX - quartzBounds.minX),
                    y: screen.frame.maxY - (frame.maxY - quartzBounds.minY),
                    width: frame.width,
                    height: frame.height
                ),
                screen
            )
        }
        return nil
    }
}

/// A deliberately non-intrinsic AppKit boundary between an `NSPanel` and
/// SwiftUI. `NSHostingView` is retained for the controller's lifetime, but it
/// can only fill this container's explicit bounds; its fitting size never
/// participates in sizing the panel itself.
private final class CommandTabPanelContentView<Content: View>: NSView {
    private let hostingView: CommandTabHostingView<Content>
    let pointerView = WindowPreviewTrackingView()

    init(rootView: Content) {
        hostingView = CommandTabHostingView(rootView: rootView)
        super.init(frame: .zero)

        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        addSubview(hostingView)
        pointerView.frame = bounds
        pointerView.autoresizingMask = [.width, .height]
        pointerView.scrollingView = hostingView
        addSubview(pointerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var needsPanelToBecomeKey: Bool {
        true
    }

    override func layout() {
        super.layout()
        guard hostingView.frame != bounds else { return }
        hostingView.frame = bounds
    }
}

/// A nonactivating panel receives hover tracking without becoming key, but
/// AppKit asks the actual hit view—not only its container—whether the first
/// mouse-down should be delivered. Keep this local to Cmd-Tab so the first
/// click reaches the SwiftUI preview buttons without activating SuperIsland.
private final class CommandTabHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var needsPanelToBecomeKey: Bool {
        true
    }
}

/// Receives button mouse-down/up while retaining `.nonactivatingPanel`
/// behavior, so SuperIsland itself does not become the active application.
private final class CommandTabInteractionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CommandTabPreviewTarget: Hashable {
    let applicationIndex: Int
    let windowIndex: Int
    let identity: WindowPreviewIdentity
}

struct CommandTabDisplayItem: Identifiable {
    let id: Int
    let appName: String
    let icon: NSImage?
    let isLoading: Bool
    let windows: [CommandTabWindowDisplayItem]

    func replacingWindows(
        _ windows: [CommandTabWindowDisplayItem]
    ) -> CommandTabDisplayItem {
        CommandTabDisplayItem(
            id: id,
            appName: appName,
            icon: icon,
            isLoading: isLoading,
            windows: windows
        )
    }
}

struct CommandTabWindowDisplayItem: Identifiable {
    let id: Int
    let identity: WindowPreviewIdentity
    let title: String
    let isMinimized: Bool
    let canClose: Bool
    let isSelected: Bool
    let thumbnailResult: WindowThumbnailResult?
    var canActivate = true

    func replacingThumbnailResult(
        _ thumbnailResult: WindowThumbnailResult?
    ) -> CommandTabWindowDisplayItem {
        CommandTabWindowDisplayItem(
            id: id,
            identity: identity,
            title: title,
            isMinimized: isMinimized,
            canClose: canClose,
            isSelected: isSelected,
            thumbnailResult: thumbnailResult,
            canActivate: canActivate
        )
    }
}

@MainActor
final class CommandTabOverlayModel: ObservableObject {
    @Published private(set) var items: [CommandTabDisplayItem] = []
    @Published private(set) var selectedID = 0
    @Published private(set) var previewTileWidth: CGFloat = 220
    @Published private(set) var reduceMotion = false
    @Published private(set) var pointerHoveredTarget: CommandTabPreviewTarget?

    private var previewFrames: [CommandTabPreviewTarget: CGRect] = [:]
    private var pointerState = WindowPreviewPointerState<CommandTabPreviewTarget>()

    var onCommitWindow: (Int, Int) -> Void = { _, _ in }
    var onHoverWindow: (Int, Int) -> Void = { _, _ in }
    var onCloseWindow: (Int, Int) -> Void = { _, _ in }

    var selectedItem: CommandTabDisplayItem? {
        items.first(where: { $0.id == selectedID })
    }

    func update(
        items: [CommandTabDisplayItem],
        selectedID: Int,
        previewTileWidth: CGFloat,
        reduceMotion: Bool
    ) {
        let newIdentities = items.flatMap { $0.windows.map(\.identity) }
        if self.items.flatMap({ $0.windows.map(\.identity) }) != newIdentities {
            previewFrames = [:]
            pointerHoveredTarget = nil
            pointerState = WindowPreviewPointerState()
        }
        self.reduceMotion = reduceMotion
        if reduceMotion {
            self.items = items
            self.selectedID = selectedID
            self.previewTileWidth = previewTileWidth
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.items = items
                self.selectedID = selectedID
                self.previewTileWidth = previewTileWidth
            }
        }
        updatePointerFrames()
    }

    func clear() {
        items = []
        selectedID = 0
        previewTileWidth = 220
        reduceMotion = false
        onCommitWindow = { _, _ in }
        onHoverWindow = { _, _ in }
        onCloseWindow = { _, _ in }
        pointerHoveredTarget = nil
        previewFrames = [:]
        pointerState = WindowPreviewPointerState()
    }

    func setPreviewFrames(_ frames: [CommandTabPreviewTarget: CGRect]) {
        previewFrames = frames.filter { isCurrent($0.key) }
        updatePointerFrames()
    }

    func setPreviewFrame(
        _ frame: CGRect?,
        for target: CommandTabPreviewTarget
    ) {
        guard frame == nil || isCurrent(target) else { return }
        if let frame {
            previewFrames[target] = frame
        } else {
            previewFrames.removeValue(forKey: target)
        }
        updatePointerFrames()
    }

    func setPointerHovered(_ target: CommandTabPreviewTarget?) {
        guard pointerHoveredTarget != target else { return }
        pointerHoveredTarget = target
    }

    func clearPointerSelection() {
        pointerState.resetPointer()
        setPointerHovered(nil)
    }

    func isCurrent(_ target: CommandTabPreviewTarget) -> Bool {
        guard let item = selectedItem, item.id == target.applicationIndex else { return false }
        return item.windows.contains { $0.id == target.windowIndex && $0.identity == target.identity }
    }

    private func updatePointerFrames() {
        var closable: Set<CommandTabPreviewTarget> = []
        var activatable: Set<CommandTabPreviewTarget> = []
        for window in selectedItem?.windows ?? [] {
            let target = CommandTabPreviewTarget(applicationIndex: selectedID, windowIndex: window.id, identity: window.identity)
            if window.canClose { closable.insert(target) }
            if window.canActivate { activatable.insert(target) }
        }
        pointerState.update(frames: previewFrames.filter { isCurrent($0.key) }, activatable: activatable, closable: closable)
    }

    func handlePointer(_ type: NSEvent.EventType, at point: CGPoint) -> WindowPreviewPointerAction<CommandTabPreviewTarget>? {
        let action = pointerState.handle(type, at: point)
        setPointerHovered(pointerState.hovered)
        return action
    }

    func expireRecentCaches(now: Date) -> Date? {
        var didChange = false
        var nextExpiration: Date?
        let updatedItems = items.map { item in
            item.replacingWindows(item.windows.map { window in
                guard let result = window.thumbnailResult,
                      case let .recentCache(_, timestamp) = result else {
                    return window
                }
                let expiration = timestamp.addingTimeInterval(
                    WindowThumbnailProvider.recentCacheTTL
                )
                guard expiration > now else {
                    didChange = true
                    return window.replacingThumbnailResult(.notEnumerated)
                }
                if nextExpiration == nil || expiration < nextExpiration! {
                    nextExpiration = expiration
                }
                return window
            })
        }
        if didChange { items = updatedItems }
        return nextExpiration
    }

}

private struct CommandTabPreviewView: View {
    static let coordinateSpaceName = "CommandTabPreview"

    @ObservedObject var model: CommandTabOverlayModel

    var body: some View {
        ZStack {
            if let item = model.selectedItem {
                previewCard(item)
                    .id(item.id)
                    .transition(
                        model.reduceMotion
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 0.97))
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            model.reduceMotion ? nil : .easeOut(duration: 0.14),
            value: model.selectedID
        )
    }

    private func previewCard(_ item: CommandTabDisplayItem) -> some View {
        VStack(spacing: 8) {
            Text(item.appName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if item.windows.isEmpty {
                ZStack {
                    Color.black.opacity(0.16)
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 58, height: 58)
                            .opacity(0.90)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(item.isLoading ? "正在读取窗口预览…" : "没有可预览的窗口")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if item.windows.count == 1, let window = item.windows.first {
                windowTile(item: item, window: window)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 10) {
                            ForEach(item.windows) { window in
                                windowTile(item: item, window: window)
                                    .id(window.id)
                            }
                        }
                        .padding(.horizontal, 1)
                        .padding(.bottom, 2)
                    }
                    .onAppear {
                        scrollSelectedWindow(item: item, proxy: proxy)
                    }
                    .onChange(of: selectedWindowID(in: item)) { _, _ in
                        scrollSelectedWindow(item: item, proxy: proxy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.10))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }

    private func windowTile(
        item: CommandTabDisplayItem,
        window: CommandTabWindowDisplayItem
    ) -> some View {
        let target = CommandTabPreviewTarget(
            applicationIndex: item.id,
            windowIndex: window.id,
            identity: window.identity
        )
        return CommandTabWindowPreviewTile(
            target: target,
            window: window,
            icon: item.icon,
            width: model.previewTileWidth,
            isPointerHovered: model.pointerHoveredTarget == target,
            onCommit: {
                guard model.isCurrent(target), window.canActivate else { return }
                model.onCommitWindow(item.id, window.id)
            },
            onClose: {
                guard model.isCurrent(target), window.canClose else { return }
                model.onCloseWindow(item.id, window.id)
            },
            onFrameChange: { target, frame in
                model.setPreviewFrame(frame, for: target)
            }
        )
    }

    private func selectedWindowID(in item: CommandTabDisplayItem) -> Int? {
        item.windows.first(where: \.isSelected)?.id
    }

    private func scrollSelectedWindow(
        item: CommandTabDisplayItem,
        proxy: ScrollViewProxy
    ) {
        guard model.pointerHoveredTarget == nil,
              let selectedWindowID = selectedWindowID(in: item) else { return }
        DispatchQueue.main.async {
            guard model.pointerHoveredTarget == nil else { return }
            if model.reduceMotion {
                proxy.scrollTo(selectedWindowID, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    proxy.scrollTo(selectedWindowID, anchor: .center)
                }
            }
        }
    }
}

private struct CommandTabWindowPreviewTile: View {
    let target: CommandTabPreviewTarget
    let window: CommandTabWindowDisplayItem
    let icon: NSImage?
    let width: CGFloat
    let isPointerHovered: Bool
    let onCommit: () -> Void
    let onClose: () -> Void
    let onFrameChange: (CommandTabPreviewTarget, CGRect?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onCommit) {
                VStack(spacing: 5) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(isPointerHovered || window.isSelected ? 0.24 : 0.16))

                        previewContent
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isPointerHovered || window.isSelected
                                    ? Color.accentColor.opacity(0.92)
                                    : Color.white.opacity(0.12),
                                lineWidth: isPointerHovered || window.isSelected ? 2 : 0.75
                            )
                            .allowsHitTesting(false)
                    )
                    .frame(maxHeight: .infinity)
                    .frame(width: width)

                    Text(window.title.isEmpty ? "未命名窗口" : window.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: width)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!window.canActivate)

            if isPointerHovered, window.canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.68), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(5)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .background(
            WindowPreviewFrameReporter(
                target: target,
                onChange: onFrameChange
            )
        )
    }

    @ViewBuilder
    private var previewContent: some View {
        if let result = window.thumbnailResult {
            switch result {
            case let .fresh(image):
                thumbnailImage(image)
            case let .recentCache(image, timestamp):
                ZStack(alignment: .topTrailing) {
                    thumbnailImage(image)
                    Text(recentPreviewLabel(timestamp: timestamp))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.68), in: Capsule())
                        .padding(6)
                }
            case .permissionRequired:
                previewFailure(
                    title: "需要屏幕录制权限",
                    symbol: "record.circle"
                )
            case .restartRequired:
                previewFailure(
                    title: "重启 SuperIsland 后显示",
                    symbol: "arrow.clockwise"
                )
            case .notEnumerated:
                previewFailure(
                    title: "全屏预览暂不可用",
                    symbol: "rectangle.on.rectangle"
                )
            case .ambiguous:
                previewFailure(
                    title: "无法唯一匹配窗口",
                    symbol: "questionmark.square"
                )
            case .captureFailed:
                previewFailure(
                    title: "窗口预览暂不可用",
                    symbol: "exclamationmark.triangle"
                )
            }
        } else {
            VStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在生成预览")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func thumbnailImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(4)
    }

    private func previewFailure(title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .opacity(window.isMinimized ? 0.56 : 0.72)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private func recentPreviewLabel(timestamp: Date) -> String {
        let age = max(0, Int(Date().timeIntervalSince(timestamp)))
        return age < 2 ? "最近预览" : "最近 · \(age)秒"
    }
}
