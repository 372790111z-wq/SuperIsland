import XCTest
@testable import SuperIsland

final class UpdateReleasePolicyTests: XCTestCase {
    private var policy: UpdateReleasePolicy {
        .init(bundleIdentifier: UpdateReleasePolicy.we1BundleID, currentVersion: "1.0.9", currentBuild: "20260920160408", architecture: "arm64")
    }

    func testEmptyRepositoryDoesNotClaimLatestOrOfferOriginalApp() throws {
        XCTAssertEqual(try policy.selectRelease(from: Data("[]".utf8)), .noCompatibleRelease)
        let original: [String: Any] = [
            "tag_name": "v99.0.0", "html_url": "https://github.com/372790111z-wq/SuperIsland/releases/tag/v99.0.0",
            "assets": [["name": "SuperIsland.dmg", "browser_download_url": "https://github.com/372790111z-wq/SuperIsland/releases/download/v99.0.0/SuperIsland.dmg"]]
        ]
        XCTAssertEqual(try select([original]), .noCompatibleRelease)
    }

    func testOffersNewestCompatibleBuildRegardlessOfReleaseOrdering() throws {
        let older = release(build: "20260921120000")
        let newer = release(build: "20260922120000")
        let draft = release(build: "20260923120000", draft: true)
        let wrongArchitecture = release(build: "20260924120000", architecture: "x86_64")
        guard case .available(let offer) = try select([older, newer, draft, wrongArchitecture]) else {
            return XCTFail("Expected newest compatible non-draft release")
        }
        XCTAssertEqual(offer.build, "20260922120000")
        XCTAssertEqual(offer.downloadURL?.lastPathComponent, "SuperIsland-WE1-20260922120000-arm64.dmg")
    }

    func testCurrentAndOlderCompatibleReleasesAreUpToDate() throws {
        XCTAssertEqual(try select([release(build: "20260920160408")]), .upToDate)
        XCTAssertEqual(try select([release(build: "20260919160408")]), .upToDate)
    }

    func testWrongRepositoryOrSpoofedHostAndNonWE1AssetAreRejected() throws {
        var foreign = release(build: "20260921120000")
        foreign["html_url"] = "https://github.com/other/SuperIsland/releases/tag/we1-20260921120000"
        var malicious = release(build: "20260921120000")
        malicious["assets"] = [["name": "SuperIsland-WE1-20260921120000-arm64.dmg", "browser_download_url": "https://github.com.evil.test/372790111z-wq/SuperIsland/releases/download/we1-20260921120000/SuperIsland-WE1-20260921120000-arm64.dmg"]]
        var originalAsset = release(build: "20260921120000")
        originalAsset["assets"] = [["name": "SuperIsland.dmg", "browser_download_url": "https://github.com/372790111z-wq/SuperIsland/releases/download/we1-20260921120000/SuperIsland.dmg"]]
        XCTAssertEqual(try select([foreign, malicious, originalAsset]), .noCompatibleRelease)
    }

    func testUniversalAssetIsCompatibleButDowngradeCannotBeDownloaded() throws {
        guard case .available(let offer) = try select([release(build: "20260921120000", architecture: "universal")]) else {
            return XCTFail("Expected universal package")
        }
        XCTAssertTrue(policy.allowedWE1Download(try XCTUnwrap(offer.downloadURL)))
        XCTAssertFalse(policy.allowedWE1Download(URL(string: "https://github.com/372790111z-wq/SuperIsland/releases/download/we1-20260919120000/SuperIsland-WE1-20260919120000-arm64.dmg")!))
    }

    func testOriginalBuildKeepsOriginalReleaseChannel() throws {
        let original = UpdateReleasePolicy(bundleIdentifier: "com.workview.SuperIsland", currentVersion: "1.0.9", currentBuild: "10", architecture: "arm64")
        XCTAssertTrue(original.apiURL.absoluteString.contains("shobhit99/superisland/releases/latest"))
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.1.0", "html_url": "https://github.com/shobhit99/superisland/releases/tag/v1.1.0",
            "assets": [["name": "SuperIsland.dmg", "browser_download_url": "https://github.com/shobhit99/superisland/releases/download/v1.1.0/SuperIsland.dmg"]]
        ])
        guard case .available(let offer) = try original.selectRelease(from: data) else { return XCTFail("Expected original update") }
        XCTAssertEqual(offer.version, "1.1.0")
    }

    func testInvalidBuildAndUnexpectedResponseCannotOfferAnUpdate() throws {
        let invalid = UpdateReleasePolicy(bundleIdentifier: UpdateReleasePolicy.we1BundleID, currentVersion: "1.0.9", currentBuild: "unknown", architecture: "arm64")
        XCTAssertThrowsError(try invalid.selectRelease(from: Data("[]".utf8)))
        XCTAssertThrowsError(try policy.selectRelease(from: Data("{}".utf8)))
        XCTAssertEqual(try select([release(build: "20260921oops00")]), .noCompatibleRelease)
    }

    func testDownloadedAppMustMatchIdentityBuildAndActualArchitecture() throws {
        func validate(id: String = UpdateReleasePolicy.we1BundleID, build: String = "20260921120000", architectures: [Int] = [0x0100000c]) throws {
            try UpdatePackageValidator.validateMetadata(bundleIdentifier: id, build: build, executableArchitectures: architectures, policy: policy, expectedBuild: "20260921120000")
        }
        XCTAssertNoThrow(try validate())
        XCTAssertThrowsError(try validate(id: "com.workview.SuperIsland"))
        XCTAssertThrowsError(try validate(build: "20260922120000"))
        XCTAssertThrowsError(try validate(build: "20260919120000"))
        XCTAssertThrowsError(try validate(architectures: [0x01000007]))
        XCTAssertThrowsError(try validate(architectures: []))
    }

    private func select(_ releases: [[String: Any]]) throws -> UpdateReleasePolicy.Result {
        try policy.selectRelease(from: JSONSerialization.data(withJSONObject: releases))
    }

    private func release(build: String, architecture: String = "arm64", draft: Bool = false) -> [String: Any] {
        let tag = "we1-\(build)"
        let name = "SuperIsland-WE1-\(build)-\(architecture).dmg"
        return [
            "tag_name": tag, "draft": draft,
            "html_url": "https://github.com/372790111z-wq/SuperIsland/releases/tag/\(tag)",
            "assets": [["name": name, "browser_download_url": "https://github.com/372790111z-wq/SuperIsland/releases/download/\(tag)/\(name)"]]
        ]
    }
}
