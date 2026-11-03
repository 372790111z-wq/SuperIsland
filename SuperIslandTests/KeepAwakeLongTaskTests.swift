import XCTest
@testable import SuperIsland

final class KeepAwakeCompletionSleepTests: XCTestCase {
    private let notebook = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true)
    private let closed = KeepAwakeCompletionSleep.Snapshot(lidClosed: true, externalDisplays: 0, sleepDisabled: false, cpuSleepBlocked: false)

    private var clearCPUAssertions: [String: Any] {
        Dictionary(uniqueKeysWithValues: KeepAwakeSystemSleep.cpuAssertionTypes.map { ($0, NSNumber(value: 0)) })
    }

    func testPowerdBackgroundCPUIsNotHiddenByClearDriverMask() {
        var levels = clearCPUAssertions
        levels["BackgroundTask"] = NSNumber(value: 1)
        XCTAssertEqual(KeepAwakeSystemSleep.cpuSleepBlocked(NSNumber(value: 256)), false)
        XCTAssertEqual(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 256), levels: levels), true)
        levels["BackgroundTask"] = NSNumber(value: 0)
        levels["PreventUserIdleSystemSleep"] = NSNumber(value: 1)
        levels["PreventUserIdleDisplaySleep"] = NSNumber(value: 1)
        XCTAssertEqual(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 256), levels: levels), false)
    }
    func testCPUBlockingDiagnosticsUseAggregateTypesAndPreserveUnknown() {
        var levels = clearCPUAssertions
        XCTAssertEqual(KeepAwakeSystemSleep.cpuBlockingTypes(driver: NSNumber(value: 0), levels: levels), [])
        levels["BackgroundTask"] = NSNumber(value: 1)
        levels["PreventUserIdleSystemSleep"] = NSNumber(value: 1)
        XCTAssertEqual(KeepAwakeSystemSleep.cpuBlockingTypes(driver: NSNumber(value: 0), levels: levels), ["BackgroundTask"])
        XCTAssertEqual(KeepAwakeSystemSleep.cpuBlockingTypes(driver: NSNumber(value: 1), levels: levels), ["KernelCPU", "BackgroundTask"])
        XCTAssertNil(KeepAwakeSystemSleep.cpuBlockingTypes(driver: NSNumber(value: 0), levels: nil))
        levels["BackgroundTask"] = NSNumber(value: 0.5)
        XCTAssertNil(KeepAwakeSystemSleep.cpuBlockingTypes(driver: NSNumber(value: 0), levels: levels))
    }
    func testCapturedLongDarkWakeWaitsForMaintenanceReleaseAndStillRejectsNewWork() {
        for newWork in [false, true] {
            var gate = acceptedBatch(), blocked = closed
            _ = gate.observeKernelWake(kernelSnapshot(1000, 1001), now: 100)
            XCTAssertTrue(gate.observeKernelWake(kernelSnapshot(2000, 2001), now: 200))
            blocked.cpuSleepBlocked = true; blocked.cpuBlockingTypes = ["BackgroundTask"]
            for now in stride(from: 200.0, through: 7020, by: 5) {
                XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked, now: now))
            }
            XCTAssertTrue(gate.waitingForCPU)
            if newWork { _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: false, snapshot: blocked, now: 7021) }
            let shouldRequest = gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 7022)
            XCTAssertEqual(shouldRequest, !newWork)
            if shouldRequest { gate.requested(.accepted) }
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 99999))
        }
    }

    func testEveryPowerdCPUTypeBlocksAndKnownBlockWinsOverUnknown() {
        for key in KeepAwakeSystemSleep.cpuAssertionTypes {
            var levels = clearCPUAssertions; levels[key] = NSNumber(value: 1)
            XCTAssertEqual(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 0), levels: levels), true, key)
            XCTAssertEqual(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: nil, levels: levels), true, key)
        }
        XCTAssertEqual(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 1), levels: nil), true)
    }

    func testAggregateCPUUnavailableMalformedOrUnsupportedIsUnknown() {
        XCTAssertNil(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 0), levels: nil))
        XCTAssertNil(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 0), levels: [:]))
        XCTAssertNil(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: nil, levels: clearCPUAssertions))
        for key in KeepAwakeSystemSleep.cpuAssertionTypes {
            for invalid: Any in [true, false, "0", NSNumber(value: -1), NSNumber(value: 0.5), NSNumber(value: 2), NSNull()] {
                var levels = clearCPUAssertions; levels[key] = invalid
                XCTAssertNil(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 0), levels: levels), key)
            }
            var levels = clearCPUAssertions; levels.removeValue(forKey: key)
            XCTAssertNil(KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 0), levels: levels), key)
        }
    }

    func testCapturedNinetySixMinuteBackgroundHoldDefersWithoutCallingSleep() {
        var gate = armed(), blocked = closed, levels = clearCPUAssertions, calls = 0
        levels["BackgroundTask"] = NSNumber(value: 1)
        blocked.cpuSleepBlocked = KeepAwakeSystemSleep.aggregateCPUSleepBlocked(driver: NSNumber(value: 256), levels: levels)
        for now in stride(from: 0.0, through: 5777, by: 5) {
            if gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked, now: now) { calls += 1 }
        }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(gate.armed)
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 5778))
        gate.requested(.accepted)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 99999))
    }

    func testAcceptedButCPUBlockedSleepCanRecoverOnlyAfterObservedReleaseAndFreshChecks() {
        var gate = acceptedBatch(), blocked = closed
        blocked.cpuSleepBlocked = true
        gate.systemWillSleep() // The notification is not actual sleep.
        for now in stride(from: 131.0, through: 5907, by: 5) {
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked, now: now))
        }
        XCTAssertFalse(gate.armed)
        XCTAssertTrue(gate.waitingForCPU)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 5908))
        XCTAssertEqual(gate.wakeRecheckAt, 5938)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 5937.999))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 5938, sourcesRefreshed: false))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false, snapshot: closed, now: 5938))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 5938))
        gate.requested(.accepted)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 99999))
    }

    func testUnknownCPUAfterAcceptedRequestDoesNotInventARecordedVeto() {
        var gate = acceptedBatch(), unknown = closed; unknown.cpuSleepBlocked = nil
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: unknown, now: 200))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 1000))
        XCTAssertNil(gate.wakeRecheckAt)
    }

    func testPostAcceptanceCPURecoveryCancelledByOpenStopForeignOverrideAndNewWork() {
        for mode in 0..<6 {
            var gate = acceptedBatch(), blocked = closed; blocked.cpuSleepBlocked = true
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked, now: 200))
            if mode < 3 {
                var physical = closed
                if mode == 0 { physical.lidClosed = false }
                if mode == 1 { physical.externalDisplays = 1 }
                if mode == 2 { physical.sleepDisabled = true }
                _ = gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: physical, now: 201)
            } else if mode == 3 { gate.cancel() }
            else { _ = gate.update(phase: mode == 4 ? .inactive : .unfinished, ownsLidHold: false, releasesConfirmed: false, snapshot: closed, now: 201) }
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 1000))
        }
    }

    func testActualSleepDuringPostAcceptanceCPUWaitUsesRealWakeGrace() {
        var gate = acceptedBatch(), blocked = closed; blocked.cpuSleepBlocked = true
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked, now: 200))
        gate.systemWillSleep()
        XCTAssertTrue(gate.observeClock(continuous: 800, awake: 200))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 829))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 830))
    }

    func testKernelCPUDecoderDistinguishesMagicWakeAndUnknown() {
        XCTAssertEqual(KeepAwakeSystemSleep.cpuSleepBlocked(NSNumber(value: 0)), false)
        XCTAssertEqual(KeepAwakeSystemSleep.cpuSleepBlocked(NSNumber(value: 1)), true)
        XCTAssertEqual(KeepAwakeSystemSleep.cpuSleepBlocked(NSNumber(value: 256)), false)
        XCTAssertEqual(KeepAwakeSystemSleep.cpuSleepBlocked(NSNumber(value: 257)), true)
        XCTAssertEqual(KeepAwakeSystemSleep.cpuSleepBlocked(NSNumber(value: UInt32.max)), true)
        for value: Any? in [nil, true, false, "0", NSNumber(value: -1), NSNumber(value: 0.5), NSNumber(value: Double.infinity)] {
            XCTAssertNil(KeepAwakeSystemSleep.cpuSleepBlocked(value))
        }
    }

    func testCapturedSeventyFiveMinuteCPUHoldPreservesOneWakeRequestWithoutPollingSleepAPI() {
        var gate = armed(), calls = 0
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        gate.requested(.accepted)
        _ = gate.observeClock(continuous: 0, awake: 0)
        XCTAssertTrue(gate.observeClock(continuous: 400, awake: 30))
        var blocked = closed; blocked.cpuSleepBlocked = true
        for now in stride(from: 430.0, through: 4_909, by: 5) {
            if gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                           snapshot: blocked, now: now) { calls += 1 }
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 4_910, sourcesRefreshed: false))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 4_910, sourcesRefreshed: true))
        let result = KeepAwakeCompletionSleep.attempt(snapshot: { self.closed }, request: { calls += 1; return 0 })
        XCTAssertEqual(result, .accepted); gate.requested(result)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 99_999))
    }

    func testUnknownOrBlockedCPUWaitsWithoutConsumingOriginalEligibility() {
        for value: Bool? in [true, nil] {
            var gate = armed(), blocked = closed
            blocked.cpuSleepBlocked = value
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                snapshot: blocked, now: 100))
            XCTAssertTrue(gate.armed)
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                snapshot: closed, now: 101))
        }
    }

    func testFinalCPURecheckDefersWithoutCallingAPIAndKeepsEligibility() {
        for value: Bool? in [true, nil] {
            var gate = armed(), changed = closed, calls = 0
            changed.cpuSleepBlocked = value
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
            let result = KeepAwakeCompletionSleep.attempt(snapshot: { changed }, request: { calls += 1; return 0 })
            XCTAssertEqual(result, .deferred); XCTAssertEqual(calls, 0)
            gate.requested(result)
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: changed))
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        }
    }

    func testDeferredCPURequestCannotSurviveOpenStopOrNewUnheldWork() {
        for mode in 0..<3 {
            var gate = armed()
            gate.requested(.deferred)
            if mode == 0 {
                var open = closed; open.lidClosed = false; gate.observePhysical(open)
            } else {
                _ = gate.update(phase: mode == 1 ? .inactive : .unfinished,
                    ownsLidHold: false, releasesConfirmed: true, snapshot: closed)
            }
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        }
    }

    func testWaitingCPURequestCannotSurviveNewUnheldWork() {
        var gate = armed(), blocked = closed; blocked.cpuSleepBlocked = true
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked))
        _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: false, snapshot: blocked)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
    }

    func testDeferredCPURequestStillRequiresConfirmedReleaseAndPhysicalSafety() {
        var gate = armed(); gate.requested(.deferred)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false, snapshot: closed))
        var foreign = closed; foreign.sleepDisabled = true
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: foreign))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
    }

    func testSystemSleepingBeforeDeferredRequestStillNeedsFreshWakeGraceAndSources() {
        var gate = armed(), blocked = closed; blocked.cpuSleepBlocked = true
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked))
        _ = gate.observeClock(continuous: 100, awake: 100)
        gate.systemWillSleep()
        XCTAssertTrue(gate.observeClock(continuous: 500, awake: 101))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 529))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 530, sourcesRefreshed: false))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 530, sourcesRefreshed: true))
    }

    private func event(_ state: KeepAwakeEngine.TaskState, session: String = "one", sequence: UInt64 = 1) -> KeepAwakeEngine.Event {
        .init(source: "codex-desktop", session: session, sequence: sequence, state: state)
    }
    private func completedEngine() -> KeepAwakeEngine {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        engine.receive(event(.running), now: 0)
        engine.receive(event(.completed, sequence: 2), now: 10)
        return engine
    }
    private func armed() -> KeepAwakeCompletionSleep {
        var gate = KeepAwakeCompletionSleep()
        XCTAssertFalse(gate.update(phase: .unfinished, ownsLidHold: true, releasesConfirmed: false, snapshot: closed))
        return gate
    }

    func testLastTaskTerminalControlsSleepDeadline() {
        var engine = completedEngine()
        engine.receive(event(.running, session: "two"), now: 20)
        XCTAssertEqual(engine.completionSleepPhase(now: 45, environment: notebook), .unfinished)
        engine.receive(event(.failed, session: "two", sequence: 2), now: 50)
        XCTAssertEqual(engine.completionSleepPhase(now: 79.999, environment: notebook), .grace)
        XCTAssertEqual(engine.completionSleepPhase(now: 80, environment: notebook), .ready)
        engine.receive(event(.failed, session: "two", sequence: 3), now: 85)
        XCTAssertEqual(engine.completionSleepPhase(now: 85, environment: notebook), .ready)
    }

    func testWaitingIdleAndSilentTasksCannotRequestSleep() {
        for state: KeepAwakeEngine.TaskState in [.running, .waiting, .idle] {
            var engine = completedEngine()
            engine.receive(event(.running, session: "two"), now: 20)
            engine.receive(event(state, session: "two", sequence: 2), now: 25)
            XCTAssertEqual(engine.completionSleepPhase(now: 86_400, environment: notebook), .unfinished)
        }
    }

    func testNoStartedTaskOrDisconnectedTaskCannotBecomeReady() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        engine.receive(event(.completed), now: 0)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
        engine = completedEngine()
        engine.disconnect(source: "codex-desktop")
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
    }

    func testStoppedPausedManualProtectedAndDesktopCannotSleep() {
        var engine = completedEngine()
        engine.stop()
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
        engine = completedEngine(); engine.togglePause(now: 20)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
        engine = completedEngine(); engine.startManual(minutes: 30, now: 20)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
        engine = completedEngine()
        var unsafe = notebook; unsafe.lowPower = true
        _ = engine.evaluate(now: 41, environment: unsafe)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
        engine = completedEngine()
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: .init(hardware: .desktop)), .inactive)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: .init()), .inactive)
    }

    func testLowPowerCannotReplaceAnExistingThermalSafetyLatch() {
        var engine = completedEngine(), hot = notebook, low = notebook
        hot.thermalUnsafe = true; low.lowPower = true
        _ = engine.evaluate(now: 40, environment: hot)
        _ = engine.evaluate(now: 41, environment: low)
        XCTAssertTrue(engine.hasThermalProtection)
        XCTAssertFalse(engine.evaluate(now: 100, environment: notebook).hold)
    }

    func testOnlyLowPowerInAutomaticModeIsEligibleForRecovery() {
        var engine = completedEngine(), low = notebook
        low.lowPower = true
        _ = engine.evaluate(now: 40, environment: low)
        XCTAssertFalse(engine.canAutomaticallyRecoverLowPower(now: 100, environment: low))
        XCTAssertTrue(engine.canAutomaticallyRecoverLowPower(now: 100, environment: notebook))
        for time in [Double.nan, Double.infinity, -1] {
            XCTAssertFalse(engine.canAutomaticallyRecoverLowPower(now: time, environment: notebook))
        }
        XCTAssertFalse(engine.canAutomaticallyRecoverLowPower(now: 100, environment: .init()))
        engine.togglePause(now: 100)
        XCTAssertFalse(engine.canAutomaticallyRecoverLowPower(now: 100, environment: notebook))
        engine.selectMode(.manual)
        XCTAssertFalse(engine.canAutomaticallyRecoverLowPower(now: 100, environment: notebook))
        engine.selectMode(.automatic); engine.stop()
        XCTAssertFalse(engine.canAutomaticallyRecoverLowPower(now: 100, environment: notebook))
    }

    func testAutomaticRecoveryNeedsStableConditionsAndHasBoundedRetries() {
        var gate = KeepAwakeLowPowerRecovery()
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 100))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 129.999))
        XCTAssertTrue(gate.shouldAttempt(eligible: true, now: 130))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 189.999))
        XCTAssertTrue(gate.shouldAttempt(eligible: true, now: 190))
        XCTAssertTrue(gate.shouldAttempt(eligible: true, now: 250))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 10000))
        XCTAssertEqual(gate.attempts, 3)
        XCTAssertFalse(gate.shouldAttempt(eligible: false, now: 10001))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 10002))
        XCTAssertTrue(gate.shouldAttempt(eligible: true, now: 10032))
    }

    func testInterruptedOrInvalidRecoveryClockCannotSkipStabilization() {
        for invalid in [Double.nan, Double.infinity, -1, 99] {
            var gate = KeepAwakeLowPowerRecovery()
            XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 100))
            XCTAssertFalse(gate.shouldAttempt(eligible: true, now: invalid))
            XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 101))
        }
        var gate = KeepAwakeLowPowerRecovery()
        _ = gate.shouldAttempt(eligible: true, now: 0)
        XCTAssertFalse(gate.shouldAttempt(eligible: false, now: 29))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 30))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 59))
        XCTAssertTrue(gate.shouldAttempt(eligible: true, now: 60))
    }

    func testSleepingDoesNotSatisfyTheLowPowerRecoverySafeDelay() {
        var gate = KeepAwakeLowPowerRecovery()
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 0, awake: 0))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 29, awake: 29))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 1000, awake: 30))
        XCTAssertFalse(gate.shouldAttempt(eligible: true, now: 1029, awake: 59))
        XCTAssertTrue(gate.shouldAttempt(eligible: true, now: 1030, awake: 60))
    }

    func testThermalStopDoesNotPreventSleepAfterExplicitTaskCompletion() {
        var engine = completedEngine()
        var hot = notebook; hot.thermalUnsafe = true
        XCTAssertFalse(engine.evaluate(now: 35, environment: hot).hold)
        XCTAssertEqual(engine.completionSleepPhase(now: 39, environment: hot), .grace)
        XCTAssertEqual(engine.completionSleepPhase(now: 40, environment: hot), .ready)
        // Cooling does not silently resume keeping, or erase sleep eligibility.
        XCTAssertFalse(engine.evaluate(now: 41, environment: notebook).hold)
        XCTAssertNotNil(engine.protection)
        XCTAssertEqual(engine.completionSleepPhase(now: 41, environment: notebook), .ready)
    }

    func testWaitsForBothPowerAndLidReleaseAcknowledgement() {
        var gate = armed()
        XCTAssertFalse(gate.update(phase: .grace, ownsLidHold: true, releasesConfirmed: false, snapshot: closed))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false, snapshot: closed))
        XCTAssertTrue(gate.armed)
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
    }

    func testHistoricalCompletionWithoutAnOwnedLidHoldNeverSleeps() {
        var gate = KeepAwakeCompletionSleep()
        _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: false, snapshot: closed)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
    }

    func testNewWorkDuringReleaseCancelsReadyUntilItAlsoFinishes() {
        var engine = completedEngine()
        var gate = armed()
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 40, environment: notebook),
                                   ownsLidHold: false, releasesConfirmed: false, snapshot: closed))
        engine.receive(event(.running, session: "two"), now: 40.5)
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 41, environment: notebook),
                                   ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        engine.receive(event(.cancelled, session: "two", sequence: 2), now: 50)
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 79, environment: notebook),
                                   ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        XCTAssertTrue(gate.update(phase: engine.completionSleepPhase(now: 80, environment: notebook),
                                  ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
    }

    func testOpenExternalOrUnknownConsumesCompletionWithoutDelayedSleep() {
        for snapshot in [
            KeepAwakeCompletionSleep.Snapshot(lidClosed: false, externalDisplays: 0, sleepDisabled: false),
            .init(lidClosed: true, externalDisplays: 1, sleepDisabled: false),
            .init(lidClosed: nil, externalDisplays: 0, sleepDisabled: false),
            .init(lidClosed: true, externalDisplays: nil, sleepDisabled: false)
        ] {
            var gate = armed()
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false, snapshot: snapshot))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        }
    }

    func testForeignOrUnknownSleepDisabledCannotRequestOrRetry() {
        for flag: Bool? in [true, nil] {
            var gate = armed()
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                                       snapshot: .init(lidClosed: true, externalDisplays: 0, sleepDisabled: flag)))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        }
    }

    func testInactiveAndExplicitCancellationRequireNewOwnedWorkToRearm() {
        for explicit in [true, false] {
            var gate = armed()
            if explicit { gate.cancel() }
            else { _ = gate.update(phase: .inactive, ownsLidHold: false, releasesConfirmed: true, snapshot: closed) }
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
            _ = gate.update(phase: .unfinished, ownsLidHold: true, releasesConfirmed: false, snapshot: closed)
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
        }
    }

    func testCapacityUnknownCannotReachCompletionSleep() {
        var engine = KeepAwakeEngine()
        engine.setAutomatic(true)
        for index in 0..<KeepAwakeEngine.sessionLimit {
            engine.receive(event(.completed, session: "terminal-\(index)"), now: 0)
        }
        engine.receive(event(.running, session: "overflow"), now: 1)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
    }

    func testPhysicalRecheckPreventsSleepAfterLidOrDisplayChanges() {
        for changed in [
            KeepAwakeCompletionSleep.Snapshot(lidClosed: false, externalDisplays: 0, sleepDisabled: false),
            .init(lidClosed: true, externalDisplays: 1, sleepDisabled: false),
            .init(lidClosed: true, externalDisplays: 0, sleepDisabled: true),
            .init()
        ] {
            var gate = armed(); var calls = 0
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
            XCTAssertEqual(KeepAwakeCompletionSleep.attempt(snapshot: { changed }, request: { calls += 1; return 0 }), .skipped)
            XCTAssertEqual(calls, 0)
        }
    }

    func testAcceptedAndRejectedRequestsAreNotRetriedForHistoricalTerminals() {
        for status: Int32 in [0, -1] {
            var gate = armed(); var calls = 0
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
            XCTAssertEqual(KeepAwakeCompletionSleep.attempt(snapshot: { self.closed }, request: { calls += 1; return status }),
                           status == 0 ? .accepted : .failed(status))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed))
            XCTAssertEqual(calls, 1)
        }
    }

    private func kernelSnapshot(_ slept: Double, _ woke: Double) -> KeepAwakeCompletionSleep.Snapshot {
        var value = closed; value.kernelSleepTime = slept; value.kernelWakeTime = woke; return value
    }
    func testSubsecondKernelWakeDetectedButFirstStaleInvalidAndUnownedPairsCannotArm() {
        var gate = acceptedBatch()
        XCTAssertFalse(gate.observeKernelWake(kernelSnapshot(1000, 1000.16), now: 100))
        XCTAssertFalse(gate.observeClock(continuous: 141, awake: 140.84))
        XCTAssertTrue(gate.observeKernelWake(kernelSnapshot(1040, 1040.16), now: 141))
        XCTAssertEqual(gate.wakeRecheckAt, 201)
        for pair in [(1040.0,1040.16), (1000,1000.16), (1050,1049), (0,1050), (1050,Double.nan)] {
            XCTAssertFalse(gate.observeKernelWake(kernelSnapshot(pair.0, pair.1), now: 150))
        }
        XCTAssertEqual(gate.wakeRecheckAt, 201)
        gate.cancel()
        XCTAssertFalse(gate.observeKernelWake(kernelSnapshot(1100,1100.16), now: 200))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 300))
    }
    func testCapturedNineMaintenanceWakesAndCPULingerDoNotIssueRedundantRequests() {
        var gate = acceptedBatch(), calls = 0
        XCTAssertFalse(gate.observeKernelWake(kernelSnapshot(1000,1000.16), now: 100))
        for cycle in 1...9 {
            let now = 100 + Double(cycle) * 41
            gate.systemWillSleep()
            XCTAssertTrue(gate.observeKernelWake(kernelSnapshot(1000 + Double(cycle)*41,1000.16 + Double(cycle)*41), now: now))
            var blocked = closed; blocked.cpuSleepBlocked = true
            for delta in [0.0, 5, 10, 30, 40] {
                let snapshot = delta < 10 ? blocked : closed
                if gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: snapshot, now: now + delta) { calls += 1 }
            }
        }
        XCTAssertEqual(calls, 0)
        let settled = 100 + 9.0*41 + 60
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: settled, sourcesRefreshed: false))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: settled))
        gate.requested(.accepted)
        var blocked = closed; blocked.cpuSleepBlocked = true
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: blocked, now: settled+5))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: settled+100))
    }
    func testKernelWakeSettlementCannotBeShortenedByClockOrQueuedNotification() {
        var gate = acceptedBatch()
        _ = gate.observeKernelWake(kernelSnapshot(1000,1001), now:100)
        XCTAssertTrue(gate.observeKernelWake(kernelSnapshot(1100,1101), now:200))
        XCTAssertTrue(gate.observeClock(continuous:201, awake:110))
        gate.systemWillSleep()
        XCTAssertEqual(gate.wakeRecheckAt,260)
        XCTAssertFalse(gate.update(phase:.ready,ownsLidHold:false,releasesConfirmed:true,snapshot:closed,now:259.999))
        XCTAssertTrue(gate.update(phase:.ready,ownsLidHold:false,releasesConfirmed:true,snapshot:closed,now:260))
    }
    func testKernelWakeRetryStillRejectsNewWorkOpenExternalUnknownCPUAndUnreleasedHelper() {
        for mode in 0..<6 {
            var gate = acceptedBatch()
            _ = gate.observeKernelWake(kernelSnapshot(1000,1000.1),now:100)
            XCTAssertTrue(gate.observeKernelWake(kernelSnapshot(1100,1100.1),now:200))
            var snapshot = closed
            if mode == 0 { snapshot.lidClosed = false }
            if mode == 1 { snapshot.externalDisplays = 1 }
            if mode == 2 { snapshot.cpuSleepBlocked = nil }
            if mode == 3 { snapshot.sleepDisabled = true }
            let phase: KeepAwakeCompletionSleep.Phase = mode == 4 ? .unfinished : .ready
            XCTAssertFalse(gate.update(phase:phase,ownsLidHold:false,releasesConfirmed:mode != 5,snapshot:snapshot,now:300))
            if mode == 0 || mode == 1 || mode == 3 || mode == 4 {
                XCTAssertFalse(gate.update(phase:.ready,ownsLidHold:false,releasesConfirmed:true,snapshot:closed,now:400))
            }
        }
    }

    private func acceptedBatch() -> KeepAwakeCompletionSleep {
        var gate = armed()
        gate.observeClock(continuous: 100, awake: 100)
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 100))
        gate.requested(.accepted)
        return gate
    }

    /// Replay the observed 2026-10-30 sequence, relative to the first accepted
    /// request: sleep 6s, dark wake 8s, sleep 10s, dark wake 9s. All clocks and
    /// thermal inputs are fixtures; this never sleeps or heats the host Mac.
    private func capturedShortThermalWakes() -> (KeepAwakeCompletionSleep, KeepAwakeEngine) {
        var gate = acceptedBatch(), engine = completedEngine()
        var hot = notebook; hot.thermalUnsafe = true; hot.thermalLevel = 2
        for (continuous, awake, duration) in [(106.0, 100.0, 8.0), (124.0, 108.0, 9.0)] {
            gate.systemWillSleep()
            XCTAssertTrue(gate.observeClock(continuous: continuous, awake: awake))
            XCTAssertFalse(engine.evaluate(now: continuous, environment: hot).hold)
            XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: continuous + duration, environment: hot),
                ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
                now: continuous + duration, thermalProtection: engine.hasThermalProtection))
            XCTAssertFalse(gate.observeClock(continuous: continuous + duration, awake: awake + duration))
        }
        return (gate, engine)
    }

    func testCapturedShortDarkWakesWaitForFreshGraceAndReleaseBeforeOneRetry() {
        var (gate, engine) = capturedShortThermalWakes()
        gate.systemWillSleep()
        // The next observed sleep lasts 116s. Time asleep cannot satisfy the
        // new wake's grace, even though the previous wake's deadline passed.
        XCTAssertTrue(gate.observeClock(continuous: 249, awake: 117))
        XCTAssertEqual(gate.wakeRecheckAt, 279)
        for time in [249.0, 278.999] {
            XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: time, environment: notebook),
                ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
                now: time, thermalProtection: engine.hasThermalProtection))
        }
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 279, sourcesRefreshed: false, thermalProtection: true))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false,
            snapshot: closed, now: 280, thermalProtection: true))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 281, thermalProtection: true))
        gate.requested(.accepted)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 1000, thermalProtection: true))
        XCTAssertTrue(engine.hasThermalProtection)
        XCTAssertFalse(engine.evaluate(now: 1000, environment: notebook).hold)
    }

    func testCapturedShortDarkWakesFollowedByOpeningCannotRetryOldBatch() {
        var (gate, engine) = capturedShortThermalWakes()
        gate.systemWillSleep()
        XCTAssertTrue(gate.observeClock(continuous: 249, awake: 117))
        gate.observePhysical(.init(lidClosed: false, externalDisplays: 0, sleepDisabled: false))
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 1000, environment: notebook),
            ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
            now: 1000, thermalProtection: true))
        XCTAssertNil(gate.thermalWakeRecheckAt)
        XCTAssertTrue(engine.hasThermalProtection)
    }

    func testCapturedShortDarkWakesCannotSleepOverNewUnfinishedWork() {
        for state: KeepAwakeEngine.TaskState in [.running, .waiting, .idle] {
            var (gate, engine) = capturedShortThermalWakes()
            gate.systemWillSleep()
            XCTAssertTrue(gate.observeClock(continuous: 249, awake: 117))
            engine.receive(event(.running, session: "new-work"), now: 250)
            engine.receive(event(state, session: "new-work", sequence: 2), now: 251)
            for time in [279.0, 1000] {
                let phase = engine.completionSleepPhase(now: time, environment: notebook)
                XCTAssertEqual(phase, .unfinished)
                XCTAssertFalse(gate.update(phase: phase, ownsLidHold: false, releasesConfirmed: true,
                    snapshot: closed, now: time, thermalProtection: true))
            }
            engine.receive(event(.completed, session: "new-work", sequence: 3), now: 1001)
            XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 1030.999, environment: notebook),
                ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
                now: 1030.999, thermalProtection: true))
            XCTAssertTrue(gate.update(phase: engine.completionSleepPhase(now: 1031, environment: notebook),
                ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
                now: 1031, thermalProtection: true))
        }
    }

    func testRealBackgroundWakeRechecksAfterFreshGraceAndRequestsOnlyOnce() {
        var gate = acceptedBatch()
        gate.systemWillSleep()
        XCTAssertTrue(gate.observeClock(continuous: 710, awake: 110))
        XCTAssertEqual(gate.wakeRecheckAt, 740)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 739.999))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 740))
        gate.requested(.accepted)
        for time in [741.0, 800, 1000] {
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: time))
        }
    }

    func testDarkWakeWithoutWorkspaceNotificationsIsDetectedByClocks() {
        var gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 710, awake: 110))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 740))
    }

    func testDelayedWillSleepNotificationCannotEraseObservedWakeRecheck() {
        var gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
        gate.systemWillSleep()
        XCTAssertEqual(gate.wakeRecheckAt, 730)
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 729))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 730))
    }

    func testEveryActualSleepWakeGetsItsOwnGraceWithoutNotificationDuplicates() {
        var gate = acceptedBatch()
        for cycle in 1...3 {
            let time = 100 + Double(cycle) * 1000
            gate.systemWillSleep()
            XCTAssertTrue(gate.observeClock(continuous: time, awake: 100 + Double(cycle) * 40))
            XCTAssertFalse(gate.observeClock(continuous: time + 1, awake: 101 + Double(cycle) * 40))
            XCTAssertEqual(gate.wakeRecheckAt, time + 30)
            XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: time + 30))
            gate.requested(.accepted)
        }
    }

    func testTimerStallAndAcceptedRequestWithoutActualSleepNeverRetry() {
        var gate = acceptedBatch()
        gate.systemWillSleep() // A notification alone is not evidence of sleep.
        XCTAssertFalse(gate.observeClock(continuous: 3700, awake: 3700))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 3700))
        XCTAssertNil(gate.wakeRecheckAt)
    }

    func testInitialOffAndHistoricalCompletionCannotAcquireWakeEligibility() {
        var gate = KeepAwakeCompletionSleep()
        gate.observeClock(continuous: 100, awake: 100)
        gate.systemWillSleep()
        XCTAssertFalse(gate.observeClock(continuous: 700, awake: 100))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 730))
    }

    func testUnacceptedFailedAndSkippedRequestsCannotRetryEvenAfterSleep() {
        for result: KeepAwakeCompletionSleep.RequestResult in [.failed(-1), .skipped] {
            var gate = acceptedBatch()
            gate.requested(result)
            gate.systemWillSleep()
            XCTAssertFalse(gate.observeClock(continuous: 700, awake: 100))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 730))
        }
        var gate = armed()
        gate.observeClock(continuous: 100, awake: 100)
        gate.systemWillSleep() // External sleep before our batch requested it.
        XCTAssertFalse(gate.observeClock(continuous: 700, awake: 100))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 730))
    }

    func testOpeningOrExternalDisplayCancelsWakeCycleEvenBeforeGraceEnds() {
        for snapshot: KeepAwakeCompletionSleep.Snapshot in [
            .init(lidClosed: false, externalDisplays: 0, sleepDisabled: false),
            .init(lidClosed: true, externalDisplays: 1, sleepDisabled: false),
            .init(lidClosed: nil, externalDisplays: 0, sleepDisabled: false),
            .init(lidClosed: true, externalDisplays: nil, sleepDisabled: false)
        ] {
            var gate = acceptedBatch()
            XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: snapshot, now: 701))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 740))
            XCTAssertFalse(gate.observeClock(continuous: 1300, awake: 140))
        }
    }

    func testOpenAfterAcceptedRequestCancelsLaterClosedWake() {
        var gate = acceptedBatch()
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: .init(lidClosed: false, externalDisplays: 0, sleepDisabled: false), now: 101))
        gate.systemWillSleep()
        XCTAssertFalse(gate.observeClock(continuous: 700, awake: 100))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 730))
    }

    func testNewUnfinishedWorkCancelsWakeRetryAndMustOwnANewHold() {
        for state: KeepAwakeEngine.TaskState in [.running, .waiting, .idle] {
            var engine = completedEngine(), gate = acceptedBatch()
            XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
            engine.receive(event(.running, session: "new"), now: 701)
            engine.receive(event(state, session: "new", sequence: 2), now: 702)
            XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 740, environment: notebook),
                ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 740))
            XCTAssertNil(gate.wakeRecheckAt)
            engine.receive(event(.completed, session: "new", sequence: 3), now: 741)
            XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 771, environment: notebook),
                ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 771))
        }
    }

    func testNewOwnedTaskDuringWakeUsesItsOwnTerminalGrace() {
        var engine = completedEngine(), gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
        engine.receive(event(.running, session: "new"), now: 701)
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 701, environment: notebook),
            ownsLidHold: true, releasesConfirmed: false, snapshot: closed, now: 701))
        engine.receive(event(.completed, session: "new", sequence: 2), now: 750)
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 779, environment: notebook),
            ownsLidHold: true, releasesConfirmed: false, snapshot: closed, now: 779))
        XCTAssertTrue(gate.update(phase: engine.completionSleepPhase(now: 780, environment: notebook),
            ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 780))
    }

    func testWakeRecheckStillRequiresPowerAndHelperRelease() {
        var gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false, snapshot: closed, now: 740))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 741))
    }

    func testFailedOrPreSleepSourceSnapshotCannotPermitWakeSleep() {
        var gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
        for time in [730.0, 740, 1000] {
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                snapshot: closed, now: time, sourcesRefreshed: false))
        }
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
            snapshot: closed, now: 1001, sourcesRefreshed: true))
    }

    func testExplicitStopAndSafetyProtectionCancelAcceptedWakeCycle() {
        for explicit in [true, false] {
            var gate = acceptedBatch()
            if explicit { gate.cancel() }
            else { _ = gate.update(phase: .inactive, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 101) }
            XCTAssertFalse(gate.observeClock(continuous: 700, awake: 100))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 730))
        }
    }

    func testThermalWakeWithNewWorkWaitsForEveryTerminalAndFreshSources() {
        var engine = completedEngine(), gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
        for session in ["two", "three"] { engine.receive(event(.running, session: session), now: 701) }
        _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 701)
        var hot = notebook; hot.thermalUnsafe = true
        XCTAssertFalse(engine.evaluate(now: 780, environment: hot).hold)
        engine.receive(event(.completed, session: "two", sequence: 2), now: 790)
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 820, environment: hot),
            ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 820, thermalProtection: true))
        engine.receive(event(.completed, session: "three", sequence: 2), now: 821)
        XCTAssertFalse(gate.update(phase: engine.completionSleepPhase(now: 850.999, environment: hot),
            ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 850.999, thermalProtection: true))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
            now: 851, sourcesRefreshed: false, thermalProtection: true))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: false, snapshot: closed,
            now: 852, thermalProtection: true))
        XCTAssertTrue(gate.update(phase: engine.completionSleepPhase(now: 853, environment: notebook),
            ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 853, thermalProtection: engine.hasThermalProtection))
        XCTAssertFalse(engine.evaluate(now: 853, environment: notebook).hold)
        XCTAssertNotNil(engine.protection)
        gate.requested(.accepted)
        // Accepting the second request cannot spin into another one while awake.
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
            now: 2000, thermalProtection: true))
        gate.observeClock(continuous: 2000, awake: 1400)
        XCTAssertTrue(gate.observeClock(continuous: 3000, awake: 1410))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
            now: 3029, thermalProtection: true))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
            now: 3030, thermalProtection: true))
    }

    func testDormantThermalContextCannotRearmOrdinaryWorkAfterExternalSleep() {
        var gate = acceptedBatch()
        XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
        _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: true, snapshot: closed)
        gate.systemWillSleep()
        XCTAssertTrue(gate.observeClock(continuous: 1700, awake: 110))
        XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 1800))
        XCTAssertTrue(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
            now: 1800, thermalProtection: true))
    }

    func testThermalWakeContextIsLostOnOpeningDuringWorkOrGrace() {
        for phase: KeepAwakeCompletionSleep.Phase in [.unfinished, .grace] {
            for snapshot: KeepAwakeCompletionSleep.Snapshot in [
                .init(lidClosed: false, externalDisplays: 0, sleepDisabled: false),
                .init(lidClosed: true, externalDisplays: 1, sleepDisabled: false), .init()
            ] {
                var gate = acceptedBatch()
                XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
                _ = gate.update(phase: phase, ownsLidHold: false, releasesConfirmed: true, snapshot: snapshot, now: 701)
                XCTAssertNil(gate.thermalWakeRecheckAt)
                XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
                    now: 800, thermalProtection: true))
            }
        }
    }

    func testThermalProtectionNeverInventsAnOwnedOrAcceptedBatch() {
        for acceptedWithoutSleep in [false, true] {
            var gate = acceptedWithoutSleep ? acceptedBatch() : KeepAwakeCompletionSleep()
            _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: true, snapshot: closed)
            XCTAssertNil(gate.thermalWakeRecheckAt)
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed,
                now: 1000, thermalProtection: true))
        }
    }

    func testThermalExceptionStillRejectsNonthermalProtectionAndUnknownPower() {
        var hot = notebook; hot.thermalUnsafe = true
        for environment in [
            KeepAwakeEngine.Environment(), .init(hardware: .desktop),
            .init(hardware: .notebook), .init(hardware: .notebook, battery: 2, onAC: true),
            .init(hardware: .notebook, battery: 80, onAC: false),
            .init(hardware: .notebook, battery: 80, onAC: true, lowPower: true)
        ] {
            var engine = completedEngine()
            _ = engine.evaluate(now: 41, environment: hot)
            XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: environment), .inactive)
        }
        var engine = completedEngine(), low = notebook; low.lowPower = true
        _ = engine.evaluate(now: 41, environment: low)
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: notebook), .inactive)
        engine = completedEngine(); _ = engine.evaluate(now: 41, environment: hot)
        engine.stop(); XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: hot), .inactive)
    }

    func testThermalWakeCannotBypassForeignPowerOrRetryFailedSleep() {
        for disabled: Bool? in [true, nil] {
            var gate = acceptedBatch()
            XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
            _ = gate.update(phase: .unfinished, ownsLidHold: false, releasesConfirmed: true, snapshot: closed)
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                snapshot: .init(lidClosed: true, externalDisplays: 0, sleepDisabled: disabled), now: 800, thermalProtection: true))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                snapshot: closed, now: 801, thermalProtection: true))
        }
        for result: KeepAwakeCompletionSleep.RequestResult in [.failed(-1), .skipped] {
            var gate = acceptedBatch()
            XCTAssertTrue(gate.observeClock(continuous: 700, awake: 100))
            gate.requested(result)
            XCTAssertFalse(gate.observeClock(continuous: 1700, awake: 110))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true,
                snapshot: closed, now: 1800, thermalProtection: true))
        }
    }

    func testInvalidOrRegressingClockCancelsWakeEligibility() {
        for clock in [(Double.nan, 101.0), (110.0, Double.infinity), (99.0, 101.0), (110.0, 99.0)] {
            var gate = acceptedBatch()
            XCTAssertFalse(gate.observeClock(continuous: clock.0, awake: clock.1))
            XCTAssertFalse(gate.observeClock(continuous: 700, awake: 110))
            XCTAssertFalse(gate.update(phase: .ready, ownsLidHold: false, releasesConfirmed: true, snapshot: closed, now: 740))
        }
    }
}

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
