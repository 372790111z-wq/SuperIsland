import XCTest
@testable import SuperIsland

final class KeepAwakeCodexInstallerTests: XCTestCase {
    private let source = KeepAwakeSource(id: "codex-cli", name: "Codex CLI", integration: "fixture", hookFamily: "codex")

    func testInstallAndUninstallPreserveOtherHooksSettingsAndEmptyNotify() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original: [String: Any] = ["notify": [String](), "other": ["enabled": false]]
        try json(original).write(to: fixture.config)
        let existing: [String: Any] = ["enabled": false, "hooks": ["UserPromptSubmit": [["matcher": "", "hooks": [["type": "command", "command": "/other/notifier", "enabled": false]]]]]]
        try json(existing).write(to: fixture.hooks)
        let trust = fixture.codex.appendingPathComponent("trust-sentinel.fixture")
        try Data("unchanged-trust".utf8).write(to: trust)
        try install(fixture)
        var config = try object(fixture.config)
        XCTAssertEqual(config["notify"] as? [String], fixture.notify)
        XCTAssertEqual((config["other"] as? [String: Bool])?["enabled"], false)
        let hooks = try object(fixture.hooks)
        XCTAssertEqual(hooks["enabled"] as? Bool, false)
        XCTAssertEqual(commands(hooks, event: "UserPromptSubmit").first, "/other/notifier")
        XCTAssertEqual(commands(hooks, event: "UserPromptSubmit").count, 2)
        XCTAssertEqual(commands(hooks, event: "Stop").count, 1)
        let owned = ((hooks["hooks"] as? [String: Any])?["PreCompact"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]]
        XCTAssertNil(owned?[0]["async"], "Compaction hooks must retain synchronous execution order")
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, editor: fakeEditor)
        config = try object(fixture.config)
        XCTAssertEqual(config["notify"] as? [String], [])
        XCTAssertEqual(commands(try object(fixture.hooks), event: "UserPromptSubmit"), ["/other/notifier"])
        XCTAssertEqual(try Data(contentsOf: trust), Data("unchanged-trust".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        let stateFiles = try FileManager.default.contentsOfDirectory(at: fixture.state, includingPropertiesForKeys: nil)
        XCTAssertTrue(stateFiles.contains { $0.lastPathComponent != "install.lock" })
    }

    func testForeignNotifyConflictDoesNotWriteEitherConfiguration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let config = try json(["notify": ["/other/program", "private-argument"]])
        let hooks = try json(["hooks": [:]])
        try config.write(to: fixture.config); try hooks.write(to: fixture.hooks)
        XCTAssertThrowsError(try install(fixture))
        XCTAssertEqual(try Data(contentsOf: fixture.config), config)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testRepeatedInstallDoesNotDuplicateOrEnableAnExistingDisabledOwnedHook() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try install(fixture)
        var root = try object(fixture.hooks)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        var handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        handlers[0]["enabled"] = false; groups[0]["hooks"] = handlers
        hooks["UserPromptSubmit"] = groups; root["hooks"] = hooks
        try json(root).write(to: fixture.hooks)
        try install(fixture)
        let result = try object(fixture.hooks)
        XCTAssertEqual(commands(result, event: "UserPromptSubmit").count, 1)
        let kept = ((result["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]]
        XCTAssertEqual(kept?[0]["enabled"] as? Bool, false)
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, editor: fakeEditor)
        XCTAssertNil(try object(fixture.config)["notify"])
    }

    func testUninstallDoesNotOverwriteUsersLaterNotifyOrOtherSettings() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try install(fixture)
        try json(["notify": ["/user/new-notifier"], "newPreference": true]).write(to: fixture.config)
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, editor: fakeEditor)
        let result = try object(fixture.config)
        XCTAssertEqual(result["notify"] as? [String], ["/user/new-notifier"])
        XCTAssertEqual(result["newPreference"] as? Bool, true)
        for event in KeepAwakeCodexInstaller.events { XCTAssertTrue(commands(try object(fixture.hooks), event: event).isEmpty) }
    }

    func testConcurrentConfigEditIsPreservedAndDoesNotPartiallyInstallHooks() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try json(["original": true]).write(to: fixture.config)
        let userEdit = try json(["userEdit": true])
        let editor: KeepAwakeCodexInstaller.ConfigEditor = { original, mutation in
            try userEdit.write(to: fixture.config)
            return try self.fakeEditor(original, mutation)
        }
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, editor: editor))
        XCTAssertEqual(try Data(contentsOf: fixture.config), userEdit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testPendingPartialTransactionRollsBackBeforeUninstall() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let before = try json(["original": true]), after = try json(["partialInstall": true])
        try after.write(to: fixture.config)
        try pending(fixture, changes: [["name": "config.toml", "before": before.base64EncodedString(), "after": after.base64EncodedString()]])
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, editor: fakeEditor)
        XCTAssertEqual(try Data(contentsOf: fixture.config), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("pending.json").path))
    }

    func testPendingTransactionConflictLeavesAllFilesAndRecoveryRecordIntact() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let before = Data("before".utf8), after = Data("after".utf8), user = Data("user-new-edit".utf8)
        try user.write(to: fixture.config); try after.write(to: fixture.hooks)
        try pending(fixture, changes: [
            ["name": "config.toml", "before": before.base64EncodedString(), "after": after.base64EncodedString()],
            ["name": "hooks.json", "before": before.base64EncodedString(), "after": after.base64EncodedString()]
        ])
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, editor: fakeEditor))
        XCTAssertEqual(try Data(contentsOf: fixture.config), user)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("pending.json").path))
    }

    func testFailedCommitAndRollbackReportPendingAndRetainReceiptAndJournal() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try install(fixture)
        let receipt = try Data(contentsOf: fixture.receipt)
        let hooks = try Data(contentsOf: fixture.hooks)
        // Inject a readback failure after config has been replaced. Recovery
        // cannot safely read this file either and must leave its journal intact.
        let partialConfig = Data(repeating: 0x78, count: 1_048_577)
        let editor: KeepAwakeCodexInstaller.ConfigEditor = { _, _ in
            .init(data: partialConfig, previousNotify: fixture.notify)
        }
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, editor: editor)) { error in
            guard case KeepAwakeCodexInstaller.Failure.transactionPending = error else {
                XCTFail("An unconfirmed rollback must report transactionPending, got \(error)"); return
            }
            XCTAssertTrue(error.localizedDescription.contains("待恢复"))
            XCTAssertFalse(error.localizedDescription.contains("原配置未覆盖"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.config), partialConfig)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), receipt)
        let journal = try object(fixture.state.appendingPathComponent("pending.json"))
        let changes = try XCTUnwrap(journal["changes"] as? [[String: Any]])
        XCTAssertTrue(changes.contains { $0["name"] as? String == "config.toml" })
    }

    func testSymlinkConfigurationIsNotFollowedOrReplaced() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let external = fixture.base.appendingPathComponent("untouched.json")
        let original = try json(["other": true]); try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: external)
        XCTAssertThrowsError(try install(fixture))
        XCTAssertEqual(try Data(contentsOf: external), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.config.path), external.path)
    }

    func testDesktopCannotUseCLIInstallerAndCLIPathDoesNotFallBackToClaude() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let desktop = KeepAwakeSource(id: "codex-desktop", name: "desktop", integration: "fixture", hookFamily: "codex")
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: desktop, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, editor: fakeEditor))
        XCTAssertEqual(KeepAwakeHookInstaller.path(source: source, home: fixture.home), fixture.config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".claude").path))
    }

    func testOfficialEditorPreservesTomlCommentsInlineHooksAndProjectTrust() throws {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw XCTSkip("Official Codex CLI unavailable for isolated editor validation") }
        let original = Data("""
        # keep top comment
        model_reasoning_effort = "medium" # keep inline comment
        [projects."/tmp/superisland-fixture"]
        trust_level = "untrusted"
        [[hooks.UserPromptSubmit]]
        matcher = ""
        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = "/usr/bin/true"
        enabled = false
        """.utf8)
        let owned = ["/fixture/tool", "--superisland-ka1-codex-notify", "codex-cli", "/fixture/credential"]
        let installed = try KeepAwakeCodexInstaller.officialEdit(original, .install(owned: owned, replacingOwned: nil), executable: cli)
        XCTAssertNil(installed.previousNotify)
        let text = String(decoding: installed.data, as: UTF8.self)
        XCTAssertTrue(text.contains("# keep top comment")); XCTAssertTrue(text.contains("# keep inline comment"))
        XCTAssertTrue(text.contains("trust_level = \"untrusted\"")); XCTAssertTrue(text.contains("enabled = false"))
        let removed = try KeepAwakeCodexInstaller.officialEdit(installed.data, .remove(owned: owned, restore: nil), executable: cli)
        XCTAssertFalse(String(decoding: removed.data, as: UTF8.self).contains("notify ="))
        XCTAssertTrue(String(decoding: removed.data, as: UTF8.self).contains("trust_level = \"untrusted\""))
    }

    func testOfficialEditorRejectsForeignNotifyAndMalformedTomlWithoutModelCalls() throws {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw XCTSkip("Official Codex CLI unavailable for isolated editor validation") }
        let owned = ["/fixture/tool", "--superisland-ka1-codex-notify", "codex-cli", "/fixture/credential"]
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.officialEdit(Data("notify = [\"/other/program\"]".utf8),
            .install(owned: owned, replacingOwned: nil), executable: cli))
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.officialEdit(Data("notify = [not valid toml".utf8),
            .install(owned: owned, replacingOwned: nil), executable: cli))
    }

    func testOfficialEditorDoesNotReplaceProfileOwnedNotify() throws {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw XCTSkip("Official Codex CLI unavailable for isolated editor validation") }
        let original = Data("""
        profile = "fixture"
        [profiles.fixture]
        notify = ["/other/profile-notifier"]
        """.utf8)
        let owned = ["/fixture/tool", "--superisland-ka1-codex-notify", "codex-cli", "/fixture/credential"]
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.officialEdit(original,
            .install(owned: owned, replacingOwned: nil), executable: cli))
    }

    private func install(_ fixture: Fixture) throws {
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, editor: fakeEditor)
    }
    private func fakeEditor(_ data: Data, _ mutation: KeepAwakeCodexInstaller.NotifyMutation) throws -> KeepAwakeCodexInstaller.EditedConfig {
        var values = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let before = values["notify"] as? [String]
        let after = try KeepAwakeCodexInstaller.notifyValue(current: before, mutation: mutation)
        values["notify"] = after
        return .init(data: try json(values), previousNotify: before)
    }
    private func commands(_ root: [String: Any], event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }
    private func object(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func pending(_ fixture: Fixture, changes: [[String: String]]) throws {
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try json(["id": UUID().uuidString, "changes": changes]).write(to: fixture.state.appendingPathComponent("pending.json"))
    }
    private final class Fixture {
        let base: URL, home: URL, tool: URL
        var codex: URL { home.appendingPathComponent(".codex") }
        var config: URL { codex.appendingPathComponent("config.toml") }
        var hooks: URL { codex.appendingPathComponent("hooks.json") }
        var state: URL { codex.appendingPathComponent(".superisland-keep-awake") }
        var receipt: URL { state.appendingPathComponent("receipt.json") }
        var credential: URL { base.appendingPathComponent("credential.json") }
        var notify: [String] { [tool.path, "--superisland-ka1-codex-notify", "codex-cli", credential.path] }
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("KA1CodexInstaller-" + UUID().uuidString)
            home = base.appendingPathComponent("home")
            tool = base.appendingPathComponent("tool with spaces and ' quote")
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            XCTAssertTrue(FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o700]))
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }
}
