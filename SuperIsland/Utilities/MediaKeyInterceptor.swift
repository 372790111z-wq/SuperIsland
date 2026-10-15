import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem
import Combine

/// Intercepts the hardware volume keys (F10/F11/F12 or touch-bar / keyboard-row
/// equivalents) via a session-level `CGEventTap` so the macOS system overlay
/// (`OSDUIHelper`) never receives the event. The volume change is then applied
/// programmatically via `VolumeManager` and SuperIsland's own HUD is shown.
///
/// The tap runs in `.defaultTap` mode which lets the callback return `nil` to
/// consume the event. Consuming before the OS dispatches to `OSDUIHelper` is
/// what actually prevents the system HUD from drawing — simply killing the
/// helper after the fact is too late, because the overlay has already been
/// queued for display by the time any `CoreAudio` listener fires.
///
/// Requires Accessibility permission. If permission isn't granted when the
/// tap is requested, the interceptor keeps polling (and re-installs whenever
/// the app regains focus) so the tap activates as soon as the user flips the
/// switch in System Settings.
final class MediaKeyInterceptor: ObservableObject {
    static let shared = MediaKeyInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var brightnessObservationTap: CFMachPort?
    private var brightnessObservationSource: CFRunLoopSource?
    private var desiredEnabled = false
    private var volumeEnabled = false
    private var brightnessEnabled = false
    private var retryTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastObservedKey: (code: Int, timestamp: TimeInterval)?
    @Published private(set) var statusText = "系统调节监听未启用"
    @Published private(set) var brightnessKeyStatusText = "键盘亮度监听未启用"

    /// Volume adjustment per keypress. Matches macOS's default step (1/16).
    private static let volumeStep: Float = 1.0 / 16.0
    /// Finer step used when Shift+Option is held, matching macOS behavior.
    private static let fineVolumeStep: Float = 1.0 / 64.0

    // HID key codes for media keys. Defined in <IOKit/hidsystem/ev_keymap.h>
    // but the symbols aren't bridged into Swift, so we define them here.
    private static let NX_KEYTYPE_SOUND_UP: Int = 0
    private static let NX_KEYTYPE_SOUND_DOWN: Int = 1
    private static let NX_KEYTYPE_MUTE: Int = 7
    private static let NX_KEYTYPE_BRIGHTNESS_UP: Int = 2
    private static let NX_KEYTYPE_BRIGHTNESS_DOWN: Int = 3
    private static let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
    private static let NX_SYSDEFINED_EVENT_TYPE: UInt32 = 14

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidBecomeActive),
            name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(appDidBecomeActive),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    /// Install or remove the event tap based on the user preference.
    func apply(enabled: Bool) {
        apply(volumeEnabled: enabled, brightnessEnabled: false)
    }

    func apply(volumeEnabled: Bool, brightnessEnabled: Bool) {
        self.volumeEnabled = volumeEnabled
        self.brightnessEnabled = brightnessEnabled
        desiredEnabled = volumeEnabled || brightnessEnabled
        if desiredEnabled {
            install()
            installObservationFallback()
            installBrightnessObservation()
            if eventTap == nil {
                // Missing Accessibility permission, most likely. Keep retrying
                // until the user grants it so the setting "just starts working."
                scheduleRetry()
            }
        } else {
            uninstall()
            cancelRetry()
            statusText = "系统调节监听未启用"
        }
    }

    /// `true` if the event tap is currently installed and active.
    var isInstalled: Bool { eventTap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false }

    // MARK: - Install / Uninstall

    private func install() {
        if let eventTap {
            if CFMachPortIsValid(eventTap) {
                if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
                return
            }
            uninstall()
        }

        guard PermissionsManager.shared.checkAccessibility() else {
            // Background retries must stay silent. Re-requesting here causes the
            // macOS Accessibility dialog to reappear immediately after dismissal.
            // The user can explicitly request access from Settings instead.
            NSLog("[MediaKeyInterceptor] Accessibility permission not granted — waiting for explicit user action.")
            return
        }

        let eventMask: CGEventMask = CGEventMask(1) << CGEventMask(Self.NX_SYSDEFINED_EVENT_TYPE)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            MediaKeyInterceptor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        ) else {
            NSLog("[MediaKeyInterceptor] CGEvent.tapCreate returned nil (Accessibility likely denied for this build).")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        statusText = "系统调节监听已连接；等待调节键"
        NSLog("[MediaKeyInterceptor] Event tap installed.")
    }

    private func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        runLoopSource = nil
        removeBrightnessObservation()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        lastObservedKey = nil
    }

    /// AppKit's delivered-event path is observation only. It covers events
    /// which a session tap does not receive and never applies a second change.
    private func installObservationFallback() {
        guard PermissionsManager.shared.checkAccessibility() else {
            statusText = "系统调节提示需要辅助功能权限"
            return
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
                Self.observeDeliveredEvent(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { event in
                Self.observeDeliveredEvent(event)
                return event
            }
        }
    }

    /// Observe brightness before session filters (for example display tools)
    /// can consume its media-key event. This tap never changes or consumes it.
    /// Preflight only: never request broader input access in the background.
    private func installBrightnessObservation() {
        guard brightnessEnabled else { removeBrightnessObservation(); return }
        if let tap = brightnessObservationTap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        removeBrightnessObservation()
        guard CGPreflightListenEventAccess() else {
            brightnessKeyStatusText = "键盘使用兼容监听；提前读取亮度键需要输入监控权限"
            SystemFeedbackDiagnostics.write("brightnessKeyObservation", fields: ["earlyTapInstalled": false, "existingInputAccess": false])
            return
        }
        let mask = CGEventMask(1) << CGEventMask(Self.NX_SYSDEFINED_EVENT_TYPE)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MediaKeyInterceptor.shared.brightnessObservationTap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type.rawValue == MediaKeyInterceptor.NX_SYSDEFINED_EVENT_TYPE,
                      let delivered = NSEvent(cgEvent: event),
                      let key = MediaKeyInterceptor.brightnessKeyDown(subtype: delivered.subtype.rawValue, data1: delivered.data1),
                      MediaKeyInterceptor.shared.brightnessEnabled, MediaKeyInterceptor.shared.recordKey(key, timestamp: delivered.timestamp) {
                Task { @MainActor in ScreenBrightnessManager.shared.noteUserInitiatedChange() }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            brightnessKeyStatusText = "键盘使用兼容监听；系统未开放提前读取通道"
            SystemFeedbackDiagnostics.write("brightnessKeyObservation", fields: ["earlyTapInstalled": false, "existingInputAccess": true])
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        brightnessObservationTap = tap
        brightnessObservationSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        brightnessKeyStatusText = "键盘亮度监听已连接"
        SystemFeedbackDiagnostics.write("brightnessKeyObservation", fields: ["earlyTapInstalled": true, "existingInputAccess": true])
    }

    private func removeBrightnessObservation() {
        if let tap = brightnessObservationTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = brightnessObservationSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = brightnessObservationTap { CFMachPortInvalidate(tap) }
        brightnessObservationTap = nil
        brightnessObservationSource = nil
        brightnessKeyStatusText = "键盘亮度监听未启用"
    }

    static func brightnessKeyDown(subtype: Int16, data1: Int) -> Int? {
        guard let key = mediaKeyDown(subtype: subtype, data1: data1), key == 2 || key == 3 else { return nil }
        return key
    }

    static func mediaKeyDown(subtype: Int16, data1: Int) -> Int? {
        guard subtype == NX_SUBTYPE_AUX_CONTROL_BUTTONS,
              ((data1 & 0xFF00) >> 8) == 0x0A else { return nil }
        let key = (data1 >> 16) & 0xFFFF
        return [0, 1, 2, 3, 7].contains(key) ? key : nil
    }

    private static func observeDeliveredEvent(_ event: NSEvent) {
        guard let key = mediaKeyDown(subtype: event.subtype.rawValue, data1: event.data1),
              shared.recordKey(key, timestamp: event.timestamp) else { return }
        switch key {
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            if shared.brightnessEnabled {
                Task { @MainActor in ScreenBrightnessManager.shared.noteUserInitiatedChange() }
            }
        default:
            if shared.volumeEnabled {
                Task { @MainActor in VolumeManager.shared.refreshAfterSystemKeyChange() }
            }
        }
    }

    private func recordKey(_ code: Int, timestamp: TimeInterval) -> Bool {
        if let lastObservedKey, lastObservedKey.code == code,
           abs(lastObservedKey.timestamp - timestamp) < 0.001 { return false }
        lastObservedKey = (code, timestamp)
        statusText = (code == 2 || code == 3) ? "已收到屏幕亮度调节键" : "已收到音量调节键"
        if code == 2 || code == 3 { brightnessKeyStatusText = "已收到屏幕亮度调节键" }
        Task { @MainActor in
            let state = AppState.shared
            SystemFeedbackDiagnostics.write("lastAdjustmentKey", fields: ["kind": (code == 2 || code == 3) ? "brightness" : "volume", "isCompact": state.currentState == .compact, "interactionSuppressed": state.isZilanInteractionSuppressed, "volumeEnabled": state.volumeHUDEnabled, "brightnessEnabled": state.brightnessHUDEnabled])
        }
        return true
    }

    // MARK: - Retry

    private func scheduleRetry() {
        cancelRetry()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.desiredEnabled else {
                self.cancelRetry()
                return
            }
            if self.eventTap == nil {
                self.install()
                self.installObservationFallback()
            }
            if self.eventTap != nil {
                self.cancelRetry()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    @objc private func appDidBecomeActive() {
        // Coming back from System Settings is a strong signal the user may
        // have just granted Accessibility — try immediately.
        guard desiredEnabled else { return }
        install()
        installObservationFallback()
        installBrightnessObservation()
    }

    // MARK: - Callback

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS may disable the tap if it misbehaves or times out. Re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = MediaKeyInterceptor.shared.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == NX_SYSDEFINED_EVENT_TYPE,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isNewKey = isKeyDown && mediaKeyDown(subtype: nsEvent.subtype.rawValue, data1: data1) != nil
            && shared.recordKey(keyCode, timestamp: nsEvent.timestamp)

        switch keyCode {
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            if isNewKey, shared.brightnessEnabled {
                Task { @MainActor in ScreenBrightnessManager.shared.noteUserInitiatedChange() }
            }
            // macOS owns the brightness change, including fine adjustments.
            return Unmanaged.passUnretained(event)
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN:
            guard shared.volumeEnabled else {
                return Unmanaged.passUnretained(event)
            }
            guard VolumeManager.canAdjustCurrentOutputVolume() else {
                if isKeyDown { Task { @MainActor in VolumeManager.shared.refreshAfterSystemKeyChange() } }
                return Unmanaged.passUnretained(event)
            }
            if isKeyDown {
                let modifiers = nsEvent.modifierFlags
                let fine = modifiers.contains(.shift) && modifiers.contains(.option)
                let step = fine ? fineVolumeStep : volumeStep
                let delta: Float = keyCode == NX_KEYTYPE_SOUND_UP ? step : -step
                applyVolumeDelta(delta)
            }
            return nil
        case NX_KEYTYPE_MUTE:
            guard shared.volumeEnabled else {
                return Unmanaged.passUnretained(event)
            }
            guard VolumeManager.canAdjustCurrentOutputMute() else {
                if isKeyDown { Task { @MainActor in VolumeManager.shared.refreshAfterSystemKeyChange() } }
                return Unmanaged.passUnretained(event)
            }
            if isKeyDown {
                applyToggleMute()
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Volume application

    private static func applyVolumeDelta(_ delta: Float) {
        Task { @MainActor in
            let manager = VolumeManager.shared
            // If currently muted, a volume-up press should unmute first
            // (matches default macOS behavior).
            if manager.isMuted, delta > 0 {
                manager.toggleMute()
            }
            let current = manager.volume
            let next = max(0, min(1, current + delta))
            manager.setVolume(next)
        }
    }

    private static func applyToggleMute() {
        Task { @MainActor in
            VolumeManager.shared.toggleMute()
        }
    }
}
