import Carbon.HIToolbox
import Combine
import XCTest
@testable import SuperIsland

@MainActor
final class WE1AdvancedSettingsTests: XCTestCase {
    func testResetReloadsLiveWindowSettingsAndOnlyRemovesTargetDomain() throws {
        let domain = "com.workview.SuperIsland.Tests.Advanced.\(UUID().uuidString)"
        let otherDomain = "com.workview.SuperIsland.Tests.Unrelated.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let other = UserDefaults(suiteName: otherDomain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            other.removePersistentDomain(forName: otherDomain)
        }
        defaults.set(true, forKey: "windowEnhancement.fileTrash")
        defaults.set(true, forKey: "windowEnhancement.dockPreview")
        defaults.set("purple", forKey: "windowEnhancement.accent")
        defaults.set(["com.example.Excluded"], forKey: "windowEnhancement.excludedBundleIDs")
        defaults.set([WindowQuickAction.hideAll.rawValue], forKey: "windowEnhancement.disabledActions")
        defaults.set(try JSONEncoder().encode([
            FinderFileShortcut.id: WindowShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey), display: "S")
        ]), forKey: "windowEnhancement.shortcuts")
        defaults.set("isolated-token", forKey: "extensions.test.store.oauth")
        other.set("preserve-me", forKey: "sentinel")
        let preferences = WindowEnhancementPreferences(defaults: defaults)
        XCTAssertTrue(preferences.fileTrashEnabled)
        XCTAssertNotNil(preferences.shortcut(for: FinderFileShortcut.id))
        var configurationChanges = 0
        let subscription = preferences.configurationChanges.sink { configurationChanges += 1 }
        let notifications = NotificationCenter()
        var lifecycle: [String] = []
        let before = notifications.addObserver(forName: .superIslandSettingsWillReset, object: nil, queue: nil) { _ in
            lifecycle.append("stop")
            // A runtime unloading can persist state; it must happen before deletion.
            defaults.set("last-deactivation-write", forKey: "extensions.test.store.runtime")
        }
        let after = notifications.addObserver(forName: .superIslandSettingsDidReset, object: nil, queue: nil) { _ in
            lifecycle.append("restart")
            XCTAssertNil(defaults.string(forKey: "extensions.test.store.runtime"))
            XCTAssertNil(defaults.string(forKey: "extensions.test.store.oauth"))
        }
        defer { notifications.removeObserver(before); notifications.removeObserver(after) }

        ApplicationSettingsReset.reset(defaults: defaults, domain: domain, windowPreferences: preferences, notificationCenter: notifications)

        XCTAssertEqual(lifecycle, ["stop", "restart"])
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertFalse(preferences.fileTrashEnabled)
        XCTAssertFalse(preferences.dockPreviewEnabled)
        XCTAssertEqual(preferences.accentName, "blue")
        XCTAssertEqual(preferences.excludedBundleIDs, [])
        XCTAssertNil(preferences.shortcut(for: FinderFileShortcut.id))
        XCTAssertTrue(preferences.isActionEnabled(.hideAll))
        XCTAssertGreaterThan(configurationChanges, 0, "Existing monitor subscriptions must receive reset values")
        XCTAssertEqual(other.string(forKey: "sentinel"), "preserve-me")
        withExtendedLifetime(subscription) {}
    }
}
