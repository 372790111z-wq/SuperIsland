import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import OSLog
import ScreenCaptureKit

/// A cache identity for one concrete application process. PID and WindowServer
/// window numbers can both be reused, so neither is safe as a cache namespace
/// on its own. The process start time prevents a later process with the same
/// bundle identifier and PID from reading thumbnails captured for an earlier
/// instance.
struct WindowThumbnailApplicationIdentity: Sendable, Equatable {
    let processIdentifier: pid_t
    fileprivate let cacheNamespace: String
    fileprivate let bundlePath: String?

    /// Stable only for this concrete process launch. Window inventory uses the
    /// same namespace so a recycled PID can never inherit old window IDs.
    var processLifetimeKey: String { cacheNamespace }

    init?(application: NSRunningApplication) {
        let processIdentifier = application.processIdentifier
        guard processIdentifier > 0,
              !application.isTerminated,
              let bundleIdentifier = application.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty,
              let processStartToken = Self.processStartToken(
                processIdentifier: processIdentifier,
                launchDate: application.launchDate
              ) else { return nil }

        self.processIdentifier = processIdentifier
        self.cacheNamespace = "\(bundleIdentifier.utf8.count):\(bundleIdentifier)|\(processStartToken)|\(processIdentifier)"
        self.bundlePath = application.bundleURL?.standardizedFileURL.path
    }

    func matchesCurrentProcess() -> Bool {
        guard let currentApplication = NSRunningApplication(
            processIdentifier: processIdentifier
        ), !currentApplication.isTerminated,
           let currentIdentity = Self(application: currentApplication) else {
            return false
        }
        return currentIdentity == self
    }

    private static func processStartToken(
        processIdentifier: pid_t,
        launchDate: Date?
    ) -> String? {
        var processInfo = proc_bsdinfo()
        let bytesCopied = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        if bytesCopied == MemoryLayout<proc_bsdinfo>.size,
           processInfo.pbi_pid == UInt32(bitPattern: processIdentifier) {
            return "proc:\(processInfo.pbi_start_tvsec):\(processInfo.pbi_start_tvusec)"
        }

        // launchDate is the public API fallback if proc_pidinfo is unavailable.
        // Microsecond precision is stable across repeated NSRunningApplication
        // lookups while still distinguishing practical process launches.
        guard let launchDate else { return nil }
        let microseconds = Int64(
            (launchDate.timeIntervalSinceReferenceDate * 1_000_000).rounded()
        )
        return "launch:\(microseconds)"
    }
}

/// Event-driven AX window registry shared by Dock and Cmd-Tab. Some Apps omit
/// inactive windows from `AXWindows`; remembering only exact window IDs seen in
/// lifecycle notifications preserves those real windows without admitting raw
/// WindowServer helper surfaces. The observer sources are installed on the
/// main run loop, and every public entry point is called from the main actor.
final class WindowAXLifecycleRegistry: @unchecked Sendable {
    static let shared = WindowAXLifecycleRegistry()

    private final class ProcessObservation {
        let identity: WindowThumbnailApplicationIdentity
        let applicationElement: AXUIElement
        let observer: AXObserver
        var windowsByID: [CGWindowID: AXUIElement] = [:]
        var subscribedWindowIDs: Set<CGWindowID> = []
        var notificationRegistrationResults: [
            String: WindowAXNotificationRegistrationDiagnostic
        ] = [:]
        var accessSequence: UInt64 = 0

        init(
            identity: WindowThumbnailApplicationIdentity,
            applicationElement: AXUIElement,
            observer: AXObserver
        ) {
            self.identity = identity
            self.applicationElement = applicationElement
            self.observer = observer
        }
    }

    private struct ObserverCreationDiagnostic {
        let processLifetimeKey: String
        let result: Int32
    }

    private static let observerCallback: AXObserverCallback = {
        observer,
        element,
        notification,
        refcon in
        guard Thread.isMainThread, let refcon else { return }
        let registry = Unmanaged<WindowAXLifecycleRegistry>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        registry.receive(
            observer: observer,
            element: element,
            notification: notification as String
        )
    }

    private var observationsByPID: [pid_t: ProcessObservation] = [:]
    private var observerCreationResultsByPID: [
        pid_t: ObserverCreationDiagnostic
    ] = [:]
    private var accessSequence: UInt64 = 0
    private let maximumObservedProcesses = 24
    private let maximumWindowsPerProcess = 64
    private let perWindowNotifications = [
        kAXUIElementDestroyedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String
    ]

    private init() {}

    /// Installs one observer for this concrete process launch and refreshes its
    /// current AX identities. Unsupported individual notifications do not
    /// invalidate the other event sources.
    func observe(application: NSRunningApplication) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AXIsProcessTrusted(),
              application.activationPolicy == .regular,
              !application.isTerminated,
              let identity = WindowThumbnailApplicationIdentity(
                  application: application
              ) else { return }

        if let existing = observationsByPID[identity.processIdentifier] {
            if existing.identity == identity {
                touch(existing)
                seedCurrentWindows(in: existing)
                return
            }
            removeObservation(processIdentifier: identity.processIdentifier)
        }

        let applicationElement = AXUIElementCreateApplication(
            identity.processIdentifier
        )
        AXUIElementSetMessagingTimeout(applicationElement, 0.15)
        var createdObserver: AXObserver?
        let observerCreationResult = AXObserverCreate(
            identity.processIdentifier,
            Self.observerCallback,
            &createdObserver
        )
        if WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            observerCreationResultsByPID[identity.processIdentifier] =
                ObserverCreationDiagnostic(
                    processLifetimeKey: identity.processLifetimeKey,
                    result: Int32(observerCreationResult.rawValue)
                )
        }
        guard observerCreationResult == .success,
              let observer = createdObserver else { return }

        let observation = ProcessObservation(
            identity: identity,
            applicationElement: applicationElement,
            observer: observer
        )
        observationsByPID[identity.processIdentifier] = observation
        touch(observation)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        addNotification(
            kAXWindowCreatedNotification as String,
            element: applicationElement,
            observation: observation,
            refcon: refcon,
            targetWindowID: nil
        )
        addNotification(
            kAXFocusedWindowChangedNotification as String,
            element: applicationElement,
            observation: observation,
            refcon: refcon,
            targetWindowID: nil
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        seedCurrentWindows(in: observation)
        pruneIfNeeded()
    }

    /// Returns only exact-ID AX elements from this same process launch. The
    /// normal candidate policy and private WindowServer reconciliation still
    /// decide whether each element may become a visible preview card.
    func windowElements(for application: NSRunningApplication) -> [AXUIElement] {
        dispatchPrecondition(condition: .onQueue(.main))
        observe(application: application)
        guard let identity = WindowThumbnailApplicationIdentity(
                  application: application
              ),
              let observation = observationsByPID[identity.processIdentifier],
              observation.identity == identity else { return [] }
        touch(observation)
        return observation.windowsByID
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    func diagnosticSnapshot(
        for application: NSRunningApplication
    ) -> WindowAXLifecycleDiagnosticSnapshot {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let identity = WindowThumbnailApplicationIdentity(
            application: application
        ) else {
            return WindowAXLifecycleDiagnosticSnapshot(
                observerCreationResult: nil,
                isObservationInstalled: false,
                windowIDs: [],
                notificationRegistrations: []
            )
        }
        let observation = observationsByPID[identity.processIdentifier]
        let matchingObservation = observation.flatMap {
            $0.identity == identity ? $0 : nil
        }
        return WindowAXLifecycleDiagnosticSnapshot(
            observerCreationResult: observerCreationResultsByPID[
                identity.processIdentifier
            ].flatMap {
                $0.processLifetimeKey == identity.processLifetimeKey
                    ? $0.result
                    : nil
            },
            isObservationInstalled: matchingObservation != nil,
            windowIDs: matchingObservation?.windowsByID.keys.sorted() ?? [],
            notificationRegistrations: matchingObservation?
                .notificationRegistrationResults.values.sorted {
                    if $0.notification == $1.notification {
                        return ($0.targetWindowID ?? 0) < ($1.targetWindowID ?? 0)
                    }
                    return $0.notification < $1.notification
                } ?? []
        )
    }

    func remove(processIdentifier: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        removeObservation(processIdentifier: processIdentifier)
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        for processIdentifier in Array(observationsByPID.keys) {
            removeObservation(processIdentifier: processIdentifier)
        }
        accessSequence = 0
        observerCreationResultsByPID.removeAll(keepingCapacity: false)
    }

    private func receive(
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let observation = observationsByPID.values.first(where: {
            CFEqual($0.observer, observer)
        }), observation.identity.matchesCurrentProcess() else { return }
        touch(observation)

        switch notification {
        case kAXWindowCreatedNotification as String,
             kAXWindowMiniaturizedNotification as String,
             kAXWindowDeminiaturizedNotification as String:
            track(element, in: observation)
        case kAXFocusedWindowChangedNotification as String:
            if let focused = elementAttribute(
                kAXFocusedWindowAttribute,
                of: observation.applicationElement
            ) {
                track(focused, in: observation)
            }
        case kAXUIElementDestroyedNotification as String:
            if let windowID = windowDirectWindowNumber(of: element) {
                observation.windowsByID.removeValue(forKey: windowID)
                observation.subscribedWindowIDs.remove(windowID)
            } else {
                let removedIDs = observation.windowsByID.compactMap {
                    CFEqual($0.value, element) ? $0.key : nil
                }
                for windowID in removedIDs {
                    observation.windowsByID.removeValue(forKey: windowID)
                    observation.subscribedWindowIDs.remove(windowID)
                }
            }
        default:
            break
        }
    }

    private func seedCurrentWindows(in observation: ProcessObservation) {
        var windows: [AXUIElement] = []
        for attribute in [
            kAXFocusedWindowAttribute,
            kAXMainWindowAttribute
        ] {
            if let window = elementAttribute(
                attribute,
                of: observation.applicationElement
            ), !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            observation.applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
        let available = value as? [AXUIElement] {
            for window in available
            where !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        for window in windows { track(window, in: observation) }
    }

    private func track(
        _ element: AXUIElement,
        in observation: ProcessObservation
    ) {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(element, &ownerPID) == .success,
              ownerPID == observation.identity.processIdentifier,
              let windowID = windowDirectWindowNumber(of: element),
              windowID > 0 else { return }
        if let existing = observation.windowsByID[windowID],
           !CFEqual(existing, element) {
            removeWindowNotifications(
                from: existing,
                observation: observation
            )
            observation.subscribedWindowIDs.remove(windowID)
        }
        observation.windowsByID[windowID] = element
        if observation.windowsByID.count > maximumWindowsPerProcess {
            let retainedIDs = Set(
                observation.windowsByID.keys.sorted().suffix(
                    maximumWindowsPerProcess
                )
            )
            for (candidateID, candidateElement) in observation.windowsByID
            where !retainedIDs.contains(candidateID) {
                removeWindowNotifications(
                    from: candidateElement,
                    observation: observation
                )
            }
            observation.windowsByID = observation.windowsByID.filter {
                retainedIDs.contains($0.key)
            }
            observation.subscribedWindowIDs = observation.subscribedWindowIDs
                .intersection(retainedIDs)
        }
        guard observation.subscribedWindowIDs.insert(windowID).inserted else {
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in perWindowNotifications {
            addNotification(
                notification,
                element: element,
                observation: observation,
                refcon: refcon,
                targetWindowID: windowID
            )
        }
    }

    private func addNotification(
        _ notification: String,
        element: AXUIElement,
        observation: ProcessObservation,
        refcon: UnsafeMutableRawPointer,
        targetWindowID: CGWindowID?
    ) {
        let result = AXObserverAddNotification(
            observation.observer,
            element,
            notification as CFString,
            refcon
        )
        if WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            let key = "\(notification)|\(targetWindowID.map(String.init) ?? "application")"
            observation.notificationRegistrationResults[key] =
                WindowAXNotificationRegistrationDiagnostic(
                    notification: notification,
                    targetWindowID: targetWindowID,
                    result: Int32(result.rawValue)
                )
        }
    }

    private func removeWindowNotifications(
        from element: AXUIElement,
        observation: ProcessObservation
    ) {
        for notification in perWindowNotifications {
            AXObserverRemoveNotification(
                observation.observer,
                element,
                notification as CFString
            )
        }
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

    private func touch(_ observation: ProcessObservation) {
        accessSequence &+= 1
        observation.accessSequence = accessSequence
    }

    private func pruneIfNeeded() {
        while observationsByPID.count > maximumObservedProcesses,
              let oldestPID = observationsByPID.min(by: {
                  $0.value.accessSequence < $1.value.accessSequence
              })?.key {
            removeObservation(processIdentifier: oldestPID)
        }
    }

    private func removeObservation(processIdentifier: pid_t) {
        observerCreationResultsByPID.removeValue(forKey: processIdentifier)
        guard let observation = observationsByPID.removeValue(
            forKey: processIdentifier
        ) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            .commonModes
        )
    }
}

/// Pure relationship policy for cross-process compositor pixels. Hosted Apps
/// such as WeChat frequently render a main AX window in a child or grandchild
/// process whose bundle identifier is intentionally different. A candidate is
/// therefore trusted only when its live process ancestry reaches the target
/// and its executable remains inside the target App bundle. The older sibling
/// launch-batch rule remains as a compatibility path for split-process Apps.
enum WindowRendererLineagePolicy {
    static func descendantDepth(
        candidatePID: pid_t,
        targetPID: pid_t,
        maximumDepth: Int = 4,
        parentOf: (pid_t) -> pid_t?
    ) -> Int? {
        guard candidatePID > 0,
              targetPID > 0,
              candidatePID != targetPID,
              maximumDepth > 0 else { return nil }
        var cursor = candidatePID
        var visited: Set<pid_t> = [cursor]
        for depth in 1...maximumDepth {
            guard let parent = parentOf(cursor), parent > 0 else { return nil }
            if parent == targetPID { return depth }
            guard parent > 1, visited.insert(parent).inserted else { return nil }
            cursor = parent
        }
        return nil
    }

    static func executablePath(
        _ executablePath: String,
        isInsideBundleAt bundlePath: String
    ) -> Bool {
        let executable = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.path
        let bundle = URL(fileURLWithPath: bundlePath)
            .standardizedFileURL.path
        guard !bundle.isEmpty else { return false }
        return executable.hasPrefix(bundle + "/")
    }

    static func commonBundlePrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs.split(separator: "."), rhs.split(separator: ".")) {
            guard left.caseInsensitiveCompare(right) == .orderedSame else { break }
            count += 1
        }
        return count
    }

    static func relationshipPenalty(
        descendantDepth: Int?,
        executableInsideTargetBundle: Bool,
        isSiblingProcess: Bool,
        sharesBundleNamespace: Bool,
        launchDelta: TimeInterval
    ) -> CGFloat? {
        let descendantPenalty: CGFloat? = {
            guard executableInsideTargetBundle,
                  let descendantDepth,
                  descendantDepth > 0 else { return nil }
            return CGFloat(descendantDepth * 4)
        }()
        let siblingPenalty: CGFloat? = {
            guard isSiblingProcess,
                  sharesBundleNamespace,
                  launchDelta <= 3 else { return nil }
            return CGFloat(launchDelta * 12)
        }()
        return [descendantPenalty, siblingPenalty]
            .compactMap { $0 }
            .min()
    }
}

struct WindowThumbnailRequest: Sendable {
    let title: String
    let occurrence: Int
    let bounds: CGRect?
    let windowID: CGWindowID?
    var allowsUniformContent = false
}

/// A typed outcome for one requested window. Callers keep `nil` separately as
/// their short-lived loading state; once the provider finishes every request
/// has an explicit result and can no longer silently degrade to an unrelated
/// application icon.
enum WindowThumbnailResult: @unchecked Sendable {
    case fresh(NSImage)
    case recentCache(NSImage, timestamp: Date)
    case permissionRequired
    case restartRequired
    case notEnumerated
    case ambiguous
    case captureFailed

    var image: NSImage? {
        switch self {
        case let .fresh(image), let .recentCache(image, _): image
        case .permissionRequired,
             .restartRequired,
             .notEnumerated,
             .ambiguous,
             .captureFailed: nil
        }
    }

    var cachedAt: Date? {
        guard case let .recentCache(_, timestamp) = self else { return nil }
        return timestamp
    }

    /// A visible card must either contain validated pixels or explain a global
    /// permission/restart boundary. Per-window absence, ambiguity, and blank
    /// capture are fail-closed and never become selectable placeholders.
    var isEligibleForWindowCard: Bool {
        switch self {
        case .fresh, .recentCache, .permissionRequired, .restartRequired:
            true
        case .notEnumerated, .ambiguous, .captureFailed:
            false
        }
    }
}

/// A WindowServer-only discovery is intentionally weaker than an AX window:
/// it can supply pixels and an exact WindowServer number, but it does not prove
/// that the surface supports activation, closing, minimization, or other window
/// management actions.
struct WindowThumbnailDiscoveredWindow: @unchecked Sendable {
    let request: WindowThumbnailRequest
    let result: WindowThumbnailResult
}

enum WindowThumbnailDiscoveryResult: @unchecked Sendable {
    case windows([WindowThumbnailDiscoveredWindow])
    case unavailable(WindowThumbnailResult)
}

/// WindowServer-only discovery has pixels but no AX operation identity. It is
/// therefore an application preview fallback, not proof of N independent user
/// windows. Showing every compositor surface is exactly how helper/renderer
/// shells become phantom cards. Keep one deterministic best preview until AX
/// and WindowServer can establish concrete window identities.
enum WindowPreviewOnlySelectionPolicy {
    static func selectOne(
        from windows: [WindowThumbnailDiscoveredWindow]
    ) -> WindowThumbnailDiscoveredWindow? {
        windows
            .filter { $0.result.isEligibleForWindowCard }
            .sorted { lhs, rhs in
                let lhsScore = score(lhs)
                let rhsScore = score(rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return (lhs.request.windowID ?? .max)
                    < (rhs.request.windowID ?? .max)
            }
            .first
    }

    private static func score(
        _ window: WindowThumbnailDiscoveredWindow
    ) -> Double {
        var result: Double = window.result.image == nil ? 0 : 1_000_000_000
        let title = window.request.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { result += 100_000_000 }
        if let bounds = window.request.bounds,
           bounds.width.isFinite,
           bounds.height.isFinite {
            result += min(
                99_999_999,
                max(0, Double(bounds.width * bounds.height))
            )
        }
        return result
    }
}

enum WindowThumbnailProvider {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland",
        category: "WindowThumbnails"
    )

    static let didInvalidatePreviewsNotification = Notification.Name(
        "SuperIsland.WindowThumbnailProvider.didInvalidatePreviews"
    )

    private struct CachedThumbnail {
        let image: NSImage
        let capturedAt: Date
        let processIdentifier: pid_t
        let estimatedByteCost: Int
    }

    private enum AuthorizationState: Equatable {
        case authorized
        case permissionRequired
        case restartRequired
    }

    /// Shared with the persistent Dock/Cmd-Tab view models so a cached image
    /// cannot outlive the provider entry that made it eligible for display.
    static let recentCacheTTL: TimeInterval = 60
    private static let maximumCacheKeyCount = 32
    private static let maximumCacheByteCost = 32 * 1_024 * 1_024
    private static let maximumFallbackWindowCount = 8
    private static let privateCaptureQueue = DispatchQueue(
        label: "com.workview.SuperIsland.window-private-capture",
        qos: .userInitiated
    )
    private static let cacheLock = NSLock()
    private static var thumbnailCache: [String: CachedThumbnail] = [:]
    private static var expirationSweepWorkItem: DispatchWorkItem?
    private static var expirationSweepGeneration: UInt64 = 0
    /// Invalidates captures that were already in flight when a privacy or
    /// lifecycle boundary purged the cache. Cancellation alone is insufficient:
    /// ScreenCaptureKit may finish a capture after sleep/lock or after a feature
    /// toggle, and that late result must never repopulate cleared memory.
    private static var cacheGeneration: UInt64 = 0
    private static var permissionWasRevokedAfterLaunch = false
    @MainActor private static var lifecycleObservers: [NSObjectProtocol] = []
    @MainActor private static var permissionPollTimer: Timer?
    @MainActor private static var lastKnownScreenRecordingPermission: Bool?

    /// Captures off-Space and minimized windows through ScreenCaptureKit. Each
    /// request is matched to one WindowServer window, preferring an exact
    /// window number and then AX geometry. If a native fullscreen window is no
    /// longer enumerated in the current Space, the exact same process/window
    /// may reuse a preview captured during the previous 60 seconds. Every
    /// failure remains typed so callers can explain why no image is shown.
    static func captureWindows(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        requests: [WindowThumbnailRequest]
    ) async -> [WindowThumbnailResult] {
        guard !requests.isEmpty else { return [] }
        guard !Task.isCancelled else {
            return repeated(.captureFailed, count: requests.count)
        }
        switch authorizationState() {
        case .permissionRequired:
            return repeated(.permissionRequired, count: requests.count)
        case .restartRequired:
            return repeated(.restartRequired, count: requests.count)
        case .authorized:
            break
        }
        guard applicationIdentity.matchesCurrentProcess() else {
            clearCache(processIdentifier: applicationIdentity.processIdentifier)
            return repeated(.notEnumerated, count: requests.count)
        }
        let expectedCacheGeneration = cacheGenerationSnapshot()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            return fallbackResults(
                for: requests,
                applicationIdentity: applicationIdentity,
                failure: failureResultAfterCaptureError()
            )
        }
        return await captureWindows(
            applicationIdentity: applicationIdentity,
            requests: requests,
            content: content,
            expectedCacheGeneration: expectedCacheGeneration
        )
    }

    /// Discovers previewable layer-zero surfaces for accessory/helper Apps
    /// that expose no AXWindows. This is deliberately called only after the AX
    /// source returned an empty list. The result is preview-only: callers must
    /// not infer AX actions from these WindowServer surfaces.
    static func discoverAndCaptureWindows(
        applicationIdentity: WindowThumbnailApplicationIdentity
    ) async -> WindowThumbnailDiscoveryResult {
        guard !Task.isCancelled else { return .unavailable(.captureFailed) }
        switch authorizationState() {
        case .permissionRequired:
            return .unavailable(.permissionRequired)
        case .restartRequired:
            return .unavailable(.restartRequired)
        case .authorized:
            break
        }
        guard applicationIdentity.matchesCurrentProcess() else {
            clearCache(processIdentifier: applicationIdentity.processIdentifier)
            return .unavailable(.notEnumerated)
        }
        let expectedCacheGeneration = cacheGenerationSnapshot()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            return .unavailable(failureResultAfterCaptureError())
        }
        guard !Task.isCancelled,
              applicationIdentity.matchesCurrentProcess() else {
            return .unavailable(.notEnumerated)
        }

        let candidates = fallbackPreviewCandidates(
            in: content,
            processIdentifier: applicationIdentity.processIdentifier
        )
        guard !candidates.isEmpty else {
            // Some hosted mini-program Dock services publish only narrow
            // compositor strips. Their immediate host owns a hidden backing
            // surface while the ancestor application owns the corresponding
            // visible pixels. Resolve that ownership bridge only when the
            // ordinary AX and same-PID WindowServer paths are both empty.
            if let hostedPreview = await captureAncestorHostedPreviewFallback(
                applicationIdentity: applicationIdentity,
                content: content,
                expectedCacheGeneration: expectedCacheGeneration
            ) {
                return hostedPreview
            }
            return .windows([])
        }

        var titleOccurrences: [String: Int] = [:]
        let requests = candidates.map { window -> WindowThumbnailRequest in
            let title = (window.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let occurrence = titleOccurrences[title, default: 0]
            titleOccurrences[title] = occurrence + 1
            return WindowThumbnailRequest(
                title: title,
                occurrence: occurrence,
                bounds: window.frame,
                windowID: window.windowID
            )
        }
        var results = await captureWindows(
            applicationIdentity: applicationIdentity,
            requests: requests,
            content: content,
            expectedCacheGeneration: expectedCacheGeneration
        )
        guard !Task.isCancelled else { return .unavailable(.captureFailed) }

        // Chromium-style accessory Apps can expose a layer-zero Dock service
        // shell while a sibling Renderer process owns the visible pixels. A
        // size-valid but visually blank shell is not a successful preview.
        // Only this weaker discovery path may look for a sibling surface, and
        // only when the exact shell did not produce a fresh valid frame.
        for index in results.indices {
            let shouldTryRelatedRenderer: Bool
            switch results[index] {
            case .captureFailed, .recentCache:
                // A failed blank capture can otherwise be hidden by a stale
                // shell cache. Prefer a live, uniquely matched Renderer when
                // one is available; preserve the cache if none exists.
                shouldTryRelatedRenderer = true
            case .fresh,
                 .permissionRequired,
                 .restartRequired,
                 .notEnumerated,
                 .ambiguous:
                shouldTryRelatedRenderer = false
            }
            guard shouldTryRelatedRenderer,
                  requests.indices.contains(index),
                  let windowID = requests[index].windowID,
                  let shellWindow = candidates.first(where: {
                      $0.windowID == windowID
                  }) else { continue }
            if let relatedResult = await captureRelatedRendererFallback(
                shellWindow: shellWindow,
                applicationIdentity: applicationIdentity,
                content: content,
                expectedCacheGeneration: expectedCacheGeneration
            ) {
                results[index] = relatedResult
            }
        }

        guard !Task.isCancelled,
              applicationIdentity.matchesCurrentProcess(),
              cacheGenerationSnapshot() == expectedCacheGeneration else {
            return .unavailable(.captureFailed)
        }
        return .windows(zip(requests, results).map {
            WindowThumbnailDiscoveredWindow(request: $0.0, result: $0.1)
        })
    }

    private static func captureWindows(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        requests: [WindowThumbnailRequest],
        content: SCShareableContent,
        expectedCacheGeneration: UInt64
    ) async -> [WindowThumbnailResult] {
        let applicationPID = applicationIdentity.processIdentifier
        guard !Task.isCancelled,
              applicationIdentity.matchesCurrentProcess() else {
            return repeated(.captureFailed, count: requests.count)
        }
        switch authorizationState() {
        case .permissionRequired:
            return repeated(.permissionRequired, count: requests.count)
        case .restartRequired:
            return repeated(.restartRequired, count: requests.count)
        case .authorized:
            break
        }

        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == applicationPID &&
                window.windowLayer == 0 &&
                window.frame.width >= 80 &&
                window.frame.height >= 60
        }

        var usedWindowIDs = Set<CGWindowID>()
        var results = repeated(.captureFailed, count: requests.count)

        for (index, request) in requests.enumerated() {
            guard !Task.isCancelled else { return results }
            guard applicationIdentity.matchesCurrentProcess() else {
                clearCache(processIdentifier: applicationPID)
                return repeated(.notEnumerated, count: requests.count)
            }
            switch authorizationState() {
            case .permissionRequired:
                return repeated(.permissionRequired, count: requests.count)
            case .restartRequired:
                return repeated(.restartRequired, count: requests.count)
            case .authorized:
                break
            }
            let match = bestMatch(
                for: request,
                among: candidates.filter { !usedWindowIDs.contains($0.windowID) }
            )
            guard case let .matched(window) = match else {
                let failure: WindowThumbnailResult
                switch match {
                case .ambiguous: failure = .ambiguous
                case .notFound: failure = .notEnumerated
                case .matched: failure = .captureFailed
                }
                results[index] = recentCacheResult(
                    for: request,
                    applicationIdentity: applicationIdentity
                ) ?? failure
                continue
            }

            usedWindowIDs.insert(window.windowID)
            let key = cacheKey(
                applicationIdentity: applicationIdentity,
                windowID: window.windowID
            )
            let captureResult = await captureResult(window: window, allowsUniformContent: request.allowsUniformContent)
            let capturedImage = captureResult.image
            guard !Task.isCancelled else { return results }
            guard applicationIdentity.matchesCurrentProcess() else {
                clearCache(processIdentifier: applicationPID)
                return repeated(.notEnumerated, count: requests.count)
            }
            switch authorizationState() {
            case .permissionRequired:
                return repeated(.permissionRequired, count: requests.count)
            case .restartRequired:
                return repeated(.restartRequired, count: requests.count)
            case .authorized:
                break
            }
            if let image = capturedImage {
                results[index] = storeFreshCapture(
                    image,
                    exactKey: key,
                    request: request,
                    applicationIdentity: applicationIdentity,
                    expectedCacheGeneration: expectedCacheGeneration
                )
            } else {
                if captureResult.isEmptySurface {
                    discardCachedCapture(
                        keys: cacheKeysForStore(exactKey: key, applicationIdentity: applicationIdentity, request: request),
                        expectedGeneration: expectedCacheGeneration
                    )
                }
                // Some hosted Apps expose the actionable AX/WindowServer shell
                // in the Dock process while a launch-related Renderer sibling
                // owns the visible pixels. The shell identity remains the
                // action target; this strict sibling/geometry matcher supplies
                // pixels only and never changes activation or close identity.
                if let relatedResult = await captureRelatedRendererFallback(
                    shellWindow: window,
                    applicationIdentity: applicationIdentity,
                    content: content,
                    expectedCacheGeneration: expectedCacheGeneration
                ) {
                    results[index] = relatedResult
                } else if let uniformImage = captureResult.uniformImage {
                    // A uniform but strongly evidenced document is accepted
                    // only after both exact-ID capture paths and the verified
                    // renderer path had a chance to supply real content.
                    results[index] = storeFreshCapture(
                        uniformImage,
                        exactKey: key,
                        request: request,
                        applicationIdentity: applicationIdentity,
                        expectedCacheGeneration: expectedCacheGeneration
                    )
                } else if captureResult.isEmptySurface {
                    // A live empty shell must not be resurrected from an older
                    // successful image. Missing/off-Space windows still retain
                    // their separately labelled recent-cache path above.
                    results[index] = .captureFailed
                } else {
                    results[index] = recentCacheResult(
                        for: request,
                        applicationIdentity: applicationIdentity
                    ) ?? .captureFailed
                }
            }
        }
        guard cacheGenerationSnapshot() == expectedCacheGeneration else {
            return repeated(.captureFailed, count: requests.count)
        }
        guard applicationIdentity.matchesCurrentProcess() else {
            clearCache(processIdentifier: applicationPID)
            return repeated(.notEnumerated, count: requests.count)
        }
        switch authorizationState() {
        case .permissionRequired:
            return repeated(.permissionRequired, count: requests.count)
        case .restartRequired:
            return repeated(.restartRequired, count: requests.count)
        case .authorized:
            return results
        }
    }

    private static func storeFreshCapture(
        _ image: NSImage,
        exactKey: String,
        request: WindowThumbnailRequest,
        applicationIdentity: WindowThumbnailApplicationIdentity,
        expectedCacheGeneration: UInt64
    ) -> WindowThumbnailResult {
        let entry = CachedThumbnail(
            image: image,
            capturedAt: Date(),
            processIdentifier: applicationIdentity.processIdentifier,
            estimatedByteCost: estimatedByteCost(of: image)
        )
        let stored = store(
            entry,
            keys: cacheKeysForStore(
                exactKey: exactKey,
                applicationIdentity: applicationIdentity,
                request: request
            ),
            expectedGeneration: expectedCacheGeneration
        )
        return stored ? .fresh(image) : .captureFailed
    }

    /// Filters ScreenCaptureKit's full window inventory down to surfaces that
    /// are plausible user windows for one helper process. A helper can publish
    /// backing surfaces that exactly mirror its parent App; accepting those
    /// would show the parent WeChat window under a mini-program Dock item.
    private static func fallbackPreviewCandidates(
        in content: SCShareableContent,
        processIdentifier: pid_t
    ) -> [SCWindow] {
        let parentPID = parentProcessIdentifier(of: processIdentifier)
        let parentFrames: [CGRect]
        if let parentPID, parentPID > 1 {
            parentFrames = content.windows.compactMap { window in
                guard window.owningApplication?.processID == parentPID,
                      window.windowLayer == 0,
                      window.frame.width >= 160,
                      window.frame.height >= 100 else { return nil }
                return window.frame
            }
        } else {
            parentFrames = []
        }

        var accepted: [SCWindow] = []
        for window in content.windows {
            guard window.owningApplication?.processID == processIdentifier,
                  window.windowLayer == 0,
                  window.frame.width >= 160,
                  window.frame.height >= 100 else { continue }
            // Fail closed when the helper surface is only a duplicate of the
            // parent App's backing frame, or when the same helper publishes two
            // near-identical surfaces for one visual window.
            guard !parentFrames.contains(where: {
                rectDistance($0, window.frame) <= 12
            }), !accepted.contains(where: {
                rectDistance($0.frame, window.frame) <= 8
            }) else { continue }
            accepted.append(window)
        }
        // The ordinary AX path remains unbounded and exposes every real
        // window. Only this weaker helper-process fallback is capped so a
        // malformed App cannot trigger an unbounded screenshot burst.
        return Array(accepted.prefix(maximumFallbackWindowCount))
    }

    private static func parentProcessIdentifier(of processIdentifier: pid_t) -> pid_t? {
        processSnapshot(of: processIdentifier)?.parentProcessIdentifier
    }

    private struct AncestorHostedPreviewCandidate {
        let window: SCWindow
        let parentSnapshot: ProcessSnapshot
        let ancestorSnapshot: ProcessSnapshot
    }

    private enum AncestorHostedPreviewMatch {
        case matched(AncestorHostedPreviewCandidate)
        case ambiguous
        case notFound
    }

    /// Maps a hosted mini-program Dock process to pixels owned by its ancestor
    /// application without guessing by title or frontmost state. The mapping
    /// requires all three pieces of the compositor ownership chain:
    ///
    /// 1. the Dock process publishes a narrow surface spanning the host shell;
    /// 2. its immediate parent publishes one hidden, full-sized backing shell;
    /// 3. its grandparent publishes one visible surface with the same geometry.
    ///
    /// The host relationship is proven by live process ancestry and bundle
    /// containment, never by a vendor or application identifier.
    private static func ancestorHostedPreviewMatch(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        in content: SCShareableContent
    ) -> AncestorHostedPreviewMatch {
        let targetPID = applicationIdentity.processIdentifier
        guard let targetApplication = NSRunningApplication(
            processIdentifier: targetPID
        ), !targetApplication.isTerminated,
           let targetBundleIdentifier = targetApplication.bundleIdentifier,
           let targetSnapshot = processSnapshot(of: targetPID),
           targetSnapshot.parentProcessIdentifier > 1,
           let parentSnapshot = processSnapshot(
            of: targetSnapshot.parentProcessIdentifier
           ),
           parentSnapshot.parentProcessIdentifier > 1,
           let ancestorSnapshot = processSnapshot(
               of: parentSnapshot.parentProcessIdentifier
           ),
           let targetBundlePath = applicationIdentity.bundlePath,
           let ancestorBundlePath = NSRunningApplication(
                processIdentifier: ancestorSnapshot.processIdentifier
           )?.bundleURL?.standardizedFileURL.path else {
            return .notFound
        }

        let targetAnchors = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == targetPID &&
                owner.bundleIdentifier.caseInsensitiveCompare(
                    targetBundleIdentifier
                ) == .orderedSame &&
                window.windowLayer == 0 &&
                window.frame.width >= 160 &&
                window.frame.height >= 8 &&
                window.frame.height < 100
        }
        guard !targetAnchors.isEmpty else { return .notFound }

        let hiddenParentShells = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == parentSnapshot.processIdentifier &&
                owner.bundleIdentifier.caseInsensitiveCompare(
                    targetBundleIdentifier
                ) == .orderedSame &&
                window.windowLayer == 0 &&
                !window.isOnScreen &&
                window.frame.width >= 160 &&
                window.frame.height >= 100 &&
                targetAnchors.contains(where: {
                    horizontallyAnchors($0.frame, to: window.frame)
                })
        }
        guard !hiddenParentShells.isEmpty else { return .notFound }

        let visibleAncestorWindows = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == ancestorSnapshot.processIdentifier &&
                isTrustedHostedPreviewLineage(
                    targetBundleIdentifier: targetBundleIdentifier,
                    parentBundleIdentifier: hiddenParentShells.first?
                        .owningApplication?.bundleIdentifier ?? "",
                    targetBundlePath: targetBundlePath,
                    ancestorBundlePath: ancestorBundlePath
                ) &&
                window.windowLayer == 0 &&
                window.isOnScreen &&
                window.frame.width >= 160 &&
                window.frame.height >= 100
        }
        guard !visibleAncestorWindows.isEmpty else { return .notFound }

        var matchedWindows: [CGWindowID: SCWindow] = [:]
        for shell in hiddenParentShells {
            let geometryMatches = visibleAncestorWindows.filter {
                rectDistance(shell.frame, $0.frame) <= 8
            }
            guard geometryMatches.count <= 1 else { return .ambiguous }
            if let match = geometryMatches.first {
                matchedWindows[match.windowID] = match
            }
        }
        guard matchedWindows.count == 1,
              let matchedWindow = matchedWindows.values.first else {
            return matchedWindows.isEmpty ? .notFound : .ambiguous
        }
        return .matched(AncestorHostedPreviewCandidate(
            window: matchedWindow,
            parentSnapshot: parentSnapshot,
            ancestorSnapshot: ancestorSnapshot
        ))
    }

    private static func horizontallyAnchors(
        _ anchor: CGRect,
        to shell: CGRect
    ) -> Bool {
        let widthTolerance = max(32, shell.width * 0.05)
        return abs(anchor.midX - shell.midX) <= 24 &&
            abs(anchor.width - shell.width) <= widthTolerance
    }

    private static func isTrustedHostedPreviewLineage(
        targetBundleIdentifier: String,
        parentBundleIdentifier: String,
        targetBundlePath: String,
        ancestorBundlePath: String
    ) -> Bool {
        guard targetBundleIdentifier.caseInsensitiveCompare(
            parentBundleIdentifier
        ) == .orderedSame else { return false }
        return WindowRendererLineagePolicy.executablePath(
            targetBundlePath,
            isInsideBundleAt: ancestorBundlePath
        )
    }

    private static func captureAncestorHostedPreviewFallback(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        content: SCShareableContent,
        expectedCacheGeneration: UInt64
    ) async -> WindowThumbnailDiscoveryResult? {
        switch ancestorHostedPreviewMatch(
            applicationIdentity: applicationIdentity,
            in: content
        ) {
        case .notFound:
            return nil
        case .ambiguous:
            logger.info(
                "Ancestor-hosted preview match is ambiguous pid=\(applicationIdentity.processIdentifier, privacy: .public)"
            )
            return .unavailable(.ambiguous)
        case let .matched(candidate):
            let image = await capture(window: candidate.window)
            guard !Task.isCancelled,
                  cacheGenerationSnapshot() == expectedCacheGeneration,
                  applicationIdentity.matchesCurrentProcess(),
                  processSnapshot(
                    of: candidate.parentSnapshot.processIdentifier
                  ) == candidate.parentSnapshot,
                  processSnapshot(
                    of: candidate.ancestorSnapshot.processIdentifier
                  ) == candidate.ancestorSnapshot else {
                return .unavailable(.captureFailed)
            }
            switch authorizationState() {
            case .permissionRequired:
                return .unavailable(.permissionRequired)
            case .restartRequired:
                return .unavailable(.restartRequired)
            case .authorized:
                break
            }
            let result: WindowThumbnailResult = image.map {
                logger.debug(
                    "Used ancestor-hosted preview targetPID=\(applicationIdentity.processIdentifier, privacy: .public) parentPID=\(candidate.parentSnapshot.processIdentifier, privacy: .public) ancestorPID=\(candidate.ancestorSnapshot.processIdentifier, privacy: .public) window=\(candidate.window.windowID, privacy: .public)"
                )
                return .fresh($0)
            } ?? .captureFailed
            let rawTitle = (candidate.window.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let request = WindowThumbnailRequest(
                title: rawTitle,
                occurrence: 0,
                bounds: candidate.window.frame,
                windowID: candidate.window.windowID
            )
            // Cross-process pixels intentionally bypass the ordinary cache and
            // are held only by the current hover model.
            return .windows([WindowThumbnailDiscoveredWindow(
                request: request,
                result: result
            )])
        }
    }

    private struct ProcessSnapshot: Equatable {
        let processIdentifier: pid_t
        let parentProcessIdentifier: pid_t
        let startTime: TimeInterval
        let executablePath: String?
    }

    private static func processSnapshot(of processIdentifier: pid_t) -> ProcessSnapshot? {
        var processInfo = proc_bsdinfo()
        let bytesCopied = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard bytesCopied == MemoryLayout<proc_bsdinfo>.size,
              processInfo.pbi_pid == UInt32(bitPattern: processIdentifier),
              processInfo.pbi_ppid > 0 else { return nil }
        return ProcessSnapshot(
            processIdentifier: processIdentifier,
            parentProcessIdentifier: pid_t(processInfo.pbi_ppid),
            startTime: TimeInterval(processInfo.pbi_start_tvsec) +
                TimeInterval(processInfo.pbi_start_tvusec) / 1_000_000,
            executablePath: processExecutablePath(processIdentifier)
        )
    }

    private static func processExecutablePath(
        _ processIdentifier: pid_t
    ) -> String? {
        // proc_pidpath documents a maximum process path buffer of 4 KiB. The
        // C SDK macro is intentionally unavailable to Swift on newer SDKs.
        let maximumProcessPathLength = 4_096
        var buffer = [CChar](
            repeating: 0,
            count: maximumProcessPathLength
        )
        let length = proc_pidpath(
            processIdentifier,
            &buffer,
            UInt32(buffer.count)
        )
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func descendantDepth(
        candidatePID: pid_t,
        targetPID: pid_t
    ) -> Int? {
        WindowRendererLineagePolicy.descendantDepth(
            candidatePID: candidatePID,
            targetPID: targetPID
        ) { processSnapshot(of: $0)?.parentProcessIdentifier }
    }

    private struct RelatedRendererCandidate {
        let window: SCWindow
        let processSnapshot: ProcessSnapshot
        let overlap: CGFloat
        let score: CGFloat
    }

    private enum RelatedRendererMatch {
        case matched([RelatedRendererCandidate])
        case notFound
    }

    /// Finds a remote Renderer surface without guessing by title. The normal
    /// route requires a child/grandchild process whose executable is sealed
    /// inside the target App bundle. A same-launch sibling with a specific
    /// bundle namespace is retained for older split-process Apps. Both routes
    /// still require strong WindowServer geometry; a bounded set of comparable
    /// compositor surfaces may be tried because only substantive pixels are
    /// accepted by the capture boundary.
    private static func relatedRendererMatch(
        for shellWindow: SCWindow,
        applicationIdentity: WindowThumbnailApplicationIdentity,
        in content: SCShareableContent
    ) -> RelatedRendererMatch {
        let targetPID = applicationIdentity.processIdentifier
        guard let targetSnapshot = processSnapshot(of: targetPID),
              let targetBundleIdentifier = shellWindow.owningApplication?
                .bundleIdentifier,
              !targetBundleIdentifier.isEmpty else { return .notFound }

        let shellArea = shellWindow.frame.width * shellWindow.frame.height
        guard shellArea > 0 else { return .notFound }

        var matches: [RelatedRendererCandidate] = []
        var snapshots: [pid_t: ProcessSnapshot] = [:]
        for window in content.windows {
            guard window.windowID != shellWindow.windowID,
                  window.windowLayer == 0,
                  window.frame.width >= 80,
                  window.frame.height >= 60,
                  let owner = window.owningApplication,
                  owner.processID != targetPID else { continue }

            let snapshot: ProcessSnapshot
            if let cached = snapshots[owner.processID] {
                snapshot = cached
            } else if let current = processSnapshot(of: owner.processID) {
                snapshots[owner.processID] = current
                snapshot = current
            } else {
                continue
            }
            let launchDelta = abs(snapshot.startTime - targetSnapshot.startTime)
            let depth = descendantDepth(
                candidatePID: snapshot.processIdentifier,
                targetPID: targetPID
            )
            let isInsideTargetBundle = applicationIdentity.bundlePath.flatMap {
                bundlePath in snapshot.executablePath.map {
                    WindowRendererLineagePolicy.executablePath(
                        $0,
                        isInsideBundleAt: bundlePath
                    )
                }
            } ?? false
            let isSiblingProcess = targetSnapshot.parentProcessIdentifier > 1
                && snapshot.parentProcessIdentifier
                    == targetSnapshot.parentProcessIdentifier
            guard let relationshipPenalty = WindowRendererLineagePolicy
                .relationshipPenalty(
                    descendantDepth: depth,
                    executableInsideTargetBundle: isInsideTargetBundle,
                    isSiblingProcess: isSiblingProcess,
                    sharesBundleNamespace: sharesBundleNamespace(
                        targetBundleIdentifier,
                        owner.bundleIdentifier
                    ),
                    launchDelta: launchDelta
                ) else { continue }

            let candidateArea = window.frame.width * window.frame.height
            let minimumArea = min(shellArea, candidateArea)
            guard minimumArea > 0 else { continue }
            let intersection = shellWindow.frame.intersection(window.frame)
            let intersectionArea = intersection.isNull
                ? 0
                : intersection.width * intersection.height
            let overlap = intersectionArea / minimumArea
            let widthError = abs(window.frame.width - shellWindow.frame.width) /
                max(shellWindow.frame.width, 1)
            let heightError = abs(window.frame.height - shellWindow.frame.height) /
                max(shellWindow.frame.height, 1)
            let centerDistance = hypot(
                window.frame.midX - shellWindow.frame.midX,
                window.frame.midY - shellWindow.frame.midY
            )
            let centerLimit = max(
                48,
                min(shellWindow.frame.width, shellWindow.frame.height) * 0.10
            )
            guard overlap >= 0.82,
                  widthError <= 0.14,
                  heightError <= 0.14,
                  centerDistance <= centerLimit else { continue }

            let onScreenPenalty: CGFloat =
                window.isOnScreen == shellWindow.isOnScreen ? 0 : 24
            let score = rectDistance(shellWindow.frame, window.frame) +
                relationshipPenalty +
                onScreenPenalty
            matches.append(RelatedRendererCandidate(
                window: window,
                processSnapshot: snapshot,
                overlap: overlap,
                score: score
            ))
        }

        let sorted = matches.sorted {
            if $0.score == $1.score { return $0.window.windowID < $1.window.windowID }
            return $0.score < $1.score
        }
        guard let best = sorted.first else { return .notFound }
        // Multi-process UI frameworks can publish several same-geometry child
        // surfaces for one actionable shell. Every candidate here already has
        // verified process ancestry, bundle containment, and strong geometry,
        // so try only the bounded near-best set until one yields substantive
        // pixels. Treating this normal compositor stack as identity ambiguity
        // made WeChat and similar Apps permanently unpreviewable.
        let nearBest = sorted.filter {
            $0.score <= best.score + 12 && abs($0.overlap - best.overlap) <= 0.04
        }
        return .matched(Array(nearBest.prefix(4)))
    }

    private static func sharesBundleNamespace(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        // `com.vendor.product` is specific enough to avoid grouping unrelated
        // helpers that merely share a reverse-DNS owner prefix.
        return WindowRendererLineagePolicy.commonBundlePrefixCount(lhs, rhs) >= 3
    }

    private static func captureRelatedRendererFallback(
        shellWindow: SCWindow,
        applicationIdentity: WindowThumbnailApplicationIdentity,
        content: SCShareableContent,
        expectedCacheGeneration: UInt64
    ) async -> WindowThumbnailResult? {
        let match = relatedRendererMatch(
            for: shellWindow,
            applicationIdentity: applicationIdentity,
            in: content
        )
        switch match {
        case .notFound:
            return nil
        case let .matched(candidates):
            for candidate in candidates {
                guard !Task.isCancelled,
                      cacheGenerationSnapshot() == expectedCacheGeneration,
                      applicationIdentity.matchesCurrentProcess() else {
                    return .captureFailed
                }
                guard processSnapshot(
                    of: candidate.processSnapshot.processIdentifier
                ) == candidate.processSnapshot else { continue }
                switch authorizationState() {
                case .permissionRequired: return .permissionRequired
                case .restartRequired: return .restartRequired
                case .authorized: break
                }
                guard let image = await capture(window: candidate.window) else {
                    continue
                }
                // Do not place cross-process fallback pixels in the ordinary
                // cache. Renderer lifetime is independent of the AX shell.
                logger.debug(
                    "Used related Renderer preview targetPID=\(applicationIdentity.processIdentifier, privacy: .public) rendererPID=\(candidate.processSnapshot.processIdentifier, privacy: .public) shell=\(shellWindow.windowID, privacy: .public) renderer=\(candidate.window.windowID, privacy: .public) candidates=\(candidates.count, privacy: .public)"
                )
                return .fresh(image)
            }
            return .captureFailed
        }
    }

    private enum CaptureResult: @unchecked Sendable {
        case image(NSImage)
        case uniformImage(NSImage)
        case emptySurface
        case failed

        var image: NSImage? {
            if case let .image(image) = self { return image }
            return nil
        }
        var uniformImage: NSImage? {
            if case let .uniformImage(image) = self { return image }
            return nil
        }
        var isEmptySurface: Bool {
            if case .emptySurface = self { return true }
            return false
        }
    }

    private static func capture(window: SCWindow) async -> NSImage? {
        await captureResult(window: window, allowsUniformContent: false).image
    }

    private static func captureResult(window: SCWindow, allowsUniformContent: Bool) async -> CaptureResult {
        let configuration = SCStreamConfiguration()
        let longestSide = max(window.frame.width, window.frame.height)
        guard longestSide > 0 else { return .failed }
        // Preview cards never render near full-window resolution. Capping the
        // decoded longest side keeps one cached BGRA image below ~1 MiB while
        // retaining more than 2x detail for the largest current card.
        let scale = min(2, 480 / longestSide)
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let screenCaptureResult = classifiedCapture(
                image,
                allowsUniformContent: allowsUniformContent
            )
            if screenCaptureResult.image != nil { return screenCaptureResult }

            let privateResult = await privateCaptureResult(
                windowID: window.windowID,
                allowsUniformContent: allowsUniformContent
            )
            if privateResult.image != nil { return privateResult }
            if privateResult.uniformImage != nil { return privateResult }
            if screenCaptureResult.uniformImage != nil { return screenCaptureResult }
            if screenCaptureResult.isEmptySurface || privateResult.isEmptySurface {
                logger.debug(
                    "Rejected visually blank preview pid=\(window.owningApplication?.processID ?? 0, privacy: .public) window=\(window.windowID, privacy: .public)"
                )
                return .emptySurface
            }
            return .failed
        } catch {
            return await privateCaptureResult(
                windowID: window.windowID,
                allowsUniformContent: allowsUniformContent
            )
        }
    }

    private static func privateCaptureResult(
        windowID: CGWindowID,
        allowsUniformContent: Bool
    ) async -> CaptureResult {
        await withCheckedContinuation { continuation in
            privateCaptureQueue.async {
                let result = autoreleasepool {
                    guard let image = WindowServerPrivateBridge.capture(
                        windowID: windowID
                    ) else { return CaptureResult.failed }
                    return classifiedCapture(
                        image,
                        allowsUniformContent: allowsUniformContent
                    )
                }
                continuation.resume(returning: result)
            }
        }
    }

    private static func classifiedCapture(
        _ image: CGImage,
        allowsUniformContent: Bool
    ) -> CaptureResult {
        guard image.width > 1, image.height > 1 else { return .failed }
        let isUniform: Bool
        if hasMeaningfulVisualContent(image) {
            isUniform = false
        } else if allowsUniformContent,
                  hasMeaningfulVisualContent(
                    image,
                    allowsUniformContent: true
                  ) {
            isUniform = true
        } else {
            return .emptySurface
        }
        guard let previewImage = previewSizedImage(image) else { return .failed }
        let appKitImage = NSImage(
            cgImage: previewImage,
            size: NSSize(width: previewImage.width, height: previewImage.height)
        )
        return isUniform ? .uniformImage(appKitImage) : .image(appKitImage)
    }

    private static func previewSizedImage(_ image: CGImage) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > 0 else { return nil }
        // Preview capture is a memory-reduction boundary. Never upscale a
        // small WindowServer image just to fill the cache budget.
        let scale = min(1, 480 / CGFloat(longestSide))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        if width == image.width, height == image.height { return image.copy() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Detects transparent or near-uniform frames at a fixed 40x40 cost. It is
    /// intentionally conservative: a mostly-white document with text or chrome
    /// remains valid, while a uniform white/transparent compositor shell does
    /// not become a false-success thumbnail.
    static func hasMeaningfulVisualContent(_ image: CGImage, allowsUniformContent: Bool = false) -> Bool {
        let width = 40
        let height = 40
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var opaqueCount = 0
        var luminanceSum = 0.0
        var luminanceSquaredSum = 0.0
        var minimumLuminance = 255.0
        var maximumLuminance = 0.0
        var colorBins: [UInt16: Int] = [:]
        // Inspect content, not the compositor edge or title-bar close dot.
        // Real blank documents are allowed only by independent AX evidence.
        // Exclude both vertical ends, independent of bitmap row orientation.
        let sampleOffsets = (5..<35).flatMap { y in (2..<38).map { x in (y * width + x) * 4 } }
        for offset in sampleOffsets {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 16 else { continue }
            opaqueCount += 1
            let luminance = 0.2126 * Double(red) +
                0.7152 * Double(green) +
                0.0722 * Double(blue)
            luminanceSum += luminance
            luminanceSquaredSum += luminance * luminance
            minimumLuminance = min(minimumLuminance, luminance)
            maximumLuminance = max(maximumLuminance, luminance)
            let bin = UInt16((red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4))
            colorBins[bin, default: 0] += 1
        }

        let totalSamples = sampleOffsets.count
        guard opaqueCount >= max(16, totalSamples / 25) else { return false }
        if allowsUniformContent { return true }
        let mean = luminanceSum / Double(opaqueCount)
        let variance = max(
            0,
            luminanceSquaredSum / Double(opaqueCount) - mean * mean
        )
        let standardDeviation = sqrt(variance)
        let dominantCoverage = Double(colorBins.values.max() ?? 0) /
            Double(opaqueCount)
        let luminanceRange = maximumLuminance - minimumLuminance

        if dominantCoverage >= 0.985 { return false }
        if dominantCoverage >= 0.96,
           standardDeviation < 12,
           luminanceRange < 48 {
            return false
        }
        return colorBins.count >= 2 || luminanceRange >= 8
    }

    private enum MatchResult {
        case matched(SCWindow)
        case ambiguous
        case notFound
    }

    private static func bestMatch(
        for request: WindowThumbnailRequest,
        among candidates: [SCWindow]
    ) -> MatchResult {
        if let windowID = request.windowID,
           let exact = candidates.first(where: { $0.windowID == windowID }) {
            return .matched(exact)
        }

        let requestedTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Geometry is the first public, cross-process identity signal after an
        // exact window number. Title is only a tie-breaker here; a far-away
        // helper window with the same title must not beat the real AX frame.
        if let requestedBounds = request.bounds {
            let geometryMatches = candidates.compactMap { window -> (SCWindow, CGFloat, Int)? in
                let distance = rectDistance(requestedBounds, window.frame)
                guard distance <= 96 else { return nil }
                return (window, distance, titleRank(requestedTitle, window.title ?? ""))
            }
            if let nearestDistance = geometryMatches.map(\.1).min() {
                let geometryTieTolerance: CGFloat = 4
                let nearBest = geometryMatches.filter {
                    $0.1 <= nearestDistance + geometryTieTolerance
                }
                let bestTitleRank = nearBest.map(\.2).min() ?? Int.max
                let finalists = nearBest.filter { $0.2 == bestTitleRank }
                guard finalists.count == 1, let unique = finalists.first else {
                    return .ambiguous
                }
                return .matched(unique.0)
            }
        }

        // Without usable geometry, only an exact non-empty raw title is safe.
        guard !requestedTitle.isEmpty else { return .notFound }
        let exactTitleMatches = candidates.filter {
            ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == requestedTitle
        }
        guard exactTitleMatches.count == 1, let unique = exactTitleMatches.first else {
            return exactTitleMatches.isEmpty ? .notFound : .ambiguous
        }
        return .matched(unique)
    }

    private static func rectDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) +
            abs(lhs.minY - rhs.minY) +
            abs(lhs.width - rhs.width) +
            abs(lhs.height - rhs.height)
    }

    private static func titleRank(_ requested: String, _ candidate: String) -> Int {
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate == requested { return 0 }
        if !candidate.isEmpty,
           !requested.isEmpty,
           (candidate.contains(requested) || requested.contains(candidate)) { return 1 }
        return 2
    }

    private static func recentCacheResult(
        for request: WindowThumbnailRequest,
        applicationIdentity: WindowThumbnailApplicationIdentity
    ) -> WindowThumbnailResult? {
        guard !currentTaskIsCancelled,
              authorizationState() == .authorized,
              applicationIdentity.matchesCurrentProcess() else { return nil }

        let keys: [String]
        if let windowID = request.windowID,
           windowID > 0 {
            // A public WindowServer number is the concrete identity. Never
            // fall through to a weaker title alias when it exists: a newly
            // opened window in the same process can legitimately reuse the
            // old title and geometry but must not inherit the old pixels.
            keys = [cacheKey(
               applicationIdentity: applicationIdentity,
               windowID: windowID
            )]
        } else if let aliasKey = safeAliasCacheKey(
            applicationIdentity: applicationIdentity,
            request: request
        ) {
            keys = [aliasKey]
        } else {
            return nil
        }
        guard let entry = cachedEntry(for: keys) else { return nil }
        guard !currentTaskIsCancelled,
              authorizationState() == .authorized,
              applicationIdentity.matchesCurrentProcess() else { return nil }
        return .recentCache(entry.image, timestamp: entry.capturedAt)
    }

    private static func fallbackResults(
        for requests: [WindowThumbnailRequest],
        applicationIdentity: WindowThumbnailApplicationIdentity,
        failure: WindowThumbnailResult
    ) -> [WindowThumbnailResult] {
        requests.map {
            recentCacheResult(
                for: $0,
                applicationIdentity: applicationIdentity
            ) ?? failure
        }
    }

    private static func failureResultAfterCaptureError() -> WindowThumbnailResult {
        switch authorizationState() {
        case .authorized: .captureFailed
        case .permissionRequired: .permissionRequired
        case .restartRequired: .restartRequired
        }
    }

    private static func repeated(
        _ result: WindowThumbnailResult,
        count: Int
    ) -> [WindowThumbnailResult] {
        Array(repeating: result, count: count)
    }

    private static var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private static func authorizationState() -> AuthorizationState {
        let permissionManager = PermissionsManager.shared
        guard permissionManager.checkScreenRecording() else {
            if permissionManager.screenRecordingGrantedAtProcessLaunch {
                markPermissionRevokedAfterLaunch()
            }
            purgeAllCache()
            return .permissionRequired
        }
        guard permissionManager.screenRecordingGrantedAtProcessLaunch,
              !permissionRevocationRequiresRestart() else {
            purgeAllCache()
            return .restartRequired
        }
        return .authorized
    }

    private static func cacheKey(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        windowID: CGWindowID
    ) -> String {
        "\(applicationIdentity.cacheNamespace)|window|\(windowID)"
    }

    private static func safeAliasCacheKey(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        request: WindowThumbnailRequest
    ) -> String? {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let bounds = request.bounds else { return nil }
        let boundsKey = [bounds.minX, bounds.minY, bounds.width, bounds.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
        return "\(applicationIdentity.cacheNamespace)|alias|\(request.title)|\(request.occurrence)|\(boundsKey)"
    }

    private static func cacheKeysForStore(
        exactKey: String,
        applicationIdentity: WindowThumbnailApplicationIdentity,
        request: WindowThumbnailRequest
    ) -> [String] {
        guard request.windowID == nil,
              let aliasKey = safeAliasCacheKey(
                applicationIdentity: applicationIdentity,
                request: request
              ) else { return [exactKey] }
        return [exactKey, aliasKey]
    }

    @discardableResult
    private static func store(
        _ entry: CachedThumbnail,
        keys: [String],
        expectedGeneration: UInt64
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cacheGeneration == expectedGeneration else { return false }
        let now = Date()
        pruneExpiredEntriesLocked(now: now)
        for key in keys { thumbnailCache[key] = entry }
        enforceCacheBudgetLocked()
        scheduleExpirationSweepLocked(now: now)
        return true
    }

    private static func discardCachedCapture(keys: [String], expectedGeneration: UInt64) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cacheGeneration == expectedGeneration else { return }
        for key in keys { thumbnailCache.removeValue(forKey: key) }
        scheduleExpirationSweepLocked(now: Date())
    }

    private static func enforceCacheBudgetLocked() {
        var byteCost = thumbnailCache.values.reduce(0) {
            $0 + $1.estimatedByteCost
        }
        guard thumbnailCache.count > maximumCacheKeyCount ||
                byteCost > maximumCacheByteCost else { return }
        for entry in thumbnailCache.sorted(by: {
            $0.value.capturedAt < $1.value.capturedAt
        }) {
            guard thumbnailCache.count > maximumCacheKeyCount ||
                    byteCost > maximumCacheByteCost else { break }
            if let removed = thumbnailCache.removeValue(forKey: entry.key) {
                byteCost -= removed.estimatedByteCost
            }
        }
    }

    private static func estimatedByteCost(of image: NSImage) -> Int {
        let bitmap = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { lhs, rhs in
                lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
            }
        let width = bitmap?.pixelsWide ?? Int(image.size.width.rounded(.up))
        let height = bitmap?.pixelsHigh ?? Int(image.size.height.rounded(.up))
        return max(1, width) * max(1, height) * 4
    }

    /// Keeps exactly one delayed release job for the cache. The previous
    /// implementation queued one block per stored key, so a screenshot burst
    /// retained a matching burst of delayed work for the full TTL.
    private static func scheduleExpirationSweepLocked(now: Date) {
        expirationSweepGeneration &+= 1
        let generation = expirationSweepGeneration
        expirationSweepWorkItem?.cancel()
        guard let oldestCapture = thumbnailCache.values
            .map(\.capturedAt)
            .min() else {
            expirationSweepWorkItem = nil
            return
        }
        let delay = max(
            0.05,
            oldestCapture.addingTimeInterval(recentCacheTTL + 0.1)
                .timeIntervalSince(now)
        )
        let item = DispatchWorkItem {
            cacheLock.lock()
            guard expirationSweepGeneration == generation else {
                cacheLock.unlock()
                return
            }
            pruneExpiredEntriesLocked(now: Date())
            expirationSweepWorkItem = nil
            scheduleExpirationSweepLocked(now: Date())
            cacheLock.unlock()
        }
        expirationSweepWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private static func cacheGenerationSnapshot() -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cacheGeneration
    }

    private static func markPermissionRevokedAfterLaunch() {
        cacheLock.lock()
        permissionWasRevokedAfterLaunch = true
        cacheLock.unlock()
    }

    private static func permissionRevocationRequiresRestart() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return permissionWasRevokedAfterLaunch
    }

    private static func cachedEntry(for keys: [String]) -> CachedThumbnail? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let now = Date()
        pruneExpiredEntriesLocked(now: now)
        return keys.lazy.compactMap { thumbnailCache[$0] }.first
    }

    private static func pruneExpiredEntriesLocked(now: Date) {
        thumbnailCache = thumbnailCache.filter {
            now.timeIntervalSince($0.value.capturedAt) <= recentCacheTTL
        }
    }

    static func clearAllCache() {
        purgeAllCache()
        WindowInventoryBindingHistory.shared.reset()
        WindowServerInventoryService.shared.invalidate()
        let resetRegistry = {
            WindowAXLifecycleRegistry.shared.reset()
        }
        if Thread.isMainThread {
            resetRegistry()
        } else {
            DispatchQueue.main.async(execute: resetRegistry)
        }
        notifyPreviewInvalidation()
    }

    /// Permission checks can happen while constructing a typed failure row.
    /// They must purge image memory without cancelling that same UI update;
    /// lifecycle and explicit feature boundaries call `clearAllCache()` and
    /// therefore also invalidate every persistent consumer model.
    private static func purgeAllCache() {
        cacheLock.lock()
        cacheGeneration &+= 1
        expirationSweepGeneration &+= 1
        expirationSweepWorkItem?.cancel()
        expirationSweepWorkItem = nil
        thumbnailCache.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }

    static func clearCache(processIdentifier: pid_t) {
        cacheLock.lock()
        cacheGeneration &+= 1
        thumbnailCache = thumbnailCache.filter {
            $0.value.processIdentifier != processIdentifier
        }
        scheduleExpirationSweepLocked(now: Date())
        cacheLock.unlock()
    }

    static func clearCache(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        request: WindowThumbnailRequest
    ) {
        var keys: [String] = []
        if let windowID = request.windowID, windowID > 0 {
            keys.append(cacheKey(
                applicationIdentity: applicationIdentity,
                windowID: windowID
            ))
        } else if let aliasKey = safeAliasCacheKey(
            applicationIdentity: applicationIdentity,
            request: request
        ) {
            keys.append(aliasKey)
        }
        cacheLock.lock()
        cacheGeneration &+= 1
        for key in keys { thumbnailCache.removeValue(forKey: key) }
        scheduleExpirationSweepLocked(now: Date())
        cacheLock.unlock()
    }

    /// Installs one process-lifetime set of cache privacy observers. The cache
    /// is memory-only, and is purged on sleep, lock/session switch, app exit,
    /// or target-process termination.
    @MainActor
    static func beginLifecycleMonitoring() {
        guard lifecycleObservers.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in invalidateAllPreviews() }
        )
        lifecycleObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in invalidateAllPreviews() }
        )
        lifecycleObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                clearCache(processIdentifier: application.processIdentifier)
                WindowInventoryBindingHistory.shared.remove(
                    processIdentifier: application.processIdentifier
                )
                WindowAXLifecycleRegistry.shared.remove(
                    processIdentifier: application.processIdentifier
                )
                WindowServerInventoryService.shared.invalidate()
                notifyPreviewInvalidation()
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in invalidateAllPreviews() }
        )

        lastKnownScreenRecordingPermission = PermissionsManager.shared.checkScreenRecording()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let currentPermission = PermissionsManager.shared.checkScreenRecording()
                if lastKnownScreenRecordingPermission == true, !currentPermission {
                    invalidateAllPreviews()
                }
                lastKnownScreenRecordingPermission = currentPermission
            }
        }
        permissionPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func invalidateAllPreviews() {
        clearAllCache()
    }

    private static func notifyPreviewInvalidation() {
        let post = {
            NotificationCenter.default.post(
                name: didInvalidatePreviewsNotification,
                object: nil
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}
