import Carbon.HIToolbox
import Combine
import XCTest
@testable import SuperIsland

@MainActor
final class FinderFileShortcutPreferencesTests: XCTestCase {
    func testNewInstallLeavesFileDeletionOffAndUnbound() {
        withIsolatedDefaults { defaults in
            let preferences = WindowEnhancementPreferences(defaults: defaults)

            XCTAssertFalse(preferences.fileTrashEnabled)
            XCTAssertNil(preferences.shortcut(for: FinderFileShortcut.id))
            XCTAssertEqual(FinderFileShortcut.id, "file.moveToTrash")
            XCTAssertEqual(WindowQuickAction.hideAll.shortcutID, "action.hideAll")
            XCTAssertEqual(WindowQuickAction.hideAll.title, "隐藏/显示所有窗口")
        }
    }

    func testPersistedFileBindingDoesNotEnableItsSwitchOrChangeWindowBinding() throws {
        try withIsolatedDefaults { defaults in
            let binding = fileShortcut
            try seedBindings([
                FinderFileShortcut.id: binding,
                WindowQuickAction.hideAll.shortcutID: sampleShortcut
            ], in: defaults)
            let preferences = WindowEnhancementPreferences(defaults: defaults)

            XCTAssertFalse(preferences.fileTrashEnabled)
            XCTAssertEqual(preferences.shortcut(for: FinderFileShortcut.id), binding)
            XCTAssertEqual(preferences.shortcut(for: WindowQuickAction.hideAll.shortcutID), sampleShortcut)
        }
    }

    func testSwitchPersistsWithoutCreatingBindingAndPublishesConfigurationChange() {
        withIsolatedDefaults { defaults in
            let preferences = WindowEnhancementPreferences(defaults: defaults)
            var changes = 0
            let subscription = preferences.configurationChanges.sink { changes += 1 }

            preferences.fileTrashEnabled = true
            XCTAssertEqual(changes, 1)
            XCTAssertNil(preferences.shortcut(for: FinderFileShortcut.id))
            XCTAssertTrue(WindowEnhancementPreferences(defaults: defaults).fileTrashEnabled)

            preferences.publishFeedback("仅供隔离测试的状态消息")
            XCTAssertEqual(changes, 1, "Runtime feedback must not rebuild shortcut registrations")
            withExtendedLifetime(subscription) {}
        }
    }

    func testClearingFileBindingPreservesSwitchAndOtherShortcuts() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "windowEnhancement.fileTrash")
            try seedBindings([
                FinderFileShortcut.id: fileShortcut,
                WindowQuickAction.hideAll.shortcutID: sampleShortcut
            ], in: defaults)
            let preferences = WindowEnhancementPreferences(defaults: defaults)

            XCTAssertTrue(preferences.setShortcut(nil, for: FinderFileShortcut.id))
            let reloaded = WindowEnhancementPreferences(defaults: defaults)
            XCTAssertTrue(reloaded.fileTrashEnabled)
            XCTAssertNil(reloaded.shortcut(for: FinderFileShortcut.id))
            XCTAssertEqual(reloaded.shortcut(for: WindowQuickAction.hideAll.shortcutID), sampleShortcut)
        }
    }

    func testFinderBindingDoesNotClaimToOverrideOtherApplications() throws {
        try withIsolatedDefaults { defaults in
            try seedBindings([
                FinderFileShortcut.id: WindowShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey), display: "W"),
                WindowQuickAction.hideAll.shortcutID: sampleShortcut
            ], in: defaults)
            let preferences = WindowEnhancementPreferences(defaults: defaults)

            XCTAssertNil(preferences.shortcutSafetyWarning(for: FinderFileShortcut.id))
            XCTAssertNotNil(preferences.shortcutSafetyWarning(for: WindowQuickAction.hideAll.shortcutID))
        }
    }

    private var sampleShortcut: WindowShortcut {
        WindowShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey), display: "D")
    }

    private var fileShortcut: WindowShortcut {
        WindowShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey), display: "D")
    }

    private func seedBindings(_ bindings: [String: WindowShortcut], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(bindings), forKey: "windowEnhancement.shortcuts")
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "com.workview.SuperIsland.Tests.FileShortcut.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
