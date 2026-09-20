import AppKit
import ApplicationServices
import Darwin
import OSLog
import SwiftUI

enum WindowCommandTabEventTapFactory {
    /// Resource creation must run once per attempted location. A lazy
    /// compactMap followed by first can evaluate a successful transform twice,
    /// leaving the first WindowServer tap without an owner or run-loop source.
    static func firstAvailable<Tap>(
        at locations: [CGEventTapLocation],
        create: (CGEventTapLocation) -> Tap?
    ) -> (tap: Tap, location: CGEventTapLocation)? {
        for location in locations {
            if let tap = create(location) {
                return (tap, location)
            }
        }
        return nil
    }
}

/// Reuse the bounded, gap-reporting writer in a separate stream. The sampled
/// interaction log deliberately drops bursts and cannot diagnose input edges.
private enum WindowCommandTabDiagnostics {
    static let enabled: Bool = {
#if DEBUG
        WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier)
#else
        false
#endif
    }()
    static let recorder = WindowLifecycleDiagnosticRecorder(
        fileURL: WindowLifecycleDiagnosticRecorder.diagnosticFileURL?
            .deletingLastPathComponent().appendingPathComponent("cmdtab-input.jsonl")
    )

    static func keyStates() -> [String: WindowInteractionDiagnosticValue] {
        [
            "hidCommand": .flag(CGEventSource.keyState(.hidSystemState, key: 55)
                || CGEventSource.keyState(.hidSystemState, key: 54)),
            "combinedCommand": .flag(CGEventSource.keyState(.combinedSessionState, key: 55)
                || CGEventSource.keyState(.combinedSessionState, key: 54)),
            "hidTab": .flag(CGEventSource.keyState(.hidSystemState, key: 48)),
            "combinedTab": .flag(CGEventSource.keyState(.combinedSessionState, key: 48))
        ]
    }

    static func measure<Value>(_ operation: String, sequence: Int, _ body: () -> Value) -> Value {
        guard enabled else { return body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let identity: [String: WindowInteractionDiagnosticValue] = [
            "spanNS": .integer(Int64(clamping: start)),
            "sequence": .integer(Int64(clamping: sequence))
        ]
        recorder.record(event: operation + "Begin", metadata: identity)
        defer {
            var metadata = identity.merging(keyStates()) { first, _ in first }
            metadata["durationNS"] = .integer(Int64(clamping: DispatchTime.now().uptimeNanoseconds - start))
            recorder.record(event: operation + "End", metadata: metadata)
        }
        return body()
    }

    static func addFrame(_ frame: CGRect, prefix: String, to metadata: inout [String: WindowInteractionDiagnosticValue]) {
        // AX coordinates are untrusted. Never let diagnostic integer conversion
        // trap or change the window operation being observed.
        for (suffix, value) in [("X", frame.minX), ("Y", frame.minY), ("W", frame.width), ("H", frame.height)] {
            guard value.isFinite, abs(value) < 1_000_000_000 else { continue }
            metadata[prefix + suffix] = .integer(Int64(value.rounded()))
        }
    }
}

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
        isVisible: Bool?,
        hasDocument: Bool = false
    ) -> Bool {
        // AppKit can report a minimized document as AXDialog. Preserve that
        // real AX object only with explicit document/nonmodal evidence; the
        // reconciler still requires its exact WindowServer ID and owner.
        let isMinimizedDocument = subrole == kAXDialogSubrole as String
            && isMinimized && isModal == false && hasDocument
        guard role == kAXWindowRole as String,
              subrole == kAXStandardWindowSubrole as String || isMinimizedDocument,
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

private func weChatSharingApplication(_ application: NSRunningApplication) -> WindowCommandTabSharingPolicy.Application {
    WindowCommandTabSharingPolicy.Application(
        processID: application.processIdentifier,
        bundlePath: application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path,
        bundleIdentifier: application.bundleIdentifier
    )
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
    private let zilanPointerInteraction: ZilanEventTapInteractionState
    private var nativePointerClickCaptured: Bool { zilanPointerInteraction.isCapturing }
    private var nativePointerReleaseCleanup: DispatchWorkItem?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRetryTask: Task<Void, Never>?
    private var eventTapInstallAttempts = 0
    private var reportedEventTapFailure = false
    private var accessibilityTrustRetryTask: Task<Void, Never>?
    private var accessibilityTrustRetryAttempt = 0
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var previewInvalidationObserver: NSObjectProtocol?
    private var windowRetirementObserver: NSObjectProtocol?
    private var thumbnailCaptureTask: Task<Void, Never>?
    private var sharedPreviewFallbackTask: Task<Void, Never>?
    private var postCloseRefreshTask: Task<Void, Never>?
    private var closeWindowRetryTask: Task<Void, Never>?
    private var selectedApplicationRefreshTask: Task<Void, Never>?
    private var concreteWindowActivationTask: Task<Void, Never>?
    private var nativeWindowCommit = WindowCommandTabCommitCoordinator()
    private var nativeWindowCommitTask: Task<Void, Never>?
    private var nativeSessionReconciliationTask: Task<Void, Never>?
    private var nativeSessionReconciliationGeneration: UInt64 = 0
    private var nativeClick = WindowCommandTabNativeClickCoordinator()
    private var nativeClickReleaseWatchTask: Task<Void, Never>?
    private var nativePreviewRefreshPending = false
    private var nativeSelectionPending = false
    private var nativeSwitcherSyncTask: Task<Void, Never>?
    private var nativePointerSyncWorkItem: DispatchWorkItem?
    private var nativePointerEventTap: CFMachPort?
    private var lastPointerDiagnosticTime: TimeInterval = 0
    private var nativePointerRunLoopSource: CFRunLoopSource?
    private var pendingNativePointerLocation: CGPoint?
    private var loggedNativePointerActivity = false
    private var thumbnailCaptureGeneration = 0
    private var currentThumbnailResults: [WindowThumbnailResult?] = []
    private var previewOnlyWindows: [CommandTabWindowDisplayItem] = []
    private var previewLoading = false
    private var nativeSwitcherAnchorFrame: CGRect?
    private var nativeCommitContext: NativeProcessSwitcherBridge.CommitContext?
    private var hasExplicitWindowSelection = false
    private var reportedAccessibilityUnavailable = false
    private struct PrewarmJob: Sendable {
        let applicationIdentity: WindowThumbnailApplicationIdentity
        let requests: [WindowThumbnailRequest]
        let lifecycleRevision: WindowAXLifecycleRevision?
        let cacheGeneration: WindowThumbnailCaptureGeneration
    }

    /// Prewarming is intentionally serialized. Starting one ScreenCaptureKit
    /// enumeration per visible App at launch can retain hundreds of decoded
    /// window images at once and overwhelm WindowServer before Cmd-Tab is ever
    /// used. The active App is still refreshed on every activation, while a
    /// small MRU seed keeps inactive-fullscreen previews useful after launch.
    private var pendingPrewarmJobs: [pid_t: PrewarmJob] = [:]
    private var pendingPrewarmOrder: [pid_t] = []
    private var activePrewarmPID: pid_t?
    private var activePrewarmLifetimeKey: String?
    private var activePrewarmRevision: WindowAXLifecycleRevision?
    private var prewarmGeneration: UInt64 = 0
    private var activePrewarmTask: Task<Void, Never>?
    private var candidates: [Candidate] = []
    private var candidateLifecycleRevisions: [String: WindowAXLifecycleRevision] = [:]
    private var selectedIndex = 0
    private var selectedWindowIndex = 0
    private var isPresenting = false
    private var commandSequenceActive = false
    private var eventSequenceID = 0
    private var diagnosticCallbackID: Int64 = 0
    private var queuedEventActions: [QueuedEventAction] = []
    private var eventActionDrainTask: Task<Void, Never>?
    private var eventActionGeneration = 0

    private enum QueuedEventAction {
        case syncNativeSelection(sequenceID: Int)
        case moveWindowSelection(reverse: Bool, sequenceID: Int)
        case selectWindow(index: Int, sequenceID: Int)
        case commitWindow(target: WindowActionTarget, sequenceID: Int)
        case closeWindow(target: WindowActionTarget, sequenceID: Int)
        case closeSelectedWindow(sequenceID: Int)
        case quitSelectedApplication(sequenceID: Int)
        case finish(sequenceID: Int)

        var sequenceID: Int {
            switch self {
            case let .syncNativeSelection(sequenceID),
                 let .moveWindowSelection(_, sequenceID),
                 let .selectWindow(_, sequenceID),
                 let .commitWindow(_, sequenceID),
                 let .closeWindow(_, sequenceID),
                 let .closeSelectedWindow(sequenceID),
                 let .quitSelectedApplication(sequenceID),
                 let .finish(sequenceID):
                sequenceID
            }
        }
    }

    private struct WindowCandidate {
        let application: NSRunningApplication
        let element: AXUIElement?
        let title: String
        let bounds: CGRect?
        let windowID: CGWindowID?
        let isMinimized: Bool
        let isPreferredWindow: Bool
        let canClose: Bool
        var allowsUniformContent = false
    }

    private struct WindowActionTarget {
        let window: WindowCandidate
        let applicationIdentity: WindowThumbnailApplicationIdentity
    }

    private struct Candidate {
        let applications: [NSRunningApplication]
        let windows: [WindowCandidate]
        var isSharedWeChat = false

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

    init(zilanPointerInteraction: ZilanEventTapInteractionState = ZilanEventTapInteractionState()) {
        self.zilanPointerInteraction = zilanPointerInteraction
    }

    func beginZilanSuppression(requestID: String) -> Bool {
        // Do not split an existing keyboard sequence or its queued completion.
        // These fields and both callbacks are confined to the main run loop.
        guard !commandSequenceActive, !isPresenting, queuedEventActions.isEmpty,
              eventActionDrainTask == nil, nativeSwitcherSyncTask == nil,
              nativePointerSyncWorkItem == nil, !nativeWindowCommit.isPending else { return false }
        return zilanPointerInteraction.beginSuppression(requestID: requestID)
    }

    func endZilanSuppression(requestID: String) {
        zilanPointerInteraction.endSuppression(requestID: requestID)
    }

    func start() {
        if WindowCommandTabDiagnostics.enabled {
            // Warm the destination and writer before any input callback. This
            // also states the capture boundary in every new diagnostic session.
            WindowCommandTabDiagnostics.recorder.record(event: "monitorStart", metadata: [
                "tabDownObserved": .flag(true), "tabUpObserved": .flag(false),
                "commandFlagsObserved": .flag(true), "newInputTap": .flag(false)
            ])
        }
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
        WindowThumbnailProvider.clearAllCache(reason: .commandTabStopped)
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
        if let previewInvalidationObserver {
            NotificationCenter.default.removeObserver(previewInvalidationObserver)
            self.previewInvalidationObserver = nil
        }
        if let windowRetirementObserver {
            NotificationCenter.default.removeObserver(windowRetirementObserver)
            self.windowRetirementObserver = nil
        }
    }

    func updateEnabledState() {
        let anyPreviewEnabled = preferences.isEnabled && (
            preferences.cmdTabPlusEnabled || preferences.dockPreviewEnabled
        )
        if !anyPreviewEnabled {
            cancelPrewarmTasks()
            WindowThumbnailProvider.clearAllCache(reason: .commandTabAllPreviewsDisabled)
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
                preferences.publishFeedback("Cmd-Tab 未启动，请检查辅助功能权限并重启 WE1")
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
        let installation = WindowCommandTabEventTapFactory.firstAvailable(at: locations) { location in
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.eventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }

        guard let installation else {
            eventTapInstallationFailed()
            return
        }
        let tap = installation.tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            eventTapInstallationFailed()
            return
        }
        eventTap = tap
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
        logger.info("Cmd-Tab event tap installed at location \(String(describing: installation.location), privacy: .public)")
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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
    }

    private func eventTapInstallationFailed() {
        eventTapInstallAttempts += 1
        logger.error("Cmd-Tab event tap installation failed (attempt \(self.eventTapInstallAttempts, privacy: .public))")

        if !reportedEventTapFailure {
            reportedEventTapFailure = true
            preferences.publishFeedback("Cmd-Tab 未启动，请检查辅助功能权限并重启 WE1")
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
        guard WindowCommandTabDiagnostics.enabled else { return processEvent(type: type, event: event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // Do not gate on Command flags or session state: a malformed Tab or a
        // Command-up arriving after cancel is precisely the missing evidence.
        let relevant = (type == .keyDown && key == 48)
            || (type == .flagsChanged && (key == 54 || key == 55))
            || type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        guard relevant else { return processEvent(type: type, event: event) }
        let start = DispatchTime.now().uptimeNanoseconds
        diagnosticCallbackID &+= 1
        let callbackID = diagnosticCallbackID
        var metadata = WindowCommandTabDiagnostics.keyStates()
        metadata["callback"] = .integer(callbackID)
        metadata["callbackNS"] = .integer(Int64(clamping: start))
        metadata["eventNS"] = .integer(Int64(clamping: event.timestamp))
        metadata["sequence"] = .integer(Int64(clamping: eventSequenceID))
        metadata["active"] = .flag(commandSequenceActive)
        metadata["type"] = .integer(Int64(type.rawValue))
        metadata["key"] = .integer(key)
        metadata["eventCommand"] = .flag(event.flags.contains(.maskCommand))
        metadata["repeat"] = .integer(event.getIntegerValueField(.keyboardEventAutorepeat))
        metadata["sourcePID"] = .integer(event.getIntegerValueField(.eventSourceUnixProcessID))
        metadata["sourceState"] = .integer(event.getIntegerValueField(.eventSourceStateID))
        metadata["ownCommit"] = .flag(event.getIntegerValueField(.eventSourceUserData)
            == NativeProcessSwitcherBridge.sharedCommitEventMarker)
        WindowCommandTabDiagnostics.recorder.record(event: "keyboardEnter", metadata: metadata)
        let result = processEvent(type: type, event: event)
        var outcome = WindowCommandTabDiagnostics.keyStates()
        outcome["callback"] = .integer(callbackID)
        outcome["durationNS"] = .integer(Int64(clamping: DispatchTime.now().uptimeNanoseconds - start))
        outcome["sequence"] = .integer(Int64(clamping: eventSequenceID))
        outcome["active"] = .flag(commandSequenceActive)
        outcome["presenting"] = .flag(isPresenting)
        outcome["suppressed"] = .flag(zilanPointerInteraction.isSuppressed)
        outcome["passed"] = .flag(result != nil)
        WindowCommandTabDiagnostics.recorder.record(event: "keyboardExit", metadata: outcome)
        return result
    }

    private func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("Cmd-Tab event tap was disabled by the system (type \(type.rawValue, privacy: .public)); re-enabling")
            reenableTap()
            // AX work cannot run inside a disabled tap callback. Stop stale
            // actions immediately, then reconcile the original native list.
            abortNativeWindowCommit(reason: "keyboardTapDisabled", reconcile: false)
            cancelQueuedEventActions()
            concreteWindowActivationTask?.cancel()
            concreteWindowActivationTask = nil
            hasExplicitWindowSelection = false
            nativeSelectionPending = true
            overlay.clearPointerSelection()
            scheduleNativeSessionReconciliation(reason: "keyboardTapDisabled")
            return Unmanaged.passUnretained(event)
        }

        guard !zilanPointerInteraction.isSuppressed else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == NativeProcessSwitcherBridge.sharedCommitEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            // New keyboard intent supersedes an already released native click.
            // Do not leave its cancelled readback holding previews indefinitely.
            if nativeClick.resumeForKeyboardInput(buttonPressed: Self.nativeLeftButtonPressed) {
                nativeClickReleaseWatchTask?.cancel()
                nativeClickReleaseWatchTask = nil
                overlay.setNativeClickSuspended(false)
                // Clearing the pause alone leaves nativeSelectionPending set.
                // Every new keyboard intent needs a fresh native selection,
                // including extension keys that do not normally schedule one.
                enqueueEventAction(.syncNativeSelection(sequenceID: eventSequenceID))
            }
            cancelNativeSessionReconciliation()
            abortNativeWindowCommit(reason: "newKeyDown", reconcile: false)
            concreteWindowActivationTask?.cancel()
            concreteWindowActivationTask = nil
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if keyCode != 53, !event.flags.contains(.maskCommand),
               commandSequenceActive || isPresenting {
                // A lost Command-up or a failed native dismissal must never
                // turn the next ordinary arrow/number key into a WE1 action.
                hasExplicitWindowSelection = false
                scheduleNativeSessionReconciliation(reason: "keyWithoutCommand")
                return Unmanaged.passUnretained(event)
            }

            if keyCode == 48, event.flags.contains(.maskCommand) {
                nativeSelectionPending = true
                hasExplicitWindowSelection = false
                concreteWindowActivationTask?.cancel()
                concreteWindowActivationTask = nil
                if !commandSequenceActive {
                    logger.debug("Observed a new native Cmd-Tab sequence")
                    commandSequenceActive = true
                    hasExplicitWindowSelection = false
                    loggedNativePointerActivity = false
                    nativeSwitcher.reset()
                    eventSequenceID &+= 1
                    WindowInteractionDiagnosticRecorder.shared.record(
                        component: "cmdTab", event: "sequenceStart",
                        metadata: ["sequence": .integer(Int64(clamping: eventSequenceID))]
                    )
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
                    nativeSelectionPending = true
                    hasExplicitWindowSelection = false
                    let sequenceID = eventSequenceID
                    enqueueEventAction(.syncNativeSelection(sequenceID: sequenceID))
                    return Unmanaged.passUnretained(event)
                case 124: // Right arrow
                    nativeSelectionPending = true
                    hasExplicitWindowSelection = false
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
            if nativeWindowCommit.markCommandReleased() {
                return Unmanaged.passUnretained(event)
            }
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
                hasExplicitWindowSelection = false
                scheduleNativeSwitcherSync()
            case let .moveWindowSelection(reverse, _):
                moveWindowSelection(reverse: reverse)
            case let .selectWindow(index, _):
                selectWindow(index: index)
            case let .commitWindow(target, _):
                if let location = location(of: target) {
                    commit(applicationIndex: location.application, windowIndex: location.window)
                }
            case let .closeWindow(target, _):
                if let location = location(of: target) {
                    closeWindow(applicationIndex: location.application, windowIndex: location.window)
                }
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
        guard !nativeWindowCommit.isPending else {
            nativeWindowCommit.markCommandReleased()
            return
        }
        let explicitSelection: (Candidate, WindowCandidate)? = {
            guard !nativePointerClickCaptured, !nativeSelectionPending,
                  hasExplicitWindowSelection,
                  isPresenting,
                  candidates.indices.contains(selectedIndex),
                  candidates[selectedIndex].windows.indices.contains(selectedWindowIndex),
                  candidates[selectedIndex].windows[selectedWindowIndex].element != nil else {
                return nil
            }
            return (
                candidates[selectedIndex],
                candidates[selectedIndex].windows[selectedWindowIndex]
            )
        }()
        if let explicitSelection, explicitSelection.0.isSharedWeChat {
            commitNativeWindow(candidate: explicitSelection.0, window: explicitSelection.1)
            return
        }
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
        guard !zilanPointerInteraction.isSuppressed,
              !nativeClick.blocksPreviewUpdates else { return }
        // Both callers run after the input callback has returned. Creating a
        // system event tap inside Tab-down can hold up delivery to Dock. Only
        // install here if the deferred action still belongs to a live session.
        installNativePointerTapIfNeeded()
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
                      !self.nativeClick.blocksPreviewUpdates,
                      self.eventSequenceID == sequenceID else { return }
                switch WindowCommandTabDiagnostics.measure("nativeSnapshot", sequence: sequenceID, {
                    self.nativeSwitcher.snapshot()
                }) {
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
            WindowInteractionDiagnosticRecorder.shared.record(
                component: "cmdTab", event: "selectionUnavailable",
                metadata: [
                    "sequence": .integer(Int64(clamping: sequenceID)),
                    "ambiguous": .flag(sawAmbiguousSelection)
                ]
            )
            self.overlay.hide()
            self.isPresenting = false
            self.candidates.removeAll(keepingCapacity: false)
        }
    }

    private func applyNativeSwitcherSnapshot(
        _ snapshot: NativeProcessSwitcherBridge.Snapshot
    ) {
        guard !nativeClick.blocksPreviewUpdates else { return }
        if WindowCommandTabDiagnostics.enabled {
            var metadata = WindowCommandTabDiagnostics.keyStates()
            metadata["sequence"] = .integer(Int64(clamping: eventSequenceID))
            metadata["ownerPID"] = .integer(Int64(snapshot.applications.first?.processIdentifier ?? 0))
            metadata["hasItemFrame"] = .flag(snapshot.selectedItemFrame != nil)
            WindowCommandTabDiagnostics.addFrame(snapshot.listFrame, prefix: "listAX", to: &metadata)
            if let frame = snapshot.selectedItemFrame {
                WindowCommandTabDiagnostics.addFrame(frame, prefix: "itemAX", to: &metadata)
            }
            WindowCommandTabDiagnostics.recorder.record(event: "nativePlacement", metadata: metadata)
        }
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
        WindowInteractionDiagnosticRecorder.shared.record(
            component: "cmdTab", event: "selectionResolved",
            metadata: [
                "sequence": .integer(Int64(clamping: eventSequenceID)),
                "processCount": .integer(Int64(processIdentifiers.count)),
                "firstPID": .integer(Int64(processIdentifiers.first ?? 0)),
                "sharedWeChat": .flag(snapshot.isSharedWeChat),
                "hasCommitContext": .flag(snapshot.commitContext != nil)
            ]
        )
        let didChangeApplication = candidates.first?.processIdentifiers != processIdentifiers
            || candidates.first?.isSharedWeChat != snapshot.isSharedWeChat
        let nextAnchorFrame = snapshot.selectedItemFrame ?? snapshot.listFrame
        let didChangeAnchor = nativeSwitcherAnchorFrame != nextAnchorFrame
        if snapshot.isSharedWeChat && didChangeAnchor { hasExplicitWindowSelection = false }
        nativeCommitContext = snapshot.commitContext
        nativeSelectionPending = false
        let needsResumeRefresh = nativePreviewRefreshPending
        nativePreviewRefreshPending = false
        if !didChangeApplication,
           !didChangeAnchor,
           !needsResumeRefresh,
           isPresenting {
            return
        }
        let windows = WindowCommandTabDiagnostics.measure("selectedWindows", sequence: eventSequenceID) {
            didChangeApplication
                ? windowCandidates(for: applications)
                : (candidates.first?.windows ?? windowCandidates(for: applications))
        }
        candidates = [Candidate(applications: applications, windows: windows, isSharedWeChat: snapshot.isSharedWeChat)]
        if didChangeApplication {
            candidateLifecycleRevisions.removeAll()
            recordLifecycleRevisions(for: applications)
        }
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
        } else if needsResumeRefresh {
            renderOverlay(preservingThumbnails: currentThumbnailResults)
        } else {
            presentOverlay(thumbnails: currentThumbnailResults, for: selectedIndex)
        }
    }

    private func scheduleNativePointerSync() {
        guard commandSequenceActive,
              !nativeClick.blocksPreviewUpdates,
              preferences.isEnabled,
              preferences.cmdTabPlusEnabled,
              nativePointerSyncWorkItem == nil else { return }
        let sequenceID = eventSequenceID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.nativePointerSyncWorkItem = nil
            guard self.commandSequenceActive,
                  !self.nativeClick.blocksPreviewUpdates,
                  self.eventSequenceID == sequenceID else { return }
            // Dock does not update AXSelected/AXFocused when the pointer merely
            // hovers a native Cmd-Tab tile. Query the actual global pointer and
            // hit-test Dock's Process Switcher instead of re-reading the
            // keyboard selection. This stays coalesced by one 20ms
            // work item and does not add polling.
            guard let pointer = self.pendingNativePointerLocation
                    ?? CGEvent(source: nil)?.location else { return }
            self.pendingNativePointerLocation = nil
            if case let .visible(snapshot) = WindowCommandTabDiagnostics.measure("pointerSnapshot", sequence: sequenceID, {
                self.nativeSwitcher.snapshot(at: pointer)
            }) {
                self.applyNativeSwitcherSnapshot(snapshot)
            }
        }
        nativePointerSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020, execute: workItem)
    }

    /// Observe native switcher pointer movement independently of the custom
    /// preview panel. The tap exists only during a Command sequence (plus a
    /// bounded paired-release drain); only clicks begun in our panel are
    /// consumed. All native AX hit-testing remains coalesced to 20 ms.
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
        let installation = WindowCommandTabEventTapFactory.firstAvailable(at: locations) { location in
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.nativePointerEventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard let installation else {
            logger.error("Native Cmd-Tab pointer event tap could not be installed")
            WindowInteractionDiagnosticRecorder.shared.record(
                component: "cmdTab", event: "pointerTapInstall", metadata: ["installed": .flag(false)]
            )
            return
        }
        let tap = installation.tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.error("Native Cmd-Tab pointer run-loop source could not be created")
            WindowInteractionDiagnosticRecorder.shared.record(
                component: "cmdTab", event: "pointerTapInstall", metadata: ["installed": .flag(false)]
            )
            return
        }
        nativePointerEventTap = tap
        nativePointerRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let installed = CGEvent.tapIsEnabled(tap: tap)
        if !installed { removeNativePointerTap(force: true) }
        WindowInteractionDiagnosticRecorder.shared.record(
            component: "cmdTab", event: "pointerTapInstall", metadata: ["installed": .flag(installed)]
        )
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
        guard WindowCommandTabDiagnostics.enabled else { return processNativePointerEvent(type: type, event: event) }
        let relevant = ProcessInfo.processInfo.systemUptime - lastPointerDiagnosticTime >= 0.5
            || type == .leftMouseDown || type == .leftMouseUp
            || type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        guard relevant else { return processNativePointerEvent(type: type, event: event) }
        let start = DispatchTime.now().uptimeNanoseconds
        diagnosticCallbackID &+= 1
        let callbackID = diagnosticCallbackID
        var metadata = WindowCommandTabDiagnostics.keyStates()
        metadata["callback"] = .integer(callbackID)
        metadata["callbackNS"] = .integer(Int64(clamping: start))
        metadata["eventNS"] = .integer(Int64(clamping: event.timestamp))
        metadata["sequence"] = .integer(Int64(clamping: eventSequenceID))
        metadata["type"] = .integer(Int64(type.rawValue))
        metadata["active"] = .flag(commandSequenceActive)
        WindowCommandTabDiagnostics.recorder.record(event: "pointerEnter", metadata: metadata)
        let captured = processNativePointerEvent(type: type, event: event)
        var outcome = WindowCommandTabDiagnostics.keyStates()
        outcome["callback"] = .integer(callbackID)
        outcome["durationNS"] = .integer(Int64(clamping: DispatchTime.now().uptimeNanoseconds - start))
        outcome["sequence"] = .integer(Int64(clamping: eventSequenceID))
        outcome["active"] = .flag(commandSequenceActive)
        outcome["captured"] = .flag(captured)
        WindowCommandTabDiagnostics.recorder.record(event: "pointerExit", metadata: outcome)
        return captured
    }

    private func processNativePointerEvent(type: CGEventType, event: CGEvent) -> Bool {
        if WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPointerDiagnosticTime >= 0.5 {
                lastPointerDiagnosticTime = now
                WindowInteractionDiagnosticRecorder.shared.record(
                    component: "cmdTab", event: "pointerTap",
                    metadata: [
                        "eventType": .integer(Int64(type.rawValue)),
                        "sequenceActive": .flag(commandSequenceActive),
                        "suppressed": .flag(zilanPointerInteraction.isSuppressed),
                        "insidePanel": .flag(overlay.containsPointer(NSEvent.mouseLocation))
                    ]
                )
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            overlay.clearPointerSelection()
            if let nativePointerEventTap { CGEvent.tapEnable(tap: nativePointerEventTap, enable: true) }
            abortNativeWindowCommit(reason: "pointerTapDisabled", reconcile: false)
            cancelQueuedEventActions()
            hasExplicitWindowSelection = false
            scheduleNativeSessionReconciliation(reason: "pointerTapDisabled")
            return false
        }
        guard !zilanPointerInteraction.isSuppressed else { return false }
        if type == .leftMouseDown {
            cancelNativeSessionReconciliation()
            abortNativeWindowCommit(reason: "newPointerDown", reconcile: false)
            if (nativeClick.blocksPreviewUpdates || !overlay.containsPointer(NSEvent.mouseLocation)),
               commandSequenceActive || isPresenting {
                beginNativeClick()
                return false
            }
        }
        // Consume both halves only for a click that began in our visible
        // panel. A listen-only release used to race Dock's own selection and
        // dismiss the preview before the specific window action ran.
        if type == .leftMouseUp, nativePointerClickCaptured {
            zilanPointerInteraction.endCapture()
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
        if type == .leftMouseUp, commandSequenceActive || isPresenting {
            if nativeClick.blocksPreviewUpdates {
                releaseNativeClick(reason: "outsidePointerUp")
            } else {
                scheduleNativeSessionReconciliation(reason: "outsidePointerUp")
            }
        }
        // A gesture begun on the native strip stays native even when dragged
        // into our panel. No hover, async publication or new capture may race
        // Dock while it finishes that click.
        guard !nativeClick.blocksPreviewUpdates else { return false }
        guard commandSequenceActive else { return false }
        if type == .leftMouseDown, overlay.containsPointer(NSEvent.mouseLocation) {
            guard zilanPointerInteraction.beginCapture() else { return false }
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

    private static var nativeLeftButtonPressed: Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    private func beginNativeClick() {
        let ticket = nativeClick.begin(sequenceID: eventSequenceID)
        nativeClickReleaseWatchTask?.cancel()
        cancelQueuedEventActions()
        nativeSwitcherSyncTask?.cancel()
        nativeSwitcherSyncTask = nil
        nativePointerSyncWorkItem?.cancel()
        nativePointerSyncWorkItem = nil
        pendingNativePointerLocation = nil
        nativeSelectionPending = true
        hasExplicitWindowSelection = false
        nativePreviewRefreshPending = true
        overlay.setNativeClickSuspended(true)
        recordNativeClick("nativeClickBegin")
        // Recovery only for the lifetime of this press. A missing mouseUp or
        // disabled tap must not freeze previews forever, and a held button
        // must never be released merely because a fixed timeout elapsed.
        nativeClickReleaseWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
                guard let self, !Task.isCancelled,
                      self.nativeClick.pending == ticket,
                      self.eventSequenceID == ticket.sequenceID,
                      !self.nativeClick.hasReleased else { return }
                if !Self.nativeLeftButtonPressed {
                    self.releaseNativeClick(reason: "nativeClickPhysicalRelease")
                    return
                }
            }
        }
    }

    private func releaseNativeClick(reason: String) {
        guard nativeClick.markReleased(sequenceID: eventSequenceID) != nil else { return }
        nativeClickReleaseWatchTask?.cancel()
        nativeClickReleaseWatchTask = nil
        recordNativeClick("nativeClickReleased")
        scheduleNativeSessionReconciliation(reason: reason)
    }

    private func invalidateNativeClick() {
        nativeClickReleaseWatchTask?.cancel()
        nativeClickReleaseWatchTask = nil
        nativeClick.invalidate()
        overlay.setNativeClickSuspended(false)
    }

    private func recordNativeClick(_ event: String) {
        guard WindowCommandTabDiagnostics.enabled else { return }
        var metadata = WindowCommandTabDiagnostics.keyStates()
        metadata["sequence"] = .integer(Int64(clamping: eventSequenceID))
        metadata["blocked"] = .flag(nativeClick.blocksPreviewUpdates)
        metadata["released"] = .flag(nativeClick.hasReleased)
        metadata["leftPressed"] = .flag(Self.nativeLeftButtonPressed)
        WindowCommandTabDiagnostics.recorder.record(event: event, metadata: metadata)
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
        zilanPointerInteraction.endCapture()
        if let nativePointerEventTap {
            CGEvent.tapEnable(tap: nativePointerEventTap, enable: false)
        }
        if let nativePointerRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                nativePointerRunLoopSource,
                .commonModes
            )
            CFRunLoopSourceInvalidate(nativePointerRunLoopSource)
        }
        if let nativePointerEventTap { CFMachPortInvalidate(nativePointerEventTap) }
        nativePointerRunLoopSource = nil
        nativePointerEventTap = nil
        pendingNativePointerLocation = nil
        loggedNativePointerActivity = false
    }

    private func moveWindowSelection(reverse: Bool) {
        guard !nativeClick.blocksPreviewUpdates, isPresenting, !nativeSelectionPending,
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
        guard !nativeClick.blocksPreviewUpdates, isPresenting, !nativeSelectionPending,
              candidates.indices.contains(selectedIndex),
              candidates[selectedIndex].windows.indices.contains(index) else { return }
        overlay.clearPointerSelection()
        selectedWindowIndex = index
        hasExplicitWindowSelection = true
        presentOverlay(thumbnails: currentThumbnailResults, for: selectedIndex)
    }

    private func renderOverlay(
        retryMissingWindows: Bool = true,
        preservingThumbnails: [WindowThumbnailResult?]? = nil,
        continuingRecovery: Bool = false
    ) {
        guard !nativeClick.blocksPreviewUpdates,
              isPresenting, candidates.indices.contains(selectedIndex) else { return }
        let renderStartedAt = ProcessInfo.processInfo.systemUptime
        if !continuingRecovery {
            selectedApplicationRefreshTask?.cancel()
            selectedApplicationRefreshTask = nil
        }
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        sharedPreviewFallbackTask?.cancel()
        sharedPreviewFallbackTask = nil
        thumbnailCaptureGeneration &+= 1

        let now = Date()
        let retainedThumbnails = preservingThumbnails?.map { result -> WindowThumbnailResult? in
            if case let .some(.recentCache(_, timestamp)) = result,
               timestamp.addingTimeInterval(WindowThumbnailProvider.recentCacheTTL) <= now { return nil }
            return result
        }
        currentThumbnailResults = retainedThumbnails ?? []
        previewOnlyWindows = []
        previewLoading = retainedThumbnails == nil
        // Updating to an empty loading model clears the previous target's
        // identities and pointer state without hiding and reopening the panel.
        // AX-less helpers keep this state until their original discovery path
        // produces independently validated windows.
        // An operation recovery keeps the current exact-ID pixels visible.
        // Only an ordinary selection starts with an empty loading model.
        presentOverlay(thumbnails: currentThumbnailResults, for: selectedIndex)

        let selectedWindows = candidates[selectedIndex].windows
        if candidates[selectedIndex].isSharedWeChat && !selectedWindows.isEmpty {
            discoverSharedPreviewFallbacks()
        }
        // A normal application's retained window can have pixels but no AX
        // object, just like a missing member of a shared selection. It must
        // receive the same bounded recovery without losing its visible card.
        if retryMissingWindows && !selectedWindows.isEmpty {
            scheduleSelectedApplicationWindowRefresh()
        }
        guard !selectedWindows.isEmpty else {
            if retryMissingWindows { scheduleSelectedApplicationWindowRefresh() }
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
            if let retainedThumbnails, retainedThumbnails.indices.contains(index),
               retainedThumbnails[index]?.image != nil { continue }
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
            currentThumbnailResults = retainedThumbnails ?? [WindowThumbnailResult?](
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
        // The capture batch can omit owners whose images were retained. The
        // publication guard must still validate every owner in the model.
        let captureApplicationIdentities = thumbnailApplicationIdentities(for: candidate)
        let lifecycleRevisions = captureApplicationIdentities.map {
            candidateLifecycleRevisions[$0.processLifetimeKey]
        }
        let cacheGenerations = Dictionary(uniqueKeysWithValues: captureApplicationIdentities.map {
            ($0.processLifetimeKey, WindowThumbnailProvider.cacheGenerationSnapshot(for: $0))
        })
        let sequenceID = eventSequenceID
        let captureGeneration = thumbnailCaptureGeneration
        let thumbnailCount = selectedWindows.count

        // Both phases publish against the same request-time identities. A
        // cache read or screenshot can finish before a lifecycle/privacy change
        // yet wait for the main actor until after it; recheck every epoch here.
        let publishThumbnails: @MainActor @Sendable ([WindowThumbnailResult?], Bool) -> Bool = {
            [weak self] thumbnails, isFinal in
            guard !Task.isCancelled,
                  let self,
                  self.commandSequenceActive,
                  self.preferences.isEnabled,
                  self.preferences.cmdTabPlusEnabled,
                  self.isPresenting,
                  self.nativeSwitcherAnchorFrame != nil,
                  self.eventSequenceID == sequenceID,
                  self.selectedIndex == captureIndex,
                  self.candidates.indices.contains(captureIndex),
                  self.thumbnailCaptureGeneration == captureGeneration else { return false }
            guard self.candidates[captureIndex].processIdentifiers == captureProcessIdentifiers,
                  self.thumbnailApplicationIdentities(for: self.candidates[captureIndex])
                    == captureApplicationIdentities,
                  captureApplicationIdentities.map({
                WindowAXLifecycleRegistry.shared.revision(for: $0)
            }) == lifecycleRevisions,
                  captureApplicationIdentities.allSatisfy({ identity in
                    identity.matchesCurrentProcess()
                  }) else {
                self.cancel()
                return false
            }
            let presentationFailure = WindowThumbnailProvider.presentationFailureResult()
            let epochsAreCurrent = captureApplicationIdentities.allSatisfy { identity in
                WindowThumbnailProvider.cacheGenerationSnapshot(for: identity)
                    == cacheGenerations[identity.processLifetimeKey]
            }
            // A provider permission failure purges its cache and advances its
            // epoch. Preserve that typed final failure so it replaces any
            // cached pixels; every image still requires the original epoch.
            guard epochsAreCurrent || presentationFailure != nil else {
                self.cancel()
                return false
            }
            let now = Date()
            var publishedThumbnails = thumbnails.map { result -> WindowThumbnailResult? in
                if case let .some(.recentCache(_, timestamp)) = result,
                   timestamp.addingTimeInterval(WindowThumbnailProvider.recentCacheTTL) <= now {
                    return isFinal ? .notEnumerated : nil
                }
                return result
            }
            if let presentationFailure {
                // Replace the whole batch, including cache hits from other
                // processes, under the provider's launch/revocation policy.
                publishedThumbnails = Array(repeating: presentationFailure, count: thumbnailCount)
            }
            if !isFinal, presentationFailure == nil,
               !publishedThumbnails.contains(where: { $0?.image != nil }) {
                return true
            }
            // These stable candidates already passed AX + WindowServer
            // reconciliation. Missing cache entries remain loading; neither
            // cached nor new pixels create action identities or reorder rows.
            self.selectedWindowIndex = min(
                self.selectedWindowIndex,
                max(0, self.candidates[captureIndex].windows.count - 1)
            )
            self.currentThumbnailResults = publishedThumbnails
            self.previewLoading = false
            self.presentOverlay(thumbnails: publishedThumbnails, for: captureIndex)
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - renderStartedAt) * 1_000
            let cachedCount = publishedThumbnails.reduce(into: 0) { count, result in
                if case .some(.recentCache(_, _)) = result { count += 1 }
            }
            let freshCount = publishedThumbnails.reduce(into: 0) { count, result in
                if case .some(.fresh(_)) = result { count += 1 }
            }
            let event = presentationFailure != nil
                ? "permissionPresented"
                : isFinal ? "freshPresented" : "cachePresented"
            // Measures renderOverlay-to-model publication, not key input to
            // painted pixels. The final phase can also publish typed failures.
            self.logger.info(
                "CmdTabPreviewTiming stage=render event=\(event, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) windows=\(thumbnailCount, privacy: .public) cachedCount=\(cachedCount, privacy: .public) freshCount=\(freshCount, privacy: .public)"
            )
            if isFinal || presentationFailure != nil { self.thumbnailCaptureTask = nil }
            return presentationFailure == nil
        }

        thumbnailCaptureTask = Task.detached(priority: .userInitiated) {
            var thumbnails = retainedThumbnails ?? [WindowThumbnailResult?](
                repeating: nil,
                count: thumbnailCount
            )
            for index in unavailableThumbnailIndexes {
                thumbnails[index] = .notEnumerated
            }
            var cachedThumbnails = thumbnails
            for batch in batches {
                guard !Task.isCancelled,
                      let expectedGeneration = cacheGenerations[batch.applicationIdentity.processLifetimeKey]
                else { return }
                let cached = WindowThumbnailProvider.validatedCachedResults(
                    applicationIdentity: batch.applicationIdentity,
                    requests: batch.requests.map(\.request),
                    expectedCacheGeneration: expectedGeneration
                )
                for (indexedRequest, result) in zip(batch.requests, cached) {
                    cachedThumbnails[indexedRequest.index] = result
                }
            }
            if cachedThumbnails.contains(where: { $0?.image != nil }) {
                let cachedResults = cachedThumbnails
                guard await publishThumbnails(cachedResults, false) else { return }
            }
            // Multiple processes can legitimately represent the same Dock App
            // identity. Capture one process at a time to keep ScreenCaptureKit
            // work bounded, then restore the aggregate window order.
            for batch in batches {
                guard !Task.isCancelled else { return }
                let results = await WindowThumbnailProvider.captureWindows(
                    applicationIdentity: batch.applicationIdentity,
                    requests: batch.requests.map(\.request),
                    expectedCacheGeneration: cacheGenerations[batch.applicationIdentity.processLifetimeKey]
                )
                for (indexedRequest, result) in zip(batch.requests, results) {
                    thumbnails[indexedRequest.index] = result
                }
            }
            guard !Task.isCancelled else { return }
            let completedThumbnails = thumbnails
            _ = await publishThumbnails(completedThumbnails, true)
        }
    }

    /// AXFocusedWindow/AXMainWindow/AXWindows can all be transiently empty
    /// while an App or Space is activating. Refresh only the selected App with
    /// a small bounded retry; never re-enumerate every desktop App or start
    /// screenshot work until real windows are available. A shared selection
    /// also retries a missing owner while the other owner's cards stay usable.
    private func scheduleSelectedApplicationWindowRefresh() {
        guard isPresenting,
              candidates.indices.contains(selectedIndex) else { return }
        let applicationIndex = selectedIndex
        let candidate = candidates[applicationIndex]
        let hasExistingWindows = !candidate.windows.isEmpty
        let processIdentifiers = candidate.processIdentifiers
        let requestedOwners = Set(processIdentifiers)
        guard !WindowCommandTabRecoveryPolicy.ownersNeedingRecovery(
            windows: candidate.windows, owners: requestedOwners,
            owner: { $0.application.processIdentifier }, hasOperation: { $0.element != nil }
        ).isEmpty else { return }
        let sequenceID = eventSequenceID
        let originalCaptureGeneration = thumbnailCaptureGeneration
        let applicationIdentities = thumbnailApplicationIdentities(for: candidate.applications)
        guard applicationIdentities.count == candidate.applications.count else {
            if !hasExistingWindows {
                previewLoading = false
                presentOverlay(thumbnails: [], for: applicationIndex)
            }
            return
        }
        let revisions = applicationIdentities.map { WindowAXLifecycleRegistry.shared.revision(for: $0) }
        let cacheGenerations = applicationIdentities.map { WindowThumbnailProvider.cacheGenerationSnapshot(for: $0) }

        selectedApplicationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var captureGeneration = originalCaptureGeneration
            defer {
                if self.eventSequenceID == sequenceID && self.thumbnailCaptureGeneration == captureGeneration {
                    self.selectedApplicationRefreshTask = nil
                }
            }
            for (attempt, delay) in WindowCommandTabRecoveryPolicy.delays.enumerated() {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled, self.isPresenting,
                      self.eventSequenceID == sequenceID,
                      self.thumbnailCaptureGeneration == captureGeneration,
                      self.selectedIndex == applicationIndex,
                      self.candidates.indices.contains(applicationIndex),
                      self.candidates[applicationIndex].processIdentifiers == processIdentifiers,
                      applicationIdentities.map({ WindowAXLifecycleRegistry.shared.revision(for: $0) }) == revisions,
                      applicationIdentities.map({ WindowThumbnailProvider.cacheGenerationSnapshot(for: $0) }) == cacheGenerations
                else { return }
                if self.nativeSelectionPending || self.nativePointerClickCaptured || self.overlay.hasPendingPointerPress ||
                    CGEventSource.buttonState(.combinedSessionState, button: .left) { continue }

                let currentApplications = processIdentifiers.compactMap {
                    NSRunningApplication(processIdentifier: $0)
                }.filter { !$0.isTerminated }
                guard currentApplications.count == processIdentifiers.count,
                      self.thumbnailApplicationIdentities(for: currentApplications) == applicationIdentities else { return }
                let currentCandidate = self.candidates[applicationIndex]
                let missingOwners = WindowCommandTabRecoveryPolicy.ownersNeedingRecovery(
                    windows: currentCandidate.windows, owners: requestedOwners,
                    owner: { $0.application.processIdentifier }, hasOperation: { $0.element != nil }
                )
                guard !missingOwners.isEmpty else { return }
                let retryApplications = currentApplications.filter { missingOwners.contains($0.processIdentifier) }
                var refreshedWindows = self.windowCandidates(for: retryApplications, messagingTimeout: 0.075)
                var admittedRecovery = false
                for identity in applicationIdentities where missingOwners.contains(identity.processIdentifier) {
                    let availableIDs = Set(refreshedWindows.filter {
                        $0.application.processIdentifier == identity.processIdentifier && $0.element != nil
                    }.compactMap(\.windowID))
                    let missingIDs = Set(currentCandidate.windows.filter {
                        $0.application.processIdentifier == identity.processIdentifier && $0.element == nil
                    }.compactMap(\.windowID)).union(self.previewOnlyWindows.filter {
                        $0.identity.processID == identity.processIdentifier && !$0.canActivate
                    }.map { $0.identity.windowID }).subtracting(availableIDs)
                    let eligible = WindowAXLifecycleRegistry.shared.recoverableWindowIDs(
                        missingIDs, identity: identity,
                        discoverWhenEmpty: !refreshedWindows.contains { $0.application.processIdentifier == identity.processIdentifier }
                    )
                    guard !eligible.isEmpty else { continue }
                    let recovered = await WindowAXExactRecovery.shared.recover(identity: identity, windowIDs: eligible)
                    // The pointer may have selected another App, dismissed the
                    // native switcher, or begun a click while the worker ran.
                    guard !Task.isCancelled, self.isPresenting,
                          self.eventSequenceID == sequenceID,
                          self.thumbnailCaptureGeneration == captureGeneration,
                          self.selectedIndex == applicationIndex,
                          self.candidates.indices.contains(applicationIndex),
                          self.candidates[applicationIndex].processIdentifiers == processIdentifiers,
                          applicationIdentities.allSatisfy({ $0.matchesCurrentProcess() }),
                          applicationIdentities.map({ WindowAXLifecycleRegistry.shared.revision(for: $0) }) == revisions,
                          applicationIdentities.map({ WindowThumbnailProvider.cacheGenerationSnapshot(for: $0) }) == cacheGenerations
                    else { return }
                    guard !self.nativeSelectionPending, !self.nativePointerClickCaptured,
                          !self.overlay.hasPendingPointerPress,
                          !CGEventSource.buttonState(.combinedSessionState, button: .left) else { continue }
                    guard let identityIndex = applicationIdentities.firstIndex(of: identity) else { continue }
                    if WindowAXLifecycleRegistry.shared.admitRecoveredWindows(
                        recovered, identity: identity, expectedRevision: revisions[identityIndex]
                    ) > 0 { admittedRecovery = true }
                }
                if admittedRecovery {
                    refreshedWindows = self.windowCandidates(for: retryApplications, messagingTimeout: 0.075)
                }
                guard !Task.isCancelled, applicationIdentities.allSatisfy({ $0.matchesCurrentProcess() }),
                      applicationIdentities.map({ WindowAXLifecycleRegistry.shared.revision(for: $0) }) == revisions,
                      applicationIdentities.map({ WindowThumbnailProvider.cacheGenerationSnapshot(for: $0) }) == cacheGenerations
                else { return }
                guard !self.nativePointerClickCaptured, !self.overlay.hasPendingPointerPress,
                      !CGEventSource.buttonState(.combinedSessionState, button: .left) else { continue }
                let replacementWindows = WindowCommandTabRecoveryPolicy.restoringMissingWindows(
                    current: currentCandidate.windows, refreshed: refreshedWindows,
                    requestedOwners: missingOwners, owner: { $0.application.processIdentifier },
                    windowID: \.windowID, hasOperation: { $0.element != nil }
                )
                WindowInteractionDiagnosticRecorder.shared.record(
                    component: "cmdTab", event: "operationRecoveryAttempt",
                    metadata: [
                        "attempt": .integer(Int64(attempt + 1)),
                        "requestedOwnerCount": .integer(Int64(missingOwners.count)),
                        "windowCount": .integer(Int64(refreshedWindows.count)),
                        "madeProgress": .flag(replacementWindows != nil),
                        "keptExistingCards": .flag(hasExistingWindows)
                    ]
                )
                guard let replacementWindows else { continue }
                let previousSelection: WindowActionTarget? = {
                    guard self.hasExplicitWindowSelection,
                          currentCandidate.windows.indices.contains(self.selectedWindowIndex) else { return nil }
                    let window = currentCandidate.windows[self.selectedWindowIndex]
                    guard let identity = WindowThumbnailApplicationIdentity(application: window.application) else { return nil }
                    return WindowActionTarget(window: window, applicationIdentity: identity)
                }()
                let retainedThumbnails = replacementWindows.map { window -> WindowThumbnailResult? in
                    guard let id = window.windowID, id > 0 else { return nil }
                    let matches = currentCandidate.windows.indices.filter {
                        currentCandidate.windows[$0].application.processIdentifier == window.application.processIdentifier &&
                            currentCandidate.windows[$0].windowID == id
                    }
                    guard matches.count == 1, let index = matches.first,
                          self.currentThumbnailResults.indices.contains(index) else { return nil }
                    let result = self.currentThumbnailResults[index]
                    if case let .some(.recentCache(_, timestamp)) = result,
                       timestamp.addingTimeInterval(WindowThumbnailProvider.recentCacheTTL) <= Date() { return nil }
                    return result
                }
                let sameTopology = currentCandidate.windows.count == replacementWindows.count &&
                    zip(currentCandidate.windows, replacementWindows).allSatisfy {
                        $0.application.processIdentifier == $1.application.processIdentifier && $0.windowID == $1.windowID
                    }
                let recoveredWindowNeedsImage = replacementWindows.indices.contains { index in
                    let window = replacementWindows[index]
                    guard window.element != nil, retainedThumbnails[index]?.image == nil else { return false }
                    return !currentCandidate.windows.contains {
                        $0.application.processIdentifier == window.application.processIdentifier &&
                            $0.windowID == window.windowID && $0.element != nil
                    }
                }
                self.candidates[applicationIndex] = Candidate(
                    applications: currentApplications, windows: replacementWindows,
                    isSharedWeChat: candidate.isSharedWeChat
                )
                let restoredSelection = previousSelection.flatMap { self.location(of: $0) }
                self.selectedWindowIndex = restoredSelection?.window ?? min(self.selectedWindowIndex, max(0, replacementWindows.count - 1))
                self.hasExplicitWindowSelection = restoredSelection != nil
                if sameTopology && !recoveredWindowNeedsImage {
                    // Upgrade only AX capabilities. Keep image work, ordering
                    // and frame generation for the unchanged exact targets.
                    self.previewLoading = false
                    self.currentThumbnailResults = retainedThumbnails
                    self.presentOverlay(thumbnails: self.currentThumbnailResults, for: applicationIndex)
                } else {
                    // Changed topology invalidates old image/fallback indexes.
                    // This is the same finite recovery task, not a fresh budget.
                    self.renderOverlay(retryMissingWindows: false,
                                       preservingThumbnails: retainedThumbnails,
                                       continuingRecovery: true)
                    captureGeneration = self.thumbnailCaptureGeneration
                }
                let remaining = WindowCommandTabRecoveryPolicy.ownersNeedingRecovery(
                    windows: replacementWindows, owners: requestedOwners,
                    owner: { $0.application.processIdentifier }, hasOperation: { $0.element != nil }
                )
                WindowInteractionDiagnosticRecorder.shared.record(
                    component: "cmdTab", event: "selectedWindowsRecovered",
                    metadata: [
                        "sharedWeChat": .flag(candidate.isSharedWeChat),
                        "remainingOwnerCount": .integer(Int64(remaining.count)),
                        "windowCount": .integer(Int64(replacementWindows.count))
                    ]
                )
                if remaining.isEmpty { return }
            }
            if self.candidates[applicationIndex].windows.isEmpty { self.discoverPreviewOnlyWindows() }
        }
    }

    private func discoverPreviewOnlyWindows() {
        if isPresenting, candidates.indices.contains(selectedIndex), candidates[selectedIndex].isSharedWeChat {
            discoverSharedPreviewFallbacks()
            return
        }
        guard isPresenting, candidates.indices.contains(selectedIndex),
              candidates[selectedIndex].windows.isEmpty else { return }
        let index = selectedIndex
        let sequence = eventSequenceID
        let generation = thumbnailCaptureGeneration
        let identities = thumbnailApplicationIdentities(for: candidates[index].applications)
        let lifecycleRevisions = identities.map {
            candidateLifecycleRevisions[$0.processLifetimeKey]
        }
        let cacheGenerations = Dictionary(uniqueKeysWithValues: identities.map {
            ($0.processLifetimeKey, WindowThumbnailProvider.cacheGenerationSnapshot(for: $0))
        })
        thumbnailCaptureTask = Task { @MainActor [weak self] in
            var discovered: [(
                identity: WindowThumbnailApplicationIdentity,
                window: WindowThumbnailDiscoveredWindow
            )] = []
            for identity in identities {
                guard !Task.isCancelled else { return }
                let result = await WindowThumbnailProvider.discoverAndCaptureWindows(
                    applicationIdentity: identity,
                    expectedCacheGeneration: cacheGenerations[identity.processLifetimeKey]
                )
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
            guard identities.map({ WindowAXLifecycleRegistry.shared.revision(for: $0) })
                == lifecycleRevisions else {
                self.cancel()
                return
            }
            self.previewOnlyWindows = items
            self.previewLoading = false
            self.thumbnailCaptureTask = nil
            self.presentOverlay(thumbnails: [], for: index)
        }
    }

    /// Retain one bounded preview-only fallback per missing installation,
    /// using the existing surface-selection policy. It is never an operation
    /// target and cannot replace a canonical window's true owner.
    private func discoverSharedPreviewFallbacks() {
        guard isPresenting, candidates.indices.contains(selectedIndex),
              candidates[selectedIndex].isSharedWeChat else { return }
        sharedPreviewFallbackTask?.cancel()
        let candidate = candidates[selectedIndex]
        let index = selectedIndex
        let sequence = eventSequenceID
        let generation = thumbnailCaptureGeneration
        let exactOwners = Set(candidate.windows.map { $0.application.processIdentifier })
        let identities = thumbnailApplicationIdentities(for: candidate.applications.filter {
            !exactOwners.contains($0.processIdentifier)
        })
        let revisions = identities.map { WindowAXLifecycleRegistry.shared.revision(for: $0) }
        let cacheGenerations = identities.map { WindowThumbnailProvider.cacheGenerationSnapshot(for: $0) }
        let labels = Dictionary(uniqueKeysWithValues: candidate.applications.map { ($0.processIdentifier, sharedWeChatLabel(for: $0)) })
        sharedPreviewFallbackTask = Task { @MainActor [weak self] in
            var items: [CommandTabWindowDisplayItem] = []
            for (offset, identity) in identities.enumerated() {
                guard !Task.isCancelled else { return }
                let result = await WindowThumbnailProvider.discoverAndCaptureWindows(
                    applicationIdentity: identity, expectedCacheGeneration: cacheGenerations[offset]
                )
                guard case let .windows(discovered) = result,
                      let selected = WindowPreviewOnlySelectionPolicy.selectOne(from: discovered),
                      let windowID = selected.request.windowID else { continue }
                items.append(CommandTabWindowDisplayItem(
                    id: candidate.windows.count + items.count,
                    identity: WindowPreviewIdentity(processID: identity.processIdentifier, windowID: windowID),
                    title: "\(labels[identity.processIdentifier] ?? "微信") · 应用预览",
                    isMinimized: false, canClose: false, isSelected: false,
                    thumbnailResult: selected.result, canActivate: false
                ))
            }
            guard let self, !Task.isCancelled, self.isPresenting,
                  self.eventSequenceID == sequence, self.thumbnailCaptureGeneration == generation,
                  self.selectedIndex == index, self.candidates.indices.contains(index),
                  self.candidates[index].processIdentifiers == candidate.processIdentifiers,
                  identities.allSatisfy({ $0.matchesCurrentProcess() }),
                  identities.map({ WindowAXLifecycleRegistry.shared.revision(for: $0) }) == revisions,
                  identities.map({ WindowThumbnailProvider.cacheGenerationSnapshot(for: $0) }) == cacheGenerations else { return }
            self.sharedPreviewFallbackTask = nil
            self.previewOnlyWindows = items
            if candidate.windows.isEmpty { self.previewLoading = false }
            self.presentOverlay(thumbnails: self.currentThumbnailResults, for: index)
        }
    }

    private func presentOverlay(
        thumbnails: [WindowThumbnailResult?],
        for presentedIndex: Int
    ) {
        guard !nativeClick.blocksPreviewUpdates,
              isPresenting,
              selectedIndex == presentedIndex,
              candidates.indices.contains(presentedIndex),
              let nativeSwitcherAnchorFrame else { return }
        let actionTargets = candidates.map { candidate in
            candidate.windows.map { window -> WindowActionTarget? in
                guard let identity = WindowThumbnailApplicationIdentity(application: window.application) else { return nil }
                return WindowActionTarget(window: window, applicationIdentity: identity)
            }
        }
        let items = candidates.enumerated().map { index, candidate in
            CommandTabDisplayItem(
                id: index,
                appName: candidate.isSharedWeChat ? "微信 · 全部窗口" : candidate.application.localizedName ?? "App",
                icon: candidate.application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                isLoading: previewLoading,
                windows: previewLoading ? [] : candidate.windows.isEmpty ? previewOnlyWindows : (candidate.windows.enumerated().map { windowIndex, window in
                    CommandTabWindowDisplayItem(
                        id: windowIndex,
                        identity: WindowPreviewIdentity(processID: window.application.processIdentifier, windowID: window.windowID ?? 0),
                        title: candidate.isSharedWeChat
                            ? "\(sharedWeChatLabel(for: window.application)) · \(window.title)"
                            : window.title,
                        isMinimized: window.isMinimized,
                        canClose: window.element != nil && window.canClose,
                        isSelected: index == presentedIndex && windowIndex == selectedWindowIndex
                            && (!candidate.isSharedWeChat || hasExplicitWindowSelection),
                        thumbnailResult: index == presentedIndex && thumbnails.indices.contains(windowIndex)
                            ? thumbnails[windowIndex]
                            : nil,
                        canActivate: window.element != nil
                    )
                } + (candidate.isSharedWeChat ? previewOnlyWindows : []))
            )
        }
        let sequence = eventSequenceID
        overlay.showNativePreview(
            items: items,
            selectedIndex: selectedIndex,
            anchorAXFrame: nativeSwitcherAnchorFrame,
            diagnosticSequence: sequence,
            allowsSyntheticHoverSelection: !candidates[presentedIndex].isSharedWeChat,
            onCommitWindow: { [weak self] applicationIndex, windowIndex in
                guard let self, self.eventSequenceID == sequence,
                      !self.nativeClick.blocksPreviewUpdates else { return }
                self.logger.debug(
                    "Mouse committed Cmd-Tab window appIndex=\(applicationIndex, privacy: .public) windowIndex=\(windowIndex, privacy: .public)"
                )
                guard actionTargets.indices.contains(applicationIndex),
                      actionTargets[applicationIndex].indices.contains(windowIndex),
                      let target = actionTargets[applicationIndex][windowIndex] else { return }
                self.enqueueEventAction(.commitWindow(
                    target: target,
                    sequenceID: sequence
                ))
            },
            onHoverWindow: { [weak self] applicationIndex, windowIndex in
                guard self?.eventSequenceID == sequence,
                      self?.nativeClick.blocksPreviewUpdates == false else { return }
                self?.logger.debug(
                    "Mouse hovered Cmd-Tab window appIndex=\(applicationIndex, privacy: .public) windowIndex=\(windowIndex, privacy: .public)"
                )
                self?.selectWindow(applicationIndex: applicationIndex, windowIndex: windowIndex)
            },
            onCloseWindow: { [weak self] applicationIndex, windowIndex in
                guard let self, self.eventSequenceID == sequence,
                      !self.nativeClick.blocksPreviewUpdates else { return }
                guard actionTargets.indices.contains(applicationIndex),
                      actionTargets[applicationIndex].indices.contains(windowIndex),
                      let target = actionTargets[applicationIndex][windowIndex] else { return }
                self.enqueueEventAction(.closeWindow(
                    target: target,
                    sequenceID: sequence
                ))
            }
        )
    }

    private func sharedActionPolicy(
        candidate: Candidate,
        action: WindowCommandTabSharingPolicy.RequestedAction,
        selectedWindow: WindowCandidate?
    ) -> WindowCommandTabSharingPolicy.CommitPolicy {
        let applications = candidate.applications.map(weChatSharingApplication)
        guard candidate.isSharedWeChat, let first = applications.first,
              let group = WindowCommandTabSharingPolicy.sharedWeChatGroup(
                selected: [first], running: applications, evidence: .resolvedIdentity
              ) else { return .unavailable }
        return WindowCommandTabSharingPolicy.commitPolicy(
            for: action, group: group,
            explicitlySelectedOwner: selectedWindow.map { weChatSharingApplication($0.application) }
        )
    }

    private func sharedWeChatLabel(for application: NSRunningApplication) -> String {
        WindowCommandTabSharingPolicy.installation(for: weChatSharingApplication(application))?.label ?? "微信"
    }

    private func location(of target: WindowActionTarget) -> (application: Int, window: Int)? {
        guard !nativeSelectionPending, target.applicationIdentity.matchesCurrentProcess() else { return nil }
        var matches: [(application: Int, window: Int)] = []
        for (applicationIndex, candidate) in candidates.enumerated() {
            for (windowIndex, window) in candidate.windows.enumerated() {
                guard window.application.processIdentifier == target.applicationIdentity.processIdentifier,
                      WindowThumbnailApplicationIdentity(application: window.application) == target.applicationIdentity else { continue }
                let matchesWindow: Bool
                if let windowID = target.window.windowID {
                    matchesWindow = window.windowID == windowID
                } else if let lhs = window.element, let rhs = target.window.element {
                    matchesWindow = CFEqual(lhs, rhs)
                } else { matchesWindow = false }
                if matchesWindow { matches.append((applicationIndex, windowIndex)) }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func selectWindow(applicationIndex: Int, windowIndex: Int) {
        guard !nativeClick.blocksPreviewUpdates, isPresenting, !nativeSelectionPending,
              selectedIndex == applicationIndex,
              candidates.indices.contains(applicationIndex) else { return }
        guard candidates[applicationIndex].windows.indices.contains(windowIndex) else {
            if candidates[applicationIndex].isSharedWeChat, hasExplicitWindowSelection {
                hasExplicitWindowSelection = false
                presentOverlay(thumbnails: currentThumbnailResults, for: applicationIndex)
            }
            return
        }
        hasExplicitWindowSelection = true
        guard selectedWindowIndex != windowIndex else { return }
        selectedWindowIndex = windowIndex
        presentOverlay(thumbnails: currentThumbnailResults, for: applicationIndex)
    }

    private func commit(applicationIndex: Int, windowIndex: Int) {
        guard !nativeClick.blocksPreviewUpdates, isPresenting,
              candidates.indices.contains(applicationIndex),
              candidates[applicationIndex].windows.indices.contains(windowIndex),
              candidates[applicationIndex].windows[windowIndex].element != nil else { return }
        selectedIndex = applicationIndex
        selectedWindowIndex = windowIndex
        let candidate = candidates[applicationIndex]
        let window = candidate.windows[windowIndex]
        commitNativeWindow(candidate: candidate, window: window)
    }

    private func closeSelectedWindow() {
        guard isPresenting, !nativeSelectionPending, candidates.indices.contains(selectedIndex) else { return }
        guard !candidates[selectedIndex].isSharedWeChat || hasExplicitWindowSelection else {
            preferences.publishFeedback("请先选择要关闭的窗口")
            return
        }
        let windowIndex = candidates[selectedIndex].windows.indices.contains(selectedWindowIndex)
            ? selectedWindowIndex
            : 0
        if candidates[selectedIndex].isSharedWeChat {
            guard candidates[selectedIndex].windows.indices.contains(windowIndex),
                  sharedActionPolicy(candidate: candidates[selectedIndex], action: .closeWindow,
                    selectedWindow: candidates[selectedIndex].windows[windowIndex])
                    == .exactWindowOwner(processID: candidates[selectedIndex].windows[windowIndex].application.processIdentifier) else { return }
        }
        closeWindow(applicationIndex: selectedIndex, windowIndex: windowIndex)
    }

    private func closeWindow(applicationIndex: Int, windowIndex: Int) {
        guard !nativeClick.blocksPreviewUpdates else { return }
        guard isPresenting,
              candidates.indices.contains(applicationIndex),
              candidates[applicationIndex].windows.indices.contains(windowIndex) else {
            preferences.publishFeedback("暂无可关闭窗口")
            return
        }
        let candidate = candidates[applicationIndex]
        let window = candidate.windows[windowIndex]
        guard window.element != nil else {
            preferences.publishFeedback("窗口暂不可操作，请先切换到该应用")
            return
        }
        guard let applicationIdentity = WindowThumbnailApplicationIdentity(
            application: window.application
        ) else {
            preferences.publishFeedback("应用状态已变化，请重新选择")
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
            preferences.publishFeedback("窗口状态已变化，请重新选择")
            return
        }
        guard currentWindow.canClose,
              let currentElement = currentWindow.element,
              let closeButton = elementAttribute(
                  kAXCloseButtonAttribute,
                  of: currentElement
              ) else {
            preferences.publishFeedback("窗口暂无法关闭")
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
        preferences.publishFeedback("关闭结果未确认，请检查窗口状态")
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
                guard let candidateElement = candidate.windows[$0].element,
                      let closedElement = closedWindow.element else {
                    return false
                }
                return CFEqual(candidateElement, closedElement)
            }
            return matches.count == 1 ? matches[0] : nil
        }()
        guard let windowIndex = currentWindowIndex else {
            preferences.publishFeedback("已请求关闭，正在刷新预览")
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
            windows: remainingWindows,
            isSharedWeChat: candidate.isSharedWeChat
        )
        selectedIndex = applicationIndex
        selectedWindowIndex = min(windowIndex, max(0, remainingWindows.count - 1))
        if candidate.isSharedWeChat { hasExplicitWindowSelection = false }
        // Update the visible model immediately from the thumbnails already in
        // memory, but do not start a second capture round. The bounded AX
        // reconciliation below performs the single authoritative refresh.
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        sharedPreviewFallbackTask?.cancel()
        sharedPreviewFallbackTask = nil
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
        guard isPresenting, !nativeSelectionPending, candidates.indices.contains(selectedIndex) else { return }
        let candidate = candidates[selectedIndex]
        let application: NSRunningApplication
        if candidate.applications.count == 1 {
            application = candidate.application
        } else if hasExplicitWindowSelection,
                  candidate.windows.indices.contains(selectedWindowIndex) {
            application = candidate.windows[selectedWindowIndex].application
        } else {
            cancel()
            preferences.publishFeedback("应用有多个运行实例，请先选择具体窗口再退出")
            return
        }
        if candidate.isSharedWeChat {
            guard hasExplicitWindowSelection, candidate.windows.indices.contains(selectedWindowIndex),
                  sharedActionPolicy(candidate: candidate, action: .quitApplication,
                    selectedWindow: candidate.windows[selectedWindowIndex])
                    == .exactWindowOwner(processID: application.processIdentifier) else { return }
        }
        let processIdentifier = application.processIdentifier
        let applicationName = candidate.isSharedWeChat ? sharedWeChatLabel(for: application) : application.localizedName ?? "这个 App"
        guard let selectedApplicationIdentity = WindowThumbnailApplicationIdentity(
            application: application
        ) else {
            cancel()
            preferences.publishFeedback("应用状态已变化，请重新打开 Cmd-Tab")
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
        alert.informativeText = "将退出所选应用，请先确认未保存内容。"
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
                windows: reconciledWindows,
                isSharedWeChat: candidate.isSharedWeChat
            )
            if let validatedCurrentApplication {
                self.recordLifecycleRevisions(for: [validatedCurrentApplication])
            }
            self.selectedIndex = applicationIndex
            let windowCount = self.candidates[self.selectedIndex].windows.count
            self.selectedWindowIndex = min(self.selectedWindowIndex, max(0, windowCount - 1))
            if candidate.isSharedWeChat { self.hasExplicitWindowSelection = false }
            self.renderOverlay()
        }
    }

    private func activate(candidate: Candidate, window: WindowCandidate?, expectedMouseInputCounts: [UInt32]? = nil) {
        let mouseInputCounts = expectedMouseInputCounts ?? Self.mousePressCounts()
        concreteWindowActivationTask?.cancel()
        concreteWindowActivationTask = nil
        let application = window?.application ?? candidate.application
        let processIdentifier = application.processIdentifier
        let applicationIdentity = WindowThumbnailApplicationIdentity(
            application: application
        )
        if let window {
            guard applicationIdentity?.matchesCurrentProcess() == true,
                  freshWindow(matching: window, application: application) != nil,
                  Self.mousePressCounts() == mouseInputCounts else {
                cancel()
                return
            }
        }
        if let windowID = window?.windowID {
            WindowServerPrivateBridge.activate(
                processIdentifier: processIdentifier,
                windowID: windowID
            )
        }
        guard Self.mousePressCounts() == mouseInputCounts else { cancel(); return }
        let activationAccepted = application.activate(options: [])
        var focusedExactWindow = false
        if let window,
           let currentWindow = freshWindow(
                matching: window,
                application: application
           ), Self.mousePressCounts() == mouseInputCounts {
            focusedExactWindow = focusExactWindow(
                currentWindow,
                application: application,
                expectedWindowID: currentWindow.windowID
            )
        }
        recordFocusOutcome(
            event: focusedExactWindow && application.isActive ? "actualFocus" : "activationPending",
            application: application, window: window,
            activationAccepted: activationAccepted, focusedExactWindow: focusedExactWindow
        )
        cancel()

        guard let window, let applicationIdentity else { return }
        let activationSequence = eventSequenceID
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
                      self.eventSequenceID == activationSequence,
                      Self.mousePressCounts() == mouseInputCounts,
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
                guard Self.mousePressCounts() == mouseInputCounts else { return }
                let focused = self.focusExactWindow(
                    currentWindow,
                    application: currentApplication,
                    expectedWindowID: currentWindow.windowID
                )
                if delay == 140_000_000 {
                    self.recordFocusOutcome(
                        event: "actualFocusReassert", application: currentApplication,
                        window: currentWindow, activationAccepted: activationAccepted,
                        focusedExactWindow: focused
                    )
                }
            }
            self?.concreteWindowActivationTask = nil
        }
    }

    private static func mousePressCounts() -> [UInt32] {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown].map {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
        }
    }

    private func recordFocusOutcome(
        event: String, application: NSRunningApplication, window: WindowCandidate?,
        activationAccepted: Bool, focusedExactWindow: Bool
    ) {
        WindowInteractionDiagnosticRecorder.shared.record(component: "cmdTab", event: event, metadata: [
            "ownerPID": .integer(Int64(application.processIdentifier)),
            "windowID": .integer(Int64(window?.windowID ?? 0)),
            "activationAccepted": .flag(activationAccepted),
            "frontmostMatched": .flag(application.isActive),
            "axFocusedMatched": .flag(focusedExactWindow)
        ])
    }

    private func recordNativeCommit(
        _ event: String,
        ticket: WindowCommandTabCommitCoordinator.Ticket? = nil,
        reason: String? = nil,
        window: WindowCandidate? = nil,
        visibility: WindowCommandTabCommitCoordinator.Visibility? = nil
    ) {
        var metadata: [String: WindowInteractionDiagnosticValue] = [
            "sequence": .integer(Int64(clamping: ticket?.sequenceID ?? eventSequenceID))
        ]
        if let ticket { metadata["generation"] = .integer(Int64(clamping: ticket.generation)) }
        if let reason { metadata["reason"] = .code(reason) }
        if let window {
            metadata["ownerPID"] = .integer(Int64(window.application.processIdentifier))
            metadata["windowID"] = .integer(Int64(window.windowID ?? 0))
        }
        if let visibility { metadata["visibility"] = .code(visibility.rawValue) }
        WindowInteractionDiagnosticRecorder.shared.record(component: "cmdTab", event: event, metadata: metadata)
    }

    /// Abort the pending action, not the live native-switcher session. Its
    /// pointer tap and cards must survive a failed dismissal or new input.
    private func abortNativeWindowCommit(reason: String, reconcile: Bool = true) {
        guard let ticket = nativeWindowCommit.pending else { return }
        nativeWindowCommit.invalidate()
        nativeWindowCommitTask?.cancel()
        nativeWindowCommitTask = nil
        hasExplicitWindowSelection = false
        overlay.clearPointerSelection()
        recordNativeCommit("commitAbort", ticket: ticket, reason: reason)
        if reconcile { scheduleNativeSessionReconciliation(reason: reason) }
    }

    private func cancelNativeSessionReconciliation() {
        nativeSessionReconciliationGeneration &+= 1
        nativeSessionReconciliationTask?.cancel()
        nativeSessionReconciliationTask = nil
    }

    /// Input/failure edges schedule a deferred read. A native click keeps
    /// previews paused through a bounded release readback; ordinary session
    /// reconciliation retains its single read and existing visibility policy.
    private func scheduleNativeSessionReconciliation(reason: String) {
        let context = nativeCommitContext
        cancelNativeSessionReconciliation()
        let clickTicket = nativeClick.pending
        guard clickTicket == nil || nativeClick.hasReleased else { return }
        let generation = nativeSessionReconciliationGeneration
        let sequence = eventSequenceID
        nativeSessionReconciliationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  self.nativeSessionReconciliationGeneration == generation,
                  self.eventSequenceID == sequence,
                  !self.nativeWindowCommit.isPending else { return }
            defer {
                if self.nativeSessionReconciliationGeneration == generation {
                    self.nativeSessionReconciliationTask = nil
                }
            }
            guard self.preferences.isEnabled, self.preferences.cmdTabPlusEnabled,
                  !self.zilanPointerInteraction.isSuppressed, let context else {
                self.cancel()
                return
            }
            let isCurrent = {
                !Task.isCancelled
                    && self.nativeSessionReconciliationGeneration == generation
                    && self.eventSequenceID == sequence
                    && !self.nativeWindowCommit.isPending
                    && self.preferences.isEnabled && self.preferences.cmdTabPlusEnabled
                    && !self.zilanPointerInteraction.isSuppressed
            }
            let readVisibility = {
                WindowCommandTabDiagnostics.measure("reconcileVisibility", sequence: sequence) {
                    self.nativeSwitcher.commitVisibility(context)
                }
            }
            let visibility: WindowCommandTabCommitCoordinator.Visibility
            if let clickTicket {
                // Native-only control takes about 260–300ms from mouseUp to
                // retiring the strip. Do not restore our panel at the first
                // 50ms visible read and interrupt that native transaction.
                var settledVisibility: WindowCommandTabCommitCoordinator.Visibility?
                await WindowCommandTabNativeClickWorkflow.run(
                    isCurrent: { isCurrent() && self.nativeClick.pending == clickTicket },
                    isReleased: {
                        self.nativeClick.canReconcile(
                            clickTicket, sequenceID: sequence,
                            buttonPressed: Self.nativeLeftButtonPressed
                        )
                    },
                    readVisibility: readVisibility,
                    onSettled: { settledVisibility = $0 }
                )
                guard isCurrent(), let settledVisibility,
                      self.nativeClick.finish(clickTicket) else { return }
                self.overlay.setNativeClickSuspended(false)
                visibility = settledVisibility
                self.recordNativeClick("nativeClickSettled")
            } else {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard isCurrent(), !self.nativeClick.blocksPreviewUpdates else { return }
                visibility = readVisibility()
            }
            guard !Task.isCancelled,
                  self.nativeSessionReconciliationGeneration == generation,
                  self.eventSequenceID == sequence else { return }
            let commandHeld = CGEventSource.keyState(.combinedSessionState, key: 55)
                || CGEventSource.keyState(.combinedSessionState, key: 54)
            self.recordNativeCommit("sessionReconciled", reason: reason, visibility: visibility)
            let action = WindowCommandTabSessionReconciliation.action(visibility: visibility, commandHeld: commandHeld)
            if WindowCommandTabDiagnostics.enabled {
                var metadata = WindowCommandTabDiagnostics.keyStates()
                metadata["sequence"] = .integer(Int64(clamping: sequence))
                metadata["reason"] = .code(reason)
                metadata["visibility"] = .code(visibility.rawValue)
                metadata["policyCommandHeld"] = .flag(commandHeld)
                metadata["active"] = .flag(self.commandSequenceActive)
                switch action {
                case .endSession: metadata["action"] = .code("endSession")
                case .restorePointerSession: metadata["action"] = .code("restorePointerSession")
                case .awaitFreshSelection: metadata["action"] = .code("awaitFreshSelection")
                }
                WindowCommandTabDiagnostics.recorder.record(event: "reconcileDecision", metadata: metadata)
            }
            switch action {
            case .endSession:
                self.cancel()
            case .restorePointerSession:
                self.commandSequenceActive = true
                self.nativeSelectionPending = true
                self.installNativePointerTapIfNeeded()
                // Refresh the selection before restoring actionable cards: a
                // disabled tap may have missed Tab as well as Command-up.
                self.scheduleNativeSwitcherSync()
            case .awaitFreshSelection:
                self.commandSequenceActive = true
                self.hasExplicitWindowSelection = false
                self.nativeSelectionPending = true
                self.overlay.hide()
                self.isPresenting = false
                self.candidates.removeAll()
                self.installNativePointerTapIfNeeded()
            }
        }
    }

    /// Every explicit card click must end Dock's switcher before activating a
    /// concrete window. Shared WeChat still derives action identity exclusively
    /// from the selected card, never from the ambiguous native tile.
    private func commitNativeWindow(candidate: Candidate, window: WindowCandidate) {
        cancelNativeSessionReconciliation()
        abortNativeWindowCommit(reason: "superseded", reconcile: false)
        let mouseInputCounts = Self.mousePressCounts()
        guard !candidate.isSharedWeChat
                || sharedActionPolicy(candidate: candidate, action: .commandRelease, selectedWindow: window)
                    == .exactWindowOwner(processID: window.application.processIdentifier),
              let context = nativeCommitContext,
              let identity = WindowThumbnailApplicationIdentity(application: window.application),
              identity.matchesCurrentProcess(),
              freshWindow(matching: window, application: window.application) != nil else {
            hasExplicitWindowSelection = false
            recordNativeCommit("commitRejected", reason: "invalidTargetOrContext", window: window)
            scheduleNativeSessionReconciliation(reason: "invalidTargetOrContext")
            preferences.publishFeedback("窗口状态已变化，请重新选择")
            return
        }
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let allowedForegroundPIDs = Set(candidate.processIdentifiers + [foregroundPID].compactMap { $0 })
        let ticket = nativeWindowCommit.begin(sequenceID: eventSequenceID)
        recordNativeCommit("commitRequested", ticket: ticket, window: window)
        let initialVisibility = nativeSwitcher.commitVisibility(context)
        recordNativeCommit("commitVisibilityInitial", ticket: ticket, visibility: initialVisibility)
        guard initialVisibility != .unknown,
              Self.mousePressCounts() == mouseInputCounts,
              nativeWindowCommit.isCurrent(ticket, sequenceID: eventSequenceID) else {
            abortNativeWindowCommit(reason: "initialVisibilityOrInput")
            preferences.publishFeedback("无法确认系统 Cmd-Tab 状态，请重试")
            return
        }
        if initialVisibility == .visible {
            // A Command-release commit can arrive just before Dock retires the
            // list. Keep monitoring that original session during the handshake.
            commandSequenceActive = true
            let dismissal = nativeSwitcher.dismissForWindowCommit(context, stillValid: { [weak self] in
                guard let self else { return false }
                return self.nativeWindowCommit.isCurrent(ticket, sequenceID: self.eventSequenceID)
                    && Self.mousePressCounts() == mouseInputCounts
                    && NSWorkspace.shared.frontmostApplication.map({ allowedForegroundPIDs.contains($0.processIdentifier) }) == true
                    && identity.matchesCurrentProcess()
                    && !self.zilanPointerInteraction.isSuppressed
            }, mayPostEscape: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
            })
            guard dismissal != .rejected else {
                abortNativeWindowCommit(reason: "dismissRejected")
                preferences.publishFeedback("系统 Cmd-Tab 尚未关闭，请重试")
                return
            }
            recordNativeCommit("commitDismissRequested", ticket: ticket,
                reason: dismissal == .posted ? "hidEscape" : "alreadyAbsent", window: window)
        }
        nativeWindowCommitTask = Task { @MainActor [weak self] in
            defer {
                // A cancelled old task must not clear a subsequent click.
                if let self, self.nativeWindowCommit.finish(ticket) {
                    self.nativeWindowCommitTask = nil
                }
            }
            guard let self else { return }
            await WindowCommandTabCommitWorkflow.run(
                isCurrent: { self.nativeWindowCommit.isCurrent(ticket, sequenceID: self.eventSequenceID) },
                isValid: {
                    self.preferences.isEnabled && self.preferences.cmdTabPlusEnabled
                        && !self.zilanPointerInteraction.isSuppressed
                        && identity.matchesCurrentProcess()
                        && NSWorkspace.shared.frontmostApplication.map({ allowedForegroundPIDs.contains($0.processIdentifier) }) == true
                        && Self.mousePressCounts() == mouseInputCounts
                },
                readVisibility: { self.nativeSwitcher.commitVisibility(context) },
                decision: { self.nativeWindowCommit.observe(visibility: $0, for: ticket, sequenceID: self.eventSequenceID) },
                onConfirmed: {
                    // AX refresh can yield different lifetime/window evidence.
                    // Check native absence and input again after that work.
                    guard let app = NSRunningApplication(processIdentifier: identity.processIdentifier),
                          let fresh = self.freshWindow(matching: window, application: app),
                          !Task.isCancelled,
                          self.nativeWindowCommit.isCurrent(ticket, sequenceID: self.eventSequenceID),
                          !self.zilanPointerInteraction.isSuppressed,
                          let latestForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          allowedForegroundPIDs.contains(latestForegroundPID),
                          Self.mousePressCounts() == mouseInputCounts else {
                        self.abortNativeWindowCommit(reason: "targetChangedBeforeActivation")
                        return
                    }
                    let finalVisibility = self.nativeSwitcher.commitVisibility(context)
                    self.recordNativeCommit("commitVisibilityFinal", ticket: ticket, visibility: finalVisibility)
                    guard finalVisibility == .absent,
                          Self.mousePressCounts() == mouseInputCounts,
                          self.nativeWindowCommit.isCurrent(ticket, sequenceID: self.eventSequenceID),
                          NSWorkspace.shared.frontmostApplication.map({ allowedForegroundPIDs.contains($0.processIdentifier) }) == true else {
                        self.abortNativeWindowCommit(reason: "switcherOrInputChanged")
                        return
                    }
                    guard self.nativeWindowCommit.finish(ticket) else { return }
                    self.nativeWindowCommitTask = nil
                    self.recordNativeCommit("activationRequest", ticket: ticket, window: fresh)
                    self.activate(candidate: candidate, window: fresh, expectedMouseInputCounts: mouseInputCounts)
                },
                onAbort: { reason in
                    self.recordNativeCommit("commitVisibilityFinal", ticket: ticket,
                        reason: reason.rawValue)
                    self.abortNativeWindowCommit(reason: reason.rawValue)
                    if reason != .stateChanged {
                        self.preferences.publishFeedback("系统 Cmd-Tab 尚未关闭，可继续选择窗口")
                    }
                }
            )
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
        let activationSequence = eventSequenceID
        concreteWindowActivationTask = Task { @MainActor [weak self] in
            for delay in [45_000_000, 90_000_000, 160_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.eventSequenceID == activationSequence,
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
            let matches = currentWindows.filter {
                $0.windowID == expectedWindowID && $0.element != nil
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let originalElement = original.element else { return nil }
        let retainedMatches = currentWindows.filter {
            guard let currentElement = $0.element else { return false }
            return CFEqual(currentElement, originalElement)
        }
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
              let element = window.element,
              AXUIElementGetPid(element, &ownerPID) == .success,
              ownerPID == application.processIdentifier else { return false }
        if let expectedWindowID,
           windowIDAttribute(element) != expectedWindowID {
            return false
        }
        if boolAttribute(kAXMinimizedAttribute, of: element) == true {
            AXUIElementSetAttributeValue(
                element,
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
            element
        )
        AXUIElementSetAttributeValue(
            element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let raiseResult = AXUIElementPerformAction(
            element,
            kAXRaiseAction as CFString
        )
        guard focusResult == .success, raiseResult == .success,
              let focusedWindow = elementAttribute(
                kAXFocusedWindowAttribute,
                of: applicationElement
              ) else { return false }
        return CFEqual(focusedWindow, element)
    }

    private func cancel() {
        invalidateNativeClick()
        nativePreviewRefreshPending = false
        cancelNativeSessionReconciliation()
        concreteWindowActivationTask?.cancel()
        concreteWindowActivationTask = nil
        abortNativeWindowCommit(reason: "sessionCancelled", reconcile: false)
        nativeSelectionPending = false
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
        sharedPreviewFallbackTask?.cancel()
        sharedPreviewFallbackTask = nil
        thumbnailCaptureGeneration &+= 1
        commandSequenceActive = false
        hasExplicitWindowSelection = false
        nativeSwitcherAnchorFrame = nil
        nativeCommitContext = nil
        eventSequenceID &+= 1
        isPresenting = false
        candidates.removeAll()
        candidateLifecycleRevisions.removeAll()
        selectedWindowIndex = 0
        currentThumbnailResults.removeAll()
        overlay.hide()
    }

    /// Some applications omit a fullscreen window from AXWindows while its
    /// Space is inactive but continue exposing it as focused or main. Merge all
    /// three public AX sources, then collapse distinct proxies only when their
    /// exact WindowServer identity proves that they represent the same window.
    private func windowCandidates(
        for applications: [NSRunningApplication],
        messagingTimeout: Float? = nil
    ) -> [WindowCandidate] {
        let collected = applications
            .filter { !$0.isTerminated }
            .flatMap { windowCandidates(for: $0, messagingTimeout: messagingTimeout) }
        return WindowAXProxyPreDeduplicator.deduplicate(
            collected,
            ownerPID: { $0.application.processIdentifier },
            windowID: \.windowID,
            sameAXObject: { lhs, rhs in
                guard let lhsElement = lhs.element,
                      let rhsElement = rhs.element else { return false }
                return CFEqual(lhsElement, rhsElement)
            },
            merge: { [weak self] existing, candidate, canonicalWindowID in
                self?.mergedWindowCandidate(
                    existing: existing,
                    candidate: candidate,
                    canonicalWindowID: canonicalWindowID
                ) ?? existing
            }
        )
    }

    private func windowCandidates(
        for application: NSRunningApplication,
        messagingTimeout: Float? = nil
    ) -> [WindowCandidate] {
        let diagnosticsEnabled = WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let messagingTimeout { AXUIElementSetMessagingTimeout(appElement, messagingTimeout) }
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, of: appElement)
        let mainWindow = elementAttribute(kAXMainWindowAttribute, of: appElement)
        var collectedWindows: [AXUIElement] = []
        for preferredWindow in [focusedWindow, mainWindow].compactMap({ $0 })
        where !collectedWindows.contains(where: { CFEqual($0, preferredWindow) }) {
            collectedWindows.append(preferredWindow)
        }

        var windowsValue: CFTypeRef?
        let windowsAttributeResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        let attributeWindows = windowsValue as? [AXUIElement] ?? []
        if windowsAttributeResult == .success {
            let availableWindows = attributeWindows
            for window in availableWindows
            where !collectedWindows.contains(where: { CFEqual($0, window) }) {
                collectedWindows.append(window)
            }
        }

        // Preserve exact window identities delivered by AX lifecycle events.
        // This covers Apps that omit inactive real windows from AXWindows;
        // current private WindowServer evidence still decides admission.
        let lifecycleWindows = WindowAXLifecycleRegistry.shared.windowElements(
            for: application,
            refreshBeforeRead: messagingTimeout == nil
        )
        for window in lifecycleWindows
        where !collectedWindows.contains(where: { CFEqual($0, window) }) {
            collectedWindows.append(window)
        }

        var rawAXDiagnostics: [WindowInventoryAXCandidateDiagnostics] = []
        let resolvedCandidates = collectedWindows.compactMap { window -> WindowCandidate? in
            if let messagingTimeout { AXUIElementSetMessagingTimeout(window, messagingTimeout) }
            let token = rawAXDiagnostics.count
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(window, &ownerPID) == .success else {
                if diagnosticsEnabled {
                    rawAXDiagnostics.append(.ownerValidationFailure(
                        token: token,
                        ownerPID: 0,
                        isFocusedSource: focusedWindow.map { CFEqual($0, window) } ?? false,
                        isMainSource: mainWindow.map { CFEqual($0, window) } ?? false,
                        isWindowsAttributeSource: attributeWindows.contains { CFEqual($0, window) },
                        isLifecycleRegistrySource: lifecycleWindows.contains { CFEqual($0, window) }
                    ))
                }
                return nil
            }
            guard ownerPID == application.processIdentifier else {
                if diagnosticsEnabled {
                    rawAXDiagnostics.append(.ownerValidationFailure(
                        token: token,
                        ownerPID: ownerPID,
                        isFocusedSource: focusedWindow.map { CFEqual($0, window) } ?? false,
                        isMainSource: mainWindow.map { CFEqual($0, window) } ?? false,
                        isWindowsAttributeSource: attributeWindows.contains { CFEqual($0, window) },
                        isLifecycleRegistrySource: lifecycleWindows.contains { CFEqual($0, window) }
                    ))
                }
                return nil
            }
            let role = stringAttribute(kAXRoleAttribute, of: window) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, of: window) ?? ""
            let title = (stringAttribute(kAXTitleAttribute, of: window) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isMinimized = boolAttribute(
                kAXMinimizedAttribute,
                of: window
            ) ?? false
            let isPreferredWindow = [focusedWindow, mainWindow]
                .compactMap { $0 }
                .contains { CFEqual($0, window) }
            let isHidden = boolAttribute(
                kAXHiddenAttribute,
                of: window
            )
            let isVisible = boolAttribute(
                "AXVisible",
                of: window
            )
            let isModal = boolAttribute("AXModal", of: window)
            let hasMinimizedDocument = isMinimized
                && subrole == kAXDialogSubrole as String
                && isModal == false
                && isHidden != true
                && WindowPreviewCaptureEvidence.hasDocument(of: window)
            // Electron Apps can publish background standard-window shells.
            // Preserve a real focused/main or minimized untitled window, but
            // reject an otherwise hidden/invisible or untitled background
            // shell before it becomes an unavailable preview card.
            let shouldInclude = WindowAXCandidatePolicy.shouldInclude(
                role: role,
                subrole: subrole,
                isModal: isModal,
                title: title,
                isMinimized: isMinimized,
                isPreferredWindow: isPreferredWindow,
                isHidden: isHidden == true,
                isVisible: isVisible == false ? false : nil,
                hasDocument: hasMinimizedDocument
            )
            let diagnosticWindowID = diagnosticsEnabled ? windowIDAttribute(window) : nil
            let diagnosticBounds = diagnosticsEnabled ? windowBounds(window) : nil
            if diagnosticsEnabled {
                rawAXDiagnostics.append(WindowInventoryAXCandidateDiagnostics(
                    token: token,
                    ownerPID: ownerPID,
                    windowID: diagnosticWindowID,
                    role: role,
                    subrole: subrole,
                    titleLength: title.count,
                    bounds: diagnosticBounds,
                    isMinimized: isMinimized,
                    isPreferredWindow: isPreferredWindow,
                    isHidden: isHidden,
                    isVisible: isVisible,
                    isModal: isModal,
                    isFocusedSource: focusedWindow.map { CFEqual($0, window) } ?? false,
                    isMainSource: mainWindow.map { CFEqual($0, window) } ?? false,
                    isWindowsAttributeSource: attributeWindows.contains { CFEqual($0, window) },
                    isLifecycleRegistrySource: lifecycleWindows.contains { CFEqual($0, window) },
                    wasIncludedByAXPolicy: shouldInclude
                ))
            }
            guard shouldInclude else { return nil }
            let windowID = diagnosticsEnabled
                ? diagnosticWindowID
                : windowIDAttribute(window)
            let bounds = diagnosticsEnabled
                ? diagnosticBounds
                : windowBounds(window)
            return WindowCandidate(
                application: application,
                element: window,
                title: title,
                bounds: bounds,
                windowID: windowID,
                isMinimized: isMinimized,
                isPreferredWindow: isPreferredWindow,
                canClose: elementAttribute(kAXCloseButtonAttribute, of: window) != nil,
                allowsUniformContent: hasMinimizedDocument
                    || WindowPreviewCaptureEvidence.allowsUniformContent(of: window)
            )
        }

        // Before canonical reconciliation, deduplicate only the same AX object
        // or the same non-zero WindowServer ID. A title/geometry match is not
        // proof of identity: two real overlapping documents can be identical.
        let deduplicated = WindowAXProxyPreDeduplicator.deduplicate(
            resolvedCandidates,
            ownerPID: { $0.application.processIdentifier },
            windowID: \.windowID,
            sameAXObject: { lhs, rhs in
                guard let lhsElement = lhs.element,
                      let rhsElement = rhs.element else { return false }
                return CFEqual(lhsElement, rhsElement)
            },
            merge: { [weak self] existing, candidate, canonicalWindowID in
                self?.mergedWindowCandidate(
                    existing: existing,
                    candidate: candidate,
                    canonicalWindowID: canonicalWindowID
                ) ?? existing
            }
        )
        let processIdentity = WindowThumbnailApplicationIdentity(
            application: application
        )
        let processLifetimeKey = processIdentity?.processLifetimeKey
        let retainedWindowIDs = processLifetimeKey.map {
            WindowInventoryBindingHistory.shared.windowIDs(for: $0)
        } ?? []
        let currentExactWindowIDs = Set(deduplicated.compactMap(\.windowID))
        let snapshot = WindowServerInventoryService.shared.snapshot(
            for: [application.processIdentifier],
            requestedWindowIDs: currentExactWindowIDs.union(retainedWindowIDs)
        )
        let inventoryCandidates = deduplicated.enumerated().map { index, candidate in
                WindowInventoryCandidate(
                    token: index,
                    ownerPID: application.processIdentifier,
                    windowID: candidate.windowID,
                    title: candidate.title,
                    bounds: candidate.bounds,
                    isMinimized: candidate.isMinimized,
                    isPreferredWindow: candidate.isPreferredWindow
                )
            }
        let resolution = WindowInventoryReconciler.resolve(
            candidates: inventoryCandidates,
            snapshot: snapshot,
            retainedWindowIDs: retainedWindowIDs
        )
        if snapshot.mode == .skyLight, let processLifetimeKey {
            let liveValidatedIDs = Set<CGWindowID>(snapshot.surfaces.compactMap { surface in
                guard WindowInventoryReconciler.isRetainablePrivateTarget(
                    surface,
                    mode: snapshot.mode
                ) else { return nil }
                return surface.windowID
            })
            let newlyConfirmedIDs = Set<CGWindowID>(resolution.windows.compactMap { resolved in
                guard let operationToken = resolved.operationToken,
                      deduplicated.indices.contains(operationToken),
                      deduplicated[operationToken].windowID == resolved.surface.windowID,
                      resolved.confidence == .exactWindowServerID,
                      WindowInventoryReconciler.isRetainablePrivateTarget(
                          resolved.surface,
                          mode: snapshot.mode
                      ) else { return nil }
                return resolved.surface.windowID
            })
            WindowInventoryBindingHistory.shared.recordObservation(
                processIdentifier: application.processIdentifier,
                processLifetimeKey: processLifetimeKey,
                confirmedExactWindowIDs: newlyConfirmedIDs,
                liveValidatedWindowIDs: liveValidatedIDs,
                snapshotCapturedAt: snapshot.capturedAt,
                snapshotIsComplete: snapshot.isComplete
            )
        }
        logger.debug(
            "Cmd-Tab inventory pid=\(application.processIdentifier, privacy: .public) mode=\(snapshot.mode.rawValue, privacy: .public) ax=\(resolvedCandidates.count, privacy: .public) proxies=\(deduplicated.count, privacy: .public) surfaces=\(snapshot.surfaces.count, privacy: .public) resolved=\(resolution.windows.count, privacy: .public) rejected=\(resolution.rejections.count, privacy: .public)"
        )
        if diagnosticsEnabled {
            WindowInventoryDiagnosticRecorder.shared.record(
                source: .commandTab,
                applicationBundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier,
                axSources: WindowInventoryAXSourceDiagnostics(
                    hasFocusedWindow: focusedWindow != nil,
                    hasMainWindow: mainWindow != nil,
                    windowsAttributeResult: Int32(windowsAttributeResult.rawValue),
                    windowsAttributeCount: attributeWindows.count,
                    lifecycleRegistryCount: lifecycleWindows.count,
                    collectedCount: collectedWindows.count
                ),
                rawAXCandidates: rawAXDiagnostics,
                reconcilerCandidates: inventoryCandidates,
                lifecycle: WindowAXLifecycleRegistry.shared.diagnosticSnapshot(
                    for: application
                ),
                snapshot: snapshot,
                retainedWindowIDs: retainedWindowIDs,
                resolution: resolution
            )
        }
        return resolution.windows.compactMap { resolved in
            if let operationToken = resolved.operationToken {
                guard deduplicated.indices.contains(operationToken) else {
                    return nil
                }
                let candidate = deduplicated[operationToken]
                return WindowCandidate(
                    application: candidate.application,
                    element: candidate.element,
                    title: candidate.title,
                    bounds: resolved.surface.bounds,
                    windowID: resolved.surface.windowID,
                    isMinimized: candidate.isMinimized,
                    isPreferredWindow: candidate.isPreferredWindow,
                    canClose: candidate.canClose,
                    allowsUniformContent: candidate.allowsUniformContent
                )
            }
            let surfaceTitle = resolved.surface.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return WindowCandidate(
                application: application,
                element: nil,
                title: surfaceTitle.isEmpty ? "未命名窗口" : surfaceTitle,
                bounds: resolved.surface.bounds,
                windowID: resolved.surface.windowID,
                isMinimized: false,
                isPreferredWindow: false,
                canClose: false,
                allowsUniformContent: false
            )
        }
    }

    private func mergedWindowCandidate(
        existing: WindowCandidate,
        candidate: WindowCandidate,
        canonicalWindowID: CGWindowID?
    ) -> WindowCandidate {
        let operationProxy: WindowCandidate
        if existing.element == nil, candidate.element != nil {
            operationProxy = candidate
        } else if existing.element != nil, candidate.element == nil {
            operationProxy = existing
        } else {
            let useCandidate = WindowAXOperationProxyPolicy.prefersCandidate(
                existing: proxyEvidence(for: existing),
                candidate: proxyEvidence(for: candidate)
            )
            operationProxy = useCandidate ? candidate : existing
        }
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

    private func observeApplicationActivationIfNeeded() {
        guard activationObserver == nil, deactivationObserver == nil else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        activationObserver = workspaceCenter.addObserver(
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
                WindowLifecycleDiagnosticRecorder.shared.record(event: "applicationActivated", metadata: [
                    "ownerPID": .integer(Int64(application.processIdentifier))
                ])
                WindowAXLifecycleRegistry.shared.observe(
                    application: application
                )
                self?.schedulePrewarm(for: application)
            }
        }
        deactivationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.preferences.isEnabled,
                      self.preferences.cmdTabPlusEnabled || self.preferences.dockPreviewEnabled,
                      application.activationPolicy == .regular,
                      !application.isTerminated,
                      !self.preferences.isExcluded(application) else { return }
                WindowLifecycleDiagnosticRecorder.shared.record(event: "applicationDeactivated", metadata: [
                    "ownerPID": .integer(Int64(application.processIdentifier))
                ])
                // Refresh the event-driven registry as the App leaves the
                // foreground. This performs AX reads only at a lifecycle edge;
                // WindowServer reconciliation remains demand-driven on hover
                // or Cmd-Tab presentation.
                WindowAXLifecycleRegistry.shared.observe(
                    application: application
                )
            }
        }
        // Do not prewarm background Apps at launch. The native switcher path
        // enumerates only its selected App, and subsequent activations refresh
        // that App opportunistically. This keeps the always-on footprint low.
    }

    private func recordLifecycleRevisions(for applications: [NSRunningApplication]) {
        for identity in thumbnailApplicationIdentities(for: applications) {
            candidateLifecycleRevisions[identity.processLifetimeKey] =
                WindowAXLifecycleRegistry.shared.revision(for: identity)
        }
    }

    private func observePreviewInvalidationIfNeeded() {
        guard previewInvalidationObserver == nil else { return }
        windowRetirementObserver = NotificationCenter.default.addObserver(
            forName: WindowAXLifecycleRegistry.didRetireWindowsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = notification.object as? WindowAXLifecycleChange else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelPrewarmTasks(retiredBy: change)
                guard self.isPresenting,
                      self.candidates.indices.contains(self.selectedIndex),
                      let capturedRevision = self.candidateLifecycleRevisions[change.processLifetimeKey],
                      change.invalidates(capturedRevision) else { return }
                let candidate = self.candidates[self.selectedIndex]
                let affected = candidate.windows.contains { window in
                    change.affects(
                        processLifetimeKey: WindowThumbnailApplicationIdentity(
                            application: window.application
                        )?.processLifetimeKey,
                        windowID: window.windowID
                    )
                } || self.previewOnlyWindows.contains { window in
                    candidate.applications.contains { application in
                        application.processIdentifier == window.identity.processID && change.affects(
                            processLifetimeKey: WindowThumbnailApplicationIdentity(
                                application: application
                            )?.processLifetimeKey,
                            windowID: window.identity.windowID
                        )
                    }
                }
                // A window acknowledged by our own close path was already
                // removed from candidates. Only cancel a still-stale selection.
                if affected { self.cancel() }
            }
        }
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
            requests: requests,
            lifecycleRevision: WindowAXLifecycleRegistry.shared.revision(for: applicationIdentity),
            cacheGeneration: WindowThumbnailProvider.cacheGenerationSnapshot(for: applicationIdentity)
        )
        pendingPrewarmJobs[processIdentifier] = job
        if !pendingPrewarmOrder.contains(processIdentifier) {
            // New activations should prewarm before older startup seeds.
            pendingPrewarmOrder.insert(processIdentifier, at: 0)
        }
        drainPrewarmQueueIfNeeded()
    }

    private func cancelPrewarmTasks() {
        prewarmGeneration &+= 1
        activePrewarmTask?.cancel()
        activePrewarmTask = nil
        activePrewarmPID = nil
        activePrewarmLifetimeKey = nil
        activePrewarmRevision = nil
        pendingPrewarmJobs.removeAll(keepingCapacity: false)
        pendingPrewarmOrder.removeAll(keepingCapacity: false)
    }

    private func cancelPrewarmTasks(retiredBy change: WindowAXLifecycleChange) {
        let removedPIDs = Set(pendingPrewarmJobs.compactMap { pid, job in
            guard job.applicationIdentity.processLifetimeKey == change.processLifetimeKey,
                  let revision = job.lifecycleRevision,
                  change.invalidates(revision) else { return nil as pid_t? }
            return pid
        })
        for pid in removedPIDs { pendingPrewarmJobs.removeValue(forKey: pid) }
        pendingPrewarmOrder.removeAll { removedPIDs.contains($0) }
        if activePrewarmLifetimeKey == change.processLifetimeKey,
           let revision = activePrewarmRevision, change.invalidates(revision) {
            prewarmGeneration &+= 1
            activePrewarmTask?.cancel()
            activePrewarmTask = nil
            activePrewarmPID = nil
            activePrewarmLifetimeKey = nil
            activePrewarmRevision = nil
        }
        drainPrewarmQueueIfNeeded()
    }

    private func drainPrewarmQueueIfNeeded() {
        guard activePrewarmTask == nil else { return }
        while let processIdentifier = pendingPrewarmOrder.first {
            pendingPrewarmOrder.removeFirst()
            guard let job = pendingPrewarmJobs.removeValue(
                forKey: processIdentifier
            ) else { continue }
            guard WindowAXLifecycleRegistry.shared.revision(for: job.applicationIdentity)
                == job.lifecycleRevision else { continue }

            activePrewarmPID = processIdentifier
            activePrewarmLifetimeKey = job.applicationIdentity.processLifetimeKey
            activePrewarmRevision = job.lifecycleRevision
            prewarmGeneration &+= 1
            let generation = prewarmGeneration
            activePrewarmTask = Task.detached(priority: .utility) { [weak self] in
                _ = await WindowThumbnailProvider.captureWindows(
                    applicationIdentity: job.applicationIdentity,
                    requests: job.requests,
                    expectedCacheGeneration: job.cacheGeneration
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.activePrewarmPID == processIdentifier,
                          self.prewarmGeneration == generation else { return }
                    self.activePrewarmTask = nil
                    self.activePrewarmPID = nil
                    self.activePrewarmLifetimeKey = nil
                    self.activePrewarmRevision = nil
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
        var isSharedWeChat = false
        var commitContext: CommitContext? = nil

        var application: NSRunningApplication {
            applications[0]
        }
    }

    enum SnapshotResult {
        case visible(Snapshot)
        case notVisible
        case ambiguous
    }

    static let sharedCommitEventMarker: Int64 = 0x574531435442

    final class CommitContext {
        let dockApplication: NSRunningApplication
        let dockPID: pid_t
        let dockLaunchDate: Date?
        let list: AXUIElement
        let parent: AXUIElement
        let childrenAttribute: String
        var usedFallbackDiscovery = false

        init(dockApplication: NSRunningApplication, dockPID: pid_t, dockLaunchDate: Date?,
             list: AXUIElement, parent: AXUIElement, childrenAttribute: String) {
            self.dockApplication = dockApplication
            self.dockPID = dockPID
            self.dockLaunchDate = dockLaunchDate
            self.list = list
            self.parent = parent
            self.childrenAttribute = childrenAttribute
        }
    }

    typealias CommitVisibility = WindowCommandTabCommitCoordinator.Visibility

    private func makeCommitContext(list: AXUIElement) -> CommitContext? {
        guard let dockPID = cachedDockPID,
              let dock = NSRunningApplication(processIdentifier: dockPID),
              dock.bundleIdentifier == "com.apple.dock", !dock.isTerminated,
              let parent = elementAttribute(kAXParentAttribute, of: list) else { return nil }
        for attribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement],
                  children.contains(where: { CFEqual($0, list) }) else { continue }
            return CommitContext(dockApplication: dock, dockPID: dockPID, dockLaunchDate: dock.launchDate, list: list, parent: parent, childrenAttribute: attribute)
        }
        return nil
    }

    func commitVisibility(_ context: CommitContext) -> CommitVisibility {
        guard AXIsProcessTrusted(), !context.dockApplication.isTerminated,
              let dock = NSRunningApplication(processIdentifier: context.dockPID),
              !dock.isTerminated, dock.bundleIdentifier == "com.apple.dock",
              dock.launchDate == context.dockLaunchDate else { return .unknown }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(context.parent, context.childrenAttribute as CFString, &value)
        guard error == .success, let children = value as? [AXUIElement] else {
            // A retired AX parent is not proof of absence. This exceptional
            // path makes one bounded fresh read, never a full-tree retry loop.
            return freshCommitVisibility(context)
        }
        if children.contains(where: { CFEqual($0, context.list) }) {
            guard let listFrame = frame(of: context.list) else { return .unknown }
            return listFrame.width > 20 && listFrame.height > 20 ? .visible : .unknown
        }
        // The normal Dock layout exposes the list directly under its App.
        // Verify this exact live root before using its complete children read
        // as absence evidence. Other hierarchies require bounded rediscovery.
        guard CFEqual(context.parent, AXUIElementCreateApplication(context.dockPID)),
              children.count <= 32 else { return freshCommitVisibility(context) }
        for child in children {
            var subroleValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleValue)
            guard result == .success || result == .noValue || result == .attributeUnsupported else { return .unknown }
            if subroleValue as? String == kAXProcessSwitcherListSubrole as String {
                return .unknown // A replacement list belongs to a new session.
            }
        }
        return .absent
    }

    private func freshCommitVisibility(_ context: CommitContext) -> CommitVisibility {
        guard !context.usedFallbackDiscovery else { return .unknown }
        context.usedFallbackDiscovery = true
        let root = AXUIElementCreateApplication(context.dockPID)
        AXUIElementSetMessagingTimeout(root, 0.025)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.120
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var cursor = 0
        while cursor < queue.count {
            guard visited.count < 32, ProcessInfo.processInfo.systemUptime < deadline else { return .unknown }
            let (element, depth) = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.025)
            var subroleValue: CFTypeRef?
            let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
            guard subroleError == .success || subroleError == .noValue || subroleError == .attributeUnsupported else { return .unknown }
            if subroleValue as? String == kAXProcessSwitcherListSubrole as String {
                guard CFEqual(element, context.list), let listFrame = frame(of: element),
                      listFrame.width > 20, listFrame.height > 20 else { return .unknown }
                return .visible
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .unknown }
            var childrenValue: CFTypeRef?
            let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            if childrenError == .noValue || childrenError == .attributeUnsupported { continue }
            guard childrenError == .success, let children = childrenValue as? [AXUIElement] else { return .unknown }
            guard children.isEmpty || (depth < 6 && queue.count + children.count <= 64) else { return .unknown }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? .absent : .unknown
    }

    func dismissForWindowCommit(
        _ context: CommitContext, stillValid: () -> Bool, mayPostEscape: () -> Bool
    ) -> WindowCommandTabCommitCoordinator.Dismissal {
        // Both visibility and input evidence must be current immediately before
        // this one pair. Never retry Escape later against a different session.
        let visibility = commitVisibility(context)
        guard stillValid() else { return .rejected }
        if visibility == .absent { return .alreadyAbsent }
        guard visibility == .visible, mayPostEscape(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return .rejected }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.sharedCommitEventMarker)
            // Dock handles the system switcher in the session input path.
            // Process-directed events bypass that route; WINS uses HID here.
            event.post(tap: .cghidEventTap)
        }
        return .posted
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
            listFrame: listFrame,
            recordsIdentityFailure: true
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
                selectedItemFrame: frame(of: selection.anchorElement),
                isSharedWeChat: selection.isSharedWeChat,
                commitContext: makeCommitContext(list: context.list)
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
        listFrame: CGRect,
        recordsIdentityFailure: Bool = false
    ) -> SnapshotResult {
        switch resolveApplication(
            from: element, in: list,
            recordsIdentityFailure: recordsIdentityFailure
        ) {
        case let .success(selection):
            return .visible(
                Snapshot(
                    applications: selection.applications,
                    listFrame: listFrame,
                    selectedItemFrame: frame(of: selection.anchorElement),
                isSharedWeChat: selection.isSharedWeChat,
                    commitContext: makeCommitContext(list: list)
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
        var isSharedWeChat = false

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
                guard let identity = selectionGroupIdentity(selection) else { return .ambiguous }
                if let existing = selectionsByIdentity[identity] {
                    if existing.isSharedWeChat && selection.isSharedWeChat {
                        selectionsByIdentity[identity] = existing
                    } else {
                        guard let mergedApplications = mergeApplications(existing.applications, selection.applications) else { return .ambiguous }
                        selectionsByIdentity[identity] = SelectedApplication(applications: mergedApplications, anchorElement: existing.anchorElement)
                    }
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
        in list: AXUIElement,
        recordsIdentityFailure: Bool = false
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
        var allAmbiguousScopesComplete = true
        var diagnosticEvidence: (applications: [NSRunningApplication], firstDepth: Int)?
        scopeLoop: for scope in lineage {
            var scopeEvidence: (applications: [NSRunningApplication], firstDepth: Int)?
            switch resolveApplication(
                in: scope,
                maximumDepth: 3,
                applications: applications,
                diagnosticEvidence: &scopeEvidence
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
                if scopeEvidence == nil { allAmbiguousScopesComplete = false }
                if diagnosticEvidence == nil { diagnosticEvidence = scopeEvidence }
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
            let selection = SelectedApplication(applications: selectedApplications, anchorElement: anchorElement)
            return .success(expandKnownWeChatSelection(selection, selectedElement: selectedElement, running: applications))
        }
        if sawAmbiguousScope, allAmbiguousScopesComplete,
           let diagnosticEvidence,
           diagnosticEvidence.firstDepth == 0,
           let shared = weakSharedWeChatSelection(from: selectedElement, running: applications) {
            return .success(shared)
        }
        if recordsIdentityFailure, sawAmbiguousScope, let diagnosticEvidence {
            // Only the native selected-tile snapshot opts into sampling.
            // Pointer candidates can fail here then resolve through a fallback;
            // those intermediate failures must not consume diagnostic capacity.
            WindowNativeIdentityDiagnostics.shared.capture(
                element: selectedElement,
                applications: diagnosticEvidence.applications,
                firstDepth: diagnosticEvidence.firstDepth
            )
        }
        return sawAmbiguousScope ? .ambiguous : .notFound
    }

    private func expandKnownWeChatSelection(
        _ selection: SelectedApplication,
        selectedElement: AXUIElement,
        running: [NSRunningApplication]
    ) -> SelectedApplication {
        guard selection.applications.allSatisfy({
            WindowCommandTabSharingPolicy.installation(for: weChatSharingApplication($0)) != nil
        }) else { return selection }
        let values = directIdentityValues(from: selectedElement, includeCustomIdentityAttributes: true)
        let selected = selection.applications.map(weChatSharingApplication)
        let strongStrings = values.strings.filter { $0.contains("/") || $0.contains(".") }
        guard !values.processIdentifiers.isEmpty || !values.urls.isEmpty || !strongStrings.isEmpty else {
            return weakSharedWeChatSelection(from: selectedElement, running: running) ?? selection
        }
        // Unmatched/conflicting strong values must not be rescued by a name.
        guard values.processIdentifiers.isEmpty || Set(values.processIdentifiers) == Set(selected.map(\.processID)),
              values.urls.allSatisfy({ url in url.isFileURL && selected.contains { $0.bundlePath == url.standardizedFileURL.resolvingSymlinksInPath().path } }),
              values.strings.filter({ $0.contains("/") || $0.contains(".") }).allSatisfy({ value in
                  selection.applications.contains { app in
                      value == app.bundleIdentifier || value == app.bundleURL?.path || value == app.bundleURL?.absoluteString
                  }
              }),
              let group = WindowCommandTabSharingPolicy.sharedWeChatGroup(
                selected: selected, running: running.map(weChatSharingApplication), evidence: .resolvedIdentity
              ) else { return selection }
        let byPID = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        return SelectedApplication(
            applications: group.processIDs.compactMap { byPID[$0] },
            anchorElement: selection.anchorElement,
            isSharedWeChat: true
        )
    }

    private func weakSharedWeChatSelection(
        from element: AXUIElement,
        running: [NSRunningApplication]
    ) -> SelectedApplication? {
        guard stringAttribute(kAXRoleAttribute, of: element) == kAXButtonRole as String,
              let title = stringAttribute(kAXTitleAttribute, of: element),
              title == "微信" || title == "WeChat" else { return nil }
        var rawNames: CFArray?
        guard AXUIElementCopyAttributeNames(element, &rawNames) == .success,
              let names = rawNames as? [String] else { return nil }
        // Never call a failed/truncated hierarchy probe an empty leaf.
        for name in [kAXChildrenAttribute, kAXVisibleChildrenAttribute] where names.contains(name) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if error == .noValue { continue }
            guard error == .success,
                  let values = value as? [AXUIElement], values.isEmpty else { return nil }
        }
        let keywords = ["bundle", "identifier", "url", "path", "application", "process", "pid"]
        let identityNames = names.filter { name in keywords.contains { name.lowercased().contains($0) } }
        guard identityNames.count <= 24 else { return nil }
        let scalarNames = Set(identityNames + [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute])
        for name in scalarNames where names.contains(name) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if error == .noValue { continue }
            guard error == .success else { return nil }
            // A read failure or an unrecognized scalar/reference must not be
            // mistaken for lack of stronger identity.
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || trimmed == title || trimmed == "微信" || trimmed == "WeChat" else { return nil }
        }
        let values = directIdentityValues(from: element, includeCustomIdentityAttributes: true)
        let hasStrongIdentity = !values.urls.isEmpty || !values.processIdentifiers.isEmpty
            || values.strings.contains { $0 != title && $0 != "微信" && $0 != "WeChat" }
        let selected = matchingApplications(identityValues: values, applications: running)
        guard let group = WindowCommandTabSharingPolicy.sharedWeChatGroup(
            selected: selected.map(weChatSharingApplication), running: running.map(weChatSharingApplication),
            evidence: .weakSelectedButton(title: title, isLeaf: true, searchComplete: true, hasStrongIdentity: hasStrongIdentity)
        ) else { return nil }
        let byPID = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        return SelectedApplication(applications: group.processIDs.compactMap { byPID[$0] }, anchorElement: element, isSharedWeChat: true)
    }

    private func selectionGroupIdentity(_ selection: SelectedApplication) -> String? {
        if selection.isSharedWeChat {
            return "sharedWeChat:" + selection.applications.map { String($0.processIdentifier) }.sorted().joined(separator: ",")
        }
        return applicationGroupIdentity(for: selection.applications)
    }

    private func resolveApplication(
        in root: AXUIElement,
        maximumDepth: Int,
        applications: [NSRunningApplication],
        diagnosticEvidence: inout (applications: [NSRunningApplication], firstDepth: Int)?
    ) -> IdentityResolution {
        let maximumIdentityNodes = 48
        var currentLevel = [root]
        var currentLevelWasTruncated = false
        var visited: [AXUIElement] = []
        var ambiguousMatchCount = 0
        var ambiguousMatchDepth = 0
        var ambiguousEvidence = ""
        var ambiguousApplications: [NSRunningApplication] = []
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
                    ambiguousApplications = matches
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
            diagnosticEvidence = (ambiguousApplications, ambiguousMatchDepth)
            WindowInteractionDiagnosticRecorder.shared.record(
                component: "cmdTab", event: "identityAmbiguous",
                metadata: [
                    "firstDepth": .integer(Int64(ambiguousMatchDepth)),
                    "matchCount": .integer(Int64(ambiguousMatchCount))
                ]
            )
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
    var hasPendingPointerPress: Bool { model.hasPendingPointerPress }
    private let previewPanel: WindowPreviewInteractionPanel
    private let previewContentView: CommandTabPanelContentView<CommandTabPreviewView>
    private var presentationScreen: NSScreen?
    private var nativeClickSuspended = false
    private var hoveredWindowSelection: CommandTabPreviewTarget?
    private var interactionGeneration: UInt64 = 0
    private var recentCacheExpirationGeneration = 0
    private var recentCacheExpirationWorkItem: DispatchWorkItem?
    private var lastPointerDiagnosticTime: TimeInterval = 0

    init() {
        let model = CommandTabOverlayModel()
        let previewContentView = CommandTabPanelContentView(
            rootView: CommandTabPreviewView(model: model)
        )
        let previewPanel = WindowPreviewInteractionPanel(
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
        diagnosticSequence: Int,
        allowsSyntheticHoverSelection: Bool = true,
        onCommitWindow: @escaping (Int, Int) -> Void,
        onHoverWindow: @escaping (Int, Int) -> Void,
        onCloseWindow: @escaping (Int, Int) -> Void
    ) {
        interactionGeneration &+= 1
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
        WindowInteractionDiagnosticRecorder.shared.record(
            component: "cmdTab", event: "previewModel", metadata: model.diagnosticMetadata()
        )
        rescheduleRecentCacheExpiration()

        // Dock owns and draws the native application strip. SuperIsland adds
        // only the selected application's window preview above it.
        previewPanel.orderFrontRegardless()
        previewContentView.layoutSubtreeIfNeeded()
        if WindowCommandTabDiagnostics.enabled {
            var metadata: [String: WindowInteractionDiagnosticValue] = [
                "sequence": .integer(Int64(clamping: diagnosticSequence)),
                "displayID": .integer(Int64((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)),
                "visible": .flag(previewPanel.isVisible)
            ]
            WindowCommandTabDiagnostics.addFrame(anchorAXFrame, prefix: "anchorAX", to: &metadata)
            WindowCommandTabDiagnostics.addFrame(previewPanel.frame, prefix: "panelAppKit", to: &metadata)
            WindowCommandTabDiagnostics.recorder.record(event: "previewPlacement", metadata: metadata)
        }
        let generation = interactionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.interactionGeneration == generation,
                  self.previewPanel.isVisible else { return }
            self.previewContentView.layoutSubtreeIfNeeded()
            _ = self.handleExternalPointer(
                type: .mouseMoved,
                at: NSEvent.mouseLocation,
                deferAction: true,
                allowsHoverSelection: allowsSyntheticHoverSelection
            )
        }
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
        deferAction: Bool = false,
        allowsHoverSelection: Bool = true
    ) -> Bool {
        guard !nativeClickSuspended, previewPanel.isVisible else { return false }
        let panelPoint = previewPanel.convertPoint(fromScreen: screenLocation)
        let point = CGPoint(
            x: panelPoint.x,
            y: (previewPanel.contentView?.bounds.height ?? 0) - panelPoint.y
        )
        guard previewPanel.frame.contains(screenLocation) else {
            handlePointer(type: .mouseExited, point: point, deferAction: deferAction)
            return false
        }
        handlePointer(type: type, point: point, deferAction: deferAction, allowsHoverSelection: allowsHoverSelection)
        return true
    }

    func containsPointer(_ point: CGPoint) -> Bool {
        previewPanel.isVisible && previewPanel.frame.contains(point)
    }

    func setNativeClickSuspended(_ suspended: Bool) {
        guard nativeClickSuspended != suspended else { return }
        nativeClickSuspended = suspended
        // Also invalidate AppKit/SwiftUI hover callbacks queued before the
        // native press. They share the same pause as the CG event-tap route.
        interactionGeneration &+= 1
        clearPointerSelection()
    }

    func clearPointerSelection() {
        hoveredWindowSelection = nil
        model.clearPointerSelection()
    }

    private func handlePointer(type: NSEvent.EventType, point: CGPoint, deferAction: Bool, allowsHoverSelection: Bool = true) {
        guard !nativeClickSuspended else { return }
        let action = model.handlePointer(type, at: point)
        if WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPointerDiagnosticTime >= 0.5 {
                lastPointerDiagnosticTime = now
                var metadata = model.diagnosticMetadata(at: type == .mouseExited ? nil : point)
                metadata["insidePanel"] = .flag(type != .mouseExited)
                metadata["externalTap"] = .flag(deferAction)
                metadata["eventType"] = .integer(Int64(type.rawValue))
                if type == .mouseExited || metadata["hitCount"] != .integer(1) {
                    // Only failed hits need coordinates; keep successful-hit
                    // records within the recorder's 16-field privacy budget.
                    // Coordinates are relative to our panel, never AX text.
                    for (key, value) in [
                        ("pointerX", point.x), ("pointerY", point.y),
                        ("panelWidth", previewPanel.frame.width),
                        ("panelHeight", previewPanel.frame.height)
                    ] where value.isFinite && abs(value) < 1_000_000 {
                        metadata[key] = .integer(Int64(value.rounded()))
                    }
                }
                WindowInteractionDiagnosticRecorder.shared.record(
                    component: "cmdTab", event: "previewPointer", metadata: metadata
                )
            }
        }
        let hovered = model.pointerHoveredTarget
        let changed = hoveredWindowSelection != hovered
        hoveredWindowSelection = allowsHoverSelection ? hovered : nil
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
            if allowsHoverSelection, changed, let hovered, self.model.pointerHoveredTarget == hovered,
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
    @Published private(set) var previewFrameGeneration: UInt64 = 0

    private var previewFrames: [CommandTabPreviewTarget: CGRect] = [:]
    private var previewFrameOwners: [CommandTabPreviewTarget: UInt64] = [:]
    private var pointerState = WindowPreviewPointerState<CommandTabPreviewTarget>()
    var hasPendingPointerPress: Bool { pointerState.hasPendingPress }

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
            previewFrameGeneration &+= 1
            previewFrames = [:]
            previewFrameOwners = [:]
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
        previewFrameGeneration &+= 1
        items = []
        selectedID = 0
        previewTileWidth = 220
        reduceMotion = false
        onCommitWindow = { _, _ in }
        onHoverWindow = { _, _ in }
        onCloseWindow = { _, _ in }
        pointerHoveredTarget = nil
        previewFrames = [:]
        previewFrameOwners = [:]
        pointerState = WindowPreviewPointerState()
    }

    func setPreviewFrames(_ frames: [CommandTabPreviewTarget: CGRect]) {
        previewFrames = frames.filter { isCurrent($0.key) }
        updatePointerFrames()
    }

    func setPreviewFrame(
        _ frame: CGRect?,
        for target: CommandTabPreviewTarget,
        generation: UInt64? = nil,
        owner: UInt64? = nil
    ) {
        if let generation, generation != previewFrameGeneration { return }
        guard frame == nil || isCurrent(target) else { return }
        if let owner {
            if frame != nil {
                guard owner >= (previewFrameOwners[target] ?? 0) else { return }
                previewFrameOwners[target] = owner
            } else {
                guard previewFrameOwners[target] == owner else { return }
            }
        } else if previewFrameOwners[target] != nil {
            return
        }
        if let frame {
            previewFrames[target] = frame
        } else {
            // Keep the owner as a tombstone until the frame generation changes.
            // A retiring SwiftUI view must neither erase its replacement's
            // rectangle nor restore its old rectangle after that view detaches.
            previewFrames.removeValue(forKey: target)
        }
        updatePointerFrames()
    }

    func diagnosticMetadata(at point: CGPoint? = nil) -> [String: WindowInteractionDiagnosticValue] {
        let windows = selectedItem?.windows ?? []
        var values: [String: WindowInteractionDiagnosticValue] = [
            "windowCount": .integer(Int64(windows.count)),
            "frameCount": .integer(Int64(previewFrames.count)),
            "closableCount": .integer(Int64(windows.filter(\.canClose).count)),
            "activatableCount": .integer(Int64(windows.filter(\.canActivate).count)),
            "imageCount": .integer(Int64(windows.filter { $0.thumbnailResult?.image != nil }.count)),
            "frameGeneration": .integer(Int64(clamping: previewFrameGeneration))
        ]
        if let point {
            let hits = previewFrames.filter { isCurrent($0.key) && $0.value.contains(point) }
            values["hitCount"] = .integer(Int64(hits.count))
            if hits.count == 1, let target = hits.first?.key {
                values["hitPID"] = .integer(Int64(target.identity.processID))
                values["hitWindowID"] = .integer(Int64(target.identity.windowID))
                let hitWindow = windows.first(where: {
                    $0.id == target.windowIndex && $0.identity == target.identity
                })
                values["hitCanClose"] = .flag(hitWindow?.canClose == true)
                values["hitCanActivate"] = .flag(hitWindow?.canActivate == true)
                values["hitHasImage"] = .flag(hitWindow?.thumbnailResult?.image != nil)
            }
        }
        return values
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

                Text(item.isLoading ? "正在读取预览…" : "暂无可预览窗口")
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
        let frameGeneration = model.previewFrameGeneration
        return CommandTabWindowPreviewTile(
            target: target,
            window: window,
            icon: item.icon,
            width: model.previewTileWidth,
            isPointerHovered: model.pointerHoveredTarget == target,
            frameGeneration: frameGeneration,
            onCommit: {
                guard model.isCurrent(target), window.canActivate else { return }
                model.onCommitWindow(item.id, window.id)
            },
            onClose: {
                guard model.isCurrent(target), window.canClose else { return }
                model.onCloseWindow(item.id, window.id)
            },
            onFrameChange: { target, frame, owner in
                model.setPreviewFrame(frame, for: target, generation: frameGeneration, owner: owner)
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
    let frameGeneration: UInt64
    let onCommit: () -> Void
    let onClose: () -> Void
    let onFrameChange: (CommandTabPreviewTarget, CGRect?, UInt64) -> Void

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
                generation: frameGeneration,
                onOwnedChange: onFrameChange
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
                    title: "重启 WE1 后显示",
                    symbol: "arrow.clockwise"
                )
            case .notEnumerated:
                previewFailure(
                    title: "全屏预览暂不可用",
                    symbol: "rectangle.on.rectangle"
                )
            case .ambiguous:
                previewFailure(
                    title: "无法确定对应窗口",
                    symbol: "questionmark.square"
                )
            case .captureFailed:
                previewFailure(
                    title: "预览暂不可用",
                    symbol: "exclamationmark.triangle"
                )
            }
        } else {
            VStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在生成预览…")
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
