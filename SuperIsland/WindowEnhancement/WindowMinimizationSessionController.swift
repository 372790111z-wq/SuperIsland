import AppKit
import ApplicationServices
import CoreGraphics

/// Owns one reversible hide/minimize batch.
///
/// WINS treats "隐藏所有窗口" and "隐藏其他窗口" as toggles. The second
/// invocation must restore only the windows hidden by the first invocation;
/// windows that were already minimized before the action are never adopted by
/// this session.
@MainActor
final class WindowMinimizationSessionController {
    enum Mode: Equatable {
        case all
        case others

        var keepingFocusedWindow: Bool { self == .others }
    }

    enum Outcome {
        case minimized(mode: Mode, succeeded: Int, pending: Int, failed: Int)
        case restored(mode: Mode, succeeded: Int, pending: Int, failed: Int, missing: Int)
        case nothingToMinimize(mode: Mode)
        case nothingToRestore(mode: Mode)
        case missingFocusedWindow
    }

    struct Application {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
    }

    /// The production backend uses AX; tests replace these operations without
    /// enumerating, minimizing, raising, or activating real windows.
    struct Environment {
        var ownProcessIdentifier: pid_t
        var applications: () -> [Application]
        var frontmostProcessIdentifier: () -> pid_t?
        var isApplicationRunning: (pid_t) -> Bool
        var activateApplication: (pid_t) -> Void
        var windowOrder: () -> [Int: Int]
        var focusedWindow: () -> AXUIElement?
        var windows: (pid_t) -> (succeeded: Bool, windows: [AXUIElement])
        var processIdentifier: (AXUIElement) -> pid_t?
        var isOrdinaryWindow: (AXUIElement) -> Bool
        var windowNumber: (AXUIElement) -> Int?
        var identifier: (AXUIElement) -> String?
        var minimized: (AXUIElement) -> Bool?
        var canMinimize: (AXUIElement) -> Bool
        var setMinimized: (AXUIElement, Bool) -> AXError
        var raiseWindow: (AXUIElement) -> Void
        var now: () -> Date
    }

    private enum Phase {
        case minimizeRequested, minimized, restoreRequested
    }

    private struct WindowReference {
        let processIdentifier: pid_t
        let windowNumber: Int?
        let identifier: String?
        let originalElement: AXUIElement
        let frontToBackOrder: Int
        var missingObservationCount: Int
        var firstMissingObservationAt: Date?
        var phase: Phase
    }

    private enum WindowResolution {
        case found(AXUIElement)
        case applicationTerminated
        case notFoundInSuccessfulSnapshot
        case temporarilyUnavailable
    }

    private struct Session {
        let mode: Mode
        let originalFrontmostPID: pid_t?
        var windows: [WindowReference]
        var activationHandled = false
    }

    private let environment: Environment
    private var session: Session?

    init(environment: Environment? = nil) {
        self.environment = environment ?? Self.liveEnvironment()
    }

    var activeMode: Mode? { session?.mode }
    var hasActiveSession: Bool { session != nil }

    func restoreActiveSession() -> Outcome? {
        guard let session else { return nil }
        return restore(session)
    }

    func resetWithoutRestoring() {
        session = nil
    }

    func toggle(
        mode: Mode,
        excludingBundleIdentifiers: Set<String>
    ) -> Outcome {
        reconcileCompletedRestores()
        if let session {
            // A hide batch is a single reversible transaction. Triggering
            // either hide action while a batch is active first restores that
            // exact batch, preventing overlapping ownership of the same AX
            // windows and making recovery deterministic.
            return restore(session)
        }
        return minimize(
            mode: mode,
            excludingBundleIdentifiers: excludingBundleIdentifiers
        )
    }

    /// A previously accepted restore may finish after its immediate readback.
    /// Retire only positively restored references here, so the next press can
    /// start a new batch. Missing/terminated references go through restore()
    /// instead, preventing a vanished old batch from adopting new windows.
    private func reconcileCompletedRestores() {
        guard var current = session else { return }
        current.windows.removeAll { reference in
            guard reference.phase == .restoreRequested,
                  case let .found(window) = resolve(reference) else { return false }
            return environment.minimized(window) == false
        }
        session = current.windows.isEmpty ? nil : current
    }

    private func minimize(
        mode: Mode,
        excludingBundleIdentifiers: Set<String>
    ) -> Outcome {
        let focusedWindow: AXUIElement?
        if mode.keepingFocusedWindow {
            guard let focused = environment.focusedWindow() else {
                return .missingFocusedWindow
            }
            focusedWindow = focused
        } else {
            focusedWindow = nil
        }

        let frontOrder = environment.windowOrder()
        let originalFrontmostPID = environment.frontmostProcessIdentifier()
        let applications = environment.applications().filter { application in
            guard application.processIdentifier != environment.ownProcessIdentifier else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return true }
            return !excludingBundleIdentifiers.contains(bundleIdentifier)
        }

        var minimized: [WindowReference] = []
        var confirmed = 0
        var pending = 0
        var failed = 0
        for application in applications {
            let snapshot = environment.windows(application.processIdentifier)
            guard snapshot.succeeded else {
                failed += 1
                continue
            }
            for window in snapshot.windows {
                guard environment.isOrdinaryWindow(window),
                      focusedWindow.map({ !CFEqual(window, $0) }) ?? true,
                      environment.canMinimize(window) else {
                    continue
                }
                guard let wasMinimized = environment.minimized(window) else {
                    failed += 1
                    continue
                }
                guard !wasMinimized else { continue }

                let number = environment.windowNumber(window)
                var reference = WindowReference(
                    processIdentifier: application.processIdentifier,
                    windowNumber: number,
                    identifier: environment.identifier(window),
                    originalElement: window,
                    frontToBackOrder: number.flatMap { frontOrder[$0] } ?? Int.max,
                    missingObservationCount: 0,
                    firstMissingObservationAt: nil,
                    phase: .minimizeRequested
                )
                guard environment.setMinimized(window, true) == .success else {
                    failed += 1
                    continue
                }
                // A successful AX write accepts the request; applications may
                // publish its state only after their minimization animation.
                if environment.minimized(window) == true {
                    reference.phase = .minimized
                    confirmed += 1
                } else {
                    pending += 1
                }
                minimized.append(reference)
            }
        }

        guard !minimized.isEmpty else {
            return failed > 0
                ? .minimized(mode: mode, succeeded: 0, pending: 0, failed: failed)
                : .nothingToMinimize(mode: mode)
        }
        session = Session(
            mode: mode,
            originalFrontmostPID: originalFrontmostPID,
            windows: minimized
        )
        return .minimized(mode: mode, succeeded: confirmed, pending: pending, failed: failed)
    }

    private func restore(_ session: Session) -> Outcome {
        var restored = 0
        var pending = 0
        var failed = 0
        var missing = 0
        var retryable: [WindowReference] = []

        // Restore back-to-front, then raise in the same order. The final raise
        // therefore returns the original front-most member of this batch to
        // the top without activating every application along the way.
        let ordered = session.windows.sorted {
            $0.frontToBackOrder > $1.frontToBackOrder
        }
        for var reference in ordered {
            let window: AXUIElement
            switch resolve(reference) {
            case let .found(resolved):
                window = resolved
            case .applicationTerminated:
                missing += 1
                continue
            case .temporarilyUnavailable:
                failed += 1
                retryable.append(reference)
                continue
            case .notFoundInSuccessfulSnapshot:
                let now = environment.now()
                reference.missingObservationCount += 1
                if reference.firstMissingObservationAt == nil {
                    reference.firstMissingObservationAt = now
                }
                let elapsed = now.timeIntervalSince(reference.firstMissingObservationAt ?? now)
                if reference.missingObservationCount >= 3, elapsed >= 0.4 {
                    missing += 1
                } else {
                    failed += 1
                    retryable.append(reference)
                }
                continue
            }
            guard let isMinimized = environment.minimized(window) else {
                if reference.phase == .restoreRequested { pending += 1 } else { failed += 1 }
                retryable.append(reference)
                continue
            }
            if !isMinimized, reference.phase != .minimizeRequested {
                // The user or target App already restored this window. It no
                // longer needs mutation, but it is still a successful final
                // state for the batch.
                restored += 1
                continue
            }
            // Even a still-false minimizeRequested window needs a compensating
            // false write: its accepted true request may still be in flight.
            guard environment.canMinimize(window),
                  environment.setMinimized(window, false) == .success else {
                failed += 1
                retryable.append(reference)
                continue
            }
            reference.phase = .restoreRequested
            guard environment.minimized(window) == false else {
                pending += 1
                retryable.append(reference)
                continue
            }
            environment.raiseWindow(window)
            restored += 1
        }

        var activationHandled = session.activationHandled
        if !activationHandled, restored > 0 || pending > 0,
           let originalFrontmostPID = session.originalFrontmostPID,
           environment.isApplicationRunning(originalFrontmostPID) {
            environment.activateApplication(originalFrontmostPID)
            activationHandled = true
        }

        // Keep only windows whose restore failed while they still exist. A
        // transient AX refusal must not erase SuperIsland's ownership of those
        // minimized windows; the next trigger (or stop cleanup) can retry them.
        self.session = retryable.isEmpty
            ? nil
            : Session(
                mode: session.mode,
                originalFrontmostPID: session.originalFrontmostPID,
                windows: retryable,
                activationHandled: activationHandled
            )
        guard !session.windows.isEmpty else {
            return .nothingToRestore(mode: session.mode)
        }
        return .restored(
            mode: session.mode,
            succeeded: restored,
            pending: pending,
            failed: failed,
            missing: missing
        )
    }

    private static func liveEnvironment() -> Environment {
        Environment(
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            applications: {
                NSWorkspace.shared.runningApplications.compactMap { application in
                    guard application.activationPolicy == .regular,
                          !application.isTerminated else { return nil }
                    return Application(
                        processIdentifier: application.processIdentifier,
                        bundleIdentifier: application.bundleIdentifier
                    )
                }
            },
            frontmostProcessIdentifier: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            isApplicationRunning: { pid in
                NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
            },
            activateApplication: { NSRunningApplication(processIdentifier: $0)?.activate(options: []) },
            windowOrder: visibleWindowOrder,
            focusedWindow: focusedWindowElement,
            windows: { windowElements(of: AXUIElementCreateApplication($0)) },
            processIdentifier: { element in
                var pid: pid_t = 0
                return AXUIElementGetPid(element, &pid) == .success ? pid : nil
            },
            isOrdinaryWindow: isOrdinaryWindow,
            windowNumber: windowNumber,
            identifier: { stringAttribute("AXIdentifier", of: $0) },
            minimized: { boolAttribute(kAXMinimizedAttribute, of: $0) },
            canMinimize: { isAttributeSettable(kAXMinimizedAttribute, of: $0) },
            setMinimized: { element, minimized in
                AXUIElementSetAttributeValue(
                    element, kAXMinimizedAttribute as CFString,
                    minimized ? kCFBooleanTrue : kCFBooleanFalse
                )
            },
            raiseWindow: { AXUIElementPerformAction($0, kAXRaiseAction as CFString) },
            now: Date.init
        )
    }

    private static func focusedWindowElement() -> AXUIElement? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return elementAttribute(
            kAXFocusedWindowAttribute,
            of: AXUIElementCreateApplication(application.processIdentifier)
        )
    }

    private static func windowElements(of application: AXUIElement) -> (succeeded: Bool, windows: [AXUIElement]) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
        let windows = value as? [AXUIElement] else { return (false, []) }
        return (true, windows)
    }

    private func resolve(_ reference: WindowReference) -> WindowResolution {
        guard environment.isApplicationRunning(reference.processIdentifier) else { return .applicationTerminated }

        if exactMatch(reference.originalElement, reference: reference) {
            return .found(reference.originalElement)
        }

        let snapshot = environment.windows(reference.processIdentifier)
        guard snapshot.succeeded else { return .temporarilyUnavailable }
        let windows = snapshot.windows
        if let windowNumber = reference.windowNumber {
            let matches = windows.filter { environment.windowNumber($0) == windowNumber }
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .temporarilyUnavailable }
        }
        if let identifier = reference.identifier {
            let matches = windows.filter {
                environment.identifier($0) == identifier
            }
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .temporarilyUnavailable }
        }
        guard reference.windowNumber != nil || reference.identifier != nil else {
            return .temporarilyUnavailable
        }
        return .notFoundInSuccessfulSnapshot
    }

    private func exactMatch(
        _ element: AXUIElement,
        reference: WindowReference
    ) -> Bool {
        guard environment.processIdentifier(element) == reference.processIdentifier,
              environment.isOrdinaryWindow(element) else { return false }
        if let windowNumber = reference.windowNumber {
            return environment.windowNumber(element) == windowNumber
        }
        if let identifier = reference.identifier {
            return environment.identifier(element) == identifier
        }
        return CFEqual(element, reference.originalElement)
    }

    private static func isOrdinaryWindow(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute, of: element) == kAXWindowRole as String,
              boolAttribute("AXModal", of: element) != true else { return false }
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        return subrole == nil ||
            subrole == kAXStandardWindowSubrole as String ||
            subrole == kAXDialogSubrole as String
    }

    private static func visibleWindowOrder() -> [Int: Int] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var order: [Int: Int] = [:]
        for (index, window) in windows.enumerated() {
            guard let number = window[kCGWindowNumber as String] as? NSNumber else { continue }
            order[number.intValue] = index
        }
        return order
    }

    private static func windowNumber(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXWindowNumber" as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func stringAttribute(
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

    private static func boolAttribute(
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

    private static func elementAttribute(
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

    private static func isAttributeSettable(
        _ name: String,
        of element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            name as CFString,
            &settable
        ) == .success else { return false }
        return settable.boolValue
    }
}
