import XCTest
@testable import SuperIsland

/// Task lifetime and daemon lifetime are deliberately different: an unfinished
/// task has no age limit, while the privileged lease must expire if its app dies.
final class KeepAwakeLongTaskTests: XCTestCase {
    private let notebook = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true)

    private func event(_ state: KeepAwakeEngine.TaskState, sequence: UInt64 = 1,
                       source: String = "claude-code", session: String = "long-task") -> KeepAwakeEngine.Event {
        .init(source: source, session: session, sequence: sequence, state: state)
    }

    private func automaticEngine() -> KeepAwakeEngine {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        return engine
    }

    func testSilentRunningTaskRemainsHeldBeyondOneDayAndIsReportedUnknown() {
        var engine = automaticEngine()
        XCTAssertTrue(engine.receive(event(.running), now: 10))
        XCTAssertTrue(engine.evaluate(now: 54.999, environment: notebook).hold)

        for now in [55.0, 190.0, 3_600.0, 86_410.0, 172_810.0] {
            let decision = engine.evaluate(now: now, environment: notebook)
            XCTAssertTrue(decision.hold, "An unfinished task must survive a missing heartbeat at \(now).")
            XCTAssertEqual(decision.runningSources, 0, "A stale task is not confirmed running.")
            XCTAssertTrue((decision.title + decision.detail).contains("待核实"),
                          "Missing signals must not be presented as known running or completed.")
        }
    }

    func testWaitingForUserNeverStartsCompletionCountdown() {
        var engine = automaticEngine()
        engine.receive(event(.running), now: 0)
        engine.receive(event(.waiting, sequence: 2), now: 20)

        for now in [50.0, 200.0, 3_600.0, 86_400.0] {
            XCTAssertTrue(engine.evaluate(now: now, environment: notebook).hold)
        }
        engine.receive(event(.waiting, sequence: 3), now: 86_401)
        XCTAssertTrue(engine.evaluate(now: 172_800, environment: notebook).hold)
    }

    func testIdleObservationDoesNotProveStartedTaskFinished() {
        var engine = automaticEngine()
        engine.receive(event(.running), now: 0)
        engine.receive(event(.idle, sequence: 2), now: 20)
        XCTAssertTrue(engine.evaluate(now: 50, environment: notebook).hold)
        XCTAssertTrue(engine.evaluate(now: 86_400, environment: notebook).hold)

        engine.receive(event(.completed, sequence: 3), now: 86_401)
        XCTAssertTrue(engine.evaluate(now: 86_430.999, environment: notebook).hold)
        XCTAssertFalse(engine.evaluate(now: 86_431, environment: notebook).hold)
    }

    func testExplicitTerminalStatesReleaseThirtySecondsAfterActualArrival() {
        for state: KeepAwakeEngine.TaskState in [.completed, .failed, .cancelled] {
            var engine = automaticEngine()
            engine.receive(event(.running), now: 0)
            // A very late terminal event still ends a task that was held while
            // unknown; the old heartbeat must not shorten its completion delay.
            XCTAssertTrue(engine.evaluate(now: 90_000, environment: notebook).hold)
            engine.receive(event(state, sequence: 2), now: 90_001)
            XCTAssertTrue(engine.evaluate(now: 90_030.999, environment: notebook).hold)
            XCTAssertFalse(engine.evaluate(now: 90_031, environment: notebook).hold)
        }
    }

    func testRepeatedTerminalEventsAndDelayedRunningCannotExtendOrResurrect() {
        var engine = automaticEngine()
        engine.receive(event(.running, sequence: 10), now: 0)
        engine.receive(event(.completed, sequence: 20), now: 100)
        XCTAssertFalse(engine.receive(event(.running, sequence: 19), now: 110))
        XCTAssertFalse(engine.receive(event(.completed, sequence: 20), now: 115))
        XCTAssertTrue(engine.receive(event(.completed, sequence: 21), now: 129))
        XCTAssertTrue(engine.evaluate(now: 129.999, environment: notebook).hold)
        XCTAssertFalse(engine.evaluate(now: 130, environment: notebook).hold)

        XCTAssertTrue(engine.receive(event(.failed, sequence: 22), now: 500))
        XCTAssertFalse(engine.receive(event(.running, sequence: 21), now: 501))
        XCTAssertFalse(engine.evaluate(now: 501, environment: notebook).hold)
    }

    func testNewRunningEventCancelsReleaseAndStartsAnotherTaskLifetime() {
        var engine = automaticEngine()
        engine.receive(event(.running), now: 0)
        engine.receive(event(.completed, sequence: 2), now: 100)
        engine.receive(event(.running, sequence: 3), now: 129)
        XCTAssertTrue(engine.evaluate(now: 130, environment: notebook).hold)
        XCTAssertTrue(engine.evaluate(now: 86_400, environment: notebook).hold)

        engine.receive(event(.cancelled, sequence: 4), now: 86_401)
        XCTAssertTrue(engine.evaluate(now: 86_430.999, environment: notebook).hold)
        XCTAssertFalse(engine.evaluate(now: 86_431, environment: notebook).hold)
    }

    func testMultipleSessionsRequireEveryStartedTaskToExplicitlyFinish() {
        var engine = automaticEngine()
        engine.receive(event(.running, session: "first"), now: 0)
        engine.receive(event(.running, session: "second"), now: 1)
        engine.receive(event(.running, source: "opencode", session: "third"), now: 2)
        engine.receive(event(.completed, sequence: 2, session: "first"), now: 10)
        engine.receive(event(.failed, sequence: 2, source: "opencode", session: "third"), now: 20)
        engine.receive(event(.waiting, sequence: 2, session: "second"), now: 30)
        XCTAssertTrue(engine.evaluate(now: 86_400, environment: notebook).hold)

        engine.receive(event(.cancelled, sequence: 3, session: "second"), now: 86_401)
        XCTAssertTrue(engine.evaluate(now: 86_430.999, environment: notebook).hold)
        XCTAssertFalse(engine.evaluate(now: 86_431, environment: notebook).hold)
    }

    func testEventsWithoutObservedRunningNeverInventHoldOrGrace() {
        for state: KeepAwakeEngine.TaskState in [.waiting, .idle, .completed, .failed, .cancelled] {
            var engine = automaticEngine()
            XCTAssertTrue(engine.receive(event(state), now: 0))
            XCTAssertFalse(engine.evaluate(now: 0, environment: notebook).hold)
            XCTAssertFalse(engine.evaluate(now: 1, environment: notebook).hold)
            XCTAssertFalse(engine.evaluate(now: 86_400, environment: notebook).hold)
        }

        var engine = automaticEngine()
        engine.receive(event(.idle), now: 0)
        engine.receive(event(.waiting, sequence: 2), now: 1)
        XCTAssertFalse(engine.evaluate(now: 2, environment: notebook).hold)
        engine.receive(event(.running, sequence: 3), now: 3)
        XCTAssertTrue(engine.evaluate(now: 4, environment: notebook).hold)
    }

    func testOutOfOrderTerminalEventCannotStopNewerRunningWork() {
        var engine = automaticEngine()
        engine.receive(event(.running, sequence: 5), now: 0)
        engine.receive(event(.waiting, sequence: 6), now: 1)
        engine.receive(event(.running, sequence: 8), now: 2)
        XCTAssertFalse(engine.receive(event(.completed, sequence: 7), now: 3))
        XCTAssertFalse(engine.receive(event(.cancelled, sequence: 8), now: 4))
        XCTAssertTrue(engine.evaluate(now: 86_400, environment: notebook).hold)
    }

    func testManualStopAndPauseTakePriorityOverUnfinishedTask() {
        var engine = automaticEngine()
        engine.receive(event(.running), now: 0)
        engine.togglePause(now: 1)
        XCTAssertFalse(engine.evaluate(now: 2, environment: notebook).hold)
        XCTAssertTrue(engine.evaluate(now: 1_801, environment: notebook).hold)

        engine.stop()
        engine.receive(event(.waiting, sequence: 2), now: 1_802)
        engine.receive(event(.running, sequence: 3), now: 1_803)
        XCTAssertFalse(engine.evaluate(now: 1_804, environment: notebook).hold)
    }

    func testDisconnectRemovesOnlyChosenSourcesLongTaskHold() {
        var engine = automaticEngine()
        engine.receive(event(.running), now: 0)
        engine.receive(event(.running, source: "opencode"), now: 1)
        engine.disconnect(source: "claude-code")
        XCTAssertTrue(engine.evaluate(now: 86_400, environment: notebook).hold)
        engine.disconnect(source: "opencode")
        XCTAssertFalse(engine.evaluate(now: 86_401, environment: notebook).hold)
    }

    func testProtectionStaysLatchedUntilSafeExplicitResumeForLongTask() {
        let unsafeEnvironments: [KeepAwakeEngine.Environment] = [
            .init(hardware: .notebook, battery: 19, onAC: true),
            .init(hardware: .notebook, battery: 80, onAC: false),
            .init(hardware: .notebook, battery: 80, onAC: true, lowPower: true),
            .init(hardware: .notebook, battery: 80, onAC: true, thermalUnsafe: true)
        ]
        for unsafe in unsafeEnvironments {
            var engine = automaticEngine()
            engine.receive(event(.running), now: 0)
            engine.receive(event(.waiting, sequence: 2), now: 1)
            XCTAssertFalse(engine.evaluate(now: 86_400, environment: unsafe).hold)
            XCTAssertFalse(engine.resume(environment: unsafe))
            XCTAssertFalse(engine.evaluate(now: 86_401, environment: notebook).hold)
            XCTAssertTrue(engine.resume(environment: notebook))
            XCTAssertTrue(engine.evaluate(now: 86_402, environment: notebook).hold)
        }
    }
}

final class KeepAwakeLongTaskLeaseTests: XCTestCase {
    func testThirtyHourRenewalHasNoTaskAgeLimitButAppLossExpiresAfterThreeMinutes() throws {
        var power = 0
        var stored: KeepAwakeLease.Journal?
        var powerWrites: [Int] = []
        let owner = UUID().uuidString
        let lease = KeepAwakeLease(journal: nil, readPower: { power }, writePower: { value in
            // The daemon must have persisted recovery intent before applying.
            XCTAssertNotNil(stored)
            powerWrites.append(value)
            power = value
        }, save: { stored = $0 })

        for second in stride(from: 0, through: 108_000, by: 30) {
            let now = Double(second)
            try lease.renew(owner: owner, now: now)
            try lease.expire(now: now + 29)
            XCTAssertEqual(power, 1)
            XCTAssertEqual(stored?.expires, now + 180)
        }
        XCTAssertEqual(powerWrites, [1], "Normal renewals must not toggle the global sleep override.")

        // No more renewals: simulate the main app exiting or becoming unreachable.
        try lease.expire(now: 108_179.999)
        XCTAssertEqual(power, 1)
        try lease.expire(now: 108_180)
        XCTAssertEqual(power, 0)
        XCTAssertNil(stored)
        XCTAssertNil(lease.journal)
        XCTAssertEqual(powerWrites, [1, 0])
    }

    func testLongTaskReleaseRestoresOriginalPowerSettingWithoutWaitingForLeaseExpiry() throws {
        var power = 0
        var stored: KeepAwakeLease.Journal?
        let owner = UUID().uuidString
        let lease = KeepAwakeLease(journal: nil, readPower: { power },
                                   writePower: { power = $0 }, save: { stored = $0 })
        try lease.renew(owner: owner, now: 0)
        for now in stride(from: 30.0, through: 90_000.0, by: 30.0) {
            try lease.renew(owner: owner, now: now)
        }
        XCTAssertEqual(stored?.expires, 90_180)
        try lease.release(owner: owner)
        XCTAssertEqual(power, 0)
        XCTAssertNil(stored)
        XCTAssertNil(lease.journal)
        try lease.expire(now: 90_180)
        XCTAssertEqual(power, 0)
    }
}
