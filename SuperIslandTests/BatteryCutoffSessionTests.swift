import XCTest
@testable import SuperIsland

final class BatteryCutoffSessionTests: XCTestCase {
    private let owner = UUID()
    private func session(timeout: Double = 90) throws -> BatteryCutoffSession {
        try BatteryCutoffSession(timeout: timeout) { _ in }
    }
    func testMissingTelemetryCannotInventAnOffOnRecovery() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: true, now: 1)
        let missing = BatteryTelemetry()
        XCTAssertNil(missing.powerSupplyObservation)
        XCTAssertFalse(try s.observeRecovery(powered: missing.powerSupplyObservation, controlsMatch: true, now: 2))
        XCTAssertFalse(s.record?.observedPowerOff == true)
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 3))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 20))
        XCTAssertFalse(try s.observeRecovery(powered: false, controlsMatch: true, now: 21))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 22))
        XCTAssertFalse(try s.observeRecovery(powered: nil, controlsMatch: true, now: 30))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 31))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 40))
        XCTAssertTrue(try s.observeRecovery(powered: true, controlsMatch: true, now: 41))
    }
    func testUnknownPowerRemainsBoundedEvenWhenConnectionFlagIsPresent() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.observeDischarge(owner: owner, owned: true, powered: nil, physicalConnection: true, now: 1)
        XCTAssertFalse(s.record?.observedPowerOff == true)
        XCTAssertThrowsError(try s.observeDischarge(owner: owner, owned: true, powered: nil, physicalConnection: true, now: 91))
    }
    func testMissingPowerFieldAndLegacySnapshotsStayUnknown() throws {
        let missing = BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100])
        XCTAssertNil(missing.powerSupplyObservation)
        let off = BatteryTelemetry.decode(["BatteryInstalled": true, "ExternalConnected": false])
        XCTAssertEqual(off.powerSupplyObservation, false)
        let on = BatteryTelemetry.decode(["BatteryInstalled": true, "ExternalConnected": true])
        XCTAssertEqual(on.powerSupplyObservation, true)
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        oldJSON.removeValue(forKey: "observedExternalPower")
        let legacy = try JSONDecoder().decode(BatteryTelemetry.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(legacy.powerSupplyObservation)
    }
    func testIntentMustBeDurableBeforeCutoffAndSaveFailureCannotArm() throws {
        var stored: BatteryCutoffSession.Record?
        var fail = true
        let s = try BatteryCutoffSession { next in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            stored = next
        }
        XCTAssertThrowsError(try s.arm(owner: owner, powered: true, now: 0))
        XCTAssertNil(s.record); XCTAssertNil(stored)
        fail = false
        try s.arm(owner: owner, powered: true, now: 0)
        XCTAssertEqual(stored?.phase, .discharging)
        XCTAssertEqual(stored?.owner, owner)
    }
    func testNoPoweredStartAndNoOwnershipProofCannotAuthorizeCutoff() throws {
        let s = try session()
        XCTAssertThrowsError(try s.arm(owner: owner, powered: false, now: 0))
        try s.arm(owner: owner, powered: true, now: 0)
        XCTAssertThrowsError(try s.observeDischarge(owner: owner, owned: false, powered: false, physicalConnection: nil, now: 1))
        XCTAssertThrowsError(try s.observeDischarge(owner: UUID(), owned: true, powered: false, physicalConnection: nil, now: 1))
        XCTAssertThrowsError(try s.beginRecovery(owner: UUID(), releasingLease: true, now: 1))
        XCTAssertEqual(s.record?.phase, .discharging)
    }
    func testTrustedContextRequiresSameOwnerOriginalsAndLiveRegister() throws {
        let s = try session(); try s.arm(owner: owner, powered: true, now: 0)
        var journal = BatteryOverrideLease.Journal(owner: owner, entries: ["CHIE": .init(original: 0, expected: 8)])
        XCTAssertTrue(try s.ownsCutoff(owner: owner, journal: journal, key: "CHIE", actual: 8))
        XCTAssertThrowsError(try s.ownsCutoff(owner: UUID(), journal: journal, key: "CHIE", actual: 8))
        XCTAssertThrowsError(try s.ownsCutoff(owner: owner, journal: nil, key: "CHIE", actual: 8))
        XCTAssertThrowsError(try s.ownsCutoff(owner: owner, journal: journal, key: "CHIE", actual: 0))
        XCTAssertThrowsError(try s.ownsCutoff(owner: owner, journal: journal, key: "CHIE", actual: nil))
        journal.owner = UUID()
        XCTAssertThrowsError(try s.ownsCutoff(owner: owner, journal: journal, key: "CHIE", actual: 8))
        journal.owner = owner; journal.entries["CHIE"]?.original = 8
        XCTAssertThrowsError(try s.ownsCutoff(owner: owner, journal: journal, key: "CHIE", actual: 8))
        journal.entries["CHIE"] = .init(original: 0, expected: 0)
        XCTAssertThrowsError(try s.ownsCutoff(owner: owner, journal: journal, key: "CHIE", actual: 8))
    }
    func testRecoveryAcceptsOnlySameRequestOrCurrentCalibrationCancellation() throws {
        let s = try session(), id = UUID()
        let previous = BatteryControlRequest(owner: owner, preferences: .init(), calibration: .start(id))
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: false, now: 1)
        XCTAssertTrue(s.acceptsRecoveryRequest(previous, previous: previous))
        var changed = previous; changed.owner = UUID()
        XCTAssertFalse(s.acceptsRecoveryRequest(changed, previous: previous))
        changed = previous; changed.preferences.limit = 85
        XCTAssertFalse(s.acceptsRecoveryRequest(changed, previous: previous))
        changed = previous; changed.mode = .topUp
        XCTAssertFalse(s.acceptsRecoveryRequest(changed, previous: previous))
        changed = previous; changed.calibration = .cancel(UUID())
        XCTAssertFalse(s.acceptsRecoveryRequest(changed, previous: previous))
        changed.calibration = .cancel(id)
        XCTAssertTrue(s.acceptsRecoveryRequest(changed, previous: previous))
        try s.beginRecovery(owner: owner, releasingLease: true, now: 2)
        XCTAssertFalse(s.acceptsRecoveryRequest(previous, previous: previous))
        XCTAssertFalse(s.acceptsRecoveryRequest(changed, previous: previous))
    }
    func testCompletedDischargeHeartbeatSurvivesTargetRecovery() throws {
        let s = try session()
        let original = BatteryControlRequest(owner: owner, preferences: .init(), mode: .discharge, dischargeTarget: 80)
        var automatic = original; automatic.mode = .automatic; automatic.dischargeTarget = nil
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: false, now: 1)
        XCTAssertFalse(s.acceptsRecoveryRequest(original, previous: automatic), "Raw stale modes are still rejected")
        let completion = BatteryCompletedRequest(original)
        XCTAssertEqual(completion.automatic, automatic)
        let normalized = completion.normalize(original)
        XCTAssertTrue(s.acceptsRecoveryRequest(normalized, previous: automatic),
            "A heartbeat queued before the client learns completion must not interrupt recovery")
        XCTAssertFalse(try s.observeRecovery(powered: false, controlsMatch: true, now: 2))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 3))
        XCTAssertTrue(try s.observeRecovery(powered: true, controlsMatch: true, now: 13))
        var rebound = BatteryTelemetry(); rebound.hasBattery = true; rebound.level = 81; rebound.onAC = true
        var policy = BatteryControlPolicy()
        XCTAssertFalse(try policy.decide(request: completion.normalize(original), snapshot: rebound).forceDischarge,
            "A delayed heartbeat after recovery must not restart the completed discharge")
    }
    func testCompletionCannotSwallowNewActionChangedPreferencesOrOtherOwner() throws {
        let original = BatteryControlRequest(owner: owner, preferences: .init(), mode: .discharge, dischargeTarget: 80)
        let completion = BatteryCompletedRequest(original)
        var next = original; next.operationID = UUID()
        XCTAssertEqual(completion.normalize(next), next)
        var rebound = BatteryTelemetry(); rebound.hasBattery = true; rebound.level = 81; rebound.onAC = true
        var policy = BatteryControlPolicy()
        XCTAssertTrue(try policy.decide(request: completion.normalize(next), snapshot: rebound).forceDischarge,
            "An explicit new action with the same target remains a new action")
        let edits: [(inout BatteryControlRequest) -> Void] = [
            { $0.owner = UUID() }, { $0.preferences.limit = 85 }, { $0.dischargeTarget = 79 },
            { $0.mode = .paused }, { $0.mode = .automatic; $0.dischargeTarget = nil; $0.operationID = UUID() },
            { $0.sleeping = true }, { $0.calibration = .start(UUID()) }]
        let session = try session()
        try session.arm(owner: owner, powered: true, now: 0)
        try session.beginRecovery(owner: owner, releasingLease: false, now: 1)
        for edit in edits {
            var changed = original; edit(&changed)
            XCTAssertEqual(completion.normalize(changed), changed)
            XCTAssertFalse(session.acceptsRecoveryRequest(completion.normalize(changed), previous: completion.automatic))
        }
        try session.beginRecovery(owner: owner, releasingLease: true, now: 2)
        XCTAssertFalse(session.acceptsRecoveryRequest(completion.normalize(original), previous: completion.automatic))
    }
    func testCompletionHeartbeatCannotExtendRecoveryTimeout() throws {
        let original = BatteryControlRequest(owner: owner, preferences: .init(), mode: .discharge, dischargeTarget: 80)
        let completion = BatteryCompletedRequest(original), session = try session()
        try session.arm(owner: owner, powered: true, now: 0)
        try session.beginRecovery(owner: owner, releasingLease: false, now: 1)
        for now in [2.0, 30, 60, 90, 91] {
            XCTAssertTrue(session.acceptsRecoveryRequest(completion.normalize(original), previous: completion.automatic))
            try session.beginRecovery(owner: owner, releasingLease: false, now: now)
            XCTAssertFalse(try session.observeRecovery(powered: false, controlsMatch: true, now: now))
        }
        XCTAssertEqual(session.record?.phase, .attention)
        let restarted = try BatteryCutoffSession(record: session.record) { _ in }
        XCTAssertFalse(restarted.acceptsRecoveryRequest(original, previous: nil), "Restart cannot resume an old task")
    }
    func testOperationIdentitySurvivesWireAndLegacyPayloadCannotInventOne() throws {
        let original = BatteryControlRequest(owner: owner, preferences: .init(), mode: .discharge, dischargeTarget: 80)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(BatteryControlRequest.self, from: encoded), original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "operationID")
        XCTAssertThrowsError(try JSONDecoder().decode(BatteryControlRequest.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }
    func testUnknownConnectionIsBoundedAndHeartbeatsCannotPostponeIt() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: nil, now: 1)
        try s.arm(owner: owner, powered: false, now: 89)
        XCTAssertNoThrow(try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: nil, now: 90))
        XCTAssertThrowsError(try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: nil, now: 91))
        XCTAssertTrue(s.record?.observedPowerOff == true)
    }
    func testKnownDisconnectAndUnacknowledgedCutoffStopTheRun() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        XCTAssertThrowsError(try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: false, now: 1))
        let unactuated = try session()
        try unactuated.arm(owner: owner, powered: true, now: 0)
        XCTAssertThrowsError(try unactuated.observeDischarge(owner: owner, owned: true, powered: true, physicalConnection: true, now: 90))
    }
    func testRegisterRestorationAloneDoesNotClearRecoveryAndTimeoutRetainsResponsibility() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: true, now: 1)
        XCTAssertFalse(try s.observeRecovery(powered: false, controlsMatch: true, now: 2))
        try s.beginRecovery(owner: owner, releasingLease: true, now: 89)
        XCTAssertFalse(try s.observeRecovery(powered: false, controlsMatch: true, now: 91))
        XCTAssertEqual(s.record?.phase, .attention)
        XCTAssertTrue(s.record?.releasingLease == true)
        XCTAssertThrowsError(try s.arm(owner: owner, powered: true, now: 92))
        // Real recovery after the timeout can clear through reads alone.
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 92))
        XCTAssertTrue(try s.observeRecovery(powered: true, controlsMatch: true, now: 102))
    }
    func testStaleACAndConflictingManualLimitCannotAcknowledgeRecovery() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: false, now: 1)
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 2))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 20))
        XCTAssertFalse(try s.observeRecovery(powered: false, controlsMatch: true, now: 21))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: false, now: 22))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: false, now: 40))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 41))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: false, now: 50))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 51))
        XCTAssertTrue(try s.observeRecovery(powered: true, controlsMatch: true, now: 61))
        XCTAssertNil(s.record)
    }
    func testFullReleaseIsStickyAndCannotBeDowngradedByContinuation() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: false, now: 1)
        try s.beginRecovery(owner: owner, releasingLease: true, now: 2)
        try s.beginRecovery(owner: owner, releasingLease: false, now: 3)
        XCTAssertTrue(s.record?.releasingLease == true)
    }
    func testUnappliedIntentCanClearOnlyBeforeAnyPowerOffWasObserved() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.beginRecovery(owner: owner, releasingLease: true, now: 1, mayHaveApplied: false)
        XCTAssertNil(s.record)
        try s.arm(owner: owner, powered: true, now: 2)
        try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: nil, now: 3)
        try s.beginRecovery(owner: owner, releasingLease: true, now: 4, mayHaveApplied: false)
        XCTAssertNotNil(s.record)
    }
    func testNativePreferenceOnlyRecoveryDoesNotRequireAPowerCycle() throws {
        let s = try session()
        try s.beginRecovery(owner: owner, releasingLease: true, now: 0, requiresSupplyRecovery: false)
        XCTAssertFalse(try s.observeRecovery(powered: false, controlsMatch: true, now: 0))
        XCTAssertTrue(try s.observeRecovery(powered: false, controlsMatch: true, now: 10))
    }
    func testRestartLosesStabilityEvidenceAndCannotResumeDischargeDuringRecovery() throws {
        let s = try session()
        try s.arm(owner: owner, powered: true, now: 0)
        try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: nil, now: 1)
        let restarted = try BatteryCutoffSession(record: s.record) { _ in }
        try restarted.beginRecovery(owner: owner, releasingLease: true, now: 0)
        XCTAssertThrowsError(try restarted.arm(owner: owner, powered: true, now: 1))
        XCTAssertFalse(try restarted.observeRecovery(powered: true, controlsMatch: true, now: 2))
        let again = try BatteryCutoffSession(record: restarted.record) { _ in }
        XCTAssertFalse(try again.observeRecovery(powered: true, controlsMatch: true, now: 20))
        XCTAssertTrue(try again.observeRecovery(powered: true, controlsMatch: true, now: 30))
    }
    func testClockRollbackCannotCreateFalseStability() throws {
        let s = try session()
        try s.beginRecovery(owner: owner, releasingLease: true, now: 100, requiresSupplyRecovery: false)
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 105))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 1))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 10))
        XCTAssertTrue(try s.observeRecovery(powered: true, controlsMatch: true, now: 11))
    }
    func testCompletionCheckpointFailureKeepsTheRecoveryRecord() throws {
        var fail = false
        let s = try BatteryCutoffSession { _ in if fail { throw CocoaError(.fileWriteOutOfSpace) } }
        try s.beginRecovery(owner: owner, releasingLease: true, now: 0, requiresSupplyRecovery: false)
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 0))
        fail = true
        XCTAssertThrowsError(try s.observeRecovery(powered: true, controlsMatch: true, now: 10))
        XCTAssertNotNil(s.record)
        fail = false
        XCTAssertTrue(try s.observeRecovery(powered: true, controlsMatch: true, now: 11))
    }
    func testMalformedPersistentStateAndInvalidClockAreRejected() throws {
        var r = BatteryCutoffSession.Record(owner: owner, phase: .discharging)
        r.releasingLease = true
        XCTAssertThrowsError(try BatteryCutoffSession(record: r) { _ in })
        r.releasingLease = false; r.requiresSupplyRecovery = false
        XCTAssertThrowsError(try BatteryCutoffSession(record: r) { _ in })
        r.phase = .restoring
        XCTAssertThrowsError(try BatteryCutoffSession(record: r) { _ in })
        r.releasingLease = true; r.schema = 2
        XCTAssertThrowsError(try BatteryCutoffSession(record: r) { _ in })
        let s = try session()
        XCTAssertThrowsError(try s.arm(owner: owner, powered: true, now: .nan))
        XCTAssertThrowsError(try s.beginRecovery(owner: owner, releasingLease: true, now: -1))
    }
}

final class BatteryDeferredRestorationTests: XCTestCase {
    func testRestoredRegistersStayOwnedUntilActualSupplyIsStableWithoutRewrites() throws {
        let owner = UUID()
        var values = ["CHIE": 0, "nativeAPILimit": 80], writes = 0
        let lease = BatteryOverrideLease(read: { values[$0]! }, write: { values[$0] = $1; writes += 1 }, save: { _ in })
        let s = try BatteryCutoffSession { _ in }
        try lease.renew(owner: owner, now: 0)
        try s.arm(owner: owner, powered: true, now: 0)
        try lease.apply(["CHIE": 8, "nativeAPILimit": 82], owner: owner)
        try s.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: nil, now: 1)
        try s.beginRecovery(owner: owner, releasingLease: true, now: 2)
        var time = 2.0, powered = false
        let verifier: (BatteryOverrideLease.Journal) throws -> Bool = { journal in
            XCTAssertEqual(journal.entries["nativeAPILimit"]?.original, 80)
            XCTAssertEqual(lease.journal, journal, "Checkpoint must precede the recovery verifier")
            return try s.observeRecovery(powered: powered, controlsMatch: true, now: time)
        }
        XCTAssertFalse(try lease.release(owner: owner, verifyRestoration: verifier))
        XCTAssertEqual(values, ["CHIE": 0, "nativeAPILimit": 80])
        let count = writes
        for t in [3.0, 30, 92] {
            time = t
            XCTAssertFalse(try lease.release(owner: owner, verifyRestoration: verifier))
        }
        XCTAssertEqual(writes, count); XCTAssertNotNil(lease.journal)
        XCTAssertEqual(s.record?.phase, .attention)
        time = 93; powered = true
        XCTAssertFalse(try lease.release(owner: owner, verifyRestoration: verifier))
        time = 103
        XCTAssertTrue(try lease.release(owner: owner, verifyRestoration: verifier))
        XCTAssertEqual(writes, count); XCTAssertNil(lease.journal); XCTAssertNil(s.record)
    }
    func testLaterExternalChangeIsNotOverwrittenByRecoveryRetries() throws {
        let owner = UUID(); var value = 80, writes = 0
        let lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in value = v; writes += 1 }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 82], owner: owner)
        XCTAssertFalse(try lease.release(verifyRestoration: { _ in false }))
        let count = writes; value = 82 // Replug or another controller changed it back.
        XCTAssertThrowsError(try lease.release(verifyRestoration: { _ in XCTFail("Unmatched values cannot reach verifier"); return true }))
        XCTAssertEqual(value, 82); XCTAssertEqual(writes, count); XCTAssertNotNil(lease.journal)
    }
    func testCrashAfterRestoreBeforeAcknowledgementCanRetryWithoutWritingAgain() throws {
        let owner = UUID(); var value = 82, saved: BatteryOverrideLease.Journal?
        let initial = BatteryOverrideLease.Journal(owner: owner, entries: ["limit": .init(original: 80, expected: 82)])
        var failAcknowledgement = true, writes = 0
        let lease = BatteryOverrideLease(journal: initial, read: { _ in value }, write: { _, v in value = v; writes += 1 }, save: { next in
            if next?.entries["limit"]?.prior == nil && failAcknowledgement { throw CocoaError(.fileWriteOutOfSpace) }
            saved = next
        })
        XCTAssertThrowsError(try lease.release(verifyRestoration: { _ in true }))
        XCTAssertEqual(saved?.entries["limit"]?.prior, 82)
        XCTAssertEqual(value, 80)
        failAcknowledgement = false
        let restarted = BatteryOverrideLease(journal: saved, read: { _ in value }, write: { _, _ in writes += 1 }, save: { saved = $0 })
        XCTAssertFalse(try restarted.release(verifyRestoration: { _ in false }))
        XCTAssertTrue(try restarted.release(verifyRestoration: { _ in true }))
        XCTAssertEqual(writes, 1); XCTAssertNil(saved)
    }
    func testRestoreIntentSaveFailurePreventsHardwareWriteAndRetainsOriginals() throws {
        var writes = 0
        let initial = BatteryOverrideLease.Journal(owner: UUID(), entries: ["limit": .init(original: 80, expected: 82)])
        let lease = BatteryOverrideLease(journal: initial, read: { _ in 82 }, write: { _, _ in writes += 1 }, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try lease.release(verifyRestoration: { _ in true }))
        XCTAssertEqual(writes, 0); XCTAssertEqual(lease.journal, initial)
    }
    func testFinalJournalRemovalFailureCannotAcknowledgeRelease() throws {
        var value = 82, failRemoval = true, writes = 0
        let initial = BatteryOverrideLease.Journal(owner: UUID(), entries: ["limit": .init(original: 80, expected: 82)])
        let lease = BatteryOverrideLease(journal: initial, read: { _ in value }, write: { _, v in value = v; writes += 1 }, save: { next in
            if next == nil && failRemoval { throw CocoaError(.fileWriteOutOfSpace) }
        })
        XCTAssertThrowsError(try lease.release(verifyRestoration: { _ in true }))
        XCTAssertNotNil(lease.journal)
        failRemoval = false
        XCTAssertTrue(try lease.release(verifyRestoration: { _ in true }))
        XCTAssertEqual(writes, 1)
    }
    func testPartialNativeEnablementRecoveryNeedsPositiveRegistrationEvidence() {
        XCTAssertTrue(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 0, savedManualLimit: nil, registrations: []))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 0, savedManualLimit: nil, registrations: nil))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 0, savedManualLimit: 80, registrations: [80]))
        XCTAssertTrue(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 1, savedManualLimit: 82, registrations: [82]))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 1, savedManualLimit: nil, registrations: [82]))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 1, savedManualLimit: 80, registrations: [82]))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: nil, enabled: 2, savedManualLimit: 80, registrations: [80]))
    }
    func testNativeRecoveryRejectsReplugLimitDriftAndAmbiguousRegistrations() {
        XCTAssertTrue(BatteryNativeRegistration.restorationMatches(limit: 80, enabled: 1, savedManualLimit: 80, registrations: [80]))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: 80, enabled: 1, savedManualLimit: 82, registrations: [82]))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: 80, enabled: 1, savedManualLimit: 80, registrations: [80, 82]))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: 80, enabled: 1, savedManualLimit: 80, registrations: nil))
        XCTAssertTrue(BatteryNativeRegistration.restorationMatches(limit: 80, enabled: 0, savedManualLimit: 80, registrations: []))
        XCTAssertFalse(BatteryNativeRegistration.restorationMatches(limit: 80, enabled: 0, savedManualLimit: 82, registrations: []))
    }
    func testForeignOwnerCannotReleasePendingRecovery() throws {
        let initial = BatteryOverrideLease.Journal(owner: UUID(), entries: ["limit": .init(original: 80, expected: 80)])
        var writes = 0
        let lease = BatteryOverrideLease(journal: initial, read: { _ in 80 }, write: { _, _ in writes += 1 }, save: { _ in })
        XCTAssertThrowsError(try lease.release(owner: UUID(), verifyRestoration: { _ in true }))
        XCTAssertEqual(writes, 0); XCTAssertEqual(lease.journal, initial)
    }
}

final class BatteryCutoffTargetOwnershipTests: XCTestCase {
    func testAutomaticControlNeverAcquiresOrRestoresAnExternalCutoff() throws {
        for (key, active) in [("CHIE", 8), ("CH0I", 1), ("CH0J", 1)] {
            var value = active, writes = 0
            let owner = UUID()
            let lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in value = v; writes += 1 }, save: { _ in })
            try lease.renew(owner: owner, now: 0)
            XCTAssertThrowsError(try BatteryCutoffTargets.make(key: key, forceDischarge: false, ownedKeys: [], read: { _ in value }))
            XCTAssertThrowsError(try BatteryCutoffTargets.make(key: key, forceDischarge: true, ownedKeys: [], read: { _ in value }))
            try lease.release(owner: owner)
            XCTAssertEqual(writes, 0); XCTAssertEqual(value, active)
        }
    }
    func testInactiveUnownedCutoffIsNotAddedToTheLease() throws {
        var values = ["CHIE": 0, "limit": 80], changedKeys: [String] = []
        let owner = UUID(), lease = BatteryOverrideLease(read: { values[$0]! }, write: { values[$0] = $1; changedKeys.append($0) }, save: { _ in })
        try lease.renew(owner: owner, now: 0)
        var targets = try BatteryCutoffTargets.make(key: "CHIE", forceDischarge: false, ownedKeys: [], read: { values[$0]! })
        targets["limit"] = 82
        try lease.apply(targets, owner: owner)
        XCTAssertNil(lease.journal?.entries["CHIE"])
        try lease.release(owner: owner)
        XCTAssertFalse(changedKeys.contains("CHIE")); XCTAssertEqual(values, ["CHIE": 0, "limit": 80])
    }
    func testOnlyAnOwnedCutoffCanPlanItsRelease() throws {
        var value = 0, writes: [Int] = []
        let owner = UUID(), lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in value = v; writes.append(v) }, save: { _ in })
        try lease.renew(owner: owner, now: 0)
        try lease.apply(BatteryCutoffTargets.make(key: "CHIE", forceDischarge: true, ownedKeys: [], read: { _ in value }), owner: owner)
        try lease.apply(BatteryCutoffTargets.make(key: "CHIE", forceDischarge: false, ownedKeys: Set(lease.journal!.entries.keys), read: { _ in value }), owner: owner)
        try lease.release(owner: owner)
        XCTAssertEqual(writes, [8, 0]); XCTAssertEqual(value, 0)
    }
    func testLegacyExternalCutoffOriginalCannotBeWrittenBackOnRestart() throws {
        for (key, active) in [("CHIE", 8), ("CH0I", 1), ("CH0J", 1)] {
            let old = BatteryOverrideLease.Journal(owner: UUID(), entries: [key: .init(original: active, expected: 0)])
            XCTAssertThrowsError(try BatteryCutoffTargets.validateRestoration(old))
        }
        let ours = BatteryOverrideLease.Journal(owner: UUID(), entries: ["CHIE": .init(original: 0, expected: 8)])
        XCTAssertNoThrow(try BatteryCutoffTargets.validateRestoration(ours))
    }
    func testUnreadableAndUnsupportedCutoffCannotBeAcquired() {
        XCTAssertThrowsError(try BatteryCutoffTargets.make(key: "CHIE", forceDischarge: false, ownedKeys: [], read: { _ in throw CocoaError(.fileReadUnknown) }))
        XCTAssertThrowsError(try BatteryCutoffTargets.make(key: "anything", forceDischarge: true, ownedKeys: [], read: { _ in 0 }))
    }
}

final class BatterySMCDiscoveryTests: XCTestCase {
    func testDiscoveryUsesOnlyFixedReadKeysAndPreservesFailuresAsUnknown() throws {
        var keys: [String] = []
        let result = BatterySMCDiscovery.capture(sourceUID: 0) { key in
            keys.append(key)
            if key == "bfD0" { throw BatteryControlError.unavailable("permission denied") }
            return .init(type: "ui8 ", bytes: [0])
        }
        XCTAssertEqual(keys, ["bfF0", "bfD0", "bfE0"])
        XCTAssertEqual(result.sourceUID, 0)
        let failed = try XCTUnwrap(result.registers.first { $0.key == "bfD0" })
        XCTAssertNil(failed.bytes); XCTAssertNil(failed.type); XCTAssertNotNil(failed.failure)
        XCTAssertEqual(result.registers.first?.bytes, [0], "A successful zero read stays distinct from failure")
        var report = BatteryControlReport(); report.smcDiscovery = result
        XCTAssertEqual(try JSONDecoder().decode(BatteryControlReport.self, from: JSONEncoder().encode(report)).smcDiscovery, result)
    }
    func testHelperPackageFlagProtectsCachedRegistrationsWithoutNewArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BM1PackageFlag-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Contents/MacOS/BatteryManagementHelper")
        let info = root.appendingPathComponent("Contents/Info.plist")
        func write(_ identifier: String, diagnostic: Bool) throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "BM1DiagnosticsOnly": diagnostic], format: .xml, options: 0).write(to: info)
        }
        try write("com.workview.SuperIsland.BM1Debug", diagnostic: true)
        let flag = BatteryManagementIdentity.packageDiagnosticsOnly(executableURL: executable)
        XCTAssertEqual(flag, true)
        XCTAssertTrue(BatteryManagementIdentity.diagnosticHelper(arguments: ["old cached argv0"], packageFlag: flag))
        try write("com.workview.SuperIsland.BM1Debug", diagnostic: false)
        XCTAssertEqual(BatteryManagementIdentity.packageDiagnosticsOnly(executableURL: executable), false)
        try write("com.workview.SuperIsland", diagnostic: true)
        XCTAssertEqual(BatteryManagementIdentity.packageDiagnosticsOnly(executableURL: executable), false)
    }
    func testUnknownHelperParentPackageCannotEnableControl() {
        XCTAssertNil(BatteryManagementIdentity.packageDiagnosticsOnly(executableURL: nil))
        XCTAssertTrue(BatteryManagementIdentity.diagnosticHelper(arguments: [], packageFlag: nil))
    }
    func testFixedDiagnosticPackageRemainsReadOnlyWithoutLaunchArguments() {
        XCTAssertTrue(BatteryStartupContext.diagnosticsOnly(bundleIdentifier: "com.workview.SuperIsland.BM1Debug", arguments: [], packageFlag: true))
        XCTAssertFalse(BatteryStartupContext.automaticallyEnables(defaultLaunch: true, bundleIdentifier: "com.workview.SuperIsland.BM1Debug", arguments: [], packageFlag: true))
        XCTAssertFalse(BatteryStartupContext.diagnosticsOnly(bundleIdentifier: "com.workview.SuperIsland", arguments: [], packageFlag: true))
        XCTAssertTrue(BatteryManagementIdentity.diagnosticHelper(arguments: ["Contents/MacOS/BatteryManagementHelper", "--bm1-helper-diagnostics"]))
        XCTAssertFalse(BatteryManagementIdentity.diagnosticHelper(arguments: ["Contents/MacOS/BatteryManagementHelper"]))
    }
    func testDiagnosticLaunchIsRestrictedToReviewIDAndDefersReopenControl() {
        let flag = ["app", "--bm1-diagnostics"]
        XCTAssertTrue(BatteryStartupContext.diagnosticsOnly(bundleIdentifier: "com.workview.SuperIsland.BM1Debug", arguments: flag))
        XCTAssertFalse(BatteryStartupContext.automaticallyEnables(defaultLaunch: true, bundleIdentifier: "com.workview.SuperIsland.BM1Debug", arguments: flag))
        XCTAssertTrue(BatteryStartupContext.automaticallyEnables(defaultLaunch: true, bundleIdentifier: "com.workview.SuperIsland", arguments: flag))
        XCTAssertFalse(BatteryStartupContext.diagnosticsOnly(bundleIdentifier: nil, arguments: flag))
        XCTAssertTrue(BatteryStartupContext.automaticallyEnables(defaultLaunch: true, bundleIdentifier: "com.workview.SuperIsland.BM1Debug", arguments: []))
    }
}


final class BatteryCutoffHandoffTests: XCTestCase {
    private final class Rig {
        let owner = UUID()
        var values = ["CHIE": 0, "nativeAPILimit": 80, "nativeAPIEnabled": 1, "ACLC": 0]
        var writes: [String] = []
        var saved: BatteryOverrideLease.Journal?
        var failRestoreCheckpoint = false, failRestoreAcknowledgement = false
        var input: Bool? = false
        var registered = 100
        lazy var lease = BatteryOverrideLease(read: { self.values[$0]! }, write: {
            self.values[$0] = $1; self.writes.append("\($0)=\($1)")
        }, save: { next in
            if next?.entries["CHIE"]?.expected == 0 {
                if self.failRestoreCheckpoint && next?.entries["CHIE"]?.prior == 8 { throw CocoaError(.fileWriteOutOfSpace) }
                if self.failRestoreAcknowledgement && next?.entries["CHIE"]?.prior == nil { throw CocoaError(.fileWriteOutOfSpace) }
            }
            self.saved = next
        })
        lazy var session = try! BatteryCutoffSession { _ in }
        func start() throws {
            try lease.renew(owner: owner, now: 0)
            XCTAssertTrue(try BatteryCutoffHandoff.prepareNative(lease: lease, owner: owner, registrationsMatch: matches))
            try session.arm(owner: owner, powered: true, now: 0)
            try lease.apply(["nativeAPIEnabled": 1, "nativeAPILimit": 100, "CHIE": 8], owner: owner)
            try session.beginRecovery(owner: owner, releasingLease: true, now: 1)
        }
        func matches(_ journal: BatteryOverrideLease.Journal) -> Bool {
            if let cutoff = journal.entries["CHIE"], values["CHIE"] != cutoff.expected { return false }
            return values["nativeAPILimit"] == journal.entries["nativeAPILimit"]?.expected
                && registered == journal.entries["nativeAPILimit"]?.expected
        }
        func recover(_ now: Double, session override: BatteryCutoffSession? = nil, lease other: BatteryOverrideLease? = nil) throws -> Bool {
            try BatteryCutoffHandoff.recover(lease: other ?? lease, session: override ?? session, now: now,
                powered: { self.input }, controlsMatch: matches)
        }
    }
    func testNeutralRegistrationPrecedesCutoffAndLowerOriginalWaitsForIndependentInput() throws {
        let r = Rig(); try r.start()
        XCTAssertEqual(r.writes, ["nativeAPILimit=100", "CHIE=8"])
        // AC can remain connected during native drain; it is deliberately not
        // supplied as input evidence to the real shared coordinator.
        XCTAssertFalse(try r.recover(1))
        XCTAssertEqual(r.values["CHIE"], 0); XCTAssertEqual(r.values["nativeAPILimit"], 100)
        XCTAssertEqual(r.lease.journal?.entries["nativeAPILimit"]?.original, 80)
        let count = r.writes.count
        r.input = nil; XCTAssertFalse(try r.recover(20))
        r.input = true; XCTAssertFalse(try r.recover(21))
        XCTAssertFalse(try r.recover(30)); XCTAssertTrue(try r.recover(31))
        XCTAssertNil(r.session.record); XCTAssertNotNil(r.lease.journal)
        XCTAssertEqual(r.writes.count, count, "Supply observation must not repeat cutoff or native writes")
        // Only now restore the lower original. Its registration check must not
        // require another off/on cycle, because macOS may intentionally drain.
        try r.session.beginRecovery(owner: r.owner, releasingLease: true, now: 31, requiresSupplyRecovery: false)
        XCTAssertFalse(try r.lease.release(verifyRestoration: { _ in
            try r.session.observeRecovery(powered: false, controlsMatch: true, now: 31)
        }))
        XCTAssertEqual(r.values["nativeAPILimit"], 80)
        XCTAssertTrue(try r.lease.release(verifyRestoration: { _ in
            try r.session.observeRecovery(powered: false, controlsMatch: true, now: 41)
        }))
        XCTAssertNil(r.lease.journal)
        XCTAssertEqual(r.writes, ["nativeAPILimit=100", "CHIE=8", "CHIE=0", "nativeAPILimit=80"])
    }
    func testRegistrationPreparationCannotAcquireCutoffOrLoseOriginals() throws {
        let r = Rig(); try r.lease.renew(owner: r.owner, now: 0)
        r.registered = 80
        XCTAssertFalse(try BatteryCutoffHandoff.prepareNative(lease: r.lease, owner: r.owner, registrationsMatch: r.matches))
        XCTAssertEqual(r.values["CHIE"], 0); XCTAssertNil(r.lease.journal?.entries["CHIE"])
        XCTAssertNil(r.session.record)
        XCTAssertEqual(r.lease.journal?.entries["nativeAPILimit"]?.original, 80)
        let count = r.writes.count; r.registered = 100
        XCTAssertTrue(try BatteryCutoffHandoff.prepareNative(lease: r.lease, owner: r.owner, registrationsMatch: r.matches))
        XCTAssertEqual(r.writes.count, count)
        try r.lease.release(); XCTAssertEqual(r.values["nativeAPILimit"], 80)
    }
    func testNativeDriftCannotRestoreLowerLimitOrClearResponsibility() throws {
        let r = Rig(); try r.start(); XCTAssertFalse(try r.recover(1))
        r.input = true; r.registered = 80
        XCTAssertFalse(try r.recover(2)); XCTAssertFalse(try r.recover(100))
        XCTAssertEqual(r.values["nativeAPILimit"], 100); XCTAssertNotNil(r.lease.journal)
        XCTAssertEqual(r.session.record?.phase, .attention)
        r.registered = 100
        XCTAssertFalse(try r.recover(101)); XCTAssertTrue(try r.recover(111))
    }
    func testRestartAfterCutoffAcknowledgementFailureRestoresWithoutRepeatingWrite() throws {
        let r = Rig(); try r.start(); r.failRestoreAcknowledgement = true
        XCTAssertThrowsError(try r.recover(1))
        XCTAssertEqual(r.values["CHIE"], 0); XCTAssertEqual(r.saved?.entries["CHIE"]?.prior, 8)
        r.failRestoreAcknowledgement = false
        let restartedLease = BatteryOverrideLease(journal: r.saved, read: { r.values[$0]! }, write: {
            r.values[$0] = $1; r.writes.append("\($0)=\($1)")
        }, save: { r.saved = $0 })
        let restartedSession = try BatteryCutoffSession(record: r.session.record) { _ in }
        r.input = true
        XCTAssertFalse(try r.recover(2, session: restartedSession, lease: restartedLease))
        XCTAssertTrue(try r.recover(12, session: restartedSession, lease: restartedLease))
        XCTAssertEqual(r.writes.filter { $0 == "CHIE=0" }.count, 1)
        XCTAssertEqual(restartedLease.journal?.entries["nativeAPILimit"]?.original, 80)
        XCTAssertEqual(r.values["nativeAPILimit"], 100)
    }
    func testRestoreSaveFailureNeverWritesAndDoesNotDiscardRecovery() throws {
        let r = Rig(); try r.start(); r.failRestoreCheckpoint = true
        let count = r.writes.count
        XCTAssertThrowsError(try r.recover(1))
        XCTAssertEqual(r.writes.count, count); XCTAssertEqual(r.values["CHIE"], 8)
        XCTAssertNotNil(r.session.record); XCTAssertEqual(r.lease.journal?.entries["CHIE"]?.expected, 8)
        r.failRestoreCheckpoint = false
        XCTAssertFalse(try r.recover(2)); XCTAssertEqual(r.values["CHIE"], 0)
    }
    func testUnknownInputCannotCompleteEvenWhenAllRegistersMatch() throws {
        let r = Rig(); try r.start(); r.input = nil
        XCTAssertFalse(try r.recover(1)); XCTAssertFalse(try r.recover(100))
        XCTAssertEqual(r.values["CHIE"], 0); XCTAssertEqual(r.values["nativeAPILimit"], 100)
        XCTAssertNotNil(r.session.record); XCTAssertNotNil(r.lease.journal)
        r.input = true
        XCTAssertFalse(try r.recover(101)); XCTAssertFalse(try r.recover(111), "No off observation exists")
    }
    func testForeignOwnerAndExternalCutoffEditsAreNeverOverwritten() throws {
        let r = Rig(); try r.start(); let count = r.writes.count
        XCTAssertThrowsError(try BatteryCutoffHandoff.recover(lease: r.lease, session: r.session, owner: UUID(),
            now: 1, powered: { false }, controlsMatch: { _ in true }))
        XCTAssertEqual(r.writes.count, count)
        r.values["CHIE"] = 4
        XCTAssertThrowsError(try r.recover(2))
        XCTAssertEqual(r.values["CHIE"], 4); XCTAssertEqual(r.writes.count, count)
        XCTAssertNotNil(r.session.record); XCTAssertNotNil(r.lease.journal)
    }
    func testLegacyConnectionFlagEvidenceCannotBecomeIndependentInputProofAfterUpgrade() throws {
        let r = Rig(); try r.start()
        var old = try XCTUnwrap(r.session.record)
        old.observedPowerOff = true
        let encoded = try JSONEncoder().encode(old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "inputEvidenceVersion")
        let decoded = try JSONDecoder().decode(BatteryCutoffSession.Record.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.inputEvidenceVersion)
        let migrated = try BatteryCutoffSession(record: decoded) { _ in }
        XCTAssertEqual(migrated.record?.observedPowerOff, false)
        r.input = true
        XCTAssertFalse(try r.recover(2, session: migrated))
        XCTAssertFalse(try r.recover(12, session: migrated))
        XCTAssertNotNil(migrated.record); XCTAssertEqual(r.values["nativeAPILimit"], 100)
        r.input = false; XCTAssertFalse(try r.recover(13, session: migrated))
        r.input = true; XCTAssertFalse(try r.recover(14, session: migrated))
        XCTAssertTrue(try r.recover(24, session: migrated))
        var unknown = decoded; unknown.inputEvidenceVersion = 2
        XCTAssertThrowsError(try BatteryCutoffSession(record: unknown) { _ in })
    }
    func testUncertainUnrelatedWriteDoesNotBlockReleasingOwnedCutoff() throws {
        var values = ["CHIE": 8, "ACLC": 1]
        let owner = UUID()
        let journal = BatteryOverrideLease.Journal(owner: owner, entries: [
            "CHIE": .init(original: 0, expected: 8), "ACLC": .init(original: 0, expected: 4, prior: 1)])
        let lease = BatteryOverrideLease(journal: journal, read: { values[$0]! }, write: { values[$0] = $1 }, save: { _ in })
        try lease.restore(keys: ["CHIE"], owner: owner)
        XCTAssertEqual(values, ["CHIE": 0, "ACLC": 1])
        XCTAssertEqual(lease.journal?.entries["ACLC"]?.prior, 1)
        XCTAssertNotNil(lease.journal?.entries["CHIE"])
    }
}

final class BatteryAdapterInputTests: XCTestCase {
    private func value(_ number: Float) -> BatterySMC.Value {
        var bits = number.bitPattern.littleEndian
        return .init(type: "flt ", bytes: withUnsafeBytes(of: &bits) { Array($0) })
    }
    func testFixedFreshReadsDecodeUsefulInputWithoutOSFlagsOrCachedReport() throws {
        var keys: [String] = []
        let watts = BatteryAdapterInput.watts { key in
            keys.append(key); return self.value(key == "VD0R" ? 20 : 1.25)
        }
        XCTAssertEqual(keys, ["VD0R", "ID0R"]); XCTAssertEqual(watts, 25)
        XCTAssertEqual(BatteryAdapterInput.supplying(watts: watts), true)
        XCTAssertEqual(BatteryAdapterInput.supplying(watts: 0), false)
        XCTAssertEqual(BatteryAdapterInput.supplying(watts: 1), false)
        XCTAssertEqual(BatteryAdapterInput.supplying(watts: 1.01), true)
    }
    func testReadFailuresInvalidTypesAndNonfiniteValuesStayUnknown() {
        XCTAssertNil(BatteryAdapterInput.watts { _ in throw CocoaError(.fileReadUnknown) })
        for invalid in [BatterySMC.Value(type: "ui16", bytes: [0, 1]), .init(type: "flt ", bytes: [0]),
                        value(.nan), value(.infinity), value(-1), value(61)] {
            XCTAssertNil(BatteryAdapterInput.watts { _ in invalid })
        }
        XCTAssertNil(BatteryAdapterInput.watts { self.value($0 == "VD0R" ? 20 : 21) })
        for invalid: Double? in [nil, .nan, .infinity, -1, 1201] {
            XCTAssertNil(BatteryAdapterInput.supplying(watts: invalid))
        }
    }
}


final class BatteryNativeCutoffTrialTests: XCTestCase {
    func testOnlyExplicitReviewPackageCanEnableTheBoundedTrial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BM1TrialFlag-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Contents/MacOS/BatteryManagementHelper")
        let info = root.appendingPathComponent("Contents/Info.plist")
        for (id, flag, diagnostic, expected) in [
            ("com.workview.SuperIsland", true, false, false),
            ("com.workview.SuperIsland.BM1Debug", false, false, false),
            ("com.workview.SuperIsland.BM1Debug", true, true, false),
            ("com.workview.SuperIsland.BM1Debug", true, false, true),
            ("unknown", true, false, false)] {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
                "BM1NativeCutoffTrial": flag, "BM1NativeCutoffTrialDurationSeconds": 600, "BM1DiagnosticsOnly": diagnostic], format: .xml, options: 0).write(to: info)
            XCTAssertEqual(BatteryManagementIdentity.packageNativeCutoffTrial(executableURL: executable), expected)
        }
        for duration: Int? in [nil, 10, 599, 601] {
            var contents: [String: Any] = ["CFBundleIdentifier": "com.workview.SuperIsland.BM1Debug", "BM1NativeCutoffTrial": true]
            if let duration { contents["BM1NativeCutoffTrialDurationSeconds"] = duration }
            try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: info)
            XCTAssertFalse(BatteryManagementIdentity.packageNativeCutoffTrial(executableURL: executable),
                "An old ten-second package or mismatched seal cannot inherit the longer trial")
        }
        XCTAssertFalse(BatteryManagementIdentity.packageNativeCutoffTrial(executableURL: nil))
        XCTAssertFalse(BatteryManagementIdentity.packageNativeCutoffTrial(executableURL: info))
    }
    func testFixedRequestRangeAndModeRestrictions() throws {
        var r = BatteryControlRequest(owner: UUID(), preferences: .init())
        try BatteryNativeCutoffTrial.validate(r, level: 79)
        r.preferences.limit = 85; try BatteryNativeCutoffTrial.validate(r, level: 85)
        r.mode = .discharge; r.dischargeTarget = 80
        try BatteryNativeCutoffTrial.validate(r, level: 81)
        for level: Int? in [nil, 78, 86, 100] { XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(r, level: level)) }
        for target in [10, 79, 81] {
            r.dischargeTarget = target
            XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(r, level: 81))
        }
        r.dischargeTarget = 80; r.preferences.limit = 100
        XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(r, level: 81))
        r.preferences.limit = 80; r.mode = .topUp
        XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(r, level: 81))
        r.mode = .automatic; r.calibration = .start(UUID())
        XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(r, level: 81))
    }
    func testAdditionalHardwareAndSleepModesCannotEnterFixedTrial() {
        let edits: [(inout BatteryControlPreferences) -> Void] = [
            { $0.allowLowLimit = true }, { $0.automaticDischarge = true }, { $0.sailing = true },
            { $0.heatProtection = true }, { $0.sleep = .pause }, { $0.lowPower = .always },
            { $0.highPowerScope = .adapter }, { $0.led = .green }, { $0.blinkWhileDischarging = true }]
        for edit in edits {
            var p = BatteryControlPreferences(); edit(&p)
            XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(.init(owner: UUID(), preferences: p), level: 81))
        }
        var r = BatteryControlRequest(owner: UUID(), preferences: .init()); r.sleeping = true
        XCTAssertThrowsError(try BatteryNativeCutoffTrial.validate(r, level: 81))
    }
    func testDeadlineCannotBeExtendedByHeartbeatRestartOrInvalidClock() throws {
        let owner = UUID(), session = try BatteryCutoffSession { _ in }
        try session.arm(owner: owner, powered: true, now: 100)
        let deadline = 100 + BatteryNativeCutoffTrial.maximumDuration
        try session.enforceDischargeDeadline(now: deadline - 0.1, maximum: BatteryNativeCutoffTrial.maximumDuration)
        try session.arm(owner: owner, powered: true, now: deadline - 0.1) // A repeated arm cannot renew the deadline.
        XCTAssertThrowsError(try session.enforceDischargeDeadline(now: deadline, maximum: BatteryNativeCutoffTrial.maximumDuration))
        XCTAssertThrowsError(try session.enforceDischargeDeadline(now: 99, maximum: 10))
        XCTAssertThrowsError(try session.enforceDischargeDeadline(now: .nan, maximum: 10))
        let restart = try BatteryCutoffSession(record: session.record) { _ in }
        XCTAssertThrowsError(try restart.enforceDischargeDeadline(now: 105, maximum: 10))
    }
    func testVerifiedConnectionSupportsSustainedOwnedCutoffButDeadlineRemainsFixed() throws {
        let owner = UUID(), session = try BatteryCutoffSession { _ in }
        try session.arm(owner: owner, powered: true, now: 0)
        var telemetry = BatteryTelemetry(); telemetry.hasBattery = true; telemetry.onAC = false
        telemetry.adapterPhysicallyConnected = false; telemetry.adapterConnectionCandidate = true
        for now in [1.0, 91, 200, 400, 599] {
            try session.enforceDischargeDeadline(now: now, maximum: BatteryNativeCutoffTrial.maximumDuration)
            try session.observeDischarge(owner: owner, owned: true, powered: false,
                physicalConnection: BatteryCutoffConnection.observation(telemetry, verifiedReviewTrial: true), now: now)
            try session.arm(owner: owner, powered: false, now: now)
        }
        XCTAssertThrowsError(try session.enforceDischargeDeadline(now: 600, maximum: BatteryNativeCutoffTrial.maximumDuration))
        XCTAssertEqual(session.record?.phase, .discharging, "The caller must explicitly start recovery; no invented completion")
        try session.beginRecovery(owner: owner, releasingLease: true, now: 600)
        XCTAssertTrue(session.recovering)
    }
    func testConnectorUnknownCannotFallBackToAffectedOSFlagsAndStillTimesOutAt90Seconds() throws {
        let owner = UUID(), session = try BatteryCutoffSession { _ in }
        try session.arm(owner: owner, powered: true, now: 0)
        var telemetry = BatteryTelemetry(); telemetry.hasBattery = true; telemetry.onAC = true
        telemetry.adapterConnectionCandidate = nil
        let connection = BatteryCutoffConnection.observation(telemetry, verifiedReviewTrial: true)
        XCTAssertNil(connection)
        try session.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: connection, now: 1)
        XCTAssertThrowsError(try session.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: connection, now: 91))
        XCTAssertEqual(BatteryCutoffConnection.observation(telemetry, verifiedReviewTrial: false), true)
        telemetry.adapterConnectionCandidate = false
        XCTAssertEqual(BatteryCutoffConnection.observation(telemetry, verifiedReviewTrial: true), false)
        XCTAssertThrowsError(try session.observeDischarge(owner: owner, owned: true, powered: false, physicalConnection: false, now: 92))
        telemetry.onAC = false; telemetry.adapterConnectionCandidate = true
        XCTAssertNil(BatteryCutoffConnection.observation(telemetry, verifiedReviewTrial: false),
            "The device-specific candidate is never promoted in normal production")
    }
    func testCutoffStartRequiresSuccessfulConnectorEvidenceBeforeNativePreparation() throws {
        var telemetry = BatteryTelemetry(); telemetry.hasBattery = true; telemetry.onAC = true
        for connection: Bool? in [nil, false] {
            telemetry.adapterConnectionCandidate = connection
            XCTAssertThrowsError(try BatteryNativeCutoffTrial.validateStart(telemetry: telemetry))
        }
        telemetry.adapterConnectionCandidate = true
        try BatteryNativeCutoffTrial.validateStart(telemetry: telemetry)
    }
    func testBoundedNeutralPreparationNeverUses100AndRetainsOriginal80() throws {
        let owner = UUID(); var values = ["nativeAPILimit": 80, "nativeAPIEnabled": 1]; var writes: [Int] = []
        let lease = BatteryOverrideLease(read: { values[$0]! }, write: { values[$0] = $1; writes.append($1) }, save: { _ in })
        try lease.renew(owner: owner, now: 0)
        XCTAssertTrue(try BatteryCutoffHandoff.prepareNative(lease: lease, owner: owner,
            neutralTarget: BatteryNativeCutoffTrial.neutralLimit, registrationsMatch: { $0.entries["nativeAPILimit"]?.expected == 85 }))
        XCTAssertEqual(values["nativeAPILimit"], 85)
        XCTAssertEqual(lease.journal?.entries["nativeAPILimit"]?.original, 80)
        XCTAssertFalse(writes.contains(100))
        XCTAssertThrowsError(try BatteryCutoffHandoff.prepareNative(lease: lease, owner: owner, neutralTarget: 86,
            registrationsMatch: { _ in XCTFail("Invalid target must not reach registration"); return true }))
        try lease.release(); XCTAssertEqual(values["nativeAPILimit"], 80)
    }
}
final class BatteryRecoveryFailureClassificationTests: XCTestCase {
    func testUnreadableRecoveryIsUnknownAndDoesNotClaimExternalMutation() {
        let initial = BatteryOverrideLease.Journal(owner: UUID(), entries: ["limit": .init(original: 80, expected: 81)])
        var writes = 0
        let lease = BatteryOverrideLease(journal: initial,
            read: { _ in throw BatteryControlError.unavailable("query limit timeout") },
            write: { _, _ in writes += 1 }, save: { _ in })
        XCTAssertThrowsError(try lease.release()) { error in
            XCTAssertTrue(error.localizedDescription.contains("读取当前值失败"))
            XCTAssertTrue(error.localizedDescription.contains("query limit timeout"))
            XCTAssertFalse(error.localizedDescription.contains("外部"))
        }
        XCTAssertEqual(writes, 0); XCTAssertEqual(lease.journal, initial)
    }
    func testObservedExternalValueIsNotOverwritten() {
        let initial = BatteryOverrideLease.Journal(owner: UUID(), entries: ["limit": .init(original: 80, expected: 81)])
        var writes = 0
        let lease = BatteryOverrideLease(journal: initial, read: { _ in 85 },
            write: { _, _ in writes += 1 }, save: { _ in })
        XCTAssertThrowsError(try lease.release()) { error in
            XCTAssertTrue(error.localizedDescription.contains("已确认外部值变化"))
        }
        XCTAssertEqual(writes, 0); XCTAssertEqual(lease.journal, initial)
    }
    func testLaterSuccessfulKeyCannotDropEarlierFailedCheckpoint() throws {
        let initial = BatteryOverrideLease.Journal(owner: UUID(), entries: [
            "z": .init(original: 0, expected: 1), "a": .init(original: 0, expected: 1)])
        var saved: BatteryOverrideLease.Journal? = initial
        var values = ["z": 1, "a": 1]
        var failOnce = true
        let lease = BatteryOverrideLease(journal: initial, read: { values[$0]! },
            write: { values[$0] = $1 }, save: { next in
                if next?.entries["z"] == nil && failOnce {
                    failOnce = false; throw CocoaError(.fileWriteOutOfSpace)
                }
                saved = next
            })
        XCTAssertThrowsError(try lease.release()) { error in
            XCTAssertTrue(error.localizedDescription.contains("保存恢复结果失败"))
            XCTAssertFalse(error.localizedDescription.contains("外部"))
        }
        XCTAssertEqual(values, ["z": 0, "a": 0])
        XCTAssertNotNil(saved?.entries["z"])
        XCTAssertNil(saved?.entries["a"])
        XCTAssertEqual(lease.journal, saved)
        XCTAssertTrue(try lease.release()); XCTAssertNil(saved)
    }
    func testWorkerProgressAndFinalValueMustBothBeValid() throws {
        let progress = "{\"schema\":1,\"phase\":\"initializing\"}\n{\"schema\":1,\"phase\":\"querying\"}\n"
        let final = "{\"schema\":1,\"phase\":\"reply\",\"value\":81}"
        XCTAssertEqual(try BatteryNativeReadTransport.decode(Data((progress + final).utf8), query: .limit), 81)
        XCTAssertEqual(BatteryNativeReadProcess.lastPhase(Data(progress.utf8)), "querying")
        for text in [progress, final + "\n" + final,
                     "{\"schema\":1,\"phase\":\"unexpected\"}\n" + final] {
            XCTAssertThrowsError(try BatteryNativeReadTransport.decode(Data(text.utf8), query: .limit))
        }
    }
    func testTimeoutReportsPhaseAndProcessBoundaryWithoutChangingDeadline() {
        let program = "import sys,time;print('{\"schema\":1,\"phase\":\"querying\"}',flush=True);time.sleep(10)"
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", program], timeout: 0.4)) { error in
            for field in ["超时", "phase=querying", "pid=", "launch=", "processFinished=", "pipeFinished="] {
                XCTAssertTrue(error.localizedDescription.contains(field), field)
            }
        }
    }
    func testLEDOffUsesPackagedOffMappingAndPreservesSystemRelease() {
        XCTAssertEqual(BatteryLED.off.controlValue(reachedLimit: false), 1)
        XCTAssertEqual(BatteryLED.off.controlValue(reachedLimit: true), 1)
        XCTAssertNil(BatteryLED.system.controlValue(reachedLimit: true))
    }
}
