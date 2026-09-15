import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import OSLog

enum MissionControlInspectionPolicy {
    static func shouldSchedule(
        force: Bool,
        missionControlHierarchyObserved: Bool
    ) -> Bool {
        force || missionControlHierarchyObserved
    }
}

enum MissionControlRootPresence: Equatable, Sendable {
    case present
    case absent
    case unavailable
}

/// A motion-driven recovery probe is separate from a full window inspection.
/// Invalidating a session keeps its outstanding slot occupied until completion,
/// so a delayed AX reply cannot queue overlapping work or resurrect that session.
struct MissionControlRootRecovery {
    struct Request: Equatable, Sendable {
        let generation: UInt64
        let sequence: UInt64
    }

    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private(set) var inFlight: Request?
    private(set) var nextAllowedNanoseconds: UInt64 = 0

    mutating func invalidate() { generation &+= 1 }

    func delayNanoseconds(now: UInt64) -> UInt64 {
        nextAllowedNanoseconds > now ? nextAllowedNanoseconds - now : 0
    }

    mutating func begin(now: UInt64) -> Request? {
        guard inFlight == nil, delayNanoseconds(now: now) == 0 else { return nil }
        sequence &+= 1
        let request = Request(generation: generation, sequence: sequence)
        inFlight = request
        return request
    }

    /// Only a timely, complete positive probe may arm the strict target resolver.
    mutating func finish(
        _ request: Request,
        result: MissionControlRootPresence,
        now: UInt64,
        elapsedNanoseconds: UInt64,
        canPublish: Bool
    ) -> Bool {
        guard inFlight == request else { return false }
        inFlight = nil
        let slow = elapsedNanoseconds > 120_000_000
        let cooldown: UInt64 = slow ? 2_000_000_000
            : (result == .unavailable ? 1_000_000_000 : 250_000_000)
        nextAllowedNanoseconds = now &+ cooldown
        return request.generation == generation && canPublish && !slow && result == .present
    }
}

private typealias MissionControlAXWindowNumberResolver = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
) -> AXError

private let missionControlPrivateWindowNumberResolver: MissionControlAXWindowNumberResolver? = {
    let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    let handles = [
        dlopen(nil, RTLD_LAZY),
        dlopen(frameworkPath, RTLD_LAZY)
    ].compactMap { $0 }
    for handle in handles {
        if let symbol = dlsym(handle, "_AXUIElementGetWindow") {
            return unsafeBitCast(symbol, to: MissionControlAXWindowNumberResolver.self)
        }
    }
    return nil
}()

/// Returns one exact WindowServer identity or nothing. Public AX attributes
/// and the private WindowServer resolver must agree when both are available;
/// a conflicting or missing identity is deliberately non-actionable.
private func missionControlDirectWindowNumber(
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
    if let resolver = missionControlPrivateWindowNumberResolver {
        var number: CGWindowID = 0
        if resolver(element, &number) == .success, number > 0 {
            numbers.insert(number)
        }
    }
    guard numbers.count == 1 else { return nil }
    return numbers.first
}

#if DEBUG
private typealias MissionControlCGSMainConnectionID = @convention(c) () -> UInt32
private typealias MissionControlCGSGetWindowOwner = @convention(c) (
    UInt32,
    CGWindowID,
    UnsafeMutablePointer<UInt32>
) -> Int32
private typealias MissionControlSLSConnectionGetPID = @convention(c) (
    UInt32,
    UnsafeMutablePointer<pid_t>
) -> Int32
private typealias MissionControlCGSCopyManagedDisplaySpaces = @convention(c) (
    UInt32
) -> Unmanaged<CFArray>?
private typealias MissionControlCGSCopyWindowsWithOptionsAndTags = @convention(c) (
    UInt32,
    UInt32,
    CFArray,
    UInt32,
    UnsafePointer<UInt64>?,
    UnsafePointer<UInt64>?
) -> Unmanaged<CFArray>?
private typealias MissionControlCGSCopySpacesForWindows = @convention(c) (
    UInt32,
    UInt32,
    CFArray
) -> Unmanaged<CFArray>?
#endif

private struct MissionControlAXHit: @unchecked Sendable {
    let thumbnailFrame: CGRect
    let window: AXUIElement
    let windowNumber: CGWindowID
    let ownerPID: pid_t
    let canClose: Bool
}

private enum MissionControlAXResolution: @unchecked Sendable {
    case outsideMissionControl(String)
    case indeterminate(String)
    case missionControlWithoutExactTarget(String)
    case valid(MissionControlAXHit)

    var diagnosticCode: String {
        switch self {
        case let .outsideMissionControl(code),
             let .indeterminate(code),
             let .missionControlWithoutExactTarget(code):
            code
        case .valid:
            "valid"
        }
    }
}

private final class MissionControlMouseIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingDelivery: (@Sendable () -> Void)?

    func submit(_ delivery: @escaping @Sendable () -> Void) {
        lock.lock()
        let needsScheduling = pendingDelivery == nil
        pendingDelivery = delivery
        guard needsScheduling else {
            lock.unlock()
            return
        }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let latestDelivery = self.pendingDelivery
            self.pendingDelivery = nil
            self.lock.unlock()
            latestDelivery?()
        }
    }

    func reset() {
        lock.lock()
        pendingDelivery = nil
        lock.unlock()
    }
}

enum MissionControlCloseClickDecision {
    case suppressedPassThrough
    case passThrough
    case consume
    case consumeAndTrigger
}

/// A lock-protected snapshot shared with the Quartz event-tap callback. It
/// stores only the close control's global Quartz bounds and the current click
/// sequence; the callback never reaches into AppKit or Accessibility.
final class MissionControlCloseInteractionState: @unchecked Sendable {
    private let lock = NSLock()
    private var visibleRegion: CGRect?
    private let interaction = ZilanEventTapInteractionState()

    var isSuppressed: Bool { interaction.isSuppressed }

    func beginZilanSuppression(requestID: String) -> Bool {
        // The same lock prevents an in-flight hit-test from starting a capture
        // between checking the lease and returning its ACK.
        lock.withLock { interaction.beginSuppression(requestID: requestID) }
    }

    func endZilanSuppression(requestID: String) {
        interaction.endSuppression(requestID: requestID)
    }

    func updateVisibleRegion(_ region: CGRect?) {
        lock.lock()
        visibleRegion = region
        lock.unlock()
    }

    func decision(
        for type: CGEventType,
        location: CGPoint
    ) -> MissionControlCloseClickDecision {
        lock.lock()
        defer { lock.unlock() }
        guard !interaction.isSuppressed else { return .suppressedPassThrough }
        guard type == .leftMouseDown ||
                type == .leftMouseUp ||
                type == .leftMouseDragged else {
            return .passThrough
        }
        switch type {
        case .leftMouseDown:
            if interaction.isCapturing {
                return .consume
            }
            guard let visibleRegion,
                  visibleRegion.contains(location) else {
                return .passThrough
            }
            guard interaction.beginCapture() else { return .suppressedPassThrough }
            return .consumeAndTrigger
        case .leftMouseUp:
            guard interaction.isCapturing else { return .passThrough }
            interaction.endCapture()
            return .consume
        case .leftMouseDragged:
            return interaction.isCapturing ? .consume : .passThrough
        default:
            return .passThrough
        }
    }

    func reset() {
        lock.lock()
        visibleRegion = nil
        interaction.endCapture()
        lock.unlock()
    }
}

/// Mission Control is hosted by the Dock/WindowManager and does not reliably
/// forward pointer motion through NSEvent's global monitor on macOS 26. A
/// Quartz tap observes the session stream. It modifies the stream only for a
/// complete left-click sequence that begins inside the visible close control;
/// every other event is returned unchanged. The callback is intentionally
/// bounded to one motion delivery per display frame, and it performs no AX or
/// AppKit work.
private final class MissionControlMouseEventTap: @unchecked Sendable {
    private let closeInteractionState: MissionControlCloseInteractionState
    private let motionDelivery: @Sendable () -> Void
    private let closeDelivery: @Sendable () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var lastDeliveryNanoseconds: UInt64 = 0
    private let minimumDeliveryIntervalNanoseconds: UInt64 = 16_000_000

    init(
        closeInteractionState: MissionControlCloseInteractionState,
        motionDelivery: @escaping @Sendable () -> Void,
        closeDelivery: @escaping @Sendable () -> Void
    ) {
        self.closeInteractionState = closeInteractionState
        self.motionDelivery = motionDelivery
        self.closeDelivery = closeDelivery
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue |
            CGEventMask(1) << CGEventType.leftMouseDragged.rawValue |
            CGEventMask(1) << CGEventType.leftMouseDown.rawValue |
            CGEventMask(1) << CGEventType.leftMouseUp.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: missionControlMouseEventTapCallback,
            userInfo: userInfo
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        lock.lock()
        lastDeliveryNanoseconds = 0
        lock.unlock()
        closeInteractionState.reset()
    }

    fileprivate func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            closeInteractionState.reset()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }
        switch closeInteractionState.decision(
            for: type,
            location: event.location
        ) {
        case .suppressedPassThrough:
            return false
        case .consumeAndTrigger:
            closeDelivery()
            return true
        case .consume:
            return true
        case .passThrough:
            break
        }
        guard type == .mouseMoved || type == .leftMouseDragged else {
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard now &- lastDeliveryNanoseconds >= minimumDeliveryIntervalNanoseconds else {
            lock.unlock()
            return false
        }
        lastDeliveryNanoseconds = now
        lock.unlock()
        motionDelivery()
        return false
    }

    deinit {
        stop()
    }
}

private let missionControlMouseEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    let shouldConsume: Bool
    if let userInfo {
        shouldConsume = Unmanaged<MissionControlMouseEventTap>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
            .handle(type: type, event: event)
    } else {
        shouldConsume = false
    }
    return shouldConsume ? nil : Unmanaged.passUnretained(event)
}

private final class MissionControlMonitorWeakBox: @unchecked Sendable {
    weak var value: MissionControlInteractionMonitor?

    init(_ value: MissionControlInteractionMonitor) {
        self.value = value
    }
}

/// Performs the potentially blocking Accessibility IPC away from the main
/// thread. Only one request is submitted by the monitor at a time. Every AX
/// application object receives a short messaging timeout so an unresponsive
/// Dock or target App degrades to no affordance instead of blocking the UI.
private final class MissionControlAXResolver: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.workview.SuperIsland.mission-control-resolver",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let messagingTimeout: Float = 0.075
    private let missionControlStabilizationNanoseconds: UInt64 = 300_000_000
    private var observedMissionControlRoot: (
        hash: CFHashCode,
        firstSeenNanoseconds: UInt64
    )?

#if DEBUG
    // Tests replace only the existing scene read; routing and canonicalization
    // still run through resolveSynchronously without querying desktop AX.
    private var sceneSnapshotForTesting: MissionControlAXResolution?

    /// Read-only shadow diagnostics for the isolated WE1 test bundle. This
    /// follows the identity-validation portion of WINS' observed scene path
    /// without changing target selection or enabling any destructive action.
    private var sceneProbeLastSampleNanoseconds: UInt64 = 0
    private var sceneProbeLastPrivateInventoryNanoseconds: UInt64 = 0
    private var sceneProbeLastFingerprint = ""
    private var sceneProbeRemainingSamples = 12
    private var sceneProbePrivateInventoryRemainingSamples = 4
    private var sceneProbeCachedApplicationRoots: [pid_t: AXUIElement] = [:]
    private let sceneProbeLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland",
        category: "MissionControlSceneProbe"
    )

    private struct SceneProbeProxyGeometry {
        let depth: Int
        let role: String
        let identifier: String
        let frame: CGRect
        let windowNumbers: [CGWindowID]
    }

    private struct SceneProbePublicWindow {
        let windowNumber: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
    }

    private struct SceneProbeAXWindow {
        let windowNumber: CGWindowID
        let frame: CGRect?
    }

    private static let privateCGSOwnerResolvers: (
        mainConnectionID: MissionControlCGSMainConnectionID,
        getWindowOwner: MissionControlCGSGetWindowOwner,
        connectionGetPID: MissionControlSLSConnectionGetPID,
        copyManagedDisplaySpaces: MissionControlCGSCopyManagedDisplaySpaces,
        copyWindowsWithOptionsAndTags: MissionControlCGSCopyWindowsWithOptionsAndTags,
        copySpacesForWindows: MissionControlCGSCopySpacesForWindows
    )? = {
        let handles = [
            dlopen(nil, RTLD_LAZY),
            dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
        ].compactMap { $0 }
        for handle in handles {
            guard let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
                  let ownerSymbol = dlsym(handle, "CGSGetWindowOwner"),
                  let pidSymbol = dlsym(handle, "SLSConnectionGetPID"),
                  let spacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
                  let windowsSymbol = dlsym(
                      handle,
                      "CGSCopyWindowsWithOptionsAndTags"
                  ),
                  let windowSpacesSymbol = dlsym(
                      handle,
                      "CGSCopySpacesForWindows"
                  ) else {
                continue
            }
            return (
                unsafeBitCast(mainSymbol, to: MissionControlCGSMainConnectionID.self),
                unsafeBitCast(ownerSymbol, to: MissionControlCGSGetWindowOwner.self),
                unsafeBitCast(pidSymbol, to: MissionControlSLSConnectionGetPID.self),
                unsafeBitCast(
                    spacesSymbol,
                    to: MissionControlCGSCopyManagedDisplaySpaces.self
                ),
                unsafeBitCast(
                    windowsSymbol,
                    to: MissionControlCGSCopyWindowsWithOptionsAndTags.self
                ),
                unsafeBitCast(
                    windowSpacesSymbol,
                    to: MissionControlCGSCopySpacesForWindows.self
                )
            )
        }
        return nil
    }()
#endif

    func resolve(
        point: CGPoint,
        dockPID: pid_t,
        completion: @escaping @Sendable (MissionControlAXResolution, UInt64) -> Void
    ) {
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let resolution = autoreleasepool {
                resolveSynchronously(point: point, dockPID: dockPID)
            }
            completion(
                resolution,
                DispatchTime.now().uptimeNanoseconds &- started
            )
        }
    }

    /// Read only Dock's direct children. Never enumerate application windows or
    /// descend into Mission Control merely because the desktop pointer moved.
    func probeRootPresence(
        dockPID: pid_t,
        completion: @escaping @Sendable (MissionControlRootPresence, UInt64) -> Void
    ) {
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let result: MissionControlRootPresence = autoreleasepool {
                guard dockPID > 0 else { return .unavailable }
                let application = AXUIElementCreateApplication(dockPID)
                AXUIElementSetMessagingTimeout(application, 0.015)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    application, kAXChildrenAttribute as CFString, &value
                ) == .success,
                let children = value as? [AXUIElement], children.count <= 32 else {
                    return .unavailable
                }
                let deadline = started &+ 45_000_000
                var roots = 0
                for child in children {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else {
                        return .unavailable
                    }
                    AXUIElementSetMessagingTimeout(child, 0.015)
                    var identifier: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(
                        child, "AXIdentifier" as CFString, &identifier
                    )
                    if error == .attributeUnsupported || error == .noValue { continue }
                    guard error == .success, let identifier = identifier as? String else {
                        return .unavailable
                    }
                    if normalizedAXToken(identifier) == "mc" { roots += 1 }
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    return .unavailable
                }
                switch roots {
                case 0: return .absent
                case 1: return .present
                default: return .unavailable
                }
            }
            completion(result, DispatchTime.now().uptimeNanoseconds &- started)
        }
    }

    /// Revalidates a destructive action against the identity that was bound to
    /// the visible affordance. A generic point resolver is intentionally not
    /// used here: overlapping WindowServer rectangles can be ambiguous at a
    /// thumbnail's center even though the selected window ID remains exact.
    func resolveExpectedTarget(
        windowNumber: CGWindowID,
        ownerPID: pid_t,
        expectedThumbnailFrame: CGRect,
        dockPID: pid_t,
        completion: @escaping @Sendable (MissionControlAXResolution, UInt64) -> Void
    ) {
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let resolution = autoreleasepool {
                resolveExpectedTargetSynchronously(
                    windowNumber: windowNumber,
                    ownerPID: ownerPID,
                    expectedThumbnailFrame: expectedThumbnailFrame,
                    dockPID: dockPID
                )
            }
            completion(
                resolution,
                DispatchTime.now().uptimeNanoseconds &- started
            )
        }
    }

    func resetMissionControlSession() {
        queue.async { [weak self] in
            self?.observedMissionControlRoot = nil
#if DEBUG
            self?.sceneProbeLastSampleNanoseconds = 0
            self?.sceneProbeLastPrivateInventoryNanoseconds = 0
            self?.sceneProbeLastFingerprint = ""
            self?.sceneProbeRemainingSamples = 12
            self?.sceneProbePrivateInventoryRemainingSamples = 4
            self?.sceneProbeCachedApplicationRoots.removeAll(keepingCapacity: true)
#endif
        }
    }

    private func resolveSynchronously(
        point: CGPoint,
        dockPID: pid_t
    ) -> MissionControlAXResolution {
        // An absent or ambiguous current Dock scene is terminal evidence.
        // App-owned AX groups inherit the real window ID, and their ordinary
        // subrectangles are not proof of a Mission Control thumbnail.
        canonicalized(resolveFromSceneSnapshot(point: point, dockPID: dockPID))
    }

    /// Mission Control's AX hierarchy supplies transformed thumbnail geometry,
    /// but only the all-Space WindowServer inventory can prove that the bound
    /// PID/window number is still one canonical user surface. This single
    /// post-filter covers every scene and compatibility resolver branch.
    private func canonicalized(
        _ resolution: MissionControlAXResolution,
        forceRefresh: Bool = false
    ) -> MissionControlAXResolution {
        guard case let .valid(hit) = resolution else { return resolution }
        let snapshot = WindowServerInventoryService.shared.snapshot(
            for: [hit.ownerPID],
            forceRefresh: forceRefresh
        )
        guard snapshot.surfaces.contains(where: {
            $0.windowID == hit.windowNumber
                && $0.ownerPID == hit.ownerPID
                && $0.layer == 0
        }) else {
            return .missionControlWithoutExactTarget(
                "window-server-canonical-target-missing"
            )
        }
        return resolution
    }

    private func resolveExpectedTargetSynchronously(
        windowNumber: CGWindowID,
        ownerPID: pid_t,
        expectedThumbnailFrame: CGRect,
        dockPID: pid_t
    ) -> MissionControlAXResolution {
        guard windowNumber > 0,
              ownerPID > 0,
              ownerPID != dockPID,
              ownerPID != ProcessInfo.processInfo.processIdentifier else {
            return .indeterminate("close-invalid-identity")
        }

        let dockApplication = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockApplication, 0.025)
        let missionControlRoots = childAttributeElements(
            kAXChildrenAttribute,
            of: dockApplication
        ).filter {
            normalizedAXToken(stringAttribute("AXIdentifier", of: $0) ?? "") == "mc"
        }
        guard missionControlRoots.count == 1 else {
            return .missionControlWithoutExactTarget(
                missionControlRoots.isEmpty
                    ? "close-mc-root-missing"
                    : "close-mc-root-ambiguous"
            )
        }

        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let descriptions = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .indeterminate("close-window-server-unavailable")
        }
        let matches = descriptions.filter { description in
            guard let number = description[kCGWindowNumber as String] as? NSNumber else {
                return false
            }
            return CGWindowID(number.uint32Value) == windowNumber
        }
        guard matches.count == 1,
              let description = matches.first,
              let currentOwner = description[kCGWindowOwnerPID as String] as? NSNumber,
              pid_t(currentOwner.int32Value) == ownerPID,
              let layer = description[kCGWindowLayer as String] as? NSNumber,
              layer.intValue == 0,
              let currentFrame = windowFrame(
                  from: description[kCGWindowBounds as String]
              ),
              thumbnailFrameIsStable(
                  currentFrame,
                  comparedWith: expectedThumbnailFrame
              ),
              let liveWindow = resolveExactWindow(
                  processIdentifier: ownerPID,
                  windowNumber: windowNumber
              ),
              isTransformedMissionControlFrame(
                  currentFrame,
                  liveWindow: liveWindow
              ) else {
            return .missionControlWithoutExactTarget("close-exact-target-changed")
        }

        return canonicalized(.valid(MissionControlAXHit(
            thumbnailFrame: currentFrame,
            window: liveWindow,
            windowNumber: windowNumber,
            ownerPID: ownerPID,
            canClose: elementAttribute(
                kAXCloseButtonAttribute,
                of: liveWindow
            ) != nil
        )), forceRefresh: true)
    }

    private func thumbnailFrameIsStable(
        _ current: CGRect,
        comparedWith expected: CGRect
    ) -> Bool {
        let sizeDelta = max(
            abs(current.width - expected.width),
            abs(current.height - expected.height)
        )
        let originDelta = max(
            abs(current.minX - expected.minX),
            abs(current.minY - expected.minY)
        )
        return sizeDelta <= 12 && originDelta <= 16
    }

    /// Mission Control creates a transient `AXIdentifier == "mc"` direct child
    /// under the Dock. Hammerspoon uses the same root and documents that the
    /// subtree is incomplete until the Mission Control animation settles.
    /// Anchor the bounded scan to that concrete root instead of guessing across
    /// all WindowManager/Dock windows, then geometry-hit-test only exact
    /// AXExposeWindowGroup descendants.
    private func resolveFromSceneSnapshot(
        point: CGPoint,
        dockPID: pid_t
    ) -> MissionControlAXResolution {
#if DEBUG
        if let sceneSnapshotForTesting { return sceneSnapshotForTesting }
#endif
        let started = DispatchTime.now().uptimeNanoseconds
        let hardDeadline = started &+ 110_000_000
        let maximumTraversalDepth = 8
        let maximumVisitedNodes = 96

        guard dockPID > 0 else {
            observedMissionControlRoot = nil
            return .outsideMissionControl("scene-marker-not-found-no-dock")
        }
        let dockApplication = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockApplication, 0.025)
        let directDockChildren = childAttributeElements(
            kAXChildrenAttribute,
            of: dockApplication
        )
        let missionControlRoots = directDockChildren.filter {
            normalizedAXToken(stringAttribute("AXIdentifier", of: $0) ?? "") == "mc"
        }
        let dockRootIdentifiers: Set<String> = Set(directDockChildren.compactMap {
            let identifier = stringAttribute("AXIdentifier", of: $0) ?? ""
            guard !identifier.isEmpty else { return nil }
            return sanitizedDiagnosticToken(identifier)
        }.prefix(12))
        guard missionControlRoots.count == 1,
              let missionControlRoot = missionControlRoots.first else {
            observedMissionControlRoot = nil
            return .outsideMissionControl(sceneDiagnosticCode(
                prefix: missionControlRoots.isEmpty
                    ? "scene-marker-not-found-mc-root"
                    : "scene-marker-not-found-ambiguous-mc-root",
                visitedCount: directDockChildren.count,
                visitedByProvider: ["dock-direct": directDockChildren.count],
                roles: [],
                hints: dockRootIdentifiers
            ))
        }

        let rootHash = CFHash(missionControlRoot)
        if observedMissionControlRoot?.hash != rootHash {
            observedMissionControlRoot = (rootHash, started)
        }
        guard let rootObservation = observedMissionControlRoot,
              started &- rootObservation.firstSeenNanoseconds >=
                missionControlStabilizationNanoseconds else {
            return .indeterminate("scene-mc-root-stabilizing")
        }

#if DEBUG
        runReadOnlySceneProbe(
            point: point,
            dockPID: dockPID,
            missionControlRoot: missionControlRoot,
            now: started
        )
#endif

        // Tahoe's Mission Control AX thumbnail buttons intentionally expose no
        // original-window identity. The WindowServer inventory does: while
        // Mission Control is active, the public description for each live
        // layer-zero window keeps its original CGWindowID / owner PID and uses
        // the transformed thumbnail rectangle as kCGWindowBounds. This is the
        // same identity + frame model used by WINS' scene detector, without
        // relying on titles or guessing from the anonymous AX button order.
        //
        // Keep the concrete `mc` AX root above as the session gate. That makes
        // a transient desktop/window animation incapable of becoming a
        // destructive Mission Control target. Only fall back to the legacy AX
        // subtree resolver if WindowServer fails to return an inventory at all.
        if let windowServerResolution = resolveFromWindowServerSnapshot(
            point: point,
            dockPID: dockPID
        ) {
            return windowServerResolution
        }

        var hitsByWindowNumber: [CGWindowID: MissionControlAXHit] = [:]
        var sawConcreteMarker = false
        var sawUnresolvedMarker = false
        var visitedCount = 0
        var traversalWasTruncated = false
        var visitedByProvider: [String: Int] = [:]
        var observedRoles = Set<String>()
        var observedMarkerHints = Set<String>()

        var pending: [(element: AXUIElement, depth: Int)] = [(missionControlRoot, 0)]
        var visitedHashes = Set<CFHashCode>()

        while !pending.isEmpty {
            if visitedCount >= maximumVisitedNodes ||
                DispatchTime.now().uptimeNanoseconds >= hardDeadline {
                traversalWasTruncated = true
                break
            }
            let next = pending.removeFirst()
            let hash = CFHash(next.element)
            guard visitedHashes.insert(hash).inserted else { continue }
            visitedCount += 1
            visitedByProvider["dock-mc", default: 0] += 1

            let role = stringAttribute(
                kAXRoleAttribute,
                of: next.element
            )?.lowercased() ?? ""
            let identifier = stringAttribute(
                "AXIdentifier",
                of: next.element
            )?.lowercased() ?? ""
            let subrole = stringAttribute(
                kAXSubroleAttribute,
                of: next.element
            )?.lowercased() ?? ""
            if !role.isEmpty, observedRoles.count < 10 {
                observedRoles.insert(sanitizedDiagnosticToken(role))
            }
            // Identifiers are structural metadata, not window titles/content.
            // Preserve a small sanitized inventory so a future macOS rename is
            // diagnosable without another blind broad-tree implementation.
            for hint in [identifier, subrole] where
                !hint.isEmpty && observedMarkerHints.count < 12 {
                observedMarkerHints.insert(sanitizedDiagnosticToken(hint))
            }

            if isExactExposeWindowGroup(
                role: role,
                identifier: identifier,
                subrole: subrole,
                description: ""
            ) {
                sawConcreteMarker = true
                if let frame = visibleFrame(of: next.element),
                   let resolved = exactWindow(in: next.element) {
                    let hit = MissionControlAXHit(
                        thumbnailFrame: frame,
                        window: resolved.window,
                        windowNumber: resolved.windowNumber,
                        ownerPID: resolved.ownerPID,
                        canClose: elementAttribute(
                            kAXCloseButtonAttribute,
                            of: resolved.window
                        ) != nil
                    )
                    if let existing = hitsByWindowNumber[resolved.windowNumber] {
                        if frame.width * frame.height <
                            existing.thumbnailFrame.width * existing.thumbnailFrame.height {
                            hitsByWindowNumber[resolved.windowNumber] = hit
                        }
                    } else {
                        hitsByWindowNumber[resolved.windowNumber] = hit
                    }
                } else {
                    sawUnresolvedMarker = true
                }
                continue
            }

            if next.depth < maximumTraversalDepth {
                pending.append(contentsOf: childElements(of: next.element).map {
                    ($0, next.depth + 1)
                })
            }
        }

        // Destructive actions must never use a partial scene inventory. A
        // partial snapshot cannot prove the thumbnail under the pointer after
        // Mission Control reflows.
        if traversalWasTruncated {
            return .indeterminate(sceneDiagnosticCode(
                prefix: "scene-scan-budget-exhausted",
                visitedCount: visitedCount,
                visitedByProvider: visitedByProvider,
                roles: observedRoles,
                hints: observedMarkerHints
            ))
        }
        guard sawConcreteMarker else {
            return .outsideMissionControl(sceneDiagnosticCode(
                prefix: "scene-marker-not-found",
                visitedCount: visitedCount,
                visitedByProvider: visitedByProvider,
                roles: observedRoles,
                hints: observedMarkerHints
            ))
        }

        let containingHits = hitsByWindowNumber.values.filter {
            $0.thumbnailFrame.insetBy(dx: -2, dy: -2).contains(point)
        }.sorted {
            let leftDistance = hypot(
                $0.thumbnailFrame.midX - point.x,
                $0.thumbnailFrame.midY - point.y
            )
            let rightDistance = hypot(
                $1.thumbnailFrame.midX - point.x,
                $1.thumbnailFrame.midY - point.y
            )
            return leftDistance < rightDistance
        }

        guard let nearest = containingHits.first else {
            return .missionControlWithoutExactTarget(
                sawUnresolvedMarker
                    ? "scene-unresolved-thumbnail"
                    : "scene-no-thumbnail-hit-\(hitsByWindowNumber.count)"
            )
        }
        if containingHits.count > 1 {
            let firstDistance = hypot(
                nearest.thumbnailFrame.midX - point.x,
                nearest.thumbnailFrame.midY - point.y
            )
            let second = containingHits[1]
            let secondDistance = hypot(
                second.thumbnailFrame.midX - point.x,
                second.thumbnailFrame.midY - point.y
            )
            guard abs(firstDistance - secondDistance) > 1 else {
                return .missionControlWithoutExactTarget("scene-overlap-unresolved")
            }
        }
        return .valid(nearest)
    }

    private func resolveFromWindowServerSnapshot(
        point: CGPoint,
        dockPID: pid_t
    ) -> MissionControlAXResolution? {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let descriptions = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var inspectedLayerZeroWindows = 0

        // `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)` returns
        // windows in front-to-back order. Mission Control thumbnails can
        // overlap, so the first eligible rectangle containing the pointer is
        // the only actionable target. Never skip an unresolved frontmost
        // entry and fall through to a window behind it.
        for description in descriptions {
            guard let windowNumberValue = description[
                kCGWindowNumber as String
            ] as? NSNumber,
            let ownerPIDValue = description[
                kCGWindowOwnerPID as String
            ] as? NSNumber,
            let layerValue = description[
                kCGWindowLayer as String
            ] as? NSNumber,
            layerValue.intValue == 0,
            let frame = windowFrame(
                from: description[kCGWindowBounds as String]
            ) else { continue }

            inspectedLayerZeroWindows += 1
            let windowNumber = CGWindowID(windowNumberValue.uint32Value)
            let ownerPID = pid_t(ownerPIDValue.int32Value)
            guard windowNumber > 0,
                  ownerPID > 0,
                  ownerPID != dockPID,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  frame.insetBy(dx: -2, dy: -2).contains(point) else {
                continue
            }

            // The all-window snapshot already provides the window ID and its
            // owner PID. Use that identity for AX matching without a redundant
            // description query and the extra race with window destruction.
            // Require one exact AX window under the reported owner;
            // any stale identity, PID mismatch or duplicate remains
            // non-actionable.
            guard let liveWindow = resolveExactWindow(
                processIdentifier: ownerPID,
                windowNumber: windowNumber
            ) else {
                return .missionControlWithoutExactTarget(
                    "window-server-frontmost-thumbnail-unresolved"
                )
            }
            guard isTransformedMissionControlFrame(
                frame,
                liveWindow: liveWindow
            ) else {
                return .missionControlWithoutExactTarget(
                    "window-server-frontmost-thumbnail-not-transformed"
                )
            }

            return .valid(MissionControlAXHit(
                thumbnailFrame: frame,
                window: liveWindow,
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                canClose: elementAttribute(
                    kAXCloseButtonAttribute,
                    of: liveWindow
                ) != nil
            ))
        }

        return .missionControlWithoutExactTarget(
            "window-server-no-thumbnail-hit-\(inspectedLayerZeroWindows)"
        )
    }

    private func isTransformedMissionControlFrame(
        _ windowServerFrame: CGRect,
        liveWindow: AXUIElement
    ) -> Bool {
        guard let liveFrame = frame(of: liveWindow) else { return false }
        let sizeDelta = max(
            abs(windowServerFrame.width - liveFrame.width),
            abs(windowServerFrame.height - liveFrame.height)
        )
        let originDelta = max(
            abs(windowServerFrame.minX - liveFrame.minX),
            abs(windowServerFrame.minY - liveFrame.minY)
        )

        // A lingering/transitioning `mc` root must never turn an ordinary
        // desktop window into a Mission Control action target. Window shadows
        // and AppKit/AX rounding can differ by a handful of points, so require
        // a material transform before accepting the WindowServer rectangle.
        return sizeDelta >= 12 || originDelta >= 24
    }

    private func isExactExposeWindowGroup(
        role: String,
        identifier: String,
        subrole: String,
        description: String
    ) -> Bool {
        [role, identifier, subrole, description].contains { rawValue in
            rawValue
                .filter { $0.isLetter || $0.isNumber }
                .lowercased() == "axexposewindowgroup"
        }
    }

    private func sceneDiagnosticCode(
        prefix: String,
        visitedCount: Int,
        visitedByProvider: [String: Int],
        roles: Set<String>,
        hints: Set<String>
    ) -> String {
        let providers = visitedByProvider.keys.sorted().map {
            "\($0):\(visitedByProvider[$0, default: 0])"
        }.joined(separator: ",")
        let roleSummary = roles.sorted().joined(separator: ",")
        let hintSummary = hints.sorted().joined(separator: ",")
        return "\(prefix)-v\(visitedCount)-p[\(providers)]-r[\(roleSummary)]-h[\(hintSummary)]"
    }

    private func sanitizedDiagnosticToken(_ value: String) -> String {
        String(value
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            .prefix(48))
    }

    private func normalizedAXToken(_ value: String) -> String {
        value
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }

    private func directWindowNumber(of element: AXUIElement) -> CGWindowID? {
        missionControlDirectWindowNumber(of: element)
    }

    private func exactWindow(
        in group: AXUIElement
    ) -> (window: AXUIElement, windowNumber: CGWindowID, ownerPID: pid_t, windowServerFrame: CGRect?)? {
        var found = Set<CGWindowID>()
        var queue: [(AXUIElement, Int)] = [(group, 0)]
        var visited = Set<CFHashCode>()
        var visitedCount = 0
        while !queue.isEmpty, visitedCount < 24 {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }
            for name in ["AXWindowNumber", "AXWindowID"] {
                if let number = numberAttribute(name, of: element), number > 0 {
                    found.insert(CGWindowID(number))
                }
            }
            if let resolver = missionControlPrivateWindowNumberResolver {
                var number: CGWindowID = 0
                if resolver(element, &number) == .success, number > 0 {
                    found.insert(number)
                }
            }
            if depth < 1 {
                queue.append(contentsOf: childElements(of: element).map {
                    ($0, depth + 1)
                })
            }
        }

        let resolved = found.compactMap(resolveExactWindow)
        guard resolved.count == 1 else { return nil }
        return resolved[0]
    }

    private func resolveExactWindow(
        _ windowNumber: CGWindowID
    ) -> (window: AXUIElement, windowNumber: CGWindowID, ownerPID: pid_t, windowServerFrame: CGRect?)? {
        guard let descriptions = WindowServerWindowDescriptions.copy(for: [windowNumber]),
              descriptions.count == 1,
              let describedNumber = descriptions[0][kCGWindowNumber as String] as? NSNumber,
              CGWindowID(describedNumber.uint32Value) == windowNumber,
              let ownerNumber = descriptions[0][kCGWindowOwnerPID as String] as? NSNumber else {
            return nil
        }
        let ownerPID = pid_t(ownerNumber.int32Value)
        guard ownerPID > 0 else { return nil }
        // Tahoe commonly omits the public AXWindowNumber attribute while the
        // exact WindowServer identity is still available through
        // _AXUIElementGetWindow. Reuse the same fail-closed identity resolver
        // used by the diagnostic proof instead of treating that exact window
        // as unresolved. Keep the AX IPC bounded; a target outside this cap is
        // intentionally non-actionable rather than guessed.
        guard let liveWindow = resolveExactWindow(
            processIdentifier: ownerPID,
            windowNumber: windowNumber
        ) else { return nil }
        let windowServerFrame = windowFrame(
            from: descriptions[0][kCGWindowBounds as String]
        )
        return (liveWindow, windowNumber, ownerPID, windowServerFrame)
    }

    private func resolveExactWindow(
        processIdentifier: pid_t,
        windowNumber: CGWindowID
    ) -> AXUIElement? {
        guard processIdentifier > 0, windowNumber > 0 else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let matches = childAttributeElements(
            kAXWindowsAttribute,
            of: application
        ).prefix(64).filter {
            directWindowNumber(of: $0) == windowNumber
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func windowFrame(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: NSNumber],
              let x = bounds["X"],
              let y = bounds["Y"],
              let width = bounds["Width"],
              let height = bounds["Height"] else { return nil }
        let frame = CGRect(
            x: x.doubleValue,
            y: y.doubleValue,
            width: width.doubleValue,
            height: height.doubleValue
        )
        guard frame.width >= 24,
              frame.height >= 24,
              !frame.isNull,
              !frame.isInfinite else { return nil }
        return frame
    }

    private func visibleFrame(of element: AXUIElement) -> CGRect? {
        if boolAttribute("AXVisible", of: element) == false { return nil }
        guard let frame = frame(of: element),
              frame.width >= 24,
              frame.height >= 24,
              !frame.isNull,
              !frame.isInfinite,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else {
            return nil
        }
        return frame
    }

    private func exactPID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func numberAttribute(_ name: String, of element: AXUIElement) -> UInt32? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.uint32Value
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        childAttributeElements(kAXChildrenAttribute, of: element)
    }

    private func childAttributeElements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

#if DEBUG
    /// Samples the live Mission Control accessibility scene without feeding
    /// any result into production target resolution. It intentionally cannot
    /// move, close, activate, press, set an AX attribute, or post an event.
    private func runReadOnlySceneProbe(
        point: CGPoint,
        dockPID: pid_t,
        missionControlRoot: AXUIElement,
        now: UInt64
    ) {
        guard Bundle.main.bundleIdentifier == "com.workview.SuperIsland.WE1Debug",
              sceneProbeRemainingSamples > 0,
              now &- sceneProbeLastSampleNanoseconds >= 300_000_000 else {
            return
        }
        sceneProbeLastSampleNanoseconds = now
        sceneProbeRemainingSamples -= 1

        struct ProbeNode {
            let provider: String
            let element: AXUIElement
            let depth: Int
        }
        struct ProbeMapping: Hashable {
            let windowNumber: CGWindowID
            let axPID: pid_t
            let cgsPID: pid_t
            let containsPointer: Bool
        }

        let probeStarted = DispatchTime.now().uptimeNanoseconds
        let missionControlWindowContainers = sceneProbeMCWindowsContainers(
            in: missionControlRoot,
            deadline: probeStarted &+ 20_000_000
        )
        let deadline = probeStarted &+ (
            missionControlWindowContainers.isEmpty ? 60_000_000 : 40_000_000
        )
        let maximumVisitedNodes = missionControlWindowContainers.isEmpty ? 96 : 64
        let maximumTraversalDepth = missionControlWindowContainers.isEmpty ? 6 : 4
        var queue: [ProbeNode]
        if missionControlWindowContainers.isEmpty {
            queue = [
                ProbeNode(
                    provider: "dock-mc-fallback",
                    element: missionControlRoot,
                    depth: 0
                )
            ]
        } else {
            queue = missionControlWindowContainers.map {
                ProbeNode(provider: "dock-mcwindows", element: $0, depth: 0)
            }
        }
        var queueIndex = 0
        var cachedRootPIDs = Set<pid_t>()

        // Once Tahoe's concrete `mcwindows` container is present, do not spend
        // the probe budget walking unrelated Dock, WindowManager, or Settings
        // trees. Those broad providers are retained only as a diagnostic
        // fallback when the structural path itself is missing.
        if missionControlWindowContainers.isEmpty {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.020)
            var hitElement: AXUIElement?
            if AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &hitElement
            ) == .success, let hitElement {
                var current: AXUIElement? = hitElement
                var parentHashes = Set<CFHashCode>()
                for depth in 0..<4 {
                    guard let element = current else { break }
                    let hash = CFHash(element)
                    guard parentHashes.insert(hash).inserted else { break }
                    queue.append(ProbeNode(
                        provider: "system-hit-parent",
                        element: element,
                        depth: depth
                    ))
                    current = elementAttribute(kAXParentAttribute, of: element)
                }
            }

            var providerPIDs: [(String, pid_t)] = [("dock-app", dockPID)]
            if let windowManagerPID = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.WindowManager"
            ).first?.processIdentifier,
               windowManagerPID > 0,
               windowManagerPID != dockPID {
                providerPIDs.insert(("window-manager", windowManagerPID), at: 0)
            }
            for (provider, pid) in providerPIDs where pid > 0 {
                let root: AXUIElement
                if let cached = sceneProbeCachedApplicationRoots[pid] {
                    root = cached
                } else {
                    root = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(root, 0.020)
                    sceneProbeCachedApplicationRoots[pid] = root
                }
                cachedRootPIDs.insert(pid)
                queue.append(ProbeNode(provider: provider, element: root, depth: 0))
            }
        }
        sceneProbeCachedApplicationRoots = sceneProbeCachedApplicationRoots.filter {
            cachedRootPIDs.contains($0.key)
        }

        var visited = Set<CFHashCode>()
        var visitedByProvider: [String: Int] = [:]
        var childReadErrors = 0
        var exposeGroupCount = 0
        var exposeGroupsContainingPointer = 0
        var directWindowNumberCount = 0
        var publicDescriptionCount = 0
        var mappings = Set<ProbeMapping>()
        var structuralHints = Set<String>()
        var mcWindowCandidateCount = 0
        var mcWindowCandidatesContainingPointer = 0
        var mcWindowAmbiguousIdentityCount = 0
        var pointerProxyGeometries: [SceneProbeProxyGeometry] = []
        var pointerProxyGeometryKeys = Set<String>()
        var truncated = false

        while queueIndex < queue.count {
            if visited.count >= maximumVisitedNodes ||
                DispatchTime.now().uptimeNanoseconds >= deadline {
                truncated = true
                break
            }
            let next = queue[queueIndex]
            queueIndex += 1
            let hash = CFHash(next.element)
            guard visited.insert(hash).inserted else { continue }
            visitedByProvider[next.provider, default: 0] += 1

            let role = stringAttribute(kAXRoleAttribute, of: next.element) ?? ""
            let identifier = stringAttribute("AXIdentifier", of: next.element) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, of: next.element) ?? ""
            if structuralHints.count < 16 {
                for raw in [role, identifier, subrole] where !raw.isEmpty {
                    structuralHints.insert(sanitizedDiagnosticToken(raw))
                }
            }

            if isExactExposeWindowGroup(
                role: role.lowercased(),
                identifier: identifier.lowercased(),
                subrole: subrole.lowercased(),
                description: ""
            ) {
                exposeGroupCount += 1
                let frame = visibleFrame(of: next.element)
                let containsPointer = frame?.insetBy(dx: -2, dy: -2).contains(point) == true
                if containsPointer {
                    exposeGroupsContainingPointer += 1
                }
                for windowNumber in sceneProbeWindowNumbers(in: next.element) {
                    directWindowNumberCount += 1
                    let descriptions = WindowServerWindowDescriptions.copy(for: [windowNumber])
                    if descriptions?.count == 1 {
                        publicDescriptionCount += 1
                    }
                    let axPID = exactPID(of: next.element) ?? 0
                    let cgsPID = privateCGSOwnerPID(for: windowNumber) ?? 0
                    mappings.insert(ProbeMapping(
                        windowNumber: windowNumber,
                        axPID: axPID,
                        cgsPID: cgsPID,
                        containsPointer: containsPointer
                    ))
                }
            }

            if next.provider == "dock-mcwindows", next.depth > 0 {
                mcWindowCandidateCount += 1
                let frame = visibleFrame(of: next.element)
                let containsPointer = frame?.insetBy(dx: -2, dy: -2).contains(point) == true
                if containsPointer {
                    mcWindowCandidatesContainingPointer += 1
                    if let frame,
                       pointerProxyGeometries.count < 8 {
                        let windowNumbers = sceneProbeWindowNumbers(
                            in: next.element
                        ).sorted()
                        let geometryKey = [
                            sceneProbeRectSummary(frame),
                            windowNumbers.map(String.init).joined(separator: ".")
                        ].joined(separator: "#")
                        if pointerProxyGeometryKeys.insert(geometryKey).inserted {
                            pointerProxyGeometries.append(SceneProbeProxyGeometry(
                                depth: next.depth,
                                role: sanitizedDiagnosticToken(role),
                                identifier: sanitizedDiagnosticToken(identifier),
                                frame: frame,
                                windowNumbers: windowNumbers
                            ))
                        }
                    }
                }
                let windowNumbers = sceneProbeWindowNumbers(in: next.element)
                if windowNumbers.count == 1, let windowNumber = windowNumbers.first {
                    directWindowNumberCount += 1
                    let descriptions = WindowServerWindowDescriptions.copy(for: [windowNumber])
                    if descriptions?.count == 1 {
                        publicDescriptionCount += 1
                    }
                    mappings.insert(ProbeMapping(
                        windowNumber: windowNumber,
                        axPID: exactPID(of: next.element) ?? 0,
                        cgsPID: privateCGSOwnerPID(for: windowNumber) ?? 0,
                        containsPointer: containsPointer
                    ))
                } else if windowNumbers.count > 1 {
                    mcWindowAmbiguousIdentityCount += 1
                }
            }

            guard next.depth < maximumTraversalDepth else { continue }
            var childValue: CFTypeRef?
            let childResult = AXUIElementCopyAttributeValue(
                next.element,
                kAXChildrenAttribute as CFString,
                &childValue
            )
            if childResult == .success,
               let children = childValue as? [AXUIElement] {
                queue.append(contentsOf: children.map {
                    ProbeNode(
                        provider: next.provider,
                        element: $0,
                        depth: next.depth + 1
                    )
                })
            } else if childResult != .noValue && childResult != .attributeUnsupported {
                childReadErrors += 1
            }
        }

        let providerSummary = visitedByProvider.keys.sorted().map {
            "\($0):\(visitedByProvider[$0, default: 0])"
        }.joined(separator: ",")
        let mappingSummary = mappings.sorted {
            if $0.containsPointer != $1.containsPointer {
                return $0.containsPointer && !$1.containsPointer
            }
            return $0.windowNumber < $1.windowNumber
        }.prefix(12).map {
            "\($0.windowNumber):\($0.axPID):\($0.cgsPID):\($0.containsPointer ? 1 : 0)"
        }.joined(separator: ",")
        let privateInventorySummary: String
        let now = DispatchTime.now().uptimeNanoseconds
        if sceneProbePrivateInventoryRemainingSamples > 0,
           mcWindowCandidatesContainingPointer > 0,
           now &- sceneProbeLastPrivateInventoryNanoseconds >= 600_000_000 {
            sceneProbePrivateInventoryRemainingSamples -= 1
            sceneProbeLastPrivateInventoryNanoseconds = now
            privateInventorySummary = sceneProbeSkyLightInventory(
                point: point,
                dockPID: dockPID,
                proxyWindowNumbers: Set(mappings.map(\.windowNumber)),
                pointerProxyGeometries: pointerProxyGeometries
            )
        } else {
            privateInventorySummary = "not-sampled"
        }
        let hintSummary = structuralHints.sorted().joined(separator: ",")
        let privateAPIState = Self.privateCGSOwnerResolvers == nil ? "missing" : "ready"
        let fingerprint = [
            providerSummary,
            String(exposeGroupCount),
            String(exposeGroupsContainingPointer),
            String(directWindowNumberCount),
            String(publicDescriptionCount),
            mappingSummary,
            String(truncated),
            String(childReadErrors),
            String(missionControlWindowContainers.count),
            String(mcWindowCandidateCount),
            String(mcWindowCandidatesContainingPointer),
            String(mcWindowAmbiguousIdentityCount),
            privateAPIState,
            privateInventorySummary,
            hintSummary
        ].joined(separator: "|")
        guard fingerprint != sceneProbeLastFingerprint else { return }
        sceneProbeLastFingerprint = fingerprint
        sceneProbeLogger.notice(
            "probe providers=\(providerSummary, privacy: .public) visited=\(visited.count, privacy: .public) mcwindows=\(missionControlWindowContainers.count, privacy: .public) mcCandidates=\(mcWindowCandidateCount, privacy: .public) pointCandidates=\(mcWindowCandidatesContainingPointer, privacy: .public) ambiguous=\(mcWindowAmbiguousIdentityCount, privacy: .public) expose=\(exposeGroupCount, privacy: .public) pointExpose=\(exposeGroupsContainingPointer, privacy: .public) directWID=\(directWindowNumberCount, privacy: .public) described=\(publicDescriptionCount, privacy: .public) mappings=\(mappingSummary, privacy: .public) privateInventory=\(privateInventorySummary, privacy: .public) childErrors=\(childReadErrors, privacy: .public) truncated=\(truncated, privacy: .public) privateAPI=\(privateAPIState, privacy: .public) hints=\(hintSummary, privacy: .public)"
        )
    }

    private func sceneProbeMCWindowsContainers(
        in missionControlRoot: AXUIElement,
        deadline: UInt64
    ) -> [AXUIElement] {
        var queue: [(element: AXUIElement, depth: Int)] = [(missionControlRoot, 0)]
        var queueIndex = 0
        var visited = Set<CFHashCode>()
        var containers: [AXUIElement] = []

        while queueIndex < queue.count,
              visited.count < 48,
              DispatchTime.now().uptimeNanoseconds < deadline {
            let next = queue[queueIndex]
            queueIndex += 1
            let hash = CFHash(next.element)
            guard visited.insert(hash).inserted else { continue }

            let identifier = normalizedAXToken(
                stringAttribute("AXIdentifier", of: next.element) ?? ""
            )
            if identifier == "mcwindows" {
                containers.append(next.element)
                continue
            }

            guard next.depth < 4 else { continue }
            queue.append(contentsOf: childElements(of: next.element).map {
                ($0, next.depth + 1)
            })
        }
        return containers
    }

    private func sceneProbeWindowNumbers(in group: AXUIElement) -> Set<CGWindowID> {
        var numbers = Set<CGWindowID>()
        var pending: [(AXUIElement, Int)] = [(group, 0)]
        var visited = Set<CFHashCode>()
        while !pending.isEmpty, visited.count < 16 {
            let (element, depth) = pending.removeFirst()
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }
            if let windowNumber = directWindowNumber(of: element) {
                numbers.insert(windowNumber)
            }
            if depth < 2 {
                pending.append(contentsOf: childElements(of: element).map {
                    ($0, depth + 1)
                })
            }
        }
        return numbers
    }

    /// Mirrors the two read-only WindowServer inventory calls present in the
    /// WINS binary. The result is diagnostic only: it never participates in
    /// target resolution and deliberately records IDs/counts rather than
    /// window titles, contents, or screenshots.
    private func sceneProbeSkyLightInventory(
        point: CGPoint,
        dockPID: pid_t,
        proxyWindowNumbers: Set<CGWindowID>,
        pointerProxyGeometries: [SceneProbeProxyGeometry]
    ) -> String {
        guard let resolvers = Self.privateCGSOwnerResolvers else {
            return "symbols-missing"
        }
        let connectionID = resolvers.mainConnectionID()
        guard connectionID != 0,
              let managedDisplays = resolvers.copyManagedDisplaySpaces(
                  connectionID
              )?.takeRetainedValue() else {
            return "spaces-unavailable"
        }

        let spaceIDs = sceneProbeManagedSpaceIDs(in: managedDisplays)
        guard !spaceIDs.isEmpty else { return "spaces-empty" }
        let spaceArray = spaceIDs.map(NSNumber.init(value:)) as CFArray

        func copyWindowIDs(options: UInt32) -> [CGWindowID]? {
            var setTags: UInt64 = 0
            var clearTags: UInt64 = 0
            guard let copied = resolvers.copyWindowsWithOptionsAndTags(
                connectionID,
                0,
                spaceArray,
                options,
                &setTags,
                &clearTags
            )?.takeRetainedValue() as? [NSNumber] else {
                return nil
            }
            return copied.map { CGWindowID($0.uint32Value) }.filter { $0 > 0 }
        }

        guard let option7 = copyWindowIDs(options: 7),
              let option2 = copyWindowIDs(options: 2) else {
            return "windows-unavailable-spaces=\(spaceIDs.count)"
        }
        let option7Set = Set(option7)
        let option2Set = Set(option2)
        let inventoryUnion = option7Set.union(option2Set)
        let sortedInventory = inventoryUnion.sorted()
        let cappedInventory = Array(sortedInventory.prefix(512))
        let inventoryTruncated = cappedInventory.count < sortedInventory.count

        var inventoryOwnerByWindow: [CGWindowID: pid_t] = [:]
        if let descriptions = WindowServerWindowDescriptions.copy(
            for: cappedInventory
        ) {
            for description in descriptions {
                guard let windowNumber = description[
                    kCGWindowNumber as String
                ] as? NSNumber,
                let ownerPID = description[
                    kCGWindowOwnerPID as String
                ] as? NSNumber else { continue }
                inventoryOwnerByWindow[CGWindowID(windowNumber.uint32Value)] =
                    pid_t(ownerPID.int32Value)
            }
        }

        let publicPointerCandidates = sceneProbePublicPointerWindows(
            at: point,
            excluding: [dockPID, ProcessInfo.processInfo.processIdentifier]
        )
        let bindingSummary = publicPointerCandidates.prefix(3).map { candidate in
            let axWindows = sceneProbeAXWindows(ownerPID: candidate.ownerPID)
            let axWindowIDs = Set(axWindows.map(\.windowNumber))
            let exactAXFrame = axWindows.first {
                $0.windowNumber == candidate.windowNumber
            }?.frame
            let describedOwnerIDs = Set(inventoryOwnerByWindow.compactMap {
                $0.value == candidate.ownerPID ? $0.key : nil
            })
            let axInInventory = axWindowIDs.intersection(inventoryUnion)
            let sameWindowID = axWindowIDs.contains(candidate.windowNumber)
            let candidateSpaces = sceneProbeSpaceIDs(
                for: candidate.windowNumber,
                connectionID: connectionID,
                resolver: resolvers.copySpacesForWindows
            )
            let geometry = pointerProxyGeometries.prefix(4).map { proxy in
                let referenceFrame = exactAXFrame ?? candidate.frame
                return [
                    "d\(proxy.depth)",
                    "r\(proxy.role)",
                    "i\(proxy.identifier)",
                    "pw\(sceneProbeIDSummary(Set(proxy.windowNumbers)))",
                    "pf\(sceneProbeRectSummary(proxy.frame))",
                    "ar\(sceneProbeAspectDeltaPermille(proxy.frame, referenceFrame))",
                    "sr\(sceneProbeScaleResidualPermille(proxy.frame, referenceFrame))"
                ].joined(separator: ":")
            }.joined(separator: "+")
            return [
                "w\(candidate.windowNumber)",
                "p\(candidate.ownerPID)",
                "o7\(option7Set.contains(candidate.windowNumber) ? 1 : 0)",
                "o2\(option2Set.contains(candidate.windowNumber) ? 1 : 0)",
                "same\(sameWindowID ? 1 : 0)",
                "ax\(sceneProbeIDSummary(axWindowIDs))",
                "axInv\(sceneProbeIDSummary(axInInventory))",
                "ownerInv\(sceneProbeIDSummary(describedOwnerIDs))",
                "cg\(sceneProbeRectSummary(candidate.frame))",
                "axf\(sceneProbeOptionalRectSummary(exactAXFrame))",
                "sp\(sceneProbeUInt64Summary(candidateSpaces))",
                "geo[\(geometry)]"
            ].joined(separator: ":")
        }.joined(separator: ",")

        let proxySpaceSummary = pointerProxyGeometries.prefix(4).map { proxy in
            let spaces = Set(proxy.windowNumbers.flatMap {
                sceneProbeSpaceIDs(
                    for: $0,
                    connectionID: connectionID,
                    resolver: resolvers.copySpacesForWindows
                )
            })
            return [
                "d\(proxy.depth)",
                "w\(sceneProbeIDSummary(Set(proxy.windowNumbers)))",
                "f\(sceneProbeRectSummary(proxy.frame))",
                "sp\(sceneProbeUInt64Summary(spaces))"
            ].joined(separator: ":")
        }.joined(separator: ",")

        return [
            "spaces\(spaceIDs.count)",
            "o7\(option7Set.count)",
            "o2\(option2Set.count)",
            "both\(option7Set.intersection(option2Set).count)",
            "proxy7\(proxyWindowNumbers.intersection(option7Set).count)",
            "proxy2\(proxyWindowNumbers.intersection(option2Set).count)",
            "described\(inventoryOwnerByWindow.count)",
            "pointer\(publicPointerCandidates.count)",
            "truncated\(inventoryTruncated ? 1 : 0)",
            "proxyGeo[\(proxySpaceSummary)]",
            "bind[\(bindingSummary)]"
        ].joined(separator: ";")
    }

    private func sceneProbeManagedSpaceIDs(in managedDisplays: CFArray) -> [UInt64] {
        let displayArray = managedDisplays as NSArray
        var identifiers = Set<UInt64>()
        for case let display as NSDictionary in displayArray {
            guard let spaces = display["Spaces"] as? NSArray else { continue }
            for case let space as NSDictionary in spaces {
                for key in ["ManagedSpaceID", "id64", "id"] {
                    if let number = space[key] as? NSNumber,
                       number.uint64Value > 0 {
                        identifiers.insert(number.uint64Value)
                        break
                    }
                }
            }
        }
        return identifiers.sorted()
    }

    private func sceneProbePublicPointerWindows(
        at point: CGPoint,
        excluding excludedPIDs: Set<pid_t>
    ) -> [SceneProbePublicWindow] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let descriptions = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var results: [SceneProbePublicWindow] = []
        var seen = Set<CGWindowID>()
        for description in descriptions {
            guard let layer = description[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let windowNumber = description[
                      kCGWindowNumber as String
                  ] as? NSNumber,
                  let ownerPID = description[
                      kCGWindowOwnerPID as String
                  ] as? NSNumber,
                  let frame = windowFrame(
                      from: description[kCGWindowBounds as String]
                  ),
                  frame.insetBy(dx: -2, dy: -2).contains(point) else {
                continue
            }
            let windowID = CGWindowID(windowNumber.uint32Value)
            let pid = pid_t(ownerPID.int32Value)
            guard windowID > 0,
                  pid > 0,
                  !excludedPIDs.contains(pid),
                  seen.insert(windowID).inserted else { continue }
            results.append(SceneProbePublicWindow(
                windowNumber: windowID,
                ownerPID: pid,
                frame: frame
            ))
        }
        return results
    }

    private func sceneProbeAXWindows(ownerPID: pid_t) -> [SceneProbeAXWindow] {
        guard ownerPID > 0 else { return [] }
        let application = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.025)
        let windows = childAttributeElements(kAXWindowsAttribute, of: application)
        return windows.prefix(24).compactMap { window in
            guard let windowNumber = directWindowNumber(of: window) else {
                return nil
            }
            return SceneProbeAXWindow(
                windowNumber: windowNumber,
                frame: frame(of: window)
            )
        }
    }

    private func sceneProbeSpaceIDs(
        for windowNumber: CGWindowID,
        connectionID: UInt32,
        resolver: MissionControlCGSCopySpacesForWindows
    ) -> Set<UInt64> {
        guard windowNumber > 0 else { return [] }
        let windows = [NSNumber(value: windowNumber)] as CFArray
        guard let copied = resolver(
            connectionID,
            7,
            windows
        )?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return Set(copied.map(\.uint64Value).filter { $0 > 0 })
    }

    private func sceneProbeRectSummary(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height].map {
            String(Int($0.rounded()))
        }.joined(separator: ".")
    }

    private func sceneProbeOptionalRectSummary(_ frame: CGRect?) -> String {
        frame.map(sceneProbeRectSummary) ?? "none"
    }

    private func sceneProbeAspectDeltaPermille(
        _ left: CGRect,
        _ right: CGRect
    ) -> Int {
        guard left.height > 0,
              right.height > 0,
              right.width > 0 else { return -1 }
        let leftAspect = left.width / left.height
        let rightAspect = right.width / right.height
        return Int((abs(leftAspect - rightAspect) / rightAspect * 1_000).rounded())
    }

    private func sceneProbeScaleResidualPermille(
        _ thumbnail: CGRect,
        _ source: CGRect
    ) -> Int {
        guard source.width > 0,
              source.height > 0 else { return -1 }
        let scaleX = thumbnail.width / source.width
        let scaleY = thumbnail.height / source.height
        let denominator = max(scaleX, scaleY, 0.000_001)
        return Int((abs(scaleX - scaleY) / denominator * 1_000).rounded())
    }

    private func sceneProbeUInt64Summary(_ identifiers: Set<UInt64>) -> String {
        let sorted = identifiers.sorted()
        let prefix = sorted.prefix(4).map(String.init).joined(separator: ".")
        return "\(sorted.count){\(prefix)\(sorted.count > 4 ? ".more" : "")}"
    }

    private func sceneProbeIDSummary(_ identifiers: Set<CGWindowID>) -> String {
        let sorted = identifiers.sorted()
        let prefix = sorted.prefix(8).map(String.init).joined(separator: ".")
        return "\(sorted.count){\(prefix)\(sorted.count > 8 ? ".more" : "")}"
    }

    private func privateCGSOwnerPID(for windowNumber: CGWindowID) -> pid_t? {
        guard let resolvers = Self.privateCGSOwnerResolvers else { return nil }
        let connectionID = resolvers.mainConnectionID()
        guard connectionID != 0 else { return nil }
        var ownerConnection: UInt32 = 0
        guard resolvers.getWindowOwner(
            connectionID,
            windowNumber,
            &ownerConnection
        ) == 0,
        ownerConnection != 0 else { return nil }
        var ownerPID: pid_t = 0
        guard resolvers.connectionGetPID(ownerConnection, &ownerPID) == 0,
              ownerPID > 0 else { return nil }
        return ownerPID
    }
#endif
}

/// Adds a close affordance to the exact window thumbnail currently under the
/// pointer in Mission Control or App Expose.
///
/// Mission Control session state belongs to the Dock accessibility hierarchy,
/// while the transformed thumbnails keep their original WindowServer identity.
/// Before presenting an action we therefore require a concrete Dock `mc` root,
/// one material WindowServer transform under the pointer, and a unique
/// CGWindowID / owner PID resolving to one live application AX window. If any
/// signal is missing we show nothing rather than risk closing another window.
@MainActor
final class MissionControlInteractionMonitor {
    enum TargetedActionResult {
        case noTarget
        case completed(String)
        case failed(String)
    }

    private struct Target {
        let application: NSRunningApplication
        let applicationIdentity: WindowThumbnailApplicationIdentity
        let applicationName: String
        let window: AXUIElement
        let windowNumber: CGWindowID
        let thumbnailFrame: CGRect
        let canClose: Bool
    }

    private struct ActionTarget {
        let target: Target
    }

    private enum KeyboardTargetAction: Equatable {
        case closeWindow
        case quitApplication

        var preferenceAction: WindowQuickAction {
            switch self {
            case .closeWindow: .closeWindow
            case .quitApplication: .quitApp
            }
        }
    }

    private struct MonitoredKeyDown: Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
        let timestamp: TimeInterval

        func hasSameChord(as other: MonitoredKeyDown) -> Bool {
            keyCode == other.keyCode && modifiers == other.modifiers
        }
    }

    private struct PendingKeyboardTarget {
        let action: KeyboardTargetAction
        let target: Target
    }

    private enum TargetResolution {
        case absent
        case valid(ActionTarget)
        case stale
    }

    private let preferences = WindowEnhancementPreferences.shared
    private let closeInteractionState = MissionControlCloseInteractionState()
    private lazy var closePanel = MissionControlClosePanel(
        interactionState: closeInteractionState
    )
    private let axResolver = MissionControlAXResolver()
    private let mouseIngress = MissionControlMouseIngress()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland",
        category: "MissionControlPro"
    )
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseEventTap: MissionControlMouseEventTap?
    private var inspectionWorkItem: DispatchWorkItem?
    private var inspectionGeneration: UInt64 = 0
    private var inspectionInFlightGeneration: UInt64?
    private var inspectionInFlight: Bool { inspectionInFlightGeneration != nil }
    private var inspectionPending = false
    private var rootRecovery = MissionControlRootRecovery()
    private var rootRecoveryWorkItem: DispatchWorkItem?
    private var lastInspectionStartedNanoseconds: UInt64 = 0
    private var lastInspectionFinishedNanoseconds: UInt64 = 0
    private var consecutiveSlowInspections = 0
    private var inspectionCircuitOpenUntil: ContinuousClock.Instant?
    private var lastResolutionDiagnosticCode: String?
    private var currentTarget: Target?
    private var currentTargetResolvedNanoseconds: UInt64 = 0
    private var closeValidationGeneration: UInt64 = 0
    private var pendingKeyboardTarget: PendingKeyboardTarget?
    private var pendingKeyboardTargetExpiration: DispatchWorkItem?
    private var pendingKeyboardTargetGeneration: UInt64 = 0
    private var monitorGeneration: UInt64 = 0
    private var lastAcceptedKeyDown: MonitoredKeyDown?
    private var dockPID: pid_t?
    private var activeSpaceObserver: NSObjectProtocol?
    private var exposeObservers: [NSObjectProtocol] = []
    private var missionControlHierarchyObserved = false
    private var lastMissionControlEvidenceNanoseconds: UInt64 = 0
    private var missionControlSessionValidationWorkItem: DispatchWorkItem?
    private var postActionInspectionWorkItems: [DispatchWorkItem] = []
#if DEBUG
    private var canInspectSceneForTesting: Bool?
#endif

    func beginZilanSuppression(requestID: String) -> Bool {
        guard closeInteractionState.beginZilanSuppression(requestID: requestID) else { return false }
        clearMissionControlObservation(reason: "suppression")
        return true
    }

    func endZilanSuppression(requestID: String) {
        closeInteractionState.endZilanSuppression(requestID: requestID)
    }

    func start() {
        updateEnabledState()
    }

    func stop() {
        removeMonitors()
        clearTarget(clearPendingKeyboardTarget: true)
        clearMissionControlObservation()
    }

    func updateEnabledState() {
        guard preferences.isEnabled,
              preferences.missionControlEnabled,
              (preferences.isActionEnabled(.closeWindow) ||
                preferences.isActionEnabled(.quitApp)),
              AXIsProcessTrusted() else {
            removeMonitors()
            clearTarget(clearPendingKeyboardTarget: true)
            return
        }
        installMonitorsIfNeeded()
    }

    func closeTargetedWindow() -> TargetedActionResult {
        guard preferences.isActionEnabled(.closeWindow) else {
            return .failed("调度中心关闭窗口已关闭")
        }
        let actionTarget: ActionTarget
        switch resolveTarget(for: .closeWindow) {
        case .absent:
            return missionControlRootIsCurrentlyPresent()
                ? .failed("请先将鼠标移入要关闭的 Mission Control 窗口")
                : .noTarget
        case .stale:
            return .failed("Mission Control 目标已变化，请重新选择")
        case let .valid(resolvedTarget):
            actionTarget = resolvedTarget
        }
        return requestValidatedClose(actionTarget)
    }

    private func requestValidatedClose(
        _ actionTarget: ActionTarget
    ) -> TargetedActionResult {
        guard revalidatedTarget(actionTarget) != nil,
              let dockPID = resolvedDockPID() else {
            clearTarget(clearPendingKeyboardTarget: true)
            return .failed("Mission Control 目标已变化，请重新选择")
        }
        closeValidationGeneration &+= 1
        let generation = closeValidationGeneration
        let expected = actionTarget.target
        logger.notice(
            "Mission Control close requested windowID=\(expected.windowNumber, privacy: .public) ownerPID=\(expected.application.processIdentifier, privacy: .public)"
        )

        // The affordance is bound to one exact PID + WindowServer ID. Hide our
        // panels, then verify that exact identity and its current transformed
        // frame instead of performing another generic center-point selection.
        closePanel.hide()
        axResolver.resolveExpectedTarget(
            windowNumber: expected.windowNumber,
            ownerPID: expected.application.processIdentifier,
            expectedThumbnailFrame: expected.thumbnailFrame,
            dockPID: dockPID
        ) { [weak self] resolution, elapsed in
            Task { @MainActor [weak self] in
                self?.finishValidatedClose(
                    resolution,
                    expected: expected,
                    generation: generation,
                    elapsedNanoseconds: elapsed
                )
            }
        }
        return .completed("正在验证 Mission Control 目标")
    }

    private func handleInterceptedCloseClick() {
        guard closePanel.triggerClose() else {
            logger.notice("Mission Control intercepted close click discarded because the control is no longer active")
            return
        }
        logger.notice("Mission Control close click intercepted")
    }

    private func finishValidatedClose(
        _ resolution: MissionControlAXResolution,
        expected: Target,
        generation: UInt64,
        elapsedNanoseconds: UInt64
    ) {
        // A reply from an exited session must not clear a new session's UI.
        guard closeValidationGeneration == generation else { return }
        guard preferences.isEnabled,
              preferences.missionControlEnabled,
              preferences.isActionEnabled(.closeWindow),
              case let .valid(hit) = resolution,
              let freshTarget = target(from: hit),
              targetsMatch(freshTarget, expected),
              isExactTargetCurrent(freshTarget) else {
            logger.notice(
                "Mission Control close rejected windowID=\(expected.windowNumber, privacy: .public) resolution=\(resolution.diagnosticCode, privacy: .public) elapsedMs=\(Double(elapsedNanoseconds) / 1_000_000, privacy: .public)"
            )
            clearTarget(clearPendingKeyboardTarget: true)
            preferences.publishFeedback("Mission Control 目标已变化，未执行关闭")
            return
        }
        guard let closeButton = elementAttribute(
            kAXCloseButtonAttribute,
            of: freshTarget.window
        ) else {
            logger.notice(
                "Mission Control close unavailable windowID=\(expected.windowNumber, privacy: .public)"
            )
            clearTarget(clearPendingKeyboardTarget: true)
            preferences.publishFeedback("当前 Mission Control 窗口没有可用的关闭按钮")
            return
        }
        let result = AXUIElementPerformAction(
            closeButton,
            kAXPressAction as CFString
        )
        guard result == .success else {
            logger.error(
                "Mission Control close AXPress failed windowID=\(expected.windowNumber, privacy: .public) error=\(result.rawValue, privacy: .public)"
            )
            preferences.publishFeedback("关闭 Mission Control 中的窗口失败")
            return
        }
        logger.notice(
            "Mission Control close AXPress succeeded windowID=\(expected.windowNumber, privacy: .public) elapsedMs=\(Double(elapsedNanoseconds) / 1_000_000, privacy: .public)"
        )
        clearTarget(clearPendingKeyboardTarget: true)
        schedulePostActionInspection()
        preferences.publishFeedback("已关闭 Mission Control 中的窗口")
    }

    func quitTargetedApplication() -> TargetedActionResult {
        guard preferences.isActionEnabled(.quitApp) else {
            return .failed("调度中心退出程序已关闭")
        }
        let actionTarget: ActionTarget
        switch resolveTarget(for: .quitApplication) {
        case .absent:
            return missionControlRootIsCurrentlyPresent()
                ? .failed("请先将鼠标移入要管理的 Mission Control 窗口")
                : .noTarget
        case .stale:
            return .failed("Mission Control 目标已变化，请重新选择")
        case let .valid(resolvedTarget):
            actionTarget = resolvedTarget
        }
        guard let target = revalidatedTarget(actionTarget) else {
            clearTarget(clearPendingKeyboardTarget: true)
            return .failed("Mission Control 目标已变化，请重新选择")
        }
        let alert = NSAlert()
        alert.messageText = "退出 \(target.applicationName)？"
        alert.informativeText = "这会退出当前 Mission Control 缩略图所属的整个 App。未保存内容是否可恢复由 \(target.applicationName) 决定。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            clearTarget(clearPendingKeyboardTarget: true)
            return .completed("已取消退出 \(target.applicationName)")
        }
        guard isApplicationIdentityCurrent(target) else {
            clearTarget(clearPendingKeyboardTarget: true)
            return .failed("Mission Control 目标 App 已变化，未执行退出")
        }
        guard target.application.terminate() else {
            return .failed("无法退出 \(target.applicationName)")
        }
        clearTarget(clearPendingKeyboardTarget: true)
        return .completed("已请求退出 \(target.applicationName)")
    }

    private func installMonitorsIfNeeded() {
        guard globalMonitor == nil,
              localMonitor == nil,
              mouseEventTap == nil else { return }
        monitorGeneration &+= 1
        lastAcceptedKeyDown = nil
        let generation = monitorGeneration
        let weakBox = MissionControlMonitorWeakBox(self)
        let mouseIngress = self.mouseIngress
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { event in
            let keyDown = Self.compactKeyDown(event)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let owner = weakBox.value,
                          owner.monitorGeneration == generation,
                          owner.globalMonitor != nil else { return }
                    owner.accept(keyDown)
                }
            }
        }
        let mouseEventTap = MissionControlMouseEventTap(
            closeInteractionState: closeInteractionState,
            motionDelivery: {
                mouseIngress.submit {
                    MainActor.assumeIsolated {
                        guard let owner = weakBox.value,
                              owner.monitorGeneration == generation,
                              owner.mouseEventTap != nil else { return }
                        owner.scheduleInspection()
                    }
                }
            },
            closeDelivery: {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let owner = weakBox.value,
                              owner.monitorGeneration == generation,
                              owner.mouseEventTap != nil else { return }
                        owner.handleInterceptedCloseClick()
                    }
                }
            }
        )
        if mouseEventTap.start() {
            self.mouseEventTap = mouseEventTap
            logger.info("Mission Control mouse event tap installed")
        } else {
            logger.error("Mission Control mouse event tap installation failed")
            preferences.publishFeedback("调度中心 Pro 无法监听鼠标，请检查辅助功能权限")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .keyDown]
        ) { event in
            let keyDown = event.type == .keyDown
                ? Self.compactKeyDown(event)
                : nil
            if let keyDown {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let owner = weakBox.value,
                              owner.monitorGeneration == generation,
                              owner.localMonitor != nil else { return }
                        owner.accept(keyDown)
                    }
                }
            } else {
                mouseIngress.submit {
                    MainActor.assumeIsolated {
                        guard let owner = weakBox.value,
                              owner.monitorGeneration == generation,
                              owner.localMonitor != nil else { return }
                        owner.scheduleInspection()
                    }
                }
            }
            return event
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitorGeneration == generation else { return }
                self.clearMissionControlObservation(reason: "space_changed")
            }
        }
        let distributedCenter = DistributedNotificationCenter.default()
        exposeObservers = [
            Notification.Name("com.apple.expose.awake"),
            Notification.Name("com.apple.expose.front.awake")
        ].map { name in
            distributedCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.monitorGeneration == generation,
                          self.canInspectScene else { return }
                    self.beginMissionControlObservation()
                }
            }
        }
    }

    private func removeMonitors() {
        monitorGeneration &+= 1
        closeValidationGeneration &+= 1
        lastAcceptedKeyDown = nil
        clearMissionControlObservation()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        mouseEventTap?.stop()
        globalMonitor = nil
        localMonitor = nil
        mouseEventTap = nil
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        let distributedCenter = DistributedNotificationCenter.default()
        exposeObservers.forEach(distributedCenter.removeObserver)
        exposeObservers.removeAll()
        inspectionWorkItem?.cancel()
        inspectionWorkItem = nil
        inspectionGeneration &+= 1
        inspectionPending = false
        lastInspectionStartedNanoseconds = 0
        lastInspectionFinishedNanoseconds = 0
        consecutiveSlowInspections = 0
        inspectionCircuitOpenUntil = nil
        lastResolutionDiagnosticCode = nil
        mouseIngress.reset()
        postActionInspectionWorkItems.forEach { $0.cancel() }
        postActionInspectionWorkItems.removeAll()
    }

    nonisolated private static func compactKeyDown(
        _ event: NSEvent
    ) -> MonitoredKeyDown {
        let relevant = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        var modifiers: UInt32 = 0
        if relevant.contains(.control) { modifiers |= UInt32(controlKey) }
        if relevant.contains(.option) { modifiers |= UInt32(optionKey) }
        if relevant.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if relevant.contains(.command) { modifiers |= UInt32(cmdKey) }
        return MonitoredKeyDown(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            timestamp: event.timestamp
        )
    }

    private func accept(_ keyDown: MonitoredKeyDown) {
        if let previous = lastAcceptedKeyDown,
           keyDown.hasSameChord(as: previous),
           abs(keyDown.timestamp - previous.timestamp) < 0.004 {
            return
        }
        lastAcceptedKeyDown = keyDown

        guard let action = keyboardTargetAction(matching: keyDown) else {
            clearTarget(clearPendingKeyboardTarget: true)
            return
        }
        guard let currentTarget else {
            clearPendingKeyboardTarget()
            return
        }
        stagePendingKeyboardTarget(action: action, target: currentTarget)
    }

    private func keyboardTargetAction(
        matching keyDown: MonitoredKeyDown
    ) -> KeyboardTargetAction? {
        guard preferences.isEnabled, preferences.missionControlEnabled else {
            return nil
        }
        for action in [KeyboardTargetAction.closeWindow, .quitApplication] {
            let preferenceAction = action.preferenceAction
            guard preferences.isActionEnabled(preferenceAction),
                  let shortcut = preferences.shortcut(
                    for: preferenceAction.shortcutID
                  ) else { continue }
            if shortcut.keyCode == keyDown.keyCode,
               shortcut.modifiers == keyDown.modifiers {
                return action
            }
        }
        return nil
    }

    private var canInspectScene: Bool {
#if DEBUG
        if let canInspectSceneForTesting { return canInspectSceneForTesting }
#endif
        return (globalMonitor != nil || localMonitor != nil) &&
            preferences.isEnabled && preferences.missionControlEnabled &&
            !closeInteractionState.isSuppressed && AXIsProcessTrusted()
    }

    private func scheduleRootRecovery() {
        guard canInspectScene, !missionControlHierarchyObserved,
              rootRecoveryWorkItem == nil, rootRecovery.inFlight == nil else { return }
        if let inspectionCircuitOpenUntil, ContinuousClock.now < inspectionCircuitOpenUntil {
            return
        }
        guard !inspectionInFlight, inspectionWorkItem == nil else {
            inspectionPending = true
            return
        }
        let generation = inspectionGeneration
        let delay = rootRecovery.delayNanoseconds(now: DispatchTime.now().uptimeNanoseconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.inspectionGeneration == generation else { return }
            self.rootRecoveryWorkItem = nil
            guard self.canInspectScene else { return }
            if self.missionControlHierarchyObserved {
                self.scheduleInspection()
                return
            }
            guard !self.inspectionInFlight, self.inspectionWorkItem == nil else {
                self.inspectionPending = true
                return
            }
            guard let dockPID = self.resolvedDockPID(),
                  let request = self.rootRecovery.begin(
                    now: DispatchTime.now().uptimeNanoseconds
                  ) else { return }
            self.axResolver.probeRootPresence(dockPID: dockPID) { [weak self] result, elapsed in
                Task { @MainActor [weak self] in
                    self?.finishRootRecovery(request, result: result, elapsedNanoseconds: elapsed)
                }
            }
        }
        rootRecoveryWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(delay)), execute: item
        )
    }

    private func finishRootRecovery(
        _ request: MissionControlRootRecovery.Request,
        result: MissionControlRootPresence,
        elapsedNanoseconds: UInt64
    ) {
        let recovered = rootRecovery.finish(
            request,
            result: result,
            now: DispatchTime.now().uptimeNanoseconds,
            elapsedNanoseconds: elapsedNanoseconds,
            canPublish: canInspectScene
        )
        let code: String
        switch result {
        case .present: code = "present"
        case .absent: code = "absent"
        case .unavailable: code = "unavailable"
        }
        WindowInteractionDiagnosticRecorder.shared.record(
            component: "mission_control", event: "root_recovery",
            metadata: [
                "result": .code(code), "recovered": .flag(recovered),
                "elapsed_ms": .integer(Int64(elapsedNanoseconds / 1_000_000))
            ]
        )
        guard canInspectScene else { return }
        if recovered {
            logger.notice("Mission Control session recovered from pointer root probe")
            markMissionControlObserved()
            inspectionPending = false
            scheduleInspection(force: true)
        } else if inspectionPending, missionControlHierarchyObserved {
            // An expose notification may have arrived while this probe was busy.
            inspectionPending = false
            scheduleInspection(force: true)
        }
        // A negative probe never rearms itself. Only another pointer event may
        // schedule the next one, so an idle desktop has no new periodic AX work.
    }

    private func scheduleInspection(force: Bool = false) {
        guard canInspectScene else {
            clearTarget()
            return
        }
        // Movement alone never starts a full AX/window scan. A bounded root-only
        // probe recovers missed expose notifications and expired sessions.
        guard MissionControlInspectionPolicy.shouldSchedule(
            force: force,
            missionControlHierarchyObserved: missionControlHierarchyObserved
        ) else {
            scheduleRootRecovery()
            return
        }
        let appKitLocation = NSEvent.mouseLocation
        if !force, closePanel.contains(appKitLocation) { return }

        let clockNow = ContinuousClock.now
        if let inspectionCircuitOpenUntil {
            guard clockNow >= inspectionCircuitOpenUntil else { return }
            self.inspectionCircuitOpenUntil = nil
            consecutiveSlowInspections = 0
        }

        if inspectionInFlight || rootRecovery.inFlight != nil {
            inspectionPending = true
            return
        }
        rootRecoveryWorkItem?.cancel()
        rootRecoveryWorkItem = nil
        guard inspectionWorkItem == nil else {
            inspectionPending = true
            return
        }

        let minimumInterval: UInt64 = 80_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let throttleAnchor = max(
            lastInspectionStartedNanoseconds,
            lastInspectionFinishedNanoseconds
        )
        let elapsed = now &- throttleAnchor
        let delayNanoseconds = force || elapsed >= minimumInterval
            ? 0
            : minimumInterval - elapsed
        let generation = inspectionGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.inspectionGeneration == generation else { return }
            self.inspectionWorkItem = nil
            self.beginInspection(generation: generation)
        }
        inspectionWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(delayNanoseconds)),
            execute: item
        )
    }

    private func beginInspection(generation: UInt64) {
        guard canInspectScene, inspectionGeneration == generation else { return }
        guard !inspectionInFlight, rootRecovery.inFlight == nil else {
            inspectionPending = true
            return
        }
        guard let quartzLocation = CGEvent(source: nil)?.location,
              let dockPID = resolvedDockPID() else {
            clearTarget()
            return
        }
        inspectionInFlightGeneration = generation
        inspectionPending = false
        lastInspectionStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
        axResolver.resolve(point: quartzLocation, dockPID: dockPID) { [weak self] resolution, elapsed in
            Task { @MainActor [weak self] in
                self?.finishInspection(
                    resolution,
                    elapsedNanoseconds: elapsed,
                    generation: generation
                )
            }
        }
    }

    private func finishInspection(
        _ resolution: MissionControlAXResolution,
        elapsedNanoseconds: UInt64,
        generation: UInt64
    ) {
        guard inspectionInFlightGeneration == generation else { return }
        inspectionInFlightGeneration = nil
        guard inspectionGeneration == generation, canInspectScene else {
            if inspectionPending {
                inspectionPending = false
                scheduleInspection()
            }
            return
        }
        lastInspectionFinishedNanoseconds = DispatchTime.now().uptimeNanoseconds

        if elapsedNanoseconds > 120_000_000 {
            consecutiveSlowInspections += 1
        } else {
            consecutiveSlowInspections = 0
        }
        if consecutiveSlowInspections >= 3 {
            inspectionCircuitOpenUntil = ContinuousClock.now.advanced(by: .seconds(60))
            inspectionPending = false
            clearTarget(clearPendingKeyboardTarget: true)
            logger.error(
                "Mission Control AX resolver paused after repeated slow queries; lastMs=\(Double(elapsedNanoseconds) / 1_000_000, privacy: .public)"
            )
            preferences.publishFeedback("调度中心 Pro 已因系统响应缓慢暂停 60 秒")
            return
        }

        if lastResolutionDiagnosticCode != resolution.diagnosticCode {
            lastResolutionDiagnosticCode = resolution.diagnosticCode
            let state: String
            switch resolution {
            case .outsideMissionControl: state = "outside"
            case .indeterminate: state = "indeterminate"
            case .missionControlWithoutExactTarget: state = "unresolved"
            case .valid: state = "exact"
            }
            // Keep the fixed reason prefix; omit AX role/hint summaries.
            let reason = resolution.diagnosticCode.components(separatedBy: "-v").first ?? "unknown"
            var metadata: [String: WindowInteractionDiagnosticValue] = [
                "state": .code(state),
                "reason": .code(WindowInteractionDiagnosticLimiter.isStateCode(reason) ? reason : "multiple_states"),
                "elapsed_ms": .integer(Int64(elapsedNanoseconds / 1_000_000))
            ]
            if case let .valid(hit) = resolution {
                metadata["pid"] = .integer(Int64(hit.ownerPID))
                metadata["windowID"] = .integer(Int64(hit.windowNumber))
                metadata["canClose"] = .flag(hit.canClose)
            }
            WindowInteractionDiagnosticRecorder.shared.record(
                component: "mission_control", event: "target_resolution", metadata: metadata
            )
            logger.notice(
                "Mission Control pointer resolution=\(resolution.diagnosticCode, privacy: .public) elapsedMs=\(Double(elapsedNanoseconds) / 1_000_000, privacy: .public)"
            )
        }

        switch resolution {
        case .outsideMissionControl:
            clearMissionControlObservation(reason: "scene_exited")
        case let .indeterminate(code):
            if code == "scene-mc-root-stabilizing" {
                // The Dock publishes `mc` before its thumbnail subtree is
                // complete. Keep a short, throttled retry alive even if the
                // pointer has already stopped moving; never busy-wait on the
                // main thread or accept a partial destructive target.
                markMissionControlObserved()
                inspectionPending = true
            }
            clearTarget()
        case .missionControlWithoutExactTarget:
            markMissionControlObserved()
            clearTarget()
        case let .valid(hit):
            markMissionControlObserved()
            guard let target = target(from: hit) else {
                clearTarget()
                break
            }
            present(target)
        }

        if inspectionPending {
            inspectionPending = false
            scheduleInspection()
        }
    }

    private func target(from hit: MissionControlAXHit) -> Target? {
        guard hit.ownerPID != ProcessInfo.processInfo.processIdentifier,
              hit.ownerPID != resolvedDockPID(),
              let application = NSRunningApplication(processIdentifier: hit.ownerPID),
              application.activationPolicy == .regular,
              !application.isTerminated,
              !preferences.isExcluded(application),
              let applicationIdentity = WindowThumbnailApplicationIdentity(
                application: application
              ) else { return nil }
        return Target(
            application: application,
            applicationIdentity: applicationIdentity,
            applicationName: application.localizedName ?? "当前 App",
            window: hit.window,
            windowNumber: hit.windowNumber,
            thumbnailFrame: hit.thumbnailFrame,
            canClose: hit.canClose
        )
    }

    private func present(_ target: Target) {
        currentTarget = target
        currentTargetResolvedNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard preferences.isActionEnabled(.closeWindow),
              target.canClose else {
            closePanel.hide()
            return
        }
        closePanel.show(
            nearAXFrame: target.thumbnailFrame,
            onClose: { [weak self] in
                guard let self else { return }
                let actionTarget = ActionTarget(
                    target: target
                )
                switch self.requestValidatedClose(actionTarget) {
                case .noTarget:
                    self.preferences.publishFeedback("Mission Control 目标已变化，请重新选择")
                case let .completed(message), let .failed(message):
                    self.preferences.publishFeedback(message)
                }
            }
        )
    }

    private func clearTarget(clearPendingKeyboardTarget: Bool = false) {
        currentTarget = nil
        currentTargetResolvedNanoseconds = 0
        closePanel.hide()
        if clearPendingKeyboardTarget {
            self.clearPendingKeyboardTarget()
        }
    }

    private func stagePendingKeyboardTarget(
        action: KeyboardTargetAction,
        target: Target
    ) {
        pendingKeyboardTargetExpiration?.cancel()
        pendingKeyboardTargetGeneration &+= 1
        let generation = pendingKeyboardTargetGeneration
        pendingKeyboardTarget = PendingKeyboardTarget(
            action: action,
            target: target
        )
        let expiration = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingKeyboardTargetGeneration == generation else { return }
            self.clearPendingKeyboardTarget()
        }
        pendingKeyboardTargetExpiration = expiration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1,
            execute: expiration
        )
    }

    private func clearPendingKeyboardTarget() {
        pendingKeyboardTargetGeneration &+= 1
        pendingKeyboardTargetExpiration?.cancel()
        pendingKeyboardTargetExpiration = nil
        pendingKeyboardTarget = nil
    }

    private func resolveTarget(
        for action: KeyboardTargetAction
    ) -> TargetResolution {
        let pending = pendingKeyboardTarget
        clearPendingKeyboardTarget()

        // The NSEvent monitor observes the physical shortcut before Carbon
        // dispatch invokes the controller. Preserve the exact thumbnail that
        // was under the pointer at that moment; Mission Control can rebuild its
        // AX hit-test surface while handling the same key event. The action is
        // still executed only after the current mc root, owner PID,
        // WindowServer ID, transformed frame and live AXWindow all agree.
        if let pending, pending.action == action {
            let actionTarget = ActionTarget(
                target: pending.target
            )
            guard let revalidated = revalidatedTarget(actionTarget) else {
                clearTarget()
                return .stale
            }
            currentTarget = revalidated
            return .valid(ActionTarget(
                target: revalidated
            ))
        }

        guard let currentTarget else {
            return missionControlHierarchyObserved ? .stale : .absent
        }
        let actionTarget = ActionTarget(
            target: currentTarget
        )
        guard revalidatedTarget(actionTarget) != nil else {
            clearTarget()
            return .stale
        }
        return .valid(actionTarget)
    }

    private func revalidatedTarget(_ actionTarget: ActionTarget) -> Target? {
        let expected = actionTarget.target
        guard missionControlHierarchyObserved,
              currentTargetResolvedNanoseconds > 0,
              let currentTarget,
              targetsMatch(currentTarget, expected),
              let pointer = CGEvent(source: nil)?.location,
              expected.thumbnailFrame.insetBy(dx: -8, dy: -8).contains(pointer),
              isExactTargetCurrent(currentTarget) else { return nil }
        return currentTarget
    }

    private func targetsMatch(_ lhs: Target, _ rhs: Target) -> Bool {
        lhs.windowNumber == rhs.windowNumber &&
            lhs.applicationIdentity == rhs.applicationIdentity &&
            lhs.application.processIdentifier == rhs.application.processIdentifier
    }

    private func beginMissionControlObservation() {
        // An entry notification may race an old negative inspection. Advance
        // the session while keeping that in-flight slot occupied until drain.
        clearMissionControlObservation(reason: "scene_entered")
        markMissionControlObserved()
        scheduleInspection(force: true)
    }

    private func markMissionControlObserved() {
        lastMissionControlEvidenceNanoseconds = DispatchTime.now().uptimeNanoseconds
        missionControlHierarchyObserved = true
        if missionControlSessionValidationWorkItem == nil {
            scheduleMissionControlSessionValidation()
        }
    }

    private func clearMissionControlObservation(reason: String = "monitor_reset") {
        if missionControlHierarchyObserved || rootRecovery.inFlight != nil {
            WindowInteractionDiagnosticRecorder.shared.record(
                component: "mission_control", event: "session_cleared",
                metadata: ["reason": .code(reason)]
            )
        }
        // Replies from the previous Space/session/lease must not re-arm a target.
        // Preserve occupied in-flight slots until those replies drain.
        rootRecovery.invalidate()
        rootRecoveryWorkItem?.cancel()
        rootRecoveryWorkItem = nil
        inspectionGeneration &+= 1
        inspectionWorkItem?.cancel()
        inspectionWorkItem = nil
        inspectionPending = false
        closeValidationGeneration &+= 1
        missionControlHierarchyObserved = false
        lastMissionControlEvidenceNanoseconds = 0
        missionControlSessionValidationWorkItem?.cancel()
        missionControlSessionValidationWorkItem = nil
        axResolver.resetMissionControlSession()
        postActionInspectionWorkItems.forEach { $0.cancel() }
        postActionInspectionWorkItems.removeAll()
        clearTarget(clearPendingKeyboardTarget: true)
    }

    private func scheduleMissionControlSessionValidation() {
        missionControlSessionValidationWorkItem?.cancel()
        let generation = inspectionGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.inspectionGeneration == generation,
                  self.missionControlHierarchyObserved else { return }
            self.missionControlSessionValidationWorkItem = nil
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- self.lastMissionControlEvidenceNanoseconds <= 700_000_000 {
                self.scheduleInspection(force: true)
                self.scheduleMissionControlSessionValidation()
                return
            }
            self.clearMissionControlObservation(reason: "evidence_expired")
        }
        missionControlSessionValidationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func schedulePostActionInspection() {
        postActionInspectionWorkItems.forEach { $0.cancel() }
        postActionInspectionWorkItems.removeAll()
        let generation = inspectionGeneration
        for delay in [0.16, 0.24] {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.inspectionGeneration == generation else { return }
                self.scheduleInspection(force: true)
                self.postActionInspectionWorkItems.removeAll(where: { $0.isCancelled })
            }
            postActionInspectionWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func isExactTargetCurrent(_ target: Target) -> Bool {
        guard isApplicationIdentityCurrent(target) else { return false }
        return resolveExactWindow(
            processIdentifier: target.application.processIdentifier,
            windowNumber: target.windowNumber
        ).map({ CFEqual($0, target.window) }) == true
    }

    private func isApplicationIdentityCurrent(_ target: Target) -> Bool {
        guard !target.application.isTerminated,
              let currentApplication = NSRunningApplication(
                processIdentifier: target.application.processIdentifier
              ),
              !currentApplication.isTerminated,
              WindowThumbnailApplicationIdentity(
                application: currentApplication
              ) == target.applicationIdentity else { return false }
        return true
    }

    private func resolvedDockPID() -> pid_t? {
        if let dockPID,
           NSRunningApplication(processIdentifier: dockPID)?.isTerminated == false {
            return dockPID
        }
        let resolved = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first?.processIdentifier
        dockPID = resolved
        return resolved
    }

    /// A global close/quit shortcut must never fall through to the ordinary
    /// frontmost-window action merely because Mission Control opened before
    /// the hover resolver completed its first sample.
    private func missionControlRootIsCurrentlyPresent() -> Bool {
        guard let dockPID = resolvedDockPID() else { return false }
        let dockApplication = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockApplication, 0.025)
        return childAttributeElements(
            kAXChildrenAttribute,
            of: dockApplication
        ).contains {
            (stringAttribute("AXIdentifier", of: $0) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "mc"
        }
    }

    private func resolveExactWindow(
        processIdentifier: pid_t,
        windowNumber: CGWindowID
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.075)
        let matches = childAttributeElements(
            kAXWindowsAttribute,
            of: application
        ).prefix(64).filter {
            missionControlDirectWindowNumber(of: $0) == windowNumber
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func numberAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> UInt32? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else { return nil }
        return number.uint32Value
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

    private func childAttributeElements(
        _ attribute: String,
        of element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let elements = value as? [AXUIElement] else { return [] }
        return elements
    }
}

#if DEBUG
/// Adapters expose observations of the real resolver/monitor, not another copy
/// of their transition rules. No fixture starts monitors or presents a panel.
enum MissionControlSceneResolverFixture {
    enum Input {
        case outside(String)
        case indeterminate(String)
        case unresolved(String)
    }

    struct Result: Equatable {
        let state: String
        let reason: String
    }

    static func resolve(_ input: Input) -> Result {
        let resolution: MissionControlAXResolution
        switch input {
        case let .outside(reason): resolution = .outsideMissionControl(reason)
        case let .indeterminate(reason): resolution = .indeterminate(reason)
        case let .unresolved(reason): resolution = .missionControlWithoutExactTarget(reason)
        }
        return MissionControlAXResolver.resolveFixture(resolution)
    }
}

extension MissionControlAXResolver {
    static func resolveFixture(
        _ scene: MissionControlAXResolution
    ) -> MissionControlSceneResolverFixture.Result {
        let resolver = MissionControlAXResolver()
        resolver.sceneSnapshotForTesting = scene
        let result = resolver.resolveSynchronously(point: .zero, dockPID: 123)
        let state: String
        switch result {
        case .outsideMissionControl: state = "outside"
        case .indeterminate: state = "indeterminate"
        case .missionControlWithoutExactTarget: state = "unresolved"
        case .valid: state = "valid"
        }
        return .init(state: state, reason: result.diagnosticCode)
    }
}

extension MissionControlInteractionMonitor {
    @MainActor
    final class TestFixture {
        struct Snapshot: Equatable {
            let observed: Bool
            let hasEvidence: Bool
            let targetWindow: CGWindowID?
            let pendingKeyboardWindow: CGWindowID?
            let generation: UInt64
            let inFlightGeneration: UInt64?
            let closeGeneration: UInt64
            let keyboardGeneration: UInt64
            let inspectionPending: Bool
            let inspectionScheduled: Bool
            let rootRecoveryScheduled: Bool
            let validationScheduled: Bool
            let keyboardExpirationScheduled: Bool
            let postActionCount: Int
        }

        private let monitor = MissionControlInteractionMonitor()
        private let application: NSRunningApplication
        private let identity: WindowThumbnailApplicationIdentity
        private var trackedWorkItems: [DispatchWorkItem] = []
        private let closeRegion = CGRect(x: 10, y: 40, width: 24, height: 24)

        init?() {
            let application = NSRunningApplication.current
            guard let identity = WindowThumbnailApplicationIdentity(application: application) else {
                return nil
            }
            self.application = application
            self.identity = identity
            monitor.canInspectSceneForTesting = true
        }

        var snapshot: Snapshot {
            Snapshot(
                observed: monitor.missionControlHierarchyObserved,
                hasEvidence: monitor.lastMissionControlEvidenceNanoseconds != 0,
                targetWindow: monitor.currentTarget?.windowNumber,
                pendingKeyboardWindow: monitor.pendingKeyboardTarget?.target.windowNumber,
                generation: monitor.inspectionGeneration,
                inFlightGeneration: monitor.inspectionInFlightGeneration,
                closeGeneration: monitor.closeValidationGeneration,
                keyboardGeneration: monitor.pendingKeyboardTargetGeneration,
                inspectionPending: monitor.inspectionPending,
                inspectionScheduled: monitor.inspectionWorkItem != nil,
                rootRecoveryScheduled: monitor.rootRecoveryWorkItem != nil,
                validationScheduled: monitor.missionControlSessionValidationWorkItem != nil,
                keyboardExpirationScheduled: monitor.pendingKeyboardTargetExpiration != nil,
                postActionCount: monitor.postActionInspectionWorkItems.count
            )
        }

        var trackedWorkCancellation: [Bool] { trackedWorkItems.map(\.isCancelled) }

        func seedSession() {
            monitor.inspectionGeneration = 10
            monitor.closeValidationGeneration = 20
            monitor.markMissionControlObserved()
            installTarget(windowNumber: 41)
            monitor.inspectionInFlightGeneration = monitor.inspectionGeneration
            monitor.inspectionPending = true
            monitor.inspectionWorkItem = DispatchWorkItem {}
            monitor.rootRecoveryWorkItem = DispatchWorkItem {}
            monitor.schedulePostActionInspection()
            trackedWorkItems = [
                monitor.inspectionWorkItem,
                monitor.rootRecoveryWorkItem,
                monitor.missionControlSessionValidationWorkItem,
                monitor.pendingKeyboardTargetExpiration
            ].compactMap { $0 } + monitor.postActionInspectionWorkItems
        }

        func installTarget(windowNumber: CGWindowID) {
            let target = makeTarget(windowNumber: windowNumber)
            monitor.currentTarget = target
            monitor.currentTargetResolvedNanoseconds = DispatchTime.now().uptimeNanoseconds
            monitor.stagePendingKeyboardTarget(action: .closeWindow, target: target)
            monitor.closeInteractionState.updateVisibleRegion(closeRegion)
        }

        func enterScene() { monitor.beginMissionControlObservation() }

        func clearSession() {
            monitor.clearMissionControlObservation(reason: "test_reset")
        }

        func beginCurrentInspection() {
            monitor.inspectionWorkItem?.cancel()
            monitor.inspectionWorkItem = nil
            monitor.inspectionInFlightGeneration = monitor.inspectionGeneration
            monitor.inspectionPending = false
        }

        func finishOutside(generation: UInt64) {
            monitor.finishInspection(
                .outsideMissionControl("scene-marker-not-found"),
                elapsedNanoseconds: 1_000_000, generation: generation
            )
        }

        func finishValid(generation: UInt64) {
            let target = makeTarget(windowNumber: 41)
            monitor.finishInspection(
                .valid(MissionControlAXHit(
                    thumbnailFrame: target.thumbnailFrame, window: target.window,
                    windowNumber: target.windowNumber,
                    ownerPID: application.processIdentifier, canClose: true
                )),
                elapsedNanoseconds: 1_000_000, generation: generation
            )
        }

        func finishClose(generation: UInt64) {
            monitor.finishValidatedClose(
                .outsideMissionControl("close-mc-root-missing"),
                expected: makeTarget(windowNumber: 41), generation: generation,
                elapsedNanoseconds: 1_000_000
            )
        }

        func closeClickDecision() -> MissionControlCloseClickDecision {
            let point = CGPoint(x: closeRegion.midX, y: closeRegion.midY)
            let decision = monitor.closeInteractionState.decision(for: .leftMouseDown, location: point)
            _ = monitor.closeInteractionState.decision(for: .leftMouseUp, location: point)
            return decision
        }

        private func makeTarget(windowNumber: CGWindowID) -> Target {
            Target(
                application: application, applicationIdentity: identity,
                applicationName: "Fixture", window: AXUIElementCreateApplication(application.processIdentifier),
                windowNumber: windowNumber, thumbnailFrame: closeRegion, canClose: true
            )
        }
    }
}
#endif

@MainActor
private final class MissionControlInteractionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class MissionControlFirstMouseEffectView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

private final class MissionControlFirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

@MainActor
private final class MissionControlClosePanel {
    private let panel: NSPanel
    private let highlightPanel: NSPanel
    private let closeButton: NSButton
    private let interactionState: MissionControlCloseInteractionState
    private var onClose: (() -> Void)?

    init(interactionState: MissionControlCloseInteractionState) {
        self.interactionState = interactionState
        panel = MissionControlInteractionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 24, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        highlightPanel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        closeButton = MissionControlFirstMouseButton(
            frame: CGRect(x: 3, y: 3, width: 18, height: 18)
        )

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "关闭窗口"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        )
        closeButton.contentTintColor = NSColor(
            calibratedWhite: 0.97,
            alpha: 1
        )
        closeButton.target = self
        closeButton.action = #selector(pressedClose)

        let effect = MissionControlFirstMouseEffectView(
            frame: CGRect(x: 0, y: 0, width: 24, height: 24)
        )
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        effect.layer?.borderWidth = 0.75
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        effect.addSubview(closeButton)

        let highlightView = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        highlightView.autoresizingMask = [.width, .height]
        highlightView.wantsLayer = true
        highlightView.layer?.borderWidth = 2.5
        highlightView.layer?.borderColor = NSColor.systemBlue.cgColor
        highlightView.layer?.cornerRadius = 6

        panel.contentView = effect
        highlightPanel.contentView = highlightView
        panel.identifier = NSUserInterfaceItemIdentifier(
            "SuperIsland.MissionControl.CloseButton"
        )
        highlightPanel.identifier = NSUserInterfaceItemIdentifier(
            "SuperIsland.MissionControl.HoverOutline"
        )
        configure(panel: panel, acceptsMouseEvents: true, hasShadow: true)
        configure(panel: highlightPanel, acceptsMouseEvents: false, hasShadow: false)
    }

    func show(nearAXFrame frame: CGRect, onClose: @escaping () -> Void) {
        self.onClose = onClose
        guard let appKitFrame = appKitFrame(fromAXFrame: frame) else {
            hide()
            return
        }
        highlightPanel.setFrame(
            appKitFrame.insetBy(dx: -1, dy: -1),
            display: true
        )
        let origin = CGPoint(
            x: appKitFrame.minX + 8,
            y: appKitFrame.maxY - panel.frame.height - 8
        )
        let visibleFrame = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: appKitFrame.midX, y: appKitFrame.midY))
        })?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: min(max(origin.x, visibleFrame.minX + 2), visibleFrame.maxX - panel.frame.width - 2),
                y: min(max(origin.y, visibleFrame.minY + 2), visibleFrame.maxY - panel.frame.height - 2)
            ))
        } else {
            panel.setFrameOrigin(origin)
        }
        highlightPanel.orderFrontRegardless()
        panel.orderFrontRegardless()
        interactionState.updateVisibleRegion(
            quartzFrame(fromAppKitFrame: panel.frame)
        )
    }

    func hide() {
        interactionState.updateVisibleRegion(nil)
        onClose = nil
        panel.orderOut(nil)
        highlightPanel.orderOut(nil)
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -5, dy: -5).contains(point)
    }

    /// The blue outline is a SuperIsland window spanning the thumbnail. Order it
    /// out only for the synchronous system-wide AX hit test so target validation
    /// always reaches the underlying Dock expose group. The close control stays
    /// visible and is placed outside the thumbnail center used for validation.
    func withUnderlyingHighlightHidden<T>(_ operation: () -> T) -> T {
        let wasVisible = highlightPanel.isVisible
        if wasVisible { highlightPanel.orderOut(nil) }
        defer {
            if wasVisible { highlightPanel.orderFrontRegardless() }
        }
        return operation()
    }

    @objc private func pressedClose() {
        _ = triggerClose()
    }

    @discardableResult
    func triggerClose() -> Bool {
        guard let onClose else { return false }
        onClose()
        return true
    }

    private func configure(
        panel: NSPanel,
        acceptsMouseEvents: Bool,
        hasShadow: Bool
    ) {
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = hasShadow
        panel.ignoresMouseEvents = !acceptsMouseEvents
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
    }

    private func appKitFrame(fromAXFrame frame: CGRect) -> CGRect? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)
            guard quartzBounds.intersects(frame) ||
                    quartzBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
                continue
            }
            return CGRect(
                x: screen.frame.minX + (frame.minX - quartzBounds.minX),
                y: screen.frame.maxY - (frame.maxY - quartzBounds.minY),
                width: frame.width,
                height: frame.height
            )
        }
        return nil
    }

    private func quartzFrame(fromAppKitFrame frame: CGRect) -> CGRect? {
        for screen in NSScreen.screens where
                screen.frame.intersects(frame) ||
                screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let quartzBounds = CGDisplayBounds(
                CGDirectDisplayID(number.uint32Value)
            )
            return CGRect(
                x: quartzBounds.minX + (frame.minX - screen.frame.minX),
                y: quartzBounds.minY + (screen.frame.maxY - frame.maxY),
                width: frame.width,
                height: frame.height
            )
        }
        return nil
    }
}
