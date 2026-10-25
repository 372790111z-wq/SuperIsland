import XCTest
@testable import SuperIsland

final class KeepAwakeCodexInstallerTests: XCTestCase {
    func testLifecycleRefreshAddsOnlyOwnedSessionStartAndPreservesNotifyTrustAndDisabledHandlers() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try json(["notify": [String](), "other": true]).write(to: f.config)
        try install(f)
        var root = try object(f.hooks), hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks["SessionStart"] = [["hooks": [["type": "command", "command": "/other/start", "enabled": false]]]]
        hooks.removeValue(forKey: "Interrupt") // An explicit unrelated user edit must not be undone.
        root["hooks"] = hooks
        try json(root).write(to: f.hooks)
        let config = try Data(contentsOf: f.config), receipt = try Data(contentsOf: f.receipt)
        try KeepAwakeCodexInstaller.refreshOwnedLifecycleHooks(home: f.home)
        let updated = try object(f.hooks)
        XCTAssertEqual(commands(updated, event: "SessionStart").count, 2)
        XCTAssertEqual(commands(updated, event: "SessionStart").first, "/other/start")
        XCTAssertTrue(commands(updated, event: "Interrupt").isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.config), config)
        XCTAssertEqual(try Data(contentsOf: f.receipt), receipt)
        let stable = try Data(contentsOf: f.hooks)
        try KeepAwakeCodexInstaller.refreshOwnedLifecycleHooks(home: f.home)
        XCTAssertEqual(try Data(contentsOf: f.hooks), stable)

        var disabled = try object(f.hooks); disabled["enabled"] = false
        var disabledHooks = try XCTUnwrap(disabled["hooks"] as? [String: Any]); disabledHooks.removeValue(forKey: "SessionStart")
        disabled["hooks"] = disabledHooks; try json(disabled).write(to: f.hooks)
        let before = try Data(contentsOf: f.hooks)
        try KeepAwakeCodexInstaller.refreshOwnedLifecycleHooks(home: f.home)
        XCTAssertEqual(try Data(contentsOf: f.hooks), before)
    }
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

    func testOptInForwardingKeepsOriginalArgvAndBothSourcesShareOneWrapper() throws {
        let desktop = KeepAwakeSource(id: "codex-desktop", name: "desktop", integration: "fixture", hookFamily: "codex")
        for removeDesktopFirst in [true, false] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let original = ["/other/client with spaces", "--mode", "中文值", "", "a ' quote", "line\nbreak"]
            try json(["notify": original, "other": true]).write(to: fixture.config)
            let trust = fixture.codex.appendingPathComponent("trust-sentinel.fixture")
            try Data("unchanged-trust".utf8).write(to: trust)
            try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
                home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor)
            let wrapper = [fixture.tool.path, "--superisland-ka1-codex-notify-forward", fixture.receipt.path, "--"] + original
            XCTAssertEqual(try object(fixture.config)["notify"] as? [String], wrapper)
            XCTAssertEqual(try object(fixture.receipt)["notify"] as? [String], wrapper)
            XCTAssertEqual(try object(fixture.receipt)["previousNotify"] as? [String], original)
            let config = try Data(contentsOf: fixture.config), hooks = try Data(contentsOf: fixture.hooks)
            let desktopCredential = fixture.base.appendingPathComponent("desktop-credential.json")
            // Forwarding was explicitly authorized for the first connection;
            // adding the other source must not wrap it again or change trust.
            try KeepAwakeCodexInstaller.install(source: desktop, credential: desktopCredential,
                home: fixture.home, tool: fixture.tool, editor: fakeEditor)
            XCTAssertEqual(try Data(contentsOf: fixture.config), config)
            XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
            XCTAssertEqual(try object(fixture.receipt)["previousNotify"] as? [String], original)
            for event in KeepAwakeCodexInstaller.events {
                XCTAssertEqual(commands(try object(fixture.hooks), event: event).count, 1)
            }
            let first = removeDesktopFirst ? desktop : source, last = removeDesktopFirst ? source : desktop
            let firstCredential = removeDesktopFirst ? desktopCredential : fixture.credential
            let lastCredential = removeDesktopFirst ? fixture.credential : desktopCredential
            try KeepAwakeCodexInstaller.uninstall(source: first, home: fixture.home, credential: firstCredential, editor: fakeEditor)
            XCTAssertEqual(try Data(contentsOf: fixture.config), config)
            XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
            XCTAssertEqual(try object(fixture.receipt)["sources"] as? [String: String], [last.id: lastCredential.path])
            try KeepAwakeCodexInstaller.uninstall(source: last, home: fixture.home, credential: lastCredential, editor: fakeEditor)
            XCTAssertEqual(try object(fixture.config)["notify"] as? [String], original)
            XCTAssertEqual(try object(fixture.config)["other"] as? Bool, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
            XCTAssertEqual(try Data(contentsOf: trust), Data("unchanged-trust".utf8))
        }
    }

    func testForwardingReinstallAndToolMoveDoNotNestWrappers() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = ["/other/program", "argument"]
        try json(["notify": original]).write(to: fixture.config)
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor)
        let before = try Data(contentsOf: fixture.receipt)
        try install(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before)
        let moved = fixture.base.appendingPathComponent("relocated tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: moved.path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: moved, editor: fakeEditor)
        let expected = [moved.path, "--superisland-ka1-codex-notify-forward", fixture.receipt.path, "--"] + original
        XCTAssertEqual(try object(fixture.config)["notify"] as? [String], expected)
        XCTAssertEqual(try object(fixture.receipt)["previousNotify"] as? [String], original)
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, credential: fixture.credential, editor: fakeEditor)
        XCTAssertEqual(try object(fixture.config)["notify"] as? [String], original)
    }

    func testLaterForeignNotifyEditIsNeitherRewrappedNorOverwrittenByCleanup() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try json(["notify": ["/original/notifier"]]).write(to: fixture.config)
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor)
        let receipt = try Data(contentsOf: fixture.receipt), hooks = try Data(contentsOf: fixture.hooks)
        let changed = try json(["notify": ["/user/new-notifier", "keep exactly"], "newPreference": true])
        try changed.write(to: fixture.config)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor))
        XCTAssertEqual(try Data(contentsOf: fixture.config), changed)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, credential: fixture.credential, editor: fakeEditor)
        XCTAssertEqual(try Data(contentsOf: fixture.config), changed)
    }

    func testConcurrentNotifyEditDuringForwardingIsPreservedWithoutPartialInstall() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try json(["notify": ["/original/notifier"]]).write(to: fixture.config)
        let changed = try json(["notify": ["/concurrent/notifier"], "concurrent": true])
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: { data, mutation in
                let edited = try self.fakeEditor(data, mutation)
                try changed.write(to: fixture.config)
                return edited
            }))
        XCTAssertEqual(try Data(contentsOf: fixture.config), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testChangedForwardDelegateBlocksLastCleanupAndRetainsItsDependencies() throws {
        let desktop = KeepAwakeSource(id: "codex-desktop", name: "desktop", integration: "fixture", hookFamily: "codex")
        for changedDelegate in [["/user/new-notifier", "changed argument"], [String]()] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            try json(["notify": ["/original/notifier"]]).write(to: fixture.config)
            try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
                home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor)
            let desktopCredential = fixture.base.appendingPathComponent("desktop-credential.json")
            try KeepAwakeCodexInstaller.install(source: desktop, credential: desktopCredential,
                home: fixture.home, tool: fixture.tool, editor: fakeEditor)
            let changed = try json(["notify": [fixture.tool.path, "--superisland-ka1-codex-notify-forward",
                                               fixture.receipt.path, "--"] + changedDelegate])
            try changed.write(to: fixture.config)
            let hooks = try Data(contentsOf: fixture.hooks)
            // Revoking only one shared source leaves the wrapper and its
            // remaining routing entry in place without rewriting user argv.
            try KeepAwakeCodexInstaller.uninstall(source: desktop, home: fixture.home,
                credential: desktopCredential, editor: fakeEditor)
            let receipt = try Data(contentsOf: fixture.receipt)
            XCTAssertEqual(try object(fixture.receipt)["sources"] as? [String: String], [source.id: fixture.credential.path])
            XCTAssertThrowsError(try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home,
                credential: fixture.credential, editor: fakeEditor)) {
                    guard case KeepAwakeCodexInstaller.Failure.conflict = $0 else { return XCTFail("Expected changed-wrapper conflict") }
                }
            XCTAssertEqual(try Data(contentsOf: fixture.config), changed)
            XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
            XCTAssertEqual(try Data(contentsOf: fixture.receipt), receipt)
        }
    }

    func testForwardingRejectsToolItselfAliasesAndOwnedModeRecursion() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let symbolic = fixture.base.appendingPathComponent("tool symlink")
        let hard = fixture.base.appendingPathComponent("tool hardlink")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fixture.tool)
        try FileManager.default.linkItem(at: fixture.tool, to: hard)
        let delegates = [[fixture.tool.path], [symbolic.path], [hard.path],
                         ["/bin/sh", "-c", "exec tool --superisland-ka1-codex-notify-auto path"],
                         ["/other/tool", "--superisland-ka1"],
                         ["/other/tool", "--superisland-ka1-codex-notify-forward"], [""]]
        for delegate in delegates {
            XCTAssertThrowsError(try KeepAwakeCodexInstaller.notifyValue(current: delegate,
                mutation: .install(owned: fixture.notify, replacingOwned: nil, allowNotifyForwarding: true)))
        }
    }

    func testEditorMustConfirmTheActualOwnedNotifyBeforeReceiptIsCommitted() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = try json(["notify": ["/original/notifier"]]); try original.write(to: fixture.config)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: { data, mutation in
                var edited = try self.fakeEditor(data, mutation)
                edited.effectiveNotify = ["/unexpected/notifier"]
                return edited
            })) {
                guard case KeepAwakeCodexInstaller.Failure.editorFailed = $0 else { return XCTFail("Expected editor confirmation failure") }
            }
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testMalformedForwardReceiptCannotChangeAnyConfiguration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try json(["notify": ["/original/notifier"]]).write(to: fixture.config)
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor)
        var receipt = try object(fixture.receipt)
        receipt["previousNotify"] = ["/a/different/original"]
        let corrupted = try json(receipt); try corrupted.write(to: fixture.receipt)
        let config = try Data(contentsOf: fixture.config), hooks = try Data(contentsOf: fixture.hooks)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, editor: fakeEditor))
        XCTAssertEqual(try Data(contentsOf: fixture.config), config)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), corrupted)
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

    func testDesktopAndCLIShareOneRouterWithoutFallingBackToClaude() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let desktop = KeepAwakeSource(id: "codex-desktop", name: "desktop", integration: "fixture", hookFamily: "codex")
        try install(fixture)
        let config = try Data(contentsOf: fixture.config), hooks = try Data(contentsOf: fixture.hooks)
        let desktopCredential = fixture.base.appendingPathComponent("desktop-credential.json")
        try KeepAwakeCodexInstaller.install(source: desktop, credential: desktopCredential,
            home: fixture.home, tool: fixture.tool, editor: fakeEditor)
        XCTAssertEqual(try Data(contentsOf: fixture.config), config)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        let receipt = try object(fixture.receipt)
        XCTAssertEqual(receipt["version"] as? Int, 2)
        XCTAssertEqual(receipt["sources"] as? [String: String], [source.id: fixture.credential.path, desktop.id: desktopCredential.path])
        for event in KeepAwakeCodexInstaller.events { XCTAssertEqual(commands(try object(fixture.hooks), event: event).count, 1) }
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, credential: fixture.credential, editor: fakeEditor)
        XCTAssertEqual(try Data(contentsOf: fixture.config), config)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        XCTAssertEqual(try object(fixture.receipt)["sources"] as? [String: String], [desktop.id: desktopCredential.path])
        try KeepAwakeCodexInstaller.uninstall(source: desktop, home: fixture.home, credential: desktopCredential, editor: fakeEditor)
        XCTAssertNil(try object(fixture.config)["notify"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        XCTAssertEqual(KeepAwakeHookInstaller.path(source: source, home: fixture.home), fixture.config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".claude").path))
    }

    func testLegacyCLIReceiptMigratesToSharedRouterAndKeepsDisabledHooksAndBaseline() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let legacyNotify = [fixture.tool.path, "--superisland-ka1-codex-notify", source.id, fixture.credential.path]
        let legacyCommand = [KeepAwakeHookInstaller.shellQuote(fixture.tool.path), "--superisland-ka1", source.id,
                             KeepAwakeHookInstaller.shellQuote(fixture.credential.path)].joined(separator: " ")
        try json(["notify": legacyNotify, "other": true]).write(to: fixture.config)
        var events: [String: Any] = [:]
        for event in KeepAwakeCodexInstaller.events {
            events[event] = [["matcher": "", "enabled": false, "hooks": [["type": "command", "command": legacyCommand, "enabled": false, "timeout": 5], ["type": "command", "command": "/third-party"]]]]
        }
        try json(["enabled": false, "hooks": events]).write(to: fixture.hooks)
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
        let baseline = ["/previous/notifier", "preserved"]
        try json(["version": 1, "notify": legacyNotify, "hookCommand": legacyCommand, "previousNotify": baseline]).write(to: fixture.receipt)
        try install(fixture)
        let receipt = try object(fixture.receipt)
        XCTAssertEqual(receipt["version"] as? Int, 2)
        XCTAssertEqual(receipt["previousNotify"] as? [String], baseline)
        XCTAssertEqual(receipt["sources"] as? [String: String], [source.id: fixture.credential.path])
        let hooks = try object(fixture.hooks)
        XCTAssertEqual(hooks["enabled"] as? Bool, false)
        for event in KeepAwakeCodexInstaller.events {
            let group = try XCTUnwrap(((hooks["hooks"] as? [String: Any])?[event] as? [[String: Any]])?.first)
            let handlers = try XCTUnwrap(group["hooks"] as? [[String: Any]])
            XCTAssertEqual(group["enabled"] as? Bool, false)
            XCTAssertEqual(handlers[0]["enabled"] as? Bool, false)
            XCTAssertFalse(commands(hooks, event: event).contains(legacyCommand))
            XCTAssertEqual(handlers[1]["command"] as? String, "/third-party")
            if event == "Interrupt" { XCTAssertEqual(handlers[0]["timeout"] as? Int, 3) }
        }
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home, credential: fixture.credential, editor: fakeEditor)
        XCTAssertEqual(try object(fixture.config)["notify"] as? [String], baseline)
        XCTAssertEqual(commands(try object(fixture.hooks), event: "Stop"), ["/third-party"])
    }

    func testExplicitProfileRootNeverTouchesDefaultHomeAndWrongCredentialCannotUninstall() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let profile = fixture.base.appendingPathComponent("separate profile")
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential, home: fixture.home,
            tool: fixture.tool, codexHome: profile, cli: URL(fileURLWithPath: "/unused-injected-editor"), editor: fakeEditor)
        let config = profile.appendingPathComponent("config.toml")
        let receipt = profile.appendingPathComponent(".superisland-keep-awake/receipt.json")
        XCTAssertEqual(KeepAwakeCodexInstaller.configurationURL(home: fixture.home, codexHome: profile), config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.config.path))
        let bytes = try Data(contentsOf: receipt)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home,
            credential: fixture.base.appendingPathComponent("another-connection"), codexHome: profile, editor: fakeEditor))
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home,
            credential: fixture.credential, codexHome: profile, editor: fakeEditor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testDifferentToolAndCredentialCannotTakeOverExistingSource() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try install(fixture)
        let receipt = try Data(contentsOf: fixture.receipt), config = try Data(contentsOf: fixture.config)
        let otherTool = fixture.base.appendingPathComponent("other-app-tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: otherTool.path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source,
            credential: fixture.base.appendingPathComponent("other-app-credential"), home: fixture.home,
            tool: otherTool, editor: fakeEditor))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.config), config)
    }

    func testExplicitUnsignedCLIIsRejectedBeforeConfigurationEditing() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = try json(["unrelated": true]); try original.write(to: fixture.config)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, codexHome: fixture.codex, cli: fixture.tool))
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testDesktopFirstUninstallAndSameCredentialToolUpgradeKeepCLIConnected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let desktop = KeepAwakeSource(id: "codex-desktop", name: "desktop", integration: "fixture", hookFamily: "codex")
        let desktopCredential = fixture.base.appendingPathComponent("desktop-credential")
        try KeepAwakeCodexInstaller.install(source: desktop, credential: desktopCredential,
            home: fixture.home, tool: fixture.tool, editor: fakeEditor)
        try install(fixture)
        let before = try Data(contentsOf: fixture.receipt)
        try install(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), before, "reinstall must keep the same routing record")
        try KeepAwakeCodexInstaller.uninstall(source: desktop, home: fixture.home,
            credential: desktopCredential, editor: fakeEditor)
        XCTAssertEqual(try object(fixture.receipt)["sources"] as? [String: String], [source.id: fixture.credential.path])
        let relocated = fixture.base.appendingPathComponent("relocated-app-tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: relocated.path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: relocated, editor: fakeEditor)
        XCTAssertEqual((try object(fixture.config)["notify"] as? [String])?.first, relocated.path)
        for event in KeepAwakeCodexInstaller.events {
            let hook = try XCTUnwrap(commands(try object(fixture.hooks), event: event).first)
            XCTAssertTrue(hook.contains(KeepAwakeHookInstaller.shellQuote(relocated.path)))
            XCTAssertFalse(hook.contains(KeepAwakeHookInstaller.shellQuote(fixture.tool.path)))
        }
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

    func testOfficialEditorForwardsForeignNotifyOnlyWithOptInAndRestoresExactArgv() throws {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw XCTSkip("Official Codex CLI unavailable for isolated editor validation") }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let delegate = ["/fixture/previous notifier", "--mode", "中文值", ""]
        let original = Data("""
        # preserved notification comment
        notify = ["/fixture/previous notifier", "--mode", "中文值", ""]
        model_reasoning_effort = "medium" # preserved inline comment
        [projects."/tmp/superisland-forward-fixture"]
        trust_level = "untrusted"
        """.utf8)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.officialEdit(original,
            .install(owned: fixture.notify, replacingOwned: nil), executable: cli))
        let expected = [fixture.tool.path, "--superisland-ka1-codex-notify-forward", fixture.receipt.path, "--"] + delegate
        let installed = try KeepAwakeCodexInstaller.officialEdit(original,
            .install(owned: fixture.notify, replacingOwned: nil, allowNotifyForwarding: true), executable: cli)
        XCTAssertEqual(installed.previousNotify, delegate)
        XCTAssertEqual(installed.effectiveNotify, expected)
        let text = String(decoding: installed.data, as: UTF8.self)
        XCTAssertTrue(text.contains("# preserved notification comment"))
        XCTAssertTrue(text.contains("# preserved inline comment"))
        XCTAssertTrue(text.contains("trust_level = \"untrusted\""))
        let repeated = try KeepAwakeCodexInstaller.officialEdit(installed.data,
            .install(owned: fixture.notify, replacingOwned: expected), executable: cli)
        XCTAssertEqual(repeated.data, installed.data)
        XCTAssertEqual(repeated.effectiveNotify, expected)
        let removed = try KeepAwakeCodexInstaller.officialEdit(installed.data,
            .remove(owned: expected, restore: delegate), executable: cli)
        XCTAssertEqual(removed.effectiveNotify, delegate)
        XCTAssertFalse(String(decoding: removed.data, as: UTF8.self).contains("--superisland-ka1-codex-notify-forward"))
        XCTAssertTrue(String(decoding: removed.data, as: UTF8.self).contains("# preserved notification comment"))
    }

    func testForwardingOptInStillRejectsEffectiveProfileNotifyConflict() throws {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw XCTSkip("Official Codex CLI unavailable for isolated editor validation") }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = Data("""
        profile = "fixture"
        notify = ["/user/base-notifier"]
        [profiles.fixture]
        notify = ["/profile/notifier"]
        """.utf8)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.officialEdit(original,
            .install(owned: fixture.notify, replacingOwned: nil, allowNotifyForwarding: true), executable: cli))
    }

    private let relay = "/fixture/native notification client"
    private func nativeRelay(_ previous: [String], whitespace: Bool = false) throws -> [String] {
        let encoded = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
        return [relay, "turn-ended", "--previous-notify", whitespace ? "\n " + encoded + " \n" : encoded]
    }
    private func relayChild(_ command: [String]) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(command[3].utf8))
    }
    private func nestedValue(_ current: [String], _ mutation: KeepAwakeCodexInstaller.NotifyMutation) throws -> [String]? {
        try KeepAwakeCodexInstaller.notifyValue(current: current, mutation: mutation, relayVerifier: { $0 == self.relay })
    }
    private func relayEditor(_ data: Data, _ mutation: KeepAwakeCodexInstaller.NotifyMutation) throws -> KeepAwakeCodexInstaller.EditedConfig {
        var values = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let before = values["notify"] as? [String]
        let after = try KeepAwakeCodexInstaller.notifyValue(current: before, mutation: mutation, relayVerifier: { $0 == self.relay })
        values["notify"] = after
        return .init(data: try json(values), previousNotify: before, effectiveNotify: after)
    }

    func testNativeRelayReinstallPreservesItsOriginalJSONAndUpdatesOnlyMovedOwnedLeaf() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = ["/original/program", "", "中文\nopaque"]
        let owned = [fixture.tool.path, "--superisland-ka1-codex-notify-forward", fixture.receipt.path, "--"] + original
        let current = try nativeRelay(nativeRelay(owned, whitespace: true), whitespace: true)
        XCTAssertEqual(try nestedValue(current, .install(owned: fixture.notify, replacingOwned: owned)), current)
        let moved = ["/new/App.app/tool", fixture.notify[1], fixture.notify[2]]
        let changed = try XCTUnwrap(nestedValue(current, .install(owned: moved, replacingOwned: owned)))
        XCTAssertEqual(Array(changed.prefix(3)), Array(current.prefix(3)))
        let changedChild = try relayChild(changed)
        XCTAssertEqual(Array(changedChild.prefix(3)), Array(try relayChild(current).prefix(3)))
        XCTAssertEqual(try relayChild(changedChild), [moved[0], owned[1], owned[2], "--"] + original)
    }

    func testNativeRelayRemovalRestoresOnlyOwnedLeafAndKeepsOuterArguments() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = ["/original/program", "--some-option", "a ' quote", "", "中文\nsecond"]
        let current = try nativeRelay(nativeRelay(fixture.notify))
        let removed = try XCTUnwrap(nestedValue(current, .remove(owned: fixture.notify, restore: original)))
        XCTAssertEqual(Array(removed.prefix(3)), Array(current.prefix(3)))
        let child = try relayChild(removed)
        XCTAssertEqual(Array(child.prefix(3)), Array(try relayChild(current).prefix(3)))
        XCTAssertEqual(try relayChild(child), original)
        XCTAssertFalse(removed.contains { $0.contains("--superisland-ka1") })
        let noPrior = try XCTUnwrap(nestedValue(nativeRelay(fixture.notify), .remove(owned: fixture.notify, restore: nil)))
        XCTAssertEqual(noPrior, [relay, "turn-ended"])
    }

    func testUnknownOrUnsignedRelayCannotOrphanOwnedDependencies() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let current = try nativeRelay(fixture.notify)
        XCTAssertThrowsError(try KeepAwakeCodexInstaller.notifyValue(current: current,
            mutation: .remove(owned: fixture.notify, restore: nil)))
        XCTAssertFalse(KeepAwakeCodexInstaller.isOfficialNotifyRelay(fixture.tool.path))
        var unknown = current; unknown[0] = "/untrusted/SkyComputerUseClient"
        XCTAssertThrowsError(try nestedValue(unknown, .remove(owned: fixture.notify, restore: nil)))
        var wrongAction = current; wrongAction[1] = "different-action"
        XCTAssertThrowsError(try nestedValue(wrongAction, .remove(owned: fixture.notify, restore: nil)))
        let independent = ["/user/replacement", "opaque argument"]
        XCTAssertEqual(try nestedValue(independent, .remove(owned: fixture.notify, restore: nil)), independent)
    }

    func testNativeRelayRejectsMalformedExcessiveDepthAndEditedOwnedDelegate() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for payload in ["{broken", "{}", "[]", "[1]", String(repeating: "x", count: 1_048_577)] {
            XCTAssertThrowsError(try nestedValue([relay, "turn-ended", "--previous-notify", payload],
                .remove(owned: fixture.notify, restore: nil)))
        }
        var deep = fixture.notify
        for _ in 0..<5 { deep = try nativeRelay(deep) }
        XCTAssertThrowsError(try nestedValue(deep, .remove(owned: fixture.notify, restore: nil)))
        let original = ["/original/program"]
        let owned = [fixture.tool.path, "--superisland-ka1-codex-notify-forward", fixture.receipt.path, "--"] + original
        let edited = Array(owned.prefix(4)) + ["/changed/program"]
        XCTAssertThrowsError(try nestedValue(nativeRelay(edited), .remove(owned: owned, restore: original)))
        XCTAssertThrowsError(try nestedValue(nativeRelay(["/user/other"]), .install(owned: fixture.notify, replacingOwned: owned)))
    }

    func testBothSourcesShareOwnedLeafWhenNativeClientWrapsBetweenConnections() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = ["/original/program", "opaque"]
        try json(["notify": original, "keep": true]).write(to: fixture.config)
        try KeepAwakeCodexInstaller.install(source: source, credential: fixture.credential,
            home: fixture.home, tool: fixture.tool, allowNotifyForwarding: true, editor: fakeEditor)
        let owned = try XCTUnwrap(object(fixture.receipt)["notify"] as? [String])
        let wrapped = try nativeRelay(owned, whitespace: true)
        let wrappedConfig = try json(["notify": wrapped, "keep": true]); try wrappedConfig.write(to: fixture.config)
        let hooks = try Data(contentsOf: fixture.hooks)
        let desktop = KeepAwakeSource(id: "codex-desktop", name: "desktop", integration: "fixture", hookFamily: "codex")
        let credential = fixture.base.appendingPathComponent("desktop-credential.json")
        try KeepAwakeCodexInstaller.install(source: desktop, credential: credential,
            home: fixture.home, tool: fixture.tool, relayVerifier: { $0 == self.relay }, editor: relayEditor)
        XCTAssertEqual(try Data(contentsOf: fixture.config), wrappedConfig)
        XCTAssertEqual(try Data(contentsOf: fixture.hooks), hooks)
        XCTAssertEqual(try object(fixture.receipt)["notify"] as? [String], owned, "receipt owns the leaf, never the outer relay")
        XCTAssertEqual(try object(fixture.receipt)["previousNotify"] as? [String], original)
        try KeepAwakeCodexInstaller.uninstall(source: source, home: fixture.home,
            relayVerifier: { $0 == self.relay }, editor: relayEditor)
        XCTAssertEqual(try Data(contentsOf: fixture.config), wrappedConfig)
        try KeepAwakeCodexInstaller.uninstall(source: desktop, home: fixture.home,
            relayVerifier: { $0 == self.relay }, editor: relayEditor)
        let cleaned = try XCTUnwrap(object(fixture.config)["notify"] as? [String])
        XCTAssertEqual(try relayChild(cleaned), original)
        XCTAssertEqual(try object(fixture.config)["keep"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        for event in KeepAwakeCodexInstaller.events {
            XCTAssertTrue(commands(try object(fixture.hooks), event: event).isEmpty)
        }
    }

    func testOfficialEditorRemovesNestedOwnedCommandWithoutChangingOtherTOML() throws {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw XCTSkip("Official CLI not available") }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let wrapped = try nativeRelay(fixture.notify)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let array = String(decoding: try encoder.encode(wrapped), as: UTF8.self)
        let original = Data(("# preserved relay comment\nnotify = " + array + "\nmodel_reasoning_effort = \"medium\" # untouched\n").utf8)
        let repeated = try KeepAwakeCodexInstaller.officialEdit(original,
            .install(owned: fixture.notify, replacingOwned: fixture.notify), executable: cli,
            relayVerifier: { $0 == self.relay })
        XCTAssertEqual(repeated.data, original)
        let result = try KeepAwakeCodexInstaller.officialEdit(original,
            .remove(owned: fixture.notify, restore: nil), executable: cli,
            relayVerifier: { $0 == self.relay })
        XCTAssertEqual(result.effectiveNotify, [relay, "turn-ended"])
        let text = String(decoding: result.data, as: UTF8.self)
        XCTAssertTrue(text.contains("# preserved relay comment"))
        XCTAssertTrue(text.contains("# untouched"))
        XCTAssertFalse(text.contains("--superisland-ka1"))
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
        var notify: [String] { [tool.path, "--superisland-ka1-codex-notify-auto", receipt.path] }
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
