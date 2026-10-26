import XCTest
import CryptoKit
import Darwin
@testable import SuperIsland

final class KeepAwakeCodexContractTests: XCTestCase {
    func testChildHookOwnerMatchesNotifyRatherThanSharedParentSession() throws {
        for child in ["child-a", "child-b"] {
            for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "PreCompact", "PostCompact"] {
                let input: [String: Any] = ["session_id": "shared-root", "agent_id": child,
                    "turn_id": "round", "hook_event_name": event, "transcript_path": NSNull()]
                let owner = try XCTUnwrap(KeepAwakeHookContract.codexHookSession(input))
                let terminal = try XCTUnwrap(KeepAwakeHookContract.codexNotification([
                    "type": "agent-turn-complete", "thread-id": child, "turn-id": "round"]))
                XCTAssertEqual(owner, terminal.session)
                XCTAssertNotEqual(owner, KeepAwakeHookContract.anonymousIdentity("shared-root"))
                XCTAssertTrue(KeepAwakeHookContract.codexTaskInputIsIdentified(input, verifiedSession: false))
            }
        }
        XCTAssertEqual(KeepAwakeHookContract.codexHookSession(hook("PreToolUse")),
            KeepAwakeHookContract.anonymousIdentity("PRIVATE-THREAD"))
    }
    func testMalformedChildCannotFallBackToRootOrBorrowRootProof() {
        for value: Any in ["", " \n", "child\n", 7, String(repeating: "x", count: 1025)] {
            var input = hook("SessionStart"); input["source"] = "startup"; input["agent_id"] = value
            XCTAssertNil(KeepAwakeHookContract.codexHookSession(input))
            XCTAssertNil(KeepAwakeHookContract.codexRootSessionProof(input))
            XCTAssertFalse(KeepAwakeHookContract.codexTaskInputIsIdentified(input, verifiedSession: true))
        }
        var child = hook("SessionStart"); child["source"] = "startup"; child["agent_id"] = "child"
        XCTAssertNil(KeepAwakeHookContract.codexRootSessionProof(child))
    }
    func testChildrenWithSharedSessionAndSameTurnRemainIndependentThroughRelease() throws {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        let env = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true)
        func input(_ child: String) -> [String: Any] {
            ["session_id": "root", "agent_id": child, "turn_id": "same-turn", "hook_event_name": "UserPromptSubmit"]
        }
        for child in ["one", "two"] {
            let payload = input(child), metadata = KeepAwakeHookContract.metadata(source: "codex-desktop", input: payload)
            XCTAssertTrue(engine.receive(.init(source: "codex-desktop", session: try XCTUnwrap(KeepAwakeHookContract.codexHookSession(payload)),
                sequence: 1, state: .running, taskID: metadata.taskID, startsTask: metadata.startsTask), now: 0))
        }
        func finish(_ child: String, time: TimeInterval) throws {
            let done = try XCTUnwrap(KeepAwakeHookContract.codexNotification([
                "type": "agent-turn-complete", "thread-id": child, "turn-id": "same-turn"]))
            engine.receive(.init(source: "codex-desktop", session: done.session, sequence: 2,
                state: .completed, taskID: done.metadata.taskID, startsTask: false), now: time)
        }
        try finish("one", time: 1)
        XCTAssertTrue(engine.evaluate(now: 100, environment: env).hold, "A sibling still runs even after the first child releases.")
        XCTAssertEqual(engine.sessions.count, 2)
        try finish("two", time: 101)
        XCTAssertTrue(engine.evaluate(now: 130.9, environment: env).hold)
        XCTAssertFalse(engine.evaluate(now: 131, environment: env).hold)
        XCTAssertEqual(engine.sessions.count, 2, "Notify updates the existing owner instead of leaving a parent guard.")
    }
    func testAnonymousEphemeralWorkersCannotInventPermanentTasks() {
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "PreCompact", "PostCompact"] {
            let input: [String: Any] = ["session_id": "worker", "turn_id": "worker-turn",
                "hook_event_name": event, "transcript_path": NSNull()]
            XCTAssertFalse(KeepAwakeHookContract.codexTaskInputIsIdentified(input, verifiedSession: false))
            XCTAssertTrue(KeepAwakeHookContract.codexTaskInputIsIdentified(input, verifiedSession: true),
                "A real --ephemeral root remains supported after its SessionStart proof.")
        }
    }
    func testRootCompletionReleasesAfterThirtySecondsDespiteUnfinishedInternalWorkerHooks() {
        let source = "codex-desktop"
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        let environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true)
        func deliver(_ session: String, _ turn: String, _ event: String, transcript: Any, sequence: UInt64, time: TimeInterval) {
            let payload: [String: Any] = ["session_id": session, "turn_id": turn, "hook_event_name": event, "transcript_path": transcript]
            guard KeepAwakeHookContract.codexTaskInputIsIdentified(payload, verifiedSession: false),
                  let state = KeepAwakeHookContract.eventState(source: source, input: payload),
                  let typed = KeepAwakeEngine.TaskState(rawValue: state) else { return }
            let metadata = KeepAwakeHookContract.metadata(source: source, input: payload)
            engine.receive(.init(source: source, session: KeepAwakeHookContract.anonymousIdentity(session), sequence: sequence,
                state: typed, taskID: metadata.taskID, startsTask: metadata.startsTask), now: time)
        }
        deliver("root", "root-turn", "UserPromptSubmit", transcript: "/fixture/rollout.jsonl", sequence: 1, time: 0)
        deliver("code-worker", "worker-turn", "UserPromptSubmit", transcript: NSNull(), sequence: 2, time: 1)
        deliver("code-worker", "worker-turn", "PostToolUse", transcript: NSNull(), sequence: 3, time: 2)
        deliver("code-worker", "worker-turn", "Stop", transcript: NSNull(), sequence: 4, time: 3)
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold, "The root still has no terminal event.")
        let terminal = KeepAwakeHookContract.codexNotification(["type": "agent-turn-complete", "thread-id": "root", "turn-id": "root-turn"])!
        engine.receive(.init(source: source, session: terminal.session, sequence: 5, state: .completed,
            taskID: terminal.metadata.taskID, startsTask: false), now: 10_001)
        XCTAssertEqual(engine.sessions.count, 1)
        XCTAssertTrue(engine.evaluate(now: 10_030.9, environment: environment).hold)
        XCTAssertFalse(engine.evaluate(now: 10_031, environment: environment).hold)
    }
    func testPersistedRootsLegacyHooksAndExplicitUserSubagentsRemainAdmitted() {
        XCTAssertTrue(KeepAwakeHookContract.codexTaskInputIsIdentified(hook("UserPromptSubmit"), verifiedSession: false))
        var root = hook("UserPromptSubmit"); root["transcript_path"] = "/fixture/root.jsonl"
        XCTAssertTrue(KeepAwakeHookContract.codexTaskInputIsIdentified(root, verifiedSession: false))
        root["transcript_path"] = NSNull(); root["agent_id"] = "user-spawned-agent"
        XCTAssertTrue(KeepAwakeHookContract.codexTaskInputIsIdentified(root, verifiedSession: false))
        root["agent_id"] = ""; root["transcript_path"] = "relative/path"
        XCTAssertFalse(KeepAwakeHookContract.codexTaskInputIsIdentified(root, verifiedSession: false))
    }
    func testOnlyPublicRootLifecycleCanProvideEphemeralAdmissionProof() {
        for source in ["startup", "resume", "clear", "compact", "fork"] {
            var input = hook("SessionStart"); input["source"] = source
            XCTAssertEqual(KeepAwakeHookContract.codexRootSessionProof(input), KeepAwakeHookContract.anonymousIdentity("PRIVATE-THREAD"))
        }
        for event in ["UserPromptSubmit", "SessionEnd", "SubagentStart", "PostToolUse"] {
            var input = hook(event); input["source"] = "startup"
            XCTAssertNil(KeepAwakeHookContract.codexRootSessionProof(input))
        }
        var unknown = hook("SessionStart"); unknown["source"] = "unknown-version-value"
        XCTAssertNil(KeepAwakeHookContract.codexRootSessionProof(unknown))
    }
    func testRootProofPersistsWithoutRawIDsAndRejectsSymlinkSubstitution() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let proof = KeepAwakeCodexSessionProof(credential: root.appendingPathComponent("credential.json"))
        let identity = KeepAwakeHookContract.anonymousIdentity("PRIVATE-ROOT-ID")
        XCTAssertFalse(try proof.contains(identity)); try proof.remember(identity)
        XCTAssertTrue(try KeepAwakeCodexSessionProof(credential: proof.credential).contains(identity))
        let data = try Data(contentsOf: proof.url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-ROOT-ID"))
        XCTAssertEqual((try fm.attributesOfItem(atPath: proof.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let other = root.appendingPathComponent("other.json"); try data.write(to: other)
        try fm.removeItem(at: proof.url); try fm.createSymbolicLink(at: proof.url, withDestinationURL: other)
        XCTAssertThrowsError(try proof.contains(identity)); XCTAssertThrowsError(try proof.remember(identity))
        XCTAssertEqual(try Data(contentsOf: other), data)
    }
    func testUnattributedProcessCannotRegisterAnEphemeralRootProof() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try fm.createDirectory(at: inbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let credential = root.appendingPathComponent("credential.json")
        try JSONSerialization.data(withJSONObject: ["source": "codex-cli", "generation": "fixture",
            "key": Data(repeating: 7, count: 32).base64EncodedString(), "inbox": inbox.path]).write(to: credential)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        process.arguments = ["--superisland-ka1", "codex-cli", credential.path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject:
            ["session_id": "untrusted-root", "source": "startup", "hook_event_name": "SessionStart", "transcript_path": NSNull()]))
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(fm.fileExists(atPath: KeepAwakeCodexSessionProof(credential: credential).url.path))
        XCTAssertTrue(try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).isEmpty)
    }
    private let sources = ["codex-cli", "codex-desktop"]
    private func hook(_ event: String, turn: Any = "PRIVATE-TURN-A") -> [String: Any] {
        ["session_id": "PRIVATE-THREAD", "turn_id": turn, "hook_event_name": event]
    }
    private func notification() -> [String: Any] {
        ["type": "agent-turn-complete", "thread-id": "PRIVATE-THREAD", "turn-id": "PRIVATE-TURN-A",
         "cwd": "/PRIVATE-PATH", "input-messages": ["PRIVATE-PROMPT"], "last-assistant-message": "PRIVATE-ANSWER"]
    }
    func testPublicTurnIdentityMatchesNotifyWithoutExposingOriginalIdentifiers() throws {
        let completion = try XCTUnwrap(KeepAwakeHookContract.codexNotification(notification()))
        XCTAssertEqual(completion.state, "completed")
        XCTAssertEqual(completion.session, KeepAwakeHookContract.anonymousIdentity("PRIVATE-THREAD"))
        XCTAssertEqual(completion.session.count, 64)
        for source in sources {
            let start = KeepAwakeHookContract.metadata(source: source, input: hook("UserPromptSubmit"))
            XCTAssertEqual(start.taskID, completion.metadata.taskID)
            XCTAssertEqual(start.taskID?.count, 64)
            XCTAssertTrue(start.startsTask)
            XCTAssertFalse(completion.metadata.startsTask)
        }
        let diagnostic = String(describing: completion)
        for text in ["PRIVATE-THREAD", "PRIVATE-TURN-A", "PRIVATE-PATH", "PRIVATE-PROMPT", "PRIVATE-ANSWER"] {
            XCTAssertFalse(diagnostic.contains(text))
        }
    }
    func testOnlyActualPromptMarksStartAndToolActivityPreservesSameRound() {
        for source in sources {
            let start = KeepAwakeHookContract.metadata(source: source, input: hook("UserPromptSubmit"))
            for name in ["PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt"] {
                let next = KeepAwakeHookContract.metadata(source: source, input: hook(name))
                XCTAssertEqual(next.taskID, start.taskID)
                XCTAssertFalse(next.startsTask)
            }
            XCTAssertNotEqual(start.taskID, KeepAwakeHookContract.metadata(source: source,
                input: hook("UserPromptSubmit", turn: "PRIVATE-TURN-B")).taskID)
        }
    }
    func testInterruptCanOnlyCancelItsIdentifiedMainTurn() {
        for source in sources {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: hook("Interrupt")), "cancelled")
            for value: Any in ["", " ", "line\nbreak", String(repeating: "x", count: 1025), NSNull(), 12] {
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                    input: hook("Interrupt", turn: value)), "idle")
            }
            XCTAssertNil(KeepAwakeHookContract.eventState(source: source, input: hook("SubagentStop")))
        }
    }
    func testStopCanNeverFinishEvenWithTurnIDOrContinuationFlag() {
        for source in sources {
            for continued in [false, true] {
                var input = hook("Stop"); input["stop_hook_active"] = continued
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: input), "idle")
            }
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: hook("SessionEnd")), "idle")
        }
    }
    func testNotificationRequiresExactTypeAndBothBoundedStringIdentities() {
        for key in ["thread-id", "turn-id"] {
            for invalid: Any in ["", " \t", String(repeating: "x", count: 1025), NSNull(), true, 12] {
                var input = notification(); input[key] = invalid
                XCTAssertNil(KeepAwakeHookContract.codexNotification(input))
            }
            var missing = notification(); missing.removeValue(forKey: key)
            XCTAssertNil(KeepAwakeHookContract.codexNotification(missing))
        }
        var unknown = notification(); unknown["type"] = "approval-requested"
        XCTAssertNil(KeepAwakeHookContract.codexNotification(unknown))
        for source in sources {
            var fakeHook = notification(); fakeHook["session_id"] = "PRIVATE-THREAD"
            fakeHook["hook_event_name"] = "agent-turn-complete"
            XCTAssertNil(KeepAwakeHookContract.eventState(source: source, input: fakeHook), "notify is not a stdin hook")
        }
    }
    func testNoPromptOrTranscriptValueCanSubstituteForTurnIdentity() {
        for source in sources {
            let input: [String: Any] = ["hook_event_name": "Stop", "session_id": "session",
                "tool_use_id": "PRIVATE-ID", "generation_id": "PRIVATE-ID", "transcript_path": "PRIVATE-ID",
                "prompt": "PRIVATE-ID", "turn-id": "notify-only-key"]
            XCTAssertNil(KeepAwakeHookContract.metadata(source: source, input: input).taskID)
        }
    }
    func testCLICommandRoleIsIndependentOfBundleDirectoryAndTTY() {
        let binary = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        for args in [[binary], [binary, "exec", "private prompt"], [binary, "--no-daemon", "resume", "--last"],
                     [binary, "-c", "private.config=value", "--model=test", "review"]] {
            XCTAssertEqual(KeepAwakeHookContract.codexProcessRole(arguments: args), .cli)
        }
        XCTAssertEqual(KeepAwakeHookContract.codexProcessRole(arguments: [binary, "--enable", "hooks", "app-server"]), .appServer)
        for args in [[binary, "exec-server"], [binary, "--remote", "unix://private"], [binary, "app"], [binary, "-c"], []] {
            XCTAssertEqual(KeepAwakeHookContract.codexProcessRole(arguments: args), .other)
        }
    }
    func testNearestVerifiedProcessSeparatesCLIAndDesktopIncludingNestedCLI() {
        typealias Ancestor = KeepAwakeHookContract.CodexAncestor
        let cli = Ancestor(isCodex: true, isVerified: true, role: .cli, isDesktopHost: false)
        let server = Ancestor(isCodex: true, isVerified: true, role: .appServer, isDesktopHost: false)
        let host = Ancestor(isCodex: false, isVerified: false, role: .other, isDesktopHost: true)
        XCTAssertTrue(KeepAwakeHookContract.acceptsCodexParent(source: "codex-cli", ancestors: [cli, server, host]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-desktop", ancestors: [cli, server, host]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-cli", ancestors: [server, host]))
        XCTAssertTrue(KeepAwakeHookContract.acceptsCodexParent(source: "codex-desktop", ancestors: [server, host]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-desktop", ancestors: [server, cli, host]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-desktop", ancestors: [server, server, host]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-desktop", ancestors: [server]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-cli", ancestors: [host]))
        let fake = Ancestor(isCodex: true, isVerified: false, role: .cli, isDesktopHost: false)
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-cli", ancestors: [fake, cli]))
    }
    func testSharedRouterSelectsOnlyTheObservedConnectedSourceAndRejectsMalformedMappings() throws {
        let valid = Data("{\"version\":2,\"sources\":{\"codex-cli\":\"/private/cli.json\",\"codex-desktop\":\"/private/desktop.json\"},\"previousNotify\":[\"ignored\"]}".utf8)
        let router = try JSONDecoder().decode(KeepAwakeHookContract.CodexRouter.self, from: valid)
        XCTAssertEqual(router.credentialPath(source: "codex-cli"), "/private/cli.json")
        XCTAssertEqual(router.credentialPath(source: "codex-desktop"), "/private/desktop.json")
        XCTAssertNil(router.credentialPath(source: "pi"))
        let onlyCLI = KeepAwakeHookContract.CodexRouter(version: 2, sources: ["codex-cli": "/private/cli.json"])
        XCTAssertNil(onlyCLI.credentialPath(source: "codex-desktop"))
        for invalid in [
            KeepAwakeHookContract.CodexRouter(version: 1, sources: ["codex-cli": "/private/cli.json"]),
            .init(version: 2, sources: [:]),
            .init(version: 2, sources: ["codex-cli": "relative-credential"]),
            .init(version: 2, sources: ["codex-cli": "/private/cli.json", "other": "/private/other.json"]),
            .init(version: 2, sources: ["codex-cli": "/" + String(repeating: "x", count: 4096)])
        ] {
            XCTAssertNil(invalid.credentialPath(source: "codex-cli"))
        }
    }
    func testNotifyDelegatePreservesOpaqueArgumentsAndRejectsRecursionOrInvalidBounds() {
        let tool = "/private/fixture/KeepAwakeEventTool"
        XCTAssertTrue(KeepAwakeHookContract.validCodexNotifyDelegate(
            ["/usr/bin/printf", "", "with spaces", "quote'\"", "中文\nsecond line"], toolPath: tool))
        for command in [[String](), [""], ["/usr/bin/printf", "nul\0argument"],
                        ["/usr/bin/printf", String(repeating: "x", count: 1_048_577)],
                        Array(repeating: "x", count: 1025), [String(repeating: "x", count: 4097)],
                        [tool], ["/private/fixture/../fixture/KeepAwakeEventTool"]] {
            XCTAssertFalse(KeepAwakeHookContract.validCodexNotifyDelegate(command, toolPath: tool))
        }
        for mode in ["--superisland-ka1", "--superisland-ka1-codex-hook-auto", "--superisland-ka1-codex-notify",
                     "--superisland-ka1-codex-notify-auto", KeepAwakeHookContract.codexNotifyForwardMode] {
            XCTAssertFalse(KeepAwakeHookContract.validCodexNotifyDelegate(["/bin/echo", mode], toolPath: tool))
            XCTAssertFalse(KeepAwakeHookContract.validCodexNotifyDelegate(["/bin/sh", "-c", "exec '/other/tool' " + mode], toolPath: tool))
        }
    }
    func testNotifyDelegateRejectsSymlinkAndHardlinkAliasesOfItsOwnExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KA1NotifyDelegate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("tool"), symlink = directory.appendingPathComponent("symlink"), hardlink = directory.appendingPathComponent("hardlink")
        try Data("fixture".utf8).write(to: tool)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: tool)
        try FileManager.default.linkItem(at: tool, to: hardlink)
        XCTAssertFalse(KeepAwakeHookContract.validCodexNotifyDelegate([symlink.path], toolPath: tool.path))
        XCTAssertFalse(KeepAwakeHookContract.validCodexNotifyDelegate([hardlink.path], toolPath: tool.path))
    }
    func testCodexIdentityAndTerminalMetadataArePartOfAuthentication() throws {
        let completion = try XCTUnwrap(KeepAwakeHookContract.codexNotification(notification()))
        func bytes(_ task: String?, _ starts: Bool?) -> Data {
            KeepAwakeHookContract.authenticatedBytes(generation: "credential-generation", source: "codex-cli",
                session: completion.session, sequence: 1, state: "completed", issuedAt: 1,
                taskID: task, startsTask: starts)
        }
        let correct = bytes(completion.metadata.taskID, false)
        XCTAssertNotEqual(correct, bytes(nil, false))
        XCTAssertNotEqual(correct, bytes("other-round", false))
        XCTAssertNotEqual(correct, bytes(completion.metadata.taskID, true))
        XCTAssertNotEqual(correct, bytes(completion.metadata.taskID, nil))
    }
    func testAuxiliaryTaskLabelIsNarrowAnonymousAndAuthenticated() throws {
        let metadata = KeepAwakeHookContract.metadata(source: "codex-cli", input: hook("PreCompact"))
        let taskID = try XCTUnwrap(metadata.taskID)
        XCTAssertEqual(taskID.utf8.count, 85)
        XCTAssertTrue(taskID.hasPrefix("aux.codex.compaction."))
        XCTAssertFalse(taskID.contains("PRIVATE-TURN-A"))
        for source in sources {
            XCTAssertTrue(KeepAwakeHookContract.isAuxiliaryTask(source: source, taskID: taskID))
        }
        XCTAssertFalse(KeepAwakeHookContract.isAuxiliaryTask(source: "pi", taskID: taskID))
        XCTAssertFalse(KeepAwakeHookContract.isAuxiliaryTask(source: "claude-code", taskID: taskID))
        for invalid: String? in [nil, "", "aux.codex.compaction.", taskID + "a",
                                "aux.codex.compaction." + String(repeating: "A", count: 64),
                                "aux.codex.compaction." + String(repeating: "g", count: 64),
                                KeepAwakeHookContract.anonymousIdentity("PRIVATE-TURN-A")] {
            XCTAssertFalse(KeepAwakeHookContract.isAuxiliaryTask(source: "codex-cli", taskID: invalid))
        }
        func bytes(_ identifier: String) -> Data {
            KeepAwakeHookContract.authenticatedBytes(generation: "generation", source: "codex-cli",
                session: "session", sequence: 1, state: "completed", issuedAt: 1,
                taskID: identifier, startsTask: false)
        }
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        let mac = HMAC<SHA256>.authenticationCode(for: bytes(taskID), using: key)
        XCTAssertFalse(HMAC<SHA256>.isValidAuthenticationCode(mac,
            authenticating: bytes(String(taskID.dropFirst("aux.codex.compaction.".count))), using: key))
        let root = try XCTUnwrap(KeepAwakeHookContract.codexNotification(notification()))
        XCTAssertEqual(root.metadata.taskID?.count, 64)
        XCTAssertFalse(KeepAwakeHookContract.isAuxiliaryTask(source: "codex-cli", taskID: root.metadata.taskID))
    }
    func testCompactionCannotCompleteItsParentAndMissingEndKeepsHolding() throws {
        let source = "codex-cli"
        let parent = KeepAwakeHookContract.metadata(source: source, input: hook("UserPromptSubmit"))
        let before = KeepAwakeHookContract.metadata(source: source, input: hook("PreCompact"))
        let after = KeepAwakeHookContract.metadata(source: source, input: hook("PostCompact"))
        XCTAssertNotEqual(parent.taskID, before.taskID)
        XCTAssertEqual(before.taskID, after.taskID)
        XCTAssertTrue(before.startsTask)
        XCTAssertFalse(after.startsTask)
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: hook("PreCompact")), "running")
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: hook("PostCompact")), "completed")
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: hook("PostCompact", turn: NSNull())), "idle")
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        let environment = KeepAwakeEngine.Environment(hardware: .desktop)
        let session = KeepAwakeHookContract.anonymousIdentity("PRIVATE-THREAD")
        engine.receive(.init(source: source, session: session, sequence: 1, state: .running,
            taskID: parent.taskID, startsTask: parent.startsTask), now: 0)
        engine.receive(.init(source: source, session: session, sequence: 2, state: .running,
            taskID: before.taskID, startsTask: before.startsTask), now: 1)
        engine.receive(.init(source: source, session: session, sequence: 3, state: .completed,
            taskID: after.taskID, startsTask: after.startsTask), now: 2)
        XCTAssertTrue(engine.evaluate(now: 100, environment: environment).hold, "compaction end cannot finish the parent")
        let completion = try XCTUnwrap(KeepAwakeHookContract.codexNotification(notification()))
        engine.receive(.init(source: source, session: session, sequence: 4, state: .completed,
            taskID: completion.metadata.taskID, startsTask: false), now: 101)
        // Optional post-turn compaction follows notify, and may repeat within
        // this turn. Its explicit start is allowed to reopen only its own key.
        engine.receive(.init(source: source, session: session, sequence: 5, state: .running,
            taskID: before.taskID, startsTask: before.startsTask), now: 102)
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold)
        engine.receive(.init(source: source, session: session, sequence: 6, state: .completed,
            taskID: after.taskID, startsTask: after.startsTask), now: 10_001)
        XCTAssertTrue(engine.evaluate(now: 10_030, environment: environment).hold)
        XCTAssertFalse(engine.evaluate(now: 10_031, environment: environment).hold)
    }
    func testNotifyToolRejectsNonCLISelectionAndMalformedArgvWithoutHookOutput() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        for args in [["--superisland-ka1-codex-notify", "codex-desktop", "/absent", "{}"],
                     ["--superisland-ka1-codex-notify", "codex-cli", "/absent"],
                     ["--superisland-ka1-codex-notify", "claude-code", "/absent", "{}"],
                     ["--superisland-ka1-codex-notify-auto", "/absent", "{}"],
                     ["--superisland-ka1-codex-notify-auto", "/absent"]] {
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = args
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }
    func testNotifyForwardPreservesOriginalProcessAndOpaqueCallbackDespiteMissingReceipt() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KA1NotifyForward-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalArguments = ["", "with spaces", "quote'\"", "中文\nsecond line"]
        let payload = "{ \"type\": \"agent-turn-complete\", \"thread-id\": \"fixture\", \"text\": \"原样\\n内容\" }"
        let script = "printf '%s\\0' \"$$\" \"$PPID\" \"$(pwd -P)\" \"$KA1_FORWARD_FIXTURE\" \"$@\"; printf 'fixture-stderr' >&2; exit 37"
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = [KeepAwakeHookContract.codexNotifyForwardMode, directory.appendingPathComponent("missing-receipt").path,
            "--", "/bin/sh", "-c", script, "fixture"] + originalArguments + [payload]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(["KA1_FORWARD_FIXTURE": "environment-preserved"]) { _, new in new }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        try process.run(); let pid = process.processIdentifier; process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 37)
        let records = output.fileHandleForReading.readDataToEndOfFile().split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(records.count, 4 + originalArguments.count + 1)
        guard records.count == 4 + originalArguments.count + 1 else { return }
        XCTAssertEqual(Array(records.prefix(2)), [String(pid), String(ProcessInfo.processInfo.processIdentifier)])
        // macOS may expose the same temporary directory as /var or /private/var.
        // Verify filesystem identity instead of requiring a particular alias.
        var actualDirectory = stat(), expectedDirectory = stat()
        XCTAssertEqual(stat(records[2], &actualDirectory), 0)
        XCTAssertEqual(stat(directory.path, &expectedDirectory), 0)
        XCTAssertEqual(actualDirectory.st_dev, expectedDirectory.st_dev)
        XCTAssertEqual(actualDirectory.st_ino, expectedDirectory.st_ino)
        XCTAssertEqual(Array(records.dropFirst(3)), ["environment-preserved"] + originalArguments + [payload])
        XCTAssertEqual(errors.fileHandleForReading.readDataToEndOfFile(), Data("fixture-stderr".utf8))
    }
    func testNotifyForwardRejectsIllegalDelegateOrExecFailureWithoutOutput() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        let mode = KeepAwakeHookContract.codexNotifyForwardMode
        for args in [[mode, "/absent", "--", "{}"], [mode, "/absent", "bad-marker", "/bin/echo", "{}"],
                     [mode, "/absent", "--", executable.path, "{}"],
                     [mode, "/absent", "--", "/bin/sh", "-c", "echo --superisland-ka1", "{}"],
                     [mode, "/absent", "--", "/absent/KA1OriginalNotify", "{}"]] {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = executable; process.arguments = args
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 127)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }
}
