import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
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

/// Identifies both this observer installation and its window binding changes.
/// A newly installed observer must not validate capture work from an earlier
/// registry entry even when the process launch and numeric generation match.
struct WindowAXLifecycleRevision: Equatable, Sendable {
    let observationID: UUID
    let generation: UInt64

    init(observationID: UUID = UUID(), generation: UInt64 = 0) {
        self.observationID = observationID
        self.generation = generation
    }

    func advanced() -> Self {
        Self(observationID: observationID, generation: generation &+ 1)
    }
}

enum WindowAXLifecycleActionPolicy {
    static func guardedAction(
        captured: WindowAXLifecycleRevision?,
        current: @escaping () -> WindowAXLifecycleRevision?,
        action: @escaping () -> Void
    ) -> () -> Void {
        // Captured by the displayed row, independent of hover/capture cleanup
        // during the panel's delayed-hide grace period.
        { if isCurrent(captured: captured, current: current()) { action() } }
    }

    static func isCurrent(captured: WindowAXLifecycleRevision?, current: WindowAXLifecycleRevision?) -> Bool {
        // A missing observer must not turn a previously guarded row into an
        // unguarded one while its invalidation notification is still queued.
        captured == nil || captured == current
    }
}

struct WindowAXLifecycleChange: Sendable {
    let processLifetimeKey: String
    let windowIDs: Set<CGWindowID>
    let revision: WindowAXLifecycleRevision

    func affects(processLifetimeKey: String?, windowID: CGWindowID?) -> Bool {
        guard let processLifetimeKey, let windowID else { return false }
        return self.processLifetimeKey == processLifetimeKey
            && windowIDs.contains(windowID)
    }

    /// Notification handlers may run after the consumer has already rebuilt
    /// its rows. Only a snapshot older than this change in the same observer
    /// installation is stale; a delayed notification cannot cancel fresh work.
    func invalidates(_ capturedRevision: WindowAXLifecycleRevision) -> Bool {
        capturedRevision.observationID == revision.observationID
            && capturedRevision.generation < revision.generation
    }
}

/// Diagnostic reasons only. These codes never select cache or action behavior.
enum WindowPreviewCacheClearReason: String {
    case unspecified, dockStopped, commandTabStopped
    case dockAllPreviewsDisabled, commandTabAllPreviewsDisabled
    case willSleep, sessionResigned, appTerminating, screenPermissionRevoked
    case permissionRequired, permissionRestartRequired
}

/// A window number can also be inherited by application/group proxies. Only a
/// successful root-window observation may enter or replace an exact binding.
enum WindowAXLifecycleAdmissionPolicy {
    static func allowsTracking(
        expectedOwnerPID: pid_t,
        reportedOwnerPID: pid_t,
        windowID: CGWindowID?,
        roleReadResult: AXError,
        role: String?
    ) -> Bool {
        expectedOwnerPID > 0 && reportedOwnerPID == expectedOwnerPID
            && windowID.map { $0 > 0 } == true
            && roleReadResult == .success && role == kAXWindowRole as String
    }
}

/// A destruction callback belongs to one concrete AX proxy, not every later
/// proxy that happens to reuse its WindowServer ID. Temporary AX failures or
/// absence from AXWindows likewise do not prove a real window was destroyed.
enum WindowAXLifecycleRetirementPolicy {
    static func matchingWindowIDs<Element>(
        for element: Element,
        currentWindows: [CGWindowID: Element],
        sameElement: (Element, Element) -> Bool
    ) -> Set<CGWindowID> {
        Set(currentWindows.compactMap { windowID, current in
            windowID > 0 && sameElement(current, element) ? windowID : nil
        })
    }

    static func shouldRetire(roleReadResult: AXError) -> Bool {
        roleReadResult == .invalidUIElement
    }
}

/// A capture belongs to both a global privacy generation and one concrete
/// process launch. Retiring an A window must not reject B's in-flight pixels.
struct WindowThumbnailCaptureGeneration: Equatable, Sendable {
    let globalEpoch: UUID
    let processLifetimeKey: String
    let processEpoch: UInt64
}

/// The provenance needed to admit an exact-window cache entry without starting
/// another ScreenCaptureKit enumeration. Pixels and permission checks stay in
/// the provider; this value-only policy is shared by production and tests.
struct WindowThumbnailCacheMetadata: Equatable, Sendable {
    let processIdentifier: pid_t
    let windowID: CGWindowID
    let captureGeneration: WindowThumbnailCaptureGeneration
    let capturedAt: Date
}

enum WindowThumbnailCachePolicy {
    static func canRead(
        entry: WindowThumbnailCacheMetadata,
        requestedWindowID: CGWindowID?,
        processIdentifier: pid_t,
        expectedGeneration: WindowThumbnailCaptureGeneration,
        currentGeneration: WindowThumbnailCaptureGeneration,
        allowsDiscovery: Bool,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard let requestedWindowID, requestedWindowID > 0,
              requestedWindowID == entry.windowID,
              processIdentifier > 0,
              processIdentifier == entry.processIdentifier,
              !expectedGeneration.processLifetimeKey.isEmpty,
              expectedGeneration == currentGeneration,
              entry.captureGeneration == expectedGeneration,
              allowsDiscovery else { return false }
        let age = now.timeIntervalSince(entry.capturedAt)
        // A clock adjustment must not make a future-dated capture eligible.
        return age >= 0 && age < ttl
    }
}

/// Value-only generation bookkeeping. Production access is protected by the
/// thumbnail cache lock, including validation immediately before cache writes.
/// Only invalidated namespaces occupy the bounded table; untouched launches
/// use epoch zero. Capacity recycling changes the global identity so a removed
/// namespace can never alias an old epoch-zero capture.
struct WindowThumbnailCaptureGenerationTracker: Sendable {
    private var globalEpoch = UUID()
    private var processEpochs: [String: UInt64] = [:]
    private let maximumProcessEntries: Int

    init(maximumProcessEntries: Int = 64) {
        self.maximumProcessEntries = max(1, maximumProcessEntries)
    }

    var trackedProcessCount: Int { processEpochs.count }

    func snapshot(for processLifetimeKey: String) -> WindowThumbnailCaptureGeneration {
        WindowThumbnailCaptureGeneration(
            globalEpoch: globalEpoch,
            processLifetimeKey: processLifetimeKey,
            processEpoch: processEpochs[processLifetimeKey] ?? 0
        )
    }

    func isCurrent(
        _ generation: WindowThumbnailCaptureGeneration,
        for processLifetimeKey: String
    ) -> Bool {
        generation == snapshot(for: processLifetimeKey)
    }

    func areCurrent(_ generations: [WindowThumbnailCaptureGeneration]) -> Bool {
        !generations.isEmpty && generations.allSatisfy {
            isCurrent($0, for: $0.processLifetimeKey)
        }
    }

    mutating func invalidate(processLifetimeKey: String) {
        if processEpochs[processLifetimeKey] == nil,
           processEpochs.count >= maximumProcessEntries {
            invalidateAll()
        }
        if processEpochs[processLifetimeKey] == UInt64.max {
            invalidateAll()
        }
        processEpochs[processLifetimeKey] = (processEpochs[processLifetimeKey] ?? 0) + 1
    }

    mutating func invalidateAll() {
        globalEpoch = UUID()
        processEpochs.removeAll(keepingCapacity: false)
    }
}

/// Event-driven AX window registry shared by Dock and Cmd-Tab. Some Apps omit
/// inactive windows from `AXWindows`; remembering only exact window IDs seen in
/// lifecycle notifications preserves those real windows without admitting raw
/// WindowServer helper surfaces. The observer sources are installed on the
/// main run loop, and every public entry point is called from the main actor.
final class WindowAXLifecycleRegistry: @unchecked Sendable {
    static let shared = WindowAXLifecycleRegistry()
    static let didRetireWindowsNotification = Notification.Name(
        "WindowAXLifecycleRegistry.didRetireWindows"
    )

    private final class ProcessObservation {
        let identity: WindowThumbnailApplicationIdentity
        let applicationElement: AXUIElement
        let observer: AXObserver
        var revision = WindowAXLifecycleRevision()
        var windowsByID: [CGWindowID: AXUIElement] = [:]
        var recoveredWindowIDs: Set<CGWindowID> = []
        var subscribedWindowIDs: Set<CGWindowID> = []
        var notificationRegistrationResults: [
            String: WindowAXNotificationRegistrationDiagnostic
        ] = [:]
        var accessSequence: UInt64 = 0
        let diagnosticLifetimeToken: String
        var lastSeedDiagnostic: SeedDiagnostic?

        init(
            identity: WindowThumbnailApplicationIdentity,
            applicationElement: AXUIElement,
            observer: AXObserver
        ) {
            self.identity = identity
            self.applicationElement = applicationElement
            self.observer = observer
            self.diagnosticLifetimeToken = WindowAXLifecycleRegistry.diagnosticLifetimeToken(identity)
        }
    }

    private struct SeedDiagnostic: Equatable {
        let hasFocused: Bool
        let hasMain: Bool
        let windowsResult: Int32
        let windowsCount: Int
        let hasWindowsValue: Bool
        let windowsArrayDecoded: Bool
        let candidateCount: Int
        let retainedCount: Int
        let invalidCount: Int
    }

    private enum RemovalReason: String {
        case processIdentityChanged, processCapacity, processTerminated, registryReset
    }

    private enum TrackSource: String {
        case seed, windowCreated, focusedChanged, miniaturized, deminiaturized, exactRecovery
    }

    private enum RetirementReason: String {
        case destroyedCallback, invalidProxy
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
    // Independent from the business revision/guards; changes only for diagnostics.
    private var diagnosticRegistryEpoch: UInt64 = 0
    private let maximumObservedProcesses = 24
    private let maximumWindowsPerProcess = 64
    private let perWindowNotifications = [
        kAXUIElementDestroyedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String
    ]

    private init() {}

    private static func diagnosticLifetimeToken(
        _ identity: WindowThumbnailApplicationIdentity
    ) -> String {
#if DEBUG
        guard WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else { return "disabled" }
        return SHA256.hash(data: Data(identity.processLifetimeKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
#else
        return "disabled"
#endif
    }

    private func recordDiagnostic(
        _ event: String,
        observation: ProcessObservation? = nil,
        metadata: [String: WindowInteractionDiagnosticValue] = [:]
    ) {
#if DEBUG
        guard WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else { return }
        var values = metadata
        values["registryEpoch"] = .integer(Int64(bitPattern: diagnosticRegistryEpoch))
        if let observation {
            values["ownerPID"] = .integer(Int64(observation.identity.processIdentifier))
            values["observerID"] = .code(observation.revision.observationID.uuidString)
            values["lifetimeToken"] = .code(observation.diagnosticLifetimeToken)
            values["bindingGeneration"] = .integer(Int64(bitPattern: observation.revision.generation))
        }
        WindowLifecycleDiagnosticRecorder.shared.record(event: event, metadata: values)
#endif
    }

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
            removeObservation(processIdentifier: identity.processIdentifier, reason: .processIdentityChanged)
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
              let observer = createdObserver else {
            recordDiagnostic("observerCreateFailed", metadata: [
                "ownerPID": .integer(Int64(identity.processIdentifier)),
                "lifetimeToken": .code(Self.diagnosticLifetimeToken(identity)),
                "axResult": .integer(Int64(observerCreationResult.rawValue))
            ])
            return
        }

        let observation = ProcessObservation(
            identity: identity,
            applicationElement: applicationElement,
            observer: observer
        )
        observationsByPID[identity.processIdentifier] = observation
        touch(observation)
        recordDiagnostic("observerCreated", observation: observation, metadata: [
            "observerCount": .integer(Int64(observationsByPID.count))
        ])
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
    func windowElements(
        for application: NSRunningApplication,
        refreshBeforeRead: Bool = true
    ) -> [AXUIElement] {
        dispatchPrecondition(condition: .onQueue(.main))
        // Recovery callers already read fresh AX sources and hold a lifecycle
        // token. Re-seeding here could replace a proxy and invalidate that very
        // recovery. A snapshot read preserves real observer invalidations.
        if refreshBeforeRead { observe(application: application) }
        guard let identity = WindowThumbnailApplicationIdentity(
                  application: application
              ),
              let observation = observationsByPID[identity.processIdentifier],
              observation.identity == identity else { return [] }
        touch(observation)
        return observation.windowsByID
            .filter { windowID, _ in
                !observation.recoveredWindowIDs.contains(windowID) ||
                    (WindowThumbnailProvider.allowsPreviewDiscovery(applicationIdentity: identity, windowID: windowID) &&
                     WindowServerPrivateBridge.isOrderedIn(windowID: windowID, ownerPID: identity.processIdentifier) == true)
            }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    /// Recovery fills missing registrations only. Replacing a known proxy is
    /// left to the normal lifecycle path, which advances its invalidation token.
    func recoverableWindowIDs(
        _ windowIDs: Set<CGWindowID>, identity: WindowThumbnailApplicationIdentity,
        discoverWhenEmpty: Bool = false
    ) -> Set<CGWindowID> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard identity.matchesCurrentProcess(),
              let observation = observationsByPID[identity.processIdentifier],
              observation.identity == identity else { return [] }
        var targets = windowIDs
        if targets.isEmpty && discoverWhenEmpty {
            let snapshot = WindowServerInventoryService.shared.snapshot(for: [identity.processIdentifier])
            targets = Set(snapshot.surfaces.filter {
                $0.ownerPID == identity.processIdentifier && $0.bounds.width >= 160 && $0.bounds.height >= 100 &&
                    WindowInventoryReconciler.isRetainablePrivateTarget($0, mode: snapshot.mode)
            }.map(\.windowID))
        }
        return Set(targets.filter {
            $0 > 0 && observation.windowsByID[$0] == nil &&
                WindowThumbnailProvider.allowsPreviewDiscovery(applicationIdentity: identity, windowID: $0)
        })
    }

    func allowsRecoveredAction(windowID: CGWindowID, identity: WindowThumbnailApplicationIdentity) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let observation = observationsByPID[identity.processIdentifier],
              observation.identity == identity,
              observation.recoveredWindowIDs.contains(windowID) else { return true }
        return WindowThumbnailProvider.allowsPreviewDiscovery(applicationIdentity: identity, windowID: windowID) &&
            WindowServerPrivateBridge.isOrderedIn(windowID: windowID, ownerPID: identity.processIdentifier) == true
    }

    @discardableResult
    func admitRecoveredWindows(
        _ result: WindowAXExactRecoveryResult,
        identity: WindowThumbnailApplicationIdentity,
        expectedRevision: WindowAXLifecycleRevision?
    ) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AXIsProcessTrusted(), identity.matchesCurrentProcess(),
              let observation = observationsByPID[identity.processIdentifier],
              observation.identity == identity, observation.revision == expectedRevision else { return 0 }
        let eligible = recoverableWindowIDs(Set(result.elements.keys), identity: identity)
        var accepted = 0
        for windowID in eligible.sorted() {
            guard let element = result.elements[windowID],
                  windowDirectWindowNumber(of: element) == windowID,
                  WindowServerPrivateBridge.isOrderedIn(windowID: windowID, ownerPID: identity.processIdentifier) == true
            else { continue }
            track(element, in: observation, source: .exactRecovery)
            if observation.windowsByID[windowID].map({ CFEqual($0, element) }) == true {
                observation.recoveredWindowIDs.insert(windowID)
                accepted += 1
            }
        }
        recordDiagnostic("exactRecovery", observation: observation, metadata: [
            "attempts": .integer(Int64(result.attempts)),
            "foundCount": .integer(Int64(result.elements.count)),
            "acceptedCount": .integer(Int64(accepted)),
            "elapsedMS": .integer(Int64(result.elapsedMilliseconds.rounded()))
        ])
        return accepted
    }

    /// Does not seed AX windows or install an observer. Consumers compare the
    /// token captured before asynchronous thumbnail work with this live token
    /// before publishing its rows.
    func revision(
        for identity: WindowThumbnailApplicationIdentity
    ) -> WindowAXLifecycleRevision? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let observation = observationsByPID[identity.processIdentifier],
              observation.identity == identity else { return nil }
        return observation.revision
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
                notificationRegistrations: [],
                registryEpoch: diagnosticRegistryEpoch
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
                } ?? [],
            observerID: matchingObservation?.revision.observationID.uuidString,
            registryEpoch: diagnosticRegistryEpoch,
            bindingGeneration: matchingObservation?.revision.generation
        )
    }

    func remove(processIdentifier: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        removeObservation(processIdentifier: processIdentifier, reason: .processTerminated)
    }

    func reset(
        reason: WindowPreviewCacheClearReason = .unspecified,
        clearRequestID: String? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        diagnosticRegistryEpoch &+= 1
        var metadata: [String: WindowInteractionDiagnosticValue] = [
            "reason": .code(reason.rawValue),
            "observerCount": .integer(Int64(observationsByPID.count))
        ]
        if let clearRequestID { metadata["clearRequestID"] = .code(clearRequestID) }
        recordDiagnostic("registryResetStarted", metadata: metadata)
        for processIdentifier in Array(observationsByPID.keys) {
            removeObservation(processIdentifier: processIdentifier, reason: .registryReset)
        }
        accessSequence = 0
        observerCreationResultsByPID.removeAll(keepingCapacity: false)
        metadata["observerCount"] = .integer(Int64(observationsByPID.count))
        recordDiagnostic("registryResetApplied", metadata: metadata)
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
        case kAXWindowCreatedNotification as String:
            track(element, in: observation, source: .windowCreated)
        case kAXWindowMiniaturizedNotification as String:
            track(element, in: observation, source: .miniaturized)
        case kAXWindowDeminiaturizedNotification as String:
            track(element, in: observation, source: .deminiaturized)
        case kAXFocusedWindowChangedNotification as String:
            if let focused = elementAttribute(
                kAXFocusedWindowAttribute,
                of: observation.applicationElement
            ) {
                track(focused, in: observation, source: .focusedChanged)
            } else {
                recordDiagnostic("focusedCallbackEmpty", observation: observation)
            }
        case kAXUIElementDestroyedNotification as String:
            let removedIDs = WindowAXLifecycleRetirementPolicy.matchingWindowIDs(
                for: element,
                currentWindows: observation.windowsByID,
                sameElement: { CFEqual($0, $1) }
            )
            recordDiagnostic("destructionCallback", observation: observation, metadata: [
                "matchedWindowCount": .integer(Int64(removedIDs.count))
            ])
            retire(removedIDs, in: observation, reason: .destroyedCallback)
        default:
            break
        }
    }

    private func seedCurrentWindows(in observation: ProcessObservation) {
        var windows: [AXUIElement] = []
        var hasFocused = false
        var hasMain = false
        for attribute in [
            kAXFocusedWindowAttribute,
            kAXMainWindowAttribute
        ] {
            if let window = elementAttribute(
                attribute,
                of: observation.applicationElement
            ) {
                if attribute == kAXFocusedWindowAttribute { hasFocused = true }
                if attribute == kAXMainWindowAttribute { hasMain = true }
                if !windows.contains(where: { CFEqual($0, window) }) {
                    windows.append(window)
                }
            }
        }
        var value: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            observation.applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        var windowsCount = 0
        var windowsArrayDecoded = false
        if windowsResult == .success,
        let available = value as? [AXUIElement] {
            windowsArrayDecoded = true
            windowsCount = available.count
            for window in available
            where !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        for window in windows { track(window, in: observation, source: .seed) }

        // Some Apps do not deliver every destruction notification. Only an
        // explicitly invalid cached AX object is sufficient fallback evidence;
        // a minimized/fullscreen window missing from AXWindows remains valid.
        let invalidIDs = Set(observation.windowsByID.compactMap { windowID, element in
            var role: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &role
            )
            let shouldRetire = WindowAXLifecycleRetirementPolicy.shouldRetire(
                roleReadResult: result
            )
            if shouldRetire {
                recordDiagnostic("proxyReadInvalid", observation: observation, metadata: [
                    "windowID": .integer(Int64(windowID)),
                    "axResult": .integer(Int64(result.rawValue))
                ])
            }
            return shouldRetire ? windowID : nil
        })
        retire(invalidIDs, in: observation, reason: .invalidProxy)
        let diagnostic = SeedDiagnostic(
            hasFocused: hasFocused, hasMain: hasMain,
            windowsResult: Int32(windowsResult.rawValue), windowsCount: windowsCount,
            hasWindowsValue: value != nil, windowsArrayDecoded: windowsArrayDecoded,
            candidateCount: windows.count, retainedCount: observation.windowsByID.count,
            invalidCount: invalidIDs.count
        )
        if diagnostic != observation.lastSeedDiagnostic {
            observation.lastSeedDiagnostic = diagnostic
            recordDiagnostic("seedState", observation: observation, metadata: [
                "hasFocused": .flag(hasFocused), "hasMain": .flag(hasMain),
                "axResult": .integer(Int64(windowsResult.rawValue)),
                "attributeWindowCount": .integer(Int64(windowsCount)),
                "hasWindowsValue": .flag(value != nil),
                "windowsArrayDecoded": .flag(windowsArrayDecoded),
                "candidateCount": .integer(Int64(windows.count)),
                "retainedCount": .integer(Int64(observation.windowsByID.count)),
                "invalidCount": .integer(Int64(invalidIDs.count))
            ])
        }
    }

    private func track(
        _ element: AXUIElement,
        in observation: ProcessObservation,
        source: TrackSource
    ) {
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(element, &ownerPID) == .success,
              ownerPID == observation.identity.processIdentifier,
              let windowID = windowDirectWindowNumber(of: element),
              windowID > 0 else {
            if source != .seed {
                recordDiagnostic("callbackWithoutExactWindow", observation: observation, metadata: [
                    "source": .code(source.rawValue)
                ])
            }
            return
        }
        let wasTracked = observation.windowsByID[windowID] != nil
        let replacedProxy = observation.windowsByID[windowID].map {
            !CFEqual($0, element)
        } ?? false
        if !wasTracked || replacedProxy {
            // Validate before removing subscriptions or replacing a retained
            // proxy. A bad candidate with the same WID must not evict a healthy
            // window returned earlier in this seed. Unchanged entries retain
            // the existing seed role check without an extra AX round trip.
            var role: CFTypeRef?
            let roleReadResult = AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &role
            )
            guard WindowAXLifecycleAdmissionPolicy.allowsTracking(
                expectedOwnerPID: observation.identity.processIdentifier,
                reportedOwnerPID: ownerPID,
                windowID: windowID,
                roleReadResult: roleReadResult,
                role: role as? String
            ) else { return }
        }
        if replacedProxy, let existing = observation.windowsByID[windowID] {
            removeWindowNotifications(
                from: existing,
                observation: observation
            )
            observation.subscribedWindowIDs.remove(windowID)
        }
        observation.windowsByID[windowID] = element
        if source != .exactRecovery {
            observation.recoveredWindowIDs.remove(windowID)
        }
        if !wasTracked || replacedProxy || source != .seed {
            recordDiagnostic(
                !wasTracked ? "windowTracked" : replacedProxy ? "proxyReplaced" : "windowSignal",
                observation: observation,
                metadata: [
                    "windowID": .integer(Int64(windowID)),
                    "source": .code(source.rawValue),
                    "retainedCount": .integer(Int64(observation.windowsByID.count))
                ]
            )
        }
        if observation.windowsByID.count > maximumWindowsPerProcess {
            let retainedIDs = Set(
                observation.windowsByID.keys.sorted().suffix(
                    maximumWindowsPerProcess
                )
            )
            for (candidateID, candidateElement) in observation.windowsByID
            where !retainedIDs.contains(candidateID) {
                recordDiagnostic("windowEvicted", observation: observation, metadata: [
                    "windowID": .integer(Int64(candidateID)),
                    "reason": .code("windowCapacity")
                ])
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
            observation.recoveredWindowIDs.formIntersection(retainedIDs)
        }
        if observation.subscribedWindowIDs.insert(windowID).inserted {
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
        if replacedProxy {
            invalidateBindings([windowID], in: observation)
        }
        // Registry membership alone is not proof of a new valid window. In
        // particular, a stale AX proxy can survive a seed read after closing.
        if WindowThumbnailProvider.needsPreviewDiscoveryReestablishment(
            applicationIdentity: observation.identity,
            windowID: windowID
        ) {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == (kAXWindowRole as String),
               let descriptions = WindowServerWindowDescriptions.copy(for: [windowID]) as? [[String: Any]],
               descriptions.contains(where: {
                   ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                       ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
               }) {
                let reestablished = WindowThumbnailProvider.reestablishPreviewDiscovery(
                    applicationIdentity: observation.identity,
                    windowID: windowID
                )
                recordDiagnostic("discoveryReestablishResult", observation: observation, metadata: [
                    "windowID": .integer(Int64(windowID)),
                    "changed": .flag(reestablished)
                ])
            }
        }
    }

    private func retire(
        _ windowIDs: Set<CGWindowID>,
        in observation: ProcessObservation,
        reason: RetirementReason
    ) {
        let currentIDs = windowIDs.intersection(observation.windowsByID.keys)
        guard !currentIDs.isEmpty else { return }
        for windowID in currentIDs {
            recordDiagnostic("windowRetired", observation: observation, metadata: [
                "windowID": .integer(Int64(windowID)),
                "reason": .code(reason.rawValue)
            ])
            if let element = observation.windowsByID.removeValue(forKey: windowID) {
                removeWindowNotifications(from: element, observation: observation)
            }
            observation.subscribedWindowIDs.remove(windowID)
            observation.recoveredWindowIDs.remove(windowID)
        }
        invalidateBindings(currentIDs, in: observation, recordsRetirement: true)
    }

    /// Complete all synchronous invalidation before notifying UI consumers.
    /// A retained private surface cannot recreate the binding; only a new
    /// exact AX observation can establish it again.
    private func invalidateBindings(
        _ windowIDs: Set<CGWindowID>,
        in observation: ProcessObservation,
        recordsRetirement: Bool = false
    ) {
        guard !windowIDs.isEmpty else { return }
        WindowInventoryBindingHistory.shared.forget(
            windowIDs: windowIDs,
            processLifetimeKey: observation.identity.processLifetimeKey
        )
        observation.revision = observation.revision.advanced()
        recordDiagnostic("bindingsInvalidated", observation: observation, metadata: [
            "windowCount": .integer(Int64(windowIDs.count)),
            "reason": .code(recordsRetirement ? "retired" : "proxyReplaced")
        ])
        if recordsRetirement {
            WindowThumbnailProvider.retirePreviewDiscovery(
                applicationIdentity: observation.identity,
                windowIDs: windowIDs
            )
        } else {
            for windowID in windowIDs {
                WindowThumbnailProvider.clearCache(
                    applicationIdentity: observation.identity,
                    request: WindowThumbnailRequest(
                        title: "",
                        occurrence: 0,
                        bounds: nil,
                        windowID: windowID
                    )
                )
            }
        }
        WindowServerInventoryService.shared.invalidate()
        NotificationCenter.default.post(
            name: Self.didRetireWindowsNotification,
            object: WindowAXLifecycleChange(
                processLifetimeKey: observation.identity.processLifetimeKey,
                windowIDs: windowIDs,
                revision: observation.revision
            )
        )
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
            recordDiagnostic("notificationRegistered", observation: observation, metadata: [
                "notification": .code(notification),
                "windowID": .integer(Int64(targetWindowID ?? 0)),
                "axResult": .integer(Int64(result.rawValue))
            ])
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
            removeObservation(processIdentifier: oldestPID, reason: .processCapacity)
        }
    }

    private func removeObservation(processIdentifier: pid_t, reason: RemovalReason) {
        observerCreationResultsByPID.removeValue(forKey: processIdentifier)
        guard let observation = observationsByPID.removeValue(
            forKey: processIdentifier
        ) else { return }
        recordDiagnostic("observerRemoved", observation: observation, metadata: [
            "reason": .code(reason.rawValue),
            "windowCount": .integer(Int64(observation.windowsByID.count)),
            "remainingObserverCount": .integer(Int64(observationsByPID.count))
        ])
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

/// Unbound compositor surfaces need positive ordered-in evidence. A separate
/// backing store can retain pixels after the actual AX window has retired.
/// This gate is not used for exact AX windows, including minimized windows.
enum WindowPreviewDiscoveryLivenessPolicy {
    static func allowsSurface(discoveryAllowed: Bool, orderedIn: Bool?) -> Bool {
        discoveryAllowed && orderedIn == true
    }

    static func select<Candidate>(
        from candidates: [Candidate],
        maximumCount: Int,
        isLive: (Candidate) -> Bool,
        isDuplicate: (Candidate, Candidate) -> Bool
    ) -> [Candidate] {
        guard maximumCount > 0 else { return [] }
        var accepted: [Candidate] = []
        for candidate in candidates where isLive(candidate) {
            guard !accepted.contains(where: { isDuplicate($0, candidate) }) else { continue }
            accepted.append(candidate)
            if accepted.count == maximumCount { break }
        }
        return accepted
    }
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

/// Retirement filtering precedes both the best-score anchor and the capture
/// limit. Otherwise retired compositor surfaces can crowd out a live Renderer.
enum WindowRendererSelectionPolicy {
    static func nearBest<Candidate>(
        from candidates: [Candidate],
        isAllowed: (Candidate) -> Bool,
        score: (Candidate) -> CGFloat,
        overlap: (Candidate) -> CGFloat,
        windowID: (Candidate) -> CGWindowID
    ) -> [Candidate] {
        let sorted = candidates.filter(isAllowed).sorted {
            score($0) == score($1) ? windowID($0) < windowID($1) : score($0) < score($1)
        }
        guard let best = sorted.first else { return [] }
        return Array(sorted.filter {
            score($0) <= score(best) + 12 && abs(overlap($0) - overlap(best)) <= 0.04
        }.prefix(4))
    }
}

/// The filter's content size is the capture source in points. Its desktop
/// origin must not contribute to output dimensions or crop the window.
enum WindowThumbnailCaptureConfiguration {
    static func make(contentRect: CGRect) -> SCStreamConfiguration? {
        let size = contentRect.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }

        // Preserve the existing preview memory budget and maximum upscaling.
        // Pixel rounding may differ by half a pixel on the shorter edge;
        // ScreenCaptureKit preserves the source aspect ratio within that box.
        let scale = min(2, 480 / max(size.width, size.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
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
        let metadata: WindowThumbnailCacheMetadata
        let estimatedByteCost: Int

        var capturedAt: Date { metadata.capturedAt }
        var processIdentifier: pid_t { metadata.processIdentifier }
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
    // Protected by cacheLock; coalesces only repeated empty diagnostic purges.
    private static var lastDiagnosticPurgeReason: WindowPreviewCacheClearReason?
    private static var expirationSweepWorkItem: DispatchWorkItem?
    private static var expirationSweepGeneration: UInt64 = 0
    /// Invalidates captures that were already in flight when a privacy or
    /// lifecycle boundary purged the cache. Cancellation alone is insufficient:
    /// ScreenCaptureKit may finish a capture after sleep/lock or after a feature
    /// toggle, and that late result must never repopulate cleared memory.
    private static var captureGenerations = WindowThumbnailCaptureGenerationTracker()
    // Shares cacheLock with capture generations: a new request cannot observe
    // a post-retirement epoch without also seeing its discovery exclusion.
    // Privacy/cache resets intentionally preserve these metadata-only IDs.
    private static var discoveryRetirements = WindowPreviewDiscoveryRetirementHistory()
    private static var permissionWasRevokedAfterLaunch = false
    @MainActor private static var lifecycleObservers: [NSObjectProtocol] = []
    @MainActor private static var permissionPollTimer: Timer?
    @MainActor private static var lastKnownScreenRecordingPermission: Bool?

    /// Consumers call this immediately before showing pixels, after any actor
    /// hop. Keep the launch/revocation policy centralized with capture access.
    static func presentationFailureResult() -> WindowThumbnailResult? {
        switch authorizationState() {
        case .authorized: nil
        case .permissionRequired: .permissionRequired
        case .restartRequired: .restartRequired
        }
    }

    /// Reuses only same-process, exact-window pixels under the token recorded
    /// with the consumer's current window inventory. A miss never starts AX or
    /// ScreenCaptureKit work; the ordinary capture path supplies fresh results.
    /// Callers must still validate their selection and AX revision before use.
    static func validatedCachedResults(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        requests: [WindowThumbnailRequest],
        expectedCacheGeneration: WindowThumbnailCaptureGeneration
    ) -> [WindowThumbnailResult?] {
        guard !requests.isEmpty else { return [] }
        let misses = [WindowThumbnailResult?](repeating: nil, count: requests.count)
        // Authorization may purge the cache and acquire cacheLock itself.
        guard !currentTaskIsCancelled,
              authorizationState() == .authorized,
              applicationIdentity.matchesCurrentProcess() else { return misses }

        cacheLock.lock()
        let now = Date()
        pruneExpiredEntriesLocked(now: now)
        let entries = requests.map { request -> CachedThumbnail? in
            guard let windowID = request.windowID, windowID > 0,
                  let entry = thumbnailCache[cacheKey(
                    applicationIdentity: applicationIdentity,
                    windowID: windowID
                  )],
                  canReadCachedEntryLocked(
                    entry,
                    request: request,
                    applicationIdentity: applicationIdentity,
                    expectedGeneration: expectedCacheGeneration,
                    now: now
                  ) else { return nil }
            return entry
        }
        cacheLock.unlock()

        guard !currentTaskIsCancelled,
              authorizationState() == .authorized,
              applicationIdentity.matchesCurrentProcess() else { return misses }

        cacheLock.lock()
        defer { cacheLock.unlock() }
        let checkedAt = Date()
        return zip(requests, entries).map { request, entry in
            guard let entry, let windowID = request.windowID,
                  let current = thumbnailCache[cacheKey(
                    applicationIdentity: applicationIdentity,
                    windowID: windowID
                  )],
                  current.image === entry.image,
                  current.metadata == entry.metadata,
                  canReadCachedEntryLocked(
                    entry,
                    request: request,
                    applicationIdentity: applicationIdentity,
                    expectedGeneration: expectedCacheGeneration,
                    now: checkedAt
                  ) else { return nil }
            return .recentCache(entry.image, timestamp: entry.capturedAt)
        }
    }

    /// Requires cacheLock. Never call permission or process APIs while locked.
    private static func canReadCachedEntryLocked(
        _ entry: CachedThumbnail,
        request: WindowThumbnailRequest,
        applicationIdentity: WindowThumbnailApplicationIdentity,
        expectedGeneration: WindowThumbnailCaptureGeneration,
        now: Date
    ) -> Bool {
        WindowThumbnailCachePolicy.canRead(
            entry: entry.metadata,
            requestedWindowID: request.windowID,
            processIdentifier: applicationIdentity.processIdentifier,
            expectedGeneration: expectedGeneration,
            currentGeneration: captureGenerations.snapshot(for: applicationIdentity.processLifetimeKey),
            allowsDiscovery: discoveryRetirements.allowsDiscovery(
                windowID: entry.metadata.windowID,
                processIdentifier: applicationIdentity.processIdentifier,
                processLifetimeKey: applicationIdentity.processLifetimeKey
            ),
            now: now,
            ttl: recentCacheTTL
        )
    }

    /// Captures off-Space and minimized windows through ScreenCaptureKit. Each
    /// request is matched to one WindowServer window, preferring an exact
    /// window number and then AX geometry. If a native fullscreen window is no
    /// longer enumerated in the current Space, the exact same process/window
    /// may reuse a preview captured during the previous 60 seconds. Every
    /// failure remains typed so callers can explain why no image is shown.
    static func captureWindows(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        requests: [WindowThumbnailRequest],
        expectedCacheGeneration: WindowThumbnailCaptureGeneration? = nil
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
        // Detached prewarm work may start after its AX window was retired.
        // Preserve the token recorded when its requests were constructed so
        // old work cannot acquire a new generation and repopulate the cache.
        let expectedCacheGeneration = expectedCacheGeneration
            ?? cacheGenerationSnapshot(for: applicationIdentity)
        guard cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
            return repeated(.captureFailed, count: requests.count)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            guard cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
                return repeated(.captureFailed, count: requests.count)
            }
            let fallback = fallbackResults(
                for: requests,
                applicationIdentity: applicationIdentity,
                failure: failureResultAfterCaptureError()
            )
            guard !Task.isCancelled,
                  cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
                return repeated(.captureFailed, count: requests.count)
            }
            return fallback
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
        applicationIdentity: WindowThumbnailApplicationIdentity,
        expectedCacheGeneration: WindowThumbnailCaptureGeneration? = nil
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
        let expectedCacheGeneration = expectedCacheGeneration
            ?? cacheGenerationSnapshot(for: applicationIdentity)
        guard cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
            return .unavailable(.captureFailed)
        }
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
              applicationIdentity.matchesCurrentProcess(),
              cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
            return .unavailable(.notEnumerated)
        }

        let candidates = fallbackPreviewCandidates(
            in: content,
            applicationIdentity: applicationIdentity
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
              cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
            return .unavailable(.captureFailed)
        }
        return .windows(zip(requests, results).filter {
            guard let windowID = $0.0.windowID else { return false }
            // Capture suspends; the accepted surface may have been ordered out
            // in the meantime without ever owning an AX destruction callback.
            return allowsUnboundPreviewDiscovery(applicationIdentity: applicationIdentity, windowID: windowID)
        }.map {
            WindowThumbnailDiscoveredWindow(request: $0.0, result: $0.1)
        })
    }

    private static func captureWindows(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        requests: [WindowThumbnailRequest],
        content: SCShareableContent,
        expectedCacheGeneration: WindowThumbnailCaptureGeneration
    ) async -> [WindowThumbnailResult] {
        let applicationPID = applicationIdentity.processIdentifier
        guard !Task.isCancelled,
              cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration,
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
                    windowID: window.windowID,
                    request: request,
                    applicationIdentity: applicationIdentity,
                    expectedCacheGeneration: expectedCacheGeneration
                )
            } else {
                if captureResult.isEmptySurface {
                    discardCachedCapture(
                        keys: cacheKeysForStore(exactKey: key, applicationIdentity: applicationIdentity, request: request),
                        applicationIdentity: applicationIdentity,
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
                        windowID: window.windowID,
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
        guard cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration else {
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
        windowID: CGWindowID,
        request: WindowThumbnailRequest,
        applicationIdentity: WindowThumbnailApplicationIdentity,
        expectedCacheGeneration: WindowThumbnailCaptureGeneration
    ) -> WindowThumbnailResult {
        let entry = CachedThumbnail(
            image: image,
            metadata: WindowThumbnailCacheMetadata(
                processIdentifier: applicationIdentity.processIdentifier,
                windowID: windowID,
                captureGeneration: expectedCacheGeneration,
                capturedAt: Date()
            ),
            estimatedByteCost: estimatedByteCost(of: image)
        )
        let stored = store(
            entry,
            keys: cacheKeysForStore(
                exactKey: cacheKey(applicationIdentity: applicationIdentity, windowID: windowID),
                applicationIdentity: applicationIdentity,
                request: request
            ),
            applicationIdentity: applicationIdentity,
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
        applicationIdentity: WindowThumbnailApplicationIdentity
    ) -> [SCWindow] {
        let processIdentifier = applicationIdentity.processIdentifier
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

        return WindowPreviewDiscoveryLivenessPolicy.select(
            from: content.windows,
            maximumCount: maximumFallbackWindowCount,
            isLive: { window in
                guard window.owningApplication?.processID == processIdentifier,
                      window.windowLayer == 0,
                      window.frame.width >= 160,
                      window.frame.height >= 100,
                      !parentFrames.contains(where: { rectDistance($0, window.frame) <= 12 }) else {
                    return false
                }
                return allowsUnboundPreviewDiscovery(
                    applicationIdentity: applicationIdentity,
                    windowID: window.windowID
                )
            },
            // Liveness precedes duplicate suppression and the capture limit,
            // so an old shell cannot displace a real same-frame window.
            isDuplicate: { rectDistance($0.frame, $1.frame) <= 8 }
        )
    }

    private static func allowsUnboundPreviewDiscovery(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        windowID: CGWindowID
    ) -> Bool {
        guard allowsPreviewDiscovery(applicationIdentity: applicationIdentity, windowID: windowID) else {
            return false
        }
        return WindowPreviewDiscoveryLivenessPolicy.allowsSurface(
            discoveryAllowed: true,
            orderedIn: WindowServerPrivateBridge.isOrderedIn(
                windowID: windowID, ownerPID: applicationIdentity.processIdentifier
            )
        )
    }

    private static func parentProcessIdentifier(of processIdentifier: pid_t) -> pid_t? {
        processSnapshot(of: processIdentifier)?.parentProcessIdentifier
    }

    private struct AncestorHostedPreviewCandidate {
        let window: SCWindow
        let parentSnapshot: ProcessSnapshot
        let ancestorSnapshot: ProcessSnapshot
        let parentIdentity: WindowThumbnailApplicationIdentity
        let ancestorIdentity: WindowThumbnailApplicationIdentity
        let parentCaptureGeneration: WindowThumbnailCaptureGeneration
        let ancestorCaptureGeneration: WindowThumbnailCaptureGeneration
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
           let parentIdentity = NSRunningApplication(processIdentifier: parentSnapshot.processIdentifier)
            .flatMap({ WindowThumbnailApplicationIdentity(application: $0) }),
           let ancestorIdentity = NSRunningApplication(processIdentifier: ancestorSnapshot.processIdentifier)
            .flatMap({ WindowThumbnailApplicationIdentity(application: $0) }),
           parentIdentity.matchesCurrentProcess(),
           ancestorIdentity.matchesCurrentProcess(),
           let targetBundlePath = applicationIdentity.bundlePath,
           let ancestorBundlePath = NSRunningApplication(
                processIdentifier: ancestorSnapshot.processIdentifier
           )?.bundleURL?.standardizedFileURL.path else {
            return .notFound
        }
        let parentCaptureGeneration = cacheGenerationSnapshot(for: parentIdentity)
        let ancestorCaptureGeneration = cacheGenerationSnapshot(for: ancestorIdentity)

        let targetAnchors = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == targetPID &&
                allowsPreviewDiscovery(applicationIdentity: applicationIdentity, windowID: window.windowID) &&
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
                allowsPreviewDiscovery(window: window) &&
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
                allowsPreviewDiscovery(window: window) &&
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
            ancestorSnapshot: ancestorSnapshot,
            parentIdentity: parentIdentity,
            ancestorIdentity: ancestorIdentity,
            parentCaptureGeneration: parentCaptureGeneration,
            ancestorCaptureGeneration: ancestorCaptureGeneration
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
        expectedCacheGeneration: WindowThumbnailCaptureGeneration
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
            let ownerGenerations = [candidate.parentCaptureGeneration, candidate.ancestorCaptureGeneration]
            guard candidate.parentIdentity.matchesCurrentProcess(),
                  candidate.ancestorIdentity.matchesCurrentProcess(),
                  areCaptureGenerationsCurrent(ownerGenerations) else {
                return .unavailable(.captureFailed)
            }
            let image = await capture(window: candidate.window)
            guard !Task.isCancelled,
                  cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration,
                  applicationIdentity.matchesCurrentProcess(),
                  candidate.parentIdentity.matchesCurrentProcess(),
                  candidate.ancestorIdentity.matchesCurrentProcess(),
                  areCaptureGenerationsCurrent(ownerGenerations),
                  processSnapshot(
                    of: candidate.parentSnapshot.processIdentifier
                  ) == candidate.parentSnapshot,
                  processSnapshot(
                    of: candidate.ancestorSnapshot.processIdentifier
                  ) == candidate.ancestorSnapshot,
                  case let .matched(currentCandidate) = ancestorHostedPreviewMatch(
                    applicationIdentity: applicationIdentity,
                    in: content
                  ),
                  currentCandidate.window.windowID == candidate.window.windowID,
                  currentCandidate.parentSnapshot == candidate.parentSnapshot,
                  currentCandidate.ancestorSnapshot == candidate.ancestorSnapshot else {
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
        let processIdentity: WindowThumbnailApplicationIdentity
        let captureGeneration: WindowThumbnailCaptureGeneration
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

            guard let processIdentity = NSRunningApplication(processIdentifier: owner.processID)
                .flatMap({ WindowThumbnailApplicationIdentity(application: $0) }),
                  processIdentity.matchesCurrentProcess() else { continue }
            let captureGeneration = cacheGenerationSnapshot(for: processIdentity)
            guard allowsPreviewDiscovery(applicationIdentity: processIdentity, windowID: window.windowID) else {
                continue
            }
            let onScreenPenalty: CGFloat =
                window.isOnScreen == shellWindow.isOnScreen ? 0 : 24
            let score = rectDistance(shellWindow.frame, window.frame) +
                relationshipPenalty +
                onScreenPenalty
            matches.append(RelatedRendererCandidate(
                window: window,
                processSnapshot: snapshot,
                processIdentity: processIdentity,
                captureGeneration: captureGeneration,
                overlap: overlap,
                score: score
            ))
        }

        // Multi-process UI frameworks can publish several same-geometry child
        // surfaces for one actionable shell. Every candidate here already has
        // verified process ancestry, bundle containment, and strong geometry,
        // so try only the bounded near-best set until one yields substantive
        // pixels. Treating this normal compositor stack as identity ambiguity
        // made WeChat and similar Apps permanently unpreviewable.
        let nearBest = WindowRendererSelectionPolicy.nearBest(
            from: matches,
            isAllowed: {
                allowsPreviewDiscovery(applicationIdentity: $0.processIdentity, windowID: $0.window.windowID) &&
                    areCaptureGenerationsCurrent([$0.captureGeneration])
            },
            score: { $0.score },
            overlap: { $0.overlap },
            windowID: { $0.window.windowID }
        )
        return nearBest.isEmpty ? .notFound : .matched(nearBest)
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
        expectedCacheGeneration: WindowThumbnailCaptureGeneration
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
                      cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration,
                      applicationIdentity.matchesCurrentProcess() else {
                    return .captureFailed
                }
                guard processSnapshot(
                    of: candidate.processSnapshot.processIdentifier
                ) == candidate.processSnapshot,
                      candidate.processIdentity.matchesCurrentProcess(),
                      areCaptureGenerationsCurrent([candidate.captureGeneration]),
                      allowsPreviewDiscovery(window: candidate.window) else { continue }
                switch authorizationState() {
                case .permissionRequired: return .permissionRequired
                case .restartRequired: return .restartRequired
                case .authorized: break
                }
                guard let image = await capture(window: candidate.window) else {
                    continue
                }
                guard !Task.isCancelled,
                      cacheGenerationSnapshot(for: applicationIdentity) == expectedCacheGeneration,
                      applicationIdentity.matchesCurrentProcess(),
                      processSnapshot(of: candidate.processSnapshot.processIdentifier) == candidate.processSnapshot,
                      candidate.processIdentity.matchesCurrentProcess(),
                      areCaptureGenerationsCurrent([candidate.captureGeneration]),
                      allowsPreviewDiscovery(window: candidate.window) else { continue }
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
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let configuration = WindowThumbnailCaptureConfiguration.make(
            contentRect: filter.contentRect
        ) else { return .failed }

        do {
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
            purgeAllCache(reason: .permissionRequired)
            return .permissionRequired
        }
        guard permissionManager.screenRecordingGrantedAtProcessLaunch,
              !permissionRevocationRequiresRestart() else {
            purgeAllCache(reason: .permissionRestartRequired)
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
        applicationIdentity: WindowThumbnailApplicationIdentity,
        expectedGeneration: WindowThumbnailCaptureGeneration
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard captureGenerations.isCurrent(
            expectedGeneration,
            for: applicationIdentity.processLifetimeKey
        ) else { return false }
        let now = Date()
        pruneExpiredEntriesLocked(now: now)
        for key in keys { thumbnailCache[key] = entry }
        enforceCacheBudgetLocked()
        scheduleExpirationSweepLocked(now: now)
        return true
    }

    private static func discardCachedCapture(
        keys: [String],
        applicationIdentity: WindowThumbnailApplicationIdentity,
        expectedGeneration: WindowThumbnailCaptureGeneration
    ) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard captureGenerations.isCurrent(
            expectedGeneration,
            for: applicationIdentity.processLifetimeKey
        ) else { return }
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

    static func cacheGenerationSnapshot(
        for applicationIdentity: WindowThumbnailApplicationIdentity
    ) -> WindowThumbnailCaptureGeneration {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return captureGenerations.snapshot(for: applicationIdentity.processLifetimeKey)
    }

    private static func areCaptureGenerationsCurrent(_ generations: [WindowThumbnailCaptureGeneration]) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return captureGenerations.areCurrent(generations)
    }

    static func allowsPreviewDiscovery(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        windowID: CGWindowID
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return discoveryRetirements.allowsDiscovery(
            windowID: windowID,
            processIdentifier: applicationIdentity.processIdentifier,
            processLifetimeKey: applicationIdentity.processLifetimeKey
        )
    }

    static func needsPreviewDiscoveryReestablishment(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        windowID: CGWindowID
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return discoveryRetirements.needsReestablishment(
            windowID: windowID,
            processIdentifier: applicationIdentity.processIdentifier,
            processLifetimeKey: applicationIdentity.processLifetimeKey
        )
    }

    /// Cross-process preview bridges must respect retirement of their actual
    /// pixel owner too. Unknown ownership cannot override an existing veto.
    private static func allowsPreviewDiscovery(window: SCWindow) -> Bool {
        guard let processIdentifier = window.owningApplication?.processID else { return false }
        let identity = NSRunningApplication(processIdentifier: processIdentifier)
            .flatMap { WindowThumbnailApplicationIdentity(application: $0) }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return discoveryRetirements.allowsDiscovery(
            windowID: window.windowID,
            processIdentifier: processIdentifier,
            processLifetimeKey: identity?.processLifetimeKey
        )
    }

    static func retirePreviewDiscovery(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        windowIDs: Set<CGWindowID>
    ) {
        guard applicationIdentity.matchesCurrentProcess(), !windowIDs.isEmpty else { return }
        cacheLock.lock()
        discoveryRetirements.retire(
            windowIDs: windowIDs,
            processIdentifier: applicationIdentity.processIdentifier,
            processLifetimeKey: applicationIdentity.processLifetimeKey
        )
        captureGenerations.invalidate(processLifetimeKey: applicationIdentity.processLifetimeKey)
        for windowID in windowIDs {
            thumbnailCache.removeValue(forKey: cacheKey(
                applicationIdentity: applicationIdentity,
                windowID: windowID
            ))
        }
        scheduleExpirationSweepLocked(now: Date())
        cacheLock.unlock()
    }

    /// Called only after registry validation of a live AX window, its direct
    /// number, and the current WindowServer owner. A screenshot is insufficient.
    @discardableResult
    static func reestablishPreviewDiscovery(
        applicationIdentity: WindowThumbnailApplicationIdentity,
        windowID: CGWindowID
    ) -> Bool {
        guard applicationIdentity.matchesCurrentProcess() else { return false }
        cacheLock.lock()
        let reestablished = discoveryRetirements.reestablish(
            windowID: windowID,
            processIdentifier: applicationIdentity.processIdentifier,
            processLifetimeKey: applicationIdentity.processLifetimeKey
        )
        if reestablished {
            captureGenerations.invalidate(processLifetimeKey: applicationIdentity.processLifetimeKey)
        }
        cacheLock.unlock()
        return reestablished
    }

    private static func removeRetirementsForTerminatedProcess(_ processIdentifier: pid_t) {
        let current = NSRunningApplication(processIdentifier: processIdentifier)
        let identity = current.flatMap { WindowThumbnailApplicationIdentity(application: $0) }
        // Do not erase metadata when a PID is live but its lifetime cannot be
        // established, or when this is a delayed notification for an old PID.
        guard current == nil || current?.isTerminated == true || identity != nil else { return }
        cacheLock.lock()
        discoveryRetirements.remove(
            processIdentifier: processIdentifier,
            keepingProcessLifetimeKey: identity?.processLifetimeKey
        )
        cacheLock.unlock()
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

    static func clearAllCache(reason: WindowPreviewCacheClearReason = .unspecified) {
        let clearRequestID = UUID().uuidString
        WindowLifecycleDiagnosticRecorder.shared.record(event: "cacheClearRequested", metadata: [
            "clearRequestID": .code(clearRequestID), "reason": .code(reason.rawValue),
            "requestedOnMain": .flag(Thread.isMainThread)
        ])
        purgeAllCache(reason: reason, clearRequestID: clearRequestID)
        WindowInventoryBindingHistory.shared.reset()
        WindowServerInventoryService.shared.invalidate()
        let resetRegistry = {
            WindowAXLifecycleRegistry.shared.reset(reason: reason, clearRequestID: clearRequestID)
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
    private static func purgeAllCache(
        reason: WindowPreviewCacheClearReason,
        clearRequestID: String? = nil
    ) {
        cacheLock.lock()
        let imageCount = thumbnailCache.count
        let shouldRecordPurge = clearRequestID != nil || imageCount > 0 ||
            lastDiagnosticPurgeReason != reason
        lastDiagnosticPurgeReason = reason
        captureGenerations.invalidateAll()
        expirationSweepGeneration &+= 1
        expirationSweepWorkItem?.cancel()
        expirationSweepWorkItem = nil
        thumbnailCache.removeAll(keepingCapacity: false)
        cacheLock.unlock()
        guard shouldRecordPurge else { return }
        var metadata: [String: WindowInteractionDiagnosticValue] = [
            "reason": .code(reason.rawValue),
            "imageCount": .integer(Int64(imageCount)),
            "registryResetRequested": .flag(clearRequestID != nil)
        ]
        if let clearRequestID { metadata["clearRequestID"] = .code(clearRequestID) }
        WindowLifecycleDiagnosticRecorder.shared.record(event: "imageCachePurged", metadata: metadata)
    }

    static func clearCache(processIdentifier: pid_t) {
        cacheLock.lock()
        captureGenerations.invalidateAll()
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
        captureGenerations.invalidate(processLifetimeKey: applicationIdentity.processLifetimeKey)
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
            ) { _ in invalidateAllPreviews(reason: .willSleep) }
        )
        lifecycleObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in invalidateAllPreviews(reason: .sessionResigned) }
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
                removeRetirementsForTerminatedProcess(application.processIdentifier)
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
            ) { _ in invalidateAllPreviews(reason: .appTerminating) }
        )

        lastKnownScreenRecordingPermission = PermissionsManager.shared.checkScreenRecording()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let currentPermission = PermissionsManager.shared.checkScreenRecording()
                if lastKnownScreenRecordingPermission == true, !currentPermission {
                    invalidateAllPreviews(reason: .screenPermissionRevoked)
                }
                lastKnownScreenRecordingPermission = currentPermission
            }
        }
        permissionPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func invalidateAllPreviews(reason: WindowPreviewCacheClearReason) {
        clearAllCache(reason: reason)
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
