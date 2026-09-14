import XCTest
@testable import SuperIsland

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
