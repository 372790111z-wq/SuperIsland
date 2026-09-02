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
        case minimized(mode: Mode, succeeded: Int, failed: Int)
        case restored(mode: Mode, succeeded: Int, failed: Int, missing: Int)
        case nothingToMinimize(mode: Mode)
        case nothingToRestore(mode: Mode)
        case missingFocusedWindow
    }

    private struct WindowReference {
        let processIdentifier: pid_t
        let windowNumber: Int?
        let identifier: String?
        let originalElement: AXUIElement
        let frontToBackOrder: Int
        var missingObservationCount: Int
        var firstMissingObservationAt: Date?
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
    }

    private var session: Session?

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

    private func minimize(
        mode: Mode,
        excludingBundleIdentifiers: Set<String>
    ) -> Outcome {
        let focusedWindow: AXUIElement?
        if mode.keepingFocusedWindow {
            guard let focused = focusedWindowElement() else {
                return .missingFocusedWindow
            }
            focusedWindow = focused
        } else {
            focusedWindow = nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontOrder = visibleWindowOrder()
        let originalFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  application.processIdentifier != ownPID else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return true }
            return !excludingBundleIdentifiers.contains(bundleIdentifier)
        }

        var minimized: [WindowReference] = []
        var failed = 0
        for application in applications {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let snapshot = windowElements(of: appElement)
            guard snapshot.succeeded else {
                failed += 1
                continue
            }
            for window in snapshot.windows {
                guard isOrdinaryWindow(window),
                      focusedWindow.map({ !CFEqual(window, $0) }) ?? true,
                      boolAttribute(kAXMinimizedAttribute, of: window) != true,
                      isAttributeSettable(kAXMinimizedAttribute, of: window) else {
                    continue
                }

                let reference = WindowReference(
                    processIdentifier: application.processIdentifier,
                    windowNumber: windowNumber(of: window),
                    identifier: stringAttribute("AXIdentifier", of: window),
                    originalElement: window,
                    frontToBackOrder: windowNumber(of: window).flatMap { frontOrder[$0] } ?? Int.max,
                    missingObservationCount: 0,
                    firstMissingObservationAt: nil
                )
                let result = AXUIElementSetAttributeValue(
                    window,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanTrue
                )
                if result == .success,
                   boolAttribute(kAXMinimizedAttribute, of: window) == true {
                    minimized.append(reference)
                } else {
                    failed += 1
                }
            }
        }

        guard !minimized.isEmpty else {
            return failed > 0
                ? .minimized(mode: mode, succeeded: 0, failed: failed)
                : .nothingToMinimize(mode: mode)
        }
        session = Session(
            mode: mode,
            originalFrontmostPID: originalFrontmostPID,
            windows: minimized
        )
        return .minimized(mode: mode, succeeded: minimized.count, failed: failed)
    }

    private func restore(_ session: Session) -> Outcome {
        var restored = 0
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
                let now = Date()
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
            guard boolAttribute(kAXMinimizedAttribute, of: window) == true else {
                // The user or target App already restored this window. It no
                // longer needs mutation, but it is still a successful final
                // state for the batch.
                restored += 1
                continue
            }
            guard isAttributeSettable(kAXMinimizedAttribute, of: window),
                  AXUIElementSetAttributeValue(
                    window,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                  ) == .success,
                  boolAttribute(kAXMinimizedAttribute, of: window) != true else {
                failed += 1
                retryable.append(reference)
                continue
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            restored += 1
        }

        if let originalFrontmostPID = session.originalFrontmostPID,
           let application = NSRunningApplication(processIdentifier: originalFrontmostPID),
           !application.isTerminated {
            application.activate(options: [])
        }

        // Keep only windows whose restore failed while they still exist. A
        // transient AX refusal must not erase SuperIsland's ownership of those
        // minimized windows; the next trigger (or stop cleanup) can retry them.
        self.session = retryable.isEmpty
            ? nil
            : Session(
                mode: session.mode,
                originalFrontmostPID: session.originalFrontmostPID,
                windows: retryable
            )
        guard !session.windows.isEmpty else {
            return .nothingToRestore(mode: session.mode)
        }
        return .restored(
            mode: session.mode,
            succeeded: restored,
            failed: failed,
            missing: missing
        )
    }

    private func focusedWindowElement() -> AXUIElement? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return elementAttribute(
            kAXFocusedWindowAttribute,
            of: AXUIElementCreateApplication(application.processIdentifier)
        )
    }

    private func windowElements(of application: AXUIElement) -> (succeeded: Bool, windows: [AXUIElement]) {
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
        guard let application = NSRunningApplication(
            processIdentifier: reference.processIdentifier
        ), !application.isTerminated else { return .applicationTerminated }

        if exactMatch(reference.originalElement, reference: reference) {
            return .found(reference.originalElement)
        }

        let snapshot = windowElements(
            of: AXUIElementCreateApplication(reference.processIdentifier)
        )
        guard snapshot.succeeded else { return .temporarilyUnavailable }
        let windows = snapshot.windows
        if let windowNumber = reference.windowNumber {
            let matches = windows.filter { self.windowNumber(of: $0) == windowNumber }
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .temporarilyUnavailable }
        }
        if let identifier = reference.identifier {
            let matches = windows.filter {
                stringAttribute("AXIdentifier", of: $0) == identifier
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
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == reference.processIdentifier,
              isOrdinaryWindow(element) else { return false }
        if let windowNumber = reference.windowNumber {
            return self.windowNumber(of: element) == windowNumber
        }
        if let identifier = reference.identifier {
            return stringAttribute("AXIdentifier", of: element) == identifier
        }
        return CFEqual(element, reference.originalElement)
    }

    private func isOrdinaryWindow(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute, of: element) == kAXWindowRole as String,
              boolAttribute("AXModal", of: element) != true else { return false }
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        return subrole == nil ||
            subrole == kAXStandardWindowSubrole as String ||
            subrole == kAXDialogSubrole as String
    }

    private func visibleWindowOrder() -> [Int: Int] {
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

    private func windowNumber(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXWindowNumber" as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else { return nil }
        return number.intValue
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

    private func isAttributeSettable(
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
