import AppKit
import ApplicationServices
import OSLog
import QuartzCore
import SwiftUI

private struct DockAXHitSnapshot: Sendable {
    let applicationURL: URL?
    let title: String
    let quartzFrame: CGRect?
}

struct DockApplicationIdentityCandidate: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundlePath: String?
    let localizedName: String?
    let isRegular: Bool
}

/// Resolves a Dock tile to one concrete running process. A copied application
/// can share its localized name with the original while having a different
/// bundle identifier and path, so title matching is permitted only when it is
/// unique. Ambiguity fails closed instead of borrowing the first process's
/// windows and thumbnails.
enum DockApplicationIdentityPolicy {
    static func normalizedApplicationURL(_ url: URL) -> URL? {
        if url.isFileURL { return url.standardizedFileURL }
        guard url.scheme == nil else { return nil }
        let path = url.path.isEmpty ? url.relativeString : url.path
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func normalizedApplicationURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        guard let url = URL(string: trimmed) else { return nil }
        return normalizedApplicationURL(url)
    }

    static func selectProcessIdentifier(
        targetBundleIdentifier: String?,
        targetBundlePath: String?,
        title: String,
        candidates: [DockApplicationIdentityCandidate]
    ) -> pid_t? {
        let available = candidates.filter { $0.processIdentifier > 0 && $0.isRegular }
        if let targetBundlePath {
            let exact = available.filter { $0.bundlePath == targetBundlePath }
            if exact.count == 1 { return exact[0].processIdentifier }
            if exact.count > 1 { return nil }
        }
        if let targetBundleIdentifier, !targetBundleIdentifier.isEmpty {
            let bundleMatches = available.filter {
                $0.bundleIdentifier?.caseInsensitiveCompare(targetBundleIdentifier)
                    == .orderedSame
            }
            if bundleMatches.count == 1 { return bundleMatches[0].processIdentifier }
            if bundleMatches.count > 1 { return nil }
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }
        let titleMatches = available.filter { candidate in
            guard let name = candidate.localizedName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return false }
            return name.compare(
                normalizedTitle,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: .current
            ) == .orderedSame
        }
        return titleMatches.count == 1 ? titleMatches[0].processIdentifier : nil
    }
}

private final class DockMouseIngress: @unchecked Sendable {
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

/// Dock Accessibility IPC can stall behind Dock/WindowServer. Keep the hot
/// mouse-move path off the main actor and bound both traversal and IPC time.
private final class DockAXHitResolver: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.workview.SuperIsland.dock-hit-resolver",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let messagingTimeout: Float = 0.075

    func resolve(
        point: CGPoint,
        completion: @escaping @Sendable (DockAXHitSnapshot?) -> Void
    ) {
        queue.async { [self] in
            completion(autoreleasepool { resolveSynchronously(at: point) })
        }
    }

    private func resolveSynchronously(at point: CGPoint) -> DockAXHitSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        ) == .success,
        var current = element else { return nil }

        var visited = Set<CFHashCode>()
        for _ in 0..<10 {
            let hash = CFHash(current)
            guard visited.insert(hash).inserted else { return nil }
            let role = stringAttribute(kAXRoleAttribute, of: current) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, of: current) ?? ""
            let looksLikeDockItem = role.localizedCaseInsensitiveContains("dock") ||
                subrole.localizedCaseInsensitiveContains("dock")
            if looksLikeDockItem {
                let rawTitle = stringAttribute(kAXTitleAttribute, of: current)
                    ?? stringAttribute(kAXDescriptionAttribute, of: current)
                    ?? ""
                return DockAXHitSnapshot(
                    applicationURL: urlAttribute(kAXURLAttribute, of: current),
                    title: rawTitle
                        .replacingOccurrences(of: "，有新窗口", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    quartzFrame: elementBounds(current)
                )
            }
            guard let parent = elementAttribute(kAXParentAttribute, of: current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func urlAttribute(_ name: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success,
        let value else { return nil }
        if let url = value as? URL {
            return DockApplicationIdentityPolicy.normalizedApplicationURL(url)
        }
        if let string = value as? String {
            return DockApplicationIdentityPolicy.normalizedApplicationURL(from: string)
        }
        return nil
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

    private func elementBounds(_ element: AXUIElement) -> CGRect? {
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
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeBitCast(positionValue, to: AXValue.self),
            .cgPoint,
            &origin
        ),
        AXValueGetValue(
            unsafeBitCast(sizeValue, to: AXValue.self),
            .cgSize,
            &size
        ) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
final class WindowDockInteractionMonitor {
    private let preferences = WindowEnhancementPreferences.shared
    private let preview = DockWindowPreviewController()
    private let dockAXResolver = DockAXHitResolver()
    private let mouseIngress = DockMouseIngress()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.superisland.app",
        category: "DockPreview"
    )
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var installedEventMask: NSEvent.EventTypeMask = []
    private var inspectionWorkItem: DispatchWorkItem?
    private var latestMouseSample: MouseSample?
    private var inspectionGeneration = 0
    private var inspectionInFlight = false
    private var inspectionPending = false
    private var hoverWorkItem: DispatchWorkItem?
    private var thumbnailCaptureTask: Task<Void, Never>?
    private var hoverCaptureGeneration = 0
    private var hideWorkItem: DispatchWorkItem?
    private var hideGeneration = 0
    private var lastInspectedAt = Date.distantPast
    private var hoveredDockPID: pid_t?
    private var pendingHoverPID: pid_t?
    private var mouseDownTargetPID: pid_t?
    private var mouseDownReverseAction: DockReverseAction?
    private var reverseMinimizedWindows: [pid_t: [AXUIElement]] = [:]
    private var reverseOperationGenerations: [pid_t: Int] = [:]
    /// Invalidates every delayed Dock-reverse callback across feature toggles.
    /// Per-PID generations alone are insufficient because clearing the map and
    /// quickly re-enabling the feature can reuse the same numeric generation.
    private var reverseFeatureGeneration: UInt64 = 0
    private var monitorGeneration: UInt64 = 0
    private var lastAcceptedMonitorEvent: MonitoredDockEvent?
    private var previewInvalidationObserver: NSObjectProtocol?

    private enum MonitorSource: Sendable {
        case global
        case local
    }

    private enum MonitoredDockEventKind: Sendable, Equatable {
        case mouseMoved
        case leftMouseDown
        case leftMouseUp
    }

    /// `NSEvent` itself is not Sendable. Monitor callbacks immediately reduce
    /// it to this value before crossing onto the single main-queue FIFO.
    private struct MonitoredDockEvent: Sendable {
        let kind: MonitoredDockEventKind
        let quartzLocation: CGPoint
        let appKitLocation: CGPoint
        let timestamp: TimeInterval
        let source: MonitorSource
    }

    private enum DockReverseAction {
        case minimize([AXUIElement])
        case restore([AXUIElement])
    }

    private struct MouseSample {
        let quartzLocation: CGPoint
        let appKitLocation: CGPoint
    }

    private struct DockHit {
        let application: NSRunningApplication
        /// Preserve the Dock item's own label. Helper Apps such as WeChat mini
        /// programs can have a generic bundle name that differs from the label
        /// the user actually hovered.
        let displayName: String?
        /// Dock exposes item geometry in Quartz/AX coordinates. Convert it at
        /// the hit-test boundary so the preview can use a stable AppKit anchor
        /// rather than whichever pixel inside the icon the pointer happened to
        /// occupy when the delayed hover fired.
        let appKitFrame: CGRect?
    }

    func start() {
        WindowThumbnailProvider.beginLifecycleMonitoring()
        observePreviewInvalidationIfNeeded()
        updateEnabledState()
    }

    func stop() {
        removeMonitor()
        cancelPendingWork()
        preview.hide()
        WindowThumbnailProvider.clearAllCache()
        if let previewInvalidationObserver {
            NotificationCenter.default.removeObserver(previewInvalidationObserver)
            self.previewInvalidationObserver = nil
        }
    }

    func updateEnabledState() {
        let reverseEnabled = preferences.isEnabled && preferences.dockReverseEnabled
        if !reverseEnabled {
            cancelDockReverseOperations(clearTracking: true)
        }
        let anyPreviewEnabled = preferences.isEnabled && (
            preferences.dockPreviewEnabled || preferences.cmdTabPlusEnabled
        )
        if !anyPreviewEnabled {
            WindowThumbnailProvider.clearAllCache()
        }
        if !preferences.isEnabled || !preferences.dockPreviewEnabled {
            cancelInspection()
            cancelHoverPipeline(clearTarget: true)
            cancelScheduledHide()
            preview.hide()
        }
        var desiredEventMask: NSEvent.EventTypeMask = []
        if preferences.isEnabled, preferences.dockPreviewEnabled {
            desiredEventMask.insert(.mouseMoved)
        }
        if preferences.isEnabled,
           preferences.dockPreviewEnabled || preferences.dockReverseEnabled {
            desiredEventMask.formUnion([.leftMouseDown, .leftMouseUp])
        }
        if !desiredEventMask.isEmpty {
            installMonitorIfNeeded(eventMask: desiredEventMask)
        } else {
            removeMonitor()
            cancelPendingWork()
            preview.hide()
        }
    }

    private func installMonitorIfNeeded(eventMask: NSEvent.EventTypeMask) {
        if globalMonitor != nil || localMonitor != nil {
            guard installedEventMask != eventMask else { return }
            removeMonitor()
        }
        monitorGeneration &+= 1
        lastAcceptedMonitorEvent = nil
        installedEventMask = eventMask
        let generation = monitorGeneration
        let mouseIngress = self.mouseIngress
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let compactEvent = Self.compact(event, source: .global) else { return }
            if compactEvent.kind == .mouseMoved {
                mouseIngress.submit { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.monitorGeneration == generation,
                              self.globalMonitor != nil else { return }
                        self.accept(compactEvent)
                    }
                }
            } else {
                // Down/up events retain their AppKit callback order so Dock
                // reverse never sees a release before its matching press.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.monitorGeneration == generation,
                          self.globalMonitor != nil else { return }
                    self.accept(compactEvent)
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let compactEvent = Self.compact(event, source: .local) else { return event }
            if compactEvent.kind == .mouseMoved {
                mouseIngress.submit { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.monitorGeneration == generation,
                              self.localMonitor != nil else { return }
                        self.accept(compactEvent)
                    }
                }
            } else {
                // Local monitors run on the AppKit event thread. Route a click
                // in our non-key preview synchronously and consume it before it
                // can fall through to the window behind the panel. AX actions
                // remain deferred by the row closures after the paired release.
                let consumed = MainActor.assumeIsolated { [weak self] in
                    guard let self,
                          self.monitorGeneration == generation,
                          self.localMonitor != nil else { return false }
                    return self.accept(compactEvent)
                }
                return consumed ? nil : event
            }
            return event
        }
    }

    private func observePreviewInvalidationIfNeeded() {
        guard previewInvalidationObserver == nil else { return }
        previewInvalidationObserver = NotificationCenter.default.addObserver(
            forName: WindowThumbnailProvider.didInvalidatePreviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelInspection()
                self.cancelHoverPipeline(clearTarget: true)
                self.cancelScheduledHide()
                self.preview.hide()
            }
        }
    }

    private func removeMonitor() {
        // Invalidate callbacks already queued by either monitor before
        // removing their tokens. Re-enabling cannot replay an old click or
        // hover stream into the new generation.
        monitorGeneration &+= 1
        lastAcceptedMonitorEvent = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        installedEventMask = []
        mouseIngress.reset()
    }

    nonisolated private static func compact(
        _ event: NSEvent,
        source: MonitorSource
    ) -> MonitoredDockEvent? {
        guard let quartzLocation = event.cgEvent?.location else { return nil }
        let kind: MonitoredDockEventKind
        switch event.type {
        case .mouseMoved: kind = .mouseMoved
        case .leftMouseDown: kind = .leftMouseDown
        case .leftMouseUp: kind = .leftMouseUp
        default: return nil
        }
        return MonitoredDockEvent(
            kind: kind,
            quartzLocation: quartzLocation,
            appKitLocation: NSEvent.mouseLocation,
            timestamp: event.timestamp,
            source: source
        )
    }

    @discardableResult
    private func accept(_ event: MonitoredDockEvent) -> Bool {
        if let previous = lastAcceptedMonitorEvent,
           previous.source != event.source,
           previous.kind == event.kind,
           abs(previous.timestamp - event.timestamp) <= 0.000_001,
           abs(previous.quartzLocation.x - event.quartzLocation.x) <= 0.25,
           abs(previous.quartzLocation.y - event.quartzLocation.y) <= 0.25 {
            // Local/global monitors normally partition own-App versus other-
            // App events. If macOS mirrors one native event to both, accept it
            // only once so reverse actions and hover generations do not toggle
            // twice.
            return event.kind != .mouseMoved && preview.contains(event.appKitLocation)
        }
        lastAcceptedMonitorEvent = event

        switch event.kind {
        case .mouseMoved:
            handleMouseMoved(
                quartzLocation: event.quartzLocation,
                appKitLocation: event.appKitLocation
            )
            return false
        case .leftMouseDown:
            if preview.handleExternalPointer(
                type: .leftMouseDown,
                at: event.appKitLocation
            ) {
                cancelInspection()
                cancelScheduledHide()
                return true
            }
            handleMouseDown(quartzLocation: event.quartzLocation)
            return false
        case .leftMouseUp:
            if preview.handleExternalPointer(
                type: .leftMouseUp,
                at: event.appKitLocation
            ) {
                cancelInspection()
                cancelScheduledHide()
                return true
            }
            handleMouseUp(quartzLocation: event.quartzLocation)
            return false
        }
    }

    private func handleMouseMoved(quartzLocation: CGPoint, appKitLocation: CGPoint) {
        guard preferences.isEnabled, preferences.dockPreviewEnabled else {
            cancelInspection()
            cancelHoverPipeline(clearTarget: true)
            cancelScheduledHide()
            preview.hide()
            return
        }

        let sample = MouseSample(
            quartzLocation: quartzLocation,
            appKitLocation: appKitLocation
        )
        if preview.contains(appKitLocation) {
            cancelInspection()
            cancelScheduledHide()
            preview.observePointer(at: appKitLocation)
            return
        }

        // Keep replacing only the sample, not the scheduled item. The item runs
        // at the trailing edge of the 120 ms window and therefore always
        // inspects the final cursor position even if movement stops immediately.
        latestMouseSample = sample
        scheduleTrailingInspection()
    }

    private func scheduleTrailingInspection() {
        guard inspectionWorkItem == nil else { return }
        let elapsed = Date().timeIntervalSince(lastInspectedAt)
        let delay = max(0, 0.12 - elapsed)
        let generation = inspectionGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.inspectionGeneration == generation else { return }
            self.inspectionWorkItem = nil
            guard let sample = self.latestMouseSample else { return }
            self.latestMouseSample = nil
            self.lastInspectedAt = Date()
            self.inspectMousePosition(sample)
        }
        inspectionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func inspectMousePosition(_ sample: MouseSample) {
        guard preferences.isEnabled, preferences.dockPreviewEnabled else {
            cancelInspection()
            cancelHoverPipeline(clearTarget: true)
            cancelScheduledHide()
            preview.hide()
            return
        }

        guard !inspectionInFlight else {
            latestMouseSample = sample
            inspectionPending = true
            return
        }
        inspectionInFlight = true
        inspectionPending = false
        let generation = inspectionGeneration
        dockAXResolver.resolve(point: sample.quartzLocation) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.finishMouseInspection(
                    snapshot,
                    sample: sample,
                    generation: generation
                )
            }
        }
    }

    private func finishMouseInspection(
        _ snapshot: DockAXHitSnapshot?,
        sample: MouseSample,
        generation: Int
    ) {
        guard inspectionGeneration == generation else { return }
        inspectionInFlight = false
        lastInspectedAt = Date()

        guard let snapshot,
              let hit = dockHit(from: snapshot, sample: sample) else {
            hoveredDockPID = nil
            if inspectionPending || latestMouseSample != nil {
                schedulePendingInspectionIfNeeded()
            } else {
                schedulePreviewHide()
            }
            return
        }
        let application = hit.application
        guard
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(application) else {
            hoveredDockPID = nil
            if inspectionPending || latestMouseSample != nil {
                schedulePendingInspectionIfNeeded()
            } else {
                schedulePreviewHide()
            }
            return
        }

        let applicationPID = application.processIdentifier
        cancelScheduledHide()

        // Mouse-moved events arrive continuously while the pointer is over one
        // Dock icon. Replacing the delayed task on every event meant the delay
        // could keep moving forever and the preview would never be shown.
        if hoveredDockPID == applicationPID,
           (pendingHoverPID == applicationPID || preview.applicationPID == applicationPID) {
            schedulePendingInspectionIfNeeded()
            return
        }

        cancelHoverPipeline(clearTarget: false)
        hoveredDockPID = applicationPID
        pendingHoverPID = applicationPID
        let generation = hoverCaptureGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hoverCaptureGeneration == generation else { return }
            self.hoverWorkItem = nil
            guard let currentSample = self.currentPointerContext(
                    matching: applicationPID,
                    fallback: sample,
                    dockItemFrame: hit.appKitFrame,
                    allowPreview: false
                  ),
                  self.preferences.isEnabled,
                  self.preferences.dockPreviewEnabled,
                  let application = NSRunningApplication(processIdentifier: applicationPID),
                  !application.isTerminated,
                  !self.preferences.isExcluded(application),
                  self.hoveredDockPID == applicationPID else {
                self.handleHoverTargetLoss(
                    processIdentifier: applicationPID,
                    generation: generation
                )
                return
            }
            let windows = self.windows(for: application)
            if self.pendingHoverPID == applicationPID { self.pendingHoverPID = nil }
            guard let applicationIdentity = WindowThumbnailApplicationIdentity(
                application: application
            ) else {
                self.thumbnailCaptureTask = nil
                self.preview.show(
                    application: application,
                    displayName: hit.displayName,
                    rows: self.previewRows(
                        windows: windows,
                        thumbnailResults: Array(
                            repeating: Optional.some(.notEnumerated),
                            count: windows.count
                        ),
                        applicationPID: applicationPID
                    ),
                    near: currentSample.appKitLocation,
                    dockItemFrame: hit.appKitFrame,
                    canManageWindows: AXIsProcessTrusted()
                )
                return
            }

            let requests = windows.map {
                return WindowThumbnailRequest(
                    title: $0.captureTitle,
                    occurrence: $0.captureOccurrence,
                    bounds: $0.captureBounds,
                    windowID: $0.windowID,
                    allowsUniformContent: $0.allowsUniformContent
                )
            }
            guard !requests.isEmpty else {
                let anchorLocation = currentSample.appKitLocation
                let dockItemFrame = hit.appKitFrame
                let displayName = hit.displayName
                self.thumbnailCaptureTask = Task { @MainActor [weak self] in
                    let discovery = await WindowThumbnailProvider
                        .discoverAndCaptureWindows(
                            applicationIdentity: applicationIdentity
                        )
                    guard let self else { return }
                    guard self.hoverCaptureGeneration == generation else { return }
                    self.thumbnailCaptureTask = nil
                    guard !Task.isCancelled,
                          self.preferences.isEnabled,
                          self.preferences.dockPreviewEnabled,
                          self.hoveredDockPID == applicationPID,
                          self.currentPointerContext(
                            matching: applicationPID,
                            fallback: sample,
                            dockItemFrame: dockItemFrame,
                            allowPreview: true
                          ) != nil,
                          let currentApplication = NSRunningApplication(
                            processIdentifier: applicationPID
                          ),
                          !currentApplication.isTerminated,
                          WindowThumbnailApplicationIdentity(
                            application: currentApplication
                          ) == applicationIdentity,
                          !self.preferences.isExcluded(currentApplication) else {
                        self.handleHoverTargetLoss(
                            processIdentifier: applicationPID,
                            generation: generation
                        )
                        return
                    }
                    self.preview.show(
                        application: currentApplication,
                        displayName: displayName,
                        rows: self.previewRows(discovery: discovery),
                        near: anchorLocation,
                        dockItemFrame: dockItemFrame,
                        canManageWindows: AXIsProcessTrusted()
                    )
                }
                return
            }

            let anchorLocation = currentSample.appKitLocation
            let dockItemFrame = hit.appKitFrame
            self.thumbnailCaptureTask = Task { @MainActor [weak self] in
                let thumbnails = await WindowThumbnailProvider.captureWindows(
                    applicationIdentity: applicationIdentity,
                    requests: requests
                )
                guard let self else { return }
                guard self.hoverCaptureGeneration == generation else { return }
                self.thumbnailCaptureTask = nil
                guard !Task.isCancelled,
                      self.preferences.isEnabled,
                      self.preferences.dockPreviewEnabled,
                      self.hoveredDockPID == applicationPID,
                      self.currentPointerContext(
                        matching: applicationPID,
                        fallback: sample,
                        dockItemFrame: dockItemFrame,
                        allowPreview: true
                      ) != nil,
                      let currentApplication = NSRunningApplication(
                        processIdentifier: applicationPID
                      ),
                      !currentApplication.isTerminated,
                      WindowThumbnailApplicationIdentity(
                        application: currentApplication
                      ) == applicationIdentity,
                      !self.preferences.isExcluded(currentApplication) else {
                    self.handleHoverTargetLoss(
                        processIdentifier: applicationPID,
                        generation: generation
                    )
                    return
                }

                let rows = self.previewRows(
                    windows: windows,
                    thumbnailResults: thumbnails.map(Optional.some),
                    applicationPID: applicationPID
                )
                self.preview.show(
                    application: currentApplication,
                    displayName: hit.displayName,
                    rows: rows,
                    near: anchorLocation,
                    dockItemFrame: dockItemFrame,
                    canManageWindows: AXIsProcessTrusted()
                )
            }
        }
        hoverWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
        schedulePendingInspectionIfNeeded()
    }

    private func schedulePendingInspectionIfNeeded() {
        guard inspectionPending || latestMouseSample != nil else { return }
        inspectionPending = false
        scheduleTrailingInspection()
    }

    private func currentPointerContext(
        matching processIdentifier: pid_t,
        fallback: MouseSample,
        dockItemFrame: CGRect?,
        allowPreview: Bool
    ) -> MouseSample? {
        let sample = MouseSample(
            quartzLocation: CGEvent(source: nil)?.location ?? fallback.quartzLocation,
            appKitLocation: NSEvent.mouseLocation
        )
        // The AX resolver already bound this PID to a specific Dock item. Use
        // that stable AppKit frame for delayed/capture validation instead of
        // repeating blocking system-wide AX hit-tests on the main actor.
        if dockItemFrame?.insetBy(dx: -12, dy: -12).contains(
            sample.appKitLocation
        ) == true {
            return sample
        }
        if allowPreview,
           preview.applicationPID == processIdentifier,
           preview.contains(sample.appKitLocation) {
            return sample
        }
        return nil
    }

    private func previewRows(
        windows: [DockWindowEntry],
        thumbnailResults: [WindowThumbnailResult?],
        applicationPID: pid_t
    ) -> [DockPreviewRow] {
        windows.enumerated().map { index, window in
            let thumbnailResult = thumbnailResults.indices.contains(index)
                ? thumbnailResults[index]
                : nil
            // WindowServer/SkyLight reconciliation is the identity boundary.
            // A screenshot is presentation data only: capture failure must not
            // delete a real, actionable window from a multi-window application.
            // Preview-only discovery below remains fail-closed because it lacks
            // an AX operation identity.
            return DockPreviewRow(
                id: window.id,
                title: window.title,
                isMinimized: window.isMinimized,
                canActivate: true,
                isPreviewOnly: false,
                canClose: window.canClose,
                thumbnailResult: thumbnailResult,
                action: { [weak self] in
                    self?.activate(window: window, applicationPID: applicationPID)
                },
                closeAction: { [weak self] in
                    self?.close(window: window, applicationPID: applicationPID)
                }
            )
        }
    }

    private func previewRows(
        discovery: WindowThumbnailDiscoveryResult
    ) -> [DockPreviewRow] {
        switch discovery {
        case let .windows(windows):
            guard let window = WindowPreviewOnlySelectionPolicy.selectOne(
                from: windows
            ) else { return [] }
            let rawTitle = window.request.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [DockPreviewRow(
                id: Int(window.request.windowID ?? 1),
                title: rawTitle.isEmpty ? "应用预览" : rawTitle,
                isMinimized: false,
                canActivate: false,
                isPreviewOnly: true,
                canClose: false,
                thumbnailResult: window.result,
                action: {},
                closeAction: {}
            )]
        case let .unavailable(result):
            guard result.isEligibleForWindowCard else { return [] }
            return [DockPreviewRow(
                id: -1,
                title: "窗口预览",
                isMinimized: false,
                canActivate: false,
                isPreviewOnly: true,
                canClose: false,
                thumbnailResult: result,
                action: {},
                closeAction: {}
            )]
        }
    }

    private func handleHoverTargetLoss(processIdentifier: pid_t, generation: Int) {
        guard hoverCaptureGeneration == generation else { return }
        hoverWorkItem = nil
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        if pendingHoverPID == processIdentifier { pendingHoverPID = nil }
        if hoveredDockPID == processIdentifier { hoveredDockPID = nil }

        // A newer mouse sample may still be waiting for the trailing inspector.
        // Do not cancel it merely because an older delayed/capture phase lost
        // its target; that would reproduce the final-position-loss bug.
        if inspectionWorkItem == nil, latestMouseSample == nil {
            schedulePreviewHide()
        }
    }

    private func schedulePreviewHide() {
        cancelInspection()
        cancelHoverPipeline(clearTarget: true)
        guard hideWorkItem == nil else { return }
        hideGeneration &+= 1
        let generation = hideGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.hideWorkItem = nil
            self.preview.hide(animated: true)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: item)
    }

    private func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hideGeneration &+= 1
    }

    private func cancelInspection() {
        inspectionWorkItem?.cancel()
        inspectionWorkItem = nil
        latestMouseSample = nil
        inspectionInFlight = false
        inspectionPending = false
        inspectionGeneration &+= 1
    }

    private func cancelHoverPipeline(clearTarget: Bool) {
        hoverWorkItem?.cancel()
        thumbnailCaptureTask?.cancel()
        hoverWorkItem = nil
        thumbnailCaptureTask = nil
        pendingHoverPID = nil
        if clearTarget { hoveredDockPID = nil }
        hoverCaptureGeneration &+= 1
    }

    private func handleMouseDown(quartzLocation: CGPoint) {
        guard preferences.dockReverseEnabled,
              let application = dockApplication(at: quartzLocation),
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(application) else {
            resetMouseDownState()
            return
        }

        let targetPID = application.processIdentifier
        let windows = windows(for: application)
        let visibleWindows = windows.filter { !$0.isMinimized }
        let targetWasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID

        mouseDownTargetPID = targetPID
        if targetWasFrontmost, !visibleWindows.isEmpty {
            mouseDownReverseAction = .minimize(visibleWindows.map(\.element))
        } else if visibleWindows.isEmpty, !windows.isEmpty {
            // Prefer restoring exactly the windows this feature minimized. If
            // the user/system minimized every window separately, restoring the
            // current AX list still gives the expected Dock toggle semantics.
            let tracked = (reverseMinimizedWindows[targetPID] ?? []).filter {
                boolAttribute(kAXMinimizedAttribute, of: $0) != nil
            }
            mouseDownReverseAction = .restore(tracked.isEmpty ? windows.map(\.element) : tracked)
        } else {
            // Clicking a background App with visible windows should retain the
            // Dock's normal activation behavior; it must not immediately vanish.
            mouseDownReverseAction = nil
        }
    }

    private func handleMouseUp(quartzLocation: CGPoint) {
        defer { resetMouseDownState() }
        guard preferences.dockReverseEnabled,
              let targetPID = mouseDownTargetPID,
              let action = mouseDownReverseAction,
              let releasedApplication = dockApplication(at: quartzLocation),
              releasedApplication.processIdentifier == targetPID,
              let application = NSRunningApplication(processIdentifier: targetPID),
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(application) else { return }

        // Let Dock finish its own click handling first. AXMinimized invokes the
        // system's native Dock animation, unlike NSRunningApplication.hide().
        let featureGeneration = reverseFeatureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self,
                  self.isDockReverseActive,
                  self.reverseFeatureGeneration == featureGeneration,
                  let application = NSRunningApplication(processIdentifier: targetPID),
                  !application.isTerminated else { return }
            switch action {
            case let .minimize(elements):
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
                self.minimizeWindows(elements, for: application)
            case let .restore(elements):
                self.restoreWindows(elements, for: application)
            }
        }
    }

    private func minimizeWindows(_ elements: [AXUIElement], for application: NSRunningApplication) {
        guard isDockReverseActive, !elements.isEmpty else { return }
        dismissPreview(animated: true)
        let targetPID = application.processIdentifier
        let featureGeneration = reverseFeatureGeneration
        let generation = (reverseOperationGenerations[targetPID] ?? 0) + 1
        reverseOperationGenerations[targetPID] = generation
        if reverseMinimizedWindows[targetPID] == nil {
            reverseMinimizedWindows[targetPID] = []
        }
        let step = reverseStep(windowCount: elements.count)

        for (index, element) in elements.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) { [weak self] in
                guard let self,
                      self.isDockReverseActive,
                      self.reverseFeatureGeneration == featureGeneration,
                      generation == self.reverseOperationGenerations[targetPID] else { return }
                guard self.boolAttribute(kAXMinimizedAttribute, of: element) != true else { return }
                if AXUIElementSetAttributeValue(
                    element,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanTrue
                ) == .success {
                    self.appendUnique(element, to: targetPID)
                }
            }
        }
    }

    private func restoreWindows(_ elements: [AXUIElement], for application: NSRunningApplication) {
        guard isDockReverseActive, !elements.isEmpty else { return }
        let targetPID = application.processIdentifier
        let featureGeneration = reverseFeatureGeneration
        let generation = (reverseOperationGenerations[targetPID] ?? 0) + 1
        reverseOperationGenerations[targetPID] = generation
        let step = reverseStep(windowCount: elements.count)

        _ = application.activate()
        for (index, element) in elements.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) { [weak self] in
                guard let self,
                      self.isDockReverseActive,
                      self.reverseFeatureGeneration == featureGeneration,
                      generation == self.reverseOperationGenerations[targetPID] else { return }
                guard self.boolAttribute(kAXMinimizedAttribute, of: element) == true else {
                    self.removeTracked(element, from: targetPID)
                    return
                }
                if AXUIElementSetAttributeValue(
                    element,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                ) == .success {
                    self.removeTracked(element, from: targetPID)
                }
            }
        }

        if let focusElement = elements.first {
            let focusDelay = step * Double(max(elements.count - 1, 0)) + 0.025
            DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) { [weak self] in
                guard let self,
                      self.isDockReverseActive,
                      self.reverseFeatureGeneration == featureGeneration,
                      generation == self.reverseOperationGenerations[targetPID] else { return }
                let appElement = AXUIElementCreateApplication(targetPID)
                _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(
                    appElement,
                    kAXFocusedWindowAttribute as CFString,
                    focusElement
                )
                _ = AXUIElementPerformAction(focusElement, kAXRaiseAction as CFString)
            }
        }
    }

    private func appendUnique(_ element: AXUIElement, to processIdentifier: pid_t) {
        var elements = reverseMinimizedWindows[processIdentifier] ?? []
        guard !elements.contains(where: { CFEqual($0, element) }) else { return }
        elements.append(element)
        reverseMinimizedWindows[processIdentifier] = elements
    }

    private func removeTracked(_ element: AXUIElement, from processIdentifier: pid_t) {
        guard var elements = reverseMinimizedWindows[processIdentifier] else { return }
        elements.removeAll { CFEqual($0, element) }
        reverseMinimizedWindows[processIdentifier] = elements.isEmpty ? nil : elements
    }

    /// Start all native minimize/restore animations within one short visual
    /// beat. The previous fixed 45 ms per-window delay made an App with many
    /// windows look like unrelated operations and could take hundreds of ms.
    private func reverseStep(windowCount: Int) -> TimeInterval {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              windowCount > 1 else { return 0 }
        return min(0.008, 0.06 / Double(windowCount - 1))
    }

    private var isDockReverseActive: Bool {
        preferences.isEnabled && preferences.dockReverseEnabled
    }

    private func cancelDockReverseOperations(clearTracking: Bool) {
        reverseFeatureGeneration &+= 1
        resetMouseDownState()
        reverseOperationGenerations.removeAll()
        if clearTracking {
            reverseMinimizedWindows.removeAll()
        }
    }

    private func resetMouseDownState() {
        mouseDownTargetPID = nil
        mouseDownReverseAction = nil
    }

    private func cancelPendingWork() {
        cancelInspection()
        cancelHoverPipeline(clearTarget: true)
        cancelScheduledHide()
        cancelDockReverseOperations(clearTracking: true)
    }

    private func dismissPreview(animated: Bool) {
        cancelInspection()
        cancelHoverPipeline(clearTarget: true)
        cancelScheduledHide()
        preview.hide(animated: animated)
    }

    private func dockApplication(at location: CGPoint) -> NSRunningApplication? {
        dockHit(at: location, appKitLocation: nil)?.application
    }

    private func dockHit(
        from snapshot: DockAXHitSnapshot,
        sample: MouseSample
    ) -> DockHit? {
        guard let application = dockApplication(
            applicationURL: snapshot.applicationURL,
            title: snapshot.title
        ) else { return nil }
        let appKitFrame = snapshot.quartzFrame.map { quartzFrame in
            CGRect(
                x: sample.appKitLocation.x + quartzFrame.minX - sample.quartzLocation.x,
                y: sample.appKitLocation.y + sample.quartzLocation.y - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
        }
        return DockHit(
            application: application,
            displayName: snapshot.title.isEmpty ? nil : snapshot.title,
            appKitFrame: appKitFrame
        )
    }

    private func dockHit(
        at location: CGPoint,
        appKitLocation: CGPoint?
    ) -> DockHit? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &element
        ) == .success,
        var current = element else { return nil }

        for _ in 0..<10 {
            let role = stringAttribute(kAXRoleAttribute, of: current) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, of: current) ?? ""
            let looksLikeDockItem = role.localizedCaseInsensitiveContains("dock") ||
                subrole.localizedCaseInsensitiveContains("dock")
            if looksLikeDockItem, let application = dockApplication(for: current) {
                let appKitFrame: CGRect?
                if let appKitLocation,
                   let quartzFrame = elementBounds(current) {
                    appKitFrame = CGRect(
                        x: appKitLocation.x + quartzFrame.minX - location.x,
                        y: appKitLocation.y + location.y - quartzFrame.maxY,
                        width: quartzFrame.width,
                        height: quartzFrame.height
                    )
                } else {
                    appKitFrame = nil
                }
                let displayName = dockItemTitle(for: current)
                return DockHit(
                    application: application,
                    displayName: displayName.isEmpty ? nil : displayName,
                    appKitFrame: appKitFrame
                )
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return nil
    }

    private func dockApplication(for element: AXUIElement) -> NSRunningApplication? {
        dockApplication(
            applicationURL: urlAttribute(kAXURLAttribute, of: element),
            title: dockItemTitle(for: element)
        )
    }

    private func dockItemTitle(for element: AXUIElement) -> String {
        let rawTitle = stringAttribute(kAXTitleAttribute, of: element)
            ?? stringAttribute(kAXDescriptionAttribute, of: element)
            ?? ""
        return rawTitle
            .replacingOccurrences(of: "，有新窗口", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dockApplication(
        applicationURL: URL?,
        title: String
    ) -> NSRunningApplication? {
        let normalizedURL = applicationURL.flatMap(
            DockApplicationIdentityPolicy.normalizedApplicationURL
        )
        let targetPath = normalizedURL?.resolvingSymlinksInPath().path
        let targetBundleIdentifier = normalizedURL.flatMap {
            Bundle(url: $0)?.bundleIdentifier
        }
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited
        }
        let candidates = runningApplications.map { application in
            DockApplicationIdentityCandidate(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: application.bundleURL?.standardizedFileURL
                    .resolvingSymlinksInPath().path,
                localizedName: application.localizedName,
                isRegular: application.activationPolicy == .regular
            )
        }
        guard let processIdentifier = DockApplicationIdentityPolicy
            .selectProcessIdentifier(
                targetBundleIdentifier: targetBundleIdentifier,
                targetBundlePath: targetPath,
                title: title,
                candidates: candidates
            ) else { return nil }
        return NSRunningApplication(processIdentifier: processIdentifier)
    }

    private func urlAttribute(_ name: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL {
            return DockApplicationIdentityPolicy.normalizedApplicationURL(url)
        }
        if let string = value as? String {
            return DockApplicationIdentityPolicy.normalizedApplicationURL(from: string)
        }
        return nil
    }

    private struct DockWindowEntry: Identifiable {
        let id: Int
        let element: AXUIElement
        /// Raw AX title used for WindowServer matching. Keep this separate from
        /// the user-facing fallback label so an untitled window can still match.
        let captureTitle: String
        let captureOccurrence: Int
        let captureBounds: CGRect?
        let windowID: CGWindowID?
        let title: String
        let isMinimized: Bool
        let isPreferredWindow: Bool
        let canClose: Bool
        var allowsUniformContent = false
    }

    private func windows(for application: NSRunningApplication) -> [DockWindowEntry] {
        guard AXIsProcessTrusted() else { return [] }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, of: appElement)
        let mainWindow = elementAttribute(kAXMainWindowAttribute, of: appElement)
        var collectedWindows: [AXUIElement] = []

        // Native fullscreen windows live in their own Space. Most Apps still
        // include them in AXWindows, but a few expose the active fullscreen
        // surface only through AXFocusedWindow or AXMainWindow while another
        // Space is active. Seed those two identities first and then merge the
        // complete AXWindows list so Dock hover can preview fullscreen Apps
        // without duplicating their focused window.
        for window in [focusedWindow, mainWindow].compactMap({ $0 }) {
            if !collectedWindows.contains(where: { CFEqual($0, window) }) {
                collectedWindows.append(window)
            }
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
           let rawWindows = windowsValue as? [AXUIElement] {
            for window in rawWindows
            where !collectedWindows.contains(where: { CFEqual($0, window) }) {
                collectedWindows.append(window)
            }
        }

        var rawEntries: [DockWindowEntry] = []
        for (index, window) in collectedWindows.enumerated() {
            let title = stringAttribute(kAXTitleAttribute, of: window)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let role = stringAttribute(kAXRoleAttribute, of: window) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, of: window) ?? ""
            let isMinimized = boolAttribute(kAXMinimizedAttribute, of: window) ?? false
            let isPreferredWindow = [focusedWindow, mainWindow]
                .compactMap { $0 }
                .contains { CFEqual($0, window) }
            guard WindowAXCandidatePolicy.shouldInclude(
                role: role,
                subrole: subrole,
                isModal: boolAttribute("AXModal", of: window),
                title: title,
                isMinimized: isMinimized,
                isPreferredWindow: isPreferredWindow,
                isHidden: boolAttribute(kAXHiddenAttribute, of: window),
                isVisible: boolAttribute("AXVisible", of: window)
            ) else { continue }
            rawEntries.append(DockWindowEntry(
                id: index,
                element: window,
                captureTitle: title,
                captureOccurrence: 0,
                captureBounds: elementBounds(window),
                windowID: windowIDAttribute(window),
                title: title.isEmpty ? "未命名窗口" : title,
                isMinimized: isMinimized,
                isPreferredWindow: isPreferredWindow,
                canClose: elementAttribute(kAXCloseButtonAttribute, of: window) != nil,
                allowsUniformContent: WindowPreviewCaptureEvidence.allowsUniformContent(of: window)
            ))
        }

        // Focused/main/AXWindows can vend distinct AX proxies for one real
        // window. Prefer WindowServer identity and use the shared exact-proxy
        // rule only when one proxy lacks an ID.
        var deduplicated: [DockWindowEntry] = []
        var indexByWindowID: [CGWindowID: Int] = [:]
        for entry in rawEntries {
            if let windowID = entry.windowID {
                if let existingIndex = indexByWindowID[windowID] {
                    deduplicated[existingIndex] = mergedDockEntry(
                        existing: deduplicated[existingIndex],
                        candidate: entry,
                        canonicalWindowID: windowID
                    )
                    continue
                }
                if let proxyIndex = deduplicated.firstIndex(where: {
                    $0.windowID == nil && dockEntriesAreExactProxies($0, entry, pid: application.processIdentifier)
                }) {
                    deduplicated[proxyIndex] = mergedDockEntry(
                        existing: deduplicated[proxyIndex],
                        candidate: entry,
                        canonicalWindowID: windowID
                    )
                    indexByWindowID[windowID] = proxyIndex
                } else {
                    indexByWindowID[windowID] = deduplicated.count
                    deduplicated.append(entry)
                }
            } else {
                if let proxyIndex = deduplicated.firstIndex(where: {
                    $0.windowID != nil
                        && dockEntriesAreExactProxies($0, entry, pid: application.processIdentifier)
                }) {
                    deduplicated[proxyIndex] = mergedDockEntry(
                        existing: deduplicated[proxyIndex],
                        candidate: entry,
                        canonicalWindowID: deduplicated[proxyIndex].windowID
                    )
                    continue
                }
                guard !deduplicated.contains(where: {
                    $0.windowID == nil && CFEqual($0.element, entry.element)
                }) else { continue }
                deduplicated.append(entry)
            }
        }

        let snapshot = WindowServerInventoryService.shared.snapshot(
            for: [application.processIdentifier]
        )
        let reconciliation = WindowInventoryReconciler.reconcile(
            candidates: deduplicated.enumerated().map { index, entry in
                WindowInventoryCandidate(
                    token: index,
                    ownerPID: application.processIdentifier,
                    windowID: entry.windowID,
                    title: entry.captureTitle,
                    bounds: entry.captureBounds,
                    isMinimized: entry.isMinimized,
                    isPreferredWindow: entry.isPreferredWindow
                )
            },
            snapshot: snapshot
        )
        logger.debug(
            "Dock inventory pid=\(application.processIdentifier, privacy: .public) mode=\(snapshot.mode.rawValue, privacy: .public) ax=\(rawEntries.count, privacy: .public) proxies=\(deduplicated.count, privacy: .public) matched=\(reconciliation.matches.count, privacy: .public) rejected=\(reconciliation.rejections.count, privacy: .public)"
        )
        let canonicalWindowIDByIndex = Dictionary(
            uniqueKeysWithValues: reconciliation.matches.map {
                ($0.token, $0.windowID)
            }
        )
        let confirmedEntries = deduplicated.enumerated().compactMap { index, entry in
            canonicalWindowIDByIndex[index].map { (entry, $0) }
        }

        var titleOccurrences: [String: Int] = [:]
        return confirmedEntries.enumerated().map { index, confirmed in
            let entry = confirmed.0
            let occurrence = titleOccurrences[entry.captureTitle, default: 0]
            titleOccurrences[entry.captureTitle] = occurrence + 1
            return DockWindowEntry(
                id: Int(confirmed.1),
                element: entry.element,
                captureTitle: entry.captureTitle,
                captureOccurrence: occurrence,
                captureBounds: entry.captureBounds,
                windowID: confirmed.1,
                title: entry.title,
                isMinimized: entry.isMinimized,
                isPreferredWindow: entry.isPreferredWindow,
                canClose: entry.canClose,
                allowsUniformContent: entry.allowsUniformContent
            )
        }
    }

    private func dockEntriesAreExactProxies(
        _ lhs: DockWindowEntry,
        _ rhs: DockWindowEntry,
        pid: pid_t
    ) -> Bool {
        WindowAXCandidatePolicy.areExactProxies(
            lhsPID: pid,
            lhsTitle: lhs.captureTitle,
            lhsBounds: lhs.captureBounds,
            lhsIsMinimized: lhs.isMinimized,
            lhsIsPreferredWindow: lhs.isPreferredWindow,
            rhsPID: pid,
            rhsTitle: rhs.captureTitle,
            rhsBounds: rhs.captureBounds,
            rhsIsMinimized: rhs.isMinimized,
            rhsIsPreferredWindow: rhs.isPreferredWindow
        )
    }

    private func mergedDockEntry(
        existing: DockWindowEntry,
        candidate: DockWindowEntry,
        canonicalWindowID: CGWindowID?
    ) -> DockWindowEntry {
        let useCandidate = WindowAXOperationProxyPolicy.prefersCandidate(
            existing: proxyEvidence(for: existing),
            candidate: proxyEvidence(for: candidate)
        )
        let operationProxy = useCandidate ? candidate : existing
        let metadataProxy = !candidate.captureTitle.isEmpty ? candidate : existing
        return DockWindowEntry(
            id: existing.id,
            element: operationProxy.element,
            captureTitle: metadataProxy.captureTitle,
            captureOccurrence: 0,
            captureBounds: candidate.captureBounds ?? existing.captureBounds,
            windowID: canonicalWindowID,
            title: metadataProxy.captureTitle.isEmpty
                ? operationProxy.title
                : metadataProxy.title,
            isMinimized: operationProxy.isMinimized,
            isPreferredWindow: existing.isPreferredWindow || candidate.isPreferredWindow,
            canClose: operationProxy.canClose,
            allowsUniformContent: existing.allowsUniformContent
                || candidate.allowsUniformContent
        )
    }

    private func proxyEvidence(
        for entry: DockWindowEntry
    ) -> WindowAXOperationProxyEvidence {
        WindowAXOperationProxyEvidence(
            hasWindowID: entry.windowID != nil,
            hasTitle: !entry.captureTitle.isEmpty,
            hasBounds: entry.captureBounds != nil,
            isPreferredWindow: entry.isPreferredWindow,
            canClose: entry.canClose,
            allowsUniformContent: entry.allowsUniformContent
        )
    }

    private func activate(window: DockWindowEntry, applicationPID: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: applicationPID),
              !application.isTerminated,
              !preferences.isExcluded(application) else {
            dismissPreview(animated: true)
            return
        }
        if window.isMinimized {
            _ = AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        if let windowID = window.windowID {
            WindowServerPrivateBridge.activate(
                processIdentifier: applicationPID,
                windowID: windowID
            )
        }
        _ = application.activate()
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            window.element
        )
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        dismissPreview(animated: true)
    }

    private func close(window: DockWindowEntry, applicationPID: pid_t) {
        guard AXIsProcessTrusted() else {
            preferences.publishFeedback("需要辅助功能权限才能关闭 Dock 预览窗口")
            return
        }
        guard let application = NSRunningApplication(processIdentifier: applicationPID),
              !application.isTerminated,
              !preferences.isExcluded(application),
              preview.applicationPID == applicationPID else {
            preferences.publishFeedback("Dock 预览窗口状态已变化，请重新悬停后再试")
            return
        }
        guard window.canClose,
              let closeButton = elementAttribute(
                kAXCloseButtonAttribute,
                of: window.element
              ) else {
            // The row was closable when enumerated, but its AX hierarchy may
            // have changed while the pointer travelled to the button. Do not
            // fall back to quitting or hiding the App.
            preferences.publishFeedback("当前 Dock 预览窗口已不可关闭，请重新悬停后再试")
            return
        }

        // Press the selected window's own AX close button. Never route through
        // NSRunningApplication terminate/hide, because that would affect the
        // whole App rather than the thumbnail the user chose.
        guard AXUIElementPerformAction(
            closeButton,
            kAXPressAction as CFString
        ) == .success else {
            preferences.publishFeedback("关闭 Dock 预览窗口失败")
            return
        }

        if let applicationIdentity = WindowThumbnailApplicationIdentity(
            application: application
        ) {
            WindowThumbnailProvider.clearCache(
                applicationIdentity: applicationIdentity,
                request: WindowThumbnailRequest(
                    title: window.captureTitle,
                    occurrence: window.captureOccurrence,
                    bounds: window.captureBounds,
                    windowID: window.windowID
                )
            )
        }

        if var tracked = reverseMinimizedWindows[applicationPID] {
            tracked.removeAll { CFEqual($0, window.element) }
            reverseMinimizedWindows[applicationPID] = tracked.isEmpty ? nil : tracked
        }

        // Invalidate in-flight captures that still contain the closed AX
        // element, then hide. A fresh Dock hover rebuilds rows and thumbnails
        // from the live AX window list, so stale cards cannot be clicked.
        dismissPreview(animated: true)
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

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func windowIDAttribute(_ element: AXUIElement) -> CGWindowID? {
        windowDirectWindowNumber(of: element)
    }

    private func elementBounds(_ element: AXUIElement) -> CGRect? {
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
}

@MainActor
private final class DockWindowPreviewController {
    private let panel: NSPanel
    private let contentModel: DockWindowPreviewModel
    private let contentView: DockWindowPreviewContentView
    private(set) var applicationPID: pid_t?
    private var visibilityGeneration = 0
    private var recentCacheExpirationGeneration = 0
    private var recentCacheExpirationWorkItem: DispatchWorkItem?

    init() {
        let contentModel = DockWindowPreviewModel()
        let contentView = DockWindowPreviewContentView(model: contentModel)
        let initialSize = CGSize(
            width: DockPreviewLayout.minimumPanelWidth,
            height: DockPreviewLayout.emptyPanelHeight
        )
        let panel = WindowPreviewInteractionPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentModel = contentModel
        self.contentView = contentView
        self.panel = panel

        panel.identifier = NSUserInterfaceItemIdentifier(
            "com.workview.SuperIsland.window-enhancement.dock-preview"
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        // Keep one AppKit container and one NSHostingView for the complete
        // lifetime of the panel. Placeholder rows and their asynchronous
        // thumbnail replacements update only the observable model; replacing
        // contentView here used to let two hosting trees publish competing
        // fitting sizes into the same NSPanel layout pass.
        panel.contentView = contentView
    }

    func show(
        application: NSRunningApplication,
        displayName: String?,
        rows: [DockPreviewRow],
        near location: CGPoint,
        dockItemFrame: CGRect?,
        canManageWindows: Bool
    ) {
        visibilityGeneration &+= 1
        if applicationPID != application.processIdentifier {
            contentModel.resetPointerGeometry()
        }
        applicationPID = application.processIdentifier
        panel.ignoresMouseEvents = false
        let trimmedDisplayName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = trimmedDisplayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? application.localizedName ?? "App"

        let anchorPoint = dockItemFrame.map {
            CGPoint(x: $0.midX, y: $0.midY)
        } ?? location
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
                ?? NSScreen.screens.first(where: { $0.frame.contains(location) })
                ?? NSScreen.main else { return }
        let availableWidth = max(1, screen.visibleFrame.width - 20)
        let cardCount = max(1, rows.count)
        let isSingleWindowPreview = canManageWindows && rows.count == 1
        let naturalWidth = CGFloat(cardCount) * DockPreviewLayout.cardWidth
            + CGFloat(max(0, cardCount - 1)) * 10
            + DockPreviewLayout.horizontalPadding * 2
        let hasVisibleWindowTitle = rows.contains {
            !dockPreviewNamesMatch($0.title, appName)
        }
        let size = CGSize(
            width: min(
                availableWidth,
                max(DockPreviewLayout.minimumPanelWidth, naturalWidth)
            ),
            height: rows.isEmpty || !canManageWindows
                ? DockPreviewLayout.emptyPanelHeight
                : DockPreviewLayout.panelHeight(
                    showsWindowTitle: hasVisibleWindowTitle,
                    isSingleWindow: isSingleWindowPreview
                )
        )
        let targetFrame = frame(
            for: size,
            dockItemFrame: dockItemFrame,
            fallbackLocation: location,
            on: screen
        )
        let wasVisible = panel.isVisible

        // Establish the final AppKit geometry before publishing a new SwiftUI
        // tree value. In particular, never ask a zero-sized hidden hosting
        // view to lay out placeholder rows and then resize its panel in the
        // same display cycle.
        panel.setFrame(targetFrame, display: wasVisible)
        contentModel.update(
            appName: appName,
            icon: application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
            rows: rows,
            canManageWindows: canManageWindows
        )
        rescheduleRecentCacheExpiration()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wasVisible || reduceMotion {
            panel.alphaValue = 1
            if !wasVisible { panel.orderFrontRegardless() }
        } else {
            // Establish the final geometry synchronously before exposing the
            // panel. Only alpha is animated: frame animation in the same turn
            // as a ScrollView content update can feed AppKit's layout result
            // back into SwiftUI and recreate the update-constraints loop.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        // SwiftUI publishes each card's AppKit frame on the next layout pass.
        // Perform one bounded relayout now and one on the next run-loop turn so
        // a pointer that entered during presentation is re-evaluated without a
        // second physical move or click.
        contentView.layoutSubtreeIfNeeded()
        let generation = visibilityGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.visibilityGeneration == generation,
                  self.panel.isVisible else { return }
            self.contentView.layoutSubtreeIfNeeded()
            _ = self.handleExternalPointer(
                type: .mouseMoved,
                at: NSEvent.mouseLocation
            )
        }
    }

    func hide(animated: Bool = false) {
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        cancelRecentCacheExpiration()
        applicationPID = nil
        // A fading stale card must not receive another click after its AX
        // window has already been closed or the hover target has changed.
        panel.ignoresMouseEvents = true
        guard panel.isVisible else {
            panel.alphaValue = 1
            contentModel.clear()
            return
        }
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            panel.alphaValue = 1
            panel.orderOut(nil)
            contentModel.clear()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.visibilityGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.contentModel.clear()
            }
        })
    }

    func contains(_ location: CGPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(location)
    }

    func observePointer(at location: CGPoint) {
        _ = handleExternalPointer(type: .mouseMoved, at: location)
    }

    @discardableResult
    func handleExternalPointer(type: NSEvent.EventType, at location: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        guard panel.frame.contains(location) else {
            if type == .mouseMoved || type == .mouseExited {
                contentModel.handlePointer(.mouseExited, at: .zero)
            }
            return false
        }
        let point = panel.convertPoint(fromScreen: location)
        contentModel.handlePointer(
            type,
            at: CGPoint(x: point.x, y: contentView.bounds.height - point.y)
        )
        return true
    }

    private func rescheduleRecentCacheExpiration() {
        recentCacheExpirationWorkItem?.cancel()
        recentCacheExpirationGeneration &+= 1
        let generation = recentCacheExpirationGeneration
        guard let expiration = contentModel.expireRecentCaches(now: Date()) else {
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

    private enum DockEdge {
        case bottom
        case left
        case right
    }

    private func dockEdge(near location: CGPoint, on screen: NSScreen) -> DockEdge {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let insets: [(DockEdge, CGFloat)] = [
            (.bottom, visible.minY - frame.minY),
            (.left, visible.minX - frame.minX),
            (.right, frame.maxX - visible.maxX)
        ]
        if let dockInset = insets.max(by: { $0.1 < $1.1 }), dockInset.1 > 8 {
            return dockInset.0
        }

        // Auto-hidden Docks do not reduce visibleFrame, so fall back to the
        // pointer's nearest supported screen edge while the Dock is exposed.
        let distances: [(DockEdge, CGFloat)] = [
            (.bottom, abs(location.y - frame.minY)),
            (.left, abs(location.x - frame.minX)),
            (.right, abs(frame.maxX - location.x))
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
    }

    private func frame(
        for size: CGSize,
        dockItemFrame: CGRect?,
        fallbackLocation: CGPoint,
        on screen: NSScreen
    ) -> CGRect {
        let visible = screen.visibleFrame
        let margin: CGFloat = 10
        let anchor = dockItemFrame ?? CGRect(
            x: fallbackLocation.x,
            y: fallbackLocation.y,
            width: 0,
            height: 0
        )
        let anchorCenter = CGPoint(x: anchor.midX, y: anchor.midY)
        let edge = dockEdge(near: anchorCenter, on: screen)
        let proposedOrigin: CGPoint
        switch edge {
        case .bottom:
            proposedOrigin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
        case .left:
            proposedOrigin = CGPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
        case .right:
            proposedOrigin = CGPoint(x: anchor.minX - size.width - 10, y: anchor.midY - size.height / 2)
        }
        return CGRect(
            x: max(visible.minX + margin, min(proposedOrigin.x, visible.maxX - size.width - margin)),
            y: max(visible.minY + margin, min(proposedOrigin.y, visible.maxY - size.height - margin)),
            width: size.width,
            height: size.height
        )
    }

}

/// A non-intrinsic AppKit boundary for the Dock preview. The panel owns the
/// geometry; SwiftUI can only fill the explicit bounds supplied here.
private final class DockWindowPreviewContentView: NSView {
    private let hostingView: NSHostingView<DockWindowPreviewRootView>
    private let pointerView = WindowPreviewTrackingView()

    init(model: DockWindowPreviewModel) {
        hostingView = NSHostingView(
            rootView: DockWindowPreviewRootView(model: model)
        )
        super.init(
            frame: CGRect(
                origin: .zero,
                size: CGSize(
                    width: DockPreviewLayout.minimumPanelWidth,
                    height: DockPreviewLayout.emptyPanelHeight
                )
            )
        )

        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        addSubview(hostingView)
        pointerView.frame = bounds
        pointerView.autoresizingMask = [.width, .height]
        pointerView.scrollingView = hostingView
        pointerView.onPointer = { [weak model] type, point, _ in
            model?.handlePointer(type, at: point)
        }
        addSubview(pointerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        guard hostingView.frame != bounds else { return }
        hostingView.frame = bounds
    }
}

@MainActor
final class DockWindowPreviewModel: ObservableObject {
    @Published private(set) var hoveredRowID: Int?
    private var pointerState = WindowPreviewPointerState<Int>(closeButtonSize: 18)
    private var previewFrames: [Int: CGRect] = [:]
    struct Content {
        let appName: String
        let icon: NSImage?
        let rows: [DockPreviewRow]
        let canManageWindows: Bool
    }

    @Published private(set) var content = Content(
        appName: "App",
        icon: nil,
        rows: [],
        canManageWindows: false
    )

    func update(
        appName: String,
        icon: NSImage?,
        rows: [DockPreviewRow],
        canManageWindows: Bool
    ) {
        if content.rows.map(\.id) != rows.map(\.id) {
            resetPointerGeometry()
        }
        // Publish one complete value so SwiftUI never lays out a transient mix
        // of the previous app's rows and the next app's title or permissions.
        content = Content(
            appName: appName,
            icon: icon,
            rows: rows,
            canManageWindows: canManageWindows
        )
        updatePointerFrames()
    }

    func clear() {
        resetPointerGeometry()
        content = Content(
            appName: "App",
            icon: nil,
            rows: [],
            canManageWindows: false
        )
    }

    func resetPointerGeometry() {
        previewFrames = [:]
        pointerState = WindowPreviewPointerState<Int>(closeButtonSize: 18)
        hoveredRowID = nil
    }

    func setPreviewFrames(_ frames: [Int: CGRect]) {
        previewFrames = frames
        updatePointerFrames()
    }

    func setPreviewFrame(_ frame: CGRect?, for id: Int) {
        if let frame {
            previewFrames[id] = frame
        } else {
            previewFrames.removeValue(forKey: id)
        }
        updatePointerFrames()
    }

    private func updatePointerFrames() {
        let ids = Set(content.rows.map(\.id))
        pointerState.update(
            frames: previewFrames.filter { ids.contains($0.key) },
            activatable: Set(content.rows.filter(\.canActivate).map(\.id)),
            closable: Set(content.rows.filter(\.canClose).map(\.id))
        )
    }

    func handlePointer(_ type: NSEvent.EventType, at point: CGPoint) {
        let action = pointerState.handle(type, at: point)
        if hoveredRowID != pointerState.hovered { hoveredRowID = pointerState.hovered }
        guard let action else { return }
        switch action {
        case let .activate(id): content.rows.first { $0.id == id && $0.canActivate }?.action()
        case let .close(id): content.rows.first { $0.id == id && $0.canClose }?.closeAction()
        }
    }

    /// Drops the strong NSImage reference exactly when a recent full-screen
    /// fallback reaches the provider TTL. Returning the next deadline lets the
    /// persistent controller keep one bounded timer rather than a view-owned
    /// timer per tile.
    func expireRecentCaches(now: Date) -> Date? {
        var didChange = false
        var nextExpiration: Date?
        let rows = content.rows.map { row -> DockPreviewRow in
            guard let result = row.thumbnailResult,
                  case let .recentCache(_, timestamp) = result else { return row }
            let expiration = timestamp.addingTimeInterval(
                WindowThumbnailProvider.recentCacheTTL
            )
            guard expiration > now else {
                didChange = true
                return row.replacingThumbnailResult(.notEnumerated)
            }
            if nextExpiration == nil || expiration < nextExpiration! {
                nextExpiration = expiration
            }
            return row
        }
        if didChange {
            content = Content(
                appName: content.appName,
                icon: content.icon,
                rows: rows,
                canManageWindows: content.canManageWindows
            )
        }
        return nextExpiration
    }
}

private struct DockWindowPreviewRootView: View {
    @ObservedObject var model: DockWindowPreviewModel

    var body: some View {
        DockWindowPreviewView(
            appName: model.content.appName,
            icon: model.content.icon,
            rows: model.content.rows,
            canManageWindows: model.content.canManageWindows,
            hoveredRowID: model.hoveredRowID,
            onFrameChange: { id, frame in model.setPreviewFrame(frame, for: id) }
        )
    }
}

struct DockPreviewRow: Identifiable {
    let id: Int
    let title: String
    let isMinimized: Bool
    let canActivate: Bool
    let isPreviewOnly: Bool
    let canClose: Bool
    let thumbnailResult: WindowThumbnailResult?
    let action: () -> Void
    let closeAction: () -> Void

    func replacingThumbnailResult(
        _ thumbnailResult: WindowThumbnailResult?
    ) -> DockPreviewRow {
        DockPreviewRow(
            id: id,
            title: title,
            isMinimized: isMinimized,
            canActivate: canActivate,
            isPreviewOnly: isPreviewOnly,
            canClose: canClose,
            thumbnailResult: thumbnailResult,
            action: action,
            closeAction: closeAction
        )
    }
}

private enum DockPreviewLayout {
    static let cardWidth: CGFloat = 190
    static let thumbnailHeight: CGFloat = 118
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 10
    static let singleWindowVerticalPadding: CGFloat = 8
    static let minimumPanelWidth: CGFloat = 210
    static let emptyPanelHeight: CGFloat = 88

    static func panelHeight(showsWindowTitle: Bool, isSingleWindow: Bool) -> CGFloat {
        // Single-window cards omit the duplicate app header and use tighter
        // insets; multi-window cards retain the WINS-style header hierarchy.
        if isSingleWindow {
            return showsWindowTitle ? 156 : 136
        }
        return showsWindowTitle ? 184 : 164
    }
}

private func dockPreviewNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lhs.isEmpty, !rhs.isEmpty else { return false }
    return lhs.compare(
        rhs,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        range: nil,
        locale: .current
    ) == .orderedSame
}

private struct DockWindowPreviewView: View {
    let appName: String
    let icon: NSImage?
    let rows: [DockPreviewRow]
    let canManageWindows: Bool
    let hoveredRowID: Int?
    let onFrameChange: (Int, CGRect?) -> Void

    var body: some View {
        let isSingleWindowPreview = canManageWindows && rows.count == 1
        VStack(spacing: 8) {
            if !isSingleWindowPreview {
                Text(appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if !canManageWindows {
                Label("授予辅助功能权限后显示窗口", systemImage: "figure.stand")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if rows.isEmpty {
                Text("没有可选择的窗口")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if rows.count == 1, let row = rows.first {
                // A horizontal ScrollView aligns undersized content to its
                // leading edge. Render the common single-window case directly
                // so the real thumbnail is geometrically centered over its
                // Dock icon instead of appearing shifted to the left.
                DockPreviewCard(
                    row: row,
                    appName: appName,
                    fallbackIcon: icon,
                    isHovering: hoveredRowID == row.id,
                    onFrameChange: onFrameChange
                )
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(rows) { row in
                            DockPreviewCard(
                                row: row,
                                appName: appName,
                                fallbackIcon: icon,
                                isHovering: hoveredRowID == row.id,
                                onFrameChange: onFrameChange
                            )
                        }
                    }
                    .padding(.horizontal, 0)
                    .padding(.bottom, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, DockPreviewLayout.horizontalPadding)
        .padding(
            .vertical,
            isSingleWindowPreview
                ? DockPreviewLayout.singleWindowVerticalPadding
                : DockPreviewLayout.verticalPadding
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

private struct DockPreviewCard: View {
    let row: DockPreviewRow
    let appName: String
    let fallbackIcon: NSImage?

    let isHovering: Bool
    let onFrameChange: (Int, CGRect?) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if row.canActivate {
                Button(action: row.action) {
                    cardContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.title)
                .accessibilityHint("激活这个窗口")
            } else {
                cardContent
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.title)
                    .accessibilityHint("该应用未公开可控制窗口，仅提供预览")
            }

            if isHovering, row.canClose {
                Button(action: row.closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: 5)
                .accessibilityLabel("关闭\(row.title)")
                .accessibilityHint("只关闭这个窗口")
                .transition(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? .identity
                        : .opacity.combined(with: .scale(scale: 0.9))
                )
            }
        }
        .background(
            WindowPreviewFrameReporter(
                target: row.id,
                onChange: onFrameChange
            )
        )
    }

    private var cardContent: some View {
        VStack(spacing: 7) {
            Group {
                previewContent
            }
            .frame(
                width: DockPreviewLayout.cardWidth,
                height: DockPreviewLayout.thumbnailHeight,
                alignment: .center
            )
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        row.canActivate && isHovering
                            ? Color.accentColor.opacity(0.85)
                            : Color.white.opacity(0.13),
                        lineWidth: row.canActivate && isHovering ? 2 : 1
                    )
            )
            if !dockPreviewNamesMatch(row.title, appName) {
                HStack(spacing: 4) {
                    if row.isMinimized {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9))
                    }
                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .frame(width: DockPreviewLayout.cardWidth)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(
            row.canActivate && isHovering &&
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.015 : 1
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let result = row.thumbnailResult {
            switch result {
            case let .fresh(image):
                thumbnailImage(image)
            case let .recentCache(image, timestamp):
                ZStack(alignment: .topTrailing) {
                    thumbnailImage(image)
                    Text(recentPreviewLabel(timestamp: timestamp))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.68), in: Capsule())
                        .padding(5)
                }
            case .permissionRequired:
                previewFailure(title: "需要屏幕录制权限", symbol: "record.circle")
            case .restartRequired:
                previewFailure(title: "重启 SuperIsland 后显示", symbol: "arrow.clockwise")
            case .notEnumerated:
                previewFailure(
                    title: row.isPreviewOnly
                        ? "窗口预览暂不可用"
                        : "全屏预览暂不可用",
                    symbol: "rectangle.on.rectangle"
                )
            case .ambiguous:
                previewFailure(title: "无法唯一匹配窗口", symbol: "questionmark.square")
            case .captureFailed:
                previewFailure(title: "窗口预览暂不可用", symbol: "exclamationmark.triangle")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(3)
    }

    private func previewFailure(title: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            if let fallbackIcon {
                Image(nsImage: fallbackIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .opacity(0.68)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.07))
    }

    private func recentPreviewLabel(timestamp: Date) -> String {
        let age = max(0, Int(Date().timeIntervalSince(timestamp)))
        return age < 2 ? "最近预览" : "最近 · \(age)秒"
    }
}
