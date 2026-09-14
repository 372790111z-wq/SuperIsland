import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class WindowEnhancementController {
    static let shared = WindowEnhancementController()

    private let preferences = WindowEnhancementPreferences.shared
    private let hotKeys = WindowHotKeyRegistry()
    private let feedbackPresenter = WindowEnhancementFeedbackPresenter()
    private let minimizationSessions = WindowMinimizationSessionController()
    private lazy var dragInteractionMonitor = WindowDragInteractionMonitor(controller: self)
    private let dockInteractionMonitor = WindowDockInteractionMonitor()
    private let commandTabMonitor = WindowCommandTabMonitor()
    private let missionControlMonitor = MissionControlInteractionMonitor()
    private lazy var dockDisplayLockController = DockDisplayLockController { [weak self] message in
        self?.feedback(message)
    }
    private var preferencesCancellable: AnyCancellable?
    private var reconfigureWorkItem: DispatchWorkItem?
    private var lastHotKeyFailureSignature: String?
    private var didReportAccessibilityRequirement = false
    private var activeWindowMutationTask: Task<Void, Never>?
    private var windowMutationGeneration: UInt64 = 0
    private var hideFeedbackWhenWindowMutationFinishes = false
    private var preparingForTermination = false
    private var windowMutationIntent: WindowMutationIntent = .commit
    private var lastWindowMutationCompletion: WindowMutationCompletion = .committed

    private static let geometryTolerance: CGFloat = 2
    private static let fullScreenTransitionTimeout: TimeInterval = 4
    private static let fullScreenReconciliationQuietDuration = fullScreenTransitionTimeout
    private static let fullScreenReconciliationMaximumDuration = fullScreenTransitionTimeout * 2
    private static let fullScreenPollNanoseconds: UInt64 = 80_000_000
    private static let windowedLayoutPollNanoseconds: UInt64 = 25_000_000
    /// Finder and other AppKit Apps may continue their native tile/title-bar
    /// mouse-up bookkeeping for several hundred milliseconds. Keep this
    /// bounded, but do not cancel an otherwise valid island drop at 300ms.
    private static let windowedLayoutPreparationTimeout: TimeInterval = 0.90
    private static let windowedLayoutPreparationQuietDuration: TimeInterval = 0.10
    // Hard cap must leave a full verification window after a delayed App
    // overwrite. With 0.35s quiet, 0.90s covers a change arriving around
    // 0.30s and still leaves bounded time for convergence.
    private static let windowedLayoutAttemptTimeout: TimeInterval = 0.90
    /// Finder and other AppKit Apps can overwrite an accepted AX frame near
    /// the end of their mouse-up animation. A full post-write quiet window
    /// prevents an early exact readback from being reported as success before
    /// that delayed write arrives.
    private static let windowedLayoutVerificationQuietDuration: TimeInterval = 0.35
    /// A native tile group can accept the requested frame, remain exact for
    /// the normal quiet window, and then restore its own geometry slightly
    /// later. Hold an exact result through this bounded guard before reporting
    /// success. If it drifts, the existing second attempt becomes the one
    /// authoritative repair instead of requiring the user to choose another
    /// layout first.
    private static let windowedLayoutLateVerificationDuration: TimeInterval = 0.70

    private init() {
        hotKeys.onTrigger = { [weak self] target in
            Task { @MainActor in self?.execute(targetID: target) }
        }
    }

    func beginZilanSuppression(requestID: String) -> Bool {
        ZilanSuppressionAcquisition.acquire([
            .init(acquire: { self.missionControlMonitor.beginZilanSuppression(requestID: requestID) },
                  rollback: { self.missionControlMonitor.endZilanSuppression(requestID: requestID) }),
            .init(acquire: { self.commandTabMonitor.beginZilanSuppression(requestID: requestID) },
                  rollback: { self.commandTabMonitor.endZilanSuppression(requestID: requestID) }),
        ])
    }

    func endZilanSuppression(requestID: String) {
        commandTabMonitor.endZilanSuppression(requestID: requestID)
        missionControlMonitor.endZilanSuppression(requestID: requestID)
    }

    func start() {
        preparingForTermination = false
        if activeWindowMutationTask == nil {
            windowMutationIntent = .commit
        }
        hideFeedbackWhenWindowMutationFinishes = false
        hotKeys.install()
        reconfigureHotKeys()
        dragInteractionMonitor.start()
        dockInteractionMonitor.start()
        commandTabMonitor.start()
        missionControlMonitor.start()
        dockDisplayLockController.start(
            featureEnabled: preferences.isEnabled &&
                preferences.isActionEnabled(.dockDisplayLock)
        )
        preferencesCancellable = preferences.configurationChanges.sink { [weak self] in
            guard let self else { return }
            if !self.preferences.isEnabled {
                self.requestActiveWindowMutationRecovery()
            }
            self.reconfigureWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reconfigureHotKeys() }
            self.reconfigureWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }
    }

    func stop() {
        // A full-screen mutation may already have exited full screen or moved
        // the exact window. Let that transaction reach a verified final state
        // instead of cancelling it and leaving the window half-mutated.
        requestActiveWindowMutationRecovery()
        hideFeedbackWhenWindowMutationFinishes = activeWindowMutationTask != nil
        preferencesCancellable?.cancel()
        preferencesCancellable = nil
        hotKeys.uninstall()
        dragInteractionMonitor.stop()
        dockInteractionMonitor.stop()
        commandTabMonitor.stop()
        missionControlMonitor.stop()
        dockDisplayLockController.stop()
        // Never strand a reversible hide batch when the controller is stopped
        // or the test app is quit. Only windows owned by this exact batch are
        // restored; windows the user had already minimized remain untouched.
        restoreMinimizedWindowsForShutdown()
        feedbackPresenter.hide()
    }

    var requiresTerminationPreparation: Bool {
        activeWindowMutationTask != nil ||
            minimizationSessions.hasActiveSession ||
            lastWindowMutationCompletion == .unresolved
    }

    /// Stops every new input source, then gives an already-started full-screen
    /// transaction a bounded opportunity to reach its verified final state.
    /// Returning false cancels App termination instead of killing the process
    /// with a window left between full-screen and windowed states.
    func prepareForTermination(timeout: TimeInterval = 18) async -> Bool {
        preparingForTermination = true
        requestActiveWindowMutationRecovery()
        preferencesCancellable?.cancel()
        preferencesCancellable = nil
        reconfigureWorkItem?.cancel()
        reconfigureWorkItem = nil
        hotKeys.uninstall()
        dragInteractionMonitor.stop()
        dockInteractionMonitor.stop()
        commandTabMonitor.stop()
        missionControlMonitor.stop()
        dockDisplayLockController.stop()
        let minimizedWindowsRestored = restoreMinimizedWindowsForShutdown()

        let deadline = Date().addingTimeInterval(timeout)
        while activeWindowMutationTask != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let recoveryComplete = minimizedWindowsRestored && restoreMinimizedWindowsForShutdown()
        let windowMutationResolved = activeWindowMutationTask == nil &&
            lastWindowMutationCompletion != .unresolved
        guard windowMutationResolved, recoveryComplete else {
            preparingForTermination = false
            start()
            feedback("窗口操作尚未安全收敛，已取消退出；请确认窗口状态后重试")
            return false
        }
        feedbackPresenter.hide()
        return true
    }

    func refreshSystemIntegrations() {
        reconfigureHotKeys()
        commandTabMonitor.updateEnabledState()
    }

    func execute(targetID: String) {
        guard preferences.isEnabled else {
            feedback("窗口增强已关闭")
            return
        }
        if let layout = WindowLayout.allCases.first(where: { $0.shortcutID == targetID }) {
            perform(layout: layout)
            return
        }
        guard let action = WindowQuickAction.allCases.first(where: { $0.shortcutID == targetID }) else { return }
        perform(action: action)
    }

    func perform(layout: WindowLayout, targetDisplayID: CGDirectDisplayID? = nil) {
        guard ensureAccessibility(), guardWindowMutationIsIdle() else { return }
        guard let context = standardFocusedWindowContext() else { return }
        guard !preferences.isExcluded(context.application) else {
            feedback("\(context.application.localizedName ?? "当前 App") 已被排除")
            return
        }

        if axBoolAttribute("AXFullScreen", of: context.window) == true {
            let sourceDisplayID = displayID(forAXFrame: context.frame)
            let intendedDisplayID = targetDisplayID ?? sourceDisplayID
            guard let sourceDisplayID, let intendedDisplayID else {
                feedback("找不到全屏窗口所在显示器")
                return
            }
            if targetDisplayID != nil, screen(withDisplayID: intendedDisplayID) == nil {
                feedback("目标显示器已断开，请重新选择布局")
                return
            }
            guard let identity = WindowIdentity(context: context) else {
                feedback("当前全屏窗口缺少稳定标识，已取消操作以避免影响错误窗口")
                return
            }
            beginWindowMutation { [weak self] generation in
                guard let self else { return .unresolved }
                return await self.performFullScreenLayout(
                    layout,
                    context: context,
                    identity: identity,
                    sourceDisplayID: sourceDisplayID,
                    intendedDisplayID: intendedDisplayID,
                    generation: generation
                )
            }
            return
        }

        guard let context = manageableWindowContext(context, requirement: .moveOrResize) else { return }
        beginWindowedLayout(
            layout,
            context: context,
            targetDisplayID: targetDisplayID,
            exactWindowNumber: Self.axWindowNumber(of: context.window)
        )
    }

    /// The drag monitor has already captured the exact window at mouse-down.
    /// Keep that identity through mouse-up instead of asking the application for
    /// its then-focused window, which may be a different window of the same App.
    func performDraggedLayout(
        _ layout: WindowLayout,
        targetDisplayID: CGDirectDisplayID,
        applicationPID: pid_t,
        windowID: CGWindowID?,
        window: AXUIElement
    ) {
        guard ensureAccessibility(), guardWindowMutationIsIdle() else { return }
        guard exactPID(of: window) == applicationPID,
              windowID.map({ Self.axWindowNumber(of: window) == Int($0) }) != false,
              let application = NSRunningApplication(processIdentifier: applicationPID),
              !application.isTerminated,
              application.activationPolicy == .regular,
              !preferences.isExcluded(application),
              let currentFrame = frame(of: window) else {
            feedback("拖动的窗口已变化，已取消布局")
            return
        }
        let context = FocusedWindowContext(
            application: application,
            window: window,
            frame: currentFrame
        )
        guard isStandardWindowForWindowedLayout(window),
              manageableWindowContext(context, requirement: .moveOrResize) != nil else { return }
        beginWindowedLayout(
            layout,
            context: context,
            targetDisplayID: targetDisplayID,
            exactWindowNumber: windowID.map(Int.init)
        )
    }

    private func beginWindowedLayout(
        _ layout: WindowLayout,
        context: FocusedWindowContext,
        targetDisplayID: CGDirectDisplayID?,
        exactWindowNumber: Int?
    ) {
        let initialDisplayID = displayID(forAXFrame: context.frame)
        beginWindowMutation { [weak self] generation in
            guard let self else { return .unresolved }
            return await self.performWindowedLayout(
                layout,
                context: context,
                targetDisplayID: targetDisplayID,
                initialDisplayID: initialDisplayID,
                exactWindowNumber: exactWindowNumber,
                generation: generation
            )
        }
    }

    private func performWindowedLayout(
        _ layout: WindowLayout,
        context: FocusedWindowContext,
        targetDisplayID: CGDirectDisplayID?,
        initialDisplayID: CGDirectDisplayID?,
        exactWindowNumber: Int?,
        generation: UInt64
    ) async -> WindowMutationCompletion {
        guard let window = await waitForWindowedLayoutReadiness(
            preferredElement: context.window,
            applicationPID: context.application.processIdentifier,
            exactWindowNumber: exactWindowNumber,
            generation: generation
        ) else {
            if isWindowMutationCurrent(generation) {
                feedback("窗口仍在变化，已取消布局，请重试")
            }
            return .safeWindowed
        }
        guard !shouldRecoverWindowMutation(generation) else { return .restored }

        let resolvedDisplayID = targetDisplayID ?? initialDisplayID ??
            frame(of: window).flatMap(displayID(forAXFrame:))
        guard let resolvedDisplayID,
              let targetScreen = screen(withDisplayID: resolvedDisplayID) else {
            feedback(targetDisplayID == nil ? "找不到窗口所在显示器" : "目标显示器已断开，请重新选择布局")
            return .safeWindowed
        }
        let usable = usableAXFrame(for: targetScreen)
        let target = layoutFrame(layout, in: usable)
        let commit = await commitWindowedFrame(
            target,
            within: usable,
            preferredElement: window,
            applicationPID: context.application.processIdentifier,
            exactWindowNumber: exactWindowNumber,
            generation: generation
        )
        guard isWindowMutationCurrent(generation) else { return .unresolved }
        guard !shouldRecoverWindowMutation(generation) else { return .safeWindowed }
        guard let outcome = commit else {
            if isWindowMutationCurrent(generation) {
                feedback("窗口位置未能稳定，布局未完成")
            }
            return .safeWindowed
        }

        switch outcome.result {
        case .complete:
            feedback("已应用：\(layout.title)")
        case .movedOnly:
            feedback("窗口已移动，但当前 App 不允许缩放")
        case .resizedOnly:
            feedback("窗口已缩放，但当前 App 不允许移动")
        case .constrained:
            feedback("窗口已按当前 App 限制调整，未达到完整目标布局")
        case .failed:
            feedback("窗口不允许移动或缩放")
        }
        switch outcome.result {
        case .complete:
            return .committed
        case .movedOnly, .resizedOnly, .constrained, .failed:
            return .safeWindowed
        }
    }

    func perform(action: WindowQuickAction) {
        guard preferences.isActionEnabled(action) else {
            feedback("\(action.title)已关闭")
            return
        }
        guard guardWindowMutationIsIdle() else { return }
        switch action {
        case .closeWindow:
            closeFocusedWindow()
        case .quitApp:
            confirmQuitFrontmostApp()
        case .dockDisplayLock:
            dockDisplayLockController.moveAndLockToPointerDisplay()
        case .hideAll:
            toggleMinimizedWindows(mode: .all)
        case .hideOthers:
            toggleMinimizedWindows(mode: .others)
        case .nextDisplay:
            moveFocusedWindow(displayOffset: 1)
        case .previousDisplay:
            moveFocusedWindow(displayOffset: -1)
        case .centerWindow:
            centerFocusedWindow()
        }
    }

    /// Aero Shake is a standalone core feature. It intentionally bypasses the
    /// independent quick-action toggle for `hideOthers`.
    func performAeroShake() {
        guard preferences.isEnabled, preferences.aeroShakeEnabled else { return }
        guard guardWindowMutationIsIdle() else { return }
        toggleMinimizedWindows(mode: .others)
    }

    /// Mouse-based monitors cannot present their own settings UI. Route their
    /// missing-permission state through the same lightweight, nonactivating HUD.
    func reportAccessibilityRequirement() {
        guard !PermissionsManager.shared.checkAccessibility() else {
            didReportAccessibilityRequirement = false
            return
        }
        guard !didReportAccessibilityRequirement else { return }
        didReportAccessibilityRequirement = true
        feedback("需要辅助功能权限才能管理窗口，请在系统设置中允许 SuperIsland")
    }

    private func reconfigureHotKeys() {
        if !preferences.isEnabled {
            restoreMinimizedWindowsForShutdown()
        }
        hotKeys.removeAll()
        let shortcutSnapshot = preferences.shortcuts
        var failedRegistrations: [(target: String, shortcut: WindowShortcut)] = []
        var successfulRegistrations: [(target: String, shortcut: WindowShortcut)] = []
        if preferences.isEnabled {
            for (target, shortcut) in shortcutSnapshot {
                guard shouldRegisterShortcut(target) else {
                    preferences.finishShortcutRegistration(shortcut, for: target)
                    continue
                }
                if hotKeys.register(shortcut, target: target) != noErr {
                    failedRegistrations.append((target, shortcut))
                } else {
                    successfulRegistrations.append((target, shortcut))
                }
            }
        } else {
            for (target, shortcut) in shortcutSnapshot {
                preferences.finishShortcutRegistration(shortcut, for: target)
            }
        }

        successfulRegistrations.forEach {
            preferences.finishShortcutRegistration($0.shortcut, for: $0.target)
        }

        var rolledBackTargets: [String] = []
        var unresolvedTargets: [String] = []
        for failure in failedRegistrations {
            if preferences.rollbackShortcutRegistration(failure.shortcut, for: failure.target) {
                rolledBackTargets.append(failure.target)
                if let restored = preferences.shortcut(for: failure.target),
                   shouldRegisterShortcut(failure.target),
                   hotKeys.register(restored, target: failure.target) != noErr {
                    unresolvedTargets.append(failure.target)
                }
            } else {
                unresolvedTargets.append(failure.target)
            }
        }
        dragInteractionMonitor.updateEnabledState()
        dockInteractionMonitor.updateEnabledState()
        commandTabMonitor.updateEnabledState()
        missionControlMonitor.updateEnabledState()
        dockDisplayLockController.updateFeatureEnabled(
            preferences.isEnabled &&
                preferences.isActionEnabled(.dockDisplayLock)
        )
        reportEnabledFeaturePermissionIfNeeded()

        let rolledBackSet = Set(rolledBackTargets)
        let unresolvedSet = Set(unresolvedTargets)
        let allFailedTargets = Array(rolledBackSet.union(unresolvedSet)).sorted()
        let signature = allFailedTargets.joined(separator: "|")
        if !signature.isEmpty, signature != lastHotKeyFailureSignature {
            lastHotKeyFailureSignature = signature
            let restoredOnly = rolledBackSet.subtracting(unresolvedSet).sorted()
            if unresolvedSet.isEmpty {
                let names = rolledBackSet.sorted().map(targetDisplayName).joined(separator: "、")
                feedback("快捷键冲突：\(names)。已保留原设置")
            } else if !restoredOnly.isEmpty {
                let restoredNames = restoredOnly.map(targetDisplayName).joined(separator: "、")
                let unresolvedNames = unresolvedSet.sorted().map(targetDisplayName).joined(separator: "、")
                feedback("快捷键冲突：\(restoredNames) 已保留原设置；\(unresolvedNames) 注册失败")
            } else {
                let names = unresolvedSet.sorted().map(targetDisplayName).joined(separator: "、")
                feedback("快捷键注册失败：\(names)。可能已被系统或其他 App 占用")
            }
        } else if signature.isEmpty {
            lastHotKeyFailureSignature = nil
        }
    }

    private func closeFocusedWindow() {
        switch missionControlMonitor.closeTargetedWindow() {
        case .noTarget:
            break
        case let .completed(message), let .failed(message):
            feedback(message)
            return
        }
        guard ensureAccessibility(), let context = focusedWindowContext() else { return }
        guard !preferences.isExcluded(context.application) else {
            feedback("\(context.application.localizedName ?? "当前 App") 已被排除")
            return
        }
        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(context.window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
              let closeButtonValue,
              CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID() else {
            feedback("当前窗口没有可用的关闭按钮")
            return
        }
        let result = AXUIElementPerformAction(unsafeBitCast(closeButtonValue, to: AXUIElement.self), kAXPressAction as CFString)
        feedback(result == .success ? "已关闭当前窗口" : "关闭窗口失败")
    }

    private func confirmQuitFrontmostApp() {
        switch missionControlMonitor.quitTargetedApplication() {
        case .noTarget:
            break
        case let .completed(message), let .failed(message):
            feedback(message)
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !preferences.isExcluded(application) else {
            feedback("没有可退出的前台 App")
            return
        }
        let name = application.localizedName ?? "当前 App"
        let alert = NSAlert()
        alert.messageText = "退出 \(name)？"
        alert.informativeText = "这会退出整个 App。未保存内容是否可恢复由 \(name) 决定。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            application.terminate()
            feedback("已请求退出 \(name)")
        }
    }

    private func toggleMinimizedWindows(
        mode: WindowMinimizationSessionController.Mode
    ) {
        guard ensureAccessibility() else { return }
        let excludedBundleIdentifiers = Set(preferences.excludedBundleIDs)
        let outcome = minimizationSessions.toggle(
            mode: mode,
            excludingBundleIdentifiers: excludedBundleIdentifiers
        )
        switch outcome {
        case let .minimized(_, succeeded, failed):
            if failed > 0 {
                feedback("已隐藏 \(succeeded) 个窗口，\(failed) 个窗口不允许最小化；再次触发可恢复")
            } else {
                feedback("已隐藏 \(succeeded) 个窗口；再次触发可恢复")
            }
        case let .restored(_, succeeded, failed, missing):
            let unresolved = failed + missing
            if unresolved > 0 {
                feedback("已恢复 \(succeeded) 个窗口，\(unresolved) 个窗口已关闭或不允许恢复")
            } else {
                feedback("已恢复 \(succeeded) 个窗口")
            }
        case let .nothingToMinimize(outcomeMode):
            feedback(outcomeMode == .others ? "没有其他可隐藏窗口" : "没有可隐藏窗口")
        case .nothingToRestore:
            feedback("没有由 SuperIsland 隐藏的窗口可恢复")
        case .missingFocusedWindow:
            feedback("当前 App 没有可保留的窗口")
        }
    }

    @discardableResult
    private func restoreMinimizedWindowsForShutdown() -> Bool {
        // AX can transiently reject unminimize while an App is transitioning.
        // Retry once synchronously; any remaining references stay owned by the
        // session controller rather than being silently forgotten.
        guard case let .restored(_, _, failed, _) = minimizationSessions.restoreActiveSession(),
              failed > 0 else { return !minimizationSessions.hasActiveSession }
        _ = minimizationSessions.restoreActiveSession()
        return !minimizationSessions.hasActiveSession
    }

    private func centerFocusedWindow() {
        guard ensureAccessibility(), guardWindowMutationIsIdle() else { return }
        guard let context = standardFocusedWindowContext() else { return }
        guard !preferences.isExcluded(context.application) else {
            feedback("当前 App 已被排除")
            return
        }

        if axBoolAttribute("AXFullScreen", of: context.window) == true {
            guard let sourceDisplayID = displayID(forAXFrame: context.frame) else {
                feedback("找不到全屏窗口所在显示器")
                return
            }
            guard let identity = WindowIdentity(context: context) else {
                feedback("当前全屏窗口缺少稳定标识，已取消操作以避免影响错误窗口")
                return
            }
            beginWindowMutation { [weak self] generation in
                guard let self else { return .unresolved }
                return await self.performFullScreenCenter(
                    context: context,
                    identity: identity,
                    sourceDisplayID: sourceDisplayID,
                    generation: generation
                )
            }
            return
        }

        guard let context = manageableWindowContext(context, requirement: .move) else { return }
        performWindowedCenter(context: context)
    }

    private func performWindowedCenter(context: FocusedWindowContext) {
        guard let screen = screen(containingAXFrame: context.frame) ?? NSScreen.main else {
            feedback("找不到窗口所在显示器")
            return
        }
        let usable = usableAXFrame(for: screen)
        let desiredSize = CGSize(
            width: min(context.frame.width, usable.width),
            height: min(context.frame.height, usable.height)
        )
        let wasSizeClamped = abs(desiredSize.width - context.frame.width) > 0.5 ||
            abs(desiredSize.height - context.frame.height) > 0.5
        let sizeResult: GeometryUpdateResult = wasSizeClamped
            ? setSize(desiredSize, for: context.window)
            : .exact
        guard let effectiveFrame = frame(of: context.window) else {
            feedback("无法验证窗口调整结果")
            return
        }
        let centeredOrigin = clampedOrigin(
            CGPoint(
                x: usable.midX - effectiveFrame.width / 2,
                y: usable.midY - effectiveFrame.height / 2
            ),
            size: effectiveFrame.size,
            within: usable
        )
        let positionResult = setPosition(centeredOrigin, for: context.window)
        guard positionResult != .failed, let finalFrame = frame(of: context.window) else {
            feedback("窗口居中失败")
            return
        }
        let fitsUsableArea = finalFrame.width <= usable.width + Self.geometryTolerance &&
            finalFrame.height <= usable.height + Self.geometryTolerance
        if positionResult == .exact, sizeResult == .exact, fitsUsableArea, !wasSizeClamped {
            feedback("窗口已居中")
        } else if positionResult == .exact, fitsUsableArea {
            feedback("窗口已居中，尺寸按当前 App 约束")
        } else {
            feedback("窗口已移动，但当前 App 限制了精确居中")
        }
    }

    private func moveFocusedWindow(displayOffset: Int) {
        guard ensureAccessibility(), guardWindowMutationIsIdle() else { return }
        guard let context = standardFocusedWindowContext() else { return }
        guard !preferences.isExcluded(context.application) else {
            feedback("当前 App 已被排除")
            return
        }

        if axBoolAttribute("AXFullScreen", of: context.window) == true {
            guard let sourceDisplayID = displayID(forAXFrame: context.frame),
                  let targetScreen = adjacentScreen(from: sourceDisplayID, offset: displayOffset),
                  let targetDisplayID = displayID(for: targetScreen) else {
                feedback("没有可移动到的其他显示器")
                return
            }
            guard let identity = WindowIdentity(context: context) else {
                feedback("当前全屏窗口缺少稳定标识，已取消操作以避免影响错误窗口")
                return
            }
            beginWindowMutation { [weak self] generation in
                guard let self else { return .unresolved }
                return await self.performFullScreenDisplayMove(
                    context: context,
                    identity: identity,
                    sourceDisplayID: sourceDisplayID,
                    initialTargetDisplayID: targetDisplayID,
                    displayOffset: displayOffset,
                    generation: generation
                )
            }
            return
        }

        guard let context = manageableWindowContext(context, requirement: .move) else { return }
        performWindowedDisplayMove(context: context, displayOffset: displayOffset)
    }

    private func performWindowedDisplayMove(
        context: FocusedWindowContext,
        displayOffset: Int
    ) {
        let screens = orderedScreens()
        guard screens.count > 1,
              let current = screens.firstIndex(where: { cgBounds(for: $0).contains(CGPoint(x: context.frame.midX, y: context.frame.midY)) }) else {
            feedback("没有可移动到的其他显示器")
            return
        }
        let next = (current + displayOffset + screens.count) % screens.count
        let source = usableAXFrame(for: screens[current])
        let destination = usableAXFrame(for: screens[next])
        let relativeX = source.width > context.frame.width ? (context.frame.minX - source.minX) / (source.width - context.frame.width) : 0.5
        let relativeY = source.height > context.frame.height ? (context.frame.minY - source.minY) / (source.height - context.frame.height) : 0.5
        let desiredSize = CGSize(
            width: min(context.frame.width, destination.width),
            height: min(context.frame.height, destination.height)
        )
        let wasSizeClamped = abs(desiredSize.width - context.frame.width) > 0.5 ||
            abs(desiredSize.height - context.frame.height) > 0.5
        let sizeResult: GeometryUpdateResult = wasSizeClamped
            ? setSize(desiredSize, for: context.window)
            : .exact
        guard let effectiveFrame = frame(of: context.window) else {
            feedback("无法验证窗口调整结果")
            return
        }
        let targetOrigin = CGPoint(
            x: destination.minX + max(0, min(1, relativeX)) * max(0, destination.width - effectiveFrame.width),
            y: destination.minY + max(0, min(1, relativeY)) * max(0, destination.height - effectiveFrame.height)
        )
        let positionResult = setPosition(targetOrigin, for: context.window)
        guard positionResult != .failed,
              let finalFrame = frame(of: context.window) else {
            feedback("跨屏移动失败")
            return
        }
        let destinationWithTolerance = destination.insetBy(
            dx: -Self.geometryTolerance,
            dy: -Self.geometryTolerance
        )
        guard destinationWithTolerance.contains(finalFrame.origin) ||
                destination.contains(CGPoint(x: finalFrame.midX, y: finalFrame.midY)) else {
            feedback("跨屏移动未完成，当前 App 限制了窗口位置")
            return
        }
        let fitsDestination = destinationWithTolerance.contains(finalFrame)
        if positionResult == .exact,
           sizeResult == .exact,
           !wasSizeClamped,
           fitsDestination {
            feedback("窗口已移动到其他显示器")
        } else {
            feedback("窗口已移动到其他显示器，但尺寸或位置受当前 App 限制")
        }
    }

    private struct WindowIdentity {
        let processIdentifier: pid_t
        let windowNumber: Int?
        let identifier: String?
        let requiresUniqueStandardWindow: Bool

        @MainActor
        init?(context: FocusedWindowContext) {
            processIdentifier = context.application.processIdentifier
            windowNumber = WindowEnhancementController.axWindowNumber(of: context.window)
            let rawIdentifier = WindowEnhancementController.axStringValue(
                "AXIdentifier",
                of: context.window
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            identifier = rawIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            if windowNumber != nil || identifier != nil {
                requiresUniqueStandardWindow = false
                return
            }

            // Some full-screen Apps (notably Chromium variants) omit both
            // AXWindowNumber and AXIdentifier. That is still safe when the
            // process exposes exactly one standard, non-modal window and it is
            // the focused element we captured. Re-prove this invariant during
            // every transition poll; never fall back to title or geometry.
            guard let uniqueWindow = WindowEnhancementController.uniqueStandardWindow(
                processIdentifier: processIdentifier
            ), CFEqual(uniqueWindow, context.window) else {
                return nil
            }
            requiresUniqueStandardWindow = true
        }
    }

    private enum FullScreenTransitionOutcome {
        case success(AXUIElement)
        case failure(String)
        case cancelled
    }

    private enum FullScreenRestoreOutcome {
        case restoredFullScreen
        case safeWindowed
        case failed
    }

    private enum WindowMutationIntent {
        case commit
        case recover
    }

    private enum WindowMutationCompletion: Equatable {
        case committed
        case restored
        case safeWindowed
        case unresolved
    }

    private enum WindowStabilityOutcome {
        case stable(AXUIElement)
        case interrupted
        case failed(String)
    }

    private struct DisplayMoveOutcome {
        let exact: Bool
        let finalFrame: CGRect
    }

    private struct CenterMutationOutcome {
        let exact: Bool
        let finalFrame: CGRect
    }

    private struct SettledFullScreenState {
        let isFullScreen: Bool
        let window: AXUIElement
    }

    private func guardWindowMutationIsIdle() -> Bool {
        guard !preparingForTermination else {
            feedback("正在安全结束窗口操作，暂不接受新操作")
            return false
        }
        guard activeWindowMutationTask == nil else {
            feedback("窗口操作正在进行，请稍候")
            return false
        }
        return true
    }

    private func beginWindowMutation(
        _ operation: @escaping @MainActor (UInt64) async -> WindowMutationCompletion
    ) {
        windowMutationGeneration &+= 1
        let generation = windowMutationGeneration
        windowMutationIntent = .commit
        lastWindowMutationCompletion = .unresolved
        activeWindowMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completion = await operation(generation)
            if self.windowMutationGeneration == generation {
                self.lastWindowMutationCompletion = completion
                self.activeWindowMutationTask = nil
                if !self.preparingForTermination {
                    self.windowMutationIntent = .commit
                }
                if self.hideFeedbackWhenWindowMutationFinishes {
                    self.hideFeedbackWhenWindowMutationFinishes = false
                    self.feedbackPresenter.hide()
                }
            }
        }
    }

    private func isWindowMutationCurrent(_ generation: UInt64) -> Bool {
        generation == windowMutationGeneration
    }

    private func requestActiveWindowMutationRecovery() {
        guard activeWindowMutationTask != nil else { return }
        windowMutationIntent = .recover
    }

    private func shouldRecoverWindowMutation(_ generation: UInt64) -> Bool {
        isWindowMutationCurrent(generation) && windowMutationIntent == .recover
    }

    private func performFullScreenLayout(
        _ layout: WindowLayout,
        context: FocusedWindowContext,
        identity: WindowIdentity,
        sourceDisplayID: CGDirectDisplayID,
        intendedDisplayID: CGDirectDisplayID,
        generation: UInt64
    ) async -> WindowMutationCompletion {
        feedback("正在退出全屏并应用：\(layout.title)")
        let exitOutcome = await transitionFullScreen(
            to: false,
            identity: identity,
            preferredElement: context.window,
            requiredWindowedCapability: .moveOrResize,
            generation: generation
        )
        guard isWindowMutationCurrent(generation) else { return .unresolved }
        if shouldRecoverWindowMutation(generation) {
            return await reportFullScreenFailure(
                "窗口增强已关闭或应用正在退出，已取消布局",
                identity: identity,
                preferredElement: context.window,
                sourceDisplayID: sourceDisplayID,
                originalWindowedFrame: nil,
                generation: generation
            )
        }
        guard case let .success(window) = exitOutcome else {
            if case let .failure(reason) = exitOutcome {
                return await reportFullScreenFailure(
                    reason,
                    identity: identity,
                    preferredElement: context.window,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: nil,
                    generation: generation
                )
            }
            return .unresolved
        }
        guard let originalWindowedFrame = frame(of: window) else {
            return await reportFullScreenFailure(
                "退出全屏后无法读取窗口位置",
                identity: identity,
                preferredElement: window,
                sourceDisplayID: sourceDisplayID,
                originalWindowedFrame: nil,
                generation: generation
            )
        }

        var activeWindow = window
        var activeTargetDisplayID = intendedDisplayID
        var didRecomputeTarget = false
        for _ in 0..<2 {
            guard isWindowMutationCurrent(generation) else { return .unresolved }
            if shouldRecoverWindowMutation(generation) {
                return await reportFullScreenFailure(
                    "窗口增强已关闭或应用正在退出，已取消布局",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            let targetScreen: NSScreen
            if let intended = screen(withDisplayID: activeTargetDisplayID) {
                targetScreen = intended
            } else if !didRecomputeTarget,
                      let replacement = screen(withDisplayID: sourceDisplayID) ??
                        screen(containingAXFrame: frame(of: activeWindow) ?? originalWindowedFrame) ??
                        NSScreen.main,
                      let replacementID = displayID(for: replacement) {
                didRecomputeTarget = true
                activeTargetDisplayID = replacementID
                targetScreen = replacement
            } else {
                return await reportFullScreenFailure(
                    "目标显示器已断开",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            let usable = usableAXFrame(for: targetScreen)
            let desiredFrame = layoutFrame(layout, in: usable)
            let result = setFrame(desiredFrame, within: usable, for: activeWindow)
            guard isWindowMutationCurrent(generation) else { return .unresolved }
            guard let finalFrame = frame(of: activeWindow),
                  axBoolAttribute("AXFullScreen", of: activeWindow) == false else {
                return await reportFullScreenFailure(
                    "无法验证布局结果",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            if screen(withDisplayID: activeTargetDisplayID) == nil {
                guard !didRecomputeTarget,
                      let replacement = screen(containingAXFrame: finalFrame) ??
                        screen(withDisplayID: sourceDisplayID) ?? NSScreen.main,
                      let replacementID = displayID(for: replacement) else {
                    return await reportFullScreenFailure(
                        "目标显示器在布局过程中断开",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                didRecomputeTarget = true
                activeTargetDisplayID = replacementID
                if let resolved = resolveExactWindow(identity, preferredElement: activeWindow) {
                    activeWindow = resolved
                }
                continue
            }
            guard cgBounds(for: targetScreen)
                .insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
                .contains(CGPoint(x: finalFrame.midX, y: finalFrame.midY)) else {
                return await reportFullScreenFailure(
                    "窗口布局未落在目标显示器",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            switch result {
            case .complete:
                let stability = await waitForStableWindowGeometry(
                    identity: identity,
                    preferredElement: activeWindow,
                    expectedFullScreen: false,
                    expectedDisplayID: activeTargetDisplayID,
                    expectedFrame: desiredFrame,
                    generation: generation
                )
                if shouldRecoverWindowMutation(generation) {
                    return await reportFullScreenFailure(
                        "窗口增强已关闭或应用正在退出，已回滚布局",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                switch stability {
                case .stable:
                    feedback(didRecomputeTarget
                        ? "目标显示器已变化，已在可用显示器应用：\(layout.title)"
                        : "已退出全屏并应用：\(layout.title)")
                    return .committed
                case .interrupted:
                    return .unresolved
                case let .failed(reason):
                    return await reportFullScreenFailure(
                        "布局结果未稳定：\(reason)",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
            case .movedOnly:
                return await reportFullScreenFailure(
                    "退出全屏后仅移动了窗口，未完成布局",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            case .resizedOnly:
                return await reportFullScreenFailure(
                    "退出全屏后仅缩放了窗口，未完成布局",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            case .constrained:
                return await reportFullScreenFailure(
                    "退出全屏后窗口受 App 限制，未完成精确布局",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            case .failed:
                return await reportFullScreenFailure(
                    "退出全屏后，窗口仍不允许移动或缩放",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
        }
        return .unresolved
    }

    private func performFullScreenCenter(
        context: FocusedWindowContext,
        identity: WindowIdentity,
        sourceDisplayID: CGDirectDisplayID,
        generation: UInt64
    ) async -> WindowMutationCompletion {
        feedback("正在退出全屏并居中窗口")
        let exitOutcome = await transitionFullScreen(
            to: false,
            identity: identity,
            preferredElement: context.window,
            requiredWindowedCapability: .move,
            generation: generation
        )
        guard isWindowMutationCurrent(generation) else { return .unresolved }
        if shouldRecoverWindowMutation(generation) {
            return await reportFullScreenFailure(
                "窗口增强已关闭或应用正在退出，已取消居中",
                identity: identity,
                preferredElement: context.window,
                sourceDisplayID: sourceDisplayID,
                originalWindowedFrame: nil,
                generation: generation
            )
        }
        guard case let .success(window) = exitOutcome else {
            if case let .failure(reason) = exitOutcome {
                return await reportFullScreenFailure(
                    reason,
                    identity: identity,
                    preferredElement: context.window,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: nil,
                    generation: generation
                )
            }
            return .unresolved
        }
        guard let originalWindowedFrame = frame(of: window) else {
            return await reportFullScreenFailure(
                "退出全屏后无法读取窗口位置",
                identity: identity,
                preferredElement: window,
                sourceDisplayID: sourceDisplayID,
                originalWindowedFrame: nil,
                generation: generation
            )
        }

        var activeWindow = window
        var activeTargetDisplayID = sourceDisplayID
        var didRecomputeTarget = false
        for _ in 0..<2 {
            guard isWindowMutationCurrent(generation),
                  let currentFrame = frame(of: activeWindow) else { return .unresolved }
            if shouldRecoverWindowMutation(generation) {
                return await reportFullScreenFailure(
                    "窗口增强已关闭或应用正在退出，已取消居中",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            let targetScreen: NSScreen
            if let source = screen(withDisplayID: activeTargetDisplayID) {
                targetScreen = source
            } else if !didRecomputeTarget,
                      let replacement = screen(containingAXFrame: currentFrame) ?? NSScreen.main,
                      let replacementID = displayID(for: replacement) {
                didRecomputeTarget = true
                activeTargetDisplayID = replacementID
                targetScreen = replacement
            } else {
                return await reportFullScreenFailure(
                    "显示器变化后找不到可用的居中区域",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            guard let centerOutcome = centerWindow(
                activeWindow,
                currentFrame: currentFrame,
                on: targetScreen
            ), axBoolAttribute("AXFullScreen", of: activeWindow) == false else {
                return await reportFullScreenFailure(
                    "退出全屏后窗口居中失败",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            if screen(withDisplayID: activeTargetDisplayID) == nil {
                guard !didRecomputeTarget,
                      let replacement = screen(containingAXFrame: centerOutcome.finalFrame) ?? NSScreen.main,
                      let replacementID = displayID(for: replacement) else {
                    return await reportFullScreenFailure(
                        "显示器在居中过程中断开",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                didRecomputeTarget = true
                activeTargetDisplayID = replacementID
                if let resolved = resolveExactWindow(identity, preferredElement: activeWindow) {
                    activeWindow = resolved
                }
                continue
            }

            guard centerOutcome.exact else {
                return await reportFullScreenFailure(
                    "退出全屏后 App 限制了精确居中",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            let stability = await waitForStableWindowGeometry(
                identity: identity,
                preferredElement: activeWindow,
                expectedFullScreen: false,
                expectedDisplayID: activeTargetDisplayID,
                expectedFrame: centerOutcome.finalFrame,
                generation: generation
            )
            if shouldRecoverWindowMutation(generation) {
                return await reportFullScreenFailure(
                    "窗口增强已关闭或应用正在退出，已回滚居中",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            switch stability {
            case .stable:
                feedback(didRecomputeTarget
                    ? "显示器列表已变化；已退出全屏并在可用显示器居中窗口"
                    : "已退出全屏并居中窗口")
                return .committed
            case .interrupted:
                return .unresolved
            case let .failed(reason):
                return await reportFullScreenFailure(
                    "居中结果未稳定：\(reason)",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
        }
        return .unresolved
    }

    private func performFullScreenDisplayMove(
        context: FocusedWindowContext,
        identity: WindowIdentity,
        sourceDisplayID: CGDirectDisplayID,
        initialTargetDisplayID: CGDirectDisplayID,
        displayOffset: Int,
        generation: UInt64
    ) async -> WindowMutationCompletion {
        feedback("正在将全屏窗口移动到其他显示器")
        let exitOutcome = await transitionFullScreen(
            to: false,
            identity: identity,
            preferredElement: context.window,
            requiredWindowedCapability: .move,
            generation: generation
        )
        guard isWindowMutationCurrent(generation) else { return .unresolved }
        if shouldRecoverWindowMutation(generation) {
            return await reportFullScreenFailure(
                "窗口增强已关闭或应用正在退出，已取消跨屏移动",
                identity: identity,
                preferredElement: context.window,
                sourceDisplayID: sourceDisplayID,
                originalWindowedFrame: nil,
                generation: generation
            )
        }
        guard case let .success(window) = exitOutcome else {
            if case let .failure(reason) = exitOutcome {
                return await reportFullScreenFailure(
                    reason,
                    identity: identity,
                    preferredElement: context.window,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: nil,
                    generation: generation
                )
            }
            return .unresolved
        }
        guard let originalWindowedFrame = frame(of: window) else {
            return await reportFullScreenFailure(
                "退出全屏后无法读取窗口位置",
                identity: identity,
                preferredElement: window,
                sourceDisplayID: sourceDisplayID,
                originalWindowedFrame: nil,
                generation: generation
            )
        }

        var activeWindow = window
        var activeTargetDisplayID = initialTargetDisplayID
        var didRecomputeTarget = false
        for _ in 0..<2 {
            guard isWindowMutationCurrent(generation),
                  let currentFrame = frame(of: activeWindow),
                  let currentScreen = screen(containingAXFrame: currentFrame) ??
                    screen(withDisplayID: sourceDisplayID) ?? NSScreen.main else { return .unresolved }
            if shouldRecoverWindowMutation(generation) {
                return await reportFullScreenFailure(
                    "窗口增强已关闭或应用正在退出，已取消跨屏移动",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            let destinationScreen: NSScreen
            if let target = screen(withDisplayID: activeTargetDisplayID) {
                destinationScreen = target
            } else if !didRecomputeTarget,
                      let currentDisplayID = displayID(for: currentScreen),
                      let replacement = adjacentScreen(from: currentDisplayID, offset: displayOffset),
                      let replacementID = displayID(for: replacement) {
                didRecomputeTarget = true
                activeTargetDisplayID = replacementID
                destinationScreen = replacement
            } else {
                return await reportFullScreenFailure(
                    "目标显示器已断开",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }

            guard let moveOutcome = moveWindow(
                activeWindow,
                currentFrame: currentFrame,
                from: currentScreen,
                to: destinationScreen
            ) else {
                if screen(withDisplayID: activeTargetDisplayID) == nil,
                   !didRecomputeTarget,
                   let latestFrame = frame(of: activeWindow),
                   let latestDisplayID = displayID(forAXFrame: latestFrame),
                   let replacement = adjacentScreen(from: latestDisplayID, offset: displayOffset),
                   let replacementID = displayID(for: replacement) {
                    didRecomputeTarget = true
                    activeTargetDisplayID = replacementID
                    continue
                }
                return await reportFullScreenFailure(
                    "全屏窗口退出后无法跨屏移动",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            guard isWindowMutationCurrent(generation) else { return .unresolved }

            if screen(withDisplayID: activeTargetDisplayID) == nil {
                guard !didRecomputeTarget else {
                    return await reportFullScreenFailure(
                        "目标显示器在移动过程中断开",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                didRecomputeTarget = true
                guard let movedDisplayID = displayID(forAXFrame: moveOutcome.finalFrame),
                      let replacement = adjacentScreen(from: movedDisplayID, offset: displayOffset),
                      let replacementID = displayID(for: replacement) else {
                    return await reportFullScreenFailure(
                        "显示器变化后没有其他可用显示器",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                activeTargetDisplayID = replacementID
                continue
            }

            let enterOutcome = await transitionFullScreen(
                to: true,
                identity: identity,
                preferredElement: activeWindow,
                requiredWindowedCapability: nil,
                generation: generation
            )
            guard isWindowMutationCurrent(generation) else { return .unresolved }
            if shouldRecoverWindowMutation(generation) {
                return await reportFullScreenFailure(
                    "窗口增强已关闭或应用正在退出，已回滚跨屏移动",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            guard case let .success(fullScreenWindow) = enterOutcome else {
                if case let .failure(reason) = enterOutcome {
                    return await reportFullScreenFailure(
                        reason,
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                return .unresolved
            }
            activeWindow = fullScreenWindow

            if let targetScreen = screen(withDisplayID: activeTargetDisplayID),
               let fullScreenFrame = frame(of: activeWindow),
               axBoolAttribute("AXFullScreen", of: activeWindow) == true,
               cgBounds(for: targetScreen).insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
                .contains(CGPoint(x: fullScreenFrame.midX, y: fullScreenFrame.midY)) {
                let stability = await waitForStableWindowGeometry(
                    identity: identity,
                    preferredElement: activeWindow,
                    expectedFullScreen: true,
                    expectedDisplayID: activeTargetDisplayID,
                    expectedFrame: nil,
                    generation: generation
                )
                if shouldRecoverWindowMutation(generation) {
                    return await reportFullScreenFailure(
                        "窗口增强已关闭或应用正在退出，已回滚跨屏移动",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
                switch stability {
                case .stable:
                    feedback(didRecomputeTarget
                        ? "显示器列表已变化；全屏窗口已移动到另一可用显示器"
                        : (moveOutcome.exact
                            ? "全屏窗口已移动到其他显示器"
                            : "全屏窗口已移动到其他显示器；窗口化过渡位置受 App 限制"))
                    return .committed
                case .interrupted:
                    return .unresolved
                case let .failed(reason):
                    return await reportFullScreenFailure(
                        "跨屏全屏结果未稳定：\(reason)",
                        identity: identity,
                        preferredElement: activeWindow,
                        sourceDisplayID: sourceDisplayID,
                        originalWindowedFrame: originalWindowedFrame,
                        generation: generation
                    )
                }
            }

            guard !didRecomputeTarget,
                  screen(withDisplayID: activeTargetDisplayID) == nil else {
                return await reportFullScreenFailure(
                    "窗口重新进入全屏后未落在目标显示器",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            didRecomputeTarget = true
            let secondExit = await transitionFullScreen(
                to: false,
                identity: identity,
                preferredElement: activeWindow,
                requiredWindowedCapability: .move,
                generation: generation
            )
            if shouldRecoverWindowMutation(generation) {
                return await reportFullScreenFailure(
                    "窗口增强已关闭或应用正在退出，已回滚跨屏移动",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            guard case let .success(windowedAgain) = secondExit,
                  let currentDisplayID = frame(of: windowedAgain).flatMap(displayID(forAXFrame:)),
                  let replacement = adjacentScreen(from: currentDisplayID, offset: displayOffset),
                  let replacementID = displayID(for: replacement) else {
                return await reportFullScreenFailure(
                    "显示器变化后无法重新计算目标",
                    identity: identity,
                    preferredElement: activeWindow,
                    sourceDisplayID: sourceDisplayID,
                    originalWindowedFrame: originalWindowedFrame,
                    generation: generation
                )
            }
            activeWindow = windowedAgain
            activeTargetDisplayID = replacementID
        }
        return .unresolved
    }

    private func transitionFullScreen(
        to desiredState: Bool,
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        requiredWindowedCapability: WindowMutationRequirement?,
        generation: UInt64
    ) async -> FullScreenTransitionOutcome {
        guard isWindowMutationCurrent(generation) else { return .cancelled }
        guard let window = resolveExactWindow(identity, preferredElement: preferredElement),
              let currentState = axBoolAttribute("AXFullScreen", of: window) else {
            return .failure("无法确认当前窗口的全屏状态")
        }

        if currentState != desiredState {
            if isAttributeSettable("AXFullScreen", of: window) {
                let value: CFBoolean = desiredState ? kCFBooleanTrue : kCFBooleanFalse
                guard AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, value) == .success else {
                    return .failure(desiredState ? "当前 App 拒绝进入全屏" : "当前 App 拒绝退出全屏")
                }
            } else {
                guard let button = axElementAttribute("AXFullScreenButton", of: window),
                      axBoolAttribute(kAXEnabledAttribute, of: button) != false,
                      AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    return .failure(desiredState
                        ? "当前 App 没有可用的全屏控制"
                        : "当前 App 不允许退出全屏")
                }
            }
        }

        let deadline = Date().addingTimeInterval(Self.fullScreenTransitionTimeout)
        var preferred = window
        while Date() < deadline {
            guard isWindowMutationCurrent(generation) else { return .cancelled }
            if let resolved = resolveExactWindow(identity, preferredElement: preferred) {
                preferred = resolved
                if axBoolAttribute("AXFullScreen", of: resolved) == desiredState,
                   desiredState || requiredWindowedCapability.map({ windowSupports(resolved, requirement: $0) }) != false {
                    return .success(resolved)
                }
            }
            do {
                try await Task.sleep(nanoseconds: Self.fullScreenPollNanoseconds)
            } catch {
                return .cancelled
            }
        }
        return .failure(desiredState
            ? "进入全屏超时，未能确认最终状态"
            : "退出全屏超时，窗口尚未恢复为可调整状态")
    }

    /// A first AX readback is not a committed result: AppKit may still finish a
    /// Space transition or restore a pre-fullscreen frame afterwards. Require a
    /// complete four-second quiet window. Any meaningful state, display or frame
    /// change restarts that window; failure to settle is routed through recovery
    /// instead of being reported as success.
    private func waitForStableWindowGeometry(
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        expectedFullScreen: Bool,
        expectedDisplayID: CGDirectDisplayID,
        expectedFrame: CGRect?,
        generation: UInt64,
        maximumDuration: TimeInterval = 8,
        quietDuration: TimeInterval = 4,
        respectRecoveryIntent: Bool = true
    ) async -> WindowStabilityOutcome {
        let deadline = Date().addingTimeInterval(maximumDuration)
        var preferred = preferredElement
        var lastState: Bool?
        var lastDisplayID: CGDirectDisplayID?
        var lastFrame: CGRect?
        var quietSince: Date?

        while Date() < deadline {
            guard isWindowMutationCurrent(generation) else { return .interrupted }
            if respectRecoveryIntent, shouldRecoverWindowMutation(generation) {
                return .interrupted
            }
            guard let expectedScreen = screen(withDisplayID: expectedDisplayID) else {
                return .failed("目标显示器已断开")
            }

            guard let resolved = resolveExactWindow(identity, preferredElement: preferred),
                  let currentState = axBoolAttribute("AXFullScreen", of: resolved),
                  let currentFrame = frame(of: resolved),
                  let currentDisplayID = displayID(forAXFrame: currentFrame) else {
                quietSince = nil
                do {
                    try await Task.sleep(nanoseconds: Self.fullScreenPollNanoseconds)
                } catch {
                    return .interrupted
                }
                continue
            }
            preferred = resolved

            let expandedBounds = cgBounds(for: expectedScreen).insetBy(
                dx: -Self.geometryTolerance,
                dy: -Self.geometryTolerance
            )
            let fullyOnExpectedDisplay = expandedBounds.contains(currentFrame)
            let frameIsExpected = expectedFrame.map { frameMatches(currentFrame, $0) } ?? true
            let acceptable = currentState == expectedFullScreen &&
                currentDisplayID == expectedDisplayID &&
                fullyOnExpectedDisplay &&
                frameIsExpected
            let observationChanged = lastState != currentState ||
                lastDisplayID != currentDisplayID ||
                lastFrame.map { !frameMatches($0, currentFrame) } ?? true

            if observationChanged || !acceptable {
                quietSince = acceptable ? Date() : nil
            } else if quietSince == nil {
                quietSince = Date()
            }
            lastState = currentState
            lastDisplayID = currentDisplayID
            lastFrame = currentFrame

            if let quietSince,
               Date().timeIntervalSince(quietSince) >= quietDuration {
                return .stable(resolved)
            }
            do {
                try await Task.sleep(nanoseconds: Self.fullScreenPollNanoseconds)
            } catch {
                return .interrupted
            }
        }
        return .failed("窗口状态未能连续稳定 4 秒")
    }

    private func waitForSettledFullScreenState(
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        requiredWindowedCapability: WindowMutationRequirement?,
        generation: UInt64,
        maximumDuration: TimeInterval = 8,
        quietDuration: TimeInterval = 4
    ) async -> SettledFullScreenState? {
        let deadline = Date().addingTimeInterval(maximumDuration)
        var preferred = preferredElement
        var lastState: Bool?
        var quietSince: Date?
        while Date() < deadline {
            guard isWindowMutationCurrent(generation),
                  let resolved = resolveExactWindow(identity, preferredElement: preferred),
                  let currentState = axBoolAttribute("AXFullScreen", of: resolved) else { return nil }
            preferred = resolved
            let capabilityReady = currentState || requiredWindowedCapability.map {
                windowSupports(resolved, requirement: $0)
            } != false
            if lastState != currentState || !capabilityReady {
                lastState = currentState
                quietSince = capabilityReady ? Date() : nil
            } else if quietSince == nil, capabilityReady {
                quietSince = Date()
            }
            if let quietSince,
               Date().timeIntervalSince(quietSince) >= quietDuration {
                return SettledFullScreenState(isFullScreen: currentState, window: resolved)
            }
            do {
                try await Task.sleep(nanoseconds: Self.fullScreenPollNanoseconds)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func reportFullScreenFailure(
        _ reason: String,
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        sourceDisplayID: CGDirectDisplayID,
        originalWindowedFrame: CGRect?,
        generation: UInt64
    ) async -> WindowMutationCompletion {
        guard isWindowMutationCurrent(generation) else { return .unresolved }
        let restoreOutcome = await restoreOriginalFullScreen(
            identity: identity,
            preferredElement: preferredElement,
            sourceDisplayID: sourceDisplayID,
            originalWindowedFrame: originalWindowedFrame,
            generation: generation
        )
        guard isWindowMutationCurrent(generation) else { return .unresolved }
        switch restoreOutcome {
        case .restoredFullScreen:
            feedback("\(reason)；已恢复原全屏状态")
            return .restored
        case .safeWindowed:
            feedback("\(reason)；原显示器已不可用或无法恢复全屏，窗口已安全保留在可用显示器")
            return .safeWindowed
        case .failed:
            feedback("\(reason)；未能完全恢复原全屏状态")
            return .unresolved
        }
    }

    private func restoreOriginalFullScreen(
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        sourceDisplayID: CGDirectDisplayID,
        originalWindowedFrame: CGRect?,
        generation: UInt64
    ) async -> FullScreenRestoreOutcome {
        guard isWindowMutationCurrent(generation),
              var window = resolveExactWindow(identity, preferredElement: preferredElement) else {
            return .failed
        }

        // A transition that previously timed out may complete after failure
        // handling begins. Reconcile to a stable observable state before any
        // compensating writes, so recovery never races a late fullscreen exit.
        guard let settled = await waitForSettledFullScreenState(
            identity: identity,
            preferredElement: window,
            requiredWindowedCapability: .move,
            generation: generation
        ), isWindowMutationCurrent(generation),
        let reconciledAfterSettlement = resolveExactWindow(
            identity,
            preferredElement: settled.window
        ) else {
            return .failed
        }
        window = reconciledAfterSettlement

        if axBoolAttribute("AXFullScreen", of: window) == true {
            // A timed-out exit request may still be queued by the target App.
            // Reassert the desired final state through the settable attribute;
            // button-only windows cannot safely cancel an unseen pending toggle,
            // so recovery remains explicitly unverified for those windows.
            guard reinforceFullScreenIntent(on: window) else { return .failed }
            if let sourceScreen = screen(withDisplayID: sourceDisplayID),
               let currentFrame = frame(of: window),
               cgBounds(for: sourceScreen).insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
                .contains(CGPoint(x: currentFrame.midX, y: currentFrame.midY)) {
                if await stableFullScreenRestoreOutcome(
                    identity: identity,
                    preferredElement: window,
                    sourceDisplayID: sourceDisplayID,
                    generation: generation
                ) {
                    return .restoredFullScreen
                }
                guard isWindowMutationCurrent(generation),
                      let reconciled = resolveExactWindow(identity, preferredElement: window) else {
                    return .failed
                }
                window = reconciled
            }
            if axBoolAttribute("AXFullScreen", of: window) == true {
                let exitOutcome = await transitionFullScreen(
                    to: false,
                    identity: identity,
                    preferredElement: window,
                    requiredWindowedCapability: .move,
                    generation: generation
                )
                guard isWindowMutationCurrent(generation),
                      case let .success(windowed) = exitOutcome,
                      let resolvedWindowed = resolveExactWindow(
                        identity,
                        preferredElement: windowed
                      ),
                      axBoolAttribute("AXFullScreen", of: resolvedWindowed) == false else {
                    return .failed
                }
                window = resolvedWindowed
            }
        }

        guard axBoolAttribute("AXFullScreen", of: window) == false else { return .failed }

        // If the original display disappeared, attempting to recreate its
        // fullscreen Space would be dishonest and can strand the window. A
        // continuously verified visible windowed state is the safest outcome.
        guard let sourceScreen = screen(withDisplayID: sourceDisplayID),
              let sourceUsable = onlineUsableAXFrame(for: sourceDisplayID) else {
            return await keepWindowSafelyWindowed(
                identity: identity,
                preferredElement: window,
                preferredDisplayID: nil,
                originalWindowedFrame: originalWindowedFrame,
                generation: generation
            ) ? .safeWindowed : .failed
        }
        let currentFrame = frame(of: window)
        guard let recoveryFrame = recoveryFrame(
            originalWindowedFrame: originalWindowedFrame,
            currentFrame: currentFrame,
            within: sourceUsable
        ), setFrame(recoveryFrame, within: sourceUsable, for: window) == .complete,
        let freshSourceScreen = screen(withDisplayID: sourceDisplayID),
        displayID(for: freshSourceScreen) == displayID(for: sourceScreen),
        let recoveredFrame = frame(of: window),
        frameMatches(recoveredFrame, recoveryFrame),
        cgBounds(for: freshSourceScreen)
            .insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
            .contains(recoveredFrame) else {
            return await keepWindowSafelyWindowed(
                identity: identity,
                preferredElement: window,
                preferredDisplayID: screen(withDisplayID: sourceDisplayID) == nil ? nil : sourceDisplayID,
                originalWindowedFrame: originalWindowedFrame,
                generation: generation
            ) ? .safeWindowed : .failed
        }

        guard screen(withDisplayID: sourceDisplayID) != nil,
              let resolvedBeforeEnter = resolveExactWindow(identity, preferredElement: window) else {
            return await keepWindowSafelyWindowed(
                identity: identity,
                preferredElement: window,
                preferredDisplayID: nil,
                originalWindowedFrame: originalWindowedFrame,
                generation: generation
            ) ? .safeWindowed : .failed
        }
        let enterOutcome = await transitionFullScreen(
            to: true,
            identity: identity,
            preferredElement: resolvedBeforeEnter,
            requiredWindowedCapability: nil,
            generation: generation
        )
        guard isWindowMutationCurrent(generation),
              let resolvedAfterEnter = resolveExactWindow(
                identity,
                preferredElement: {
                    if case let .success(restoredWindow) = enterOutcome { return restoredWindow }
                    return resolvedBeforeEnter
                }()
              ) else { return .failed }
        if case .success = enterOutcome,
           await stableFullScreenRestoreOutcome(
            identity: identity,
            preferredElement: resolvedAfterEnter,
            sourceDisplayID: sourceDisplayID,
            generation: generation
           ) {
            return .restoredFullScreen
        }

        // Entering full screen failed, arrived late, or the source disappeared.
        // Do not trust the pre-await screen object: re-resolve the exact window
        // and prove a complete frame on an online screen before allowing exit.
        return await keepWindowSafelyWindowed(
            identity: identity,
            preferredElement: resolvedAfterEnter,
            preferredDisplayID: screen(withDisplayID: sourceDisplayID) == nil ? nil : sourceDisplayID,
            originalWindowedFrame: originalWindowedFrame,
            generation: generation
        ) ? .safeWindowed : .failed
    }

    private func keepWindowSafelyWindowed(
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        preferredDisplayID: CGDirectDisplayID?,
        originalWindowedFrame: CGRect?,
        generation: UInt64
    ) async -> Bool {
        var preferred = preferredElement
        for _ in 0..<3 {
            guard isWindowMutationCurrent(generation),
                  var window = resolveExactWindow(identity, preferredElement: preferred) else {
                return false
            }

            if axBoolAttribute("AXFullScreen", of: window) == true {
                let exitOutcome = await transitionFullScreen(
                    to: false,
                    identity: identity,
                    preferredElement: window,
                    requiredWindowedCapability: .move,
                    generation: generation
                )
                guard isWindowMutationCurrent(generation),
                      case let .success(windowed) = exitOutcome,
                      let resolvedWindowed = resolveExactWindow(
                        identity,
                        preferredElement: windowed
                      ) else { return false }
                window = resolvedWindowed
            }
            guard axBoolAttribute("AXFullScreen", of: window) == false,
                  let currentFrame = frame(of: window) else { return false }

            let targetScreen = preferredDisplayID.flatMap(screen(withDisplayID:)) ??
                screen(containingAXFrame: currentFrame) ?? NSScreen.main ?? NSScreen.screens.first
            guard let targetScreen,
                  let targetDisplayID = displayID(for: targetScreen),
                  let safeBounds = onlineUsableAXFrame(for: targetDisplayID),
                  let safeFrame = recoveryFrame(
                    originalWindowedFrame: originalWindowedFrame,
                    currentFrame: currentFrame,
                    within: safeBounds
                  ),
                  setFrame(safeFrame, within: safeBounds, for: window) == .complete else {
                continue
            }

            let stability = await waitForStableWindowGeometry(
                identity: identity,
                preferredElement: window,
                expectedFullScreen: false,
                expectedDisplayID: targetDisplayID,
                expectedFrame: safeFrame,
                generation: generation,
                respectRecoveryIntent: false
            )
            guard isWindowMutationCurrent(generation) else { return false }
            if case let .stable(stableWindow) = stability,
               let freshScreen = screen(withDisplayID: targetDisplayID),
               let verifiedFrame = frame(of: stableWindow),
               cgBounds(for: freshScreen)
                .insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
                .contains(verifiedFrame) {
                return true
            }
            if let resolved = resolveExactWindow(identity, preferredElement: window) {
                preferred = resolved
            }
        }
        return false
    }

    private func recoveryFrame(
        originalWindowedFrame: CGRect?,
        currentFrame: CGRect?,
        within safeBounds: CGRect
    ) -> CGRect? {
        guard let reference = originalWindowedFrame ?? currentFrame else { return nil }
        let restoredSize = CGSize(
            width: min(reference.width, safeBounds.width),
            height: min(reference.height, safeBounds.height)
        )
        return CGRect(
            origin: clampedOrigin(reference.origin, size: restoredSize, within: safeBounds),
            size: restoredSize
        )
    }

    private func onlineUsableAXFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        guard CGDisplayIsOnline(displayID) != 0,
              CGDisplayIsActive(displayID) != 0,
              let screen = screen(withDisplayID: displayID) else { return nil }
        return usableAXFrame(for: screen)
    }

    private func reinforceFullScreenIntent(on window: AXUIElement) -> Bool {
        guard isAttributeSettable("AXFullScreen", of: window) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            "AXFullScreen" as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private func stableFullScreenRestoreOutcome(
        identity: WindowIdentity,
        preferredElement: AXUIElement,
        sourceDisplayID: CGDirectDisplayID,
        generation: UInt64
    ) async -> Bool {
        // A timed-out transition can still arrive late. Require one complete
        // transition-timeout quiet window inside a bounded reconciliation
        // period. If
        // a late exit arrives, request one compensating enter and restart the
        // quiet timer. Every poll resolves the display ID again so disconnects
        // cannot be mistaken for a successful restore against stale NSScreen.
        let deadline = Date().addingTimeInterval(Self.fullScreenReconciliationMaximumDuration)
        var preferred = preferredElement
        var quietSince: Date?
        var didCompensateLateExit = false
        var lastFrame: CGRect?
        while Date() < deadline {
            guard isWindowMutationCurrent(generation),
                  let sourceScreen = screen(withDisplayID: sourceDisplayID),
                  let resolved = resolveExactWindow(identity, preferredElement: preferred),
                  let isFullScreen = axBoolAttribute("AXFullScreen", of: resolved),
                  let stableFrame = frame(of: resolved) else { return false }
            preferred = resolved
            let onSourceDisplay = cgBounds(for: sourceScreen)
                .insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
                .contains(stableFrame)
            let frameChanged = lastFrame.map { !frameMatches($0, stableFrame) } ?? true
            lastFrame = stableFrame

            if isFullScreen, onSourceDisplay {
                if quietSince == nil || frameChanged { quietSince = Date() }
                if let quietSince,
                   Date().timeIntervalSince(quietSince) >= Self.fullScreenReconciliationQuietDuration {
                    return true
                }
            } else {
                quietSince = nil
                if !isFullScreen, !didCompensateLateExit {
                    didCompensateLateExit = true
                    let outcome = await transitionFullScreen(
                        to: true,
                        identity: identity,
                        preferredElement: resolved,
                        requiredWindowedCapability: nil,
                        generation: generation
                    )
                    guard case let .success(reentered) = outcome else { return false }
                    preferred = reentered
                    continue
                }
                if isFullScreen, !onSourceDisplay { return false }
            }
            do {
                try await Task.sleep(nanoseconds: Self.fullScreenPollNanoseconds)
            } catch {
                return false
            }
        }
        return false
    }

    private func moveWindow(
        _ window: AXUIElement,
        currentFrame: CGRect,
        from sourceScreen: NSScreen,
        to destinationScreen: NSScreen
    ) -> DisplayMoveOutcome? {
        let source = usableAXFrame(for: sourceScreen)
        let destination = usableAXFrame(for: destinationScreen)
        let relativeX = source.width > currentFrame.width
            ? (currentFrame.minX - source.minX) / (source.width - currentFrame.width)
            : 0.5
        let relativeY = source.height > currentFrame.height
            ? (currentFrame.minY - source.minY) / (source.height - currentFrame.height)
            : 0.5
        let desiredSize = CGSize(
            width: min(currentFrame.width, destination.width),
            height: min(currentFrame.height, destination.height)
        )
        let sizeResult: GeometryUpdateResult = sizeMatches(currentFrame.size, desiredSize)
            ? .exact
            : setSize(desiredSize, for: window)
        guard let effectiveFrame = frame(of: window) else { return nil }
        let targetOrigin = CGPoint(
            x: destination.minX + max(0, min(1, relativeX)) * max(0, destination.width - effectiveFrame.width),
            y: destination.minY + max(0, min(1, relativeY)) * max(0, destination.height - effectiveFrame.height)
        )
        let positionResult = setPosition(targetOrigin, for: window)
        guard positionResult != .failed, let finalFrame = frame(of: window) else { return nil }
        let expandedDestination = destination.insetBy(
            dx: -Self.geometryTolerance,
            dy: -Self.geometryTolerance
        )
        guard expandedDestination.contains(finalFrame.origin) ||
                destination.contains(CGPoint(x: finalFrame.midX, y: finalFrame.midY)) else { return nil }
        return DisplayMoveOutcome(
            exact: positionResult == .exact && sizeResult == .exact && expandedDestination.contains(finalFrame),
            finalFrame: finalFrame
        )
    }

    private func centerWindow(
        _ window: AXUIElement,
        currentFrame: CGRect,
        on screen: NSScreen
    ) -> CenterMutationOutcome? {
        let usable = usableAXFrame(for: screen)
        let desiredSize = CGSize(
            width: min(currentFrame.width, usable.width),
            height: min(currentFrame.height, usable.height)
        )
        let sizeResult: GeometryUpdateResult = sizeMatches(currentFrame.size, desiredSize)
            ? .exact
            : setSize(desiredSize, for: window)
        guard let effectiveFrame = frame(of: window) else { return nil }
        let targetOrigin = clampedOrigin(
            CGPoint(
                x: usable.midX - effectiveFrame.width / 2,
                y: usable.midY - effectiveFrame.height / 2
            ),
            size: effectiveFrame.size,
            within: usable
        )
        let positionResult = setPosition(targetOrigin, for: window)
        guard positionResult != .failed, let finalFrame = frame(of: window) else { return nil }
        let expectedOrigin = clampedOrigin(
            CGPoint(
                x: usable.midX - finalFrame.width / 2,
                y: usable.midY - finalFrame.height / 2
            ),
            size: finalFrame.size,
            within: usable
        )
        guard cgBounds(for: screen)
            .insetBy(dx: -Self.geometryTolerance, dy: -Self.geometryTolerance)
            .contains(CGPoint(x: finalFrame.midX, y: finalFrame.midY)) else {
            return nil
        }
        guard originMatches(finalFrame.origin, expectedOrigin) || positionResult == .constrained else {
            return nil
        }
        return CenterMutationOutcome(
            exact: originMatches(finalFrame.origin, expectedOrigin) &&
                positionResult == .exact &&
                sizeResult == .exact,
            finalFrame: finalFrame
        )
    }

    private func resolveExactWindow(
        _ identity: WindowIdentity,
        preferredElement: AXUIElement
    ) -> AXUIElement? {
        if exactWindowMatches(preferredElement, identity: identity) {
            return preferredElement
        }
        if identity.requiresUniqueStandardWindow {
            return Self.uniqueStandardWindow(processIdentifier: identity.processIdentifier)
        }
        guard identity.windowNumber != nil || identity.identifier != nil else { return nil }

        let application = AXUIElementCreateApplication(identity.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] else { return nil }

        if let expectedNumber = identity.windowNumber {
            let numberMatches = windows.filter {
                Self.axWindowNumber(of: $0) == expectedNumber &&
                    exactPID(of: $0) == identity.processIdentifier
            }
            if numberMatches.count == 1 { return numberMatches[0] }
        }
        if let expectedIdentifier = identity.identifier {
            let identifierMatches = windows.filter {
                Self.axStringValue("AXIdentifier", of: $0) == expectedIdentifier &&
                    exactPID(of: $0) == identity.processIdentifier
            }
            if identifierMatches.count == 1 { return identifierMatches[0] }
        }
        return nil
    }

    private func exactWindowMatches(
        _ element: AXUIElement,
        identity: WindowIdentity
    ) -> Bool {
        guard exactPID(of: element) == identity.processIdentifier else { return false }
        if let expectedNumber = identity.windowNumber,
           Self.axWindowNumber(of: element) == expectedNumber {
            return true
        }
        if let expectedIdentifier = identity.identifier,
           Self.axStringValue("AXIdentifier", of: element) == expectedIdentifier {
            return true
        }
        if identity.requiresUniqueStandardWindow,
           let uniqueWindow = Self.uniqueStandardWindow(
                processIdentifier: identity.processIdentifier
           ), CFEqual(uniqueWindow, element) {
            return true
        }
        return false
    }

    private func exactPID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func resolveWindowedLayoutTarget(
        applicationPID: pid_t,
        exactWindowNumber: Int?,
        preferredElement: AXUIElement
    ) -> AXUIElement? {
        guard exactPID(of: preferredElement) == applicationPID else { return nil }
        guard let exactWindowNumber else { return preferredElement }
        guard Self.axWindowNumber(of: preferredElement) == exactWindowNumber else { return nil }
        return preferredElement
    }

    private func isStandardWindowForWindowedLayout(_ window: AXUIElement) -> Bool {
        axStringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole as String &&
            axStringAttribute(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole as String &&
            axBoolAttribute("AXModal", of: window) != true &&
            axBoolAttribute("AXFullScreen", of: window) != true
    }

    /// A global mouse-up callback can arrive before the target App has finished
    /// its own title-bar drag bookkeeping. Require one quiet window before the
    /// first AX write, but keep the whole preparation bounded so snapping remains
    /// responsive.
    private func waitForWindowedLayoutReadiness(
        preferredElement: AXUIElement,
        applicationPID: pid_t,
        exactWindowNumber: Int?,
        generation: UInt64
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(Self.windowedLayoutPreparationTimeout)
        var lastFrame: CGRect?
        var quietSince: Date?
        while Date() < deadline {
            guard isWindowMutationCurrent(generation),
                  !shouldRecoverWindowMutation(generation),
                  let window = resolveWindowedLayoutTarget(
                    applicationPID: applicationPID,
                    exactWindowNumber: exactWindowNumber,
                    preferredElement: preferredElement
                  ),
                  isStandardWindowForWindowedLayout(window),
                  let currentFrame = frame(of: window) else { return nil }
            if let lastFrame, frameMatches(lastFrame, currentFrame) {
                if quietSince == nil { quietSince = Date() }
            } else {
                quietSince = Date()
            }
            lastFrame = currentFrame
            if let quietSince,
               Date().timeIntervalSince(quietSince) >= Self.windowedLayoutPreparationQuietDuration {
                return window
            }
            do {
                try await Task.sleep(nanoseconds: Self.windowedLayoutPollNanoseconds)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Commits a non-full-screen layout only after its readback has remained
    /// quiet. One retry covers Apps that accept the AX request but overwrite it
    /// once while completing mouse-up. A stable non-exact readback is the only
    /// state classified as an App constraint.
    private func commitWindowedFrame(
        _ target: CGRect,
        within safeBounds: CGRect,
        preferredElement: AXUIElement,
        applicationPID: pid_t,
        exactWindowNumber: Int?,
        generation: UInt64
    ) async -> StableWindowedFrameOutcome? {
        await commitWindowedFrameAttempts(
            target,
            within: safeBounds,
            preferredElement: preferredElement,
            applicationPID: applicationPID,
            exactWindowNumber: exactWindowNumber,
            generation: generation
        )
    }

    private func commitWindowedFrameAttempts(
        _ target: CGRect,
        within safeBounds: CGRect,
        preferredElement: AXUIElement,
        applicationPID: pid_t,
        exactWindowNumber: Int?,
        generation: UInt64
    ) async -> StableWindowedFrameOutcome? {
        var window = preferredElement
        guard let transactionBefore = frame(of: preferredElement) else { return nil }
        for attempt in 0..<2 {
            guard isWindowMutationCurrent(generation),
                  !shouldRecoverWindowMutation(generation),
                  let resolved = resolveWindowedLayoutTarget(
                    applicationPID: applicationPID,
                    exactWindowNumber: exactWindowNumber,
                    preferredElement: window
                  ),
                  isStandardWindowForWindowedLayout(resolved) else { return nil }
            window = resolved

            guard let write = writeWindowedLayoutFrame(
                    target,
                    within: safeBounds,
                    for: window,
                    applicationPID: applicationPID
                  ),
                  let settled = await waitForStableWindowedFrame(
                    preferredElement: window,
                    applicationPID: applicationPID,
                    exactWindowNumber: exactWindowNumber,
                    generation: generation
                  ) else { return nil }

#if DEBUG
            let debugWindowNumber = exactWindowNumber.map(String.init) ?? "unknown"
            NSLog(
                "[WindowEnhancement] windowed-layout attempt=\(attempt + 1) " +
                "window=\(debugWindowNumber) " +
                "target=\(target) before=\(write.before) immediate=\(write.after) " +
                "stable=\(settled) sizeWrite=\(write.sizeWriteAccepted) " +
                "positionWrite=\(write.positionWriteAccepted)"
            )
#endif

            var finalReadback = settled
            if frameMatches(settled, target) {
                guard let lateVerified = await verifyWindowedFrameRemainsExact(
                    target: target,
                    preferredElement: window,
                    applicationPID: applicationPID,
                    exactWindowNumber: exactWindowNumber,
                    generation: generation
                ) else { return nil }
                if frameMatches(lateVerified, target) {
                    return StableWindowedFrameOutcome(
                        result: .complete,
                        finalFrame: lateVerified
                    )
                }
                finalReadback = lateVerified
#if DEBUG
                NSLog(
                    "[WindowEnhancement] windowed-layout late-drift " +
                    "attempt=\(attempt + 1) target=\(target) readback=\(lateVerified)"
                )
#endif
            }
            if attempt == 0 { continue }
            return StableWindowedFrameOutcome(
                result: classifyWindowedFrameResult(
                    before: transactionBefore,
                    target: target,
                    final: finalReadback
                ),
                finalFrame: finalReadback
            )
        }
        return nil
    }

    /// Unlike the ordinary quiet readback, this guard deliberately does not
    /// return early merely because the frame is exact. Exactness must survive
    /// the whole native mouse-up/tile reconciliation window. The first drift is
    /// returned immediately so the bounded second write can repair it.
    private func verifyWindowedFrameRemainsExact(
        target: CGRect,
        preferredElement: AXUIElement,
        applicationPID: pid_t,
        exactWindowNumber: Int?,
        generation: UInt64
    ) async -> CGRect? {
        let deadline = Date().addingTimeInterval(
            Self.windowedLayoutLateVerificationDuration
        )
        var lastFrame: CGRect?
        while Date() < deadline {
            guard isWindowMutationCurrent(generation),
                  !shouldRecoverWindowMutation(generation),
                  let window = resolveWindowedLayoutTarget(
                    applicationPID: applicationPID,
                    exactWindowNumber: exactWindowNumber,
                    preferredElement: preferredElement
                  ),
                  isStandardWindowForWindowedLayout(window),
                  let currentFrame = frame(of: window) else { return nil }
            lastFrame = currentFrame
            guard frameMatches(currentFrame, target) else { return currentFrame }
            do {
                try await Task.sleep(nanoseconds: Self.windowedLayoutPollNanoseconds)
            } catch {
                return nil
            }
        }
        return lastFrame
    }

    private func waitForStableWindowedFrame(
        preferredElement: AXUIElement,
        applicationPID: pid_t,
        exactWindowNumber: Int?,
        generation: UInt64
    ) async -> CGRect? {
        let deadline = Date().addingTimeInterval(Self.windowedLayoutAttemptTimeout)
        var lastFrame: CGRect?
        var quietSince: Date?
        while Date() < deadline {
            guard isWindowMutationCurrent(generation),
                  !shouldRecoverWindowMutation(generation),
                  let window = resolveWindowedLayoutTarget(
                    applicationPID: applicationPID,
                    exactWindowNumber: exactWindowNumber,
                    preferredElement: preferredElement
                  ),
                  isStandardWindowForWindowedLayout(window),
                  let currentFrame = frame(of: window) else { return nil }
            if let lastFrame, frameMatches(lastFrame, currentFrame) {
                if quietSince == nil { quietSince = Date() }
            } else {
                quietSince = Date()
            }
            lastFrame = currentFrame
            if let quietSince,
               Date().timeIntervalSince(quietSince) >= Self.windowedLayoutVerificationQuietDuration {
                return currentFrame
            }
            do {
                try await Task.sleep(nanoseconds: Self.windowedLayoutPollNanoseconds)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func classifyWindowedFrameResult(
        before: CGRect,
        target: CGRect,
        final: CGRect
    ) -> FrameUpdateResult {
        let exactPosition = originMatches(final.origin, target.origin)
        let exactSize = sizeMatches(final.size, target.size)
        if exactPosition, exactSize { return .complete }
        let didMove = !originMatches(before.origin, final.origin)
        let didResize = !sizeMatches(before.size, final.size)
        if exactPosition, didMove, !didResize { return .movedOnly }
        if exactSize, didResize, !didMove { return .resizedOnly }
        if didMove || didResize { return .constrained }
        return .failed
    }

    private static func axWindowNumber(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func axStringValue(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Returns a window only when the application's complete AXWindows list
    /// proves there is exactly one manageable standard window. This is the
    /// strict fallback for Apps that omit stable per-window identifiers.
    private static func uniqueStandardWindow(
        processIdentifier: pid_t
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        var uniqueWindows: [AXUIElement] = []
        for window in windows {
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success,
                  pid == processIdentifier,
                  axStringValue(kAXRoleAttribute, of: window) == kAXWindowRole as String,
                  axStringValue(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole as String,
                  axBoolValue("AXModal", of: window) != true else {
                continue
            }
            if !uniqueWindows.contains(where: { CFEqual($0, window) }) {
                uniqueWindows.append(window)
            }
        }
        guard uniqueWindows.count == 1 else { return nil }
        return uniqueWindows[0]
    }

    private static func axBoolValue(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value as? Bool
    }

    private func axElementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func windowSupports(
        _ window: AXUIElement,
        requirement: WindowMutationRequirement
    ) -> Bool {
        let canMove = isAttributeSettable(kAXPositionAttribute, of: window)
        let canResize = isAttributeSettable(kAXSizeAttribute, of: window)
        switch requirement {
        case .moveOrResize:
            return canMove || canResize
        case .move:
            return canMove
        }
    }

    private func ensureAccessibility() -> Bool {
        guard PermissionsManager.shared.checkAccessibility() else {
            reportAccessibilityRequirement()
            return false
        }
        didReportAccessibilityRequirement = false
        return true
    }

    private struct FocusedWindowContext {
        let application: NSRunningApplication
        let window: AXUIElement
        let frame: CGRect
    }

    private enum WindowMutationRequirement {
        case moveOrResize
        case move
    }

    private func focusedWindowContext() -> FocusedWindowContext? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            feedback("请先切换到要管理的窗口")
            return nil
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            feedback("当前 App 没有可管理窗口")
            return nil
        }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        guard let frame = frame(of: window) else {
            feedback("无法读取当前窗口位置")
            return nil
        }
        return FocusedWindowContext(application: application, window: window, frame: frame)
    }

    private func standardFocusedWindowContext() -> FocusedWindowContext? {
        guard let context = focusedWindowContext() else { return nil }
        guard context.application.activationPolicy == .regular else {
            feedback("系统窗口不支持布局操作")
            return nil
        }

        let role = axStringAttribute(kAXRoleAttribute, of: context.window)
        let subrole = axStringAttribute(kAXSubroleAttribute, of: context.window)
        guard role == kAXWindowRole as String,
              subrole == kAXStandardWindowSubrole as String,
              axBoolAttribute("AXModal", of: context.window) != true else {
            feedback("当前窗口不是可管理的标准窗口")
            return nil
        }
        return context
    }

    private func manageableWindowContext(
        _ context: FocusedWindowContext,
        requirement: WindowMutationRequirement
    ) -> FocusedWindowContext? {
        guard axBoolAttribute("AXFullScreen", of: context.window) != true else {
            feedback("全屏状态正在变化，请稍后重试")
            return nil
        }
        let canMove = isAttributeSettable(kAXPositionAttribute, of: context.window)
        let canResize = isAttributeSettable(kAXSizeAttribute, of: context.window)
        switch requirement {
        case .moveOrResize:
            guard canMove || canResize else {
                feedback("当前窗口不允许移动或缩放")
                return nil
            }
        case .move:
            guard canMove else {
                feedback("当前窗口不允许移动")
                return nil
            }
        }
        return context
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private enum FrameUpdateResult {
        case complete
        case movedOnly
        case resizedOnly
        case constrained
        case failed
    }

    private struct FrameWriteOutcome {
        let result: FrameUpdateResult
        let before: CGRect
        let after: CGRect
        let sizeWriteAccepted: Bool
        let positionWriteAccepted: Bool
    }

    private struct StableWindowedFrameOutcome {
        let result: FrameUpdateResult
        let finalFrame: CGRect
    }

    private enum GeometryUpdateResult: Equatable {
        case exact
        case constrained
        case failed
    }

    private func setFrame(
        _ target: CGRect,
        within safeBounds: CGRect,
        for window: AXUIElement
    ) -> FrameUpdateResult {
        writeFrame(target, within: safeBounds, for: window)?.result ?? .failed
    }

    /// Generic frame writer used by non-layout recovery and centering paths.
    /// The windowed-layout path below intentionally has a stronger commit
    /// sequence and must not leak that compatibility workaround into unrelated
    /// full-screen or recovery transactions.
    private func writeFrame(
        _ target: CGRect,
        within safeBounds: CGRect,
        for window: AXUIElement
    ) -> FrameWriteOutcome? {
        guard target.width > 0,
              target.height > 0,
              let before = frame(of: window) else { return nil }

        let canResize = isAttributeSettable(kAXSizeAttribute, of: window)
        let canMove = isAttributeSettable(kAXPositionAttribute, of: window)
        var sizeWriteAccepted = sizeMatches(before.size, target.size)
        var positionWriteAccepted = false

        if canResize, !sizeMatches(before.size, target.size) {
            sizeWriteAccepted = writeSize(target.size, to: window)
        }

        let afterSize = frame(of: window) ?? before
        let safeOrigin = clampedOrigin(target.origin, size: afterSize.size, within: safeBounds)
        positionWriteAccepted = originMatches(afterSize.origin, safeOrigin)
        if canMove, !originMatches(afterSize.origin, safeOrigin) {
            positionWriteAccepted = writePosition(safeOrigin, to: window)
        }

        guard let after = frame(of: window) else { return nil }
        let exactPosition = originMatches(after.origin, target.origin)
        let exactSize = sizeMatches(after.size, target.size)
        let result: FrameUpdateResult
        if exactPosition, exactSize {
            result = .complete
        } else {
            let didMove = !originMatches(before.origin, after.origin)
            let didResize = !sizeMatches(before.size, after.size)
            if exactPosition, didMove, !didResize {
                result = .movedOnly
            } else if exactSize, didResize, !didMove {
                result = .resizedOnly
            } else if didMove || didResize {
                result = .constrained
            } else {
                result = .failed
            }
        }
        return FrameWriteOutcome(
            result: result,
            before: before,
            after: after,
            sizeWriteAccepted: sizeWriteAccepted,
            positionWriteAccepted: positionWriteAccepted
        )
    }

    /// Commits a non-full-screen layout in the same synchronous order used by
    /// WINS: target size, target position, then target size again. Native
    /// AppKit tile groups can reassert size when position changes, so the final
    /// size write is required even when the first readback looked exact.
    ///
    /// Some Apps expose AXEnhancedUserInterface at the application level while
    /// participating in native tiling. If it is explicitly enabled, disable it
    /// only for these three synchronous AX writes and restore it before any
    /// asynchronous stability wait. Unsupported Apps continue normally.
    private func writeWindowedLayoutFrame(
        _ target: CGRect,
        within safeBounds: CGRect,
        for window: AXUIElement,
        applicationPID: pid_t
    ) -> FrameWriteOutcome? {
        guard target.width > 0,
              target.height > 0,
              let before = frame(of: window) else { return nil }

        let applicationElement = AXUIElementCreateApplication(applicationPID)
        let enhancedAttribute = "AXEnhancedUserInterface"
        let enhancedWasEnabled = axBoolAttribute(enhancedAttribute, of: applicationElement) == true
        let didDisableEnhancedUI = enhancedWasEnabled &&
            writeBoolAttribute(false, named: enhancedAttribute, to: applicationElement)
        if enhancedWasEnabled, !didDisableEnhancedUI {
            NSLog(
                "[WindowEnhancement] failed to disable AXEnhancedUserInterface pid=%d",
                applicationPID
            )
        }
        defer {
            if enhancedWasEnabled {
                let firstRestoreAccepted = writeBoolAttribute(
                    true,
                    named: enhancedAttribute,
                    to: applicationElement
                )
                if !firstRestoreAccepted,
                   !writeBoolAttribute(true, named: enhancedAttribute, to: applicationElement) {
                    NSLog(
                        "[WindowEnhancement] failed to restore AXEnhancedUserInterface pid=%d",
                        applicationPID
                    )
                }
            }
        }

        let canResize = isAttributeSettable(kAXSizeAttribute, of: window)
        let canMove = isAttributeSettable(kAXPositionAttribute, of: window)
        let safeOrigin = clampedOrigin(
            target.origin,
            size: canResize ? target.size : before.size,
            within: safeBounds
        )

        var firstSizeWriteAccepted = sizeMatches(before.size, target.size)
        if canResize {
            firstSizeWriteAccepted = writeSize(target.size, to: window)
        }

        var positionWriteAccepted = originMatches(before.origin, safeOrigin)
        if canMove {
            positionWriteAccepted = writePosition(safeOrigin, to: window)
        }

        var secondSizeWriteAccepted = sizeMatches(before.size, target.size)
        if canResize {
            secondSizeWriteAccepted = writeSize(target.size, to: window)
        }

        guard let after = frame(of: window) else { return nil }
        let exactPosition = originMatches(after.origin, safeOrigin)
        let exactSize = sizeMatches(after.size, target.size)
        let result: FrameUpdateResult
        if exactPosition, exactSize {
            result = .complete
        } else {
            let didMove = !originMatches(before.origin, after.origin)
            let didResize = !sizeMatches(before.size, after.size)
            if exactPosition, didMove, !didResize {
                result = .movedOnly
            } else if exactSize, didResize, !didMove {
                result = .resizedOnly
            } else if didMove || didResize {
                result = .constrained
            } else {
                result = .failed
            }
        }
        return FrameWriteOutcome(
            result: result,
            before: before,
            after: after,
            sizeWriteAccepted: firstSizeWriteAccepted && secondSizeWriteAccepted,
            positionWriteAccepted: positionWriteAccepted
        )
    }

    private func setPosition(_ target: CGPoint, for window: AXUIElement) -> GeometryUpdateResult {
        guard let before = frame(of: window) else { return .failed }
        if originMatches(before.origin, target) { return .exact }
        guard isAttributeSettable(kAXPositionAttribute, of: window),
              writePosition(target, to: window),
              let after = frame(of: window) else { return .failed }
        if originMatches(after.origin, target) { return .exact }
        return originMatches(before.origin, after.origin) ? .failed : .constrained
    }

    private func setSize(_ target: CGSize, for window: AXUIElement) -> GeometryUpdateResult {
        guard target.width > 0,
              target.height > 0,
              let before = frame(of: window) else { return .failed }
        if sizeMatches(before.size, target) { return .exact }
        guard isAttributeSettable(kAXSizeAttribute, of: window),
              writeSize(target, to: window),
              let after = frame(of: window) else { return .failed }
        if sizeMatches(after.size, target) { return .exact }
        return sizeMatches(before.size, after.size) ? .failed : .constrained
    }

    private func writePosition(_ position: CGPoint, to window: AXUIElement) -> Bool {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    private func writeSize(_ size: CGSize, to window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            value
        ) == .success
    }

    private func writeBoolAttribute(
        _ value: Bool,
        named name: String,
        to element: AXUIElement
    ) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            name as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }

    private func isAttributeSettable(_ name: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            name as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private func originMatches(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= Self.geometryTolerance &&
            abs(lhs.y - rhs.y) <= Self.geometryTolerance
    }

    private func sizeMatches(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= Self.geometryTolerance &&
            abs(lhs.height - rhs.height) <= Self.geometryTolerance
    }

    private func frameMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        originMatches(lhs.origin, rhs.origin) && sizeMatches(lhs.size, rhs.size)
    }

    private func clampedOrigin(
        _ origin: CGPoint,
        size: CGSize,
        within bounds: CGRect
    ) -> CGPoint {
        let maximumX = max(bounds.minX, bounds.maxX - size.width)
        let maximumY = max(bounds.minY, bounds.maxY - size.height)
        return CGPoint(
            x: min(max(origin.x, bounds.minX), maximumX),
            y: min(max(origin.y, bounds.minY), maximumY)
        )
    }

    private func axStringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axBoolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func screen(containingAXFrame frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { cgBounds(for: $0).contains(center) }
    }

    private func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            self.displayID(for: screen) == displayID
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func displayID(forAXFrame frame: CGRect) -> CGDirectDisplayID? {
        guard let screen = screen(containingAXFrame: frame) else { return nil }
        return displayID(for: screen)
    }

    private func orderedScreens() -> [NSScreen] {
        NSScreen.screens.sorted { lhs, rhs in
            let a = cgBounds(for: lhs)
            let b = cgBounds(for: rhs)
            return a.minX == b.minX ? a.minY < b.minY : a.minX < b.minX
        }
    }

    private func adjacentScreen(
        from displayID: CGDirectDisplayID,
        offset: Int
    ) -> NSScreen? {
        let screens = orderedScreens()
        guard screens.count > 1,
              let currentIndex = screens.firstIndex(where: { self.displayID(for: $0) == displayID }) else {
            return nil
        }
        let nextIndex = (currentIndex + offset + screens.count) % screens.count
        return screens[nextIndex]
    }

    private func cgBounds(for screen: NSScreen) -> CGRect {
        guard let displayID = displayID(for: screen) else {
            return screen.frame
        }
        return CGDisplayBounds(displayID)
    }

    private func usableAXFrame(for screen: NSScreen) -> CGRect {
        let full = cgBounds(for: screen)
        let visible = screen.visibleFrame
        let leftInset = max(0, visible.minX - screen.frame.minX)
        let rightInset = max(0, screen.frame.maxX - visible.maxX)
        let topInset = max(0, screen.frame.maxY - visible.maxY)
        let bottomInset = max(0, visible.minY - screen.frame.minY)
        var result = CGRect(
            x: full.minX + leftInset,
            y: full.minY + topInset,
            width: full.width - leftInset - rightInset,
            height: full.height - topInset - bottomInset
        )
        if preferences.reserveStageManagerSpace {
            result.origin.x += 72
            result.size.width = max(200, result.width - 72)
        }
        return result
    }

    private func layoutFrame(_ layout: WindowLayout, in available: CGRect) -> CGRect {
        let gap: CGFloat = preferences.windowSpacingEnabled ? 8 : 0
        let inset = available.insetBy(dx: gap, dy: gap)
        let halfWidth = (inset.width - gap) / 2
        let halfHeight = (inset.height - gap) / 2
        let thirdWidth = (inset.width - gap * 2) / 3
        switch layout {
        case .leftHalf:
            return CGRect(x: inset.minX, y: inset.minY, width: halfWidth, height: inset.height)
        case .rightHalf:
            return CGRect(x: inset.maxX - halfWidth, y: inset.minY, width: halfWidth, height: inset.height)
        case .maximize:
            return inset
        case .leftThird:
            return CGRect(x: inset.minX, y: inset.minY, width: thirdWidth, height: inset.height)
        case .centerThird:
            return CGRect(x: inset.minX + thirdWidth + gap, y: inset.minY, width: thirdWidth, height: inset.height)
        case .rightThird:
            return CGRect(x: inset.maxX - thirdWidth, y: inset.minY, width: thirdWidth, height: inset.height)
        case .topHalf:
            return CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: inset.minX, y: inset.maxY - halfHeight, width: inset.width, height: halfHeight)
        case .leftTwoThirds:
            return CGRect(x: inset.minX, y: inset.minY, width: thirdWidth * 2 + gap, height: inset.height)
        case .rightTwoThirds:
            return CGRect(x: inset.maxX - thirdWidth * 2 - gap, y: inset.minY, width: thirdWidth * 2 + gap, height: inset.height)
        case .topLeftQuarter:
            return CGRect(x: inset.minX, y: inset.minY, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: inset.maxX - halfWidth, y: inset.minY, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: inset.minX, y: inset.maxY - halfHeight, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: inset.maxX - halfWidth, y: inset.maxY - halfHeight, width: halfWidth, height: halfHeight)
        }
    }

    private func feedback(_ message: String) {
        preferences.publishFeedback(message)
        if IslandWindowController.canPresentWindowEnhancementFeedback {
            feedbackPresenter.hide()
        } else {
            feedbackPresenter.show(message)
        }
    }

    private func shouldRegisterShortcut(_ target: String) -> Bool {
        if let action = WindowQuickAction.allCases.first(where: { $0.shortcutID == target }),
           !preferences.isActionEnabled(action) {
            return false
        }
        if (target == WindowQuickAction.closeWindow.shortcutID ||
            target == WindowQuickAction.quitApp.shortcutID),
           !preferences.missionControlEnabled {
            return false
        }
        return true
    }

    private func reportEnabledFeaturePermissionIfNeeded() {
        guard !PermissionsManager.shared.checkAccessibility() else {
            didReportAccessibilityRequirement = false
            return
        }
        let mouseFeatureEnabled = preferences.edgeSnapEnabled ||
            preferences.snapIslandEnabled ||
            preferences.aeroShakeEnabled ||
            preferences.dockPreviewEnabled ||
            preferences.dockReverseEnabled ||
            preferences.cmdTabPlusEnabled
        let activeShortcutConfigured = preferences.shortcuts.keys.contains {
            shouldRegisterShortcut($0)
        }
        if preferences.isEnabled, mouseFeatureEnabled || activeShortcutConfigured {
            reportAccessibilityRequirement()
        }
    }

    private func targetDisplayName(_ id: String) -> String {
        if let layout = WindowLayout.allCases.first(where: { $0.shortcutID == id }) {
            return layout.title
        }
        if let action = WindowQuickAction.allCases.first(where: { $0.shortcutID == id }) {
            return action.title
        }
        return id
    }
}

private final class WindowHotKeyRegistry {
    private static let signature: OSType = 0x53495745 // SIWE
    private var eventHandler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var targets: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    var onTrigger: ((String) -> Void)?

    func install() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                guard hotKeyID.signature == WindowHotKeyRegistry.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let registry = Unmanaged<WindowHotKeyRegistry>.fromOpaque(userData).takeUnretainedValue()
                guard let target = registry.targets[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { registry.onTrigger?(target) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    @discardableResult
    func register(_ shortcut: WindowShortcut, target: String) -> OSStatus {
        let id = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr, let reference {
            references[id] = reference
            targets[id] = target
        }
        return status
    }

    func removeAll() {
        references.values.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        targets.removeAll()
    }

    func uninstall() {
        removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}

@MainActor
private final class WindowEnhancementFeedbackPresenter {
    private let panel: NSPanel
    private let messageLabel: NSTextField
    private var hideWorkItem: DispatchWorkItem?
    private var presentationGeneration = 0
    private var lastPresentedAt: [String: Date] = [:]

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.75
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: "窗口增强"
        ) ?? NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "窗口增强"
        )
        iconView.contentTintColor = .white.withAlphaComponent(0.88)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 21),
            iconView.heightAnchor.constraint(equalToConstant: 21)
        ])

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .white.withAlphaComponent(0.94)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.cell?.wraps = true

        let stack = NSStackView(views: [iconView, messageLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -12)
        ])
        panel.contentView = effectView
    }

    func show(_ message: String) {
        let now = Date()
        if let last = lastPresentedAt[message], now.timeIntervalSince(last) < 1.5, panel.isVisible {
            scheduleDismiss()
            return
        }
        lastPresentedAt[message] = now
        if lastPresentedAt.count > 24 {
            lastPresentedAt = lastPresentedAt.filter { now.timeIntervalSince($0.value) < 30 }
        }

        messageLabel.stringValue = message
        let font = messageLabel.font ?? .systemFont(ofSize: 13, weight: .medium)
        let textBounds = (message as NSString).boundingRect(
            with: CGSize(width: 370, height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let size = CGSize(
            width: min(460, max(240, ceil(textBounds.width) + 70)),
            height: min(88, max(52, ceil(textBounds.height) + 26))
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let targetFrame = CGRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 54,
            width: size.width,
            height: size.height
        )
        panel.setFrame(targetFrame, display: true)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if panel.isVisible || reduceMotion {
            panel.alphaValue = 1
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        scheduleDismiss()
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        presentationGeneration &+= 1
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    private func scheduleDismiss() {
        hideWorkItem?.cancel()
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.hideWorkItem = nil
            self.dismissAnimated(generation: generation)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1, execute: item)
    }

    private func dismissAnimated(generation: Int) {
        guard panel.isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.presentationGeneration else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }
}
