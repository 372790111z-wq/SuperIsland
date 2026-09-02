import AppKit
import CoreGraphics
import Darwin
import OSLog

/// The WindowServer surface is the canonical identity. Accessibility remains
/// the operation channel (raise, focus, close), but it is not allowed to
/// manufacture a user-facing window on its own.
struct WindowServerSurface: Sendable, Equatable {
    enum Source: String, Sendable {
        case skyLight
        case publicWindowList
    }

    let windowID: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
    let title: String
    let isOnScreen: Bool
    let alpha: Double
    let spaceIDs: Set<UInt64>
    let source: Source
    let ownerWasPrivatelyValidated: Bool
}

enum WindowServerInventoryMode: String, Sendable {
    case skyLight
    case publicFallback
    case unavailable
}

struct WindowServerInventorySnapshot: Sendable {
    let capturedAt: Date
    let mode: WindowServerInventoryMode
    let surfaces: [WindowServerSurface]

    var surfacesByID: [CGWindowID: WindowServerSurface] {
        Dictionary(uniqueKeysWithValues: surfaces.map { ($0.windowID, $0) })
    }
}

/// AX metadata stripped of its AXUIElement so reconciliation can be tested
/// independently from live Accessibility and WindowServer state.
struct WindowInventoryCandidate: Sendable, Equatable {
    let token: Int
    let ownerPID: pid_t
    let windowID: CGWindowID?
    let title: String
    let bounds: CGRect?
    let isMinimized: Bool
    let isPreferredWindow: Bool
}

struct WindowInventoryMatch: Sendable, Equatable {
    enum Confidence: String, Sendable {
        case exactWindowServerID
        case uniqueGeometryAndTitle
    }

    let token: Int
    let windowID: CGWindowID
    let confidence: Confidence
}

enum WindowInventoryRejectionReason: String, Sendable, Equatable {
    case invalidOwner
    case exactWindowMissing
    case duplicateSurface
    case noUniqueSurface
    case ambiguousSurface
}

struct WindowInventoryRejection: Sendable, Equatable {
    let token: Int
    let reason: WindowInventoryRejectionReason
}

struct WindowInventoryReconciliation: Sendable, Equatable {
    let matches: [WindowInventoryMatch]
    let rejections: [WindowInventoryRejection]
}

/// Pure, fail-closed AX-to-WindowServer reconciliation. An AX proxy with an
/// explicit WindowServer number must resolve to that exact same-PID surface.
/// A proxy without a number is admitted only when title/geometry identify one
/// unclaimed surface unambiguously.
enum WindowInventoryReconciler {
    static func reconcile(
        candidates: [WindowInventoryCandidate],
        snapshot: WindowServerInventorySnapshot
    ) -> WindowInventoryReconciliation {
        let surfacesByID = snapshot.surfacesByID
        var acceptedByWindowID: [CGWindowID: (WindowInventoryMatch, Int)] = [:]
        var rejectionsByToken: [Int: WindowInventoryRejectionReason] = [:]
        var unresolved: [WindowInventoryCandidate] = []

        for candidate in candidates {
            guard candidate.ownerPID > 0 else {
                rejectionsByToken[candidate.token] = .invalidOwner
                continue
            }
            guard let windowID = candidate.windowID else {
                unresolved.append(candidate)
                continue
            }
            guard let surface = surfacesByID[windowID],
                  surface.ownerPID == candidate.ownerPID,
                  isExactTarget(surface, for: candidate, mode: snapshot.mode) else {
                rejectionsByToken[candidate.token] = .exactWindowMissing
                continue
            }

            let match = WindowInventoryMatch(
                token: candidate.token,
                windowID: windowID,
                confidence: .exactWindowServerID
            )
            let quality = candidateQuality(candidate)
            if let existing = acceptedByWindowID[windowID] {
                if quality > existing.1 {
                    rejectionsByToken[existing.0.token] = .duplicateSurface
                    acceptedByWindowID[windowID] = (match, quality)
                } else {
                    rejectionsByToken[candidate.token] = .duplicateSurface
                }
            } else {
                acceptedByWindowID[windowID] = (match, quality)
            }
        }

        let exactClaims = Set(acceptedByWindowID.keys)
        let fuzzySurfaces = snapshot.surfaces.filter { !exactClaims.contains($0.windowID) }
        var proposals: [(candidate: WindowInventoryCandidate, surface: WindowServerSurface, score: Int)] = []

        for candidate in unresolved {
            let ranked = fuzzySurfaces
                .filter {
                    $0.ownerPID == candidate.ownerPID
                        && isPlausibleFuzzyTarget($0, for: candidate, mode: snapshot.mode)
                }
                .map { surface in
                    (surface: surface, score: matchScore(candidate, surface))
                }
                .filter { $0.score >= 8 }
                .sorted {
                    if $0.score == $1.score {
                        return $0.surface.windowID < $1.surface.windowID
                    }
                    return $0.score > $1.score
                }

            guard let best = ranked.first else {
                rejectionsByToken[candidate.token] = .noUniqueSurface
                continue
            }
            if ranked.count > 1, best.score - ranked[1].score < 3 {
                rejectionsByToken[candidate.token] = .ambiguousSurface
                continue
            }
            proposals.append((candidate, best.surface, best.score))
        }

        proposals.sort {
            if $0.score == $1.score {
                let leftQuality = candidateQuality($0.candidate)
                let rightQuality = candidateQuality($1.candidate)
                if leftQuality == rightQuality {
                    return $0.candidate.token < $1.candidate.token
                }
                return leftQuality > rightQuality
            }
            return $0.score > $1.score
        }

        var fuzzyClaims = exactClaims
        for proposal in proposals {
            guard fuzzyClaims.insert(proposal.surface.windowID).inserted else {
                rejectionsByToken[proposal.candidate.token] = .duplicateSurface
                continue
            }
            acceptedByWindowID[proposal.surface.windowID] = (
                WindowInventoryMatch(
                    token: proposal.candidate.token,
                    windowID: proposal.surface.windowID,
                    confidence: .uniqueGeometryAndTitle
                ),
                candidateQuality(proposal.candidate)
            )
        }

        return WindowInventoryReconciliation(
            matches: acceptedByWindowID.values.map(\.0).sorted { $0.token < $1.token },
            rejections: rejectionsByToken.map {
                WindowInventoryRejection(token: $0.key, reason: $0.value)
            }.sorted { $0.token < $1.token }
        )
    }

    private static func isStructurallyUsable(_ surface: WindowServerSurface) -> Bool {
        surface.windowID > 0
            && surface.ownerPID > 0
            && surface.layer == 0
            && surface.bounds.width.isFinite
            && surface.bounds.height.isFinite
            && surface.bounds.width > 0
            && surface.bounds.height > 0
    }

    /// Exact minimized windows are allowed to retain the tiny/off-Space
    /// WindowServer representation macOS gives them. Every non-minimized
    /// window must be a substantive surface and either be on screen now or
    /// have privately verified membership in a real Space. This is the shared
    /// anti-phantom boundary for Dock and Cmd-Tab.
    private static func isExactTarget(
        _ surface: WindowServerSurface,
        for candidate: WindowInventoryCandidate,
        mode: WindowServerInventoryMode
    ) -> Bool {
        guard isStructurallyUsable(surface) else { return false }
        if candidate.isMinimized { return true }
        return isSubstantive(surface) && hasVerifiedPlacement(surface, mode: mode)
    }

    private static func isPlausibleFuzzyTarget(
        _ surface: WindowServerSurface,
        for candidate: WindowInventoryCandidate,
        mode: WindowServerInventoryMode
    ) -> Bool {
        // A minimized proxy without an exact WindowServer ID cannot be proven
        // distinct from an App helper surface, so fuzzy minimized admission is
        // deliberately fail-closed.
        !candidate.isMinimized
            && isStructurallyUsable(surface)
            && isSubstantive(surface)
            && hasVerifiedPlacement(surface, mode: mode)
    }

    private static func isSubstantive(_ surface: WindowServerSurface) -> Bool {
        surface.bounds.width >= 40
            && surface.bounds.height >= 24
            && surface.bounds.width * surface.bounds.height >= 2_048
            && surface.alpha > 0.01
    }

    private static func hasVerifiedPlacement(
        _ surface: WindowServerSurface,
        mode: WindowServerInventoryMode
    ) -> Bool {
        switch mode {
        case .skyLight:
            // When private identity is available, require it consistently.
            // Some compositor/helper surfaces claim onscreen status without
            // ever belonging to a user Space; `isOnScreen` alone is therefore
            // not sufficient evidence in this mode.
            return surface.source == .skyLight
                && surface.ownerWasPrivatelyValidated
                && !surface.spaceIDs.isEmpty
        case .publicFallback:
            // Public CGWindowList has no Space membership API. Degrade only to
            // currently visible surfaces and never infer an off-Space window.
            return surface.source == .publicWindowList && surface.isOnScreen
        case .unavailable:
            return false
        }
    }

    private static func candidateQuality(_ candidate: WindowInventoryCandidate) -> Int {
        var score = 0
        if candidate.windowID != nil { score += 8 }
        if candidate.isPreferredWindow { score += 4 }
        if !normalizedTitle(candidate.title).isEmpty { score += 2 }
        if candidate.bounds != nil { score += 1 }
        if candidate.isMinimized { score += 1 }
        return score
    }

    private static func matchScore(
        _ candidate: WindowInventoryCandidate,
        _ surface: WindowServerSurface
    ) -> Int {
        var score = 0
        let candidateTitle = normalizedTitle(candidate.title)
        let surfaceTitle = normalizedTitle(surface.title)
        if !candidateTitle.isEmpty, candidateTitle == surfaceTitle {
            score += 5
        }
        if let bounds = candidate.bounds {
            let intersection = bounds.intersection(surface.bounds)
            if !intersection.isNull {
                let intersectionArea = intersection.width * intersection.height
                let unionArea = bounds.width * bounds.height
                    + surface.bounds.width * surface.bounds.height
                    - intersectionArea
                if unionArea > 0 {
                    let overlap = intersectionArea / unionArea
                    if overlap >= 0.92 {
                        score += 10
                    } else if overlap >= 0.80 {
                        score += 8
                    }
                }
            }
            let edgeResidual = max(
                abs(bounds.minX - surface.bounds.minX),
                abs(bounds.minY - surface.bounds.minY),
                abs(bounds.width - surface.bounds.width),
                abs(bounds.height - surface.bounds.height)
            )
            if edgeResidual <= 2 {
                score = max(score, 10 + (!candidateTitle.isEmpty && candidateTitle == surfaceTitle ? 5 : 0))
            } else if edgeResidual <= 12 {
                score += 6
            }
        }
        if candidate.isPreferredWindow { score += 1 }
        return score
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private typealias WindowInventoryCGSMainConnectionID = @convention(c) () -> UInt32
private typealias WindowInventoryCGSGetWindowOwner = @convention(c) (
    UInt32,
    CGWindowID,
    UnsafeMutablePointer<UInt32>
) -> Int32
private typealias WindowInventorySLSConnectionGetPID = @convention(c) (
    UInt32,
    UnsafeMutablePointer<pid_t>
) -> Int32
private typealias WindowInventoryCGSCopyManagedDisplaySpaces = @convention(c) (
    UInt32
) -> Unmanaged<CFArray>?
private typealias WindowInventoryCGSCopyWindowsWithOptionsAndTags = @convention(c) (
    UInt32,
    UInt32,
    CFArray,
    UInt32,
    UnsafePointer<UInt64>?,
    UnsafePointer<UInt64>?
) -> Unmanaged<CFArray>?
private typealias WindowInventoryCGSCopySpacesForWindows = @convention(c) (
    UInt32,
    UInt32,
    CFArray
) -> Unmanaged<CFArray>?
private typealias WindowInventoryCGSGetWindowLevel = @convention(c) (
    UInt32,
    CGWindowID,
    UnsafeMutablePointer<Int32>
) -> Int32
private typealias WindowInventoryCGSHWCaptureWindowList = @convention(c) (
    UInt32,
    UnsafeMutablePointer<CGWindowID>,
    UInt32,
    UInt32
) -> Unmanaged<CFArray>?
private typealias WindowInventoryGetProcessForPID = @convention(c) (
    pid_t,
    UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus
private typealias WindowInventorySLPSSetFrontProcessWithOptions = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    CGWindowID,
    UInt32
) -> CGError

/// The narrow private bridge used by the WINS-style pipeline. The inventory
/// and capture functions are dynamically resolved from the same SkyLight
/// framework and fail closed when macOS changes a symbol. Callers must invoke
/// synchronous capture away from the main/event-tap thread.
enum WindowServerPrivateBridge {
    private struct Resolvers {
        let mainConnectionID: WindowInventoryCGSMainConnectionID
        let captureWindowList: WindowInventoryCGSHWCaptureWindowList?
        let getProcessForPID: WindowInventoryGetProcessForPID?
        let setFrontProcessWithOptions: WindowInventorySLPSSetFrontProcessWithOptions?
    }

    // These flags match the WindowServer capture contract used by established
    // open-source window managers: nominal resolution, ignoring global clip.
    private static let captureOptions: UInt32 = (1 << 9) | (1 << 11)

    private static let resolvers: Resolvers? = {
        let handles = [
            dlopen(nil, RTLD_LAZY),
            dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
        ].compactMap { $0 }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            handles.lazy.compactMap { dlsym($0, name) }.first
        }
        guard let mainSymbol = symbol("CGSMainConnectionID") else { return nil }
        return Resolvers(
            mainConnectionID: unsafeBitCast(
                mainSymbol,
                to: WindowInventoryCGSMainConnectionID.self
            ),
            captureWindowList: symbol("CGSHWCaptureWindowList").map {
                unsafeBitCast($0, to: WindowInventoryCGSHWCaptureWindowList.self)
            },
            getProcessForPID: symbol("GetProcessForPID").map {
                unsafeBitCast($0, to: WindowInventoryGetProcessForPID.self)
            },
            setFrontProcessWithOptions: symbol(
                "_SLPSSetFrontProcessWithOptions"
            ).map {
                unsafeBitCast(
                    $0,
                    to: WindowInventorySLPSSetFrontProcessWithOptions.self
                )
            }
        )
    }()

    static func capture(windowID: CGWindowID) -> CGImage? {
        guard windowID > 0,
              let resolvers,
              let captureWindowList = resolvers.captureWindowList else {
            return nil
        }
        let connectionID = resolvers.mainConnectionID()
        guard connectionID != 0 else { return nil }
        var exactWindowID = windowID
        guard let captured = captureWindowList(
            connectionID,
            &exactWindowID,
            1,
            captureOptions
        )?.takeRetainedValue() else { return nil }

        for case let object in captured as NSArray {
            let value = object as CFTypeRef
            guard CFGetTypeID(value) == CGImage.typeID else { continue }
            let image = unsafeBitCast(value, to: CGImage.self)
            return image.copy()
        }
        return nil
    }

    /// Bring one exact WindowServer window (including another Space) forward.
    /// AX still performs the verified focus/raise and remains the fallback.
    @discardableResult
    static func activate(processIdentifier: pid_t, windowID: CGWindowID) -> Bool {
        guard processIdentifier > 0,
              windowID > 0,
              let resolvers,
              let getProcessForPID = resolvers.getProcessForPID,
              let setFrontProcess = resolvers.setFrontProcessWithOptions else {
            return false
        }
        var processSerialNumber = ProcessSerialNumber(
            highLongOfPSN: 0,
            lowLongOfPSN: 0
        )
        guard getProcessForPID(
            processIdentifier,
            &processSerialNumber
        ) == noErr else { return false }
        return setFrontProcess(
            &processSerialNumber,
            windowID,
            0x200
        ) == .success
    }
}

/// Small cached adapter around the same read-only SkyLight/WindowServer family
/// used by mature window managers. Symbols are resolved dynamically so an OS
/// change degrades to the public window list instead of preventing launch.
final class WindowServerInventoryService: @unchecked Sendable {
    static let shared = WindowServerInventoryService()

    private struct SkyLightResolvers {
        let mainConnectionID: WindowInventoryCGSMainConnectionID
        let getWindowOwner: WindowInventoryCGSGetWindowOwner
        let connectionGetPID: WindowInventorySLSConnectionGetPID
        let copyManagedDisplaySpaces: WindowInventoryCGSCopyManagedDisplaySpaces
        let copyWindowsWithOptionsAndTags: WindowInventoryCGSCopyWindowsWithOptionsAndTags
        let copySpacesForWindows: WindowInventoryCGSCopySpacesForWindows
        let getWindowLevel: WindowInventoryCGSGetWindowLevel?
    }

    private struct CacheEntry {
        let snapshot: WindowServerInventorySnapshot
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.workview.SuperIsland",
        category: "WindowInventory"
    )
    private let cacheLock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var rawInventoryCache: WindowServerInventorySnapshot?
    private let cacheTTL: TimeInterval = 0.18
    private let rawInventoryCacheTTL: TimeInterval = 0.30
    private let maximumCacheEntries = 12

    private static let skyLightResolvers: SkyLightResolvers? = {
        let handles = [
            dlopen(nil, RTLD_LAZY),
            dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                RTLD_LAZY | RTLD_LOCAL
            )
        ].compactMap { $0 }
        for handle in handles {
            guard let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
                  let ownerSymbol = dlsym(handle, "CGSGetWindowOwner"),
                  let pidSymbol = dlsym(handle, "SLSConnectionGetPID"),
                  let spacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
                  let windowsSymbol = dlsym(handle, "CGSCopyWindowsWithOptionsAndTags"),
                  let windowSpacesSymbol = dlsym(handle, "CGSCopySpacesForWindows") else {
                continue
            }
            let levelResolver = dlsym(handle, "CGSGetWindowLevel").map {
                unsafeBitCast($0, to: WindowInventoryCGSGetWindowLevel.self)
            }
            return SkyLightResolvers(
                mainConnectionID: unsafeBitCast(
                    mainSymbol,
                    to: WindowInventoryCGSMainConnectionID.self
                ),
                getWindowOwner: unsafeBitCast(
                    ownerSymbol,
                    to: WindowInventoryCGSGetWindowOwner.self
                ),
                connectionGetPID: unsafeBitCast(
                    pidSymbol,
                    to: WindowInventorySLSConnectionGetPID.self
                ),
                copyManagedDisplaySpaces: unsafeBitCast(
                    spacesSymbol,
                    to: WindowInventoryCGSCopyManagedDisplaySpaces.self
                ),
                copyWindowsWithOptionsAndTags: unsafeBitCast(
                    windowsSymbol,
                    to: WindowInventoryCGSCopyWindowsWithOptionsAndTags.self
                ),
                copySpacesForWindows: unsafeBitCast(
                    windowSpacesSymbol,
                    to: WindowInventoryCGSCopySpacesForWindows.self
                ),
                getWindowLevel: levelResolver
            )
        }
        return nil
    }()

    func snapshot(
        for processIdentifiers: Set<pid_t>,
        forceRefresh: Bool = false
    ) -> WindowServerInventorySnapshot {
        let pids = Set(processIdentifiers.filter { $0 > 0 })
        guard !pids.isEmpty else {
            return WindowServerInventorySnapshot(
                capturedAt: Date(),
                mode: .unavailable,
                surfaces: []
            )
        }
        let cacheKey = pids.sorted().map(String.init).joined(separator: ",")
        if !forceRefresh, let cached = cachedSnapshot(for: cacheKey) {
            return cached
        }

        let snapshot = autoreleasepool {
            let rawSnapshot = rawSnapshot(forceRefresh: forceRefresh)
            return projectedSnapshot(rawSnapshot, for: pids)
        }
        store(snapshot, for: cacheKey)
        return snapshot
    }

    func invalidate() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: false)
        rawInventoryCache = nil
        cacheLock.unlock()
    }

    private func cachedSnapshot(for key: String) -> WindowServerInventorySnapshot? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key],
              Date().timeIntervalSince(entry.snapshot.capturedAt) <= cacheTTL else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.snapshot
    }

    private func store(_ snapshot: WindowServerInventorySnapshot, for key: String) {
        cacheLock.lock()
        cache[key] = CacheEntry(snapshot: snapshot)
        if cache.count > maximumCacheEntries,
           let oldest = cache.min(by: {
               $0.value.snapshot.capturedAt < $1.value.snapshot.capturedAt
           })?.key {
            cache.removeValue(forKey: oldest)
        }
        cacheLock.unlock()
    }

    private func rawSnapshot(
        forceRefresh: Bool
    ) -> WindowServerInventorySnapshot {
        if !forceRefresh {
            cacheLock.lock()
            let cached = rawInventoryCache
            cacheLock.unlock()
            if let cached,
               Date().timeIntervalSince(cached.capturedAt) <= rawInventoryCacheTTL {
                return cached
            }
        }
        let snapshot = privateRawSnapshot() ?? publicRawSnapshot()
        cacheLock.lock()
        rawInventoryCache = snapshot
        cacheLock.unlock()
        return snapshot
    }

    /// One raw all-Space scan is shared across Dock, Cmd-Tab and Mission
    /// Control. Per-App hover changes therefore do not repeat the expensive
    /// managed-Space/window-description query.
    private func privateRawSnapshot() -> WindowServerInventorySnapshot? {
        guard let resolvers = Self.skyLightResolvers else { return nil }
        let connectionID = resolvers.mainConnectionID()
        guard connectionID != 0,
              let managedDisplays = resolvers.copyManagedDisplaySpaces(
                  connectionID
              )?.takeRetainedValue() else {
            return nil
        }
        let spaceIDs = managedSpaceIDs(in: managedDisplays)
        guard !spaceIDs.isEmpty else { return nil }
        let spaceArray = spaceIDs.map(NSNumber.init(value:)) as CFArray

        func copyWindowIDs(options: UInt32) -> [CGWindowID]? {
            var setTags: UInt64 = 0
            var clearTags: UInt64 = 0
            guard let copied = resolvers.copyWindowsWithOptionsAndTags(
                connectionID,
                0,
                spaceArray,
                options,
                &setTags,
                &clearTags
            )?.takeRetainedValue() as? [NSNumber] else {
                return nil
            }
            return copied.map { CGWindowID($0.uint32Value) }.filter { $0 > 0 }
        }

        guard let optionSeven = copyWindowIDs(options: 7),
              let optionTwo = copyWindowIDs(options: 2) else {
            return nil
        }
        let windowIDs = Array(Set(optionSeven).union(optionTwo)).sorted()
        guard !windowIDs.isEmpty else {
            return WindowServerInventorySnapshot(
                capturedAt: Date(),
                mode: .skyLight,
                surfaces: []
            )
        }
        guard windowIDs.count <= 8_192 else {
            logger.error(
                "Rejected unbounded SkyLight inventory count=\(windowIDs.count, privacy: .public)"
            )
            return nil
        }

        let descriptions = CGWindowListCreateDescriptionFromArray(
            windowIDs.map(NSNumber.init(value:)) as CFArray
        ) as? [[String: Any]] ?? []
        var surfaces: [WindowServerSurface] = []
        surfaces.reserveCapacity(min(descriptions.count, 256))
        for description in descriptions {
            guard let base = surface(
                from: description,
                allowedPIDs: nil,
                source: .skyLight
            ) else { continue }
            surfaces.append(base)
        }
        return WindowServerInventorySnapshot(
            capturedAt: Date(),
            mode: .skyLight,
            surfaces: deduplicated(surfaces)
        )
    }

    private func publicRawSnapshot() -> WindowServerInventorySnapshot {
        let descriptions = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let surfaces = descriptions.compactMap {
            surface(
                from: $0,
                allowedPIDs: nil,
                source: .publicWindowList
            )
        }
        return WindowServerInventorySnapshot(
            capturedAt: Date(),
            mode: descriptions.isEmpty ? .unavailable : .publicFallback,
            surfaces: deduplicated(surfaces)
        )
    }

    private func projectedSnapshot(
        _ rawSnapshot: WindowServerInventorySnapshot,
        for processIdentifiers: Set<pid_t>
    ) -> WindowServerInventorySnapshot {
        let candidateSurfaces = rawSnapshot.surfaces.filter {
            processIdentifiers.contains($0.ownerPID)
        }
        guard rawSnapshot.mode == .skyLight,
              let resolvers = Self.skyLightResolvers else {
            return WindowServerInventorySnapshot(
                capturedAt: rawSnapshot.capturedAt,
                mode: rawSnapshot.mode,
                surfaces: candidateSurfaces
            )
        }
        let connectionID = resolvers.mainConnectionID()
        guard connectionID != 0 else {
            return WindowServerInventorySnapshot(
                capturedAt: rawSnapshot.capturedAt,
                mode: .publicFallback,
                surfaces: candidateSurfaces
            )
        }

        var validatedSurfaces: [WindowServerSurface] = []
        validatedSurfaces.reserveCapacity(candidateSurfaces.count)
        for base in candidateSurfaces.prefix(64) {
            if let getWindowLevel = resolvers.getWindowLevel {
                var privateLevel: Int32 = 0
                if getWindowLevel(
                    connectionID,
                    base.windowID,
                    &privateLevel
                ) == 0, privateLevel != 0 {
                    continue
                }
            }

            var privateOwnerConnection: UInt32 = 0
            var privateOwnerPID: pid_t = 0
            let ownerWasValidated = resolvers.getWindowOwner(
                connectionID,
                base.windowID,
                &privateOwnerConnection
            ) == 0
                && privateOwnerConnection != 0
                && resolvers.connectionGetPID(
                    privateOwnerConnection,
                    &privateOwnerPID
                ) == 0
                && privateOwnerPID > 0
            if ownerWasValidated, privateOwnerPID != base.ownerPID {
                continue
            }

            let spaces = copySpaceIDs(
                for: base.windowID,
                connectionID: connectionID,
                resolver: resolvers.copySpacesForWindows
            )
            validatedSurfaces.append(WindowServerSurface(
                windowID: base.windowID,
                ownerPID: base.ownerPID,
                bounds: base.bounds,
                layer: base.layer,
                title: base.title,
                isOnScreen: base.isOnScreen,
                alpha: base.alpha,
                spaceIDs: spaces,
                source: .skyLight,
                ownerWasPrivatelyValidated: ownerWasValidated
            ))
        }
        return WindowServerInventorySnapshot(
            capturedAt: rawSnapshot.capturedAt,
            mode: .skyLight,
            surfaces: validatedSurfaces
        )
    }

    private func surface(
        from description: [String: Any],
        allowedPIDs: Set<pid_t>?,
        source: WindowServerSurface.Source
    ) -> WindowServerSurface? {
        guard let number = description[kCGWindowNumber as String] as? NSNumber,
              let owner = description[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = description[kCGWindowLayer as String] as? NSNumber,
              let boundsValue = description[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(
                  dictionaryRepresentation: boundsValue as CFDictionary
              ) else { return nil }
        let windowID = CGWindowID(number.uint32Value)
        let ownerPID = pid_t(owner.int32Value)
        guard windowID > 0,
              ownerPID > 0,
              allowedPIDs?.contains(ownerPID) != false,
              layer.intValue == 0 else { return nil }
        return WindowServerSurface(
            windowID: windowID,
            ownerPID: ownerPID,
            bounds: bounds,
            layer: layer.intValue,
            title: (description[kCGWindowName as String] as? String) ?? "",
            isOnScreen: (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            alpha: (description[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            spaceIDs: [],
            source: source,
            ownerWasPrivatelyValidated: false
        )
    }

    private func managedSpaceIDs(in managedDisplays: CFArray) -> [UInt64] {
        let displays = managedDisplays as NSArray
        var identifiers = Set<UInt64>()
        for case let display as NSDictionary in displays {
            guard let spaces = display["Spaces"] as? NSArray else { continue }
            for case let space as NSDictionary in spaces {
                for key in ["ManagedSpaceID", "id64", "id"] {
                    if let number = space[key] as? NSNumber,
                       number.uint64Value > 0 {
                        identifiers.insert(number.uint64Value)
                        break
                    }
                }
            }
        }
        return identifiers.sorted()
    }

    private func copySpaceIDs(
        for windowID: CGWindowID,
        connectionID: UInt32,
        resolver: WindowInventoryCGSCopySpacesForWindows
    ) -> Set<UInt64> {
        guard let copied = resolver(
            connectionID,
            7,
            [NSNumber(value: windowID)] as CFArray
        )?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return Set(copied.map(\.uint64Value).filter { $0 > 0 })
    }

    private func deduplicated(
        _ surfaces: [WindowServerSurface]
    ) -> [WindowServerSurface] {
        var byID: [CGWindowID: WindowServerSurface] = [:]
        for surface in surfaces {
            if let existing = byID[surface.windowID] {
                if !existing.ownerWasPrivatelyValidated,
                   surface.ownerWasPrivatelyValidated {
                    byID[surface.windowID] = surface
                }
            } else {
                byID[surface.windowID] = surface
            }
        }
        return byID.values.sorted { $0.windowID < $1.windowID }
    }
}
