import XCTest
import CryptoKit
@testable import SuperIsland

final class KeepAwakeCodexContractTests: XCTestCase {
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
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-desktop", ancestors: [server]))
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-cli", ancestors: [host]))
        let fake = Ancestor(isCodex: true, isVerified: false, role: .cli, isDesktopHost: false)
        XCTAssertFalse(KeepAwakeHookContract.acceptsCodexParent(source: "codex-cli", ancestors: [fake, cli]))
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
                     ["--superisland-ka1-codex-notify", "claude-code", "/absent", "{}"]] {
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = args
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }
}
