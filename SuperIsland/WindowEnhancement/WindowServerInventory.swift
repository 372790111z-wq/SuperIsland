import AppKit
import CoreGraphics
import Darwin
import OSLog

/// This CoreGraphics API expects integer CGWindowID values in pointer-sized
/// CFArray slots, not NSNumber objects. The array must not retain/release or
/// dereference those values through CFType callbacks.
enum WindowServerWindowDescriptions {
    static func copy(
        for windowIDs: [CGWindowID],
        query: (CFArray) -> CFArray? = CGWindowListCreateDescriptionFromArray
    ) -> [[String: Any]]? {
        var values = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return values.withUnsafeMutableBufferPointer { buffer in
            guard let array = CFArrayCreate(
                kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil
            ) else { return nil }
            // A successful query may omit windows that have since closed.
            // Preserve nil versus empty/partial results; callers match by ID.
            return query(array) as? [[String: Any]]
        }
    }
}

enum WindowInventoryDiagnosticSource: String, Codable, Sendable {
    case dock
    case commandTab
}

struct WindowInventoryAXSourceDiagnostics: Sendable, Equatable {
    let hasFocusedWindow: Bool
    let hasMainWindow: Bool
    let windowsAttributeResult: Int32
    let windowsAttributeCount: Int
    let lifecycleRegistryCount: Int
    let collectedCount: Int
}

struct WindowInventoryAXCandidateDiagnostics: Sendable, Equatable {
    let token: Int
    let ownerPID: pid_t
    let windowID: CGWindowID?
    let role: String
    let subrole: String
    let titleLength: Int
    let bounds: CGRect?
    let isMinimized: Bool
    let isPreferredWindow: Bool
    let isHidden: Bool?
    let isVisible: Bool?
    let isModal: Bool?
    let isFocusedSource: Bool
    let isMainSource: Bool
    let isWindowsAttributeSource: Bool
    let isLifecycleRegistrySource: Bool
    let wasIncludedByAXPolicy: Bool

    static func ownerValidationFailure(
        token: Int,
        ownerPID: pid_t,
        isFocusedSource: Bool,
        isMainSource: Bool,
        isWindowsAttributeSource: Bool,
        isLifecycleRegistrySource: Bool
    ) -> Self {
        Self(
            token: token,
            ownerPID: ownerPID,
            windowID: nil,
            role: "",
            subrole: "",
            titleLength: 0,
            bounds: nil,
            isMinimized: false,
            isPreferredWindow: false,
            isHidden: nil,
            isVisible: nil,
            isModal: nil,
            isFocusedSource: isFocusedSource,
            isMainSource: isMainSource,
            isWindowsAttributeSource: isWindowsAttributeSource,
            isLifecycleRegistrySource: isLifecycleRegistrySource,
            wasIncludedByAXPolicy: false
        )
    }
}

struct WindowAXNotificationRegistrationDiagnostic: Sendable, Equatable {
    let notification: String
    let targetWindowID: CGWindowID?
    let result: Int32
}

struct WindowAXLifecycleDiagnosticSnapshot: Sendable, Equatable {
    let observerCreationResult: Int32?
    let isObservationInstalled: Bool
    let windowIDs: [CGWindowID]
    let notificationRegistrations: [WindowAXNotificationRegistrationDiagnostic]
    var observerID: String? = nil
    var registryEpoch: UInt64? = nil
    var bindingGeneration: UInt64? = nil
}

enum WindowInventoryDiagnosticGate {
    static let debugBundleIdentifier = "com.workview.SuperIsland.WE1Debug"

    static func isEnabled(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == debugBundleIdentifier
    }

    static func shouldRecord(
        now: Date,
        lastRecordedAt: Date?,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastRecordedAt else { return true }
        return now.timeIntervalSince(lastRecordedAt) >= minimumInterval
    }
}

/// Demand-driven, privacy-preserving diagnostics for the WE1 Debug bundle.
/// Callers capture small value snapshots on the main actor; JSON encoding and
/// file I/O always happen on a utility queue. Production SuperIsland never
/// enters this path, and no timer or background inventory scan is introduced.
final class WindowInventoryDiagnosticRecorder: @unchecked Sendable {
    static let shared = WindowInventoryDiagnosticRecorder()

    private struct BoundsRecord: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init?(_ bounds: CGRect?) {
            guard let bounds else { return nil }
            x = bounds.origin.x
            y = bounds.origin.y
            width = bounds.width
            height = bounds.height
        }
    }

    private struct AXSourceRecord: Codable {
        let hasFocusedWindow: Bool
        let hasMainWindow: Bool
        let windowsAttributeResult: Int32
        let windowsAttributeCount: Int
        let lifecycleRegistryCount: Int
        let collectedCount: Int
    }

    private struct AXCandidateRecord: Codable {
        let token: Int
        let ownerPID: pid_t
        let windowID: CGWindowID?
        let role: String
        let subrole: String
        let titlePresent: Bool
        let titleLength: Int
        let bounds: BoundsRecord?
        let isMinimized: Bool
        let isPreferredWindow: Bool
        let isHidden: Bool?
        let isVisible: Bool?
        let isModal: Bool?
        let isFocusedSource: Bool
        let isMainSource: Bool
        let isWindowsAttributeSource: Bool
        let isLifecycleRegistrySource: Bool
        let wasIncludedByAXPolicy: Bool
    }

    private struct CandidateRecord: Codable {
        let token: Int
        let ownerPID: pid_t
        let windowID: CGWindowID?
        let titlePresent: Bool
        let titleLength: Int
        let bounds: BoundsRecord?
        let isMinimized: Bool
        let isPreferredWindow: Bool
    }

    private struct SurfaceRecord: Codable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let bounds: BoundsRecord?
        let layer: Int
        let titlePresent: Bool
        let titleLength: Int
        let isOnScreen: Bool
        let alpha: Double
        let spaceIDs: [UInt64]
        let source: String
        let ownerWasPrivatelyValidated: Bool
        let levelWasPrivatelyValidated: Bool
        let isRetainablePrivateTarget: Bool
    }

    private struct ResolvedRecord: Codable {
        let windowID: CGWindowID
        let operationToken: Int?
        let confidence: String
    }

    private struct RejectionRecord: Codable {
        let token: Int
        let reason: String
    }

    private struct RegistrationRecord: Codable {
        let notification: String
        let targetWindowID: CGWindowID?
        let result: Int32
    }

    private struct LifecycleRecord: Codable {
        let observerCreationResult: Int32?
        let isObservationInstalled: Bool
        let windowIDs: [CGWindowID]
        let notificationRegistrations: [RegistrationRecord]
        let observerID: String?
        let registryEpoch: UInt64?
        let bindingGeneration: UInt64?
    }

    private struct Record: Codable {
        let schemaVersion: Int
        let sessionID: String
        let timestamp: Date
        let source: String
        let appBundleIdentifier: String?
        let processIdentifier: pid_t
        let buildNumber: String
        let axSources: AXSourceRecord
        let rawAXCandidates: [AXCandidateRecord]
        let reconcilerCandidates: [CandidateRecord]
        let lifecycle: LifecycleRecord
        let inventoryMode: String
        let inventoryIsComplete: Bool
        let inventoryCapturedAt: Date
        let surfaces: [SurfaceRecord]
        let retainedWindowIDs: [CGWindowID]
        let resolved: [ResolvedRecord]
        let rejections: [RejectionRecord]
    }

    private let ioQueue = DispatchQueue(
        label: "com.workview.SuperIsland.WE1Debug.window-inventory-diagnostics",
        qos: .utility
    )
    private let rateLock = NSLock()
    private var lastRecordedAtByKey: [String: Date] = [:]
    private let sessionID = UUID().uuidString
    private let minimumInterval: TimeInterval = 0.75
    private let maximumFileBytes: UInt64 = 2 * 1_024 * 1_024
    private let maximumRateLimitKeys = 96

    private init() {}

    static var diagnosticFileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SuperIsland-WE1-Debug", isDirectory: true)
            .appendingPathComponent("window-inventory.jsonl", isDirectory: false)
    }

    func record(
        source: WindowInventoryDiagnosticSource,
        applicationBundleIdentifier: String?,
        processIdentifier: pid_t,
        axSources: WindowInventoryAXSourceDiagnostics,
        rawAXCandidates: [WindowInventoryAXCandidateDiagnostics],
        reconcilerCandidates: [WindowInventoryCandidate],
        lifecycle: WindowAXLifecycleDiagnosticSnapshot,
        snapshot: WindowServerInventorySnapshot,
        retainedWindowIDs: Set<CGWindowID>,
        resolution: WindowInventoryResolution
    ) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        guard WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: bundleIdentifier
        ), processIdentifier > 0, let fileURL = Self.diagnosticFileURL else {
            return
        }

        let now = Date()
        let rateKey = "\(source.rawValue)|\(processIdentifier)"
        rateLock.lock()
        let shouldRecord = WindowInventoryDiagnosticGate.shouldRecord(
            now: now,
            lastRecordedAt: lastRecordedAtByKey[rateKey],
            minimumInterval: minimumInterval
        )
        if shouldRecord {
            if lastRecordedAtByKey[rateKey] == nil,
               lastRecordedAtByKey.count >= maximumRateLimitKeys,
               let oldestKey = lastRecordedAtByKey.min(by: {
                   $0.value < $1.value
               })?.key {
                lastRecordedAtByKey.removeValue(forKey: oldestKey)
            }
            lastRecordedAtByKey[rateKey] = now
        }
        rateLock.unlock()
        guard shouldRecord else { return }

        let record = Record(
            schemaVersion: 1,
            sessionID: sessionID,
            timestamp: now,
            source: source.rawValue,
            appBundleIdentifier: applicationBundleIdentifier,
            processIdentifier: processIdentifier,
            buildNumber: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            axSources: AXSourceRecord(
                hasFocusedWindow: axSources.hasFocusedWindow,
                hasMainWindow: axSources.hasMainWindow,
                windowsAttributeResult: axSources.windowsAttributeResult,
                windowsAttributeCount: axSources.windowsAttributeCount,
                lifecycleRegistryCount: axSources.lifecycleRegistryCount,
                collectedCount: axSources.collectedCount
            ),
            rawAXCandidates: rawAXCandidates.map {
                AXCandidateRecord(
                    token: $0.token,
                    ownerPID: $0.ownerPID,
                    windowID: $0.windowID,
                    role: $0.role,
                    subrole: $0.subrole,
                    titlePresent: $0.titleLength > 0,
                    titleLength: $0.titleLength,
                    bounds: BoundsRecord($0.bounds),
                    isMinimized: $0.isMinimized,
                    isPreferredWindow: $0.isPreferredWindow,
                    isHidden: $0.isHidden,
                    isVisible: $0.isVisible,
                    isModal: $0.isModal,
                    isFocusedSource: $0.isFocusedSource,
                    isMainSource: $0.isMainSource,
                    isWindowsAttributeSource: $0.isWindowsAttributeSource,
                    isLifecycleRegistrySource: $0.isLifecycleRegistrySource,
                    wasIncludedByAXPolicy: $0.wasIncludedByAXPolicy
                )
            },
            reconcilerCandidates: reconcilerCandidates.map {
                CandidateRecord(
                    token: $0.token,
                    ownerPID: $0.ownerPID,
                    windowID: $0.windowID,
                    titlePresent: !$0.title.isEmpty,
                    titleLength: $0.title.count,
                    bounds: BoundsRecord($0.bounds),
                    isMinimized: $0.isMinimized,
                    isPreferredWindow: $0.isPreferredWindow
                )
            },
            lifecycle: LifecycleRecord(
                observerCreationResult: lifecycle.observerCreationResult,
                isObservationInstalled: lifecycle.isObservationInstalled,
                windowIDs: lifecycle.windowIDs,
                notificationRegistrations: lifecycle.notificationRegistrations.map {
                    RegistrationRecord(
                        notification: $0.notification,
                        targetWindowID: $0.targetWindowID,
                        result: $0.result
                    )
                },
                observerID: lifecycle.observerID,
                registryEpoch: lifecycle.registryEpoch,
                bindingGeneration: lifecycle.bindingGeneration
            ),
            inventoryMode: snapshot.mode.rawValue,
            inventoryIsComplete: snapshot.isComplete,
            inventoryCapturedAt: snapshot.capturedAt,
            surfaces: snapshot.surfaces.map {
                SurfaceRecord(
                    windowID: $0.windowID,
                    ownerPID: $0.ownerPID,
                    bounds: BoundsRecord($0.bounds),
                    layer: $0.layer,
                    titlePresent: !$0.title.isEmpty,
                    titleLength: $0.title.count,
                    isOnScreen: $0.isOnScreen,
                    alpha: $0.alpha,
                    spaceIDs: $0.spaceIDs.sorted(),
                    source: $0.source.rawValue,
                    ownerWasPrivatelyValidated: $0.ownerWasPrivatelyValidated,
                    levelWasPrivatelyValidated: $0.levelWasPrivatelyValidated,
                    isRetainablePrivateTarget: WindowInventoryReconciler
                        .isRetainablePrivateTarget($0, mode: snapshot.mode)
                )
            },
            retainedWindowIDs: retainedWindowIDs.sorted(),
            resolved: resolution.windows.map {
                ResolvedRecord(
                    windowID: $0.surface.windowID,
                    operationToken: $0.operationToken,
                    confidence: $0.confidence.rawValue
                )
            },
            rejections: resolution.rejections.map {
                RejectionRecord(token: $0.token, reason: $0.reason.rawValue)
            }
        )
        ioQueue.async { [maximumFileBytes] in
            Self.append(record, to: fileURL, maximumFileBytes: maximumFileBytes)
        }
    }

    private static func append(
        _ record: Record,
        to fileURL: URL,
        maximumFileBytes: UInt64
    ) {
        autoreleasepool {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let size = try? fileManager.attributesOfItem(
                    atPath: fileURL.path
                )[.size] as? NSNumber,
                   size.uint64Value >= maximumFileBytes {
                    let previousURL = fileURL
                        .deletingPathExtension()
                        .appendingPathExtension("previous.jsonl")
                    try? fileManager.removeItem(at: previousURL)
                    try fileManager.moveItem(at: fileURL, to: previousURL)
                }

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var data = try encoder.encode(record)
                data.append(0x0A)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: .atomic)
                    return
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostics are intentionally best-effort and must never
                // affect preview behavior or keep an always-running task alive.
            }
        }
    }
}

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
    let levelWasPrivatelyValidated: Bool

    init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        bounds: CGRect,
        layer: Int,
        title: String,
        isOnScreen: Bool,
        alpha: Double,
        spaceIDs: Set<UInt64>,
        source: Source,
        ownerWasPrivatelyValidated: Bool,
        levelWasPrivatelyValidated: Bool = false
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.title = title
        self.isOnScreen = isOnScreen
        self.alpha = alpha
        self.spaceIDs = spaceIDs
        self.source = source
        self.ownerWasPrivatelyValidated = ownerWasPrivatelyValidated
        self.levelWasPrivatelyValidated = levelWasPrivatelyValidated
    }
}

enum WindowServerInventoryMode: String, Sendable {
    case skyLight
    case publicFallback
    case unavailable
}

struct WindowServerInventorySnapshot: Sendable {
    let capturedAt: Date
    let mode: WindowServerInventoryMode
    /// True only when the private all-Space enumeration and every projection
    /// query needed for absence accounting completed without truncation.
    /// Public fallback and partial private results may still match a current
    /// exact AX proxy, but they must never age historical bindings.
    let isComplete: Bool
    let surfaces: [WindowServerSurface]

    init(
        capturedAt: Date,
        mode: WindowServerInventoryMode,
        isComplete: Bool = false,
        surfaces: [WindowServerSurface]
    ) {
        self.capturedAt = capturedAt
        self.mode = mode
        self.isComplete = isComplete
        self.surfaces = surfaces
    }

    var surfacesByID: [CGWindowID: WindowServerSurface] {
        var result: [CGWindowID: WindowServerSurface] = [:]
        var conflictingIDs = Set<CGWindowID>()
        for surface in surfaces {
            if let existing = result[surface.windowID], existing != surface {
                conflictingIDs.insert(surface.windowID)
            } else if result[surface.windowID] == nil {
                result[surface.windowID] = surface
            }
        }
        for windowID in conflictingIDs {
            result.removeValue(forKey: windowID)
        }
        return result
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
        case privateWindowServerEvidence
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

/// A user-facing canonical WindowServer identity and its optional current AX
/// operation proxy. A surface without a proxy is admitted only when this same
/// process instance previously exposed that exact ID through a valid AX window
/// and the current private inventory still proves it is live.
struct WindowInventoryResolvedWindow: Sendable, Equatable {
    let surface: WindowServerSurface
    /// The AX proxy used for focus/raise/close. A nil token means the window
    /// has strong private WindowServer evidence but no trustworthy AX proxy;
    /// it may be shown and captured, but AX actions must stay unavailable.
    let operationToken: Int?
    let confidence: WindowInventoryMatch.Confidence
}

struct WindowInventoryResolution: Sendable, Equatable {
    let windows: [WindowInventoryResolvedWindow]
    let rejections: [WindowInventoryRejection]
}

/// Pure, fail-closed AX-to-WindowServer reconciliation. An AX proxy with an
/// explicit WindowServer number must resolve to that exact same-PID surface.
/// A proxy without a number is admitted only when title/geometry identify one
/// surface unambiguously without contradicting any exact-ID claim.
enum WindowInventoryReconciler {
    static func resolve(
        candidates: [WindowInventoryCandidate],
        snapshot: WindowServerInventorySnapshot,
        retainedWindowIDs: Set<CGWindowID> = []
    ) -> WindowInventoryResolution {
        let reconciliation = reconcile(candidates: candidates, snapshot: snapshot)
        let surfacesByID = snapshot.surfacesByID
        var windows = reconciliation.matches.compactMap { match in
            surfacesByID[match.windowID].map {
                WindowInventoryResolvedWindow(
                    surface: $0,
                    operationToken: match.token,
                    confidence: match.confidence
                )
            }
        }
        let claimedWindowIDs = Set(windows.map(\.surface.windowID))
        windows.append(contentsOf: surfacesByID.values
            .sorted { $0.windowID < $1.windowID }
            .compactMap { surface in
                guard retainedWindowIDs.contains(surface.windowID),
                      !claimedWindowIDs.contains(surface.windowID),
                      isRetainablePrivateTarget(surface, mode: snapshot.mode) else {
                    return nil
                }
                return WindowInventoryResolvedWindow(
                    surface: surface,
                    operationToken: nil,
                    confidence: .privateWindowServerEvidence
                )
            })
        return WindowInventoryResolution(
            windows: windows,
            rejections: reconciliation.rejections
        )
    }

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
        // Rank against every plausible surface, including exact claims. If an
        // ID-less AX proxy fits an already-claimed surface just as well as an
        // unclaimed one, excluding the claim would manufacture false
        // uniqueness and could attach operations to the wrong window.
        let fuzzySurfaces = snapshot.surfaces
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

    /// Current liveness boundary for a previously AX-proven exact window ID.
    /// Raw surfaces can satisfy these structural facts and still be App helper
    /// shells, so this predicate never grants first admission on its own.
    static func isRetainablePrivateTarget(
        _ surface: WindowServerSurface,
        mode: WindowServerInventoryMode
    ) -> Bool {
        mode == .skyLight
            && surface.source == .skyLight
            && surface.ownerWasPrivatelyValidated
            && surface.levelWasPrivatelyValidated
            && !surface.spaceIDs.isEmpty
            && isStructurallyUsable(surface)
            && isSubstantive(surface)
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
        switch mode {
        case .skyLight:
            guard surface.source == .skyLight else { return false }
            // A minimized standard AX window can lose meaningful bounds and
            // Space membership. Exact WindowServer ID plus privately verified
            // owner is the minimum safe identity; never admit an ID-less
            // minimized proxy through fuzzy matching.
            if candidate.isMinimized {
                return surface.ownerWasPrivatelyValidated
            }
            guard isSubstantive(surface) else { return false }
            // Space lookup is advisory for a currently onscreen exact ID: it
            // can transiently fail even though AX and WindowServer already
            // agree on PID and identity. Offscreen windows remain strict.
            return surface.isOnScreen
                || (surface.ownerWasPrivatelyValidated && !surface.spaceIDs.isEmpty)
        case .publicFallback:
            // Public CGWindowList cannot prove minimized or cross-Space
            // identity. Degrade only to a substantive onscreen exact match.
            return !candidate.isMinimized
                && surface.source == .publicWindowList
                && surface.isOnScreen
                && isSubstantive(surface)
        case .unavailable:
            return false
        }
    }

    private static func isPlausibleFuzzyTarget(
        _ surface: WindowServerSurface,
        for candidate: WindowInventoryCandidate,
        mode: WindowServerInventoryMode
    ) -> Bool {
        // A minimized proxy without an exact WindowServer ID cannot be proven
        // distinct from an App helper surface, so fuzzy minimized admission is
        // deliberately fail-closed.
        guard !candidate.isMinimized,
              mode == .skyLight,
              surface.source == .skyLight,
              surface.isOnScreen,
              isStructurallyUsable(surface),
              isSubstantive(surface) else {
            return false
        }
        let candidateTitle = normalizedTitle(candidate.title)
        let surfaceTitle = normalizedTitle(surface.title)
        // Geometry alone is insufficient when both systems provide
        // contradictory non-empty titles. Keep the operation unavailable
        // rather than bind it to the wrong same-PID window.
        return candidateTitle.isEmpty
            || surfaceTitle.isEmpty
            || candidateTitle == surfaceTitle
    }

    private static func isSubstantive(_ surface: WindowServerSurface) -> Bool {
        surface.bounds.width >= 40
            && surface.bounds.height >= 24
            && surface.bounds.width * surface.bounds.height >= 2_048
            && surface.alpha > 0.01
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

/// Process-lifetime memory of exact AX-to-WindowServer bindings. This is the
/// only route by which a temporarily missing AX proxy may retain a display
/// card. The caller must still revalidate every remembered ID against the
/// current private inventory before displaying it.
final class WindowInventoryBindingHistory: @unchecked Sendable {
    static let shared = WindowInventoryBindingHistory()

    private struct Entry {
        let processIdentifier: pid_t
        let completeAbsencesByWindowID: [CGWindowID: Int]
        let lastCompleteObservation: Date?
        let accessSequence: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var accessSequence: UInt64 = 0
    private let maximumProcessEntries: Int
    private let maximumWindowIDsPerProcess: Int
    private let maximumCompleteAbsences: Int

    init(
        maximumProcessEntries: Int = 32,
        maximumWindowIDsPerProcess: Int = 64,
        maximumCompleteAbsences: Int = 2
    ) {
        self.maximumProcessEntries = max(1, maximumProcessEntries)
        self.maximumWindowIDsPerProcess = max(1, maximumWindowIDsPerProcess)
        self.maximumCompleteAbsences = max(1, maximumCompleteAbsences)
    }

    func windowIDs(for processLifetimeKey: String) -> Set<CGWindowID> {
        guard !processLifetimeKey.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[processLifetimeKey] else { return [] }
        accessSequence &+= 1
        entries[processLifetimeKey] = Entry(
            processIdentifier: entry.processIdentifier,
            completeAbsencesByWindowID: entry.completeAbsencesByWindowID,
            lastCompleteObservation: entry.lastCompleteObservation,
            accessSequence: accessSequence
        )
        return Set(entry.completeAbsencesByWindowID.keys)
    }

    /// Records one coherent inventory observation. Exact AX bindings are the
    /// only way IDs enter history. A complete private snapshot must miss an ID
    /// twice before it is forgotten; partial/public results never count as an
    /// absence. Reusing the same raw `capturedAt` cannot double-count through
    /// the Dock and Cmd-Tab consumers.
    func recordObservation(
        processIdentifier: pid_t,
        processLifetimeKey: String,
        confirmedExactWindowIDs: Set<CGWindowID>,
        liveValidatedWindowIDs: Set<CGWindowID>,
        snapshotCapturedAt: Date,
        snapshotIsComplete: Bool
    ) {
        guard processIdentifier > 0, !processLifetimeKey.isEmpty else { return }
        let confirmed = Set(confirmedExactWindowIDs.filter { $0 > 0 })
        let live = Set(liveValidatedWindowIDs.filter { $0 > 0 })
        lock.lock()
        defer { lock.unlock() }

        let previous = entries[processLifetimeKey]
        var absences = previous?.completeAbsencesByWindowID ?? [:]
        for windowID in confirmed {
            absences[windowID] = 0
        }
        for windowID in absences.keys where live.contains(windowID) {
            absences[windowID] = 0
        }

        let isNewCompleteObservation = snapshotIsComplete
            && previous?.lastCompleteObservation != snapshotCapturedAt
        if isNewCompleteObservation {
            for windowID in Array(absences.keys) where !live.contains(windowID) {
                let nextCount = (absences[windowID] ?? 0) + 1
                if nextCount >= maximumCompleteAbsences {
                    absences.removeValue(forKey: windowID)
                } else {
                    absences[windowID] = nextCount
                }
            }
        }

        if absences.count > maximumWindowIDsPerProcess {
            let retainedIDs = Set(absences.keys.sorted().prefix(maximumWindowIDsPerProcess))
            absences = absences.filter { retainedIDs.contains($0.key) }
        }
        if absences.isEmpty {
            entries.removeValue(forKey: processLifetimeKey)
            return
        }
        accessSequence &+= 1
        entries[processLifetimeKey] = Entry(
            processIdentifier: processIdentifier,
            completeAbsencesByWindowID: absences,
            lastCompleteObservation: isNewCompleteObservation
                ? snapshotCapturedAt
                : previous?.lastCompleteObservation,
            accessSequence: accessSequence
        )
        if entries.count > maximumProcessEntries,
           let oldestKey = entries.min(by: {
               $0.value.accessSequence < $1.value.accessSequence
           })?.key {
            entries.removeValue(forKey: oldestKey)
        }
    }

    /// Explicit AX retirement overrides a lingering WindowServer surface.
    /// Removing only these exact bindings preserves other windows and process
    /// launches; later private inventory alone cannot insert the IDs again.
    func forget(
        windowIDs: Set<CGWindowID>,
        processLifetimeKey: String
    ) {
        guard !processLifetimeKey.isEmpty, !windowIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[processLifetimeKey] else { return }
        let remaining = entry.completeAbsencesByWindowID.filter {
            !windowIDs.contains($0.key)
        }
        guard remaining.count != entry.completeAbsencesByWindowID.count else {
            return
        }
        if remaining.isEmpty {
            entries.removeValue(forKey: processLifetimeKey)
        } else {
            entries[processLifetimeKey] = Entry(
                processIdentifier: entry.processIdentifier,
                completeAbsencesByWindowID: remaining,
                lastCompleteObservation: entry.lastCompleteObservation,
                accessSequence: entry.accessSequence
            )
        }
    }

    func remove(processIdentifier: pid_t) {
        guard processIdentifier > 0 else { return }
        lock.lock()
        entries = entries.filter { $0.value.processIdentifier != processIdentifier }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        accessSequence = 0
        lock.unlock()
    }
}

/// Negative identity evidence for WindowServer-only discovery. Positive AX
/// history may be evicted, but forgetting a confirmed retirement would allow
/// its lingering compositor surface to become a new preview-only card.
///
/// The provider protects this value with its capture/cache lock. There is one
/// slot per PID, replaced only by a verified newer process lifetime. Individual
/// slots are bounded; overflow disables only that process's weak discovery.
/// Ordinary AX windows and other processes remain usable. No LRU or timer may
/// silently remove a retirement while its process can still own the surface.
struct WindowPreviewDiscoveryRetirementHistory: Sendable {
    private struct Entry: Sendable {
        let processLifetimeKey: String
        var retiredWindowIDs: Set<CGWindowID>
        var blocksAllDiscovery = false
    }

    private var entriesByPID: [pid_t: Entry] = [:]
    private let maximumWindowIDsPerProcess: Int

    init(maximumWindowIDsPerProcess: Int = 256) {
        self.maximumWindowIDsPerProcess = max(1, maximumWindowIDsPerProcess)
    }

    var trackedProcessCount: Int { entriesByPID.count }

    func trackedWindowCount(processIdentifier: pid_t) -> Int {
        entriesByPID[processIdentifier]?.retiredWindowIDs.count ?? 0
    }

    func needsReestablishment(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        processLifetimeKey: String
    ) -> Bool {
        guard let entry = entriesByPID[processIdentifier],
              entry.processLifetimeKey == processLifetimeKey,
              !entry.blocksAllDiscovery else { return false }
        return entry.retiredWindowIDs.contains(windowID)
    }

    /// The caller must establish that this is the current process lifetime.
    mutating func retire(
        windowIDs: Set<CGWindowID>,
        processIdentifier: pid_t,
        processLifetimeKey: String
    ) {
        let validIDs = windowIDs.filter { $0 > 0 }
        guard processIdentifier > 0, !processLifetimeKey.isEmpty,
              !validIDs.isEmpty else { return }
        var entry = entriesByPID[processIdentifier].flatMap {
            $0.processLifetimeKey == processLifetimeKey ? $0 : nil
        } ?? Entry(processLifetimeKey: processLifetimeKey, retiredWindowIDs: [])
        guard !entry.blocksAllDiscovery else { return }
        let combined = entry.retiredWindowIDs.union(validIDs)
        if combined.count > maximumWindowIDsPerProcess {
            entry.blocksAllDiscovery = true
            entry.retiredWindowIDs.removeAll(keepingCapacity: false)
        } else {
            entry.retiredWindowIDs = combined
        }
        entriesByPID[processIdentifier] = entry
    }

    /// Only a live exact AX proxy with the correct owner can reestablish an ID.
    /// A returned true also requires invalidating work captured before this
    /// identity change. Overflow stays fail-closed until the process exits;
    /// exact AX windows do not use this weak discovery gate.
    @discardableResult
    mutating func reestablish(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        processLifetimeKey: String
    ) -> Bool {
        guard windowID > 0, processIdentifier > 0,
              !processLifetimeKey.isEmpty,
              var entry = entriesByPID[processIdentifier] else { return false }
        guard entry.processLifetimeKey == processLifetimeKey else {
            entriesByPID.removeValue(forKey: processIdentifier)
            return true
        }
        guard !entry.blocksAllDiscovery,
              entry.retiredWindowIDs.remove(windowID) != nil else { return false }
        if entry.retiredWindowIDs.isEmpty {
            entriesByPID.removeValue(forKey: processIdentifier)
        } else {
            entriesByPID[processIdentifier] = entry
        }
        return true
    }

    func allowsDiscovery(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        processLifetimeKey: String?
    ) -> Bool {
        guard windowID > 0, processIdentifier > 0 else { return false }
        guard let entry = entriesByPID[processIdentifier] else { return true }
        // Unknown process identity cannot negate existing retirement evidence.
        guard let processLifetimeKey else { return false }
        guard entry.processLifetimeKey == processLifetimeKey else { return true }
        return !entry.blocksAllDiscovery && !entry.retiredWindowIDs.contains(windowID)
    }

    /// A delayed exit notification must not erase the replacement lifetime's
    /// exclusions. Pass the currently verified live lifetime, or nil after
    /// proving that the PID has no running application.
    mutating func remove(
        processIdentifier: pid_t,
        keepingProcessLifetimeKey: String?
    ) {
        guard let entry = entriesByPID[processIdentifier],
              entry.processLifetimeKey != keepingProcessLifetimeKey else { return }
        entriesByPID.removeValue(forKey: processIdentifier)
    }
}

/// Pure cache deadline policy shared by production and boundary tests. A
/// projected snapshot may never outlive either its own short reuse window or
/// the raw inventory from which it was derived.
enum WindowInventoryCachePolicy {
    static func expiration(
        storedAt: Date,
        rawCapturedAt: Date,
        projectedTTL: TimeInterval = 0.18,
        rawTTL: TimeInterval = 0.30
    ) -> Date {
        min(
            storedAt.addingTimeInterval(projectedTTL),
            rawCapturedAt.addingTimeInterval(rawTTL)
        )
    }

    static func isFresh(now: Date, expiresAt: Date) -> Bool {
        now < expiresAt
    }
}

/// Shared pre-reconciliation deduplication for AX proxy lists. It merges only
/// identities that are factual before WindowServer reconciliation: the same
/// owner plus exact non-zero window ID, or the same owner plus the same id-less
/// AX object. Titles and geometry are deliberately never identity keys.
enum WindowAXProxyPreDeduplicator {
    private struct ExactIdentity: Hashable {
        let ownerPID: pid_t
        let windowID: CGWindowID
    }

    static func deduplicate<Item>(
        _ items: [Item],
        ownerPID: (Item) -> pid_t,
        windowID: (Item) -> CGWindowID?,
        sameAXObject: (Item, Item) -> Bool,
        merge: (Item, Item, CGWindowID?) -> Item
    ) -> [Item] {
        var result: [Item] = []
        var exactIndexes: [ExactIdentity: Int] = [:]
        for item in items {
            let itemOwnerPID = ownerPID(item)
            guard itemOwnerPID > 0 else { continue }
            if let itemWindowID = windowID(item), itemWindowID > 0 {
                let identity = ExactIdentity(
                    ownerPID: itemOwnerPID,
                    windowID: itemWindowID
                )
                if let existingIndex = exactIndexes[identity] {
                    result[existingIndex] = merge(
                        result[existingIndex],
                        item,
                        itemWindowID
                    )
                } else {
                    exactIndexes[identity] = result.count
                    result.append(item)
                }
                continue
            }
            if let existingIndex = result.indices.first(where: { index in
                ownerPID(result[index]) == itemOwnerPID
                    && windowID(result[index]) == nil
                    && sameAXObject(result[index], item)
            }) {
                result[existingIndex] = merge(
                    result[existingIndex],
                    item,
                    nil
                )
            } else {
                result.append(item)
            }
        }
        return result
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
private typealias WindowInventorySLSWindowIsOrderedIn = @convention(c) (
    Int32, CGWindowID, UnsafeMutablePointer<UInt8>
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
        let windowIsOrderedIn: WindowInventorySLSWindowIsOrderedIn?
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
            windowIsOrderedIn: symbol("SLSWindowIsOrderedIn").map {
                unsafeBitCast($0, to: WindowInventorySLSWindowIsOrderedIn.self)
            },
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

    /// Ordered-out backing stores may retain both pixels and an AX root after
    /// closing. Unknown state never authorizes a newly recovered operation.
    static func isOrderedIn(windowID: CGWindowID, ownerPID: pid_t) -> Bool? {
        guard windowID > 0, ownerPID > 0, let resolvers,
              let query = resolvers.windowIsOrderedIn,
              let descriptions = WindowServerWindowDescriptions.copy(for: [windowID]) as? [[String: Any]],
              descriptions.contains(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
              }) else { return nil }
        let connection = resolvers.mainConnectionID()
        guard connection != 0 else { return nil }
        var value: UInt8 = 255
        guard query(Int32(bitPattern: connection), windowID, &value) == 0, value <= 1 else { return nil }
        return value == 1
    }

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
        let expiresAt: Date
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
        requestedWindowIDs: Set<CGWindowID> = [],
        forceRefresh: Bool = false
    ) -> WindowServerInventorySnapshot {
        let pids = Set(processIdentifiers.filter { $0 > 0 })
        let exactWindowIDs = Set(requestedWindowIDs.filter { $0 > 0 })
        guard !pids.isEmpty else {
            return WindowServerInventorySnapshot(
                capturedAt: Date(),
                mode: .unavailable,
                isComplete: false,
                surfaces: []
            )
        }
        let cacheKey = [
            pids.sorted().map(String.init).joined(separator: ","),
            exactWindowIDs.sorted().map(String.init).joined(separator: ",")
        ].joined(separator: "|")
        if !forceRefresh, let cached = cachedSnapshot(for: cacheKey) {
            return cached
        }

        let snapshot = autoreleasepool {
            let rawSnapshot = rawSnapshot(forceRefresh: forceRefresh)
            return projectedSnapshot(
                rawSnapshot,
                for: pids,
                requestedWindowIDs: exactWindowIDs
            )
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
              WindowInventoryCachePolicy.isFresh(
                  now: Date(),
                  expiresAt: entry.expiresAt
              ) else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.snapshot
    }

    private func store(_ snapshot: WindowServerInventorySnapshot, for key: String) {
        let storedAt = Date()
        let expiresAt = WindowInventoryCachePolicy.expiration(
            storedAt: storedAt,
            rawCapturedAt: snapshot.capturedAt,
            projectedTTL: cacheTTL,
            rawTTL: rawInventoryCacheTTL
        )
        cacheLock.lock()
        cache[key] = CacheEntry(snapshot: snapshot, expiresAt: expiresAt)
        if cache.count > maximumCacheEntries,
           let oldest = cache.min(by: {
               $0.value.expiresAt < $1.value.expiresAt
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
                isComplete: true,
                surfaces: []
            )
        }
        guard windowIDs.count <= 8_192 else {
            logger.error(
                "Rejected unbounded SkyLight inventory count=\(windowIDs.count, privacy: .public)"
            )
            return nil
        }

        guard let descriptions = WindowServerWindowDescriptions.copy(
            for: windowIDs
        ) else { return nil }
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
            isComplete: true,
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
            isComplete: false,
            surfaces: deduplicated(surfaces)
        )
    }

    private func projectedSnapshot(
        _ rawSnapshot: WindowServerInventorySnapshot,
        for processIdentifiers: Set<pid_t>,
        requestedWindowIDs: Set<CGWindowID>
    ) -> WindowServerInventorySnapshot {
        var candidateSurfaces = rawSnapshot.surfaces.filter {
            processIdentifiers.contains($0.ownerPID)
        }
        guard rawSnapshot.mode == .skyLight,
              let resolvers = Self.skyLightResolvers else {
            return WindowServerInventorySnapshot(
                capturedAt: rawSnapshot.capturedAt,
                mode: rawSnapshot.mode,
                isComplete: false,
                surfaces: candidateSurfaces
            )
        }
        let connectionID = resolvers.mainConnectionID()
        guard connectionID != 0 else {
            // Do not relabel private surfaces as public evidence. Re-enumerate
            // the actual public list so `mode` and every surface `source`
            // remain internally consistent.
            return projectedSnapshot(
                publicRawSnapshot(),
                for: processIdentifiers,
                requestedWindowIDs: requestedWindowIDs
            )
        }

        // Managed-Space option sets can transiently omit an exact AX window
        // (most often while minimizing or changing Spaces). Ask WindowServer
        // for only those already-known AX IDs; this enriches exact identity
        // without unioning arbitrary public helper surfaces into the inventory.
        let existingWindowIDs = Set(candidateSurfaces.map(\.windowID))
        let missingRequestedIDs = requestedWindowIDs.subtracting(existingWindowIDs)
        var requestedLookupIsComplete = missingRequestedIDs.isEmpty
        if !missingRequestedIDs.isEmpty, missingRequestedIDs.count <= 64,
           let descriptions = WindowServerWindowDescriptions.copy(
               for: missingRequestedIDs.sorted()
           ) {
            requestedLookupIsComplete = true
            candidateSurfaces.append(contentsOf: descriptions.compactMap {
                surface(
                    from: $0,
                    allowedPIDs: processIdentifiers,
                    source: .publicWindowList
                )
            })
            candidateSurfaces = deduplicated(candidateSurfaces)
        }

        candidateSurfaces.sort {
            let leftWasRequested = requestedWindowIDs.contains($0.windowID)
            let rightWasRequested = requestedWindowIDs.contains($1.windowID)
            if leftWasRequested != rightWasRequested {
                return leftWasRequested
            }
            return $0.windowID < $1.windowID
        }

        var validatedSurfaces: [WindowServerSurface] = []
        validatedSurfaces.reserveCapacity(candidateSurfaces.count)
        let projectionWasTruncated = candidateSurfaces.count > 64
        var privateValidationIsComplete = resolvers.getWindowLevel != nil
        for base in candidateSurfaces.prefix(64) {
            var levelWasValidated = false
            if let getWindowLevel = resolvers.getWindowLevel {
                var privateLevel: Int32 = 0
                let levelResult = getWindowLevel(
                    connectionID,
                    base.windowID,
                    &privateLevel
                )
                if levelResult == 0 {
                    guard privateLevel == 0 else { continue }
                    levelWasValidated = true
                } else {
                    privateValidationIsComplete = false
                }
            }

            var privateOwnerConnection: UInt32 = 0
            var privateOwnerPID: pid_t = 0
            let ownerResult = resolvers.getWindowOwner(
                connectionID,
                base.windowID,
                &privateOwnerConnection
            )
            let ownerPIDResult = privateOwnerConnection == 0
                ? Int32(-1)
                : resolvers.connectionGetPID(
                    privateOwnerConnection,
                    &privateOwnerPID
                )
            let ownerWasValidated = ownerResult == 0
                && privateOwnerConnection != 0
                && ownerPIDResult == 0
                && privateOwnerPID > 0
            if !ownerWasValidated {
                privateValidationIsComplete = false
            }
            if ownerWasValidated, privateOwnerPID != base.ownerPID {
                continue
            }

            let copiedSpaces = copySpaceIDs(
                for: base.windowID,
                connectionID: connectionID,
                resolver: resolvers.copySpacesForWindows
            )
            if copiedSpaces == nil {
                privateValidationIsComplete = false
            }
            let spaces = copiedSpaces ?? []
            let validatedSource: WindowServerSurface.Source =
                base.source == .skyLight || ownerWasValidated
                    ? .skyLight
                    : .publicWindowList
            validatedSurfaces.append(WindowServerSurface(
                windowID: base.windowID,
                ownerPID: base.ownerPID,
                bounds: base.bounds,
                layer: base.layer,
                title: base.title,
                isOnScreen: base.isOnScreen,
                alpha: base.alpha,
                spaceIDs: spaces,
                source: validatedSource,
                ownerWasPrivatelyValidated: ownerWasValidated,
                levelWasPrivatelyValidated: levelWasValidated
            ))
        }
        return WindowServerInventorySnapshot(
            capturedAt: rawSnapshot.capturedAt,
            mode: .skyLight,
            isComplete: rawSnapshot.isComplete
                && requestedLookupIsComplete
                && !projectionWasTruncated
                && privateValidationIsComplete,
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
            // Missing compositor opacity is unknown evidence, not an opaque
            // window. Exact minimized identity does not depend on alpha; all
            // substantive visible paths fail closed on this zero value.
            alpha: (description[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
            spaceIDs: [],
            source: source,
            ownerWasPrivatelyValidated: false,
            levelWasPrivatelyValidated: false
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
    ) -> Set<UInt64>? {
        guard let copied = resolver(
            connectionID,
            7,
            [NSNumber(value: windowID)] as CFArray
        )?.takeRetainedValue() as? [NSNumber] else {
            return nil
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
