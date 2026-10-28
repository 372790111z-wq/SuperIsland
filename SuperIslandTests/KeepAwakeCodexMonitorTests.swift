import XCTest
import SQLite3
@testable import SuperIsland

final class KeepAwakeCodexMonitorTests: XCTestCase {
    private typealias Monitor = KeepAwakeCodexMonitor
    private let environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true)

    private func thread(_ status: String, id: String = "raw-thread-a", flags: [String] = [],
                        turns: [(String, String)] = [], complete: Bool = true) -> Monitor.Thread {
        .init(id: id, status: status, activeFlags: flags,
              turns: turns.map { .init(id: $0.0, status: $0.1) }, turnsComplete: complete)
    }

    private func engine() -> KeepAwakeEngine {
        var result = KeepAwakeEngine()
        result.setAutomatic(true)
        return result
    }

    private func apply(_ events: [KeepAwakeEngine.Event], to engine: inout KeepAwakeEngine, now: Double) {
        for event in events { XCTAssertTrue(engine.receive(event, now: now)) }
    }

    func testFirstIdleOrUnavailableSnapshotNeverInventsTask() {
        for status in ["idle", "notLoaded", "systemError", "futureStatus"] {
            var ledger = Monitor.Ledger()
            XCTAssertTrue(ledger.consume(snapshot: .init(threads: [thread(status, turns: [("old-turn", "completed")])]),
                                         now: 0, sequence: 1).isEmpty)
        }
        var ledger = Monitor.Ledger()
        XCTAssertTrue(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("old", "inProgress")])]),
                                     now: 0, sequence: 1).isEmpty)
    }

    func testActiveSnapshotBackfillsCurrentTaskWithAnonymousStableGuard() {
        var ledger = Monitor.Ledger()
        let events = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("raw-turn-a", "inProgress")])]),
                                    now: 0, sequence: 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.state, .running)
        XCTAssertEqual(events.first?.startsTask, true)
        XCTAssertEqual(events.first?.source, "codex-desktop")
        XCTAssertEqual(events.first?.session.count, 64)
        XCTAssertEqual(events.first?.taskID?.count, 64)
        XCTAssertNotEqual(events.first?.session, "raw-thread-a")
        XCTAssertNotEqual(events.first?.taskID, "raw-turn-a")
        let heartbeat = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("raw-turn-a", "inProgress")])]),
                                       now: 30, sequence: 2)
        XCTAssertEqual(heartbeat.first?.session, events.first?.session)
        XCTAssertEqual(heartbeat.first?.taskID, events.first?.taskID)
        XCTAssertEqual(heartbeat.first?.startsTask, false)
    }

    func testFirstActiveWaitingSnapshotEstablishesHoldThenShowsWaiting() {
        for flag in ["waitingOnApproval", "waitingOnUserInput"] {
            var ledger = Monitor.Ledger()
            var policy = engine()
            let events = ledger.consume(snapshot: .init(threads: [thread("active", flags: [flag], turns: [("turn-a", "inProgress")])]),
                                        now: 0, sequence: 1)
            XCTAssertEqual(events.map(\.state), [.running, .waiting])
            apply(events, to: &policy, now: 0)
            XCTAssertTrue(policy.evaluate(now: 86_400, environment: environment).hold)
            XCTAssertTrue(policy.evaluate(now: 86_400, environment: environment).title.contains("等待"))
        }
    }

    func testMatchingExplicitTerminalStatusesReleaseAfterThirtySeconds() {
        let cases: [(String, KeepAwakeEngine.TaskState)] = [("completed", .completed), ("failed", .failed), ("interrupted", .cancelled)]
        for (raw, expected) in cases {
            var ledger = Monitor.Ledger()
            var policy = engine()
            apply(ledger.consume(snapshot: .init(threads: [thread("active", turns: [("turn-a", "inProgress")])]), now: 0, sequence: 1),
                  to: &policy, now: 0)
            let terminal = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("turn-a", raw)])]), now: 10, sequence: 2)
            XCTAssertEqual(terminal.map(\.state), [expected])
            apply(terminal, to: &policy, now: 10)
            XCTAssertTrue(policy.evaluate(now: 39.999, environment: environment).hold)
            XCTAssertFalse(policy.evaluate(now: 40, environment: environment).hold)
            XCTAssertTrue(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("turn-a", raw)])]), now: 39, sequence: 3).isEmpty)
        }
    }

    func testParallelTurnsAndThreadsCannotReleaseEachOther() {
        var ledger = Monitor.Ledger()
        var policy = engine()
        apply(ledger.consume(snapshot: .init(threads: [
            thread("active", turns: [("a1", "inProgress"), ("a2", "inProgress")]),
            thread("active", id: "thread-b", turns: [("b1", "inProgress")])
        ]), now: 0, sequence: 1), to: &policy, now: 0)
        apply(ledger.consume(snapshot: .init(threads: [
            thread("active", turns: [("a1", "completed"), ("a2", "inProgress")]),
            thread("idle", id: "thread-b", turns: [("b1", "failed")])
        ]), now: 10, sequence: 2), to: &policy, now: 10)
        XCTAssertTrue(policy.evaluate(now: 86_400, environment: environment).hold)
        let ended = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a1", "completed"), ("a2", "completed")])]), now: 86_401, sequence: 3)
        XCTAssertEqual(ended.map(\.state), [.completed])
        apply(ended, to: &policy, now: 86_401)
        XCTAssertFalse(policy.evaluate(now: 86_431, environment: environment).hold)
    }

    func testUnknownTurnGuardRequiresLaterObservedInProgressIdentity() {
        var ledger = Monitor.Ledger()
        var policy = engine()
        apply(ledger.consume(snapshot: .init(threads: [thread("active")]), now: 0, sequence: 1), to: &policy, now: 0)
        let oldTerminal = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("old-turn", "completed")])]), now: 10, sequence: 2)
        XCTAssertEqual(oldTerminal.map(\.state), [.idle])
        apply(oldTerminal, to: &policy, now: 10)
        XCTAssertTrue(policy.evaluate(now: 86_400, environment: environment).hold)

        apply(ledger.consume(snapshot: .init(threads: [thread("active", turns: [("new-turn", "inProgress")])]), now: 86_401, sequence: 3),
              to: &policy, now: 86_401)
        let end = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("new-turn", "completed")])]), now: 86_402, sequence: 4)
        XCTAssertEqual(end.map(\.state), [.completed])
        apply(end, to: &policy, now: 86_402)
        XCTAssertFalse(policy.evaluate(now: 86_432, environment: environment).hold)
    }

    func testNoTurnIdentityEverSeenNeverInfersEndingFromIdle() {
        var ledger = Monitor.Ledger()
        var policy = engine()
        apply(ledger.consume(snapshot: .init(threads: [thread("active")]), now: 0, sequence: 1), to: &policy, now: 0)
        for (offset, status) in ["idle", "notLoaded", "systemError", "futureStatus"].enumerated() {
            let events = ledger.consume(snapshot: .init(threads: [thread(status)]), now: Double(offset + 1), sequence: UInt64(offset + 2))
            XCTAssertEqual(events.map(\.state), [.idle])
            apply(events, to: &policy, now: Double(offset + 1))
        }
        XCTAssertTrue(policy.evaluate(now: 86_400, environment: environment).hold)
    }

    func testMissingThreadOrEmptySnapshotPreservesVisibleUnknownHold() {
        var ledger = Monitor.Ledger()
        let start = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("turn-a", "inProgress")])]), now: 0, sequence: 1)
        let missing = ledger.consume(snapshot: .init(threads: []), now: 10, sequence: 2)
        XCTAssertEqual(missing.map(\.state), [.idle])
        XCTAssertEqual(missing.first?.taskID, start.first?.taskID)
        XCTAssertEqual(missing.first?.startsTask, false)
        let unrelated = ledger.consume(snapshot: .init(threads: [thread("idle", id: "unrelated")]), now: 20, sequence: 3)
        XCTAssertEqual(unrelated.map(\.state), [.idle])
    }

    func testPartialTurnPageCannotReleaseAndDefaultCompletenessIsFalse() {
        var ledger = Monitor.Ledger()
        _ = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("a", "inProgress"), ("b", "inProgress")])]), now: 0, sequence: 1)
        let partial = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed")], complete: false)]), now: 1, sequence: 2)
        XCTAssertEqual(partial.map(\.state), [.idle])
        let defaultPage = Monitor.Thread(id: "raw-thread-a", status: "idle", turns: [.init(id: "b", status: "completed")])
        XCTAssertFalse(defaultPage.turnsComplete)
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [defaultPage]), now: 2, sequence: 3).map(\.state), [.idle])
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed"), ("b", "completed")])]),
                                      now: 3, sequence: 4).map(\.state), [.completed])
    }

    func testNewUnknownRoundCannotBorrowPreviousRoundTerminal() {
        var ledger = Monitor.Ledger()
        _ = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("old", "inProgress")])]), now: 0, sequence: 1)
        _ = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("old", "completed")])]), now: 1, sequence: 2)
        let new = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("old", "completed")])]), now: 2, sequence: 3)
        XCTAssertEqual(new.map(\.state), [.running, .idle])
        XCTAssertEqual(new.first?.startsTask, true)
        let oldEnd = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("old", "completed")])]), now: 3, sequence: 4)
        XCTAssertEqual(oldEnd.map(\.state), [.idle])
    }

    func testOldTerminalCannotEndNewIdentifiedTurnOrReplayOldProgress() {
        var ledger = Monitor.Ledger()
        _ = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("old", "inProgress")])]), now: 0, sequence: 1)
        _ = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("old", "completed")])]), now: 1, sequence: 2)
        XCTAssertTrue(ledger.consume(snapshot: .init(threads: [thread("active", turns: [("old", "inProgress")])]), now: 2, sequence: 3).isEmpty)
        let new = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("new", "inProgress")])]), now: 3, sequence: 4)
        XCTAssertEqual(new.first?.startsTask, true)
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("old", "completed")])]), now: 4, sequence: 5).map(\.state), [.idle])
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("new", "completed")])]), now: 5, sequence: 6).map(\.state), [.completed])
    }

    func testRepeatedAndOldBatchesAreIgnoredAndOutputSequenceIsMonotonic() {
        var ledger = Monitor.Ledger()
        let snapshot = Monitor.Snapshot(threads: [thread("active", flags: ["waitingOnUserInput"], turns: [("a", "inProgress")]),
                                                 thread("active", id: "thread-b", turns: [("b", "inProgress")])])
        let first = ledger.consume(snapshot: snapshot, now: 0, sequence: 100)
        XCTAssertEqual(first.map(\.sequence), [100, 101, 102])
        XCTAssertTrue(ledger.consume(snapshot: .init(threads: []), now: 1, sequence: 100).isEmpty)
        XCTAssertTrue(ledger.consume(snapshot: .init(threads: []), now: 2, sequence: 99).isEmpty)
        let second = ledger.consume(snapshot: .init(threads: []), now: 3, sequence: 101)
        XCTAssertEqual(second.map(\.sequence), [103, 104])
        XCTAssertEqual(second.map(\.state), [.idle, .idle])
    }

    func testConflictingTurnRowsCannotSupplyFalseTerminal() {
        var ledger = Monitor.Ledger()
        _ = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("a", "inProgress")])]), now: 0, sequence: 1)
        let conflict = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed"), ("a", "inProgress")])]), now: 1, sequence: 2)
        XCTAssertEqual(conflict.map(\.state), [.idle])
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed")])]), now: 2, sequence: 3).map(\.state), [.completed])
    }

    func testUnknownActiveFlagsRemainUnknownWithoutLosingGuard() {
        var ledger = Monitor.Ledger()
        let events = ledger.consume(snapshot: .init(threads: [thread("active", flags: ["futureFlag"], turns: [("a", "inProgress")])]), now: 0, sequence: 1)
        XCTAssertEqual(events.map(\.state), [.running, .idle])
    }

    func testFutureTurnStatusDoesNotTurnCachedTerminalIntoFalseCompletion() {
        var ledger = Monitor.Ledger()
        _ = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("a", "inProgress")])]), now: 0, sequence: 1)
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed")], complete: false)]),
                                      now: 1, sequence: 2).map(\.state), [.idle])
        let unknown = ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed"), ("other", "futureStatus")])]),
                                     now: 2, sequence: 3)
        XCTAssertEqual(unknown.map(\.state), [.idle])
    }

    func testConflictingThreadPagesKeepUnknownUntilCurrentRoundCanBeIdentified() {
        var ledger = Monitor.Ledger()
        let conflict = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("a", "inProgress")]),
                                                                thread("idle", turns: [("a", "completed")])]), now: 0, sequence: 1)
        XCTAssertEqual(conflict.map(\.state), [.running, .idle])
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("a", "completed")])]), now: 1, sequence: 2).map(\.state), [.idle])
        _ = ledger.consume(snapshot: .init(threads: [thread("active", turns: [("new", "inProgress")])]), now: 2, sequence: 3)
        XCTAssertEqual(ledger.consume(snapshot: .init(threads: [thread("idle", turns: [("new", "completed")])]), now: 3, sequence: 4).map(\.state), [.completed])
    }

    func testInvalidClockOrIdentifierCannotActivateOrConsumeSequence() {
        var ledger = Monitor.Ledger()
        let active = Monitor.Snapshot(threads: [thread("active", turns: [("a", "inProgress")])])
        XCTAssertTrue(ledger.consume(snapshot: active, now: .nan, sequence: 1).isEmpty)
        XCTAssertTrue(ledger.consume(snapshot: .init(threads: [thread("active", id: "")]), now: 0, sequence: 0).isEmpty)
        XCTAssertEqual(ledger.consume(snapshot: active, now: 1, sequence: 1).first?.state, .running)
    }
}

final class KeepAwakeZCodeTurnMetadataReaderTests: XCTestCase {
    private typealias Reader = KeepAwakeZCodeTurnMetadataReader
    private let schema = "CREATE TABLE turn_usage (session_id TEXT NOT NULL,turn_id TEXT NOT NULL,status TEXT,started_at INTEGER,completed_at INTEGER,private_body TEXT,PRIMARY KEY(session_id,turn_id))"
    private let now: TimeInterval = 1_800_000_100

    private func identity(_ session: String = "session-a", _ turn: String = "turn-a") -> Reader.Identity {
        .init(sessionHash: KeepAwakeHookContract.anonymousIdentity(session), taskHash: KeepAwakeHookContract.anonymousIdentity(turn))
    }
    private func withDatabase(_ customSchema: String? = nil,
                              _ body: (OpaquePointer, URL) throws -> Void) throws {
        // SQLite's NOFOLLOW protects every path component; macOS /var is a
        // symlink, so use the physical temporary directory for the fixture.
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let physicalTemporaryPath = temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath
        let root = URL(fileURLWithPath: physicalTemporaryPath).appendingPathComponent("zcode-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        try execute(customSchema ?? schema, database)
        try body(database, url)
    }
    private func execute(_ sql: String, _ database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail("Synthetic SQLite fixture failed")
            throw CocoaError(.fileWriteUnknown)
        }
    }
    private func insert(_ database: OpaquePointer, session: String = "session-a", turn: String = "turn-a",
                        state: String = "completed", started: Int64 = 1_800_000_000_000,
                        completed: Int64 = 1_800_000_010_000) throws {
        var prepared: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO turn_usage(session_id,turn_id,status,started_at,completed_at) VALUES(?,?,?,?,?)", -1, &prepared, nil), SQLITE_OK)
        let statement = try XCTUnwrap(prepared)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, session, -1, transient)
        sqlite3_bind_text(statement, 2, turn, -1, transient)
        sqlite3_bind_text(statement, 3, state, -1, transient)
        sqlite3_bind_int64(statement, 4, started)
        sqlite3_bind_int64(statement, 5, completed)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testOnlyExactAdmittedSessionAndTurnCanEndParallelTasks() throws {
        try withDatabase { database, url in
            try insert(database)
            try insert(database, turn: "turn-b", state: "running")
            try insert(database, session: "session-b", state: "error")
            try insert(database, session: "unadmitted", state: "completed")
            let result = Reader.read(database: url, identities: [identity(), identity("session-a", "turn-b"), identity("session-b")], now: now)
            XCTAssertEqual(Set(result.map(\.identity)), [identity(), identity("session-b")])
            XCTAssertEqual(Set(result.map(\.state)), ["completed", "failed"])
            XCTAssertEqual(result.first?.startedAt, 1_800_000_000)
            XCTAssertEqual(result.first?.completedAt, 1_800_000_010)
            XCTAssertFalse(String(describing: result).contains("session-a"))
        }
    }

    func testPriorTurnCompletionCannotCloseNewTurnOrSessionWithSameTurnID() throws {
        try withDatabase { database, url in
            try insert(database, turn: "old-turn")
            try insert(database, session: "different-session", turn: "new-turn")
            XCTAssertTrue(Reader.read(database: url, identities: [identity("session-a", "new-turn")], now: now).isEmpty)
            try insert(database, turn: "new-turn", state: "running")
            XCTAssertTrue(Reader.read(database: url, identities: [identity("session-a", "new-turn")], now: now).isEmpty)
        }
    }

    func testCancelledAndFailureAreDistinctAndStopOrCompactionRunningRemainUnknown() throws {
        try withDatabase { database, url in
            try insert(database, turn: "cancelled", state: "cancelled")
            try insert(database, turn: "failed", state: "error")
            for state in ["idle", "Stop", "running", "future-outcome"] {
                try insert(database, turn: state, state: state)
            }
            let known = Set(["cancelled", "failed", "idle", "Stop", "running", "future-outcome"].map { identity("session-a", $0) })
            let result = Reader.read(database: url, identities: known, now: now)
            XCTAssertEqual(Set(result.map(\.state)), ["cancelled", "failed"])
            XCTAssertEqual(result.count, 2)
        }
    }

    func testWALFactsAreReadWithoutWritingDatabaseOrProjectingPrivateColumns() throws {
        try withDatabase { database, url in
            try execute("PRAGMA journal_mode=WAL", database)
            try execute("CREATE TABLE message (private_body TEXT);INSERT INTO message VALUES('must never be queried')", database)
            try insert(database)
            try execute("UPDATE turn_usage SET private_body='not part of the allowed projection'", database)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
            let before = try Data(contentsOf: url)
            let beforeWAL = try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
            XCTAssertEqual(Reader.read(database: url, identities: [identity()], now: now).map(\.state), ["completed"])
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")), beforeWAL)
        }
    }

    func testUnknownSchemaCorruptionAndViewsCannotSupplyTerminalProof() throws {
        for schema in ["CREATE TABLE turn_usage (session_id TEXT, turn_id TEXT,status TEXT)",
                       "CREATE TABLE message (session_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER);CREATE VIEW turn_usage AS SELECT * FROM message"] {
            try withDatabase(schema) { database, url in
                if schema.contains("CREATE VIEW") {
                    try execute("INSERT INTO message VALUES('session-a','turn-a','completed',1800000000000,1800000010000)", database)
                }
                XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: now).isEmpty)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a SQLite database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: now).isEmpty)
        XCTAssertTrue(Reader.read(database: url.appendingPathExtension("missing"), identities: [identity()], now: now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("missing").path))
    }

    func testDatabaseAndSidecarSymlinksAreRejected() throws {
        try withDatabase { database, url in
            try insert(database)
            let link = url.appendingPathExtension("symlink")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertTrue(Reader.read(database: link, identities: [identity()], now: now).isEmpty)
            let sidecar = URL(fileURLWithPath: url.path + "-wal")
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: url)
            XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: now).isEmpty)
        }
    }

    func testWideNativeUsageSchemaStillProjectsOnlyAllowedColumns() throws {
        let columns = (0..<40).map { "private_column_\($0) TEXT" }.joined(separator: ",")
        let wide = "CREATE TABLE turn_usage(session_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER," + columns + ")"
        try withDatabase(wide) { database, url in
            try insert(database)
            XCTAssertEqual(Reader.read(database: url, identities: [identity()], now: now).map(\.state), ["completed"])
        }
    }

    func testLargeUnmatchedHistoryExhaustsBoundedBudgetWithoutEndingTask() throws {
        try withDatabase { database, url in
            try execute("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO turn_usage(session_id,turn_id,status,started_at,completed_at) SELECT 'other',CAST(x AS TEXT),'completed',1800000000000,1800000010000 FROM n", database)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: now,
                                      budget: .init(maximumVMInstructions: 1000, maximumDuration: 0.05)).isEmpty)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        }
    }

    func testInvalidClocksAndIdentifiersCannotEndAnAdmittedTask() throws {
        try withDatabase { database, url in
            for (turn, started, completed) in [("backwards", Int64(20_000), Int64(10_000)),
                                               ("negative", -1, 1_800_000_010_000),
                                               ("future", 1_800_000_000_000, 1_800_000_200_000)] {
                try insert(database, turn: turn, started: started, completed: completed)
            }
            try insert(database, turn: "text-clock")
            try execute("UPDATE turn_usage SET completed_at='invalid' WHERE turn_id='text-clock'", database)
            try insert(database, turn: "null-clock")
            try execute("UPDATE turn_usage SET completed_at=NULL WHERE turn_id='null-clock'", database)
            let turns = ["backwards", "negative", "future", "text-clock", "null-clock"]
            XCTAssertTrue(Reader.read(database: url, identities: Set(turns.map { identity("session-a", $0) }), now: now).isEmpty)
            try insert(database, session: "session\n", turn: "control")
            try insert(database, turn: " ")
            XCTAssertTrue(Reader.read(database: url, identities: [identity("session\n", "control"), identity("session-a", " ")], now: now).isEmpty)
            XCTAssertTrue(Reader.read(database: url, identities: [.init(sessionHash: "invalid", taskHash: identity().taskHash)], now: now).isEmpty)
            XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: .infinity).isEmpty)
        }
    }

    func testDuplicateIdentitiesAndInstructionExhaustionFailClosed() throws {
        try withDatabase("CREATE TABLE turn_usage (session_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER)") { database, url in
            try insert(database)
            try insert(database)
            XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: now).isEmpty)
        }
        try withDatabase { database, url in
            try execute("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<500) INSERT INTO turn_usage(session_id,turn_id,status,started_at,completed_at) SELECT 'unadmitted',CAST(x AS TEXT),'completed',1800000000000,1800000010000 FROM n", database)
            try insert(database)
            XCTAssertTrue(Reader.read(database: url, identities: [identity()], now: now,
                                      budget: .init(maximumVMInstructions: 100, maximumDuration: 0.25)).isEmpty)
            XCTAssertEqual(Reader.read(database: url, identities: [identity()], now: now).count, 1)
        }
    }

    func testCustomDatabaseConfigDoesNotFallBackToWrongDefault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("zcode-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zcode/cli"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".zcode/cli/config.json")
        XCTAssertTrue(Reader.defaultPathIsConfigured(home: home))
        for value in ["{}", "{\"storage\":{}}", "{\"storage\":{\"sessionDbPath\":\"~/.zcode/cli/db/db.sqlite\"}}"] {
            try Data(value.utf8).write(to: config)
            XCTAssertTrue(Reader.defaultPathIsConfigured(home: home))
        }
        let absolute = try JSONSerialization.data(withJSONObject: ["storage": ["sessionDbPath": Reader.defaultDatabaseURL(home: home).path]])
        try absolute.write(to: config)
        XCTAssertTrue(Reader.defaultPathIsConfigured(home: home))
        for value in ["invalid-json", "[]", "{\"storage\":false}", "{\"storage\":{\"sessionDbPath\":null}}",
                      "{\"storage\":{\"sessionDbPath\":\"other.sqlite\"}}", "{\"storage\":{\"sessionDbPath\":\"/tmp/custom.sqlite\"}}"] {
            try Data(value.utf8).write(to: config)
            XCTAssertFalse(Reader.defaultPathIsConfigured(home: home))
        }
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: home.appendingPathComponent("missing"))
        XCTAssertFalse(Reader.defaultPathIsConfigured(home: home))
    }
}
