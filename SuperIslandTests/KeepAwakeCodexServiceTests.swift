import XCTest
import CryptoKit
@testable import SuperIsland

/// Exercise real service scheduling with an injected metadata source. The
/// service remains disabled; policy decisions are evaluated on a local copy so
/// these fixtures never acquire a real power assertion or a helper lease.
final class KeepAwakeCodexServiceTests: XCTestCase {
    private actor ZCodeGate {
        var continuation: CheckedContinuation<[KeepAwakeZCodeTurnMetadataReader.Terminal], Never>?
        var requested = Set<KeepAwakeZCodeTurnMetadataReader.Identity>()
        func sample(_ identities: Set<KeepAwakeZCodeTurnMetadataReader.Identity>) async -> [KeepAwakeZCodeTurnMetadataReader.Terminal] {
            requested = identities
            return await withCheckedContinuation { continuation = $0 }
        }
        func isWaiting() -> Bool { continuation != nil }
        func finish(_ results: [KeepAwakeZCodeTurnMetadataReader.Terminal]) {
            continuation?.resume(returning: results); continuation = nil
        }
    }
    @MainActor private func zcodeFixture(gate: ZCodeGate) throws -> (UserDefaults, URL, KeepAwakeService) {
        let name = "KA1ZCodeService-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(["zcode-desktop"], forKey: "keepAwake.sources.v1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, hookUninstaller: { _ in },
            zcodeSampler: { await gate.sample($0) })
        service.start() // Remains disabled: no real power assertion is acquired.
        return (defaults, root, service)
    }
    @MainActor private func submitZCode(_ identity: KeepAwakeZCodeTurnMetadataReader.Identity, root: URL,
                                       service: KeepAwakeService) throws {
        let credential = try JSONDecoder().decode(KeepAwakeMailbox.Credential.self,
            from: Data(contentsOf: root.appendingPathComponent("credentials/zcode-desktop.json")))
        var envelope = KeepAwakeMailbox.Envelope(generation: credential.generation,
            event: .init(source: "zcode-desktop", session: identity.sessionHash, sequence: mach_continuous_time(),
                         state: .running, taskID: identity.taskHash, startsTask: true),
            issuedAt: Date().timeIntervalSince1970, mac: "")
        envelope.mac = Data(HMAC<SHA256>.authenticationCode(for: envelope.authenticatedBytes,
            using: SymmetricKey(data: Data(base64Encoded: credential.key)!))).base64EncodedString()
        try JSONEncoder().encode(envelope).write(to: root.appendingPathComponent("inbox/" + UUID().uuidString + ".json"))
        service.tick()
    }
    private func waitForZCode(_ gate: ZCodeGate) async {
        for _ in 0..<100 {
            if await gate.isWaiting() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Metadata sample did not begin")
    }
    @MainActor func testZCodeMetadataCompletesOnlyAdmittedExactTurnAndPreservesParallelTask() async throws {
        let gate = ZCodeGate(), (defaults, root, service) = try zcodeFixture(gate: gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let a = KeepAwakeZCodeTurnMetadataReader.Identity(sessionHash: String(repeating: "a", count: 64), taskHash: String(repeating: "1", count: 64))
        let b = KeepAwakeZCodeTurnMetadataReader.Identity(sessionHash: a.sessionHash, taskHash: String(repeating: "2", count: 64))
        try submitZCode(a, root: root, service: service)
        await waitForZCode(gate)
        try submitZCode(b, root: root, service: service)
        await gate.finish([.init(identity: a, state: "completed", startedAt: 1, completedAt: 2),
                           .init(identity: b, state: "completed", startedAt: 1, completedAt: 2)])
        for _ in 0..<100 {
            if service.engine.sessions.values.contains(where: { $0.event.taskID == a.taskHash && $0.event.state == .completed }) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.engine.sessions.values.first { $0.event.taskID == a.taskHash }?.event.state, .completed)
        XCTAssertTrue(service.engine.sessions.values.first { $0.event.taskID == b.taskHash }?.isUnfinished == true)
        assertNoRealHold(service)
    }
    @MainActor func testZCodeMetadataLateResultCannotRecreateDisconnectedTask() async throws {
        let gate = ZCodeGate(), (defaults, root, service) = try zcodeFixture(gate: gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let identity = KeepAwakeZCodeTurnMetadataReader.Identity(sessionHash: String(repeating: "a", count: 64), taskHash: String(repeating: "1", count: 64))
        try submitZCode(identity, root: root, service: service)
        await waitForZCode(gate)
        try service.disconnect(XCTUnwrap(KeepAwakeSource.all.first { $0.id == "zcode-desktop" }))
        await gate.finish([.init(identity: identity, state: "completed", startedAt: 1, completedAt: 2)])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(service.connections.contains("zcode-desktop"))
        XCTAssertFalse(service.engine.sessions.values.contains { $0.event.source == "zcode-desktop" })
        assertNoRealHold(service)
    }
    private actor CodexMetadataGate {
        var continuation: CheckedContinuation<[KeepAwakeCodexTurnMetadataReader.Terminal], Never>?
        var requested = Set<KeepAwakeCodexTurnMetadataReader.Identity>()
        func sample(_ database: URL, _ identities: Set<KeepAwakeCodexTurnMetadataReader.Identity>) async -> [KeepAwakeCodexTurnMetadataReader.Terminal] {
            requested = identities
            return await withCheckedContinuation { continuation = $0 }
        }
        func waiting() -> Bool { continuation != nil }
        func identities() -> Set<KeepAwakeCodexTurnMetadataReader.Identity> { requested }
        func finish(_ results: [KeepAwakeCodexTurnMetadataReader.Terminal]) { continuation?.resume(returning: results); continuation = nil }
    }
    @MainActor private func codexMetadataFixture(_ gate: CodexMetadataGate, home: URL? = nil, consent: Bool = true, chatConsent: Bool = false, chatSampler: (@Sendable (URL, Set<String>) async -> KeepAwakeCodexChatMetadata.Snapshot)? = nil) throws -> (UserDefaults, URL, KeepAwakeService) {
        let name = "KA1CodexMetadata-" + UUID().uuidString, root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(consent, forKey: KeepAwakeService.codexTurnMetadataConsentKey)
        defaults.set(chatConsent, forKey: KeepAwakeService.codexChatMetadataConsentKey)
        let profile = KeepAwakeCodexEnvironment.Profile(executableURL: root.appendingPathComponent("never-launched-codex"),
            codexHome: home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), socketURL: root.appendingPathComponent("never-used.sock"))
        let service = KeepAwakeService(defaults: defaults, root: root, codexResolver: { profile },
            codexHookInstaller: { _, _, _ in }, codexHookUninstaller: { _, _, _ in },
            codexMetadataSampler: { db, ids in await gate.sample(db, ids) }, chatMetadataSampler: chatSampler)
        service.start() // No saved real home: startup cannot edit external hooks.
        let source = try XCTUnwrap(KeepAwakeSource.all.first { $0.id == "codex-desktop" })
        try service.connect(source, codexConnection: .init(profile: profile, mode: .hooks))
        return (defaults, root, service)
    }
    @MainActor private func submitCodexMetadataTask(_ task: String = "task-a", source: String = "codex-desktop", state: KeepAwakeEngine.TaskState = .running,
                                                   root: URL, service: KeepAwakeService) throws {
        let credential = try JSONDecoder().decode(KeepAwakeMailbox.Credential.self,
            from: Data(contentsOf: root.appendingPathComponent("credentials/" + source + ".json")))
        var envelope = KeepAwakeMailbox.Envelope(generation: credential.generation,
            event: .init(source: source, session: KeepAwakeHookContract.anonymousIdentity("fixture-thread"), sequence: mach_continuous_time(),
                state: state, taskID: KeepAwakeHookContract.isAuxiliaryTask(source: source, taskID: task) ? task : KeepAwakeHookContract.anonymousIdentity(task), startsTask: state == .running),
            issuedAt: Date().timeIntervalSince1970, mac: "")
        envelope.mac = Data(HMAC<SHA256>.authenticationCode(for: envelope.authenticatedBytes,
            using: SymmetricKey(data: Data(base64Encoded: credential.key)!))).base64EncodedString()
        try JSONEncoder().encode(envelope).write(to: root.appendingPathComponent("inbox/" + UUID().uuidString + ".json")); service.tick()
    }
    private func codexIdentity(_ task: String = "task-a") -> KeepAwakeCodexTurnMetadataReader.Identity {
        .init(sessionHash: KeepAwakeHookContract.anonymousIdentity("fixture-thread"), taskHash: KeepAwakeHookContract.anonymousIdentity(task))
    }
    private func waitForCodexMetadata(_ gate: CodexMetadataGate) async {
        for _ in 0..<100 { if await gate.waiting() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Metadata query did not begin")
    }
    private actor ChatMetadataGate {
        var calls = 0
        var requested = Set<String>()
        var pending: CheckedContinuation<KeepAwakeCodexChatMetadata.Snapshot, Never>?
        func sample(_ sessions: Set<String>) async -> KeepAwakeCodexChatMetadata.Snapshot {
            calls += 1; requested = sessions
            return await withCheckedContinuation { pending = $0 }
        }
        func count() -> Int { calls }
        func waiting() -> Bool { pending != nil }
        func targets() -> Set<String> { requested }
        func finish(_ value: KeepAwakeCodexChatMetadata.Snapshot) { pending?.resume(returning: value); pending = nil }
    }
    @MainActor func testChatHierarchyIsNeverReadWithoutNewConsent() async throws {
        let terminal = CodexMetadataGate(), chat = ChatMetadataGate()
        let (defaults, root, service) = try codexMetadataFixture(terminal, chatSampler: { _, ids in await chat.sample(ids) })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(terminal)
        let calls = await chat.count(); XCTAssertEqual(calls, 0)
        await terminal.finish([]); assertNoRealHold(service)
    }
    @MainActor func testHierarchyMetadataCannotFinishTasksAndRevocationRejectsInFlightResult() async throws {
        let terminal = CodexMetadataGate(), chat = ChatMetadataGate()
        let (defaults, root, service) = try codexMetadataFixture(terminal, chatConsent: true, chatSampler: { _, ids in await chat.sample(ids) })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service)
        for _ in 0..<100 { if await chat.waiting() { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        let targets = await chat.targets(); XCTAssertEqual(targets, [codexIdentity().sessionHash])
        let before = service.engine.sessions
        service.setChatMetadataConsent(false)
        let id = codexIdentity().sessionHash
        await chat.finish(.init(nodes: [id:.init(session:id,parent:nil,root:id,title:"Private in-flight title")], titles:[id:"Private in-flight title"]))
        await terminal.finish([])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(service.engine.sessions, before)
        XCTAssertTrue(service.engine.sessions.values.allSatisfy { $0.isUnfinished })
        XCTAssertTrue(service.recap.ledger.current?.displayTitles.isEmpty ?? true)
        assertNoRealHold(service)
    }
    @MainActor func testFailedCodexMetadataEndsExactAdmittedTurnAndRetainsParallelWork() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(gate)
        try submitCodexMetadataTask("task-b", root: root, service: service)
        await gate.finish([.init(identity: codexIdentity(), state: "failed", startedAt: 1, completedAt: 2),
                           .init(identity: codexIdentity("task-b"), state: "completed", startedAt: 1, completedAt: 2)])
        _ = await waitUntil { service.engine.sessions.values.contains { $0.event.taskID == self.codexIdentity().taskHash && $0.event.state == .failed } }
        XCTAssertTrue(service.engine.sessions.values.first { $0.event.taskID == codexIdentity("task-b").taskHash }?.isUnfinished == true)
        assertNoRealHold(service)
    }
    @MainActor func testCodexMetadataFailureUsesNormalThirtySecondGrace() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(gate)
        await gate.finish([.init(identity: codexIdentity(), state: "failed", startedAt: 1, completedAt: 2)])
        _ = await waitUntil { service.engine.sessions.values.first?.event.state == .failed }
        let deadline = try XCTUnwrap(service.engine.sessions.values.first?.releaseAt)
        var engine = service.engine; engine.setAutomatic(true)
        let env = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true)
        XCTAssertTrue(engine.evaluate(now: deadline - 0.001, environment: env).hold)
        XCTAssertFalse(engine.evaluate(now: deadline, environment: env).hold)
        assertNoRealHold(service)
    }
    @MainActor func testNewHookActivityInvalidatesOldCodexMetadataResult() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(gate)
        try submitCodexMetadataTask(root: root, service: service)
        await gate.finish([.init(identity: codexIdentity(), state: "failed", startedAt: 1, completedAt: 2)])
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(service.engine.sessions.values.first?.isUnfinished == true); assertNoRealHold(service)
    }
    @MainActor func testDisconnectedCodexSourceRejectsLateMetadata() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(gate)
        try service.disconnect(XCTUnwrap(KeepAwakeSource.all.first { $0.id == "codex-desktop" }))
        await gate.finish([.init(identity: codexIdentity(), state: "failed", startedAt: 1, completedAt: 2)])
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(service.engine.sessions.isEmpty); assertNoRealHold(service)
    }
    @MainActor func testMainTurnTerminalDoesNotEndCompactionAuxiliary() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let auxiliary = try XCTUnwrap(KeepAwakeHookContract.metadata(source: "codex-desktop", input: ["hook_event_name": "PreCompact", "session_id": "fixture-thread", "turn_id": "fixture-compact"]).taskID)
        try submitCodexMetadataTask(auxiliary, root: root, service: service)
        let waiting = await gate.waiting(); XCTAssertFalse(waiting)
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(gate)
        let sampled = await gate.identities(); XCTAssertEqual(sampled, [codexIdentity()])
        await gate.finish([.init(identity: codexIdentity(), state: "failed", startedAt: 1, completedAt: 2)])
        _ = await waitUntil { service.engine.sessions.values.contains { $0.event.taskID == self.codexIdentity().taskHash && $0.event.state == .failed } }
        XCTAssertTrue(service.engine.sessions.values.first { $0.event.taskID == auxiliary }?.isUnfinished == true); assertNoRealHold(service)
    }
    @MainActor func testCodexMetadataQueryDoesNotFallBackFromAnotherHome() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate, home: URL(fileURLWithPath: "/fixture/other-codex-home"))
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let waiting = await gate.waiting(); XCTAssertFalse(waiting); XCTAssertTrue(service.engine.sessions.values.first?.isUnfinished == true); assertNoRealHold(service)
    }
    @MainActor func testExistingHookConnectionDoesNotImplyMetadataReadConsent() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate, consent: false)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let waiting = await gate.waiting(); XCTAssertFalse(waiting)
        XCTAssertTrue(service.engine.sessions.values.first?.isUnfinished == true); assertNoRealHold(service)
    }
    @MainActor func testRevokedConsentDiscardsInflightMetadataResult() async throws {
        let gate = CodexMetadataGate(), (defaults, root, service) = try codexMetadataFixture(gate)
        defer { service.shutdown(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        try submitCodexMetadataTask(root: root, service: service); await waitForCodexMetadata(gate)
        defaults.set(false, forKey: KeepAwakeService.codexTurnMetadataConsentKey)
        await gate.finish([.init(identity: codexIdentity(), state: "failed", startedAt: 1, completedAt: 2)])
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(service.engine.sessions.values.first?.isUnfinished == true); assertNoRealHold(service)
        defaults.set(true, forKey: KeepAwakeService.codexTurnMetadataConsentKey)
        try? await Task.sleep(nanoseconds: 5_100_000_000)
        service.tick(); await waitForCodexMetadata(gate)
        await gate.finish([])
    }

    @MainActor func testAppOwnedAcceptanceRecorderIsExplicitBoundedAndSurvivesCallerScope() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var wall: TimeInterval = 1000, continuous: TimeInterval = 20, awake: TimeInterval = 20
        let recorder = KeepAwakeAcceptanceRecorder(root: root, wall: { wall }, continuous: { continuous }, awake: { awake })
        recorder.poll(); recorder.append("fixture-no-request")
        XCTAssertTrue(try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        let request = KeepAwakeAcceptanceRecorder.Request(id: UUID(), expiresAt: 1300)
        try JSONEncoder().encode(request).write(to: recorder.requestURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.requestURL.path)
        recorder.poll()
        do { recorder.append("accepted-task-event", fields: ["source": "codex-desktop", "state": "completed"]) }
        wall += 31; continuous += 31; awake += 31
        recorder.append("power-sample", fields: ["actualHold": false, "lidClosed": true])
        // Simulate genuine sleep: continuous clock advances, awake clock does not.
        wall += 100; continuous += 100
        recorder.append("system-did-wake")
        wall += 200; continuous += 200; awake += 200
        recorder.poll()
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        let file = try XCTUnwrap(files.first)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(lines.map { $0["event"] as? String }, ["recorder-started", "accepted-task-event", "power-sample", "system-did-wake", "recorder-finished"])
        XCTAssertEqual(lines.last?["reason"] as? String, "deadline")
        XCTAssertEqual((lines[3]["continuous"] as? Double ?? 0) - (lines[3]["awake"] as? Double ?? 0), 100)
        XCTAssertEqual((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let size = try Data(contentsOf: file).count
        recorder.poll(); recorder.append("after-deadline")
        XCTAssertEqual(try Data(contentsOf: file).count, size)
    }

    @MainActor func testAcceptanceRecorderRejectsLongRequestsAndUsesContinuousDeadline() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var wall: TimeInterval = 1000, tick: TimeInterval = 0
        let recorder = KeepAwakeAcceptanceRecorder(root: root, wall: { wall }, continuous: { tick }, awake: { tick })
        func write(_ expires: TimeInterval) throws {
            try JSONEncoder().encode(KeepAwakeAcceptanceRecorder.Request(id: UUID(), expiresAt: expires)).write(to: recorder.requestURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.requestURL.path)
        }
        try write(1901); recorder.poll()
        XCTAssertFalse(recorder.sampleDue)
        try write(1300); recorder.poll(); XCTAssertTrue(recorder.sampleDue)
        wall = 500; tick = 301; recorder.poll() // Wall clock moved backwards.
        XCTAssertFalse(recorder.sampleDue)
    }

    private typealias Snapshot = KeepAwakeCodexMonitor.Snapshot

    private func snapshot(_ status: String, turn: String, turnStatus: String) -> Snapshot {
        .init(threads: [.init(id: "fixture-thread", status: status,
                             turns: [.init(id: turn, status: turnStatus)], turnsComplete: true)])
    }

    @MainActor private func makeService(uninstaller: @escaping @MainActor (KeepAwakeSource) throws -> Void = { _ in
        XCTFail("An isolated fixture must not invoke the production hook uninstaller.")
    }, sampler: @escaping @MainActor () async throws -> Snapshot) throws
        -> (name: String, defaults: UserDefaults, root: URL, service: KeepAwakeService) {
        let name = "KA1CodexService-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let profile = KeepAwakeCodexEnvironment.Profile(executableURL: root.appendingPathComponent("Renamed App.app/codex"),
            codexHome: root.appendingPathComponent("private-codex"), socketURL: root.appendingPathComponent("private-codex/control.sock"))
        defaults.set(try JSONEncoder().encode(["codex-cli": KeepAwakeCodexConnection(profile: profile, mode: .hooks), "codex-desktop": KeepAwakeCodexConnection(profile: profile, mode: .rpc)]),
                     forKey: KeepAwakeCodexConnection.defaultsKey)
        let service = KeepAwakeService(defaults: defaults, root: root, codexSampler: sampler,
                                       codexAvailability: { true }, hookUninstaller: uninstaller, codexResolver: { profile })
        return (name, defaults, root, service)
    }

    @MainActor private func source() throws -> KeepAwakeSource {
        try XCTUnwrap(KeepAwakeSource.all.first { $0.id == "codex-desktop" })
    }

    @MainActor private func sourceSessions(_ service: KeepAwakeService) -> [KeepAwakeEngine.Session] {
        service.engine.sessions.values.filter { $0.event.source == "codex-desktop" }
    }

    @MainActor private func waitUntil(_ predicate: @escaping @MainActor () -> Bool, timeout: TimeInterval = 8,
                                     file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the injected service fixture", file: file, line: line)
        return false
    }

    @MainActor private func assertNoRealHold(_ service: KeepAwakeService, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(service.engine.enabled, file: file, line: line)
        XCTAssertFalse(service.actualHold, file: file, line: line)
        XCTAssertFalse(service.lid.enabled, file: file, line: line)
        XCTAssertFalse(service.lid.applied, file: file, line: line)
        XCTAssertFalse(service.lid.busy, file: file, line: line)
    }

    @MainActor func testRepeatedConnectIsIdempotentAndNewTurnKeepsMonotonicSequence() async throws {
        var calls = 0
        let fixture = try makeService {
            calls += 1
            switch calls {
            case 1: return self.snapshot("active", turn: "old-turn", turnStatus: "inProgress")
            case 2: return self.snapshot("idle", turn: "old-turn", turnStatus: "completed")
            default: return self.snapshot("active", turn: "new-turn", turnStatus: "inProgress")
            }
        }
        let service = fixture.service
        defer {
            service.shutdown()
            fixture.defaults.removePersistentDomain(forName: fixture.name)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        service.start()
        let source = try source()
        try service.connect(source)
        guard await waitUntil({ self.sourceSessions(service).first?.event.state == .running }) else { return }
        let first = try XCTUnwrap(sourceSessions(service).first)
        try service.connect(source)
        try service.connect(source)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calls, 1, "Repeated connect must not reset the ledger or start a replacement read.")
        XCTAssertEqual(sourceSessions(service).first?.event.sequence, first.event.sequence)

        guard await waitUntil({ self.sourceSessions(service).first?.event.state == .completed }) else { return }
        let terminal = try XCTUnwrap(sourceSessions(service).first)
        XCTAssertGreaterThan(terminal.event.sequence, first.event.sequence)
        try service.connect(source)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calls, 2)
        guard await waitUntil({ self.sourceSessions(service).first?.event.state == .running && calls >= 3 }) else { return }
        let newTurn = try XCTUnwrap(sourceSessions(service).first)
        XCTAssertEqual(newTurn.event.storageKey, first.event.storageKey)
        XCTAssertGreaterThan(newTurn.event.sequence, terminal.event.sequence)
        XCTAssertEqual(newTurn.event.startsTask, true)
        XCTAssertTrue(newTurn.isUnfinished)
        var policy = service.engine
        policy.setEnabled(true)
        XCTAssertTrue(policy.evaluate(now: KeepAwakeClock.now(), environment: .init(hardware: .notebook, battery: 80, onAC: true)).hold)
        assertNoRealHold(service)
    }

    @MainActor func testDisconnectRejectsLateSnapshotFromCancelledGeneration() async throws {
        var pending: CheckedContinuation<Snapshot, Error>?
        let began = expectation(description: "injected Codex sample began")
        let fixture = try makeService {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                began.fulfill()
            }
        }
        let service = fixture.service
        defer {
            service.shutdown()
            pending?.resume(throwing: CancellationError())
            fixture.defaults.removePersistentDomain(forName: fixture.name)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        service.start()
        let source = try source()
        try service.connect(source)
        await fulfillment(of: [began], timeout: 2)
        XCTAssertNotNil(pending)
        try service.disconnect(source)
        let continuation = pending
        pending = nil
        continuation?.resume(returning: snapshot("active", turn: "obsolete", turnStatus: "inProgress"))
        for _ in 0..<10 { await Task.yield() }
        service.tick()
        XCTAssertFalse(service.connections.contains(source.id))
        XCTAssertFalse(service.receivedSources.contains(source.id))
        XCTAssertTrue(sourceSessions(service).isEmpty)
        XCTAssertEqual(service.codexStatus, "当前任务状态通道未接通")
        assertNoRealHold(service)
    }

    @MainActor func testTransportFailureRetainsStartedTaskAsUnknown() async throws {
        var calls = 0
        let fixture = try makeService {
            calls += 1
            if calls == 1 { return self.snapshot("active", turn: "long-turn", turnStatus: "inProgress") }
            throw KeepAwakeCodexRPC.Failure.timeout
        }
        let service = fixture.service
        defer {
            service.shutdown()
            fixture.defaults.removePersistentDomain(forName: fixture.name)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        service.start()
        let source = try source()
        try service.connect(source)
        guard await waitUntil({ self.sourceSessions(service).first?.event.state == .running }) else { return }
        let before = try XCTUnwrap(sourceSessions(service).first)
        guard await waitUntil({ calls >= 2 && self.sourceSessions(service).first?.event.state == .idle }) else { return }
        let after = try XCTUnwrap(sourceSessions(service).first)
        XCTAssertEqual(after.event.storageKey, before.event.storageKey)
        XCTAssertGreaterThan(after.event.sequence, before.event.sequence)
        XCTAssertTrue(after.isUnfinished)
        XCTAssertNil(after.releaseAt)
        XCTAssertTrue(service.sourceStatus(source).contains("待核实"))
        var policy = service.engine
        policy.setEnabled(true)
        let future = KeepAwakeClock.now() + 86_400
        XCTAssertTrue(policy.evaluate(now: future, environment: .init(hardware: .notebook, battery: 80, onAC: true)).hold)
        assertNoRealHold(service)
    }

    @MainActor func testFailedHookCleanupStopsReceivingAndCanBeRetried() throws {
        var uninstalls = 0
        let fixture = try makeService(uninstaller: { source in
            XCTAssertEqual(source.id, "codex-cli")
            uninstalls += 1
            if uninstalls == 1 { throw CocoaError(.fileWriteNoPermission) }
        }) {
            XCTFail("CLI cleanup must not query a desktop task service.")
            return .init(threads: [])
        }
        let service = fixture.service
        defer {
            service.shutdown()
            fixture.defaults.removePersistentDomain(forName: fixture.name)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let cli = try XCTUnwrap(KeepAwakeSource.all.first { $0.id == "codex-cli" })
        // Restore only the private mailbox connection. No hook installer runs.
        fixture.defaults.set([cli.id], forKey: "keepAwake.sources.v1")
        service.start()
        XCTAssertTrue(service.connections.contains(cli.id))
        let credential = fixture.root.appendingPathComponent("credentials/codex-cli.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: credential.path))

        XCTAssertThrowsError(try service.disconnect(cli))
        XCTAssertEqual(uninstalls, 1)
        XCTAssertFalse(service.connections.contains(cli.id))
        XCTAssertFalse(service.receivedSources.contains(cli.id))
        XCTAssertTrue(service.cleanupPendingSources.contains(cli.id))
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "keepAwake.cleanupPending.v1"), [cli.id])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "keepAwake.sources.v1"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.path))
        XCTAssertTrue(service.sourceStatus(cli).contains("重试"))
        // Reconnection is blocked before any real configuration installer.
        XCTAssertThrowsError(try service.connect(cli))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.path))

        try service.disconnect(cli)
        XCTAssertEqual(uninstalls, 2)
        XCTAssertFalse(service.cleanupPendingSources.contains(cli.id))
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "keepAwake.cleanupPending.v1"), [])
        XCTAssertFalse(service.connections.contains(cli.id))
        assertNoRealHold(service)
    }

    @MainActor func testRestartPreservesCleanupObligationWithoutRestoringPendingSource() throws {
        let fixture = try makeService(uninstaller: { _ in throw CocoaError(.fileWriteNoPermission) }) {
            XCTFail("An isolated CLI fixture must not sample Codex desktop.")
            return .init(threads: [])
        }
        let first = fixture.service
        var second: KeepAwakeService?
        defer {
            first.shutdown()
            second?.shutdown()
            fixture.defaults.removePersistentDomain(forName: fixture.name)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let cli = try XCTUnwrap(KeepAwakeSource.all.first { $0.id == "codex-cli" })
        fixture.defaults.set([cli.id], forKey: "keepAwake.sources.v1")
        first.start()
        XCTAssertThrowsError(try first.disconnect(cli))
        XCTAssertTrue(first.cleanupPendingSources.contains(cli.id))
        first.shutdown()
        // A stale pre-crash connection preference must not override cleanup.
        fixture.defaults.set([cli.id], forKey: "keepAwake.sources.v1")
        var retries = 0
        let restarted = KeepAwakeService(defaults: fixture.defaults, root: fixture.root,
                                          codexSampler: {
            XCTFail("Restart must not query a real desktop endpoint.")
            return .init(threads: [])
        }, codexAvailability: { true }, hookUninstaller: { source in
            XCTAssertEqual(source.id, cli.id)
            retries += 1
        })
        second = restarted
        restarted.start()
        XCTAssertEqual(retries, 0, "Restart must not silently retry external configuration writes.")
        XCTAssertFalse(restarted.connections.contains(cli.id))
        XCTAssertTrue(restarted.cleanupPendingSources.contains(cli.id))
        XCTAssertTrue(restarted.sourceStatus(cli).contains("重试"))
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "keepAwake.sources.v1"), [])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "keepAwake.cleanupPending.v1"), [cli.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("credentials/codex-cli.json").path))

        try restarted.disconnect(cli)
        XCTAssertEqual(retries, 1)
        XCTAssertTrue(restarted.cleanupPendingSources.isEmpty)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "keepAwake.cleanupPending.v1"), [])
        assertNoRealHold(first)
        assertNoRealHold(restarted)
    }
}
