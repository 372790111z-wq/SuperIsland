import XCTest
@testable import SuperIsland

final class BatteryReviewIsolationTests: XCTestCase {
    func testOnlyExactReviewIdentitiesReceiveIsolatedExtensionPolicy() {
        XCTAssertTrue(ExtensionHostEnvironment.isIsolatedReview(bundleIdentifier: "com.workview.SuperIsland.BM1Debug"))
        XCTAssertTrue(ExtensionHostEnvironment.isIsolatedReview(bundleIdentifier: "com.workview.SuperIsland.WE1Debug"))
        for identifier in [nil, "com.workview.SuperIsland", "com.workview.SuperIsland.BM1Debug.extra", "other.BM1Debug"] {
            XCTAssertFalse(ExtensionHostEnvironment.isIsolatedReview(bundleIdentifier: identifier))
        }
    }
    func testBM1StorageDoesNotChangeExistingProductionOrWE1Paths() {
        XCTAssertEqual(ExtensionHostEnvironment.applicationSupportDirectoryName(bundleIdentifier: "com.workview.SuperIsland"), "SuperIsland")
        XCTAssertEqual(ExtensionHostEnvironment.applicationSupportDirectoryName(bundleIdentifier: "com.workview.SuperIsland.WE1Debug"), "SuperIsland-WE1-Debug")
        XCTAssertEqual(ExtensionHostEnvironment.applicationSupportDirectoryName(bundleIdentifier: "com.workview.SuperIsland.BM1Debug"), "SuperIsland-BM1-Review")
    }
    func testBM1DiscoveryCannotUseWorkingDirectoryOrDevelopmentPlugins() {
        let installed = URL(fileURLWithPath: "/test/SuperIsland-BM1-Review/Extensions")
        let bundled = URL(fileURLWithPath: "/test/BM1.app/Contents/Resources/BundledExtensions")
        let paths = ExtensionHostEnvironment.discoveryDirectories(
            isWE1: ExtensionHostEnvironment.isIsolatedReview(bundleIdentifier: "com.workview.SuperIsland.BM1Debug"),
            installed: installed, development: URL(fileURLWithPath: "/test/development"),
            local: URL(fileURLWithPath: "/test/working-directory"), repository: URL(fileURLWithPath: "/test/repository"), bundled: bundled)
        XCTAssertEqual(paths, [installed, bundled])
    }
    func testNewBM1PluginsAndCLIHooksRemainOffUntilExplicitOptIn() {
        let name = "SuperIsland.BM1.IsolationTests.\(UUID())"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: "extensions.superisland.agents-status.settings.hooksCodex")
        let isolated = ExtensionHostEnvironment.isIsolatedReview(bundleIdentifier: "com.workview.SuperIsland.BM1Debug")
        ExtensionActivationPolicy.register(installedIDs: ["agents-status", "ai-usage", "pomodoro"], defaultDisabledIDs: [], defaults: store, isWE1: isolated)
        XCTAssertEqual(Set(store.stringArray(forKey: ExtensionActivationPolicy.disabledKey) ?? []), ["agents-status", "ai-usage", "pomodoro"])
        XCTAssertFalse(store.bool(forKey: "extensions.superisland.agents-status.settings.hooksCodex"))
        XCTAssertFalse(store.bool(forKey: "extensions.superisland.agents-status.settings.hooksClaudeCode"))
        store.set(["agents-status", "ai-usage"], forKey: ExtensionActivationPolicy.disabledKey)
        ExtensionActivationPolicy.register(installedIDs: ["agents-status", "ai-usage", "pomodoro", "new"], defaultDisabledIDs: [], defaults: store, isWE1: isolated)
        XCTAssertEqual(Set(store.stringArray(forKey: ExtensionActivationPolicy.disabledKey) ?? []), ["agents-status", "ai-usage", "new"])
    }
    @MainActor func testBM1ShelfImagesCannotShareProductionOrWE1ImageDirectory() {
        let base = URL(fileURLWithPath: "/test/Application Support")
        let production = ShelfStore.imageStorageDirectory(base: base, bundleIdentifier: "com.workview.SuperIsland")
        let we1 = ShelfStore.imageStorageDirectory(base: base, bundleIdentifier: "com.workview.SuperIsland.WE1Debug")
        let review = ShelfStore.imageStorageDirectory(base: base, bundleIdentifier: "com.workview.SuperIsland.BM1Debug")
        XCTAssertEqual(production.path, "/test/Application Support/SuperIsland/ShelfImages")
        XCTAssertEqual(we1, production, "Preserve the historical WE1 path")
        XCTAssertEqual(review.path, "/test/Application Support/SuperIsland-BM1-Review/ShelfImages")
        XCTAssertNotEqual(review, production)
    }
}
