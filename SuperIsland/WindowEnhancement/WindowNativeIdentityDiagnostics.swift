import AppKit
import ApplicationServices
import Foundation

/// Admission belongs to the worker lifetime, not the shorter reporting deadline.
struct WindowNativeIdentityDiagnosticAdmission {
    private(set) var inFlightID: UInt64?
    private var lastStart: UInt64?
    private var nextID: UInt64 = 0

    mutating func begin(now: UInt64) -> UInt64? {
        guard inFlightID == nil, nextID < UInt64.max else { return nil }
        if let lastStart, now < lastStart || now - lastStart < 2_000_000_000 {
            return nil
        }
        nextID += 1
        lastStart = now
        inFlightID = nextID
        return nextID
    }

    mutating func workerFinished(sampleID: UInt64) {
        guard inFlightID == sampleID else { return }
        inFlightID = nil
    }
}

struct WindowNativeIdentityDiagnosticBudget {
    static let durationNanoseconds: UInt64 = 500_000_000
    static let maximumReads = 20
    let startedAt: UInt64
    private(set) var reads = 0
    private(set) var stopReason: String?

    mutating func isCurrent(now: UInt64) -> Bool {
        guard stopReason == nil else { return false }
        guard now >= startedAt, now - startedAt < Self.durationNanoseconds else {
            stopReason = "expiredUnknown"
            return false
        }
        return true
    }

    mutating func reserveRead(now: UInt64) -> Bool {
        guard isCurrent(now: now) else { return false }
        guard reads < Self.maximumReads else {
            stopReason = "readBudgetUnknown"
            return false
        }
        reads += 1
        return true
    }
}

struct WindowNativeIdentityDiagnosticCandidate: Sendable {
    let pid: pid_t
    let bundleURL: URL?
}

enum WindowNativeIdentityDiagnosticPolicy {
    static func roleCode(_ raw: String?) -> String {
        switch raw {
        case kAXApplicationRole: return "application"
        case kAXWindowRole: return "window"
        case kAXButtonRole: return "button"
        case kAXImageRole: return "image"
        case kAXGroupRole: return "group"
        case kAXStaticTextRole: return "text"
        case kAXListRole: return "list"
        case "AXDockItem": return "dockItem"
        default: return "unknown"
        }
    }

    static func matchingPIDs(
        url: URL?, candidates: [WindowNativeIdentityDiagnosticCandidate]
    ) -> [pid_t] {
        guard let url, url.isFileURL else { return [] }
        return candidates.compactMap { candidate in
            guard let bundleURL = candidate.bundleURL, bundleURL.isFileURL,
                  bundleURL.standardizedFileURL == url.standardizedFileURL else { return nil }
            return candidate.pid
        }
    }
}

/// Read-only evidence from a scope already found ambiguous by the native bridge.
/// No additional AX work or filesystem I/O runs on the input/main thread.
final class WindowNativeIdentityDiagnostics: @unchecked Sendable {
    static let shared = WindowNativeIdentityDiagnostics()

#if DEBUG
    private let lock = NSLock()
    private var admission = WindowNativeIdentityDiagnosticAdmission()
    private let queue = DispatchQueue(
        label: "com.workview.SuperIsland.native-identity-diagnostics", qos: .utility
    )
    // Separate admission counters prevent pointer/MC diagnostics from starving
    // these at-most-eleven records. The same recorder enforces 0600 and rotation.
    private let recorder = WindowInteractionDiagnosticRecorder(
        fileURL: WindowInteractionDiagnosticRecorder.diagnosticFileURL?
            .deletingLastPathComponent().appendingPathComponent("native-identity.jsonl")
    )
#endif

    private init() {}

    @MainActor
    func capture(element: AXUIElement, applications: [NSRunningApplication], firstDepth: Int) {
#if DEBUG
        guard WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: Bundle.main.bundleIdentifier),
              !applications.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let sampleID = lock.withLock({ admission.begin(now: now) }) else { return }
        let candidates = applications.prefix(4).map {
            WindowNativeIdentityDiagnosticCandidate(pid: $0.processIdentifier, bundleURL: $0.bundleURL)
        }
        var context: [String: WindowInteractionDiagnosticValue] = [
            "sampleID": .integer(Int64(clamping: sampleID)),
            "firstDepth": .integer(Int64(firstDepth)),
            "candidateCount": .integer(Int64(applications.count)),
            "candidatesTruncated": .flag(applications.count > candidates.count)
        ]
        for (index, candidate) in candidates.enumerated() {
            context["candidatePID\(index)"] = .integer(Int64(candidate.pid))
        }
        let sample = Sample(
            element: element, candidates: candidates, context: context,
            startedAt: now, recorder: recorder
        )
        // A one-shot reporting deadline, never a permanent timer. It does not
        // release admission: an outstanding AX IPC still occupies the one slot.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            sample.finish(reason: "expiredUnknown")
        }
        queue.async { [self] in
            defer {
                sample.finish(reason: "completed")
                lock.withLock { admission.workerFinished(sampleID: sampleID) }
            }
            inspect(sample)
        }
#endif
    }

#if DEBUG
    private final class Sample: @unchecked Sendable {
        let element: AXUIElement
        let candidates: [WindowNativeIdentityDiagnosticCandidate]
        private let context: [String: WindowInteractionDiagnosticValue]
        private let recorder: WindowInteractionDiagnosticRecorder
        private let lock = NSLock()
        private var budget: WindowNativeIdentityDiagnosticBudget
        private var finished = false

        init(element: AXUIElement, candidates: [WindowNativeIdentityDiagnosticCandidate],
             context: [String: WindowInteractionDiagnosticValue], startedAt: UInt64,
             recorder: WindowInteractionDiagnosticRecorder) {
            self.element = element
            self.candidates = candidates
            self.context = context
            self.recorder = recorder
            budget = WindowNativeIdentityDiagnosticBudget(startedAt: startedAt)
        }

        func read<T>(_ operation: () -> T) -> T? {
            guard lock.withLock({ !finished && budget.reserveRead(now: DispatchTime.now().uptimeNanoseconds) }) else {
                return nil
            }
            // Do not change the timeout on this shared AX object. Public AX
            // cannot interrupt an already-issued IPC; late results are dropped.
            let result = operation()
            guard lock.withLock({ !finished && budget.isCurrent(now: DispatchTime.now().uptimeNanoseconds) }) else {
                return nil
            }
            return result
        }

        func emit(_ event: String, _ metadata: [String: WindowInteractionDiagnosticValue]) {
            lock.withLock {
                guard !finished, budget.isCurrent(now: DispatchTime.now().uptimeNanoseconds) else { return }
                var values = metadata
                values["sampleID"] = context["sampleID"]
                recorder.record(component: "nativeIdentity", event: event, metadata: values)
            }
        }

        func start() { emit("sample", context) }

        func finish(reason: String) {
            lock.withLock {
                guard !finished else { return }
                _ = budget.isCurrent(now: DispatchTime.now().uptimeNanoseconds)
                finished = true
                var values = context
                values["state"] = .code(budget.stopReason ?? reason)
                values["readCount"] = .integer(Int64(budget.reads))
                recorder.record(component: "nativeIdentity", event: "finished", metadata: values)
            }
        }
    }

    private func attribute(_ name: String, element: AXUIElement, sample: Sample) -> (AXError, CFTypeRef?)? {
        sample.read {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        }
    }

    private func owner(_ element: AXUIElement, sample: Sample) -> (AXError, pid_t)? {
        sample.read {
            var pid: pid_t = 0
            let error = AXUIElementGetPid(element, &pid)
            return (error, pid)
        }
    }

    private func inspect(_ sample: Sample) {
        sample.start()
        guard AXIsProcessTrusted() else { sample.finish(reason: "permissionUnknown"); return }
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .filter { !$0.isTerminated }
        let dockPID = docks.count == 1 ? docks[0].processIdentifier : 0
        guard let (ownerError, ownerPID) = owner(sample.element, sample: sample) else { return }
        guard ownerError == .success, dockPID > 0, ownerPID == dockPID else {
            sample.emit("scope", ["dockPID": .integer(Int64(dockPID)),
                                  "ownerPID": .integer(Int64(ownerPID)),
                                  "ownerError": .integer(Int64(ownerError.rawValue))])
            sample.finish(reason: "scopeUnknown")
            return
        }
        guard let (roleError, roleValue) = attribute(kAXRoleAttribute, element: sample.element, sample: sample) else { return }
        let role = WindowNativeIdentityDiagnosticPolicy.roleCode(roleValue as? String)
        sample.emit("scope", ["dockPID": .integer(Int64(dockPID)),
                              "ownerPID": .integer(Int64(ownerPID)),
                              "ownerError": .integer(Int64(ownerError.rawValue)),
                              "role": .code(role), "roleError": .integer(Int64(roleError.rawValue))])
        guard roleError == .success, role != "application", role != "window" else {
            sample.finish(reason: "scopeRoleUnknown")
            return
        }
        guard let names = sample.read({ () -> (AXError, Int) in
            var value: CFArray?
            let error = AXUIElementCopyAttributeNames(sample.element, &value)
            return (error, value.map(CFArrayGetCount) ?? 0)
        }), let parameters = sample.read({ () -> (AXError, Int) in
            var value: CFArray?
            let error = AXUIElementCopyParameterizedAttributeNames(sample.element, &value)
            return (error, value.map(CFArrayGetCount) ?? 0)
        }) else { return }
        sample.emit("names", ["attributeError": .integer(Int64(names.0.rawValue)),
                              "attributeCount": .integer(Int64(names.1)),
                              "parameterError": .integer(Int64(parameters.0.rawValue)),
                              "parameterCount": .integer(Int64(parameters.1))])

        let relations = [("linked", "AXLinkedUIElements"), ("title", "AXTitleUIElement"),
                         ("servesTitle", "AXServesAsTitleForUIElements")]
        var referenceIndex = 0
        for (event, name) in relations {
            guard let (error, value) = attribute(name, element: sample.element, sample: sample) else { return }
            var total = 0
            var inspected = 0
            var unsupported = false
            var references: [AXUIElement] = []
            if error == .success, let value {
                if CFGetTypeID(value) == AXUIElementGetTypeID() {
                    total = 1
                    if referenceIndex < 4 {
                        inspected = 1
                        references.append(unsafeBitCast(value, to: AXUIElement.self))
                    }
                } else if CFGetTypeID(value) == CFArrayGetTypeID() {
                    let array = unsafeBitCast(value, to: CFArray.self)
                    total = CFArrayGetCount(array)
                    inspected = min(total, max(0, 4 - referenceIndex))
                    for index in 0..<inspected {
                        guard let pointer = CFArrayGetValueAtIndex(array, index) else { unsupported = true; continue }
                        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                        if CFGetTypeID(object) == AXUIElementGetTypeID() {
                            references.append(unsafeBitCast(object, to: AXUIElement.self))
                        } else { unsupported = true }
                    }
                } else { unsupported = true }
            }
            sample.emit(event, ["readError": .integer(Int64(error.rawValue)),
                                "valuePresent": .flag(value != nil), "valueCount": .integer(Int64(total)),
                                "inspectedCount": .integer(Int64(inspected)),
                                "referenceCount": .integer(Int64(references.count)),
                                "truncated": .flag(total > inspected), "unsupported": .flag(unsupported)])
            for reference in references {
                guard inspectReference(reference, relation: event, index: referenceIndex,
                                       dockPID: dockPID, sample: sample) else { return }
                referenceIndex += 1
            }
        }
    }

    private func inspectReference(_ element: AXUIElement, relation: String, index: Int,
                                  dockPID: pid_t, sample: Sample) -> Bool {
        guard let (ownerError, ownerPID) = owner(element, sample: sample),
              let (roleError, roleValue) = attribute(kAXRoleAttribute, element: element, sample: sample) else { return false }
        let role = WindowNativeIdentityDiagnosticPolicy.roleCode(roleValue as? String)
        var values: [String: WindowInteractionDiagnosticValue] = [
            "relation": .code(relation), "ownerPID": .integer(Int64(ownerPID)),
            "ownerError": .integer(Int64(ownerError.rawValue)), "role": .code(role),
            "roleError": .integer(Int64(roleError.rawValue)), "urlChecked": .flag(false)
        ]
        // Application/window references and references outside Dock stop here.
        if ownerError == .success, ownerPID == dockPID, roleError == .success,
           role != "application", role != "window" {
            guard let (error, value) = attribute(kAXURLAttribute, element: element, sample: sample) else { return false }
            let matches = error == .success ? WindowNativeIdentityDiagnosticPolicy.matchingPIDs(
                url: value as? URL, candidates: sample.candidates
            ) : []
            values["urlChecked"] = .flag(true)
            values["urlError"] = .integer(Int64(error.rawValue))
            values["urlMatchCount"] = .integer(Int64(matches.count))
            for (offset, pid) in matches.enumerated() { values["urlMatchPID\(offset)"] = .integer(Int64(pid)) }
        }
        sample.emit(["reference0", "reference1", "reference2", "reference3"][index], values)
        return true
    }
#endif
}
