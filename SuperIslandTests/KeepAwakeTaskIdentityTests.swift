import XCTest
import ServiceManagement
@testable import SuperIsland

final class KeepAwakeTaskIdentityTests: XCTestCase {
    private let environment = KeepAwakeEngine.Environment(hardware: .desktop)
    private let taskA = String(repeating: "a", count: 64)
    private let taskB = String(repeating: "b", count: 64)

    func testInitialRunningContinuationStillEstablishesRealWork() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        XCTAssertTrue(engine.receive(event(sequence: 1, state: .running, task: taskA, starts: false), now: 0))
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold)
    }

    func testDelayedContinuationCannotReviveTerminalTaskOrExtendRelease() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        engine.receive(event(sequence: 1, state: .running, task: taskA, starts: true), now: 0)
        engine.receive(event(sequence: 2, state: .completed, task: taskA), now: 10)
        let terminal = engine.sessions.values.first
        XCTAssertFalse(engine.receive(event(sequence: 3, state: .running, task: taskA, starts: false), now: 20))
        XCTAssertFalse(engine.receive(event(sequence: 4, state: .waiting, task: taskA, starts: false), now: 30))
        XCTAssertEqual(engine.sessions.values.first, terminal)
        XCTAssertTrue(engine.evaluate(now: 39, environment: environment).hold)
        XCTAssertFalse(engine.evaluate(now: 40, environment: environment).hold)
    }

    func testExplicitNewStartCanBeginAnotherRoundAfterTerminal() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        engine.receive(event(sequence: 1, state: .running, task: taskA, starts: true), now: 0)
        engine.receive(event(sequence: 2, state: .failed, task: taskA), now: 1)
        XCTAssertFalse(engine.evaluate(now: 31, environment: environment).hold)
        XCTAssertTrue(engine.receive(event(sequence: 3, state: .running, task: taskA, starts: true), now: 32))
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold)
    }

    func testLegacyFixtureWithoutStartDiscriminatorRemainsCompatible() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        engine.receive(event(sequence: 1, state: .running), now: 0)
        engine.receive(event(sequence: 2, state: .cancelled), now: 1)
        XCTAssertTrue(engine.receive(event(sequence: 3, state: .running), now: 32))
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold)
    }

    func testOldTaskTerminalCannotFinishNewTaskInSameSession() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        engine.receive(event(sequence: 1, state: .running, task: taskA, starts: true), now: 0)
        engine.receive(event(sequence: 2, state: .running, task: taskB, starts: true), now: 5)
        engine.receive(event(sequence: 3, state: .completed, task: taskA), now: 10)
        XCTAssertEqual(engine.sessions.count, 2)
        XCTAssertEqual(engine.sessions["claude-code:session:" + taskB]?.event.state, .running)
        XCTAssertTrue(engine.evaluate(now: 200, environment: environment).hold)
        engine.receive(event(sequence: 4, state: .completed, task: taskB), now: 210)
        engine.receive(event(sequence: 5, state: .cancelled, task: taskA), now: 220)
        XCTAssertTrue(engine.evaluate(now: 239, environment: environment).hold)
        XCTAssertFalse(engine.evaluate(now: 240, environment: environment).hold)
    }

    func testCapacityOverflowDoesNotSilentlyDropNewWorkingTask() {
        var engine = fullEngine()
        XCTAssertFalse(engine.evaluate(now: 100, environment: environment).hold)
        XCTAssertFalse(engine.receive(event(session: "overflow", sequence: 10_000, state: .running, starts: true), now: 101))
        XCTAssertTrue(engine.capacityExceededSources.contains("claude-code"))
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold)
        engine.stop()
        XCTAssertFalse(engine.evaluate(now: 10_001, environment: environment).hold)
        engine.setEnabled(true)
        XCTAssertTrue(engine.evaluate(now: 10_002, environment: environment).hold)
        engine.disconnect(source: "claude-code")
        XCTAssertTrue(engine.capacityExceededSources.isEmpty)
        XCTAssertFalse(engine.evaluate(now: 10_003, environment: environment).hold)
    }

    func testCapacityLocksAreClearedOnlyForDisconnectedSource() {
        var engine = fullEngine()
        engine.receive(event(session: "overflow-a", sequence: 10_000, state: .running), now: 101)
        var other = event(session: "overflow-b", sequence: 10_001, state: .running)
        other.source = "pi"
        engine.receive(other, now: 102)
        XCTAssertEqual(engine.capacityExceededSources, Set(["claude-code", "pi"]))
        engine.disconnect(source: "claude-code")
        XCTAssertEqual(engine.capacityExceededSources, Set(["pi"]))
        XCTAssertTrue(engine.evaluate(now: 10_000, environment: environment).hold)
        engine.disconnect(source: "pi")
        XCTAssertFalse(engine.evaluate(now: 10_001, environment: environment).hold)
    }

    func testCapacityDoesNotInventWorkForUnknownIdleSnapshot() {
        var engine = fullEngine()
        XCTAssertFalse(engine.receive(event(session: "overflow-idle", sequence: 10_000, state: .idle), now: 100))
        XCTAssertTrue(engine.capacityExceededSources.isEmpty)
        XCTAssertFalse(engine.evaluate(now: 100, environment: environment).hold)
    }

    @MainActor
    func testAuthorizationRevokedDuringRecoveryCannotBeReenabledByLateSuccess() async {
        var status: SMAppService.Status = .enabled
        let transport = RecoveryAuthorizationTransport()
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: { _, _ in transport }, requestTimeout: 1)
        client.authorize()
        let readyDeadline = KeepAwakeClock.now() + 1
        while !client.enabled && KeepAwakeClock.now() < readyDeadline { await Task.yield() }
        guard client.enabled else { XCTFail("Authorization status did not become ready"); return }
        client.apply(hold: true)
        while !client.applied && KeepAwakeClock.now() < readyDeadline { await Task.yield() }
        guard client.applied else { XCTFail("The owner's renewal did not apply"); return }
        let recovery = Task { await client.recoverAndEnable() }
        let deadline = KeepAwakeClock.now() + 1
        while transport.releaseReply == nil && KeepAwakeClock.now() < deadline { await Task.yield() }
        guard let reply = transport.releaseReply else {
            recovery.cancel(); XCTFail("Recovery release did not start"); return
        }
        status = .requiresApproval
        reply(true, "released")
        let recovered = await recovery.value
        XCTAssertFalse(recovered)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertTrue(client.requiresApproval)
    }

    private func fullEngine() -> KeepAwakeEngine {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        for index in 0..<KeepAwakeEngine.sessionLimit {
            XCTAssertTrue(engine.receive(event(session: "finished-\(index)", sequence: UInt64(index + 1), state: .completed), now: 0))
        }
        return engine
    }

    private func event(session: String = "session", sequence: UInt64, state: KeepAwakeEngine.TaskState,
                       task: String? = nil, starts: Bool? = nil) -> KeepAwakeEngine.Event {
        var event = KeepAwakeEngine.Event(source: "claude-code", session: session, sequence: sequence, state: state)
        event.taskID = task
        event.startsTask = starts
        return event
    }
}

private final class RecoveryAuthorizationTransport: NSObject, KeepAwakeHelperProtocol {
    var releaseReply: ((Bool, String) -> Void)?
    func status(reply: @escaping (Bool, String) -> Void) { reply(true, "test-only") }
    func renew(owner: String, acOnly: Bool, minimumBattery: Int, respectLowPower: Bool,
               reply: @escaping (Bool, String) -> Void) { reply(true, "applied") }
    func release(owner: String, reply: @escaping (Bool, String) -> Void) { releaseReply = reply }
}
