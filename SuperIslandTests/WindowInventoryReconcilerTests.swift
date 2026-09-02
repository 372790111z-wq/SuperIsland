import AppKit
import CoreGraphics
import XCTest
@testable import SuperIsland

final class WindowInventoryReconcilerTests: XCTestCase {
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

    func testUntitledPreferredProxyMergesWithSameRealWindow() {
        XCTAssertTrue(WindowAXCandidatePolicy.areExactProxies(
            lhsPID: 100,
            lhsTitle: "Document",
            lhsBounds: CGRect(x: 40, y: 60, width: 900, height: 700),
            lhsIsMinimized: false,
            lhsIsPreferredWindow: false,
            rhsPID: 100,
            rhsTitle: "",
            rhsBounds: CGRect(x: 40.5, y: 59.5, width: 900, height: 700),
            rhsIsMinimized: false,
            rhsIsPreferredWindow: true
        ))
    }

    func testUntitledBackgroundWindowsAtSameGeometryRemainDistinct() {
        XCTAssertFalse(WindowAXCandidatePolicy.areExactProxies(
            lhsPID: 100,
            lhsTitle: "",
            lhsBounds: CGRect(x: 40, y: 60, width: 900, height: 700),
            lhsIsMinimized: false,
            lhsIsPreferredWindow: false,
            rhsPID: 100,
            rhsTitle: "",
            rhsBounds: CGRect(x: 40, y: 60, width: 900, height: 700),
            rhsIsMinimized: false,
            rhsIsPreferredWindow: false
        ))
    }

    func testDifferentTitledWindowsAtSameGeometryRemainDistinct() {
        XCTAssertFalse(WindowAXCandidatePolicy.areExactProxies(
            lhsPID: 100,
            lhsTitle: "A",
            lhsBounds: CGRect(x: 40, y: 60, width: 900, height: 700),
            lhsIsMinimized: false,
            lhsIsPreferredWindow: true,
            rhsPID: 100,
            rhsTitle: "B",
            rhsBounds: CGRect(x: 40, y: 60, width: 900, height: 700),
            rhsIsMinimized: false,
            rhsIsPreferredWindow: false
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
        XCTAssertEqual(result.rejections.last?.reason, .noUniqueSurface)
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

    func testDifferentTitleCanMatchExactGeometry() {
        let result = reconcile(
            [candidate(id: nil, title: "AX Title")],
            [surface(id: 10, title: "WindowServer Title")]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
    }

    func testExactMinimizedIdentityDoesNotRequireWindowToBeOnScreenOrInASpace() {
        let result = reconcile(
            [candidate(id: 10, minimized: true)],
            [surface(id: 10, onScreen: false, spaceIDs: [])]
        )
        XCTAssertEqual(result.matches.first?.windowID, 10)
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

    func testExactOnscreenPrivateSurfaceWithoutSpaceMembershipIsRejected() {
        let result = reconcile(
            [candidate(id: 10)],
            [surface(id: 10, onScreen: true, spaceIDs: [])]
        )
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
        spaceIDs: Set<UInt64> = [1]
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
            ownerWasPrivatelyValidated: source == .skyLight
        )
    }
}
