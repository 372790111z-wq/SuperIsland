import ApplicationServices
import Foundation

/// The caller samples only the frontmost application and rechecks that identity
/// and its input/state generation before retaining this evidence.
struct DockReversePreclickContext: Equatable, Sendable {
    let processIdentifier: Int32
    let launchDate: Date
    let startedAt: TimeInterval
    let completedAt: TimeInterval
}

enum DockReversePreclickPolicy {
    static func windowsToMinimize<Window>(
        context: DockReversePreclickContext?,
        visibleBefore: [Window],
        visibleNow: [Window],
        targetProcessIdentifier: Int32,
        targetLaunchDate: Date?,
        mouseDownAt: TimeInterval,
        now: TimeInterval,
        matches: (Window, Window) -> Bool
    ) -> [Window] {
        guard canMinimize(
            context: context,
            targetProcessIdentifier: targetProcessIdentifier,
            targetLaunchDate: targetLaunchDate,
            mouseDownAt: mouseDownAt,
            now: now
        ) else { return [] }
        // Return the current operation objects, restricted to windows already
        // visible before this click. Dock restoring a window cannot add it.
        return visibleNow.filter { current in
            visibleBefore.contains { matches($0, current) }
        }
    }

    static func canMinimize(
        context: DockReversePreclickContext?,
        targetProcessIdentifier: Int32,
        targetLaunchDate: Date?,
        mouseDownAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard let context, let targetLaunchDate,
              targetProcessIdentifier > 0,
              context.processIdentifier == targetProcessIdentifier,
              context.launchDate.timeIntervalSinceReferenceDate.isFinite,
              targetLaunchDate.timeIntervalSinceReferenceDate.isFinite,
              context.launchDate == targetLaunchDate,
              [context.startedAt, context.completedAt, mouseDownAt, now]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
              context.startedAt <= context.completedAt,
              context.completedAt < mouseDownAt,
              mouseDownAt <= now else { return false }

        // Compare deadlines instead of subtracting timestamps: the exact
        // inclusive boundary remains stable despite binary floating point.
        return context.completedAt <= context.startedAt + 0.12
            && mouseDownAt <= context.completedAt + 0.40
            && now <= mouseDownAt + 0.40
    }
}

struct DockReversePreclickSnapshot: @unchecked Sendable {
    let context: DockReversePreclickContext
    let visibleWindows: [AXUIElement]
}

/// Read-only, bounded AX preflight. No event tap, activation, window mutation,
/// title/content lookup, or shared lifecycle/cache update occurs on this worker.
final class DockReversePreclickSampler: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.workview.SuperIsland.dock-reverse-preclick",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let totalBudget: TimeInterval = 0.10
    private let perMessageTimeout: TimeInterval = 0.015
    private let maximumWindowCount = 32

    /// Completion runs on the worker. The main-actor caller validates the
    /// original process launch and probe generation before using the result.
    func sample(
        processIdentifier: Int32,
        launchDate: Date,
        completion: @escaping @Sendable (DockReversePreclickSnapshot?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        queue.async { [self] in
            completion(autoreleasepool {
                sampleSynchronously(processIdentifier: processIdentifier, launchDate: launchDate)
            })
        }
    }

    private func sampleSynchronously(
        processIdentifier: Int32,
        launchDate: Date
    ) -> DockReversePreclickSnapshot? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + totalBudget
        guard processIdentifier > 0,
              launchDate.timeIntervalSinceReferenceDate.isFinite,
              AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        var candidates: [AXUIElement] = []

        func append(_ element: AXUIElement) -> Bool {
            if candidates.contains(where: { CFEqual($0, element) }) { return true }
            guard candidates.count < maximumWindowCount else { return false }
            candidates.append(element)
            return true
        }

        if let value = attribute(kAXWindowsAttribute, of: application, deadline: deadline),
           let windows = value as? [AXUIElement] {
            // A truncated list is incomplete evidence; keep the native click.
            guard windows.count <= maximumWindowCount else { return nil }
            for window in windows {
                guard append(window) else { return nil }
            }
        }
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if let value = attribute(name, of: application, deadline: deadline),
               CFGetTypeID(value) == AXUIElementGetTypeID(),
               !append(unsafeBitCast(value, to: AXUIElement.self)) { return nil }
        }

        var visibleWindows: [AXUIElement] = []
        for window in candidates {
            guard prepare(window, deadline: deadline) else { return nil }
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(window, &ownerPID) == .success,
                  ownerPID == processIdentifier,
                  let role = attribute(kAXRoleAttribute, of: window, deadline: deadline) as? String,
                  role == kAXWindowRole as String,
                  let minimized = attribute(kAXMinimizedAttribute, of: window, deadline: deadline),
                  CFGetTypeID(minimized) == CFBooleanGetTypeID(),
                  !CFBooleanGetValue(unsafeBitCast(minimized, to: CFBoolean.self)) else { continue }
            visibleWindows.append(window)
        }

        let completedAt = ProcessInfo.processInfo.systemUptime
        // Never turn a budget overrun into a partially trustworthy snapshot.
        guard completedAt <= deadline else { return nil }
        return DockReversePreclickSnapshot(
            context: DockReversePreclickContext(
                processIdentifier: processIdentifier, launchDate: launchDate,
                startedAt: startedAt, completedAt: completedAt
            ),
            visibleWindows: visibleWindows
        )
    }

    private func prepare(_ element: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(perMessageTimeout, remaining))) == .success
    }

    private func attribute(
        _ name: String,
        of element: AXUIElement,
        deadline: TimeInterval
    ) -> CFTypeRef? {
        guard prepare(element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
