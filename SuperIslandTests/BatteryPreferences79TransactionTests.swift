import XCTest
@testable import SuperIsland

final class BatteryPreferences79TransactionTests: XCTestCase {
    private typealias T = BatteryPreferences79Transaction
    private typealias V = T.Value
    func testLegacyJournalKeepsSixtySecondDeadlineAndOnlyRestores() throws {
        let f = Fixture(), original = try f.preparedAndApplied()
        var old = try XCTUnwrap(original.record)
        old.schema = 1; old.deadlineContinuous = old.startedContinuous + 60
        f.disk = old
        let restored = try f.make(), writes = f.writes.count
        XCTAssertThrowsError(try restored.apply(bootID: "boot-a", now: 20))
        XCTAssertEqual(f.writes.count, writes)
        XCTAssertEqual(restored.record?.deadlineContinuous, 70)
        try restored.restore(bootID: "boot-a", now: 1000)
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
        XCTAssertEqual(restored.record?.schema, 1)
        XCTAssertEqual(restored.record?.deadlineContinuous, 70)
    }
    func testSchemaAndDeadlineCannotBeMixedOrRenewedByReload() throws {
        let f = Fixture(), t = try f.prepare(), base = try XCTUnwrap(t.record)
        XCTAssertEqual(base.schema, 2); XCTAssertEqual(base.deadlineContinuous, 190)
        for (schema, duration) in [(1, 180.0), (2, 60.0), (2, 181.0), (0, 60.0)] {
            var bad = base; bad.schema = schema; bad.deadlineContinuous = bad.startedContinuous + duration
            XCTAssertThrowsError(try T.validate(bad))
        }
        let reloaded = try f.make()
        XCTAssertEqual(reloaded.record?.deadlineContinuous, base.deadlineContinuous)
        XCTAssertThrowsError(try reloaded.prepare(owner: f.owner, bootID: "boot-a", now: 20, observation: f.observation))
    }
    func testFixedOrderedApplyHasDurableIntentBeforeEveryWriteAndSignal() throws {
        let f = Fixture(), transaction = try f.make()
        let original = try transaction.prepare(owner: f.owner, bootID: "boot-a", now: 10, observation: f.observation)
        XCTAssertEqual(original.deadlineContinuous, 190)
        try transaction.apply(bootID: "boot-a", now: 10)
        XCTAssertEqual(f.writes.map(\.0), T.Key.direct)
        XCTAssertEqual(f.values[.mclLimitValue], .integer(79))
        XCTAssertEqual(f.signals, 1); XCTAssertEqual(transaction.record?.phase, .active)
        XCTAssertEqual(transaction.record?.deadlineContinuous, 190)
        XCTAssertFalse(transaction.mutationOutcomeUnknown)
        XCTAssertEqual(try f.make().record, transaction.record)
    }
    func testRestoreOrdersControlBeforeDerivedAndRequiresIndependentConfirmation() throws {
        let f = Fixture(), transaction = try f.preparedAndApplied()
        f.writes.removeAll(); f.observation.nativeLimit = 79; f.observation.registrations = [79]
        try transaction.restore(bootID: "boot-a", now: 1000)
        XCTAssertEqual(f.writes.first?.0, .mclLimitValue)
        XCTAssertEqual(f.writes.map(\.0), [.mclLimitValue, .checkpoint, .currentState])
        XCTAssertEqual(transaction.record?.phase, .awaitingConfirmation)
        XCTAssertFalse(try transaction.finishRestoration(validated: false))
        XCTAssertNotNil(f.disk)
        f.observation.nativeLimit = 80; f.observation.registrations = [80]
        XCTAssertTrue(try transaction.finishRestoration(validated: true)); XCTAssertNil(f.disk)
    }
    func testBoolAndRealFlagsKeepTheirOriginalTypesAndGuardDatesRejectBoolOrCFDate() throws {
        let f = Fixture(); f.values[.mclFeatureState] = .bool(true); f.values[.isEngaged] = .real(1)
        let transaction = try f.preparedAndApplied()
        XCTAssertEqual(f.values[.mclFeatureState], .bool(true)); XCTAssertEqual(f.values[.isEngaged], .real(1))
        try transaction.restore(bootID: "boot-a", now: 20)
        XCTAssertEqual(f.values[.mclFeatureState], .bool(true))
        for invalid in [V.bool(true), .date(Date()), .absent, .real(.nan), .string("100")] {
            let bad = Fixture(); bad.values[.initialChargeLimitSetDate] = invalid
            XCTAssertThrowsError(try bad.prepare()); XCTAssertNil(bad.disk); XCTAssertTrue(bad.writes.isEmpty)
        }
    }
    func testTemporaryDisableRequiresAbsenceEvenWhenNumericDateHasExpired() throws {
        for value in [V.absent] {
            let f = Fixture(); f.values[.mclTempDisabledUntilDate] = value
            let t = try f.preparedAndApplied(); try t.restore(bootID: "boot-a", now: 20)
            XCTAssertEqual(f.values[.mclTempDisabledUntilDate] ?? .absent, value)
        }
        for value in [V.integer(900), .real(900.25), .bool(false), .date(Date(timeIntervalSinceReferenceDate: 900)), .real(.infinity), .real(1001), .string("900")] {
            let f = Fixture(); f.values[.mclTempDisabledUntilDate] = value
            XCTAssertThrowsError(try f.prepare()); XCTAssertNil(f.disk); XCTAssertTrue(f.writes.isEmpty); XCTAssertEqual(f.signals, 0)
        }
    }
    func testGuardOverridesWrongRawTargetAndFalseFlagsRejectBeforeSaving() {
        let cases: [(T.Key, V)] = [(.disabledUntil, .integer(0)), (.mclOverridenUntilDate, .real(900)),
                                  (.mclSavedTargetSoC, .integer(80)), (.mclLimitValue, .bool(true)),
                                  (.mclLimitValue, .integer(79)), (.mclFeatureState, .integer(0)), (.isEngaged, .bool(false))]
        for (key, value) in cases {
            let f = Fixture(); f.values[key] = value
            XCTAssertThrowsError(try f.prepare()); XCTAssertNil(f.disk); XCTAssertTrue(f.writes.isEmpty)
        }
    }
    func testInvalidPhysicalObservationsRejectAndNeverCreatePartialWrites() {
        for alter in observationFailures() {
            let f = Fixture(); alter(&f.observation)
            XCTAssertThrowsError(try f.prepare()); XCTAssertNil(f.disk); XCTAssertTrue(f.writes.isEmpty)
        }
    }
    func testSecondPrepareForeignOwnerRepeatedApplyAndRestartCannotAcquireNewControl() throws {
        let f = Fixture(), t = try f.prepare()
        XCTAssertThrowsError(try t.prepare(owner: UUID(), bootID: "boot-a", now: 11, observation: f.observation))
        try t.apply(bootID: "boot-a", now: 10)
        let count = f.writes.count
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 11))
        XCTAssertEqual(f.writes.count, count); XCTAssertEqual(t.record?.deadlineContinuous, 190)
        let restarted = try f.make()
        XCTAssertThrowsError(try restarted.apply(bootID: "boot-a", now: 12))
        try restarted.restore(bootID: "boot-b", now: 1)
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
    }
    func testForeignBootTimeoutAndClockRollbackCannotApply() throws {
        for (boot, time) in [("boot-b", 10.0), ("boot-a", 190.0), ("boot-a", 9.0), ("boot-a", Double.nan)] {
            let f = Fixture(), t = try f.prepare()
            XCTAssertThrowsError(try t.apply(bootID: boot, now: time))
            XCTAssertTrue(f.writes.isEmpty)
        }
    }
    func testInspectAndSaveLatencyCannotCrossDeadlineAndNoStepRenewsIt() throws {
        for delayInSave in [false, true] {
            let f = Fixture(), t = try f.prepare()
            if delayInSave { f.afterSave = { f.now = 190 } }
            else { f.afterInspect = { f.now = 190 } }
            XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
            XCTAssertTrue(f.writes.isEmpty); XCTAssertEqual(t.record?.deadlineContinuous, 190)
        }
        let f = Fixture(), t = try f.prepare()
        f.afterWrite = { _, _ in f.now += 75 }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.writes.count, 3); XCTAssertEqual(t.record?.deadlineContinuous, 190)
    }
    func testFreshLowSOCUnplugCompetitionCalibrationOrGuardChangeStopsApply() throws {
        let alterations: [(Fixture) -> Void] = [
            { $0.observation.level = 79 }, { $0.observation.adapterPresent = false },
            { $0.observation.competingController = true }, { $0.observation.calibrationActive = true },
            { $0.values[.disabledUntil] = .integer(10) }, { $0.observation.batteryCurrent = .nan }
        ]
        for alter in alterations {
            let f = Fixture(), t = try f.prepare()
            f.afterWrite = { _, _ in alter(f) }
            XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
            XCTAssertEqual(f.writes.count, 1)
        }
    }
    func testRawStrongChangeBeforeApplyPreventsEvenDerivedDeletion() throws {
        for key in [T.Key.mclLimitValue, .mclFeatureState, .isEngaged, .isManuallyChargeLimited, .mclTempDisabledUntilDate] {
            let f = Fixture(), t = try f.prepare()
            f.values[key] = key == .mclLimitValue ? .integer(85) : .integer(0)
            XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
            XCTAssertTrue(f.writes.isEmpty)
        }
    }
    func testFinalSignalRequiresFreshPhysicalObservationAndDoesNotReapply() throws {
        let f = Fixture(), t = try f.prepare()
        f.afterWrite = { key, _ in if key == .isManuallyChargeLimited { f.observation.level = 79 } }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.writes.count, 7); XCTAssertEqual(f.signals, 0)
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 11))
        XCTAssertEqual(f.writes.count, 7)
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
    }
    func testStrongChangeAtFinalApplyWritePreventsNotification() throws {
        let f = Fixture(), t = try f.prepare()
        f.afterWrite = { key, _ in if key == .isManuallyChargeLimited { f.values[.mclLimitValue] = .integer(85) } }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.signals, 0); XCTAssertEqual(f.values[.mclLimitValue], .integer(85))
    }
    func testRestoreAllowsUnplugLowSOCDisabledSentinelAndNoRegistrations() throws {
        for unread in [false, true] {
            let f = Fixture(), t = try f.preparedAndApplied()
            f.observation.level = 78; f.observation.adapterPresent = false
            f.observation.nativeEnabled = unread ? nil : 0
            f.observation.nativeLimit = unread ? nil : 100; f.observation.registrations = []
            try t.restore(bootID: "boot-b", now: 1)
            XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
            XCTAssertEqual(t.record?.phase, .awaitingConfirmation)
            XCTAssertThrowsError(try t.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        }
    }
    func testRestoreRejectsUnknownCompetitionCalibrationForeignRegistrationsAndGuardChange() throws {
        let alterations: [(Fixture) -> Void] = [
            { $0.observation.level = .nan }, { $0.observation.competingController = true },
            { $0.observation.calibrationActive = true }, { $0.observation.registrations = [85] },
            { $0.values[.initialChargeLimitSetDate] = .real(800) }
        ]
        for alter in alterations {
            let f = Fixture(), t = try f.preparedAndApplied(); let count = f.writes.count; alter(f)
            XCTAssertThrowsError(try t.restore(bootID: "boot-b", now: 1))
            XCTAssertEqual(f.writes.count, count); XCTAssertNotNil(f.disk)
        }
    }
    func testStrongExternalChangesAreNotOverwrittenOrReclaimedOnAnotherRestore() throws {
        let f = Fixture(), t = try f.preparedAndApplied()
        f.values[.mclLimitValue] = .integer(85); f.values[.mclTempDisabledUntilDate] = .real(1200)
        XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
        XCTAssertEqual(f.values[.mclLimitValue], .integer(85)); XCTAssertEqual(f.values[.mclTempDisabledUntilDate], .real(1200))
        f.values[.mclLimitValue] = .integer(79)
        XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 21))
        XCTAssertEqual(f.values[.mclLimitValue], .integer(79)); XCTAssertNotNil(f.disk)
    }
    func testPreparedButNeverMutatedDoesNotClaimAnExternalExpectedValue() throws {
        let f = Fixture(), t = try f.prepare(); f.values[.mclLimitValue] = .integer(79)
        for _ in 0..<2 {
            XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
            XCTAssertEqual(f.values[.mclLimitValue], .integer(79))
        }
    }
    func testDerivedSystemRecomputationAndModeArePreservedWithoutBlockingStrongRestore() throws {
        let f = Fixture(), t = try f.preparedAndApplied()
        f.values[.checkpoint] = .dictionary(["system": .integer(7)])
        f.values[.currentState] = .string("new-state"); f.values[.modeOfOperation] = .integer(19)
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertEqual(f.values[.checkpoint], .dictionary(["system": .integer(7)]))
        XCTAssertEqual(f.values[.currentState], .string("new-state")); XCTAssertEqual(f.values[.modeOfOperation], .integer(19))
        XCTAssertTrue(t.record!.entries.filter { $0.key.derived }.allSatisfy { $0.ack == .derivedRecomputed })
        XCTAssertFalse(f.writes.contains { $0.0 == .modeOfOperation })
    }
    func testSaveFailuresBeforeEachApplyMutationNeverAdvanceMemoryPastDisk() throws {
        let baseline = Fixture(); _ = try baseline.preparedAndApplied()
        // Include every observation-intent/ack as well as each mutation pair.
        for failure in 1...baseline.saves {
            let f = Fixture(); f.failSave = failure
            var t: T?
            do { t = try f.make(); _ = try t!.prepare(owner: f.owner, bootID: "boot-a", now: 10, observation: f.observation); try t!.apply(bootID: "boot-a", now: 10) }
            catch { }
            XCTAssertEqual(t?.record, f.disk)
            if failure == 1 || failure == 2 { XCTAssertTrue(f.writes.isEmpty) }
            XCTAssertLessThanOrEqual(f.writes.count, 7)
            if let disk = f.disk { XCTAssertEqual(disk.deadlineContinuous, 190) }
        }
    }
    func testWriteErrorIncludingMutatedThenThrownIsStickyAndNeverClearedByValidation() throws {
        for mutate in [false, true] {
            let f = Fixture(), t = try f.prepare(); f.failWrite = 4; f.mutateBeforeThrow = mutate
            XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
            XCTAssertTrue(t.mutationOutcomeUnknown); XCTAssertTrue(f.disk?.mutationOutcomeUnknown == true)
            f.failWrite = nil
            try t.restore(bootID: "boot-a", now: 20)
            XCTAssertFalse(try t.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        }
    }
    func testKillAfterWriteBeforeAckLoadsAsUnknownAndRestartOnlyRestores() throws {
        let f = Fixture(), t = try f.prepare()
        // Durable intent is saved, write happens, ack + uncertainty-marker saves fail.
        f.failAllSavesWhen = { $0?.entries.first?.ack == .applied }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.disk?.entries.first?.ack, .writeIntent)
        XCTAssertFalse(f.disk?.mutationOutcomeUnknown ?? true)
        XCTAssertTrue(t.mutationOutcomeUnknown)
        f.failAllSavesFrom = nil
        let restarted = try f.make()
        XCTAssertTrue(restarted.mutationOutcomeUnknown); XCTAssertTrue(f.disk?.mutationOutcomeUnknown == true)
        try restarted.restore(bootID: "boot-b", now: 1)
        XCTAssertFalse(try restarted.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
    }
    func testLoadedPendingCannotMutateUntilUnknownMarkerIsDurable() throws {
        let f = Fixture(), t = try f.prepare(); f.failAllSavesWhen = { $0?.entries.first?.ack == .applied }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        let count = f.writes.count
        XCTAssertThrowsError(try f.make()); XCTAssertEqual(f.writes.count, count)
    }
    func testSignalErrorsAndSignalAckFailureRemainUnknown() throws {
        for failAck in [false, true] {
            let f = Fixture(), t = try f.prepare()
            if failAck { f.failSaveWhen = { $0?.phase == .active } } else { f.failSignal = 1 }
            XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
            XCTAssertTrue(t.mutationOutcomeUnknown)
            f.failSignal = nil; f.failSave = nil
            try t.restore(bootID: "boot-a", now: 20)
            XCTAssertFalse(try t.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        }
    }
    func testTrustedCancellationAfterFirstWriteStopsRemainingWritesAndCanRestore() throws {
        let f = Fixture(), t = try f.prepare(); f.rejectCancelledSubmission = true
        f.afterWrite = { _, _ in f.cancelled = true }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.writes.count, 1); XCTAssertEqual(f.signals, 0); XCTAssertFalse(t.mutationOutcomeUnknown)
        f.restoring = true; f.afterWrite = nil
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertTrue(try t.finishRestoration(validated: true))
    }
    func testTrustedCancellationAfterIntentSaveRollsBackDurableCheckpoint() throws {
        let f = Fixture(), t = try f.prepare(), prepared = t.record
        f.rejectCancelledSubmission = true
        f.afterSave = { if f.disk?.entries.first?.ack == .writeIntent { f.cancelled = true } }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(t.record, prepared); XCTAssertEqual(f.disk, prepared)
        XCTAssertTrue(f.writes.isEmpty); XCTAssertFalse(t.mutationOutcomeUnknown)
        f.restoring = true; f.afterSave = nil
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertTrue(try t.finishRestoration(validated: true))
    }
    func testTrustedCancellationBeforeSignalRollsBackSignalIntentWithoutUnknown() throws {
        let f = Fixture(), t = try f.prepare(); f.rejectCancelledSubmission = true
        f.afterSave = { if f.disk?.phase == .applySignalIntent { f.cancelled = true } }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.writes.count, 7); XCTAssertEqual(f.signals, 0)
        XCTAssertEqual(t.record?.phase, .applying); XCTAssertFalse(t.mutationOutcomeUnknown)
        f.restoring = true; f.afterSave = nil
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertTrue(try t.finishRestoration(validated: true))
    }
    func testFailedCancellationRollbackKeepsPendingIntentAndStickyUnknown() throws {
        let f = Fixture(), t = try f.prepare(); f.rejectCancelledSubmission = true
        f.failSaveWhen = { $0?.phase == .prepared && f.disk?.entries.first?.ack == .writeIntent }
        f.afterSave = { if f.disk?.entries.first?.ack == .writeIntent { f.cancelled = true } }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertTrue(f.writes.isEmpty); XCTAssertEqual(t.record?.entries.first?.ack, .writeIntent)
        XCTAssertTrue(t.mutationOutcomeUnknown); XCTAssertTrue(f.disk?.mutationOutcomeUnknown == true)
        f.restoring = true; f.afterSave = nil; f.failSave = nil
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertFalse(try t.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
    }
    func testNotSubmittedFromAcknowledgementSaveCannotUndoAPhysicalWrite() throws {
        let f = Fixture(), t = try f.prepare(); f.saveThrowsNotSubmitted = true
        f.failSaveWhen = { $0?.entries.first?.ack == .applied && f.disk?.entries.first?.ack == .writeIntent }
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertEqual(f.writes.count, 1); XCTAssertTrue(t.mutationOutcomeUnknown)
        XCTAssertEqual(t.record?.entries.first?.ack, .writeIntent)
    }
    func testRemoteErrorNamedNotSubmittedStillMeansUnknown() throws {
        let f = Fixture(), t = try f.prepare(); f.failWrite = 1
        f.writeError = NSError(domain: "BatteryPreferences79Transaction.Failure.notSubmitted", code: 1)
        XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
        XCTAssertTrue(t.mutationOutcomeUnknown)
    }
    func testRestoreSaveFailureAtEveryStageRetainsDurableRecoveryResponsibility() throws {
        let baseline = Fixture(), successful = try baseline.preparedAndApplied()
        let before = baseline.saves
        try successful.restore(bootID: "boot-a", now: 20)
        let stages = baseline.saves - before
        for offset in 1...stages {
            let f = Fixture(), t = try f.preparedAndApplied(); f.failSave = f.saves + offset
            XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
            XCTAssertEqual(t.record, f.disk); XCTAssertNotNil(f.disk)
            f.failSave = nil
            let restarted = try f.make(); try restarted.restore(bootID: "boot-b", now: 1)
            XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
        }
    }
    func testRestoreWriteErrorAndFinalSignalFailureRemainSticky() throws {
        for failSignal in [false, true] {
            let f = Fixture(), t = try f.preparedAndApplied()
            if failSignal { f.failSignal = 2 } else { f.failWrite = f.writeAttempts + 1; f.mutateBeforeThrow = true }
            XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
            XCTAssertTrue(t.mutationOutcomeUnknown)
            f.failSignal = nil; f.failWrite = nil
            try t.restore(bootID: "boot-a", now: 21)
            XCTAssertFalse(try t.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        }
    }
    func testJournalDeleteFailureRetainsRecordAndPhysicalFalseNeverDeletes() throws {
        let f = Fixture(), t = try f.preparedAndApplied(); try t.restore(bootID: "boot-a", now: 20)
        f.failDelete = true
        XCTAssertThrowsError(try t.finishRestoration(validated: true)); XCTAssertNotNil(t.record); XCTAssertNotNil(f.disk)
        XCTAssertFalse(try t.finishRestoration(validated: false))
        f.failDelete = false; XCTAssertTrue(try t.finishRestoration(validated: true))
    }
    func testFreshFinalObservationCannotDeleteJournalAfterValidationTurnsStale() throws {
        let changes: [(inout T.Observation) -> Void] = [
            { $0.nativeLimit = 79 }, { $0.nativeEnabled = 0 }, { $0.registrations = [79] }, { $0.registrations = [] },
            { $0.batteryCurrent = -0.051 }, { $0.batteryCurrent = .nan }, { $0.adapterPresent = false },
            { $0.adapterPower = 1 }, { $0.competingController = true }, { $0.calibrationActive = true }
        ]
        for change in changes {
            let f = Fixture(), t = try f.preparedAndApplied(); try t.restore(bootID: "boot-a", now: 20)
            change(&f.observation)
            XCTAssertThrowsError(try t.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        }
        let f = Fixture(), t = try f.preparedAndApplied(); try t.restore(bootID: "boot-a", now: 20)
        f.observation.batteryCurrent = -0.05; f.observation.adapterPower = 1.001
        XCTAssertTrue(try t.finishRestoration(validated: true))
    }
    func testPrepareReadFailureAtEachKeyHasNoJournalOrWrites() throws {
        for offset in 1...T.Key.allCases.count {
            let f = Fixture(); f.failRead = offset
            XCTAssertThrowsError(try f.prepare()); XCTAssertNil(f.disk); XCTAssertTrue(f.writes.isEmpty)
        }
    }
    func testReadFailureAtEveryApplyStageRetainsDurableRecordAndCanRestore() throws {
        let baseline = Fixture(), original = try baseline.prepare(); let first = baseline.reads
        try original.apply(bootID: "boot-a", now: 10); let count = baseline.reads - first
        for offset in 1...count {
            let f = Fixture(), t = try f.prepare(); f.failRead = f.reads + offset
            XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10))
            XCTAssertEqual(t.record, f.disk)
            f.failRead = nil
            let restored = try f.make(); try restored.restore(bootID: "boot-b", now: 1)
            XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
        }
    }
    func testRecordCodableRoundTripPreservesTypedOriginalsAndRecoveryOnly() throws {
        let f = Fixture(); f.values[.checkpoint] = .dictionary(["bool": .bool(true), "float": .real(1), "int": .integer(1),
            "date": .date(Date(timeIntervalSinceReferenceDate: 50)), "data": .data(Data([0, 1])), "nested": .array([.string("x")])])
        let t = try f.preparedAndApplied(), saved = try XCTUnwrap(t.record)
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(T.Record.self, from: data)
        XCTAssertEqual(decoded, saved); f.disk = decoded
        let reloaded = try f.make(); XCTAssertThrowsError(try reloaded.apply(bootID: "boot-a", now: 20))
        try reloaded.restore(bootID: "boot-a", now: 20)
        XCTAssertEqual(f.values[.checkpoint], saved.entries.first?.original)
    }
    func testExternalChangeAfterRestorationIsNotReclaimedOrDeleted() throws {
        let f = Fixture(), t = try f.preparedAndApplied(); try t.restore(bootID: "boot-a", now: 20)
        f.values[.mclLimitValue] = .integer(79)
        XCTAssertThrowsError(try t.finishRestoration(validated: true))
        let before = f.writes.count
        try t.restore(bootID: "boot-a", now: 21)
        XCTAssertEqual(f.writes.count, before); XCTAssertEqual(f.values[.mclLimitValue], .integer(79)); XCTAssertNotNil(f.disk)
    }
    func testExternalChangeDuringRestoreBeforeSignalBlocksAndNeverReclaimsIt() throws {
        let f = Fixture(), t = try f.preparedAndApplied(); let count = f.signals
        f.afterWrite = { key, _ in if key == .currentState { f.values[.mclLimitValue] = .integer(79) } }
        XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
        XCTAssertEqual(f.signals, count); XCTAssertEqual(t.record?.phase, .blocked)
        f.afterWrite = nil
        XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 21))
        XCTAssertEqual(f.values[.mclLimitValue], .integer(79))
    }
    func testTypedFoundationRoundTripAndInvalidBoundaries() throws {
        let object: [String: Any] = ["b": NSNumber(value: true), "i": NSNumber(value: Int64(7)), "r": NSNumber(value: 7.5),
                                   "d": Date(timeIntervalSinceReferenceDate: 10), "bytes": Data([1, 2]), "s": "value", "a": ["x", 4]]
        let value = try V.fromFoundation(object)
        XCTAssertEqual(try V.fromFoundation(value.foundationValue()), value)
        XCTAssertEqual(try V.fromFoundation(nil), .absent)
        XCTAssertEqual(try V.fromFoundation(NSNumber(value: true)), .bool(true))
        for bad: Any in [NSNull(), NSObject(), NSNumber(value: Double.nan), NSNumber(value: UInt64.max), Data(repeating: 1, count: 65_536)] {
            XCTAssertThrowsError(try V.fromFoundation(bad))
        }
        var deep: Any = "leaf"
        for _ in 0..<34 { deep = [deep] }
        XCTAssertThrowsError(try V.fromFoundation(deep))
        XCTAssertThrowsError(try V.array([.absent]).foundationValue())
    }
    func testMalformedJournalCannotBecomeExecutableState() throws {
        let f = Fixture(), t = try f.prepare(), base = try XCTUnwrap(t.record)
        var variants: [T.Record] = []
        var bad = base; bad.schema = 3; variants.append(bad)
        bad = base; bad.deadlineContinuous += 1; variants.append(bad)
        bad = base; bad.entries[3].expected = .integer(78); variants.append(bad)
        bad = base; bad.entries.append(bad.entries[0]); variants.append(bad)
        bad = base; bad.phase = .active; variants.append(bad)
        bad = base; bad.guards[.initialChargeLimitSetDate] = .bool(true); variants.append(bad)
        for record in variants { f.disk = record; XCTAssertThrowsError(try f.make()) }
    }
    func testAdmissionSavesPureSnapshotBeforeAnyGetterThenConfirmsPrepared() throws {
        let f = Fixture(), t = try f.admission()
        XCTAssertEqual(f.inspectCalls, 0); XCTAssertEqual(t.record?.phase, .admissionPending)
        XCTAssertNil(t.record?.initialObservation.nativeLimit); XCTAssertNil(t.record?.admittedObservation)
        XCTAssertEqual(t.record?.entries.map(\.key), T.Key.direct)
        try t.confirmAdmission(bootID: "boot-a", now: 10)
        XCTAssertEqual(f.inspectCalls, 1); XCTAssertEqual(t.record?.phase, .prepared)
        XCTAssertEqual(t.record?.admittedObservation?.nativeLimit, 80); XCTAssertNil(t.record?.initialObservation.nativeLimit)
        XCTAssertEqual(t.record?.deadlineContinuous, 190)
        try t.apply(bootID: "boot-a", now: 10)
        XCTAssertEqual(f.writes.count, 7)
        let pending = Fixture(), pendingT = try pending.admission()
        XCTAssertThrowsError(try pendingT.apply(bootID: "boot-a", now: 10)); XCTAssertTrue(pending.writes.isEmpty)
    }
    func testAdmissionInvalidPureConditionsAndSaveFailureNeverCallGetter() throws {
        for key in [T.Key.disabledUntil, .mclTempDisabledUntilDate, .initialChargeLimitSetDate, .isEngaged] {
            let f = Fixture(); f.values[key] = key == .initialChargeLimitSetDate ? .absent : .integer(0)
            XCTAssertThrowsError(try f.admission()); XCTAssertEqual(f.inspectCalls, 0); XCTAssertTrue(f.writes.isEmpty)
        }
        let f = Fixture(); f.failSave = 1
        XCTAssertThrowsError(try f.admission()); XCTAssertEqual(f.inspectCalls, 0); XCTAssertNil(f.disk)
        let intent = Fixture(), t = try intent.admission(); intent.failSave = 2
        XCTAssertThrowsError(try t.confirmAdmission(bootID: "boot-a", now: 10))
        XCTAssertEqual(intent.inspectCalls, 0); XCTAssertFalse(t.mutationOutcomeUnknown)
        XCTAssertEqual(t.record?.phase, .admissionPending)
    }
    func testAdmissionGetterErrorsAndCancellationAreAlwaysSticky() throws {
        for error: Error in [Injected.failure, T.Failure.notSubmitted] {
            let f = Fixture(), t = try f.admission(); f.inspectFailure = error
            XCTAssertThrowsError(try t.confirmAdmission(bootID: "boot-a", now: 10))
            XCTAssertTrue(t.mutationOutcomeUnknown); XCTAssertEqual(t.record?.phase, .admissionIntent)
            XCTAssertEqual(f.inspectCalls, 1); XCTAssertTrue(f.writes.isEmpty)
            let loaded = try f.make(); XCTAssertTrue(loaded.mutationOutcomeUnknown)
            XCTAssertThrowsError(try loaded.confirmAdmission(bootID: "boot-a", now: 11))
        }
    }
    func testAdmissionFreshOriginalOrGuardChangesCannotBecomePrepared() throws {
        for key in [T.Key.currentState, .mclLimitValue, .disabledUntil] {
            let f = Fixture(), t = try f.admission()
            f.afterInspect = { f.values[key] = .integer(85) }
            XCTAssertThrowsError(try t.confirmAdmission(bootID: "boot-a", now: 10))
            XCTAssertEqual(t.record?.phase, .admissionIntent); XCTAssertTrue(t.mutationOutcomeUnknown)
            XCTAssertNil(t.record?.admittedObservation); XCTAssertTrue(f.writes.isEmpty)
        }
    }
    func testAdmissionAckFailureReloadsUnknownAndCannotResumeControl() throws {
        let f = Fixture(), t = try f.admission()
        f.failAllSavesWhen = { $0?.phase == .prepared && $0?.admittedObservation != nil }
        XCTAssertThrowsError(try t.confirmAdmission(bootID: "boot-a", now: 10))
        XCTAssertEqual(t.record?.phase, .admissionIntent); XCTAssertNil(t.record?.admittedObservation)
        XCTAssertTrue(t.mutationOutcomeUnknown)
        f.failAllSavesFrom = nil
        let count = f.inspectCalls, loaded = try f.make()
        XCTAssertEqual(f.inspectCalls, count); XCTAssertTrue(loaded.mutationOutcomeUnknown)
        XCTAssertThrowsError(try loaded.apply(bootID: "boot-a", now: 11))
        XCTAssertThrowsError(try loaded.observe(restoring: false)); XCTAssertEqual(f.inspectCalls, count)
    }
    func testAllObservationPhasesJournalUnsafeGetterErrorsAndCannotClearThem() throws {
        for phase in 0..<3 {
            let f = Fixture(), t = try (phase == 0 ? f.prepare() : f.preparedAndApplied())
            f.inspectFailure = Injected.failure
            if phase == 0 { XCTAssertThrowsError(try t.apply(bootID: "boot-a", now: 10)) }
            else if phase == 1 { XCTAssertThrowsError(try t.observe(restoring: false)) }
            else { XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20)) }
            XCTAssertTrue(t.mutationOutcomeUnknown); XCTAssertTrue(t.record?.observationPending == true)
            f.inspectFailure = nil
            let loaded = try f.make(); XCTAssertTrue(loaded.mutationOutcomeUnknown)
            try loaded.restore(bootID: "boot-b", now: 1)
            XCTAssertFalse(try loaded.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        }
    }
    func testObservationAckFailureAndPendingLoadRequireDurableUnknownBeforeAnyMoreGetter() throws {
        let f = Fixture(), t = try f.prepare()
        f.failAllSavesWhen = { $0?.observationPending == false && f.disk?.observationPending == true }
        XCTAssertThrowsError(try t.observe(restoring: false))
        XCTAssertTrue(t.record?.observationPending == true); XCTAssertTrue(t.mutationOutcomeUnknown)
        let count = f.inspectCalls
        XCTAssertThrowsError(try f.make()); XCTAssertEqual(f.inspectCalls, count)
        f.failAllSavesFrom = nil
        let loaded = try f.make(); XCTAssertTrue(loaded.mutationOutcomeUnknown); XCTAssertEqual(f.inspectCalls, count)
    }
    func testPublicObservationReturnsTargetReachedAndUnpluggedWithoutAuthorizingNewWrites() throws {
        for unplugged in [false, true] {
            let f = Fixture(), t = try f.preparedAndApplied(); let count = f.writes.count
            f.observation.level = 79
            if unplugged {
                f.observation.adapterPresent = false; f.observation.nativeLimit = nil; f.observation.nativeEnabled = nil
                f.observation.registrations = []
            } else { f.observation.nativeLimit = 79; f.observation.registrations = [79] }
            XCTAssertEqual(try t.observe(restoring: false).level, 79)
            XCTAssertEqual(f.writes.count, count); XCTAssertFalse(t.mutationOutcomeUnknown)
            try t.restore(bootID: "boot-a", now: 20); XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
        }
    }
    func testDeadlineBeforeGetterIsKnownUnsubmittedButAfterGetterIsUnknown() throws {
        let f = Fixture(), t = try f.admission(); f.now = 190
        XCTAssertThrowsError(try t.confirmAdmission(bootID: "boot-a", now: 190))
        XCTAssertEqual(f.inspectCalls, 0); XCTAssertFalse(t.mutationOutcomeUnknown)
        let late = Fixture(), later = try late.admission(); late.afterInspect = { late.now = 190 }
        XCTAssertThrowsError(try later.confirmAdmission(bootID: "boot-a", now: 10))
        XCTAssertEqual(late.inspectCalls, 1); XCTAssertTrue(later.mutationOutcomeUnknown)
        let pending = Fixture(), p = try pending.prepare(); pending.rejectCancelledSubmission = true
        pending.afterSave = { if pending.disk?.observationPending == true { pending.cancelled = true } }
        XCTAssertThrowsError(try p.observe(restoring: false))
        XCTAssertTrue(p.mutationOutcomeUnknown); XCTAssertTrue(pending.writes.isEmpty)
    }

    func testObservedNative80FixtureAdmitsBeforeGettersAndRestoresExactAbsence() throws {
        let f = Fixture(); try f.loadObservedNative80()
        let original = f.values, t = try f.admission()
        XCTAssertEqual(f.inspectCalls, 0); XCTAssertEqual(t.record?.phase, .admissionPending)
        for key in [T.Key.isEngaged, .isManuallyChargeLimited] {
            XCTAssertEqual(t.record?.entries.first(where: { $0.key == key })?.original, .absent)
        }
        try t.confirmAdmission(bootID: "boot-a", now: 10)
        try t.apply(bootID: "boot-a", now: 10)
        XCTAssertEqual(f.values[.isEngaged], .integer(1)); XCTAssertEqual(f.values[.isManuallyChargeLimited], .integer(1))
        f.observation.nativeLimit = 79; f.observation.registrations = [79, 79]
        try t.restore(bootID: "boot-a", now: 20)
        XCTAssertNil(f.values[.isEngaged]); XCTAssertNil(f.values[.isManuallyChargeLimited])
        XCTAssertEqual(f.values, original)
        f.observation.nativeLimit = 80; f.observation.registrations = [80, 80]
        XCTAssertTrue(try t.finishRestoration(validated: true)); XCTAssertNil(f.disk)
    }
    func testEachMissingFlagCombinationPreservesOriginalTypesThroughWholeWorkerContract() throws {
        for missingMask in 0..<4 {
            let f = Fixture()
            f.values[.isEngaged] = missingMask & 1 == 0 ? .real(1) : nil
            f.values[.isManuallyChargeLimited] = missingMask & 2 == 0 ? .bool(true) : nil
            let original = f.values, t = try f.admission()
            try t.confirmAdmission(bootID: "boot-a", now: 10); try t.apply(bootID: "boot-a", now: 10)
            try t.restore(bootID: "boot-a", now: 20)
            XCTAssertEqual(f.values, original)
            XCTAssertTrue(try t.finishRestoration(validated: true))
        }
    }
    func testMissingFlagJournalRoundTripCanOnlyRestoreAfterRestart() throws {
        let f = Fixture(); try f.loadObservedNative80()
        let original = f.values, t = try f.admission()
        try t.confirmAdmission(bootID: "boot-a", now: 10); try t.apply(bootID: "boot-a", now: 10)
        f.disk = try JSONDecoder().decode(T.Record.self, from: JSONEncoder().encode(f.disk!))
        let loaded = try f.make()
        XCTAssertThrowsError(try loaded.apply(bootID: "boot-a", now: 11))
        try loaded.restore(bootID: "boot-b", now: 1)
        XCTAssertEqual(f.values, original)
        XCTAssertTrue(try loaded.finishRestoration(validated: true))
    }
    func testExternalInsertionBeforeMissingFlagAdmissionIsNotOwnedOrDeleted() throws {
        for key in [T.Key.isEngaged, .isManuallyChargeLimited] {
            let f = Fixture(); try f.loadObservedNative80(); let t = try f.admission()
            f.values[key] = .integer(1)
            XCTAssertThrowsError(try t.confirmAdmission(bootID: "boot-a", now: 10))
            XCTAssertEqual(f.inspectCalls, 0)
            XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
            XCTAssertEqual(f.values[key], .integer(1)); XCTAssertTrue(f.writes.isEmpty)
            XCTAssertEqual(f.signals, 0); XCTAssertNotNil(f.disk)
        }
    }
    func testExternalMissingFlagChangeBeforeRestoreBlocksDeletionAndNotification() throws {
        for key in [T.Key.isEngaged, .isManuallyChargeLimited] {
            let f = Fixture(); try f.loadObservedNative80(); let t = try f.preparedAndApplied()
            f.values[key] = .bool(false)
            XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
            XCTAssertEqual(f.values[key], .bool(false)); XCTAssertEqual(f.signals, 1)
            XCTAssertEqual(t.record?.phase, .blocked); XCTAssertNotNil(f.disk)
        }
    }
    func testMissingFlagDeleteThatMutatesThenFailsNeverClearsUnknownResponsibility() throws {
        let f = Fixture(); try f.loadObservedNative80(); let t = try f.preparedAndApplied()
        f.failWrite = f.writeAttempts + 2; f.mutateBeforeThrow = true
        XCTAssertThrowsError(try t.restore(bootID: "boot-a", now: 20))
        XCTAssertNil(f.values[.isEngaged]); XCTAssertTrue(t.mutationOutcomeUnknown)
        f.failWrite = nil; let loaded = try f.make()
        try loaded.restore(bootID: "boot-b", now: 1)
        XCTAssertNil(f.values[.isEngaged]); XCTAssertNil(f.values[.isManuallyChargeLimited])
        XCTAssertFalse(try loaded.finishRestoration(validated: true)); XCTAssertNotNil(f.disk)
        XCTAssertTrue(loaded.mutationOutcomeUnknown)
    }
    func testFinalConfirmationCannotEraseAnExternallyReintroducedMissingFlag() throws {
        let f = Fixture(); try f.loadObservedNative80(); let t = try f.preparedAndApplied()
        try t.restore(bootID: "boot-a", now: 20)
        f.values[.isEngaged] = .integer(1); let writes = f.writes.count
        XCTAssertThrowsError(try t.finishRestoration(validated: true))
        XCTAssertEqual(f.values[.isEngaged], .integer(1)); XCTAssertEqual(f.writes.count, writes)
        XCTAssertNotNil(f.disk)
    }
    func testInvalidOriginalReportsExactFieldWithoutRelaxingOtherGuards() throws {
        let cases: [(T.Key, V)] = [(.mclLimitValue, .bool(true)), (.mclFeatureState, .absent),
            (.isEngaged, .integer(0)), (.isManuallyChargeLimited, .bool(false)),
            (.initialChargeLimitSetDate, .bool(true)), (.disabledUntil, .integer(0)),
            (.mclOverridenUntilDate, .real(10)), (.mclSavedTargetSoC, .integer(80)),
            (.mclTempDisabledUntilDate, .real(1))]
        for (key, value) in cases {
            let f = Fixture(); try f.loadObservedNative80(); f.values[key] = value
            XCTAssertThrowsError(try f.admission()) { error in
                XCTAssertEqual(error as? T.Failure, .invalidOriginal(key))
                XCTAssertTrue(error.localizedDescription.contains(key.rawValue))
            }
            XCTAssertNil(f.disk); XCTAssertTrue(f.writes.isEmpty); XCTAssertEqual(f.inspectCalls, 0)
        }
    }

    private func observationFailures() -> [(inout T.Observation) -> Void] {
        [{ $0.nativeLimit = 79 }, { $0.nativeLimit = nil }, { $0.nativeEnabled = nil }, { $0.nativeEnabled = 0 }, { $0.registrations = [] }, { $0.registrations = [80, 85] },
         { $0.level = 79 }, { $0.level = 86 }, { $0.level = .nan }, { $0.adapterPresent = false },
         { $0.batteryCurrent = .infinity }, { $0.adapterPower = -.infinity }, { $0.competingController = true },
         { $0.calibrationActive = true }, { $0.wallDate = Date(timeIntervalSinceReferenceDate: .nan) }]
    }
    private enum Injected: Error { case failure }
    private final class Fixture {
        let owner = UUID()
        var now = 10.0
        var observation = T.Observation(nativeLimit: 80, nativeEnabled: 1, registrations: [80], level: 80,
            adapterPresent: true, batteryCurrent: 0, adapterPower: 20, wallDate: Date(timeIntervalSinceReferenceDate: 1000))
        var values: [T.Key: V] = [.checkpoint: .data(Data([1, 2])), .currentState: .string("old-state"),
            .mclLimitValue: .integer(80), .mclFeatureState: .integer(1),
            .isEngaged: .integer(1), .isManuallyChargeLimited: .integer(1), .initialChargeLimitSetDate: .real(100),
            .modeOfOperation: .integer(5)]
        var disk: T.Record?, saves = 0, reads = 0, inspectCalls = 0, writeAttempts = 0, signals = 0
        var inspectFailure: Error?
        var writes: [(T.Key, V)] = []
        var failSave: Int?, failAllSavesFrom: Int?, failRead: Int?, failWrite: Int?, failSignal: Int?, failDelete = false, mutateBeforeThrow = false
        var failSaveWhen: ((T.Record?) -> Bool)?, failAllSavesWhen: ((T.Record?) -> Bool)?
        var cancelled = false, rejectCancelledSubmission = false, restoring = false, saveThrowsNotSubmitted = false
        var writeError: Error = Injected.failure
        var afterWrite: ((T.Key, V) -> Void)?, afterSave: (() -> Void)?, afterInspect: (() -> Void)?
        func loadObservedNative80() throws {
            let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/BatteryPreferences79/native-80-absent-flags.json")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            let rows = json["values"] as! [String: [String: Any]]
            values.removeAll()
            for key in T.Key.allCases {
                let row = rows[key.rawValue]!
                let value = try V.fromFoundation(row["absent"] as? Bool == true ? nil : row["value"])
                store(key, value)
            }
        }
        private func store(_ key: T.Key, _ value: V) {
            if value == .absent { values.removeValue(forKey: key) }
            else { values[key] = value }
        }
        func make() throws -> T {
            try T(record: disk, read: { key in
                if self.cancelled && self.rejectCancelledSubmission && !self.restoring { throw T.Failure.notSubmitted }
                self.reads += 1; if self.failRead == self.reads { throw Injected.failure }
                return self.values[key] ?? .absent
            }, write: { key, value in
                if self.cancelled && self.rejectCancelledSubmission && !self.restoring { throw T.Failure.notSubmitted }
                self.writeAttempts += 1
                XCTAssertNotNil(self.disk)
                let entry = self.disk!.entries.first { $0.key == key }!
                XCTAssertTrue(entry.ack == .writeIntent || entry.ack == .restoreIntent)
                XCTAssertEqual(entry.prior, self.values[key] ?? .absent)
                try BatteryPreferences79IO.validateDesired(value, for: key, restoring: entry.ack == .restoreIntent)
                if self.failWrite == self.writeAttempts {
                    if self.mutateBeforeThrow { self.store(key, value) }
                    throw self.writeError
                }
                self.store(key, value); self.writes.append((key, value)); self.afterWrite?(key, value)
            }, save: { next in
                self.saves += 1
                if self.failSaveWhen?(next) == true { self.failSave = self.saves; self.failSaveWhen = nil }
                if self.failAllSavesWhen?(next) == true { self.failAllSavesFrom = self.saves; self.failAllSavesWhen = nil }
                if self.failSave == self.saves || self.failAllSavesFrom.map({ self.saves >= $0 }) == true || (next == nil && self.failDelete) {
                    if self.saveThrowsNotSubmitted { throw T.Failure.notSubmitted }
                    throw Injected.failure
                }
                self.disk = next; self.afterSave?()
            }, signal: {
                if self.cancelled && self.rejectCancelledSubmission && !self.restoring { throw T.Failure.notSubmitted }
                self.signals += 1
                XCTAssertTrue(self.disk?.phase == .applySignalIntent || self.disk?.phase == .restoreSignalIntent)
                let keys: [T.Key] = [.mclLimitValue, .mclFeatureState, .isEngaged, .isManuallyChargeLimited]
                try BatteryPreferences79IO.validateSignal(Dictionary(uniqueKeysWithValues: keys.map { ($0, self.values[$0] ?? .absent) }),
                    restoring: self.disk?.phase == .restoreSignalIntent)
                if self.failSignal == self.signals { throw Injected.failure }
            }, inspect: {
                if self.cancelled && self.rejectCancelledSubmission && !self.restoring { throw T.Failure.notSubmitted }
                self.inspectCalls += 1
                XCTAssertTrue(self.disk?.observationPending == true || self.disk?.phase == .admissionIntent)
                self.afterInspect?()
                if let failure = self.inspectFailure { throw failure }
                return self.observation
            }, continuousNow: { self.now })
        }
        func prepare() throws -> T {
            let t = try make(); try t.prepare(owner: owner, bootID: "boot-a", now: 10, observation: observation); return t
        }
        func admission() throws -> T {
            let t = try make(); var pure = observation; pure.nativeLimit = nil; pure.nativeEnabled = nil
            try t.prepareAdmission(owner: owner, bootID: "boot-a", now: 10, observation: pure); return t
        }
        func preparedAndApplied() throws -> T { let t = try prepare(); try t.apply(bootID: "boot-a", now: 10); return t }
    }
}
