import XCTest
@testable import SuperIsland

final class WindowCommandTabRecoveryPolicyTests: XCTestCase {
    private struct Window: Equatable {
        let owner: Int32
        let id: UInt32
        let actionable: Bool
        var revision: Int = 0
    }

    private func recover(_ current: [Window], _ refreshed: [Window], owners: Set<Int32>) -> [Window]? {
        WindowCommandTabRecoveryPolicy.restoringMissingWindows(
            current: current, refreshed: refreshed, requestedOwners: owners,
            owner: \.owner, windowID: { $0.id }, hasOperation: \.actionable
        )
    }

    func testColdOrdinaryApplicationDoesNotFinishRecoveryAtScreenshotOnlyWindow() {
        let pixelsOnly = Window(owner: 564, id: 419, actionable: false)
        XCTAssertNil(recover([], [pixelsOnly], owners: [564]))
        XCTAssertNil(recover([pixelsOnly], [pixelsOnly], owners: [564]))
        let restored = Window(owner: 564, id: 419, actionable: true)
        XCTAssertEqual(recover([pixelsOnly], [restored], owners: [564]), [restored])
    }

    func testPartialOwnerRecoveryKeepsOtherCardsAndRejectsUnrequestedOwner() {
        let active = Window(owner: 10, id: 100, actionable: true)
        let missing = Window(owner: 20, id: 200, actionable: false)
        let restored = Window(owner: 20, id: 200, actionable: true)
        let foreign = Window(owner: 30, id: 300, actionable: true)
        XCTAssertNil(recover([active, missing], [foreign], owners: [20]))
        XCTAssertEqual(recover([active, missing], [restored, foreign], owners: [20]), [active, restored])
    }

    func testRecoveredOwnerDoesNotGrantActionsToItsOtherUnboundWindow() {
        let restored = Window(owner: 20, id: 200, actionable: true)
        let stillUnbound = Window(owner: 20, id: 201, actionable: false)
        let result = recover([], [restored, stillUnbound], owners: [20])
        XCTAssertEqual(result, [restored, stillUnbound])
        XCTAssertEqual(result?.filter(\.actionable).map(\.id), [200])
    }
    private func missingOwners(_ windows: [Window], owners: Set<Int32> = [10]) -> Set<Int32> {
        WindowCommandTabRecoveryPolicy.ownersNeedingRecovery(
            windows: windows, owners: owners, owner: \.owner, hasOperation: \.actionable
        )
    }

    func testThreeWindowRecoveryContinuesAfterPartialProgressWithoutReplacingHealthySibling() throws {
        let a = Window(owner: 10, id: 100, actionable: true)
        let b = Window(owner: 10, id: 200, actionable: false)
        let c = Window(owner: 10, id: 300, actionable: false)
        let rereadA = Window(owner: 10, id: 100, actionable: true, revision: 1)
        let restoredB = Window(owner: 10, id: 200, actionable: true, revision: 1)
        let restoredC = Window(owner: 10, id: 300, actionable: true, revision: 2)
        var current = [a, b, c]
        XCTAssertEqual(missingOwners(current), [10])
        XCTAssertNil(recover(current, [rereadA], owners: missingOwners(current)), "A was already actionable")
        current = try XCTUnwrap(recover(current, [rereadA, restoredB], owners: missingOwners(current)))
        XCTAssertEqual(current, [a, restoredB, c], "An incomplete read cannot delete C or replace A")
        XCTAssertEqual(missingOwners(current), [10])
        current = try XCTUnwrap(recover(current, [restoredC], owners: missingOwners(current)))
        XCTAssertEqual(current, [a, restoredB, restoredC])
        XCTAssertTrue(missingOwners(current).isEmpty)
        XCTAssertEqual(WindowCommandTabRecoveryPolicy.delays.count, 3)
    }

    func testUnavailableSiblingStaysUnboundAfterFiniteAttemptsAndHealthyWindowDoesNotRegress() {
        let a = Window(owner: 10, id: 100, actionable: true)
        let b = Window(owner: 10, id: 200, actionable: false)
        let downgradedA = Window(owner: 10, id: 100, actionable: false)
        let anotherWindow = Window(owner: 10, id: 999, actionable: true)
        let current = [a, b]
        for _ in WindowCommandTabRecoveryPolicy.delays {
            XCTAssertNil(recover(current, [downgradedA, b, anotherWindow], owners: missingOwners(current)))
        }
        XCTAssertEqual(current, [a, b])
        XCTAssertEqual(missingOwners(current), [10])
    }

    func testPartialRecoveryDoesNotMatchSameWindowNumberFromAnotherOwnerOrAnUnknownID() {
        let a = Window(owner: 10, id: 100, actionable: true)
        let b = Window(owner: 10, id: 200, actionable: false)
        let foreign = Window(owner: 20, id: 200, actionable: true)
        XCTAssertNil(recover([a, b], [foreign], owners: [10]))
        let unknown = Window(owner: 10, id: 0, actionable: false)
        XCTAssertNil(recover([unknown], [Window(owner: 10, id: 0, actionable: true)], owners: [10]))
    }

    func testAmbiguousDuplicateRecoveredTargetDoesNotUpgradeOrReorderCurrentCards() {
        let a = Window(owner: 10, id: 100, actionable: true)
        let b = Window(owner: 10, id: 200, actionable: false)
        let recovered = Window(owner: 10, id: 200, actionable: true)
        XCTAssertNil(recover([a, b], [recovered, recovered], owners: [10]))
    }

    func testDiscoveringEmptyOwnerPreservesOtherOwnerAndContinuesItsUnboundSibling() throws {
        let healthy = Window(owner: 10, id: 100, actionable: true)
        let found = Window(owner: 20, id: 200, actionable: true)
        let unresolved = Window(owner: 20, id: 201, actionable: false)
        XCTAssertEqual(missingOwners([healthy], owners: [10, 20]), [20])
        let current = try XCTUnwrap(recover([healthy], [found, unresolved], owners: [20]))
        XCTAssertEqual(current, [healthy, found, unresolved])
        XCTAssertEqual(missingOwners(current, owners: [10, 20]), [20])
    }

}

final class WindowCommandTabSharingPolicyTests: XCTestCase {
    private typealias Policy = WindowCommandTabSharingPolicy
    private typealias Application = Policy.Application
    private let primary = Application(processID: 10, bundlePath: "/Applications/WeChat.app", bundleIdentifier: "com.tencent.xinWeChat")
    private let secondary = Application(processID: 20, bundlePath: "/Applications/WeChat-Work2.app", bundleIdentifier: "com.tencent.xinWeChat.work2")
    private var weakEvidence: Policy.SelectionEvidence {
        .weakSelectedButton(title: "微信", isLeaf: true, searchComplete: true, hasStrongIdentity: false)
    }

    func testEitherStrongKnownInstallationSharesTheSameTwoOwners() throws {
        for selected in [primary, secondary] {
            let group = try XCTUnwrap(Policy.sharedWeChatGroup(
                selected: [selected], running: [secondary, primary], evidence: .resolvedIdentity
            ))
            XCTAssertEqual(group.processIDs, [10, 20])
            XCTAssertEqual(group.label(for: 10), "主微信")
            XCTAssertEqual(group.label(for: 20), "双开微信")
            XCTAssertNil(group.label(for: 30))
        }
    }

    func testWeakSelectedWeChatLeafCanShareWithoutClaimingItsOwner() throws {
        for title in ["微信", "WeChat"] {
            let group = try XCTUnwrap(Policy.sharedWeChatGroup(
                selected: [secondary, primary], running: [primary, secondary],
                evidence: .weakSelectedButton(title: title, isLeaf: true, searchComplete: true, hasStrongIdentity: false)
            ))
            XCTAssertEqual(group.members.map(\.application), [primary, secondary])
        }
    }

    func testWeakEvidenceRejectsAncestorIncompleteOrStrongIdentity() {
        let evidence: [Policy.SelectionEvidence] = [
            .weakSelectedButton(title: "微信", isLeaf: false, searchComplete: true, hasStrongIdentity: false),
            .weakSelectedButton(title: "微信", isLeaf: true, searchComplete: false, hasStrongIdentity: false),
            .weakSelectedButton(title: "微信", isLeaf: true, searchComplete: true, hasStrongIdentity: true),
            .weakSelectedButton(title: "微信 (窗口)", isLeaf: true, searchComplete: true, hasStrongIdentity: false),
            .weakSelectedButton(title: "Google Chrome", isLeaf: true, searchComplete: true, hasStrongIdentity: false),
            .unresolvedOrConflicting
        ]
        for value in evidence {
            XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary, secondary], running: [primary, secondary], evidence: value))
        }
    }

    func testWeakCandidatesMustBeCompleteAndIncludeNoUnknownSameNameApplication() {
        let unknown = Application(processID: 30, bundlePath: "/Applications/Other.app", bundleIdentifier: "example.other")
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary], running: [primary, secondary], evidence: weakEvidence))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary, secondary, unknown], running: [primary, secondary, unknown], evidence: weakEvidence))
    }

    func testStrongConflictCannotBecomeSharedIdentity() {
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary, secondary], running: [primary, secondary], evidence: .resolvedIdentity))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary], running: [primary, secondary], evidence: .unresolvedOrConflicting))
    }

    func testOnlyExactPathAndMatchingBundleIDQualify() {
        let invalid: [Application] = [
            Application(processID: 30, bundlePath: "/Applications/WeChat-copy.app", bundleIdentifier: "com.tencent.xinWeChat"),
            Application(processID: 30, bundlePath: "/Applications/WeChat.app.backup", bundleIdentifier: "com.tencent.xinWeChat"),
            Application(processID: 30, bundlePath: "/Applications/WeChat.app", bundleIdentifier: "com.tencent.xinWeChat.work2"),
            Application(processID: 30, bundlePath: "/Applications/WeChat-Work2.app", bundleIdentifier: "com.tencent.xinWeChat"),
            Application(processID: 30, bundlePath: nil, bundleIdentifier: "com.tencent.xinWeChat"),
            Application(processID: 30, bundlePath: "/Applications/WeChat.app", bundleIdentifier: nil),
            Application(processID: 0, bundlePath: "/Applications/WeChat.app", bundleIdentifier: "com.tencent.xinWeChat")
        ]
        for application in invalid {
            XCTAssertNil(Policy.installation(for: application))
            XCTAssertNil(Policy.sharedWeChatGroup(selected: [application], running: [primary, secondary, application], evidence: .resolvedIdentity))
        }
    }

    func testNestedAppExIsNeverPromotedToAnInstallationOrGivenAnotherOwner() throws {
        let helper = Application(processID: 30, bundlePath: "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        XCTAssertNil(Policy.installation(for: helper))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [helper], running: [primary, secondary, helper], evidence: .resolvedIdentity))
        let group = try XCTUnwrap(Policy.sharedWeChatGroup(selected: [primary], running: [primary, secondary, helper], evidence: .resolvedIdentity))
        XCTAssertEqual(group.processIDs, [10, 20])
        XCTAssertNil(group.label(for: helper.processID))
        XCTAssertEqual(Policy.commitPolicy(for: .closeWindow, group: group, explicitlySelectedOwner: helper), .unavailable)
    }

    func testBothKnownInstallationsMustBeRunningAndSelectedSnapshotMustMatch() {
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary], running: [primary], evidence: .resolvedIdentity))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [], running: [primary, secondary], evidence: .resolvedIdentity))
        let stale = Application(processID: 11, bundlePath: primary.bundlePath, bundleIdentifier: primary.bundleIdentifier)
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [stale], running: [primary, secondary], evidence: .resolvedIdentity))
    }

    func testKnownAppExWeakMatchesKeepOnlyRootWindowOwners() throws {
        let helpers = [
            Application(processID: 30, bundlePath: primary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx"),
            Application(processID: 40, bundlePath: secondary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        ]
        for extras in [[helpers[0]], [helpers[1]], helpers, helpers + [helpers[1]]] {
            let group = try XCTUnwrap(Policy.sharedWeChatGroup(
                selected: extras + [secondary, primary], running: [primary, secondary] + extras, evidence: weakEvidence
            ))
            XCTAssertEqual(group.members.map(\.application), [primary, secondary])
            for helper in extras {
                XCTAssertNil(Policy.installation(for: helper))
                XCTAssertNil(group.label(for: helper.processID))
                for action: Policy.RequestedAction in [.commandRelease, .closeWindow, .quitApplication] {
                    XCTAssertEqual(Policy.commitPolicy(for: action, group: group, explicitlySelectedOwner: helper), .unavailable)
                }
            }
            XCTAssertEqual(Policy.commitPolicy(for: .commandRelease, group: group, explicitlySelectedOwner: nil), .nativeOnly)
            XCTAssertEqual(Policy.commitPolicy(for: .closeWindow, group: group, explicitlySelectedOwner: secondary), .exactWindowOwner(processID: 20))
        }
    }

    func testKnownAppExCannotReplaceAMissingOrUnselectedRoot() {
        let helper = Application(processID: 30, bundlePath: secondary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary, helper], running: [primary, helper], evidence: weakEvidence))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary, helper], running: [primary, secondary, helper], evidence: weakEvidence))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [helper], running: [primary, secondary, helper], evidence: weakEvidence))
    }

    func testAppExWeakMatchRequiresExactPathAndBundleID() {
        let path = secondary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app"
        let invalid = [
            Application(processID: 30, bundlePath: path + ".backup", bundleIdentifier: "com.tencent.flue.WeChatAppEx"),
            Application(processID: 30, bundlePath: "/Applications/WeChat-copy.app/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx"),
            Application(processID: 30, bundlePath: secondary.bundlePath! + "/Contents/Helpers/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx"),
            Application(processID: 30, bundlePath: path, bundleIdentifier: "com.tencent.flue.WeChatAppEx.other"),
            Application(processID: 30, bundlePath: path, bundleIdentifier: nil),
            Application(processID: 30, bundlePath: nil, bundleIdentifier: "com.tencent.flue.WeChatAppEx"),
            Application(processID: 0, bundlePath: path, bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        ]
        for helper in invalid {
            let apps = [primary, secondary, helper]
            XCTAssertNil(Policy.sharedWeChatGroup(selected: apps, running: apps, evidence: weakEvidence))
        }
    }

    func testKnownAppExDoesNotHideAnotherUnknownCandidate() {
        let helper = Application(processID: 30, bundlePath: secondary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        let unknown = Application(processID: 40, bundlePath: "/Applications/Other.app", bundleIdentifier: "example.other")
        let apps = [primary, secondary, helper, unknown]
        XCTAssertNil(Policy.sharedWeChatGroup(selected: apps, running: apps, evidence: weakEvidence))
    }

    func testAppExCandidateMustMatchTheLiveProcessSnapshot() {
        let helper = Application(processID: 30, bundlePath: secondary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        let reused = Application(processID: 30, bundlePath: primary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        let selected = [primary, secondary, helper]
        for running in [[primary, secondary], [primary, secondary, reused], [primary, secondary, helper, reused]] {
            XCTAssertNil(Policy.sharedWeChatGroup(selected: selected, running: running, evidence: weakEvidence))
        }
        XCTAssertNil(Policy.sharedWeChatGroup(selected: selected + [reused], running: selected, evidence: weakEvidence))
    }

    func testAppExCannotExpandStrongIdentityIntoSharedRoots() {
        let helper = Application(processID: 30, bundlePath: secondary.bundlePath! + "/Contents/MacOS/WeChatAppEx.app", bundleIdentifier: "com.tencent.flue.WeChatAppEx")
        for selected in [[helper], [primary, helper], [secondary, helper], [primary, secondary, helper]] {
            XCTAssertNil(Policy.sharedWeChatGroup(selected: selected, running: [primary, secondary, helper], evidence: .resolvedIdentity))
        }
    }

    func testRepeatedIdenticalEntriesDeduplicateButConflictingPIDMetadataRejects() throws {
        let group = try XCTUnwrap(Policy.sharedWeChatGroup(selected: [primary, primary], running: [secondary, primary, primary], evidence: .resolvedIdentity))
        XCTAssertEqual(group.processIDs, [10, 20])
        let reused = Application(processID: 10, bundlePath: secondary.bundlePath, bundleIdentifier: secondary.bundleIdentifier)
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary], running: [primary, reused, secondary], evidence: .resolvedIdentity))
        XCTAssertNil(Policy.sharedWeChatGroup(selected: [primary, reused], running: [primary, secondary], evidence: .resolvedIdentity))
    }

    func testAdditionalProcessAtSameInstallationRetainsItsOwnPIDAndLabel() throws {
        let secondPrimary = Application(processID: 11, bundlePath: primary.bundlePath, bundleIdentifier: primary.bundleIdentifier)
        let group = try XCTUnwrap(Policy.sharedWeChatGroup(selected: [primary, secondPrimary], running: [secondary, secondPrimary, primary], evidence: .resolvedIdentity))
        XCTAssertEqual(group.processIDs, [10, 11, 20])
        XCTAssertEqual(group.label(for: 11), "主微信")
    }

    func testNoExplicitWindowLeavesNativeCommitAndNeverClosesOrQuitsFirstMember() throws {
        let group = try XCTUnwrap(Policy.sharedWeChatGroup(selected: [primary], running: [primary, secondary], evidence: .resolvedIdentity))
        XCTAssertEqual(Policy.commitPolicy(for: .commandRelease, group: group, explicitlySelectedOwner: nil), .nativeOnly)
        XCTAssertEqual(Policy.commitPolicy(for: .closeWindow, group: group, explicitlySelectedOwner: nil), .unavailable)
        XCTAssertEqual(Policy.commitPolicy(for: .quitApplication, group: group, explicitlySelectedOwner: nil), .unavailable)
    }

    func testExplicitSelectionKeepsTheCrossInstallationWindowOwner() throws {
        let group = try XCTUnwrap(Policy.sharedWeChatGroup(selected: [primary], running: [primary, secondary], evidence: .resolvedIdentity))
        for action: Policy.RequestedAction in [.commandRelease, .closeWindow, .quitApplication] {
            XCTAssertEqual(Policy.commitPolicy(for: action, group: group, explicitlySelectedOwner: secondary), .exactWindowOwner(processID: 20))
        }
        let changedOwner = Application(processID: 20, bundlePath: primary.bundlePath, bundleIdentifier: primary.bundleIdentifier)
        XCTAssertEqual(Policy.commitPolicy(for: .commandRelease, group: group, explicitlySelectedOwner: changedOwner), .unavailable)
    }
}
