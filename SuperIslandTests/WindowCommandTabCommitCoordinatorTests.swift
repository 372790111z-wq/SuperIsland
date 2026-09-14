import XCTest
@testable import SuperIsland

final class WindowCommandTabCommitCoordinatorTests: XCTestCase {
    private typealias Coordinator = WindowCommandTabCommitCoordinator

    func testVisibleSwitcherKeepsCommitPendingWithoutActivating() {
        var coordinator = Coordinator()
        let ticket = coordinator.begin(sequenceID: 10)

        for _ in 0..<5 {
            XCTAssertEqual(coordinator.observe(visibility: .visible, for: ticket, sequenceID: 10), .wait)
            XCTAssertTrue(coordinator.isCurrent(ticket, sequenceID: 10))
            XCTAssertTrue(coordinator.isPending)
        }
    }

    func testConfirmedAbsenceCanCommitOnlyOnceAfterFinishingTicket() {
        var coordinator = Coordinator()
        let ticket = coordinator.begin(sequenceID: 10)

        XCTAssertEqual(coordinator.observe(visibility: .visible, for: ticket, sequenceID: 10), .wait)
        XCTAssertEqual(coordinator.observe(visibility: .absent, for: ticket, sequenceID: 10), .activate)
        // The caller retains the ticket until its final window/input checks
        // succeed, then finishes it before performing the activation.
        XCTAssertTrue(coordinator.isCurrent(ticket, sequenceID: 10))
        XCTAssertTrue(coordinator.finish(ticket))
        XCTAssertFalse(coordinator.isPending)
        XCTAssertEqual(coordinator.observe(visibility: .absent, for: ticket, sequenceID: 10), .stale)
        XCTAssertFalse(coordinator.finish(ticket))
    }

    func testUnknownVisibilityAbortsAndAllowsANewCommit() {
        var coordinator = Coordinator()
        let failed = coordinator.begin(sequenceID: 10)

        XCTAssertEqual(coordinator.observe(visibility: .unknown, for: failed, sequenceID: 10), .abort)
        XCTAssertTrue(coordinator.finish(failed))
        let retry = coordinator.begin(sequenceID: 10)

        XCTAssertNotEqual(failed, retry)
        XCTAssertTrue(coordinator.isPending)
        XCTAssertEqual(coordinator.observe(visibility: .absent, for: failed, sequenceID: 10), .stale)
        XCTAssertEqual(coordinator.observe(visibility: .absent, for: retry, sequenceID: 10), .activate)
    }

    func testCommandReleaseIsConsumedByPendingCommitWithoutReplacingIt() {
        var coordinator = Coordinator()
        XCTAssertFalse(coordinator.markCommandReleased())
        let ticket = coordinator.begin(sequenceID: 10)

        XCTAssertTrue(coordinator.markCommandReleased())
        XCTAssertTrue(coordinator.commandWasReleased)
        XCTAssertEqual(coordinator.pending, ticket)
        XCTAssertTrue(coordinator.markCommandReleased())
        XCTAssertEqual(coordinator.pending, ticket)
        XCTAssertEqual(coordinator.observe(visibility: .visible, for: ticket, sequenceID: 10), .wait)

        XCTAssertTrue(coordinator.finish(ticket))
        XCTAssertFalse(coordinator.commandWasReleased)
        XCTAssertFalse(coordinator.markCommandReleased())
    }

    func testNewInputInvalidatesAnyLateActivationFromOldCommit() {
        var coordinator = Coordinator()
        let ticket = coordinator.begin(sequenceID: 10)
        XCTAssertTrue(coordinator.markCommandReleased())

        XCTAssertTrue(coordinator.invalidate())
        XCTAssertFalse(coordinator.isPending)
        XCTAssertFalse(coordinator.commandWasReleased)
        XCTAssertFalse(coordinator.isCurrent(ticket, sequenceID: 10))
        XCTAssertEqual(coordinator.observe(visibility: .absent, for: ticket, sequenceID: 10), .stale)
        XCTAssertFalse(coordinator.finish(ticket))
        XCTAssertFalse(coordinator.invalidate())
    }

    func testOldTaskFinishCannotClearReplacementInTheSameCommandSequence() {
        var coordinator = Coordinator()
        let old = coordinator.begin(sequenceID: 10)
        let replacement = coordinator.begin(sequenceID: 10)

        XCTAssertNotEqual(old, replacement)
        XCTAssertFalse(coordinator.finish(old))
        XCTAssertTrue(coordinator.isCurrent(replacement, sequenceID: 10))
        XCTAssertTrue(coordinator.isPending)
        XCTAssertEqual(coordinator.observe(visibility: .unknown, for: old, sequenceID: 10), .stale)
        XCTAssertEqual(coordinator.observe(visibility: .visible, for: replacement, sequenceID: 10), .wait)
    }

    func testDifferentCommandSequenceCannotReuseAValidTicket() {
        var coordinator = Coordinator()
        let ticket = coordinator.begin(sequenceID: 10)

        XCTAssertFalse(coordinator.isCurrent(ticket, sequenceID: 11))
        for visibility in [Coordinator.Visibility.visible, .absent, .unknown] {
            XCTAssertEqual(coordinator.observe(visibility: visibility, for: ticket, sequenceID: 11), .stale)
        }
        XCTAssertTrue(coordinator.isCurrent(ticket, sequenceID: 10))
        XCTAssertEqual(coordinator.observe(visibility: .visible, for: ticket, sequenceID: 10), .wait)
    }

    func testPendingTimeoutCanFinishAndRetryWithoutInheritingReleaseState() {
        var coordinator = Coordinator()
        let timedOut = coordinator.begin(sequenceID: 10)
        XCTAssertTrue(coordinator.markCommandReleased())
        XCTAssertEqual(coordinator.observe(visibility: .visible, for: timedOut, sequenceID: 10), .wait)

        XCTAssertTrue(coordinator.finish(timedOut))
        let retry = coordinator.begin(sequenceID: 11)

        XCTAssertFalse(coordinator.commandWasReleased)
        XCTAssertTrue(coordinator.isCurrent(retry, sequenceID: 11))
        XCTAssertFalse(coordinator.finish(timedOut))
        XCTAssertEqual(coordinator.observe(visibility: .absent, for: retry, sequenceID: 11), .activate)
    }

    func testReconciliationEndsAbsentSessionEvenWhenCommandRemainsHeld() {
        for commandHeld in [true, false] {
            XCTAssertEqual(WindowCommandTabSessionReconciliation.action(
                visibility: .absent, commandHeld: commandHeld
            ), .endSession)
        }
    }

    func testReconciliationRestoresPointerForVisibleSwitcherAfterCommandRelease() {
        for commandHeld in [true, false] {
            XCTAssertEqual(WindowCommandTabSessionReconciliation.action(
                visibility: .visible, commandHeld: commandHeld
            ), .restorePointerSession)
        }
    }

    func testReconciliationCannotKeepUnknownSessionAfterCommandRelease() {
        XCTAssertEqual(WindowCommandTabSessionReconciliation.action(
            visibility: .unknown, commandHeld: false
        ), .endSession)
        XCTAssertEqual(WindowCommandTabSessionReconciliation.action(
            visibility: .unknown, commandHeld: true
        ), .awaitFreshSelection)
    }

    @MainActor
    func testWorkflowWaitsForAbsenceBeforeOneConfirmedCallback() async {
        let probe = WorkflowProbe()
        await probe.run(visibility: [.visible, .visible, .absent])

        XCTAssertEqual(probe.events, [
            "sleep:1", "read:visible", "decision:visible",
            "sleep:2", "read:visible", "decision:visible",
            "sleep:3", "read:absent", "decision:absent", "confirmed"
        ])
        XCTAssertEqual(probe.confirmedCount, 1)
        XCTAssertTrue(probe.abortReasons.isEmpty)
        XCTAssertFalse(probe.coordinator.isPending)
    }

    @MainActor
    func testWorkflowUnknownVisibilityOnlyAborts() async {
        let probe = WorkflowProbe()
        await probe.run(visibility: [.unknown, .absent])

        XCTAssertEqual(probe.visibilityReadCount, 1)
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertEqual(probe.abortReasons, [.visibilityUnknown])
        XCTAssertEqual(probe.events.last, "abort:visibilityUnknown")
    }

    @MainActor
    func testWorkflowAlreadyAbsentSwitcherConfirmsWithoutAnotherPoll() async {
        let probe = WorkflowProbe()
        await probe.run(visibility: [.absent, .unknown])

        XCTAssertEqual(probe.events, ["sleep:1", "read:absent", "decision:absent", "confirmed"])
        XCTAssertEqual(probe.confirmedCount, 1)
        XCTAssertTrue(probe.abortReasons.isEmpty)
        XCTAssertEqual(probe.visibilityReadCount, 1)
    }

    @MainActor
    func testWorkflowVisibleThroughDeadlineOnlyAborts() async {
        let probe = WorkflowProbe()
        await probe.run(visibility: [.visible, .visible, .visible])

        XCTAssertEqual(probe.visibilityReadCount, 3)
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertEqual(probe.abortReasons, [.dismissTimeout])
        XCTAssertFalse(probe.coordinator.isPending)
    }

    @MainActor
    func testWorkflowSupersededDuringSleepCannotReadOrFinishNewCommit() async {
        let probe = WorkflowProbe()
        let old = probe.ticket
        await probe.run(visibility: [.absent], onSleep: {
            probe.coordinator.invalidate()
            probe.ticket = probe.coordinator.begin(sequenceID: probe.sequenceID)
        })

        XCTAssertEqual(probe.events, ["sleep:1"])
        XCTAssertEqual(probe.visibilityReadCount, 0)
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertTrue(probe.abortReasons.isEmpty)
        XCTAssertNotEqual(probe.ticket, old)
        XCTAssertTrue(probe.coordinator.isCurrent(probe.ticket, sequenceID: probe.sequenceID))
    }

    @MainActor
    func testWorkflowSupersededDuringVisibilityReadCannotActOnOldAbsence() async {
        let probe = WorkflowProbe()
        let old = probe.ticket
        await probe.run(visibility: [.absent], onRead: {
            probe.coordinator.invalidate()
            probe.ticket = probe.coordinator.begin(sequenceID: probe.sequenceID)
        })

        XCTAssertEqual(probe.events, ["sleep:1", "read:absent"])
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertTrue(probe.abortReasons.isEmpty)
        XCTAssertNotEqual(probe.ticket, old)
        XCTAssertTrue(probe.coordinator.isCurrent(probe.ticket, sequenceID: probe.sequenceID))
    }

    @MainActor
    func testWorkflowInputChangeDuringVisibilityReadAbortsBeforeConfirmation() async {
        let probe = WorkflowProbe()
        await probe.run(visibility: [.absent], onRead: { probe.valid = false })

        XCTAssertEqual(probe.events, ["sleep:1", "read:absent", "abort:stateChanged"])
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertEqual(probe.abortReasons, [.stateChanged])
    }

    @MainActor
    func testWorkflowSleepErrorDoesNotInvokeCompletionCallbacks() async {
        let probe = WorkflowProbe()
        await probe.run(visibility: [.absent], throwsOnSleep: true)

        XCTAssertEqual(probe.events, ["sleep:1"])
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertTrue(probe.abortReasons.isEmpty)
    }

    @MainActor
    func testWorkflowTaskCancellationAfterSleepCannotConfirmOrAbort() async {
        let probe = WorkflowProbe()
        let task = Task { @MainActor in
            await probe.run(visibility: [.absent], onSleep: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(probe.events, ["sleep:1"])
        XCTAssertEqual(probe.confirmedCount, 0)
        XCTAssertTrue(probe.abortReasons.isEmpty)
    }

    /// Invokes the production workflow with deterministic input/read edges;
    /// it records callbacks without generating input or activating any app.
    @MainActor
    private final class WorkflowProbe {
        private enum SleepFailure: Error { case interrupted }
        var coordinator = Coordinator()
        var ticket: Coordinator.Ticket
        let sequenceID = 10
        var valid = true
        var visibilityReadCount = 0
        var confirmedCount = 0
        var abortReasons: [WindowCommandTabCommitWorkflow.AbortReason] = []
        var events: [String] = []

        init() {
            var initial = Coordinator()
            ticket = initial.begin(sequenceID: 10)
            coordinator = initial
        }

        func run(
            visibility: [Coordinator.Visibility],
            onSleep: (() -> Void)? = nil,
            onRead: (() -> Void)? = nil,
            throwsOnSleep: Bool = false
        ) async {
            let observedTicket = ticket
            await WindowCommandTabCommitWorkflow.run(
                delays: [1, 2, 3],
                isCurrent: { self.coordinator.isCurrent(observedTicket, sequenceID: self.sequenceID) },
                isValid: { self.valid },
                readVisibility: {
                    let next = visibility.indices.contains(self.visibilityReadCount)
                        ? visibility[self.visibilityReadCount] : .unknown
                    self.visibilityReadCount += 1
                    self.events.append("read:\(next.rawValue)")
                    onRead?()
                    return next
                },
                decision: {
                    self.events.append("decision:\($0.rawValue)")
                    return self.coordinator.observe(visibility: $0, for: observedTicket, sequenceID: self.sequenceID)
                },
                sleep: {
                    self.events.append("sleep:\($0)")
                    onSleep?()
                    if throwsOnSleep { throw SleepFailure.interrupted }
                },
                onConfirmed: {
                    self.events.append("confirmed")
                    self.confirmedCount += 1
                    self.coordinator.finish(observedTicket)
                },
                onAbort: {
                    self.events.append("abort:\($0.rawValue)")
                    self.abortReasons.append($0)
                    self.coordinator.finish(observedTicket)
                }
            )
        }
    }
}
