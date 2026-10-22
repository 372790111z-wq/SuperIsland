import XCTest
@testable import SuperIsland

/// Exercise real service scheduling with an injected metadata source. The
/// service remains disabled; policy decisions are evaluated on a local copy so
/// these fixtures never acquire a real power assertion or a helper lease.
final class KeepAwakeCodexServiceTests: XCTestCase {
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
