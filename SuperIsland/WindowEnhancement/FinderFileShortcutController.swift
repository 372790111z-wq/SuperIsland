import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

/// A separate Carbon registration, present only while Finder is frontmost.
/// This deliberately does not add a tap or synthesize a keyboard/mouse event.
@MainActor
final class FinderFileShortcutController {
    private let preferences: WindowEnhancementPreferences
    private let executor = FinderTrashExecutor()
    private let registry = FinderFileHotKeyRegistry()
    private let feedback: (String) -> Void
    private var gate = FinderShortcutPressGate()
    private var observers: [NSObjectProtocol] = []
    private var configurationObserver: AnyCancellable?
    private var releaseTimer: Timer?
    private var started = false
    private var sessionActive = true
    private var awake = true
    private var failedContext: FinderShortcutPressGate.Context?

    init(preferences: WindowEnhancementPreferences, feedback: @escaping (String) -> Void) {
        self.preferences = preferences
        self.feedback = feedback
        registry.onEvent = { [weak self] id, pressed, eventTime in
            self?.receive(id: id, pressed: pressed, eventTime: eventTime)
        }
    }

    func start() {
        guard !started else { refresh(); return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notice.name == NSWorkspace.didActivateApplicationNotification {
                        self.disarm()
                        self.refresh()
                    } else if notice.name == NSWorkspace.didDeactivateApplicationNotification {
                        let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                        if app?.processIdentifier == self.gate.context?.pid { self.disarm() }
                    } else {
                        if notice.name == NSWorkspace.willSleepNotification { self.awake = false }
                        else { self.sessionActive = false }
                        self.disarm()
                    }
                }
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notice.name == NSWorkspace.didWakeNotification { self.awake = true }
                    else { self.sessionActive = true }
                    self.refresh()
                }
            })
        }
        configurationObserver = preferences.configurationChanges.sink { [weak self] in
            self?.disarm()
            // @Published emits before the property write. Read the new values
            // on the next run-loop turn, never retain a pending file action.
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        started = false
        configurationObserver?.cancel()
        configurationObserver = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        disarm()
        registry.uninstall()
    }

    func refresh() {
        guard let context = eligibleContext() else { disarm(); return }
        if context != gate.context {
            disarm()
            gate.configure(context, keyIsDown: keyIsDown(context.keyCode))
        }
        guard registry.activeID == nil else { return }
        guard !gate.requiresRelease else { waitForRelease(); return }
        guard failedContext != context else { return }
        let status = registry.register(keyCode: context.keyCode, modifiers: context.modifiers)
        if status != noErr {
            failedContext = context
            if let shortcut = preferences.shortcut(for: FinderFileShortcut.id) {
                _ = preferences.rollbackShortcutRegistration(shortcut, for: FinderFileShortcut.id)
            }
            feedback("文件快捷键不可用，请重新设置")
        } else if let shortcut = preferences.shortcut(for: FinderFileShortcut.id) {
            preferences.finishShortcutRegistration(shortcut, for: FinderFileShortcut.id)
        }
    }

    private func eligibleContext() -> FinderShortcutPressGate.Context? {
        guard started, awake, sessionActive, preferences.isEnabled, preferences.fileTrashEnabled,
              let shortcut = preferences.shortcut(for: FinderFileShortcut.id),
              shortcut.modifiers != 0, shortcut.keyCode <= UInt32(UInt16.max),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.finder", !app.isTerminated,
              !preferences.isExcluded(app) else { return nil }
        return .init(pid: app.processIdentifier, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    private func disarm() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        registry.unregister()
        gate.invalidate()
        failedContext = nil
    }

    private func receive(id: UInt32, pressed: Bool, eventTime: EventTime) {
        guard registry.activeID == id, let context = gate.context,
              eligibleContext() == context else { refresh(); return }
        if !pressed {
            let down = keyIsDown(context.keyCode)
            gate.observeRelease(keyIsDown: down)
            if !down { registry.observePhysicalRelease() }
            if gate.requiresRelease { waitForRelease() }
            return
        }
        let generation = gate.generation
        guard let lifetime = FinderShortcutEventLifetime(eventTime: eventTime, now: GetCurrentEventTime()),
              keyIsDown(context.keyCode) else { return }
        guard gate.press(generation: generation) else { return }
        waitForRelease()
        let outcome = executor.perform(expectedPID: context.pid) { [weak self] in
            guard let self else { return false }
            // Once claimed, a normal key-up must not cancel the same action.
            // Its context and original event deadline still apply to every AX read.
            return self.registry.activeID == id && self.gate.isCurrent(generation) &&
                self.eligibleContext() == context && lifetime.isCurrent(now: GetCurrentEventTime())
        }
        guard gate.isCurrent(generation) else { return }
        feedback(outcome.message)
    }

    private func keyIsDown(_ keyCode: UInt32) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func waitForRelease() {
        guard releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let context = self.gate.context else { return }
                guard self.eligibleContext() == context else { self.disarm(); return }
                self.gate.observeRelease(keyIsDown: self.keyIsDown(context.keyCode))
                if !self.gate.requiresRelease {
                    self.registry.observePhysicalRelease()
                    self.releaseTimer?.invalidate()
                    self.releaseTimer = nil
                    self.refresh()
                }
            }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private final class FinderFileHotKeyRegistry {
    private static let signature: OSType = 0x53494654 // SIFT, separate from SIWE
    private var eventHandler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private var nextID: UInt32 = 0
    private var queuedPressGate = FinderShortcutQueuedPressGate()
    private(set) var activeID: UInt32?
    var onEvent: ((UInt32, Bool, EventTime) -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        let installStatus = install()
        guard installStatus == noErr else { return installStatus }
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, reference != nil { activeID = nextID }
        else { unregister() }
        return status
    }

    func unregister() {
        activeID = nil
        queuedPressGate.release()
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    func observePhysicalRelease() { queuedPressGate.release() }

    func uninstall() {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func install() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == FinderFileHotKeyRegistry.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let registry = Unmanaged<FinderFileHotKeyRegistry>.fromOpaque(userData).takeUnretainedValue()
            guard registry.activeID == id.id else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let receivedID = id.id
            let eventTime = GetEventTime(event)
            // Invalidate an unclaimed press before either callback is queued.
            // Otherwise an old press could borrow a later physical key cycle.
            if !pressed { registry.queuedPressGate.release() }
            let ticket = pressed ? registry.queuedPressGate.enqueuePress() : nil
            if pressed, ticket == nil { return noErr }
            DispatchQueue.main.async { [weak registry] in
                guard let registry, registry.activeID == receivedID else { return }
                if let ticket, !registry.queuedPressGate.isCurrent(ticket) { return }
                registry.onEvent?(receivedID, pressed, eventTime)
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}
