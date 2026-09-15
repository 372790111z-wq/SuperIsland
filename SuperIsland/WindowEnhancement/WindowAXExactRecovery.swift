import AppKit
import ApplicationServices
import Darwin

/// A remote AX token can also address descendants carrying their parent's WID.
/// Only a live window root for the requested owner is eligible for recovery.
enum WindowAXExactRecoveryPolicy {
    static func accepts(
        requestedPID: pid_t, actualPID: pid_t,
        requestedWindowIDs: Set<CGWindowID>, actualWindowID: CGWindowID,
        roleResult: AXError, role: String?, isOrderedIn: Bool?,
        processIsCurrent: Bool
    ) -> Bool {
        requestedPID > 0 && requestedPID == actualPID && actualWindowID > 0 &&
            requestedWindowIDs.contains(actualWindowID) && roleResult == .success &&
            role == kAXWindowRole as String && isOrderedIn == true && processIsCurrent
    }

    /// Invalid tokens and unsupported attributes are conclusive misses. A
    /// transport failure or disabled AX service is not evidence about this ID.
    static func isDefinitiveLookupFailure(_ error: AXError) -> Bool {
        switch error {
        case .illegalArgument, .invalidUIElement, .attributeUnsupported, .notImplemented, .noValue:
            return true
        default:
            return false
        }
    }

    static func token(processIdentifier: pid_t, elementID: UInt64) -> Data {
        // Layout used by AXRuntime and AltTab: pid, reserved, 'coco', element ID.
        // Resolve the constructor dynamically; never inspect AX object's memory.
        var data = Data(repeating: 0, count: 20)
        var pid = processIdentifier.littleEndian
        var marker = UInt32(0x636f636f).littleEndian
        var identifier = elementID.littleEndian
        withUnsafeBytes(of: &pid) { data.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: &marker) { data.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: &identifier) { data.replaceSubrange(12..<20, with: $0) }
        return data
    }
}

enum WindowAXRecoveryLookup<Element> {
    case found(windowID: CGWindowID, element: Element)
    case definiteMiss
    /// Cancelled, out of budget, or AX temporarily unavailable. Keep this ID
    /// for a later attempt instead of silently skipping a potentially live root.
    case inconclusive
}

/// Resume sparse/large AX namespaces across bounded attempts. Remember only
/// token numbers, never trust a previous lookup as current operation evidence.
struct WindowAXRecoveryScanCursor {
    private(set) var nextElementID: UInt64 = 0
    private(set) var knownElementIDs: [CGWindowID: UInt64] = [:]
    private var scannedTargets: Set<CGWindowID> = []

    mutating func scan<Element>(
        targets: Set<CGWindowID>, maximumCandidates: Int,
        shouldContinue: () -> Bool,
        resolve: (UInt64, Set<CGWindowID>) -> WindowAXRecoveryLookup<Element>
    ) -> (elements: [CGWindowID: Element], attempts: Int) {
        // A previous request may have skipped roots that were not its target.
        // Restart for newly requested windows while retaining validated hints.
        if !targets.isSubset(of: scannedTargets) {
            nextElementID = 0
            scannedTargets = targets
        }
        var found: [CGWindowID: Element] = [:]
        var attempts = 0
        func pending() -> Set<CGWindowID> { targets.subtracting(found.keys) }
        // Recheck known roots first; stale IDs are removed and scanning resumes.
        for windowID in targets.sorted() {
            guard attempts < maximumCandidates, shouldContinue() else { return (found, attempts) }
            guard let elementID = knownElementIDs[windowID] else { continue }
            attempts += 1
            switch resolve(elementID, [windowID]) {
            case let .found(matchedID, element) where matchedID == windowID:
                found[windowID] = element
            case .found, .definiteMiss:
                knownElementIDs.removeValue(forKey: windowID)
            case .inconclusive:
                return (found, attempts)
            }
        }
        while !pending().isEmpty && attempts < maximumCandidates && shouldContinue() {
            let elementID = nextElementID
            attempts += 1
            let lookup = resolve(elementID, pending())
            if case .inconclusive = lookup { return (found, attempts) }
            nextElementID = nextElementID == UInt64.max ? 0 : nextElementID + 1
            guard case let .found(windowID, element) = lookup, pending().contains(windowID) else { continue }
            found[windowID] = element
            if knownElementIDs.count >= 64, knownElementIDs[windowID] == nil {
                knownElementIDs.removeValue(forKey: knownElementIDs.keys.min()!)
            }
            knownElementIDs[windowID] = elementID
        }
        return (found, attempts)
    }
}

struct WindowAXExactRecoveryResult: @unchecked Sendable {
    let elements: [CGWindowID: AXUIElement]
    let attempts: Int
    let elapsedMilliseconds: Double
    static let empty = Self(elements: [:], attempts: 0, elapsedMilliseconds: 0)
}

private typealias WindowAXRemoteTokenConstructor = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
private typealias WindowAXRemoteWindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Shared serial worker for Dock and Cmd-Tab. No activation, AX action, image
/// capture or lifecycle mutation happens here. Callers validate their session
/// generation after awaiting, then admit results into the existing registry.
actor WindowAXExactRecovery {
    static let shared = WindowAXExactRecovery()
    private var cursors: [String: WindowAXRecoveryScanCursor] = [:]
    private var lastUsed: [String: UInt64] = [:]
    private static let constructor: WindowAXRemoteTokenConstructor? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(symbol, to: WindowAXRemoteTokenConstructor.self)
    }()
    private static let windowNumber: WindowAXRemoteWindowNumber? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowAXRemoteWindowNumber.self)
    }()

    func recover(
        identity: WindowThumbnailApplicationIdentity,
        windowIDs: Set<CGWindowID>
    ) -> WindowAXExactRecoveryResult {
        let start = DispatchTime.now().uptimeNanoseconds
        func hasBudget() -> Bool {
            !Task.isCancelled && DispatchTime.now().uptimeNanoseconds - start < 200_000_000
        }
        guard !Task.isCancelled, !Thread.isMainThread, AXIsProcessTrusted(),
              identity.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              identity.matchesCurrentProcess(), let create = Self.constructor,
              let getWindow = Self.windowNumber else { return .empty }
        var targets: Set<CGWindowID> = []
        for windowID in windowIDs.sorted() {
            guard hasBudget(), targets.count < 16 else { break }
            if windowID > 0, WindowServerPrivateBridge.isOrderedIn(windowID: windowID, ownerPID: identity.processIdentifier) == true {
                targets.insert(windowID)
            }
        }
        guard !targets.isEmpty else { return .empty }
        let key = identity.processLifetimeKey
        if cursors[key] == nil, cursors.count >= 24, let oldest = lastUsed.min(by: { $0.value < $1.value })?.key {
            cursors.removeValue(forKey: oldest)
            lastUsed.removeValue(forKey: oldest)
        }
        var cursor = cursors[key] ?? WindowAXRecoveryScanCursor()
        // A single AX IPC can overrun the soft budget by its 25 ms timeout;
        // WindowServer IPCs cannot be preempted. Check between all queries.
        let result = cursor.scan(targets: targets, maximumCandidates: 4096, shouldContinue: hasBudget) { elementID, pending -> WindowAXRecoveryLookup<AXUIElement> in
            guard hasBudget() else { return .inconclusive }
            guard let element = create(WindowAXExactRecoveryPolicy.token(
                processIdentifier: identity.processIdentifier, elementID: elementID
            ) as CFData)?.takeRetainedValue() else { return .inconclusive }
            guard AXUIElementSetMessagingTimeout(element, 0.025) == .success else { return .inconclusive }
            func failure(_ error: AXError) -> WindowAXRecoveryLookup<AXUIElement> {
                WindowAXExactRecoveryPolicy.isDefinitiveLookupFailure(error) ? .definiteMiss : .inconclusive
            }
            var ownerPID: pid_t = 0
            var windowID: CGWindowID = 0
            guard hasBudget() else { return .inconclusive }
            let ownerResult = AXUIElementGetPid(element, &ownerPID)
            guard ownerResult == .success else { return failure(ownerResult) }
            guard ownerPID == identity.processIdentifier else { return .definiteMiss }
            guard hasBudget() else { return .inconclusive }
            let windowResult = getWindow(element, &windowID)
            guard windowResult == .success else { return failure(windowResult) }
            guard pending.contains(windowID) else { return .definiteMiss }
            guard hasBudget() else { return .inconclusive }
            var role: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard roleResult == .success else { return failure(roleResult) }
            guard (role as? String) == (kAXWindowRole as String) else { return .definiteMiss }
            guard hasBudget() else { return .inconclusive }
            let isOrderedIn = WindowServerPrivateBridge.isOrderedIn(windowID: windowID, ownerPID: ownerPID)
            let processIsCurrent = identity.matchesCurrentProcess()
            guard hasBudget(), isOrderedIn == true, processIsCurrent else { return .inconclusive }
            guard WindowAXExactRecoveryPolicy.accepts(
                requestedPID: identity.processIdentifier, actualPID: ownerPID,
                requestedWindowIDs: pending, actualWindowID: windowID,
                roleResult: roleResult, role: role as? String,
                isOrderedIn: isOrderedIn, processIsCurrent: processIsCurrent
            ) else { return .definiteMiss }
            return .found(windowID: windowID, element: element)
        }
        cursors[key] = cursor
        lastUsed[key] = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled, AXIsProcessTrusted(), identity.matchesCurrentProcess() else { return .empty }
        return WindowAXExactRecoveryResult(
            elements: result.elements.filter {
                hasBudget() && WindowServerPrivateBridge.isOrderedIn(windowID: $0.key, ownerPID: identity.processIdentifier) == true
            }, attempts: result.attempts,
            elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        )
    }
}
