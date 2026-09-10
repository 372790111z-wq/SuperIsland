import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import SuperIsland

final class WindowInventoryReconcilerTests: XCTestCase {
    func testWindowDescriptionQueryReceivesRawUnsignedWindowIDs() {
        let ids: [CGWindowID] = [196, 0, 0x8000_0000, .max, 196]
        var received: [UInt] = []
        let result = WindowServerWindowDescriptions.copy(for: ids) { array in
            received = (0..<CFArrayGetCount(array)).map {
                UInt(bitPattern: CFArrayGetValueAtIndex(array, $0))
            }
            return [] as CFArray
        }
        XCTAssertEqual(received, ids.map(UInt.init))
        XCTAssertEqual(result?.count, 0)
    }

    func testWindowDescriptionQueryPreservesFailureAndSuccessfulEmptyResults() {
        XCTAssertNil(WindowServerWindowDescriptions.copy(for: [196]) { _ in nil })
        let empty = WindowServerWindowDescriptions.copy(for: [196]) { _ in [] as CFArray }
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.count, 0)
    }

    func testWindowDescriptionQueryAllowsOmittedAndReorderedIDs() {
        let result = WindowServerWindowDescriptions.copy(for: [196, 197, 198]) { _ in
            [
                [kCGWindowNumber as String: NSNumber(value: 198)],
                [kCGWindowNumber as String: NSNumber(value: 196)]
            ] as CFArray
        }
        XCTAssertEqual(result?.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }, [198, 196])
    }

    func testWindowDescriptionQueryUsesAnEmptyArrayForNoRequestedWindows() {
        var requestedCount: Int?
        let result = WindowServerWindowDescriptions.copy(for: []) { array in
            requestedCount = CFArrayGetCount(array)
            return [] as CFArray
        }
        XCTAssertEqual(requestedCount, 0)
        XCTAssertEqual(result?.count, 0)
    }

    @MainActor
    func testWindowDescriptionQueryFindsAnActualUnshownWindow() async throws {
        // Allocate a test-owned WindowServer window without ordering it on
        // screen. This exercises the real API, without user windows or TCC.
        let window = NSWindow(
            contentRect: CGRect(x: -16_000, y: -16_000, width: 180, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(window.isVisible)
        let windowID = try XCTUnwrap(CGWindowID(exactly: window.windowNumber))
        XCTAssertNotEqual(windowID, kCGNullWindowID)
        let descriptions = try XCTUnwrap(WindowServerWindowDescriptions.copy(for: [windowID]))
        XCTAssertEqual(descriptions.count, 1)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(
            (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value, windowID
        )
        XCTAssertEqual(
            (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, getpid()
        )
        XCTAssertFalse(window.isVisible)
    }

    func testInventoryDiagnosticsAreRestrictedToWE1DebugBundle() {
        XCTAssertTrue(WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: "com.workview.SuperIsland.WE1Debug"
        ))
        XCTAssertFalse(WindowInventoryDiagnosticGate.isEnabled(
            bundleIdentifier: "com.workview.SuperIsland"
        ))
        XCTAssertFalse(WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: nil))
    }

    func testInventoryDiagnosticsRateLimitIsDeterministic() {
        let lastRecordedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(WindowInventoryDiagnosticGate.shouldRecord(
            now: lastRecordedAt.addingTimeInterval(0.749),
            lastRecordedAt: lastRecordedAt,
            minimumInterval: 0.75
        ))
        XCTAssertTrue(WindowInventoryDiagnosticGate.shouldRecord(
            now: lastRecordedAt.addingTimeInterval(0.75),
            lastRecordedAt: lastRecordedAt,
            minimumInterval: 0.75
        ))
        XCTAssertTrue(WindowInventoryDiagnosticGate.shouldRecord(
            now: lastRecordedAt,
            lastRecordedAt: nil,
            minimumInterval: 0.75
        ))
    }

    func testHiddenMinimizedAXProxyIsRejected() {
        XCTAssertFalse(WindowAXCandidatePolicy.shouldInclude(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isModal: false,
            title: "Helper",
            isMinimized: true,
            isPreferredWindow: true,
            isHidden: true,
            isVisible: nil
        ))
    }

    func testUntitledVisibleStandardAXWindowReachesCanonicalReconciliation() {
        XCTAssertTrue(WindowAXCandidatePolicy.shouldInclude(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isModal: false,
            title: "",
            isMinimized: false,
            isPreferredWindow: false,
            isHidden: false,
            isVisible: true
        ))
    }

    func testDockGuardTimerRunsOnlyForCommittedActiveRequest() {
        XCTAssertTrue(DockDisplayLockActivityPolicy.shouldRunGuardTimer(
            started: true,
            featureEnabled: true,
            requested: true,
            suspendedForSleep: false
        ))
        XCTAssertFalse(DockDisplayLockActivityPolicy.shouldRunGuardTimer(
            started: true,
            featureEnabled: true,
            requested: false,
            suspendedForSleep: false
        ))
        XCTAssertFalse(DockDisplayLockActivityPolicy.shouldRunGuardTimer(
            started: true,
            featureEnabled: false,
            requested: true,
            suspendedForSleep: false
        ))
        XCTAssertFalse(DockDisplayLockActivityPolicy.shouldRunGuardTimer(
            started: true,
            featureEnabled: true,
            requested: true,
            suspendedForSleep: true
        ))
    }

    func testOrdinaryDesktopMovementDoesNotScheduleMissionControlAXWork() {
        XCTAssertFalse(MissionControlInspectionPolicy.shouldSchedule(
            force: false,
            missionControlHierarchyObserved: false
        ))
        XCTAssertTrue(MissionControlInspectionPolicy.shouldSchedule(
            force: true,
            missionControlHierarchyObserved: false
        ))
        XCTAssertTrue(MissionControlInspectionPolicy.shouldSchedule(
            force: false,
            missionControlHierarchyObserved: true
        ))
    }

    func testRendererDirectChildInsideTargetBundleIsTrusted() {
        let parents: [pid_t: pid_t] = [200: 100]
        XCTAssertEqual(
            WindowRendererLineagePolicy.descendantDepth(
                candidatePID: 200,
                targetPID: 100,
                parentOf: { parents[$0] }
            ),
            1
        )
        XCTAssertTrue(WindowRendererLineagePolicy.executablePath(
            "/Applications/WeChat.app/Contents/Helpers/Renderer",
            isInsideBundleAt: "/Applications/WeChat.app"
        ))
    }

    func testRendererGrandchildInsideTargetBundleIsTrusted() {
        let parents: [pid_t: pid_t] = [300: 200, 200: 100]
        XCTAssertEqual(
            WindowRendererLineagePolicy.descendantDepth(
                candidatePID: 300,
                targetPID: 100,
                parentOf: { parents[$0] }
            ),
            2
        )
    }

    func testUnrelatedProcessDoesNotReachTarget() {
        let parents: [pid_t: pid_t] = [300: 250, 250: 1]
        XCTAssertNil(WindowRendererLineagePolicy.descendantDepth(
            candidatePID: 300,
            targetPID: 100,
            parentOf: { parents[$0] }
        ))
    }

    func testSiblingBundlePathPrefixDoesNotMasqueradeAsTargetBundle() {
        XCTAssertFalse(WindowRendererLineagePolicy.executablePath(
            "/Applications/WeChat.app.fake/Contents/MacOS/Renderer",
            isInsideBundleAt: "/Applications/WeChat.app"
        ))
    }

    func testWeakVendorOnlyBundlePrefixIsRejected() {
        XCTAssertEqual(
            WindowRendererLineagePolicy.commonBundlePrefixCount(
                "com.tencent.xinWeChat",
                "com.tencent.flue.helper.renderer"
            ),
            2
        )
    }

    func testVerifiedDescendantDoesNotRequireMatchingBundleIdentifier() {
        XCTAssertEqual(
            WindowRendererLineagePolicy.relationshipPenalty(
                descendantDepth: 2,
                executableInsideTargetBundle: true,
                isSiblingProcess: false,
                sharesBundleNamespace: false,
                launchDelta: 10
            ),
            8
        )
    }

    func testUnrelatedRendererCannotUseBundleNamespaceAlone() {
        XCTAssertNil(WindowRendererLineagePolicy.relationshipPenalty(
            descendantDepth: nil,
            executableInsideTargetBundle: false,
            isSiblingProcess: false,
            sharesBundleNamespace: true,
            launchDelta: 0
        ))
    }

    func testSameLaunchSiblingStillRequiresSpecificBundleNamespace() {
        XCTAssertNil(WindowRendererLineagePolicy.relationshipPenalty(
            descendantDepth: nil,
            executableInsideTargetBundle: false,
            isSiblingProcess: true,
            sharesBundleNamespace: false,
            launchDelta: 1
        ))
        XCTAssertEqual(
            WindowRendererLineagePolicy.relationshipPenalty(
                descendantDepth: nil,
                executableInsideTargetBundle: false,
                isSiblingProcess: true,
                sharesBundleNamespace: true,
                launchDelta: 2
            ),
            24
        )
    }

    func testFreshThumbnailIsEligibleForCard() {
        XCTAssertTrue(WindowThumbnailResult.fresh(NSImage(size: NSSize(width: 8, height: 8))).isEligibleForWindowCard)
    }

    func testRecentThumbnailIsEligibleForCard() {
        XCTAssertTrue(WindowThumbnailResult.recentCache(
            NSImage(size: NSSize(width: 8, height: 8)),
            timestamp: Date()
        ).isEligibleForWindowCard)
    }

    func testPermissionBoundaryIsEligibleForExplanatoryCard() {
        XCTAssertTrue(WindowThumbnailResult.permissionRequired.isEligibleForWindowCard)
    }

    func testRestartBoundaryIsEligibleForExplanatoryCard() {
        XCTAssertTrue(WindowThumbnailResult.restartRequired.isEligibleForWindowCard)
    }

    func testNotEnumeratedThumbnailIsNotEligibleForCard() {
        XCTAssertFalse(WindowThumbnailResult.notEnumerated.isEligibleForWindowCard)
    }

    func testAmbiguousThumbnailIsNotEligibleForCard() {
        XCTAssertFalse(WindowThumbnailResult.ambiguous.isEligibleForWindowCard)
    }

    func testBlankCaptureIsNotEligibleForCard() {
        XCTAssertFalse(WindowThumbnailResult.captureFailed.isEligibleForWindowCard)
    }

    func testExactIDIsAccepted() {
        assertSingleExact(candidate: candidate(id: 10), surface: surface(id: 10))
    }

    func testExactIDRequiresSameOwner() {
        let result = reconcile([candidate(id: 10, pid: 42)], [surface(id: 10, pid: 99)])
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections, [.init(token: 0, reason: .exactWindowMissing)])
    }

    func testExactIDMustExist() {
        let result = reconcile([candidate(id: 10)], [surface(id: 11)])
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testInvalidOwnerIsRejected() {
        let result = reconcile([candidate(id: nil, pid: 0)], [surface(id: 10)])
        XCTAssertEqual(result.rejections.first?.reason, .invalidOwner)
    }

    func testDuplicateExactSurfacePrefersPreferredWindow() {
        let candidates = [
            candidate(token: 0, id: 10, preferred: false),
            candidate(token: 1, id: 10, preferred: true)
        ]
        let result = reconcile(candidates, [surface(id: 10)])
        XCTAssertEqual(result.matches.map(\.token), [1])
        XCTAssertEqual(result.rejections, [.init(token: 0, reason: .duplicateSurface)])
    }

    func testDuplicateExactSurfacePrefersRicherMetadata() {
        let candidates = [
            candidate(token: 0, id: 10, title: "", bounds: nil),
            candidate(token: 1, id: 10, title: "Document", bounds: rect())
        ]
        let result = reconcile(candidates, [surface(id: 10, title: "Document")])
        XCTAssertEqual(result.matches.map(\.token), [1])
    }

    func testExactMinimizedSurfaceMayKeepSmallBounds() {
        let tiny = CGRect(x: 0, y: 0, width: 1, height: 1)
        let result = reconcile(
            [candidate(id: 10, bounds: tiny, minimized: true)],
            [surface(id: 10, bounds: tiny)]
        )
        XCTAssertEqual(result.matches.count, 1)
    }

    func testExactSurfaceRejectsNonzeroLayer() {
        let result = reconcile([candidate(id: 10)], [surface(id: 10, layer: 3)])
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testExactSurfaceRejectsZeroBounds() {
        let result = reconcile(
            [candidate(id: 10)],
            [surface(id: 10, bounds: .zero)]
        )
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testFuzzyExactGeometryIsAccepted() {
        let result = reconcile(
            [candidate(id: nil, title: "")],
            [surface(id: 10, title: "")]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
        XCTAssertEqual(result.matches.first?.confidence, .uniqueGeometryAndTitle)
    }

    func testFuzzyMatchingUsesCaseInsensitiveTitle() {
        let result = reconcile(
            [candidate(id: nil, title: "DOCUMENT")],
            [surface(id: 10, title: "document")]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
    }

    func testFuzzyMatchingUsesDiacriticInsensitiveTitle() {
        let result = reconcile(
            [candidate(id: nil, title: "Résumé")],
            [surface(id: 10, title: "resume")]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
    }

    func testFuzzyTitleWithoutGeometryIsRejected() {
        let result = reconcile(
            [candidate(id: nil, title: "Document", bounds: nil)],
            [surface(id: 10, title: "Document")]
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testFuzzyUnrelatedGeometryIsRejected() {
        let far = CGRect(x: 900, y: 700, width: 200, height: 160)
        let result = reconcile(
            [candidate(id: nil, title: "", bounds: rect())],
            [surface(id: 10, title: "", bounds: far)]
        )
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testFuzzyWrongOwnerIsRejected() {
        let result = reconcile(
            [candidate(id: nil, pid: 42)],
            [surface(id: 10, pid: 99)]
        )
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testFuzzySmallSurfaceIsRejected() {
        let tiny = CGRect(x: 100, y: 100, width: 20, height: 20)
        let result = reconcile(
            [candidate(id: nil, bounds: tiny)],
            [surface(id: 10, bounds: tiny)]
        )
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testFuzzyTransparentSurfaceIsRejected() {
        let result = reconcile(
            [candidate(id: nil)],
            [surface(id: 10, alpha: 0)]
        )
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testFuzzyAmbiguousSurfacesAreRejected() {
        let close = CGRect(x: 101, y: 100, width: 500, height: 400)
        let result = reconcile(
            [candidate(id: nil, title: "Document")],
            [
                surface(id: 10, title: "Document"),
                surface(id: 11, title: "Document", bounds: close)
            ]
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .ambiguousSurface)
    }

    func testExactClaimPreventsFuzzyDuplicate() {
        let result = reconcile(
            [
                candidate(token: 0, id: 10),
                candidate(token: 1, id: nil)
            ],
            [surface(id: 10)]
        )
        XCTAssertEqual(result.matches.map(\.token), [0])
        XCTAssertEqual(result.rejections.last?.reason, .duplicateSurface)
    }

    func testTwoFuzzyCandidatesMapToDistinctSurfaces() {
        let secondRect = CGRect(x: 700, y: 100, width: 500, height: 400)
        let result = reconcile(
            [
                candidate(token: 0, id: nil, title: "One"),
                candidate(token: 1, id: nil, title: "Two", bounds: secondRect)
            ],
            [
                surface(id: 10, title: "One"),
                surface(id: 11, title: "Two", bounds: secondRect)
            ]
        )
        XCTAssertEqual(result.matches.map(\.windowID), [10, 11])
    }

    func testDuplicateFuzzyProxiesCollapseToOneSurface() {
        let result = reconcile(
            [
                candidate(token: 0, id: nil),
                candidate(token: 1, id: nil)
            ],
            [surface(id: 10)]
        )
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.rejections.count, 1)
        XCTAssertEqual(result.rejections.first?.reason, .duplicateSurface)
    }

    func testPreferredFuzzyProxyWinsDuplicateClaim() {
        let result = reconcile(
            [
                candidate(token: 0, id: nil, preferred: false),
                candidate(token: 1, id: nil, preferred: true)
            ],
            [surface(id: 10)]
        )
        XCTAssertEqual(result.matches.map(\.token), [1])
    }

    func testMatchesPreserveCandidateTokenOrder() {
        let result = reconcile(
            [
                candidate(token: 9, id: 90),
                candidate(token: 2, id: 20)
            ],
            [surface(id: 90), surface(id: 20)]
        )
        XCTAssertEqual(result.matches.map(\.token), [2, 9])
    }

    func testRejectionsPreserveCandidateTokenOrder() {
        let result = reconcile(
            [
                candidate(token: 9, id: 90),
                candidate(token: 2, id: 20)
            ],
            []
        )
        XCTAssertEqual(result.rejections.map(\.token), [2, 9])
    }

    func testPublicFallbackStillAcceptsExactIdentity() {
        let result = WindowInventoryReconciler.reconcile(
            candidates: [candidate(id: 10)],
            snapshot: snapshot([surface(id: 10, source: .publicWindowList)], mode: .publicFallback)
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
    }

    func testUnavailableSnapshotFailsClosed() {
        let result = WindowInventoryReconciler.reconcile(
            candidates: [candidate(id: 10)],
            snapshot: snapshot([], mode: .unavailable)
        )
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testExactConfidenceIsReported() {
        let result = reconcile([candidate(id: 10)], [surface(id: 10)])
        XCTAssertEqual(result.matches.first?.confidence, .exactWindowServerID)
    }

    func testFuzzyConfidenceIsReported() {
        let result = reconcile([candidate(id: nil)], [surface(id: 10)])
        XCTAssertEqual(result.matches.first?.confidence, .uniqueGeometryAndTitle)
    }

    func testSlightGeometryDriftIsAccepted() {
        let shifted = CGRect(x: 106, y: 105, width: 496, height: 405)
        let result = reconcile(
            [candidate(id: nil, title: "Document")],
            [surface(id: 10, title: "Document", bounds: shifted)]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
    }

    func testDifferentNonemptyTitlesCannotMatchByGeometryAlone() {
        let result = reconcile(
            [candidate(id: nil, title: "AX Title")],
            [surface(id: 10, title: "WindowServer Title")]
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testExactMinimizedIdentityRequiresValidatedOwnerButNotSpaceMembership() {
        let unvalidatedOwner = reconcile(
            [candidate(id: 10, minimized: true)],
            [surface(id: 10, onScreen: false, spaceIDs: [7], ownerValidated: false)]
        )
        XCTAssertTrue(unvalidatedOwner.matches.isEmpty)
        XCTAssertEqual(unvalidatedOwner.rejections.first?.reason, .exactWindowMissing)

        let offscreenWithoutSpace = reconcile(
            [candidate(id: 10, minimized: true)],
            [surface(id: 10, onScreen: false, spaceIDs: [], ownerValidated: true)]
        )
        XCTAssertEqual(offscreenWithoutSpace.matches.first?.windowID, 10)
        XCTAssertTrue(offscreenWithoutSpace.rejections.isEmpty)
    }

    func testExactCrossSpaceIdentityRequiresPrivateSpaceMembership() {
        let result = reconcile(
            [candidate(id: 10)],
            [surface(id: 10, onScreen: false, spaceIDs: [7])]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
    }

    func testExactOffscreenIdentityWithoutSpaceMembershipIsRejected() {
        let result = reconcile(
            [candidate(id: 10)],
            [surface(id: 10, onScreen: false, spaceIDs: [])]
        )
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testExactOnscreenPrivateSurfaceDoesNotRequireSpaceMembership() {
        let result = reconcile(
            [candidate(id: 10)],
            [surface(
                id: 10,
                bounds: rect(),
                layer: 0,
                onScreen: true,
                alpha: 1,
                spaceIDs: [],
                ownerValidated: true
            )]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
        XCTAssertTrue(result.rejections.isEmpty)
    }

    func testExactOffscreenIdentityWithoutValidatedOwnerOrSpaceIsRejected() {
        let result = reconcile(
            [candidate(id: 10)],
            [surface(
                id: 10,
                onScreen: false,
                spaceIDs: [],
                ownerValidated: false
            )]
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testPublicFallbackCannotAdmitOffscreenExactIdentity() {
        let result = WindowInventoryReconciler.reconcile(
            candidates: [candidate(id: 10)],
            snapshot: snapshot(
                [surface(id: 10, onScreen: false, source: .publicWindowList, spaceIDs: [])],
                mode: .publicFallback
            )
        )
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testPublicFallbackRejectsOnscreenFuzzyIdentity() {
        let result = WindowInventoryReconciler.reconcile(
            candidates: [candidate(id: nil)],
            snapshot: snapshot(
                [surface(id: 10, source: .publicWindowList)],
                mode: .publicFallback
            )
        )
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .noUniqueSurface)
    }

    func testOnlyAXBackedCanonicalSurfaceBecomesUserFacingResolvedWindow() {
        let result = resolve(
            [candidate(token: 41, id: 10)],
            [surface(id: 10), surface(id: 11), surface(id: 12)]
        )

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.surface.windowID, 10)
        XCTAssertEqual(result.windows.first?.operationToken, 41)
    }

    func testPreviouslyBoundPrivateSurfaceResolvesAsDisplayOnly() {
        let result = resolve(
            [],
            [surface(id: 11, title: "")],
            retainedWindowIDs: [11]
        )

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.surface.windowID, 11)
        XCTAssertNil(result.windows.first?.operationToken)
        XCTAssertEqual(
            result.windows.first?.confidence,
            .privateWindowServerEvidence
        )
    }

    func testRetainedSurfaceRequiresCompletePrivateLivenessEvidence() {
        let invalidSurfaces = [
            surface(id: 10, ownerValidated: false),
            surface(id: 10, levelValidated: false),
            surface(id: 10, spaceIDs: []),
            surface(id: 10, source: .publicWindowList),
            surface(id: 10, layer: 1),
            surface(id: 10, alpha: 0),
            surface(
                id: 10,
                bounds: CGRect(x: 0, y: 0, width: 20, height: 20)
            )
        ]

        for invalidSurface in invalidSurfaces {
            let result = resolve(
                [],
                [invalidSurface],
                retainedWindowIDs: [10]
            )
            XCTAssertTrue(
                result.windows.isEmpty,
                "Unexpected retained surface: \(invalidSurface)"
            )
        }
    }

    func testDuplicateIdenticalSurfaceIsCanonicalizedOnce() {
        let duplicate = surface(id: 10)
        let result = resolve(
            [candidate(id: 10)],
            [duplicate, duplicate]
        )

        XCTAssertEqual(result.windows.map(\.surface.windowID), [10])
    }

    func testConflictingDuplicateSurfaceFailsClosed() {
        let result = resolve(
            [candidate(id: 10, pid: 42)],
            [surface(id: 10, pid: 42), surface(id: 10, pid: 84)]
        )

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testBindingHistoryIsProcessScopedAndNeedsTwoCompleteMisses() {
        let history = WindowInventoryBindingHistory()
        let firstCapture = Date(timeIntervalSinceReferenceDate: 10)
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start-a|42",
            confirmedExactWindowIDs: [10, 11],
            liveValidatedWindowIDs: [10, 11],
            snapshotCapturedAt: firstCapture,
            snapshotIsComplete: true
        )

        XCTAssertEqual(
            history.windowIDs(for: "app|start-a|42"),
            Set<CGWindowID>([10, 11])
        )
        XCTAssertTrue(history.windowIDs(for: "app|start-b|42").isEmpty)
        XCTAssertTrue(history.windowIDs(for: "app|start-a|84").isEmpty)

        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start-a|42",
            confirmedExactWindowIDs: [],
            liveValidatedWindowIDs: [10],
            snapshotCapturedAt: firstCapture.addingTimeInterval(1),
            snapshotIsComplete: true
        )
        XCTAssertEqual(
            history.windowIDs(for: "app|start-a|42"),
            Set<CGWindowID>([10, 11])
        )

        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start-a|42",
            confirmedExactWindowIDs: [],
            liveValidatedWindowIDs: [10],
            snapshotCapturedAt: firstCapture.addingTimeInterval(2),
            snapshotIsComplete: true
        )
        XCTAssertEqual(
            history.windowIDs(for: "app|start-a|42"),
            Set<CGWindowID>([10])
        )
    }

    func testBindingHistoryDoesNotAgeOnPartialOrRepeatedSnapshot() {
        let history = WindowInventoryBindingHistory()
        let firstCapture = Date(timeIntervalSinceReferenceDate: 20)
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start|42",
            confirmedExactWindowIDs: [10],
            liveValidatedWindowIDs: [10],
            snapshotCapturedAt: firstCapture,
            snapshotIsComplete: true
        )
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start|42",
            confirmedExactWindowIDs: [],
            liveValidatedWindowIDs: [],
            snapshotCapturedAt: firstCapture.addingTimeInterval(1),
            snapshotIsComplete: false
        )
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start|42",
            confirmedExactWindowIDs: [],
            liveValidatedWindowIDs: [],
            snapshotCapturedAt: firstCapture.addingTimeInterval(2),
            snapshotIsComplete: true
        )
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start|42",
            confirmedExactWindowIDs: [],
            liveValidatedWindowIDs: [],
            snapshotCapturedAt: firstCapture.addingTimeInterval(2),
            snapshotIsComplete: true
        )

        XCTAssertEqual(
            history.windowIDs(for: "app|start|42"),
            Set<CGWindowID>([10])
        )
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: "app|start|42",
            confirmedExactWindowIDs: [],
            liveValidatedWindowIDs: [],
            snapshotCapturedAt: firstCapture.addingTimeInterval(3),
            snapshotIsComplete: true
        )
        XCTAssertTrue(history.windowIDs(for: "app|start|42").isEmpty)
    }

    func testBindingHistoryCanRemoveOneTerminatedProcessOrResetAll() {
        let history = WindowInventoryBindingHistory()
        let capture = Date(timeIntervalSinceReferenceDate: 30)
        for (pid, key, windowID) in [(pid_t(42), "a", CGWindowID(10)), (pid_t(84), "b", CGWindowID(20))] {
            history.recordObservation(
                processIdentifier: pid,
                processLifetimeKey: key,
                confirmedExactWindowIDs: [windowID],
                liveValidatedWindowIDs: [windowID],
                snapshotCapturedAt: capture,
                snapshotIsComplete: true
            )
        }

        history.remove(processIdentifier: 42)
        XCTAssertTrue(history.windowIDs(for: "a").isEmpty)
        XCTAssertEqual(history.windowIDs(for: "b"), Set<CGWindowID>([20]))
        history.reset()
        XCTAssertTrue(history.windowIDs(for: "b").isEmpty)
    }

    func testRetiredBindingCannotReturnFromLingeringPrivateSurface() {
        let history = WindowInventoryBindingHistory()
        let lifetime = "wechat|start-a|42"
        let capturedAt = Date(timeIntervalSinceReferenceDate: 40)
        let lingeringSurface = surface(
            id: 259,
            title: "",
            bounds: CGRect(x: 616, y: 362, width: 280, height: 380),
            onScreen: false
        )
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: lifetime,
            confirmedExactWindowIDs: [259],
            liveValidatedWindowIDs: [259],
            snapshotCapturedAt: capturedAt,
            snapshotIsComplete: true
        )
        XCTAssertEqual(
            resolve([], [lingeringSurface], retainedWindowIDs: history.windowIDs(for: lifetime))
                .windows.map(\.surface.windowID),
            [259]
        )

        history.forget(windowIDs: [259], processLifetimeKey: lifetime)
        for offset in 1...3 {
            history.recordObservation(
                processIdentifier: 42,
                processLifetimeKey: lifetime,
                confirmedExactWindowIDs: [],
                liveValidatedWindowIDs: [259],
                snapshotCapturedAt: capturedAt.addingTimeInterval(Double(offset)),
                snapshotIsComplete: true
            )
        }

        XCTAssertTrue(history.windowIDs(for: lifetime).isEmpty)
        XCTAssertTrue(
            resolve([], [lingeringSurface], retainedWindowIDs: history.windowIDs(for: lifetime))
                .windows.isEmpty
        )
    }

    func testRetiringOneBindingPreservesOtherWindowsAndProcessLaunches() {
        let history = WindowInventoryBindingHistory()
        let capturedAt = Date(timeIntervalSinceReferenceDate: 50)
        for lifetime in ["wechat|start-a|42", "wechat|start-b|42", "work2|start-c|84"] {
            history.recordObservation(
                processIdentifier: lifetime.hasSuffix("84") ? 84 : 42,
                processLifetimeKey: lifetime,
                confirmedExactWindowIDs: [259, 879],
                liveValidatedWindowIDs: [259, 879],
                snapshotCapturedAt: capturedAt,
                snapshotIsComplete: true
            )
        }

        history.forget(windowIDs: [259], processLifetimeKey: "wechat|start-a|42")
        history.forget(windowIDs: [259], processLifetimeKey: "wechat|start-a|42")

        XCTAssertEqual(history.windowIDs(for: "wechat|start-a|42"), [879])
        XCTAssertEqual(history.windowIDs(for: "wechat|start-b|42"), [259, 879])
        XCTAssertEqual(history.windowIDs(for: "work2|start-c|84"), [259, 879])
    }

    func testFreshExactBindingCanReestablishRetiredWindowID() {
        let history = WindowInventoryBindingHistory()
        let lifetime = "wechat|start-a|42"
        let capturedAt = Date(timeIntervalSinceReferenceDate: 60)
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: lifetime,
            confirmedExactWindowIDs: [259],
            liveValidatedWindowIDs: [259],
            snapshotCapturedAt: capturedAt,
            snapshotIsComplete: true
        )
        history.forget(windowIDs: [259], processLifetimeKey: lifetime)
        history.recordObservation(
            processIdentifier: 42,
            processLifetimeKey: lifetime,
            confirmedExactWindowIDs: [259],
            liveValidatedWindowIDs: [259],
            snapshotCapturedAt: capturedAt.addingTimeInterval(1),
            snapshotIsComplete: true
        )

        XCTAssertEqual(history.windowIDs(for: lifetime), [259])
    }

    func testLateDestroyedProxyCannotRetireReplacementWithSameWindowID() {
        struct Proxy: Equatable {
            let reportedWindowID: CGWindowID?
            let identity: Int
        }
        let old = Proxy(reportedWindowID: 259, identity: 1)
        let replacement = Proxy(reportedWindowID: 259, identity: 2)
        let current = [CGWindowID(259): replacement]

        XCTAssertTrue(WindowAXLifecycleRetirementPolicy.matchingWindowIDs(
            for: old,
            currentWindows: current,
            sameElement: { $0.identity == $1.identity }
        ).isEmpty)
        XCTAssertEqual(WindowAXLifecycleRetirementPolicy.matchingWindowIDs(
            for: replacement,
            currentWindows: current,
            sameElement: { $0.identity == $1.identity }
        ), [259])
    }

    func testDestroyedProxyWithoutReadableWindowIDStillMatchesCurrentIdentity() {
        struct Proxy {
            let reportedWindowID: CGWindowID?
            let identity: Int
        }
        let current = [CGWindowID(259): Proxy(reportedWindowID: 259, identity: 1)]
        let destroyed = Proxy(reportedWindowID: nil, identity: 1)

        XCTAssertEqual(WindowAXLifecycleRetirementPolicy.matchingWindowIDs(
            for: destroyed,
            currentWindows: current,
            sameElement: { $0.identity == $1.identity }
        ), [259])
    }

    func testOnlyExplicitInvalidAXElementProvesRetirement() {
        XCTAssertTrue(WindowAXLifecycleRetirementPolicy.shouldRetire(
            roleReadResult: .invalidUIElement
        ))
        for result: AXError in [
            .success, .cannotComplete, .noValue, .attributeUnsupported,
            .apiDisabled, .failure, .notImplemented
        ] {
            XCTAssertFalse(WindowAXLifecycleRetirementPolicy.shouldRetire(
                roleReadResult: result
            ), "Transient or unsupported AX result must preserve the window: \(result)")
        }
    }

    func testRetirementRevisionRejectsOldCaptureAndObserverRecreation() {
        let captureRevision = WindowAXLifecycleRevision()
        let afterRetirement = captureRevision.advanced()
        let recreatedObserver = WindowAXLifecycleRevision(
            generation: captureRevision.generation
        )

        XCTAssertNotEqual(captureRevision, afterRetirement)
        XCTAssertEqual(captureRevision.observationID, afterRetirement.observationID)
        XCTAssertNotEqual(captureRevision, recreatedObserver)
        XCTAssertNotEqual(afterRetirement, afterRetirement.advanced())
    }

    func testRetirementChangeMatchesOnlyExactWindowAndProcessLaunch() {
        let change = WindowAXLifecycleChange(
            processLifetimeKey: "wechat|start-a|42",
            windowIDs: [259],
            revision: WindowAXLifecycleRevision()
        )

        XCTAssertTrue(change.affects(processLifetimeKey: "wechat|start-a|42", windowID: 259))
        XCTAssertFalse(change.affects(processLifetimeKey: "wechat|start-a|42", windowID: 879))
        XCTAssertFalse(change.affects(processLifetimeKey: "wechat|start-b|42", windowID: 259))
        XCTAssertFalse(change.affects(processLifetimeKey: nil, windowID: 259))
        XCTAssertFalse(change.affects(processLifetimeKey: "wechat|start-a|42", windowID: nil))
    }

    func testRetirementChangeInvalidatesOlderSnapshotButPreservesFreshWork() {
        let original = WindowAXLifecycleRevision()
        let change = WindowAXLifecycleChange(
            processLifetimeKey: "wechat|start-a|42",
            windowIDs: [259],
            revision: original.advanced()
        )

        XCTAssertTrue(change.invalidates(original))
        XCTAssertFalse(change.invalidates(change.revision))
        XCTAssertFalse(change.invalidates(change.revision.advanced()))
    }

    func testDelayedRetirementChangeCannotInvalidateNewObserverInstallation() {
        let previousObserver = WindowAXLifecycleRevision(generation: 12)
        let change = WindowAXLifecycleChange(
            processLifetimeKey: "wechat|start-a|42",
            windowIDs: [259],
            revision: previousObserver.advanced()
        )
        let replacementObserver = WindowAXLifecycleRevision(generation: 0)

        XCTAssertFalse(change.invalidates(replacementObserver))
    }

    func testCaptureGenerationRetirementRejectsOnlyTargetProcessLaunch() {
        var tracker = WindowThumbnailCaptureGenerationTracker()
        let main = "wechat|start-a|42"
        let work2 = "work2|start-b|84"
        let mainCapture = tracker.snapshot(for: main)
        let work2Capture = tracker.snapshot(for: work2)

        tracker.invalidate(processLifetimeKey: main)

        XCTAssertFalse(tracker.isCurrent(mainCapture, for: main))
        XCTAssertTrue(tracker.isCurrent(work2Capture, for: work2))
        XCTAssertTrue(tracker.isCurrent(tracker.snapshot(for: main), for: main))
        XCTAssertFalse(tracker.isCurrent(work2Capture, for: main))
    }

    func testRetiredExactWindowCannotReenterThroughFreshPreviewOnlyDiscovery() {
        let history = WindowInventoryBindingHistory()
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        let lifetime = "zcode|start-a|551"
        history.recordObservation(
            processIdentifier: 551,
            processLifetimeKey: lifetime,
            confirmedExactWindowIDs: [131],
            liveValidatedWindowIDs: [131],
            snapshotCapturedAt: Date(timeIntervalSinceReferenceDate: 100),
            snapshotIsComplete: true
        )
        history.forget(windowIDs: [131], processLifetimeKey: lifetime)
        exclusions.retire(windowIDs: [131], processIdentifier: 551, processLifetimeKey: lifetime)

        // The compositor can still return a visually valid image after close.
        // Neither empty ordinary inventory nor fresh pixels revoke retirement.
        let discovered = WindowThumbnailDiscoveredWindow(
            request: WindowThumbnailRequest(title: "App", occurrence: 0, bounds: nil, windowID: 131),
            result: .fresh(NSImage(size: NSSize(width: 1512, height: 864)))
        )
        XCTAssertTrue(history.windowIDs(for: lifetime).isEmpty)
        XCTAssertNotNil(WindowPreviewOnlySelectionPolicy.selectOne(from: [discovered]))
        let admitted = [discovered].filter {
            exclusions.allowsDiscovery(windowID: $0.request.windowID!, processIdentifier: 551, processLifetimeKey: lifetime)
        }
        XCTAssertNil(WindowPreviewOnlySelectionPolicy.selectOne(from: admitted))
    }

    func testDiscoveryRetirementDoesNotBlockUnrelatedNoAXWindowsOrProcessLaunches() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        exclusions.retire(windowIDs: [131], processIdentifier: 551, processLifetimeKey: "zcode|old|551")
        // No absence/off-screen/geometry heuristic is part of this gate.
        // A real no-AX, minimized or fullscreen window without exact retirement
        // evidence retains the existing provider/reconciler admission behavior.
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 132, processIdentifier: 551, processLifetimeKey: "zcode|old|551"))
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 552, processLifetimeKey: "other|start|552"))
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: "zcode|new|551"))
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: nil))
    }

    func testFreshExactReestablishmentClearsOnlyItsOwnDiscoveryExclusion() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        exclusions.retire(windowIDs: [131, 132], processIdentifier: 551, processLifetimeKey: "a")
        exclusions.retire(windowIDs: [131], processIdentifier: 552, processLifetimeKey: "b")
        XCTAssertTrue(exclusions.needsReestablishment(windowID: 131, processIdentifier: 551, processLifetimeKey: "a"))
        XCTAssertFalse(exclusions.needsReestablishment(windowID: 133, processIdentifier: 551, processLifetimeKey: "a"))
        XCTAssertTrue(exclusions.reestablish(windowID: 131, processIdentifier: 551, processLifetimeKey: "a"))
        XCTAssertFalse(exclusions.needsReestablishment(windowID: 131, processIdentifier: 551, processLifetimeKey: "a"))
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: "a"))
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 132, processIdentifier: 551, processLifetimeKey: "a"))
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 552, processLifetimeKey: "b"))
        XCTAssertFalse(exclusions.reestablish(windowID: 131, processIdentifier: 551, processLifetimeKey: "a"))
    }

    func testDiscoveryRetirementCapacityCannotEvictAndReviveOldSurface() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory(maximumWindowIDsPerProcess: 2)
        exclusions.retire(windowIDs: [131, 132], processIdentifier: 551, processLifetimeKey: "a")
        exclusions.retire(windowIDs: [133], processIdentifier: 551, processLifetimeKey: "a")
        XCTAssertLessThanOrEqual(exclusions.trackedWindowCount(processIdentifier: 551), 2)
        XCTAssertFalse(exclusions.needsReestablishment(windowID: 131, processIdentifier: 551, processLifetimeKey: "a"))
        for windowID in [CGWindowID(131), 132, 133, 134] {
            XCTAssertFalse(exclusions.allowsDiscovery(windowID: windowID, processIdentifier: 551, processLifetimeKey: "a"))
        }
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 552, processLifetimeKey: "b"))
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: "new-a"))
    }

    func testVerifiedNewLifetimeReplacesSinglePIDRetirementSlot() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory(maximumWindowIDsPerProcess: 2)
        for index in 0..<100 {
            exclusions.retire(windowIDs: [CGWindowID(index + 1)], processIdentifier: 551, processLifetimeKey: "launch-\(index)")
            XCTAssertEqual(exclusions.trackedProcessCount, 1)
            XCTAssertEqual(exclusions.trackedWindowCount(processIdentifier: 551), 1)
        }
        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 1, processIdentifier: 551, processLifetimeKey: "launch-99"))
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 100, processIdentifier: 551, processLifetimeKey: "launch-99"))
    }

    func testDelayedExitCannotRemoveReplacementLifetimeRetirement() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        exclusions.retire(windowIDs: [131], processIdentifier: 551, processLifetimeKey: "new")
        exclusions.remove(processIdentifier: 551, keepingProcessLifetimeKey: "new")
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: "new"))
        exclusions.remove(processIdentifier: 551, keepingProcessLifetimeKey: nil)
        XCTAssertEqual(exclusions.trackedProcessCount, 0)
    }

    func testNewCaptureEpochAfterRetirementStillCannotDiscoverRetiredWindow() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        var generations = WindowThumbnailCaptureGenerationTracker()
        let lifetime = "zcode|start|551"
        let before = generations.snapshot(for: lifetime)
        exclusions.retire(windowIDs: [131], processIdentifier: 551, processLifetimeKey: lifetime)
        generations.invalidate(processLifetimeKey: lifetime)
        XCTAssertFalse(generations.isCurrent(before, for: lifetime))
        let after = generations.snapshot(for: lifetime)
        XCTAssertTrue(generations.isCurrent(after, for: lifetime))
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: lifetime))

        // Privacy/cache resets and observer recreation cannot erase negative
        // window metadata while the old compositor surface remains alive.
        generations.invalidateAll()
        XCTAssertFalse(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 551, processLifetimeKey: lifetime))
    }

    func testRetiredRenderersCannotSetBestScoreOrConsumeCaptureLimit() {
        struct Candidate {
            let id: CGWindowID
            let score: CGFloat
        }
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        exclusions.retire(windowIDs: [1, 2, 3, 4], processIdentifier: 42, processLifetimeKey: "renderer")
        let candidates = [
            Candidate(id: 1, score: 1),
            Candidate(id: 2, score: 2),
            Candidate(id: 3, score: 3),
            Candidate(id: 4, score: 4),
            Candidate(id: 5, score: 100),
            Candidate(id: 6, score: 108),
            Candidate(id: 7, score: 116)
        ]
        let selected = WindowRendererSelectionPolicy.nearBest(
            from: candidates,
            isAllowed: {
                exclusions.allowsDiscovery(windowID: $0.id, processIdentifier: 42, processLifetimeKey: "renderer")
            },
            score: { $0.score },
            overlap: { _ in 1 },
            windowID: { $0.id }
        )
        XCTAssertEqual(selected.map(\.id), [5, 6])
    }

    func testLiveRendererSelectionPreservesScoreOverlapAndFourCaptureBound() {
        struct Candidate {
            let id: CGWindowID
            let score: CGFloat
            let overlap: CGFloat
        }
        let candidates = [
            Candidate(id: 9, score: 0, overlap: 1),
            Candidate(id: 1, score: 0, overlap: 1),
            Candidate(id: 2, score: 1, overlap: 0.90),
            Candidate(id: 3, score: 2, overlap: 1),
            Candidate(id: 4, score: 3, overlap: 1),
            Candidate(id: 5, score: 4, overlap: 1),
            Candidate(id: 6, score: 20, overlap: 1)
        ]
        let selected = WindowRendererSelectionPolicy.nearBest(
            from: candidates,
            isAllowed: { _ in true },
            score: { $0.score },
            overlap: { $0.overlap },
            windowID: { $0.id }
        )
        XCTAssertEqual(selected.map(\.id), [1, 9, 3, 4])
    }

    func testRendererRetireThenReestablishCannotValidateItsOldPixels() {
        var exclusions = WindowPreviewDiscoveryRetirementHistory()
        var generations = WindowThumbnailCaptureGenerationTracker()
        let target = generations.snapshot(for: "shell")
        let renderer = generations.snapshot(for: "renderer")
        let capturedOwnerTokens = [target, renderer]
        XCTAssertTrue(generations.areCurrent(capturedOwnerTokens))

        exclusions.retire(windowIDs: [131], processIdentifier: 42, processLifetimeKey: "renderer")
        generations.invalidate(processLifetimeKey: "renderer")
        XCTAssertTrue(exclusions.reestablish(windowID: 131, processIdentifier: 42, processLifetimeKey: "renderer"))
        generations.invalidate(processLifetimeKey: "renderer")

        XCTAssertTrue(exclusions.allowsDiscovery(windowID: 131, processIdentifier: 42, processLifetimeKey: "renderer"))
        XCTAssertTrue(generations.isCurrent(target, for: "shell"))
        XCTAssertFalse(generations.areCurrent(capturedOwnerTokens))
        XCTAssertTrue(generations.areCurrent([target, generations.snapshot(for: "renderer")]))
    }

    func testAncestorBridgeRejectsOldCaptureWhenEitherOtherOwnerRetires() {
        for retiredLifetime in ["parent", "ancestor"] {
            var generations = WindowThumbnailCaptureGenerationTracker()
            let target = generations.snapshot(for: "target")
            let ownerTokens = [generations.snapshot(for: "parent"), generations.snapshot(for: "ancestor")]
            XCTAssertTrue(generations.areCurrent(ownerTokens))
            generations.invalidate(processLifetimeKey: retiredLifetime)
            generations.invalidate(processLifetimeKey: retiredLifetime) // valid reestablishment
            XCTAssertTrue(generations.isCurrent(target, for: "target"))
            XCTAssertFalse(generations.areCurrent(ownerTokens))
            XCTAssertTrue(generations.areCurrent([generations.snapshot(for: "parent"), generations.snapshot(for: "ancestor")]))
        }
    }

    func testDelayedCaptureCannotUseTokenRecordedBeforeRetirement() {
        var tracker = WindowThumbnailCaptureGenerationTracker()
        let lifetime = "wechat|start-a|42"
        let queuedJobToken = tracker.snapshot(for: lifetime)

        tracker.invalidate(processLifetimeKey: lifetime)
        let tokenWhenDetachedWorkEventuallyStarts = tracker.snapshot(for: lifetime)

        XCTAssertNotEqual(queuedJobToken, tokenWhenDetachedWorkEventuallyStarts)
        XCTAssertFalse(tracker.isCurrent(queuedJobToken, for: lifetime))
        XCTAssertTrue(tracker.isCurrent(tokenWhenDetachedWorkEventuallyStarts, for: lifetime))
    }

    func testGlobalCaptureGenerationResetInvalidatesEveryProcessLaunch() {
        var tracker = WindowThumbnailCaptureGenerationTracker()
        let main = "wechat|start-a|42"
        let work2 = "work2|start-b|84"
        tracker.invalidate(processLifetimeKey: main)
        let mainCapture = tracker.snapshot(for: main)
        let work2Capture = tracker.snapshot(for: work2)

        tracker.invalidateAll()

        XCTAssertEqual(tracker.trackedProcessCount, 0)
        XCTAssertFalse(tracker.isCurrent(mainCapture, for: main))
        XCTAssertFalse(tracker.isCurrent(work2Capture, for: work2))
        XCTAssertTrue(tracker.isCurrent(tracker.snapshot(for: main), for: main))
        XCTAssertTrue(tracker.isCurrent(tracker.snapshot(for: work2), for: work2))
    }

    func testCaptureGenerationCapacityRecyclingCannotAliasOldZeroEpoch() {
        var tracker = WindowThumbnailCaptureGenerationTracker(maximumProcessEntries: 2)
        let originalZeroEpoch = tracker.snapshot(for: "a")
        tracker.invalidate(processLifetimeKey: "a")
        let invalidatedEpoch = tracker.snapshot(for: "a")
        tracker.invalidate(processLifetimeKey: "b")
        XCTAssertEqual(tracker.trackedProcessCount, 2)

        tracker.invalidate(processLifetimeKey: "c")
        let recycledZeroEpoch = tracker.snapshot(for: "a")

        XCTAssertEqual(tracker.trackedProcessCount, 1)
        XCTAssertEqual(originalZeroEpoch.processEpoch, recycledZeroEpoch.processEpoch)
        XCTAssertNotEqual(originalZeroEpoch.globalEpoch, recycledZeroEpoch.globalEpoch)
        XCTAssertFalse(tracker.isCurrent(originalZeroEpoch, for: "a"))
        XCTAssertFalse(tracker.isCurrent(invalidatedEpoch, for: "a"))
        XCTAssertTrue(tracker.isCurrent(recycledZeroEpoch, for: "a"))

        for index in 0..<10 {
            tracker.invalidate(processLifetimeKey: "process-\(index)")
            XCTAssertLessThanOrEqual(tracker.trackedProcessCount, 2)
            XCTAssertFalse(tracker.isCurrent(originalZeroEpoch, for: "a"))
        }
    }

    func testSharedAXPreDeduplicatorUsesOnlyOwnerAndExactIdentity() {
        struct Proxy: Equatable {
            let ownerPID: pid_t
            let windowID: CGWindowID?
            let objectID: Int
        }
        let proxies = [
            Proxy(ownerPID: 42, windowID: 10, objectID: 1),
            Proxy(ownerPID: 42, windowID: 10, objectID: 2),
            Proxy(ownerPID: 42, windowID: 11, objectID: 1),
            Proxy(ownerPID: 84, windowID: 10, objectID: 1),
            Proxy(ownerPID: 42, windowID: nil, objectID: 3),
            Proxy(ownerPID: 42, windowID: nil, objectID: 3)
        ]

        let result = WindowAXProxyPreDeduplicator.deduplicate(
            proxies,
            ownerPID: \.ownerPID,
            windowID: \.windowID,
            sameAXObject: { $0.objectID == $1.objectID },
            merge: { _, candidate, canonicalWindowID in
                Proxy(
                    ownerPID: candidate.ownerPID,
                    windowID: canonicalWindowID,
                    objectID: candidate.objectID
                )
            }
        )

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(
            Set(result.compactMap { proxy -> String? in
                guard let windowID = proxy.windowID else { return nil }
                return "\(proxy.ownerPID):\(windowID)"
            }),
            Set(["42:10", "42:11", "84:10"])
        )
        XCTAssertEqual(result.filter { $0.windowID == nil }.count, 1)
    }

    func testInventoryCacheDeadlineUsesBothRawAndProjectedAge() {
        let rawCapturedAt = Date(timeIntervalSinceReferenceDate: 100)
        let storedAt = rawCapturedAt.addingTimeInterval(0.20)
        let expiresAt = WindowInventoryCachePolicy.expiration(
            storedAt: storedAt,
            rawCapturedAt: rawCapturedAt
        )

        XCTAssertEqual(expiresAt, rawCapturedAt.addingTimeInterval(0.30))
        XCTAssertTrue(WindowInventoryCachePolicy.isFresh(
            now: expiresAt.addingTimeInterval(-0.001),
            expiresAt: expiresAt
        ))
        XCTAssertFalse(WindowInventoryCachePolicy.isFresh(
            now: expiresAt,
            expiresAt: expiresAt
        ))
        XCTAssertFalse(WindowInventoryCachePolicy.isFresh(
            now: expiresAt.addingTimeInterval(0.001),
            expiresAt: expiresAt
        ))
    }

    func testThreeExplicitAXWindowsResolveToThreeCanonicalWindows() {
        let result = resolve(
            [
                candidate(token: 0, id: 10),
                candidate(token: 1, id: 11),
                candidate(token: 2, id: 12)
            ],
            [
                surface(id: 10),
                surface(id: 11, onScreen: true, spaceIDs: []),
                surface(id: 12)
            ]
        )

        XCTAssertEqual(result.windows.count, 3)
        XCTAssertEqual(Set(result.windows.map(\.surface.windowID)), Set<CGWindowID>([10, 11, 12]))
        XCTAssertEqual(Set(result.windows.map(\.operationToken)), Set([0, 1, 2]))
    }

    func testAXHelperWithoutCanonicalSurfaceDoesNotManufactureWindow() {
        let result = resolve(
            [candidate(token: 99, id: 999, title: "AX Helper")],
            [surface(id: 10, title: "Real Window")]
        )

        XCTAssertTrue(result.windows.isEmpty)
    }

    func testSameOwnerSameTitleAndGeometryKeepsDistinctCanonicalWindowIDs() {
        let result = resolve(
            [
                candidate(token: 0, id: 10, pid: 42, title: "Document", bounds: rect()),
                candidate(token: 1, id: 11, pid: 42, title: "Document", bounds: rect())
            ],
            [
                surface(id: 10, pid: 42, title: "Document", bounds: rect()),
                surface(id: 11, pid: 42, title: "Document", bounds: rect())
            ]
        )

        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(Set(result.windows.map(\.surface.windowID)), Set<CGWindowID>([10, 11]))
    }

    func testUnnumberedProxyIsAmbiguousWhenItMatchesClaimedAndUnclaimedSurfacesEqually() {
        let result = reconcile(
            [
                candidate(token: 0, id: 10, title: "Document", bounds: rect()),
                candidate(token: 1, id: nil, title: "Document", bounds: rect())
            ],
            [
                surface(id: 10, title: "Document", bounds: rect()),
                surface(id: 11, title: "Document", bounds: rect())
            ]
        )

        XCTAssertEqual(result.matches.map(\.windowID), [10])
        XCTAssertEqual(result.rejections, [.init(token: 1, reason: .ambiguousSurface)])
    }

    func testMultipleAXProxiesForOneCanonicalWindowProduceOneResolvedWindow() {
        let result = resolve(
            [
                candidate(token: 0, id: 10, preferred: false),
                candidate(token: 1, id: 10, preferred: true)
            ],
            [surface(id: 10)]
        )

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.surface.windowID, 10)
        XCTAssertEqual(result.windows.first?.operationToken, 1)
    }

    func testCanonicalResolutionKeepsOwnersIsolatedByPID() {
        let result = resolve(
            [
                candidate(token: 0, id: nil, pid: 42, title: "Document", bounds: rect()),
                candidate(token: 1, id: nil, pid: 84, title: "Document", bounds: rect())
            ],
            [
                surface(id: 10, pid: 42, title: "Document", bounds: rect()),
                surface(id: 20, pid: 84, title: "Document", bounds: rect())
            ]
        )

        XCTAssertEqual(result.windows.count, 2)
        let firstOwner = result.windows.first { $0.surface.ownerPID == 42 }
        let secondOwner = result.windows.first { $0.surface.ownerPID == 84 }
        XCTAssertEqual(firstOwner?.surface.windowID, 10)
        XCTAssertEqual(firstOwner?.operationToken, 0)
        XCTAssertEqual(secondOwner?.surface.windowID, 20)
        XCTAssertEqual(secondOwner?.operationToken, 1)
    }

    func testPublicFallbackResolutionOnlyAdmitsOnscreenExactIdentity() {
        let result = resolve(
            [
                candidate(token: 0, id: 10),
                candidate(token: 1, id: 11),
                candidate(token: 2, id: nil, title: "Fuzzy", bounds: rect())
            ],
            [
                surface(id: 10, source: .publicWindowList),
                surface(
                    id: 11,
                    onScreen: false,
                    source: .publicWindowList,
                    spaceIDs: []
                ),
                surface(id: 12, title: "Fuzzy", source: .publicWindowList)
            ],
            mode: .publicFallback
        )

        XCTAssertEqual(result.windows.map(\.surface.windowID), [10])
        XCTAssertEqual(result.windows.first?.operationToken, 0)
    }

    func testExactTransparentNonMinimizedSurfaceIsRejected() {
        let result = reconcile([candidate(id: 10)], [surface(id: 10, alpha: 0)])
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    func testExactTinyNonMinimizedSurfaceIsRejected() {
        let tiny = CGRect(x: 100, y: 100, width: 20, height: 20)
        let result = reconcile(
            [candidate(id: 10, bounds: tiny)],
            [surface(id: 10, bounds: tiny)]
        )
        XCTAssertEqual(result.rejections.first?.reason, .exactWindowMissing)
    }

    private func assertSingleExact(
        candidate: WindowInventoryCandidate,
        surface: WindowServerSurface,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = reconcile([candidate], [surface])
        XCTAssertEqual(result.matches.count, 1, file: file, line: line)
        XCTAssertEqual(result.matches.first?.windowID, surface.windowID, file: file, line: line)
        XCTAssertTrue(result.rejections.isEmpty, file: file, line: line)
    }

    private func reconcile(
        _ candidates: [WindowInventoryCandidate],
        _ surfaces: [WindowServerSurface]
    ) -> WindowInventoryReconciliation {
        WindowInventoryReconciler.reconcile(
            candidates: candidates,
            snapshot: snapshot(surfaces)
        )
    }

    private func resolve(
        _ candidates: [WindowInventoryCandidate],
        _ surfaces: [WindowServerSurface],
        mode: WindowServerInventoryMode = .skyLight,
        retainedWindowIDs: Set<CGWindowID> = []
    ) -> WindowInventoryResolution {
        WindowInventoryReconciler.resolve(
            candidates: candidates,
            snapshot: snapshot(surfaces, mode: mode),
            retainedWindowIDs: retainedWindowIDs
        )
    }

    private func snapshot(
        _ surfaces: [WindowServerSurface],
        mode: WindowServerInventoryMode = .skyLight
    ) -> WindowServerInventorySnapshot {
        WindowServerInventorySnapshot(
            capturedAt: Date(),
            mode: mode,
            surfaces: surfaces
        )
    }

    private func rect() -> CGRect {
        CGRect(x: 100, y: 100, width: 500, height: 400)
    }

    private func candidate(
        token: Int = 0,
        id: CGWindowID? = nil,
        pid: pid_t = 42,
        title: String = "Document",
        bounds: CGRect? = CGRect(x: 100, y: 100, width: 500, height: 400),
        minimized: Bool = false,
        preferred: Bool = false
    ) -> WindowInventoryCandidate {
        WindowInventoryCandidate(
            token: token,
            ownerPID: pid,
            windowID: id,
            title: title,
            bounds: bounds,
            isMinimized: minimized,
            isPreferredWindow: preferred
        )
    }

    private func surface(
        id: CGWindowID,
        pid: pid_t = 42,
        title: String = "Document",
        bounds: CGRect = CGRect(x: 100, y: 100, width: 500, height: 400),
        layer: Int = 0,
        onScreen: Bool = true,
        alpha: Double = 1,
        source: WindowServerSurface.Source = .skyLight,
        spaceIDs: Set<UInt64> = [1],
        ownerValidated: Bool? = nil,
        levelValidated: Bool? = nil
    ) -> WindowServerSurface {
        WindowServerSurface(
            windowID: id,
            ownerPID: pid,
            bounds: bounds,
            layer: layer,
            title: title,
            isOnScreen: onScreen,
            alpha: alpha,
            spaceIDs: spaceIDs,
            source: source,
            ownerWasPrivatelyValidated: ownerValidated ?? (source == .skyLight),
            levelWasPrivatelyValidated: levelValidated ?? (source == .skyLight)
        )
    }
}
