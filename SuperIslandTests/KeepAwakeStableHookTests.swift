import XCTest
import CryptoKit
import Darwin
@testable import SuperIsland

final class KeepAwakeStableHookTests: XCTestCase {
    func testWorkBuddyManagedPTYNeedsItsOwnNonTerminalHost() {
        typealias A = KeepAwakeHookContract.DesktopAncestor
        let root = "/Applications/WorkBuddy.app", id = "com.tencent.workbuddy.mac"
        let shell = A(bundleID: nil, appRoot: nil, hasTerminal: true, role: .shell)
        let server = A(bundleID: id, appRoot: root, hasTerminal: true, role: .workBuddyServer)
        let host = A(bundleID: id, appRoot: root, hasTerminal: false, role: .other)
        XCTAssertTrue(KeepAwakeHookContract.acceptsDesktopParent(source: "workbuddy-desktop", ancestors: [shell, server, host]))
        XCTAssertTrue(KeepAwakeHookContract.acceptsDesktopParent(source: "workbuddy-desktop", ancestors: [server, host]))
        for chain in [[server], [server, server, host], [shell],
                      [server, A(bundleID: id, appRoot: "/Other/WorkBuddy.app", hasTerminal: false, role: .other)],
                      [server, A(bundleID: id, appRoot: root, hasTerminal: true, role: .other)],
                      [A(bundleID: id, appRoot: root, hasTerminal: false, role: .independentCLI), host],
                      [A(bundleID: nil, appRoot: nil, hasTerminal: true, role: .other), server, host]] {
            XCTAssertFalse(KeepAwakeHookContract.acceptsDesktopParent(source: "workbuddy-desktop", ancestors: chain))
        }
        for source in ["qoder-desktop", "zcode-desktop", "workbuddy-cli", "unknown"] {
            XCTAssertFalse(KeepAwakeHookContract.acceptsDesktopParent(source: source, ancestors: [shell, server, host]))
        }
    }
    func testWorkBuddyRoleUsesBundledServePrefixNotPromptOrVersion() {
        let root = "/Applications/WorkBuddy.app", executable = root + "/Contents/MacOS/Electron"
        let entry = root + "/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
        XCTAssertEqual(KeepAwakeHookContract.desktopProcessRole(executable: executable, appRoot: root,
            arguments: [executable, entry, "--serve", "PRIVATE-ARGS-IGNORED"]), .workBuddyServer)
        XCTAssertEqual(KeepAwakeHookContract.desktopProcessRole(executable: executable, appRoot: root,
            arguments: [executable, entry, "--print", "--serve"]), .independentCLI)
        XCTAssertEqual(KeepAwakeHookContract.desktopProcessRole(executable: executable, appRoot: root,
            arguments: [executable, "/external/cli/bin/codebuddy", "--serve"]), .independentCLI)
        XCTAssertEqual(KeepAwakeHookContract.desktopProcessRole(executable: executable, appRoot: nil,
            arguments: [executable, entry, "--serve"]), .independentCLI)
        XCTAssertEqual(KeepAwakeHookContract.desktopProcessRole(executable: "/bin/zsh", appRoot: nil,
            arguments: ["/bin/zsh", "-c", "PRIVATE-COMMAND"]), .shell)
    }
    private func payload(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        var input: [String: Any] = ["session_id": "opaque-session", "hook_event_name": event]
        input.merge(extra) { _, value in value }
        return input
    }
    func testStopRemainsUnverifiedEvenWhenAnotherHookIsAlreadyContinuing() {
        for source in KeepAwakeHookContract.sources + ["claude-code", "codex-cli", "codex-desktop"] {
            for active in [false, true] {
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                    input: payload("Stop", extra: ["stop_hook_active": active])), "idle", source)
            }
        }
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: "gemini-cli", input: payload("AfterAgent")), "idle")
    }
    func testToolInterruptionNeverCancelsParentTask() {
        for source in KeepAwakeHookContract.sources + ["claude-code"] {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                input: payload("PostToolUseFailure", extra: ["is_interrupt": true])), "running", source)
        }
    }
    func testOnlyDocumentedWholeTurnFailuresAreTerminal() {
        for source in ["qoder-desktop", "workbuddy-desktop", "claude-code"] {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                input: payload("StopFailure", extra: ["error_type": "server_error", "generation_id": "opaque-turn"])),
                source == "workbuddy-desktop" ? "failed" : "idle", source)
            for fields: [String: Any] in [[:], ["error_type": "unknown"], ["error_type": "hook_error"], ["error": "private error text"]] {
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                    input: payload("StopFailure", extra: fields)), "idle", source)
            }
        }
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: "zcode-desktop",
            input: payload("StopFailure", extra: ["error_type": "server_error"])), "idle")
    }
    func testSessionSwitchOrUnknownEndCannotCancelLongTask() {
        for source in ["qoder-desktop", "workbuddy-desktop", "claude-code", "gemini-cli"] {
            for reason in ["clear", "logout", "prompt_input_exit"] {
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                    input: payload("SessionEnd", extra: ["reason": reason, "generation_id": "opaque-turn"])),
                    source == "workbuddy-desktop" ? "cancelled" : "idle", source)
            }
            for reason in ["resume", "other", "new-vendor-reason"] {
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                    input: payload("SessionEnd", extra: ["reason": reason])), "idle", source)
            }
        }
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: "zcode-desktop",
            input: payload("SessionEnd", extra: ["reason": "clear"])), "idle")
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: "gemini-cli",
            input: payload("SessionEnd", extra: ["reason": "exit"])), "idle")
    }
    func testOnlyVerifiedPiSettlementMappingCanClaimCompletion() {
        let ownedRound = UUID().uuidString
        for state in ["completed", "cancelled"] {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: "pi",
                input: payload(state, extra: ["ka1_task_id": ownedRound])), state)
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: "pi", input: payload(state)), "idle")
        }
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: "opencode", input: payload("completed")), "idle")
        for source in ["pi", "opencode"] {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: payload("failed")), "idle")
        }
        for source in KeepAwakeHookContract.sources {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                input: payload("Notification", extra: ["notification_type": "agent_completed"])), "idle")
            XCTAssertNil(KeepAwakeHookContract.eventState(source: source, input: payload("SubagentStop")))
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source, input: payload("FinalStop")), source == "workbuddy-desktop" ? "idle" : nil)
        }
    }
    private func workBuddy(_ event: String, generation: String = "round", actor: String = "actor", role: String? = "main") -> [String: Any] {
        var input = payload(event, extra: ["generation_id": generation, "agent_id": actor,
            "final_stop_reason": "completed", "is_truncation_recovery": false, "tool_name": "Bash"])
        if let role { input["agent_type"] = role }
        return input
    }
    func testWorkBuddyFinalStopNeedsStartedActorAndRoleAndKeepsThirtySecondGrace() throws {
        try withHome { home in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let proof = KeepAwakeWorkBuddyTurnProof(credential: home.appendingPathComponent("credential"))
            var engine = KeepAwakeEngine(); engine.setAutomatic(true)
            var sequence: UInt64 = 0
            func deliver(_ input: [String: Any], at time: Double) throws {
                let verified = try proof.observe(input)
                let state = try XCTUnwrap(KeepAwakeHookContract.eventState(source: "workbuddy-desktop", input: input,
                    verifiedWorkBuddyTurn: verified).flatMap(KeepAwakeEngine.TaskState.init(rawValue:)))
                let metadata = KeepAwakeHookContract.metadata(source: "workbuddy-desktop", input: input)
                sequence += 1
                XCTAssertTrue(engine.receive(.init(source: "workbuddy-desktop", session: "anonymous", sequence: sequence,
                    state: state, taskID: metadata.taskID, startsTask: metadata.startsTask), now: time))
            }
            XCTAssertFalse(try proof.observe(workBuddy("FinalStop")))
            try deliver(workBuddy("UserPromptSubmit", role: nil), at: 0)
            try deliver(workBuddy("PreToolUse"), at: 2)
            try deliver(workBuddy("Stop"), at: 60)
            XCTAssertTrue(engine.evaluate(now: 600, environment: .init(hardware: .desktop)).hold)
            try deliver(workBuddy("FinalStop"), at: 601)
            XCTAssertTrue(engine.evaluate(now: 630.999, environment: .init(hardware: .desktop)).hold)
            XCTAssertFalse(engine.evaluate(now: 631, environment: .init(hardware: .desktop)).hold)
            XCTAssertFalse(engine.sessions.values.contains(where: \.isUnfinished))
            _ = try proof.observe(workBuddy("FinalStop"), finished: true)
            XCTAssertFalse(try proof.observe(workBuddy("FinalStop")))
            let bytes = try String(contentsOf: proof.url)
            XCTAssertFalse(bytes.contains("opaque-session")); XCTAssertFalse(bytes.contains("\"actor\":\"actor\""))
        }
    }
    func testWorkBuddyFinalStopRejectsOtherActorsRolesTurnsAndUncertainReasons() throws {
        try withHome { home in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let proof = KeepAwakeWorkBuddyTurnProof(credential: home.appendingPathComponent("credential"))
            _ = try proof.observe(workBuddy("UserPromptSubmit"))
            for input in [workBuddy("FinalStop", actor: "child"), workBuddy("FinalStop", role: "compact"),
                          workBuddy("FinalStop", role: nil), workBuddy("FinalStop", generation: "next")] {
                XCTAssertFalse(try proof.observe(input))
            }
            for (reason, expected) in [("completed", "completed"), ("interrupted", "cancelled"), ("cancelled", "cancelled"), ("failed", "failed"), ("unknown", "idle")] {
                var input = workBuddy("FinalStop"); input["final_stop_reason"] = reason
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: "workbuddy-desktop", input: input,
                    verifiedWorkBuddyTurn: try proof.observe(input)), expected)
            }
            for invalid: Any in [true, 0, "false", NSNull()] {
                var input = workBuddy("FinalStop"); input["is_truncation_recovery"] = invalid
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: "workbuddy-desktop", input: input, verifiedWorkBuddyTurn: true), "idle")
            }
            var missing = workBuddy("FinalStop"); missing.removeValue(forKey: "is_truncation_recovery")
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: "workbuddy-desktop", input: missing, verifiedWorkBuddyTurn: true), "idle")
            for source in ["zcode-desktop", "qoder-desktop", "codex-desktop", "claude-code"] {
                XCTAssertNil(KeepAwakeHookContract.eventState(source: source, input: workBuddy("FinalStop"), verifiedWorkBuddyTurn: true))
            }
        }
    }
    func testWorkBuddyCompactionAndPostCompactNeverProveWholeTaskCompletion() throws {
        try withHome { home in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let credential = home.appendingPathComponent("credential")
            let proof = KeepAwakeWorkBuddyTurnProof(credential: credential)
            _ = try proof.observe(workBuddy("UserPromptSubmit"))
            for event in ["PreCompact", "PostCompact"] {
                XCTAssertFalse(try proof.observe(workBuddy(event)))
                XCTAssertNil(KeepAwakeHookContract.eventState(source: "workbuddy-desktop", input: workBuddy(event)))
            }
            // New tool activity or a duplicated start cannot erase a compact
            // boundary. The current vendor contract lacks final settlement proof.
            for event in ["PreToolUse", "UserPromptSubmit", "Stop", "FinalStop"] {
                XCTAssertFalse(try KeepAwakeWorkBuddyTurnProof(credential: credential).observe(workBuddy(event)))
            }
            XCTAssertTrue(try proof.observe(workBuddy("UserPromptSubmit", generation: "next")))
            XCTAssertTrue(try proof.observe(workBuddy("FinalStop", generation: "next")))
        }
    }
    func testWorkBuddyCompactionBeforeDelayedAdmissionKeepsItsTombstone() throws {
        try withHome { home in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            for compact in ["PreCompact", "PostCompact"] {
                let proof = KeepAwakeWorkBuddyTurnProof(credential: home.appendingPathComponent(compact))
                XCTAssertFalse(try proof.observe(workBuddy(compact)))
                XCTAssertFalse(try proof.observe(workBuddy("UserPromptSubmit")))
                XCTAssertFalse(try proof.observe(workBuddy("PreToolUse")))
                XCTAssertFalse(try proof.observe(workBuddy("FinalStop")))
            }
        }
    }
    func testWorkBuddyFinalVerificationAndDeliveryAreSerializedWithCompaction() throws {
        try withHome { home in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let proof = KeepAwakeWorkBuddyTurnProof(credential: home.appendingPathComponent("credential"))
            _ = try proof.observe(workBuddy("UserPromptSubmit"))
            XCTAssertTrue(try proof.observe(workBuddy("FinalStop"), delivery: { verified in
                XCTAssertTrue(verified)
                let fd = open(proof.url.appendingPathExtension("lock").path, O_RDWR | O_NOFOLLOW)
                XCTAssertGreaterThanOrEqual(fd, 0)
                defer { close(fd) }
                XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1, "another hook cannot mutate admission before terminal enqueue")
                return true
            }))
            XCTAssertFalse(try proof.observe(workBuddy("FinalStop")))
        }
    }
    func testWorkBuddyMissingIdentityStillDeliversUnverifiedRunningWork() throws {
        try withHome { home in
            var input = workBuddy("UserPromptSubmit"); input.removeValue(forKey: "generation_id")
            var called = false
            let proof = KeepAwakeWorkBuddyTurnProof(credential: home.appendingPathComponent("credential"))
            XCTAssertFalse(try proof.observe(input, delivery: { verified in
                called = true; XCTAssertFalse(verified)
                XCTAssertEqual(KeepAwakeHookContract.eventState(source: "workbuddy-desktop", input: input,
                    verifiedWorkBuddyTurn: verified), "running")
                return false
            }))
            XCTAssertTrue(called)
        }
    }
    func testWorkBuddyOverflowRemainsFailClosedWithoutRepeatedWrites() throws {
        try withHome { home in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let proof = KeepAwakeWorkBuddyTurnProof(credential: home.appendingPathComponent("credential"))
            let data = Data("{\"version\":1,\"turns\":{},\"overflowed\":true}".utf8)
            try data.write(to: proof.url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proof.url.path)
            let inode = try FileManager.default.attributesOfItem(atPath: proof.url.path)[.systemFileNumber] as? NSNumber
            for event in ["UserPromptSubmit", "PreToolUse", "Stop", "FinalStop"] {
                XCTAssertFalse(try proof.observe(workBuddy(event)))
            }
            XCTAssertEqual(try Data(contentsOf: proof.url), data)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: proof.url.path)[.systemFileNumber] as? NSNumber, inode)
        }
    }
    func testOnlyWorkBuddyPublicGenerationCanIdentifyDesktopRound() {
        let raw = "PRIVATE-VENDOR-GENERATION"
        let start = payload("UserPromptSubmit", extra: ["generation_id": raw])
        let update = payload("PostToolUse", extra: ["generation_id": raw])
        let first = KeepAwakeHookContract.metadata(source: "workbuddy-desktop", input: start)
        let next = KeepAwakeHookContract.metadata(source: "workbuddy-desktop", input: update)
        XCTAssertEqual(first.taskID, next.taskID)
        XCTAssertEqual(first.taskID?.count, 64)
        XCTAssertNotEqual(first.taskID, raw)
        XCTAssertTrue(first.startsTask)
        XCTAssertFalse(next.startsTask)
        XCTAssertNotEqual(first.taskID, KeepAwakeHookContract.metadata(source: "workbuddy-desktop",
            input: payload("UserPromptSubmit", extra: ["generation_id": "another-round"])).taskID)
        for source in ["qoder-desktop", "zcode-desktop", "claude-code", "gemini-cli", "workbuddy-cli"] {
            XCTAssertNil(KeepAwakeHookContract.metadata(source: source, input: start).taskID)
        }
        for value: Any in ["", String(repeating: "x", count: 1025), 123, NSNull()] {
            XCTAssertNil(KeepAwakeHookContract.metadata(source: "workbuddy-desktop",
                input: payload("StopFailure", extra: ["generation_id": value])).taskID)
        }
    }
    func testActivityReportsCannotPretendToStartANewRound() {
        for source in KeepAwakeHookContract.sources + ["claude-code", "codex-cli", "codex-desktop", "gemini-cli"] {
            for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "ElicitationResult", "Stop", "SessionStart"] {
                XCTAssertFalse(KeepAwakeHookContract.metadata(source: source, input: payload(event)).startsTask, source + event)
            }
        }
        XCTAssertTrue(KeepAwakeHookContract.metadata(source: "gemini-cli", input: payload("BeforeAgent")).startsTask)
        XCTAssertFalse(KeepAwakeHookContract.metadata(source: "workbuddy-desktop",
            input: payload("UserPromptSubmit", extra: ["is_internal_continuation": true])).startsTask)
        for source in ["pi", "opencode"] {
            XCTAssertFalse(KeepAwakeHookContract.metadata(source: source, input: payload("running")).startsTask)
            XCTAssertTrue(KeepAwakeHookContract.metadata(source: source, input: payload("running", extra: ["task_start": true])).startsTask)
            for invalid: Any in [1, "true", NSNull()] {
                XCTAssertFalse(KeepAwakeHookContract.metadata(source: source,
                    input: payload("running", extra: ["task_start": invalid])).startsTask)
            }
            XCTAssertFalse(KeepAwakeHookContract.metadata(source: source, input: payload("completed", extra: ["task_start": true])).startsTask)
        }
    }
    func testZCodeNativeTurnIdentitySeparatesRoundsWithoutInventingCompletion() throws {
        let raw = "PRIVATE-ZCODE-TURN"
        let start = payload("UserPromptSubmit", extra: ["turnId": raw])
        let metadata = KeepAwakeHookContract.metadata(source: "zcode-desktop", input: start)
        XCTAssertEqual(metadata.taskID, KeepAwakeHookContract.anonymousIdentity(raw))
        XCTAssertTrue(metadata.startsTask)
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Stop"] {
            let input = payload(event, extra: ["turnId": raw, "tool_name": "Bash"])
            XCTAssertEqual(KeepAwakeHookContract.metadata(source: "zcode-desktop", input: input).taskID, metadata.taskID)
            XCTAssertFalse(KeepAwakeHookContract.metadata(source: "zcode-desktop", input: input).startsTask)
        }
        XCTAssertNotEqual(metadata.taskID, KeepAwakeHookContract.metadata(source: "zcode-desktop",
            input: payload("UserPromptSubmit", extra: ["turnId": "another-turn"])).taskID)
        for invalid: Any in ["", "  ", "turn\nidentity", String(repeating: "x", count: 1025), 1, NSNull()] {
            XCTAssertNil(KeepAwakeHookContract.metadata(source: "zcode-desktop",
                input: payload("Stop", extra: ["turnId": invalid])).taskID)
        }
        for source in ["workbuddy-desktop", "qoder-desktop", "claude-code", "codex-desktop"] {
            XCTAssertNil(KeepAwakeHookContract.metadata(source: source, input: start).taskID)
        }
        XCTAssertEqual(KeepAwakeHookContract.eventState(source: "zcode-desktop",
            input: payload("Stop", extra: ["turnId": raw, "stop_hook_active": true])), "idle")
    }
    func testOwnedPiRoundIdentityIsHashedAndNeverAcceptedForAnotherSource() {
        let raw = UUID().uuidString
        let start = payload("running", extra: ["ka1_task_id": raw, "task_start": true])
        let end = payload("completed", extra: ["ka1_task_id": raw])
        let metadata = KeepAwakeHookContract.metadata(source: "pi", input: start)
        XCTAssertEqual(metadata.taskID?.count, 64)
        XCTAssertNotEqual(metadata.taskID, raw)
        XCTAssertEqual(metadata.taskID, KeepAwakeHookContract.metadata(source: "pi", input: end).taskID)
        XCTAssertTrue(metadata.startsTask)
        XCTAssertFalse(KeepAwakeHookContract.metadata(source: "pi", input: end).startsTask)
        XCTAssertNil(KeepAwakeHookContract.metadata(source: "opencode", input: start).taskID)
        XCTAssertNil(KeepAwakeHookContract.metadata(source: "workbuddy-desktop", input: start).taskID)
        XCTAssertNil(KeepAwakeHookContract.metadata(source: "pi", input: payload("completed", extra: ["ka1_task_id": "arbitrary"])).taskID)
    }
    func testDesktopTerminalWithoutCurrentRoundIdentityStaysUnverified() {
        for source in KeepAwakeHookContract.sources + ["claude-code", "gemini-cli"] {
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                input: payload("StopFailure", extra: ["error_type": "server_error"])), source == "gemini-cli" ? nil : "idle")
            XCTAssertEqual(KeepAwakeHookContract.eventState(source: source,
                input: payload("SessionEnd", extra: ["reason": "clear"])), "idle")
        }
    }
    func testLegacySignatureBytesRemainUnchangedAndNewMetadataIsAuthenticated() {
        let legacy = Data(["generation", "claude-code", "opaque-session", "7", "running", "100.0"].joined(separator: "\n").utf8)
        let old = KeepAwakeHookContract.authenticatedBytes(generation: "generation", source: "claude-code", session: "opaque-session",
            sequence: 7, state: "running", issuedAt: 100, taskID: nil, startsTask: nil)
        XCTAssertEqual(old, legacy)
        let variants: [(String?, Bool?)] = [(nil, true), (nil, false), ("round-A", nil), ("round-A", true), ("round-A", false), ("round-B", true)]
        let values = variants.map { KeepAwakeHookContract.authenticatedBytes(generation: "generation", source: "claude-code", session: "opaque-session",
            sequence: 7, state: "running", issuedAt: 100, taskID: $0.0, startsTask: $0.1) }
        XCTAssertTrue(values.allSatisfy { $0 != legacy })
        XCTAssertEqual(Set(values).count, variants.count)
    }
    func testMailboxAcceptsLegacyAndRejectsUnsignedMetadataOrTampering() throws {
        try withHome { home in
            var mailbox = KeepAwakeMailbox(root: home)
            try mailbox.connect(source: "claude-code")
            let credential = try XCTUnwrap(mailbox.credentials["claude-code"])
            func signed(taskID: String?, startsTask: Bool?) throws -> [String: Any] {
                let event = KeepAwakeEngine.Event(source: "claude-code", session: "opaque-session", sequence: 7,
                    state: .running, taskID: taskID, startsTask: startsTask)
                var envelope = KeepAwakeMailbox.Envelope(generation: credential.generation, event: event, issuedAt: 100, mac: "")
                envelope.mac = Data(HMAC<SHA256>.authenticationCode(for: envelope.authenticatedBytes,
                    using: SymmetricKey(data: Data(base64Encoded: credential.key)!))).base64EncodedString()
                return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
            }
            func deliver(_ value: [String: Any]) throws -> [KeepAwakeEngine.Event] {
                try JSONSerialization.data(withJSONObject: value).write(to: mailbox.inbox.appendingPathComponent(UUID().uuidString + ".json"))
                return mailbox.read(now: 100)
            }
            let legacy = try signed(taskID: nil, startsTask: nil)
            let oldEvent = try XCTUnwrap(deliver(legacy).first)
            XCTAssertNil(oldEvent.taskID); XCTAssertNil(oldEvent.startsTask)
            let current = try signed(taskID: "round-A", startsTask: true)
            let accepted = try XCTUnwrap(deliver(current).first)
            XCTAssertEqual(accepted.taskID, "round-A"); XCTAssertEqual(accepted.startsTask, true)
            for change: [String: Any] in [["taskID": "round-B"], ["startsTask": false], ["startsTask": NSNull()], ["taskID": NSNull()]] {
                var value = current, event = try XCTUnwrap(current["event"] as? [String: Any])
                event.merge(change) { _, next in next }; value["event"] = event
                XCTAssertTrue(try deliver(value).isEmpty)
            }
            for field in ["taskID", "startsTask"] {
                var value = current, event = try XCTUnwrap(current["event"] as? [String: Any])
                event.removeValue(forKey: field); value["event"] = event
                XCTAssertTrue(try deliver(value).isEmpty)
            }
            for change: [String: Any] in [["taskID": "round-A"], ["startsTask": true], ["startsTask": false], ["taskID": NSNull()], ["startsTask": 1]] {
                var value = legacy, event = try XCTUnwrap(legacy["event"] as? [String: Any])
                event.merge(change) { _, next in next }; value["event"] = event
                XCTAssertTrue(try deliver(value).isEmpty)
            }
        }
    }
    func testRealEventToolAlwaysSignsStartMetadataAndDoesNotLeakVendorIdentity() throws {
        try withHome { home in
            var mailbox = KeepAwakeMailbox(root: home); try mailbox.connect(source: "claude-code")
            for (event, expectedStart) in [("UserPromptSubmit", true), ("PostToolUse", false), ("Stop", false)] {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
                process.arguments = ["--superisland-ka1", "claude-code", mailbox.credentialsDirectory.appendingPathComponent("claude-code.json").path]
                process.standardInput = input; process.standardOutput = output
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject:
                    payload(event, extra: ["generation_id": "PRIVATE-GENERATION", "prompt": "PRIVATE-PROMPT"])))
                try input.fileHandleForWriting.close(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
                let files = try FileManager.default.contentsOfDirectory(at: mailbox.inbox, includingPropertiesForKeys: nil)
                XCTAssertEqual(files.count, 1)
                let raw = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
                XCTAssertFalse(raw.contains("PRIVATE-GENERATION")); XCTAssertFalse(raw.contains("PRIVATE-PROMPT"))
                let delivered = try XCTUnwrap(mailbox.read().first)
                XCTAssertEqual(delivered.startsTask, expectedStart)
                XCTAssertNil(delivered.taskID)
            }
        }
    }
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("KA1StableHooks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }
    private var zcode: KeepAwakeSource {
        .init(id: "zcode-desktop", name: "ZCode", integration: "test", hookFamily: "zcode")
    }
    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testZCodeUsesItsOwnSchemaAndPreservesDisabledTrustAndOtherHooks() throws {
        try withHome { home in
            let path = KeepAwakeHookInstaller.path(source: zcode, home: home)
            XCTAssertEqual(path.path, home.appendingPathComponent(".zcode/cli/config.json").path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let originalAction: [String: Any] = ["type": "process", "command": "/usr/bin/true", "args": ["original"], "enabled": true]
            let otherSource: [String: Any] = ["type": "process", "command": "/usr/bin/true",
                "args": [KeepAwakeHookInstaller.marker, "other-desktop", "/private/credential"]]
            let original: [String: Any] = ["theme": "preserve", "hooks": ["enabled": false, "timeoutMs": 9000,
                "events": ["Stop": [["matcher": "", "hooks": [originalAction, otherSource]]], "VendorEvent": []]]]
            let originalBytes = try JSONSerialization.data(withJSONObject: original)
            try originalBytes.write(to: path)
            let executable = URL(fileURLWithPath: "/usr/bin/true")
            for _ in 0..<2 { try KeepAwakeHookInstaller.install(source: zcode, credential: home.appendingPathComponent("credential"), home: home, executable: executable) }
            let root = try read(path), hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
            XCTAssertEqual(root["theme"] as? String, "preserve")
            XCTAssertEqual(hooks["enabled"] as? Bool, false)
            XCTAssertEqual(hooks["timeoutMs"] as? Int, 9000)
            let events = try XCTUnwrap(hooks["events"] as? [String: Any])
            let stop = try XCTUnwrap(events["Stop"] as? [[String: Any]])
            XCTAssertEqual(stop.count, 2)
            let own = try XCTUnwrap((stop.last?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(own["type"] as? String, "process")
            XCTAssertEqual(own["args"] as? [String], [KeepAwakeHookInstaller.marker, zcode.id, home.appendingPathComponent("credential").path])
            XCTAssertEqual(own["timeoutMs"] as? Int, 5000)
            XCTAssertNil(events["FinalStop"])
            XCTAssertNil(events["SessionEnd"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
            let backups = try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
            XCTAssertEqual(backups.count, 1, "repeated install must be an idempotent merge")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), originalBytes)
            try KeepAwakeHookInstaller.uninstall(source: zcode, home: home)
            let restoredHooks = try XCTUnwrap(try read(path)["hooks"] as? [String: Any])
            XCTAssertEqual(restoredHooks["enabled"] as? Bool, false)
            let restoredEvents = try XCTUnwrap(restoredHooks["events"] as? [String: Any])
            let restoredStop = try XCTUnwrap(restoredEvents["Stop"] as? [[String: Any]])
            XCTAssertEqual(restoredStop.count, 1)
            XCTAssertEqual((restoredStop[0]["hooks"] as? [[String: Any]])?.count, 2)
            let once = try Data(contentsOf: path)
            try KeepAwakeHookInstaller.uninstall(source: zcode, home: home)
            XCTAssertEqual(try Data(contentsOf: path), once)
        }
    }
    func testZCodeMalformedEventsAreNeverOverwritten() throws {
        try withHome { home in
            let path = KeepAwakeHookInstaller.path(source: zcode, home: home)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            for invalid in ["{\"hooks\":{\"enabled\":false,\"events\":[]}}", "{\"hooks\":{\"enabled\":\"false\",\"events\":{}}}", "{\"hooks\":{\"enabled\":1,\"events\":{}}}", "{\"hooks\":{\"events\":{\"Stop\":false}}}"] {
                let bytes = Data(invalid.utf8); try bytes.write(to: path)
                XCTAssertThrowsError(try KeepAwakeHookInstaller.install(source: zcode, credential: home, home: home, executable: URL(fileURLWithPath: "/usr/bin/true")))
                XCTAssertEqual(try Data(contentsOf: path), bytes)
            }
        }
    }
    func testZCodeReinstallRepairsOwnedEmptyMatchersWithoutChangingOtherHooks() throws {
        try withHome { home in
            let path = KeepAwakeHookInstaller.path(source: zcode, home: home)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let other: [String: Any] = ["matcher": "Write|Edit", "hooks": [["type": "process", "command": "/usr/bin/true"]]]
            let old: [String: Any] = ["matcher": "", "hooks": [["type": "process", "command": "/old/tool",
                "args": [KeepAwakeHookInstaller.marker, zcode.id, "/old/credential"]]]]
            let original: [String: Any] = ["hooks": ["enabled": true, "events": ["PreToolUse": [other, old]]]]
            try JSONSerialization.data(withJSONObject: original).write(to: path)
            try KeepAwakeHookInstaller.install(source: zcode, credential: home.appendingPathComponent("credential"),
                                               home: home, executable: URL(fileURLWithPath: "/usr/bin/true"))
            let hooks = try XCTUnwrap(try read(path)["hooks"] as? [String: Any])
            let events = try XCTUnwrap(hooks["events"] as? [String: [[String: Any]]])
            for entries in events.values {
                for entry in entries {
                    if let matcher = entry["matcher"] as? String { XCTAssertFalse(matcher.isEmpty) }
                }
            }
            let preTool = try XCTUnwrap(events["PreToolUse"])
            XCTAssertEqual(preTool.count, 2)
            XCTAssertEqual(preTool.first?["matcher"] as? String, "Write|Edit")
            XCTAssertNil(preTool.last?["matcher"])
        }
    }
    func testUninstallWithNoConfigurationDoesNotCreateOne() throws {
        try withHome { home in
            try KeepAwakeHookInstaller.uninstall(source: zcode, home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: KeepAwakeHookInstaller.path(source: zcode, home: home).path))
        }
    }
}
