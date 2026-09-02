import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

private struct DockEdgeProtectionDisplaySnapshot: Sendable {
    let uuid: String
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    func contains(_ point: CGPoint) -> Bool {
        let x = Double(point.x)
        let y = Double(point.y)
        // Quartz display bounds are half-open. Keeping that convention means
        // a point exactly on a vertical display seam belongs to the display
        // below it rather than being mistaken for the upper display's edge.
        return x >= minX && x < maxX && y >= minY && y < maxY
    }
}

private struct DockEdgeProtectionSnapshot: Sendable {
    let targetUUID: String
    let displays: [DockEdgeProtectionDisplaySnapshot]
    let protectedDepth: Double

    func protectedDisplay(at point: CGPoint) -> DockEdgeProtectionDisplaySnapshot? {
        guard let display = displays.first(where: { $0.contains(point) }),
              display.uuid != targetUUID,
              Double(point.y) >= display.maxY - protectedDepth,
              isExposedBottomEdge(of: display, atX: Double(point.x)) else {
            return nil
        }
        return display
    }

    private func isExposedBottomEdge(
        of display: DockEdgeProtectionDisplaySnapshot,
        atX x: Double
    ) -> Bool {
        let seamTolerance = 1.5
        // Never obstruct a real crossing into a vertically adjacent display.
        // Only physical bottom edges can summon the per-display Dock anyway.
        return !displays.contains { other in
            guard other.uuid != display.uuid,
                  abs(other.minY - display.maxY) <= seamTolerance else { return false }
            return x >= other.minX && x < other.maxX
        }
    }
}

private enum DockEdgeProtectionRecovery: Sendable {
    case timeout
    case disabledByUserInput
}

/// The event-tap callback is not MainActor-isolated. It sees only an immutable
/// geometry snapshot protected by this lock and never reads controller state.
private final class DockEdgeProtectionCallbackState: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotStorage: DockEdgeProtectionSnapshot?
    private var pendingRecoveryStorage: DockEdgeProtectionRecovery?

    func replaceSnapshot(_ snapshot: DockEdgeProtectionSnapshot?) {
        lock.lock()
        snapshotStorage = snapshot
        if snapshot == nil {
            pendingRecoveryStorage = nil
        }
        lock.unlock()
    }

    func snapshot() -> DockEdgeProtectionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotStorage
    }

    /// Returns true only for the first callback requesting recovery. This keeps
    /// a timed-out tap from flooding the main run loop with restart requests.
    func requestRecovery(_ recovery: DockEdgeProtectionRecovery) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard snapshotStorage != nil,
              pendingRecoveryStorage == nil else { return false }
        pendingRecoveryStorage = recovery
        return true
    }

    func consumeRecovery() -> DockEdgeProtectionRecovery? {
        lock.lock()
        defer { lock.unlock() }
        let recovery = pendingRecoveryStorage
        pendingRecoveryStorage = nil
        return recovery
    }
}

private let dockEdgeProtectionRecoveryNotification = Notification.Name(
    "SuperIsland.DockEdgeProtection.EventTapRecovery"
)

private func dockEdgeProtectionEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<DockEdgeProtectionCallbackState>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let recovery: DockEdgeProtectionRecovery = type == .tapDisabledByTimeout
            ? .timeout
            : .disabledByUserInput
        if state.requestRecovery(recovery) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: dockEdgeProtectionRecoveryNotification,
                    object: state
                )
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .mouseMoved,
          let snapshot = state.snapshot(),
          let display = snapshot.protectedDisplay(at: event.location) else {
        return Unmanaged.passUnretained(event)
    }

    // Drag events are not part of the tap mask. The additional hardware-state
    // check protects unusual drivers that still label a pressed move as
    // mouseMoved, so window/file dragging is never trapped at a display edge.
    let buttonIsPressed = CGEventSource.buttonState(.combinedSessionState, button: .left) ||
        CGEventSource.buttonState(.combinedSessionState, button: .right) ||
        CGEventSource.buttonState(.combinedSessionState, button: .center)
    guard !buttonIsPressed else { return Unmanaged.passUnretained(event) }

    var clampedPoint = event.location
    clampedPoint.y = CGFloat(display.maxY - snapshot.protectedDepth - 1)
    event.location = clampedPoint
    event.setIntegerValueField(.mouseEventDeltaY, value: 0)
    return Unmanaged.passUnretained(event)
}

enum DockDisplayLockPhase: String, Equatable {
    case disabled
    case idle
    case moving
    case locked
    case paused
    case failed

    var title: String {
        switch self {
        case .disabled: "能力已关闭"
        case .idle: "未固定"
        case .moving: "正在固定"
        case .locked: "已固定"
        case .paused: "固定已暂停"
        case .failed: "固定失败"
        }
    }
}

struct DockDisplayLockStatus: Equatable {
    let phase: DockDisplayLockPhase
    let targetDisplayName: String?
    let actualDisplayName: String?
    let actualDisplayIsVerified: Bool
    let message: String?

    static let idle = DockDisplayLockStatus(
        phase: .idle,
        targetDisplayName: nil,
        actualDisplayName: nil,
        actualDisplayIsVerified: false,
        message: "点击“固定到鼠标所在显示器”选择目标"
    )

    var summary: String {
        if phase == .locked, let targetDisplayName {
            return "已固定到“\(targetDisplayName)”"
        }
        return phase.title
    }

    var detail: String {
        var parts: [String] = []
        if phase != .locked, let targetDisplayName {
            parts.append("目标：\(targetDisplayName)")
        }
        if let actualDisplayName {
            let label = actualDisplayIsVerified ? "实际" : "上次读取"
            parts.append("\(label)：\(actualDisplayName)")
        }
        if let message, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class DockDisplayLockStatusStore: ObservableObject {
    static let shared = DockDisplayLockStatusStore()

    @Published private(set) var status: DockDisplayLockStatus = .idle

    private init() {}

    fileprivate func publish(_ status: DockDisplayLockStatus) {
        guard self.status != status else { return }
        self.status = status
    }
}

/// Moves the system Dock through macOS' native bottom-edge interaction only
/// after an explicit user action, then verifies it against a stable display
/// UUID. Once verified, a narrow event tap clamps only exposed bottom-edge
/// movement on non-target displays; background work never synthesizes events,
/// moves the Dock, or touches user windows.
enum DockDisplayLockActivityPolicy {
    static func shouldRunGuardTimer(
        started: Bool,
        featureEnabled: Bool,
        requested: Bool,
        suspendedForSleep: Bool
    ) -> Bool {
        started && featureEnabled && requested && !suspendedForSleep
    }
}

@MainActor
final class DockDisplayLockController {
    private struct DisplayTarget: Equatable {
        let id: CGDirectDisplayID
        let uuid: String
        let bounds: CGRect
        let name: String
    }

    private enum PreferenceKey {
        static let requested = "windowEnhancement.dockDisplayLock.enabled"
        static let targetUUID = "windowEnhancement.dockDisplayLock.targetUUID"
        static let targetHistory = "windowEnhancement.dockDisplayLock.targetUUIDs"
    }

    private enum Prerequisite: String, CaseIterable {
        case multipleDisplays
        case accessibility
        case separateSpaces
        case autoHideDisabled
        case dockAtBottom

        var message: String {
            switch self {
            case .multipleDisplays:
                return "至少需要连接两台显示器"
            case .accessibility:
                return "请在系统设置中允许 SuperIsland 使用辅助功能"
            case .separateSpaces:
                return "请在桌面与程序坞设置中开启“显示器具有单独的空间”"
            case .autoHideDisabled:
                return "请关闭 Dock 自动隐藏"
            case .dockAtBottom:
                return "请将 Dock 放在屏幕底部"
            }
        }
    }

    private enum DockReadback {
        case onDisplay(String)
        case unavailable(String)
    }

    private enum EdgeProtectionConfirmation {
        case awaitingSecondReadback
        case active
        case unavailable(String)
    }

    private struct DockFrameCandidate {
        let score: Int
        let frame: CGRect
        let depth: Int
        let role: String
        let hasExplicitDockMarker: Bool
    }

    private struct DockFrameKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(_ frame: CGRect) {
            x = Int(frame.origin.x.rounded())
            y = Int(frame.origin.y.rounded())
            width = Int(frame.width.rounded())
            height = Int(frame.height.rounded())
        }
    }

    /// A target picked by the user is provisional until the Dock AX frame has
    /// been read back on that display. Keeping the previous committed intent
    /// here makes target changes a two-phase transaction instead of replacing a
    /// working lock before the candidate has proved usable.
    private struct TargetSelectionTransaction {
        let generation: UInt64
        let candidateUUID: String
        let previousRequested: Bool
        let previousTargetUUID: String?
    }

    /// Synthetic pointer ownership is explicit process state so lifecycle
    /// cancellation can synchronously return the pointer before cancelling the
    /// asynchronous relocation task. `lastSyntheticPoint == nil` means the
    /// transaction has not moved the pointer yet.
    private struct PointerTransaction {
        let generation: UInt64
        let originalPoint: CGPoint
        let targetUUID: String
        var lastSyntheticPoint: CGPoint?
    }

    private let defaults: UserDefaults
    private let feedback: (String) -> Void
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var guardTimer: Timer?
    private var relocationTask: Task<Void, Never>?
    private let edgeProtectionCallbackState = DockEdgeProtectionCallbackState()
    private var edgeProtectionEventTap: CFMachPort?
    private var edgeProtectionRunLoopSource: CFRunLoopSource?
    private var edgeProtectionConfirmationUUID: String?
    private var edgeProtectionConfirmationCount = 0
    private var edgeProtectionInstallRetryAfter: Date?
    private var started = false
    private var featureEnabled = false
    private var suspendedForSleep = false
    private var requested = false
    private var targetUUID: String?
    private var targetSelectionTransaction: TargetSelectionTransaction?
    private var pointerTransaction: PointerTransaction?
    private var generation: UInt64 = 0
    private var lastReportedCondition: String?
    private var lastActualDisplayUUID: String?
    private var lastReadbackWasAvailable = false
    private var lastFailureReason: String?

    nonisolated private static let dockBundleIdentifier = "com.apple.dock"
    private static let verificationAttempts = 8
    private static let verificationIntervalNanoseconds: UInt64 = 140_000_000
    private static let edgeDriveIntervalNanoseconds: UInt64 = 110_000_000
    private static let edgeHoldNanoseconds: UInt64 = 260_000_000
    private static let postRestoreVerificationCount = 2
    private static let readbackMinimumWidth: CGFloat = 80
    private static let bottomEdgeTolerance: CGFloat = 18
    /// macOS only needs the last few physical pixels to transfer a bottom Dock.
    /// Keeping this at six pixels preserves normal pointer travel everywhere
    /// else and is large enough to absorb coarse high-DPI mouse deltas.
    private static let edgeProtectionDepth = 6.0
    private static let edgeProtectionInstallRetryInterval: TimeInterval = 5

    init(
        defaults: UserDefaults = .standard,
        feedback: @escaping (String) -> Void
    ) {
        self.defaults = defaults
        self.feedback = feedback
        requested = defaults.bool(forKey: PreferenceKey.requested)
        targetUUID = defaults.string(forKey: PreferenceKey.targetUUID)
    }

    func start(featureEnabled: Bool) {
        guard !started else {
            updateFeatureEnabled(featureEnabled)
            return
        }
        started = true
        self.featureEnabled = featureEnabled
        installLifecycleObservers()
        updateGuardTimerState()
        refreshActualDisplay()
        if !featureEnabled {
            // An action that was switched off while the App was not running
            // must not silently restore an earlier lock request at launch.
            deactivate(clearTarget: false, report: false)
            publishStatus(.disabled, message: "开启此能力后再选择固定目标")
        } else if requested {
            publishStatus(.paused, message: "正在确认上次已验证的固定目标")
            scheduleReadback(after: 0.6, reason: "启动确认")
        } else {
            publishStatus(.idle, message: "点击“固定到鼠标所在显示器”选择目标")
        }
    }

    /// Stops process-owned observation. Persisted user intent remains so an App
    /// relaunch can resume it; with this process gone, no event is intercepted
    /// and the Dock immediately follows normal macOS behavior.
    func stop() {
        invalidatePendingWork()
        guardTimer?.invalidate()
        guardTimer = nil
        lifecycleObservers.forEach { center, observer in
            center.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        suspendedForSleep = false
        featureEnabled = false
        started = false
    }

    func updateFeatureEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else { return }
        featureEnabled = enabled
        updateGuardTimerState()
        if enabled {
            // Disabling the action is a real deactivation. Re-enabling only
            // arms the capability and never resurrects a stale lock request.
            publishStatus(.idle, message: "点击“固定到鼠标所在显示器”选择目标")
        } else {
            deactivate(clearTarget: false, report: requested)
            refreshActualDisplay()
            publishStatus(.disabled, message: "固定请求已解除")
        }
    }

    /// Selects the display under the pointer, moves the Dock, verifies the Dock
    /// AX frame and only then persists the lock. Calling it again changes the
    /// target; it never toggles or locks the macOS login session.
    func moveAndLockToPointerDisplay() {
        guard featureEnabled else {
            publishStatus(.disabled, message: "请先开启 Dock 固定能力")
            feedback("Dock 固定到显示器已关闭")
            return
        }
        guard relocationTask == nil, pointerTransaction == nil else {
            feedback("Dock 固定操作正在进行，请完成后再试")
            return
        }
        let unmet = unmetPrerequisites()
        guard unmet.isEmpty else {
            deactivateEdgeProtection(resetVerification: true)
            let reason = prerequisiteMessage(unmet)
            lastFailureReason = reason
            refreshActualDisplay()
            publishStatus(.failed, message: reason)
            feedback(reason)
            return
        }
        // Capture the user's real pointer once, before any synthetic event can
        // run. Both the target display and the eventual restore point come from
        // this immutable snapshot, so a repeated shortcut cannot select the
        // synthetic edge point as a new target.
        guard let originalPoint = currentPointerLocation(),
              let target = displayTarget(containing: originalPoint) else {
            let reason = "无法确定鼠标所在显示器，Dock 未移动"
            lastFailureReason = reason
            publishStatus(.failed, message: reason)
            feedback(reason)
            return
        }

        lastReportedCondition = nil
        refreshActualDisplay()
        publishStatus(.moving, target: target, message: "正在验证 Dock 位置")
        beginRelocation(
            to: target,
            originalPoint: originalPoint,
            reason: "快捷键",
            reportSuccess: true,
            targetSelection: true
        )
    }

    private func deactivate(clearTarget: Bool, report: Bool) {
        let wasRequested = requested
        invalidatePendingWork()
        requested = false
        defaults.set(false, forKey: PreferenceKey.requested)
        updateGuardTimerState()
        if clearTarget {
            targetUUID = nil
            defaults.removeObject(forKey: PreferenceKey.targetUUID)
        }
        lastReportedCondition = nil
        if report, wasRequested {
            feedback("Dock 显示器固定已关闭，已恢复 macOS 原生行为")
        }
    }

    private func invalidatePendingWork() {
        // Pointer recovery is deliberately synchronous. Cancelling the Task
        // alone would leave it suspended in Task.sleep with the cursor parked at
        // the Dock edge until the executor happened to resume it.
        deactivateEdgeProtection(resetVerification: true)
        cancelPointerTransaction()
        targetSelectionTransaction = nil
        generation &+= 1
        if generation == 0 { generation = 1 }
        relocationTask?.cancel()
        relocationTask = nil
    }

    private func installLifecycleObservers() {
        let appCenter = NotificationCenter.default
        let edgeProtectionObserver = appCenter.addObserver(
            forName: dockEdgeProtectionRecoveryNotification,
            object: edgeProtectionCallbackState,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEdgeProtectionRecovery()
            }
        }
        lifecycleObservers.append((appCenter, edgeProtectionObserver))

        let screenObserver = appCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.invalidatePendingWork()
                self.refreshActualDisplay()
                if self.requested {
                    self.publishStatus(.paused, message: "显示器配置已变化，正在重新确认目标")
                }
                self.scheduleReadback(after: 0.8, reason: "显示器配置变化")
            }
        }
        lifecycleObservers.append((appCenter, screenObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.suspendedForSleep = true
                self.updateGuardTimerState()
                self.invalidatePendingWork()
            }
        }
        lifecycleObservers.append((workspaceCenter, sleepObserver))

        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.suspendedForSleep = false
                self.updateGuardTimerState()
                self.refreshActualDisplay()
                if self.requested {
                    self.publishStatus(.paused, message: "睡眠唤醒后正在重新确认目标")
                }
                self.scheduleReadback(after: 1.2, reason: "睡眠唤醒")
            }
        }
        lifecycleObservers.append((workspaceCenter, wakeObserver))

        // Dock is relaunched by launchd after a crash, settings change or OS
        // update. Observing all application launches/terminations is cheap; the
        // reassertion itself first performs an AX readback and is generation-safe.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    application.bundleIdentifier == Self.dockBundleIdentifier else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.invalidatePendingWork()
                    self.refreshActualDisplay()
                    if self.requested {
                        self.publishStatus(.paused, message: "Dock 已重新启动，正在重新确认目标")
                    }
                    self.scheduleReadback(after: 0.8, reason: "Dock 重新启动")
                }
            }
            lifecycleObservers.append((workspaceCenter, observer))
        }
    }

    private func installGuardTimer() {
        guard guardTimer == nil else { return }
        let timer = Timer(timeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.guardTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
    }

    private func updateGuardTimerState() {
        let shouldRun = DockDisplayLockActivityPolicy.shouldRunGuardTimer(
            started: started,
            featureEnabled: featureEnabled,
            requested: requested,
            suspendedForSleep: suspendedForSleep
        )
        if shouldRun {
            installGuardTimer()
        } else {
            guardTimer?.invalidate()
            guardTimer = nil
        }
    }

    private func confirmEdgeProtectionReadback(
        for target: DisplayTarget,
        explicitRelocationAlreadyDoubleVerified: Bool = false
    ) -> EdgeProtectionConfirmation {
        guard started, featureEnabled, requested, !suspendedForSleep,
              targetUUID == target.uuid else {
            deactivateEdgeProtection(resetVerification: true)
            return .unavailable("Dock 持续固定条件已失效")
        }

        if isEdgeProtectionActive(for: target.uuid) {
            edgeProtectionConfirmationUUID = target.uuid
            edgeProtectionConfirmationCount = 2
            return .active
        }

        if explicitRelocationAlreadyDoubleVerified {
            edgeProtectionConfirmationUUID = target.uuid
            edgeProtectionConfirmationCount = 2
        } else if edgeProtectionConfirmationUUID == target.uuid {
            edgeProtectionConfirmationCount = min(2, edgeProtectionConfirmationCount + 1)
        } else {
            edgeProtectionConfirmationUUID = target.uuid
            edgeProtectionConfirmationCount = 1
        }

        guard edgeProtectionConfirmationCount >= 2 else {
            return .awaitingSecondReadback
        }
        if let retryAfter = edgeProtectionInstallRetryAfter,
           retryAfter > Date() {
            return .unavailable("Dock 已在目标显示器，但持续底边保护正在等待安全重试")
        }
        if let failure = installEdgeProtectionEventTap(for: target) {
            return .unavailable(failure)
        }
        return .active
    }

    /// Returns nil after installing the tap; otherwise returns a user-facing
    /// reason. No permission prompt is triggered here—installation either uses
    /// the authority already granted to this exact App bundle or fails closed.
    private func installEdgeProtectionEventTap(for target: DisplayTarget) -> String? {
        guard started, featureEnabled, requested, !suspendedForSleep,
              targetUUID == target.uuid,
              displayTarget(uuid: target.uuid) != nil else {
            return "Dock 持续固定条件已失效"
        }
        guard AXIsProcessTrusted() else {
            return "持续底边保护未启用：辅助功能权限未生效"
        }
        if isEdgeProtectionActive(for: target.uuid) { return nil }

        stopEdgeProtectionEventTap()
        let displays = onlineDisplayTargets().map { display in
            DockEdgeProtectionDisplaySnapshot(
                uuid: display.uuid,
                minX: Double(display.bounds.minX),
                minY: Double(display.bounds.minY),
                maxX: Double(display.bounds.maxX),
                maxY: Double(display.bounds.maxY)
            )
        }
        guard displays.count >= 2,
              displays.contains(where: { $0.uuid == target.uuid }) else {
            return "持续底边保护未启用：目标显示器已断开"
        }

        let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dockEdgeProtectionEventTapCallback,
            userInfo: Unmanaged.passUnretained(edgeProtectionCallbackState).toOpaque()
        ) else {
            edgeProtectionInstallRetryAfter = Date().addingTimeInterval(
                Self.edgeProtectionInstallRetryInterval
            )
            return "Dock 已在目标显示器，但持续底边保护无法启动；请确认辅助功能权限"
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            edgeProtectionInstallRetryAfter = Date().addingTimeInterval(
                Self.edgeProtectionInstallRetryInterval
            )
            return "Dock 已在目标显示器，但持续底边保护初始化失败"
        }

        let snapshot = DockEdgeProtectionSnapshot(
            targetUUID: target.uuid,
            displays: displays,
            protectedDepth: Self.edgeProtectionDepth
        )
        edgeProtectionEventTap = eventTap
        edgeProtectionRunLoopSource = runLoopSource
        edgeProtectionCallbackState.replaceSnapshot(snapshot)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        guard CGEvent.tapIsEnabled(tap: eventTap) else {
            stopEdgeProtectionEventTap()
            edgeProtectionInstallRetryAfter = Date().addingTimeInterval(
                Self.edgeProtectionInstallRetryInterval
            )
            return "Dock 已在目标显示器，但持续底边保护未能启用"
        }
        edgeProtectionInstallRetryAfter = nil
        return nil
    }

    private func isEdgeProtectionActive(for targetUUID: String) -> Bool {
        guard let eventTap = edgeProtectionEventTap,
              edgeProtectionRunLoopSource != nil,
              CFMachPortIsValid(eventTap),
              CGEvent.tapIsEnabled(tap: eventTap),
              edgeProtectionCallbackState.snapshot()?.targetUUID == targetUUID else {
            return false
        }
        return true
    }

    private func stopEdgeProtectionEventTap() {
        // Clear the callback snapshot first. If invalidation races a timeout
        // callback, that callback becomes a no-op and cannot resurrect the tap.
        edgeProtectionCallbackState.replaceSnapshot(nil)
        if let eventTap = edgeProtectionEventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = edgeProtectionRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap = edgeProtectionEventTap {
            CFMachPortInvalidate(eventTap)
        }
        edgeProtectionRunLoopSource = nil
        edgeProtectionEventTap = nil
    }

    private func deactivateEdgeProtection(resetVerification: Bool) {
        stopEdgeProtectionEventTap()
        edgeProtectionInstallRetryAfter = nil
        if resetVerification {
            edgeProtectionConfirmationUUID = nil
            edgeProtectionConfirmationCount = 0
        }
    }

    private func handleEdgeProtectionRecovery() {
        guard let recovery = edgeProtectionCallbackState.consumeRecovery() else { return }
        switch recovery {
        case .disabledByUserInput:
            deactivateEdgeProtection(resetVerification: true)
            let reason = "Dock 持续固定已暂停：系统停用了鼠标事件保护，请确认辅助功能权限"
            lastFailureReason = reason
            let target = targetUUID.flatMap(displayTarget(uuid:))
            publishStatus(.paused, target: target, message: reason)
            reportConditionOnce("edge-protection-disabled", reason)

        case .timeout:
            // A timeout is recovered only after revalidating the committed
            // target and Dock AX frame. It never moves the pointer or the Dock.
            stopEdgeProtectionEventTap()
            guard started, featureEnabled, requested, !suspendedForSleep,
                  relocationTask == nil,
                  AXIsProcessTrusted(),
                  let targetUUID,
                  let target = displayTarget(uuid: targetUUID),
                  unmetPrerequisites().isEmpty,
                  case .onDisplay(target.uuid) = dockReadback() else {
                deactivateEdgeProtection(resetVerification: true)
                let reason = "Dock 持续固定已暂停：事件保护超时后无法安全确认目标"
                lastFailureReason = reason
                publishStatus(.paused, message: reason)
                reportConditionOnce("edge-protection-timeout-unverified", reason)
                return
            }
            edgeProtectionConfirmationUUID = target.uuid
            edgeProtectionConfirmationCount = 2
            if let failure = installEdgeProtectionEventTap(for: target) {
                lastFailureReason = failure
                publishStatus(.paused, target: target, message: failure)
                reportConditionOnce("edge-protection-timeout-restart", failure)
            } else {
                lastReportedCondition = nil
                lastFailureReason = nil
                publishStatus(.locked, target: target, message: nil)
            }
        }
    }

    private func guardTick() {
        guard started, featureEnabled, requested, !suspendedForSleep,
              relocationTask == nil else { return }
        guard let targetUUID,
              let target = displayTarget(uuid: targetUUID) else {
            deactivateEdgeProtection(resetVerification: true)
            let reason = "Dock 固定目标显示器已断开；重新连接后会重新确认，如有偏离需手动固定"
            lastFailureReason = reason
            publishStatus(.paused, message: reason)
            reportConditionOnce("target-unavailable", reason)
            return
        }
        let unmet = unmetPrerequisites()
        guard unmet.isEmpty else {
            deactivateEdgeProtection(resetVerification: true)
            let reason = "Dock 固定已暂停：\(prerequisiteMessage(unmet))"
            lastFailureReason = reason
            publishStatus(.paused, target: target, message: reason)
            reportConditionOnce(
                "prerequisites-\(unmet.map(\.rawValue).joined(separator: ","))",
                reason
            )
            return
        }
        switch dockReadback() {
        case .onDisplay(target.uuid):
            switch confirmEdgeProtectionReadback(for: target) {
            case .awaitingSecondReadback:
                publishStatus(
                    .paused,
                    target: target,
                    message: "Dock 已在目标显示器，正在进行持续固定复核"
                )
            case .active:
                lastReportedCondition = nil
                lastFailureReason = nil
                publishStatus(.locked, target: target, message: nil)
            case let .unavailable(reason):
                lastFailureReason = reason
                publishStatus(.paused, target: target, message: reason)
                reportConditionOnce("edge-protection-install", reason)
            }
        case let .onDisplay(actualUUID):
            deactivateEdgeProtection(resetVerification: true)
            let actualName = displayTarget(uuid: actualUUID)?.name ?? "其他显示器"
            let reason = "Dock 当前在“\(actualName)”；请把鼠标移到目标显示器并点击“固定到鼠标所在显示器”"
            lastFailureReason = reason
            publishStatus(.paused, target: target, message: reason)
            reportConditionOnce("dock-drift-\(actualUUID)", reason)
        case let .unavailable(reason):
            // A restarting Dock briefly has no AX hierarchy. Do not drive the
            // pointer until a later timer tick can identify and verify it.
            deactivateEdgeProtection(resetVerification: true)
            lastFailureReason = reason
            publishStatus(.paused, target: target, message: reason)
            reportConditionOnce("dock-readback", reason)
        }
    }

    /// Lifecycle recovery never drives the pointer or the Dock. Two stable AX
    /// readbacks may restore the narrow edge-protection tap; an actual Dock
    /// drift still requires an explicit button or shortcut action.
    private func scheduleReadback(after delay: TimeInterval, reason: String) {
        guard started, featureEnabled, requested, !suspendedForSleep else { return }
        let expectedGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.started,
                  self.featureEnabled,
                  self.requested,
                  !self.suspendedForSleep,
                  self.relocationTask == nil else { return }
            guard let uuid = self.targetUUID,
                  let target = self.displayTarget(uuid: uuid) else {
                self.deactivateEdgeProtection(resetVerification: true)
                let reason = "Dock 固定目标显示器已断开；重新连接后会重新确认，如有偏离需手动固定"
                self.lastFailureReason = reason
                self.publishStatus(.paused, message: reason)
                self.reportConditionOnce("target-unavailable", reason)
                return
            }
            let unmet = self.unmetPrerequisites()
            guard unmet.isEmpty else {
                self.deactivateEdgeProtection(resetVerification: true)
                let reason = "Dock 固定已暂停：\(self.prerequisiteMessage(unmet))"
                self.lastFailureReason = reason
                self.publishStatus(.paused, target: target, message: reason)
                self.reportConditionOnce(
                    "prerequisites-\(unmet.map(\.rawValue).joined(separator: ","))",
                    reason
                )
                return
            }
            switch self.dockReadback() {
            case .onDisplay(target.uuid):
                switch self.confirmEdgeProtectionReadback(for: target) {
                case .awaitingSecondReadback:
                    self.publishStatus(
                        .paused,
                        target: target,
                        message: "Dock 已在目标显示器，正在进行持续固定复核"
                    )
                case .active:
                    self.lastReportedCondition = nil
                    self.lastFailureReason = nil
                    self.publishStatus(.locked, target: target, message: nil)
                case let .unavailable(failure):
                    self.lastFailureReason = failure
                    self.publishStatus(.paused, target: target, message: failure)
                    self.reportConditionOnce("edge-protection-install", failure)
                }
                return
            case let .onDisplay(actualUUID):
                self.deactivateEdgeProtection(resetVerification: true)
                let actualName = self.displayTarget(uuid: actualUUID)?.name ?? "其他显示器"
                let message = "\(reason)后检测到 Dock 位于“\(actualName)”；请把鼠标移到目标显示器并点击“固定到鼠标所在显示器”"
                self.lastFailureReason = message
                self.publishStatus(.paused, target: target, message: message)
                self.reportConditionOnce("dock-drift-\(actualUUID)", message)
                return
            case let .unavailable(reason):
                self.deactivateEdgeProtection(resetVerification: true)
                self.lastFailureReason = reason
                self.publishStatus(.paused, target: target, message: reason)
                self.reportConditionOnce("dock-readback", reason)
                return
            }
        }
    }

    private func beginRelocation(
        to target: DisplayTarget,
        originalPoint: CGPoint,
        reason: String,
        reportSuccess: Bool,
        targetSelection: Bool
    ) {
        let previousRequested = requested
        let previousTargetUUID = targetUUID
        invalidatePendingWork()
        lastFailureReason = nil
        let operationGeneration = generation
        if targetSelection {
            targetSelectionTransaction = TargetSelectionTransaction(
                generation: operationGeneration,
                candidateUUID: target.uuid,
                previousRequested: previousRequested,
                previousTargetUUID: previousTargetUUID
            )
        }
        relocationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await self.relocateAndVerify(
                target: target,
                originalPoint: originalPoint,
                generation: operationGeneration,
                allowsUncommittedTarget: targetSelection
            )
            guard !Task.isCancelled,
                  self.generation == operationGeneration else { return }
            self.relocationTask = nil
            if success {
                if targetSelection {
                    guard let transaction = self.targetSelectionTransaction,
                          transaction.generation == operationGeneration,
                          transaction.candidateUUID == target.uuid else { return }
                    self.commitTargetSelection(target)
                }
                self.lastReportedCondition = nil
                self.lastFailureReason = nil
                switch self.confirmEdgeProtectionReadback(
                    for: target,
                    explicitRelocationAlreadyDoubleVerified: true
                ) {
                case .active:
                    self.publishStatus(.locked, target: target, message: nil)
                    if reportSuccess {
                        self.feedback("Dock 已移动并固定到“\(target.name)”")
                    }
                case .awaitingSecondReadback:
                    // relocateAndVerify already performed two post-restore
                    // readbacks, so this is defensive rather than expected.
                    self.publishStatus(
                        .paused,
                        target: target,
                        message: "Dock 已移动，正在确认持续固定"
                    )
                case let .unavailable(failure):
                    self.lastFailureReason = failure
                    self.publishStatus(.paused, target: target, message: failure)
                    self.reportConditionOnce("edge-protection-install", failure)
                    if reportSuccess {
                        self.feedback("Dock 已移动到“\(target.name)”，但\(failure)")
                    }
                }
            } else {
                let failedSelection = self.targetSelectionTransaction.flatMap { transaction in
                    transaction.generation == operationGeneration ? transaction : nil
                }
                self.targetSelectionTransaction = nil
                if let failedSelection,
                   failedSelection.previousRequested,
                   let previousTargetUUID = failedSelection.previousTargetUUID {
                    let previousTarget = self.displayTarget(uuid: previousTargetUUID)
                    let failure = self.lastFailureReason ?? "新目标未通过位置回读"
                    let reason = "\(failure)；已保留此前固定目标"
                    self.lastFailureReason = reason
                    self.publishStatus(.paused, target: previousTarget, message: reason)
                    self.reportConditionOnce(
                        "target-switch-failed-\(target.uuid)",
                        "Dock 未通过新目标位置回读验证，已保留此前固定目标；请将鼠标移到该显示器后手动恢复"
                    )
                } else {
                    let failureReason = self.lastFailureReason ?? "Dock 未通过位置回读验证（\(reason)）"
                    self.lastFailureReason = failureReason
                    if targetSelection {
                        self.publishStatus(.failed, target: target, message: failureReason)
                    }
                    self.reportConditionOnce(
                        "relocate-failed-\(target.uuid)",
                        "Dock 未通过位置回读验证，未报告为固定成功（\(reason)）"
                    )
                }
            }
        }
    }

    private func commitTargetSelection(_ target: DisplayTarget) {
        requested = true
        targetUUID = target.uuid
        defaults.set(true, forKey: PreferenceKey.requested)
        defaults.set(target.uuid, forKey: PreferenceKey.targetUUID)
        appendTargetHistory(target.uuid)
        targetSelectionTransaction = nil
        updateGuardTimerState()
    }

    private func relocateAndVerify(
        target: DisplayTarget,
        originalPoint: CGPoint,
        generation: UInt64,
        allowsUncommittedTarget: Bool
    ) async -> Bool {
        guard isCurrent(generation, allowsUncommittedTarget: allowsUncommittedTarget),
              displayTarget(uuid: target.uuid) != nil else {
            return failRelocation("固定操作已取消或目标显示器已断开")
        }
        if case .onDisplay(target.uuid) = dockReadback() { return true }
        guard let pointerBeforeFirstSyntheticMove = currentPointerLocation(),
              distance(pointerBeforeFirstSyntheticMove, originalPoint) <= 16 else {
            return failRelocation("目标确认期间鼠标已移动，未执行 Dock 固定")
        }

        pointerTransaction = PointerTransaction(
            generation: generation,
            originalPoint: originalPoint,
            targetUUID: target.uuid,
            lastSyntheticPoint: nil
        )
        defer { finishPointerTransaction(generation: generation) }

        let edgeX = target.bounds.midX
        // macOS' per-display Dock gesture depends on continued downward
        // movement. Reposting the exact same bottom-edge point does not carry
        // a movement delta and is ignored on some display arrangements.
        let edgeOffsets: [CGFloat] = [24, 18, 13, 9, 6, 3, 1]
        for offset in edgeOffsets {
            guard isCurrent(generation, allowsUncommittedTarget: allowsUncommittedTarget) else {
                return failRelocation("固定操作已取消")
            }
            let point = CGPoint(x: edgeX, y: target.bounds.maxY - offset)
            guard postSyntheticPointerMove(to: point, generation: generation) else {
                return failRelocation("无法将鼠标安全移动到目标显示器底边")
            }
            try? await Task.sleep(nanoseconds: Self.edgeDriveIntervalNanoseconds)
            guard let transaction = pointerTransaction,
                  transaction.generation == generation,
                  let syntheticPoint = transaction.lastSyntheticPoint,
                  let current = currentPointerLocation(),
                  distance(current, syntheticPoint) <= 16 else {
                // The user moved during the operation. Abort instead of taking
                // the cursor back or competing with their Dock choice.
                return failRelocation("检测到用户正在移动鼠标，已中止 Dock 固定")
            }
        }
        // Hold at the activation edge without emitting duplicate zero-delta
        // mouse events. This gives the native Dock gesture a bounded dwell.
        try? await Task.sleep(nanoseconds: Self.edgeHoldNanoseconds)
        guard let heldTransaction = pointerTransaction,
              heldTransaction.generation == generation,
              let heldPoint = heldTransaction.lastSyntheticPoint,
              let pointerAfterHold = currentPointerLocation(),
              distance(pointerAfterHold, heldPoint) <= 16 else {
            return failRelocation("检测到用户正在移动鼠标，已中止 Dock 固定")
        }

        var verified = false
        for _ in 0..<Self.verificationAttempts {
            guard isCurrent(generation, allowsUncommittedTarget: allowsUncommittedTarget) else { break }
            guard let transaction = pointerTransaction,
                  transaction.generation == generation,
                  let syntheticPoint = transaction.lastSyntheticPoint,
                  let current = currentPointerLocation(),
                  distance(current, syntheticPoint) <= 16 else {
                return failRelocation("检测到用户正在移动鼠标，已中止 Dock 固定")
            }
            if case .onDisplay(target.uuid) = dockReadback() {
                verified = true
                break
            }
            try? await Task.sleep(nanoseconds: Self.verificationIntervalNanoseconds)
        }

        guard verified else {
            return failRelocation("Dock 未出现在目标显示器，位置回读未通过")
        }
        guard finishPointerTransaction(generation: generation) else {
            return failRelocation("Dock 已移动，但鼠标位置未能安全恢复")
        }
        guard isCurrent(generation, allowsUncommittedTarget: allowsUncommittedTarget) else {
            return failRelocation("固定操作已取消")
        }
        // Two consecutive readbacks after pointer restoration prevent a
        // transient intermediate Dock frame from being accepted as success.
        for _ in 0..<Self.postRestoreVerificationCount {
            try? await Task.sleep(nanoseconds: Self.verificationIntervalNanoseconds)
            guard isCurrent(generation, allowsUncommittedTarget: allowsUncommittedTarget),
                  case .onDisplay(target.uuid) = dockReadback() else {
                return failRelocation("恢复鼠标后 Dock 位置回读不稳定，未确认固定成功")
            }
        }
        return true
    }

    private func failRelocation(_ reason: String) -> Bool {
        lastFailureReason = reason
        return false
    }

    private func isCurrent(
        _ operationGeneration: UInt64,
        allowsUncommittedTarget: Bool
    ) -> Bool {
        let hasCurrentIntent = requested || (
            allowsUncommittedTarget &&
                targetSelectionTransaction?.generation == operationGeneration
        )
        return !Task.isCancelled &&
            operationGeneration == generation &&
            started && featureEnabled && hasCurrentIntent && !suspendedForSleep
    }

    private func postSyntheticPointerMove(to point: CGPoint, generation: UInt64) -> Bool {
        guard var transaction = pointerTransaction,
              transaction.generation == generation,
              postPointerMove(to: point) else { return false }
        transaction.lastSyntheticPoint = point
        pointerTransaction = transaction
        return true
    }

    @discardableResult
    private func finishPointerTransaction(generation: UInt64) -> Bool {
        guard let transaction = pointerTransaction,
              transaction.generation == generation else { return true }
        pointerTransaction = nil
        return restorePointerIfStillSynthetic(transaction)
    }

    private func cancelPointerTransaction() {
        guard let transaction = pointerTransaction else { return }
        pointerTransaction = nil
        _ = restorePointerIfStillSynthetic(transaction)
    }

    private func restorePointerIfStillSynthetic(_ transaction: PointerTransaction) -> Bool {
        guard let syntheticPoint = transaction.lastSyntheticPoint else { return true }
        guard let current = currentPointerLocation(), distance(current, syntheticPoint) <= 16 else {
            // The user moved the pointer during migration; never fight them by
            // warping it back to a stale location.
            return true
        }
        let targets = onlineDisplayTargets()
        guard let restoreDisplay = targets.first(where: {
            $0.bounds.contains(transaction.originalPoint)
        }) ?? targets.min(by: {
            distanceToRect(transaction.originalPoint, $0.bounds) <
                distanceToRect(transaction.originalPoint, $1.bounds)
        }) else {
            feedback("Dock 迁移已结束，但当前没有可用显示器可恢复鼠标位置")
            return false
        }

        // The display containing the original point may have disconnected while
        // the Dock was moving. Project that point into the nearest active Quartz
        // display instead of warping the cursor into now-offline coordinates.
        let safeBounds = restoreDisplay.bounds.insetBy(dx: 2, dy: 2)
        var safePoint = CGPoint(
            x: min(max(transaction.originalPoint.x, safeBounds.minX), safeBounds.maxX),
            y: min(max(transaction.originalPoint.y, safeBounds.minY), safeBounds.maxY)
        )
        if restoreDisplay.uuid != transaction.targetUUID,
           safePoint.y >= restoreDisplay.bounds.maxY - 5 {
            // Restoring directly into another display's Dock activation edge
            // would immediately undo the verified migration.
            safePoint.y = restoreDisplay.bounds.maxY - 14
        }
        guard postPointerMove(to: safePoint),
              let restoredPoint = currentPointerLocation(),
              distance(restoredPoint, safePoint) <= 16 else {
            feedback("Dock 迁移已结束，但鼠标位置未能安全恢复")
            return false
        }
        return true
    }

    private func currentPointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    private func postPointerMove(to point: CGPoint) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func refreshActualDisplay() {
        _ = dockReadback()
    }

    private func publishStatus(
        _ phase: DockDisplayLockPhase,
        target: DisplayTarget? = nil,
        message: String?
    ) {
        let resolvedTarget: DisplayTarget?
        if let target {
            resolvedTarget = target
        } else if requested, let targetUUID {
            resolvedTarget = displayTarget(uuid: targetUUID)
        } else {
            resolvedTarget = nil
        }
        let actualName: String?
        if let lastActualDisplayUUID {
            actualName = displayTarget(uuid: lastActualDisplayUUID)?.name
        } else {
            actualName = nil
        }
        let targetName = resolvedTarget?.name ?? (
            requested && targetUUID != nil ? "已断开的目标显示器" : nil
        )
        DockDisplayLockStatusStore.shared.publish(
            DockDisplayLockStatus(
                phase: phase,
                targetDisplayName: targetName,
                actualDisplayName: actualName,
                actualDisplayIsVerified: lastReadbackWasAvailable,
                message: message
            )
        )
    }

    private func unmetPrerequisites() -> [Prerequisite] {
        var result: [Prerequisite] = []
        if onlineDisplayTargets().count < 2 { result.append(.multipleDisplays) }
        if !AXIsProcessTrusted() { result.append(.accessibility) }
        if preferenceBool(domain: "com.apple.spaces", key: "spans-displays") == true {
            result.append(.separateSpaces)
        }
        if preferenceBool(domain: "com.apple.dock", key: "autohide") == true {
            result.append(.autoHideDisabled)
        }
        let orientation = preferenceString(domain: "com.apple.dock", key: "orientation") ?? "bottom"
        if orientation != "bottom" { result.append(.dockAtBottom) }
        return result
    }

    private func prerequisiteMessage(_ prerequisites: [Prerequisite]) -> String {
        prerequisites.map(\.message).joined(separator: "；")
    }

    private func preferenceBool(domain: String, key: String) -> Bool? {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func preferenceString(domain: String, key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
    }

    private func displayTarget(containing point: CGPoint) -> DisplayTarget? {
        let targets = onlineDisplayTargets()
        if let exact = targets.first(where: { $0.bounds.contains(point) }) { return exact }
        return targets.min { lhs, rhs in
            distanceToRect(point, lhs.bounds) < distanceToRect(point, rhs.bounds)
        }
    }

    private func displayTarget(uuid: String) -> DisplayTarget? {
        onlineDisplayTargets().first { $0.uuid == uuid }
    }

    private func onlineDisplayTargets() -> [DisplayTarget] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsOnline(id) != 0,
                  CGDisplayIsActive(id) != 0,
                  CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = displayUUID(for: id) else { return nil }
            return DisplayTarget(
                id: id,
                uuid: uuid,
                bounds: CGDisplayBounds(id),
                name: screen.localizedName
            )
        }
    }

    private func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }

    private func distanceToRect(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func appendTargetHistory(_ uuid: String) {
        var history = defaults.stringArray(forKey: PreferenceKey.targetHistory) ?? []
        history.removeAll { $0 == uuid }
        history.append(uuid)
        if history.count > 8 { history.removeFirst(history.count - 8) }
        defaults.set(history, forKey: PreferenceKey.targetHistory)
    }

    private func reportConditionOnce(_ signature: String, _ message: String) {
        guard lastReportedCondition != signature else { return }
        lastReportedCondition = signature
        feedback(message)
    }

    private func dockReadback() -> DockReadback {
        guard AXIsProcessTrusted() else {
            lastReadbackWasAvailable = false
            return .unavailable("暂时无法验证 Dock：辅助功能权限未生效")
        }
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.dockBundleIdentifier
        ).first else {
            lastReadbackWasAvailable = false
            return .unavailable("暂时无法验证 Dock：Dock 进程正在重新启动")
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        var candidates: [DockFrameCandidate] = []
        collectDockFrameCandidates(application, depth: 0, visited: [], candidates: &candidates)

        // The same AXList can be reachable through both AXChildren and
        // AXWindows. Collapse identical frames before choosing a root.
        var uniqueByFrame: [DockFrameKey: DockFrameCandidate] = [:]
        for candidate in candidates where displayTarget(forDockFrame: candidate.frame) != nil {
            let key = DockFrameKey(candidate.frame)
            if let existing = uniqueByFrame[key],
               candidateSortsBefore(existing, candidate) {
                continue
            }
            uniqueByFrame[key] = candidate
        }

        let uniqueCandidates = Array(uniqueByFrame.values)
        let rootLists = uniqueCandidates.filter { $0.role == kAXListRole as String }
        let explicitFallbacks = uniqueCandidates.filter(\.hasExplicitDockMarker)
        let pool = !rootLists.isEmpty ? rootLists : explicitFallbacks
        guard let candidate = pool.sorted(by: candidateSortsBefore).first,
              let target = displayTarget(forDockFrame: candidate.frame) else {
            lastReadbackWasAvailable = false
            return .unavailable("暂时无法验证 Dock 所在显示器，固定已暂停而不是假定成功")
        }
        lastActualDisplayUUID = target.uuid
        lastReadbackWasAvailable = true
        return .onDisplay(target.uuid)
    }

    private func candidateSortsBefore(
        _ lhs: DockFrameCandidate,
        _ rhs: DockFrameCandidate
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        if lhs.frame.width != rhs.frame.width { return lhs.frame.width > rhs.frame.width }
        return lhs.frame.height > rhs.frame.height
    }

    private func collectDockFrameCandidates(
        _ element: AXUIElement,
        depth: Int,
        visited: Set<CFHashCode>,
        candidates: inout [DockFrameCandidate]
    ) {
        guard depth <= 3 else { return }
        let identity = CFHash(element)
        guard !visited.contains(identity) else { return }
        var visited = visited
        visited.insert(identity)
        let role = axString(kAXRoleAttribute, of: element) ?? ""
        let subrole = axString(kAXSubroleAttribute, of: element) ?? ""
        let identifier = axString(kAXIdentifierAttribute, of: element) ?? ""
        let description = axString(kAXDescriptionAttribute, of: element) ?? ""
        let hasExplicitDockMarker = subrole.localizedCaseInsensitiveContains("dock") ||
            identifier.localizedCaseInsensitiveContains("dock") ||
            description.localizedCaseInsensitiveContains("dock")
        if let frame = axFrame(of: element),
           frame.width >= Self.readbackMinimumWidth,
           frame.height > 0,
           frame.height <= 420 {
            var score = 0
            if role == kAXListRole as String { score += 50 }
            if subrole.localizedCaseInsensitiveContains("dock") { score += 80 }
            if identifier.localizedCaseInsensitiveContains("dock") { score += 40 }
            if description.localizedCaseInsensitiveContains("dock") { score += 20 }
            if onlineDisplayTargets().contains(where: {
                abs(frame.maxY - $0.bounds.maxY) <= Self.bottomEdgeTolerance
            }) { score += 30 }
            if depth == 1 { score += 15 }
            if score > 0 {
                candidates.append(
                    DockFrameCandidate(
                        score: score,
                        frame: frame,
                        depth: depth,
                        role: role,
                        hasExplicitDockMarker: hasExplicitDockMarker
                    )
                )
            }
        }

        guard depth < 3 else { return }
        var descendants: [AXUIElement] = axValue(kAXChildrenAttribute, of: element) ?? []
        let windows: [AXUIElement] = axValue(kAXWindowsAttribute, of: element) ?? []
        descendants.append(contentsOf: windows)
        for child in descendants.prefix(80) {
            collectDockFrameCandidates(
                child,
                depth: depth + 1,
                visited: visited,
                candidates: &candidates
            )
        }
    }

    private func displayTarget(forDockFrame frame: CGRect) -> DisplayTarget? {
        let targets = onlineDisplayTargets()
        let intersections = targets.compactMap { target -> (DisplayTarget, CGFloat)? in
            let area = frame.intersection(target.bounds).dockDisplayLockArea
            guard area > 0,
                  abs(frame.maxY - target.bounds.maxY) <= Self.bottomEdgeTolerance else {
                return nil
            }
            return (target, area)
        }
        // A Dock root belongs to one display. Refuse ambiguous spanning frames
        // instead of choosing a display by accident and reporting false success.
        guard intersections.count == 1 else { return nil }
        return intersections[0].0
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = axValue(kAXPositionAttribute, of: element),
              let sizeValue: AXValue = axValue(kAXSizeAttribute, of: element),
              AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func axString(_ attribute: String, of element: AXUIElement) -> String? {
        axValue(attribute, of: element)
    }

    private func axValue<T>(_ attribute: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }
}

private extension CGRect {
    var dockDisplayLockArea: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
