import XCTest
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
