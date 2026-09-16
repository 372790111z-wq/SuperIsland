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

final class WindowCommandTabNativeClickCoordinatorTests: XCTestCase {
    private typealias Coordinator = WindowCommandTabNativeClickCoordinator
    private typealias Visibility = WindowCommandTabCommitCoordinator.Visibility

    func testPreviewPauseSurvivesReleaseUntilTheCurrentClickSettles() {
        var coordinator = Coordinator()
        let ticket = coordinator.begin(sequenceID: 10)

        XCTAssertTrue(coordinator.blocksPreviewUpdates)
        XCTAssertFalse(coordinator.finish(ticket))
        XCTAssertFalse(coordinator.canReconcile(ticket, sequenceID: 10, buttonPressed: false))
        XCTAssertNil(coordinator.markReleased(sequenceID: 11))
        XCTAssertFalse(coordinator.hasReleased)

        XCTAssertEqual(coordinator.markReleased(sequenceID: 10), ticket)
        XCTAssertTrue(coordinator.blocksPreviewUpdates)
        XCTAssertFalse(coordinator.canReconcile(ticket, sequenceID: 10, buttonPressed: true))
        XCTAssertTrue(coordinator.canReconcile(ticket, sequenceID: 10, buttonPressed: false))
        XCTAssertTrue(coordinator.finish(ticket))
        XCTAssertFalse(coordinator.blocksPreviewUpdates)
        XCTAssertFalse(coordinator.hasReleased)
        XCTAssertFalse(coordinator.finish(ticket))
    }

    func testSecondClickInSameSequenceDoesNotInheritReleaseOrOldCompletion() {
        var coordinator = Coordinator()
        let old = coordinator.begin(sequenceID: 10)
        coordinator.markReleased(sequenceID: 10)
        let replacement = coordinator.begin(sequenceID: 10)

        XCTAssertNotEqual(old, replacement)
        XCTAssertFalse(coordinator.hasReleased)
        XCTAssertFalse(coordinator.finish(old))
        XCTAssertFalse(coordinator.canReconcile(old, sequenceID: 10, buttonPressed: false))
        XCTAssertEqual(coordinator.pending, replacement)
        XCTAssertTrue(coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testReleasedClickHandsSelectionToKeyboardAndRejectsItsLateReadback() async {
        let probe = NativeClickProbe()
        probe.release()
        let old = probe.ticket
        var refreshRequests = 0
        await probe.run(visibility: [.visible], onRead: {
            if probe.coordinator.resumeForKeyboardInput(buttonPressed: probe.buttonPressed) {
                refreshRequests += 1
            }
        })

        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(probe.events, ["sleep:50000000", "read:visible"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertFalse(probe.coordinator.blocksPreviewUpdates)
        XCTAssertFalse(probe.coordinator.finish(old))
        XCTAssertFalse(probe.coordinator.resumeForKeyboardInput(buttonPressed: false))

        probe.beginReplacement()
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
        XCTAssertFalse(probe.coordinator.hasReleased)
        XCTAssertFalse(probe.coordinator.finish(old))
        XCTAssertFalse(probe.coordinator.resumeForKeyboardInput(buttonPressed: probe.buttonPressed))
        XCTAssertEqual(probe.coordinator.pending, probe.ticket)
    }

    func testKeyboardInputDuringPhysicalPressKeepsTheOriginalClickProtected() {
        var coordinator = Coordinator()
        let ticket = coordinator.begin(sequenceID: 10)

        XCTAssertFalse(coordinator.resumeForKeyboardInput(buttonPressed: true))
        XCTAssertEqual(coordinator.pending, ticket)
        XCTAssertTrue(coordinator.blocksPreviewUpdates)
        XCTAssertFalse(coordinator.hasReleased)

        // A delayed release observation must not override a newer physical
        // press, even before its down callback can establish a new ticket.
        coordinator.markReleased(sequenceID: 10)
        XCTAssertFalse(coordinator.resumeForKeyboardInput(buttonPressed: true))
        XCTAssertEqual(coordinator.pending, ticket)
        XCTAssertTrue(coordinator.hasReleased)
    }

    func testCancellationAndNewSequenceRejectAnOldReleaseAndCompletion() {
        var coordinator = Coordinator()
        let old = coordinator.begin(sequenceID: 10)
        coordinator.markReleased(sequenceID: 10)
        XCTAssertTrue(coordinator.invalidate())
        XCTAssertFalse(coordinator.blocksPreviewUpdates)
        XCTAssertFalse(coordinator.hasReleased)
        XCTAssertFalse(coordinator.invalidate())
        let replacement = coordinator.begin(sequenceID: 11)

        XCTAssertNil(coordinator.markReleased(sequenceID: 10))
        XCTAssertFalse(coordinator.canReconcile(old, sequenceID: 11, buttonPressed: false))
        XCTAssertFalse(coordinator.finish(old))
        XCTAssertTrue(coordinator.isCurrent(replacement, sequenceID: 11))
        XCTAssertFalse(coordinator.hasReleased)
    }

    @MainActor
    func testHeldNativeClickDoesNotReadOrPublishEvenWhenTheStripIsVisible() async {
        let probe = NativeClickProbe()
        await probe.run(visibility: [.visible])

        XCTAssertEqual(probe.events, ["sleep:50000000"])
        XCTAssertEqual(probe.visibilityReadCount, 0)
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testVisibleNativeClickWaitsAllStagesBeforeResumingPreview() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.visible, .visible, .visible, .visible], onRead: {
            XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
            XCTAssertTrue(probe.settled.isEmpty)
        })

        XCTAssertEqual(probe.events, [
            "sleep:50000000", "read:visible",
            "sleep:100000000", "read:visible",
            "sleep:150000000", "read:visible",
            "sleep:150000000", "read:visible", "settled:visible"
        ])
        XCTAssertEqual(probe.elapsedNanoseconds, 450_000_000)
        XCTAssertEqual(probe.settled, [.visible])
        XCTAssertFalse(probe.coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testNativeDismissalAfterSeveralStagesEndsBeforeTheDeadline() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.visible, .visible, .absent, .visible])

        XCTAssertEqual(probe.visibilityReadCount, 3)
        XCTAssertEqual(probe.elapsedNanoseconds, 300_000_000)
        XCTAssertEqual(probe.settled, [.absent])
        XCTAssertFalse(probe.coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testAlreadyDismissedNativeClickDoesNotWaitOrPublishAgain() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.absent, .visible])

        XCTAssertEqual(probe.events, ["sleep:50000000", "read:absent", "settled:absent"])
        XCTAssertEqual(probe.settled, [.absent])
    }

    @MainActor
    func testUnknownVisibilityRemainsPausedUntilTheBoundedDeadline() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.unknown, .unknown, .visible, .unknown], onRead: {
            XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
            XCTAssertTrue(probe.settled.isEmpty)
        })

        XCTAssertEqual(probe.visibilityReadCount, 4)
        XCTAssertEqual(probe.elapsedNanoseconds, 450_000_000)
        XCTAssertEqual(probe.settled, [.unknown])
        XCTAssertFalse(probe.coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testUnknownReadDoesNotPreventLaterConfirmedNativeDismissal() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.unknown, .absent])

        XCTAssertEqual(probe.visibilityReadCount, 2)
        XCTAssertEqual(probe.elapsedNanoseconds, 150_000_000)
        XCTAssertEqual(probe.settled, [.absent])
    }

    @MainActor
    func testNewClickDuringDelayCannotBeReleasedByTheOldWorkflow() async {
        let probe = NativeClickProbe()
        probe.release()
        let old = probe.ticket
        await probe.run(visibility: [.absent], onSleep: { probe.beginReplacement() })

        XCTAssertEqual(probe.events, ["sleep:50000000"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertNotEqual(probe.ticket, old)
        XCTAssertEqual(probe.coordinator.pending, probe.ticket)
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
        XCTAssertFalse(probe.coordinator.hasReleased)
    }

    @MainActor
    func testNewClickDuringAXReadCannotSettleUsingTheOldAbsence() async {
        let probe = NativeClickProbe()
        probe.release()
        let old = probe.ticket
        await probe.run(visibility: [.absent], onRead: { probe.beginReplacement() })

        XCTAssertEqual(probe.events, ["sleep:50000000", "read:absent"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertNotEqual(probe.ticket, old)
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
        XCTAssertFalse(probe.coordinator.hasReleased)
    }

    @MainActor
    func testNewCommandSequenceDuringAXReadCannotReviveTheOldPreview() async {
        let probe = NativeClickProbe()
        probe.release()
        let old = probe.ticket
        await probe.run(visibility: [.visible], onRead: {
            probe.coordinator.invalidate()
            probe.sequenceID += 1
            probe.beginReplacement()
        })

        XCTAssertEqual(probe.events, ["sleep:50000000", "read:visible"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertFalse(probe.coordinator.finish(old))
        XCTAssertTrue(probe.coordinator.isCurrent(probe.ticket, sequenceID: 11))
    }

    @MainActor
    func testPhysicalPressDuringAXReadPreventsPreviewResumption() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.absent], onRead: { probe.buttonPressed = true })

        XCTAssertEqual(probe.events, ["sleep:50000000", "read:absent"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testInterruptedNativeClickDelayDoesNotReleaseThePause() async {
        let probe = NativeClickProbe()
        probe.release()
        await probe.run(visibility: [.absent], throwsOnSleep: true)

        XCTAssertEqual(probe.events, ["sleep:50000000"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
    }

    @MainActor
    func testCancelledNativeClickTaskCannotReadOrPublish() async {
        let probe = NativeClickProbe()
        probe.release()
        let task = Task { @MainActor in
            await probe.run(visibility: [.absent], onSleep: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await task.value

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(probe.events, ["sleep:50000000"])
        XCTAssertTrue(probe.settled.isEmpty)
        XCTAssertTrue(probe.coordinator.blocksPreviewUpdates)
    }

    /// Calls the production settling workflow; injected sleep/AX boundaries
    /// expose publication timing and supersession without generating input.
    @MainActor
    private final class NativeClickProbe {
        private enum SleepFailure: Error { case interrupted }
        var coordinator = Coordinator()
        var ticket: Coordinator.Ticket
        var sequenceID = 10
        var buttonPressed = true
        var visibilityReadCount = 0
        var elapsedNanoseconds: UInt64 = 0
        var settled: [Visibility] = []
        var events: [String] = []

        init() {
            var initial = Coordinator()
            ticket = initial.begin(sequenceID: 10)
            coordinator = initial
        }

        func release() {
            buttonPressed = false
            coordinator.markReleased(sequenceID: sequenceID)
        }

        func beginReplacement() {
            buttonPressed = true
            ticket = coordinator.begin(sequenceID: sequenceID)
        }

        func run(
            visibility: [Visibility],
            onSleep: (() -> Void)? = nil,
            onRead: (() -> Void)? = nil,
            throwsOnSleep: Bool = false
        ) async {
            let observedTicket = ticket
            await WindowCommandTabNativeClickWorkflow.run(
                isCurrent: { self.coordinator.isCurrent(observedTicket, sequenceID: self.sequenceID) },
                isReleased: {
                    self.coordinator.canReconcile(
                        observedTicket, sequenceID: self.sequenceID, buttonPressed: self.buttonPressed
                    )
                },
                readVisibility: {
                    let next = visibility.indices.contains(self.visibilityReadCount)
                        ? visibility[self.visibilityReadCount] : .unknown
                    self.visibilityReadCount += 1
                    self.events.append("read:\(next.rawValue)")
                    onRead?()
                    return next
                },
                sleep: {
                    self.elapsedNanoseconds += $0
                    self.events.append("sleep:\($0)")
                    onSleep?()
                    if throwsOnSleep { throw SleepFailure.interrupted }
                },
                onSettled: {
                    guard self.coordinator.finish(observedTicket) else {
                        XCTFail("An obsolete click reached the settling callback")
                        return
                    }
                    self.events.append("settled:\($0.rawValue)")
                    self.settled.append($0)
                }
            )
        }
    }
}
