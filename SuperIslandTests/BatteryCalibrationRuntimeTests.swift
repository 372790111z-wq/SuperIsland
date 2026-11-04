import XCTest
@testable import SuperIsland

final class BatteryCalibrationRuntimeTests: XCTestCase {
    private final class Rig {
        let owner = UUID(), id = UUID()
        var preferences = BatteryControlPreferences()
        var values = ["limit": 80, "cut": 0]
        var events: [String] = []
        var saved: BatteryCalibrationRuntime.Record?
        var failSave = false, failWrite = false, settled = true
        lazy var lease = BatteryOverrideLease(read: { self.values[$0]! }, write: {
            if self.failWrite { throw BatteryControlError.recovery("write failed") }
            self.events.append("write:\($0)=\($1)"); self.values[$0] = $1
        }, save: { _ in self.events.append("lease checkpoint") })
        lazy var runtime: BatteryCalibrationRuntime = try! BatteryCalibrationRuntime { record in
            if self.failSave { throw BatteryControlError.recovery("checkpoint failed") }
            self.events.append("phase:\(record.status.phase.rawValue)"); self.saved = record
        }
        func start() throws {
            try lease.renew(owner: owner, now: 0)
            try runtime.accept(.start(id), owner: owner, preferences: preferences, supported: true, date: date(0))
        }
        func date(_ t: Double) -> Date { Date(timeIntervalSince1970: 2_000_000_000 + t) }
        func tick(_ time: Double, _ level: Int = 99, charging: Bool = false,
                  system: Bool = false, sleeping: Bool = false, ac: Bool = true, ownedCutoff: Bool = false) throws {
            var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = level
            sample.onAC = ac; sample.charging = charging; sample.voltage = 12; sample.current = charging ? 1 : 0
            sample.temperature = 30
            try runtime.tick(telemetry: sample, sleeping: sleeping, systemCalibration: system, now: time, date: date(time), ownsAdapterCutoff: ownedCutoff) { action, saved in
                let targets: [String: Int]
                switch action {
                case .drive(let decision):
                    self.events.append("drive:\(decision.target)")
                    targets = ["limit": decision.nativeTarget(currentLevel: level), "cut": decision.forceDischarge ? 8 : 0]
                case .restorePreferences: self.events.append("restore"); targets = ["limit": saved.limit, "cut": 0]
                case .yieldToSystem: self.events.append("yield"); targets = ["limit": self.values["limit"]!, "cut": 0]
                }
                try self.lease.apply(targets, owner: self.owner)
                return self.settled
            }
        }
        func throughHold() throws {
            try start(); try tick(0); try tick(2, 100); try tick(4, 10); try tick(6, 98)
            XCTAssertEqual(runtime.record?.status.phase, .hold)
        }
    }
    func testCompleteCycleDrivesFixedTenAndRestoresOnlyBeforeSuccess() throws {
        let r = Rig(); try r.throughHold()
        for t in [8.0, 10, 12] { try r.tick(t) }
        XCTAssertEqual(r.runtime.record?.status.phase, .returnToLimit)
        XCTAssertEqual(r.values, ["limit": 100, "cut": 8])
        r.settled = false; try r.tick(14, 80)
        XCTAssertEqual(r.runtime.record?.status.state, .restoring)
        XCTAssertNil(r.runtime.record?.status.lastCompletedAt)
        r.settled = true; try r.tick(16, 80)
        XCTAssertEqual(r.runtime.record?.status.state, .completed)
        XCTAssertEqual(r.runtime.record?.status.lastCompletedAt, r.date(16))
        XCTAssertEqual(r.values, ["limit": 80, "cut": 0])
        XCTAssertTrue(r.events.contains("drive:10"))
        let phase = try XCTUnwrap(r.events.firstIndex(of: "phase:discharge"))
        let write = try XCTUnwrap(r.events.firstIndex(of: "write:cut=8"))
        XCTAssertLessThan(phase, write, "Persist the new stage before its hardware command")
    }
    func testUnsettledHardwareCannotAdvanceEvenWhenBatteryShowsFull() throws {
        let r = Rig(); try r.start(); r.settled = false
        try r.tick(0, 100); try r.tick(2, 100)
        XCTAssertEqual(r.runtime.record?.status.phase, .firstCharge)
        XCTAssertEqual(r.values["cut"], 0)
        r.settled = true; try r.tick(4, 100); try r.tick(6, 100)
        XCTAssertEqual(r.runtime.record?.status.phase, .discharge)
    }
    func testUnsettledDischargeIsReleasedAtTenEvenWithoutTargetAcknowledgement() throws {
        let r = Rig(); try r.start(); try r.tick(0)
        r.settled = false; try r.tick(2, 100)
        XCTAssertEqual(r.values["cut"], 8)
        try r.tick(4, 10)
        XCTAssertEqual(r.values["cut"], 0)
        XCTAssertEqual(r.saved?.status.state, .restoring)
        XCTAssertEqual(r.saved?.status.endReason, .protection)
        XCTAssertNil(r.saved?.status.lastCompletedAt)
        r.settled = true; try r.tick(6, 10)
        XCTAssertEqual(r.saved?.status.state, .interrupted)
    }
    func testFastReadAtDischargeFloorCannotReapplyCutoff() throws {
        let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
        try r.tick(3, 10) // Too soon to earn an ordinary phase sample.
        XCTAssertEqual(r.values["cut"], 0)
        XCTAssertEqual(r.saved?.status.state, .interrupted)
        XCTAssertNil(r.saved?.status.lastCompletedAt)
    }
    func testIdempotentStartDoesNotRestartActiveOrCompletedCycle() throws {
        let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
        try r.runtime.accept(.start(r.id), owner: r.owner, preferences: r.preferences, supported: true, date: r.date(100))
        XCTAssertEqual(r.runtime.record?.status.phase, .discharge)
        try r.runtime.accept(.cancel(r.id), owner: r.owner, preferences: r.preferences, supported: true, date: r.date(101))
        try r.tick(102)
        try r.runtime.accept(.start(r.id), owner: r.owner, preferences: r.preferences, supported: true, date: r.date(103))
        XCTAssertFalse(r.runtime.isActive)
        try r.runtime.accept(.start(UUID()), owner: r.owner, preferences: r.preferences, supported: true, date: r.date(104))
        XCTAssertThrowsError(try r.runtime.accept(.start(r.id), owner: r.owner, preferences: r.preferences, supported: true, date: r.date(105)))
    }
    func testOwnershipPreferenceAndModeConflictsDoNotAlterSession() throws {
        let r = Rig(); try r.start(); let before = r.runtime.record
        for command: BatteryCalibrationCommand? in [nil, .start(UUID()), .cancel(UUID())] {
            XCTAssertThrowsError(try r.runtime.accept(command, owner: r.owner, preferences: r.preferences, supported: true, date: r.date(1)))
        }
        XCTAssertThrowsError(try r.runtime.accept(.cancel(r.id), owner: UUID(), preferences: r.preferences, supported: true, date: r.date(2)))
        var changed = r.preferences; changed.limit = 85
        XCTAssertThrowsError(try r.runtime.accept(.start(r.id), owner: r.owner, preferences: changed, supported: true, date: r.date(2)))
        XCTAssertEqual(r.runtime.record, before)
        var request = BatteryControlRequest(owner: r.owner, preferences: r.preferences, mode: .discharge, dischargeTarget: 10)
        XCTAssertThrowsError(try request.validate())
        request.dischargeTarget = 70; request.calibration = .start(r.id)
        XCTAssertThrowsError(try request.validate())
    }
    func testMissingCapabilityOrFailedCheckpointNeverDrivesHardware() throws {
        let r = Rig()
        XCTAssertThrowsError(try r.runtime.accept(.start(r.id), owner: r.owner, preferences: r.preferences, supported: false, date: r.date(0)))
        XCTAssertNil(r.runtime.record)
        r.failSave = true; XCTAssertThrowsError(try r.start())
        XCTAssertNil(r.runtime.record); XCTAssertEqual(r.values, ["limit": 80, "cut": 0])
    }
    func testRestartRestoresLeaseAndMarksInterruptedWithoutDeepResume() throws {
        let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
        let journal = r.lease.journal, record = try XCTUnwrap(r.saved)
        XCTAssertEqual(r.values["cut"], 8)
        let recovered = BatteryOverrideLease(journal: journal, read: { r.values[$0]! }, write: { r.values[$0] = $1 }, save: { _ in })
        let runtime = try BatteryCalibrationRuntime(record: record) { r.saved = $0 }
        try recovered.release(); try runtime.recoveredAfterRestart()
        XCTAssertEqual(r.values, ["limit": 80, "cut": 0])
        XCTAssertEqual(runtime.record?.status.state, .interrupted)
        XCTAssertNil(runtime.record?.status.lastCompletedAt)
    }
    func testFailedWriteKeepsDurableIntentAndLeaseCanRecover() throws {
        let r = Rig(); try r.start(); try r.tick(0)
        r.failWrite = true; XCTAssertThrowsError(try r.tick(2, 100))
        XCTAssertEqual(r.saved?.status.phase, .discharge)
        XCTAssertNotNil(r.lease.journal)
        r.failWrite = false; try r.lease.release(); try r.runtime.released()
        XCTAssertEqual(r.values, ["limit": 80, "cut": 0])
        XCTAssertEqual(r.saved?.status.state, .interrupted); XCTAssertNil(r.saved?.status.lastCompletedAt)
    }
    func testFinalCheckpointFailureDoesNotRecordSuccessAndCanRetry() throws {
        let r = Rig(); try r.throughHold()
        for t in [8.0, 10, 12] { try r.tick(t) }
        r.settled = false; try r.tick(14, 80)
        r.failSave = true; r.settled = true
        XCTAssertThrowsError(try r.tick(16, 80))
        XCTAssertEqual(r.saved?.status.state, .restoring); XCTAssertNil(r.saved?.status.lastCompletedAt)
        r.failSave = false; try r.tick(18, 80)
        XCTAssertEqual(r.saved?.status.state, .completed)
    }
    func testOwnedCutoffPreservesCalibrationDischargeAndStillStopsAtTen() throws {
        let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
        try r.tick(4, 82, ac: false, ownedCutoff: true)
        XCTAssertEqual(r.runtime.record?.status.phase, .discharge)
        XCTAssertEqual(r.values["cut"], 8)
        try r.tick(6, 10, ac: false, ownedCutoff: true)
        XCTAssertEqual(r.runtime.record?.status.phase, .secondCharge)
        XCTAssertEqual(r.values["cut"], 0)
        XCTAssertNil(r.runtime.record?.status.lastCompletedAt)
    }
    func testUnplugSleepAndExplicitCancelAllRestoreWithoutSuccess() throws {
        for reason in 0...2 {
            let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
            if reason == 0 { try r.runtime.accept(.cancel(r.id), owner: r.owner, preferences: r.preferences, supported: true, date: r.date(3)) }
            try r.tick(4, sleeping: reason == 2, ac: reason != 1)
            XCTAssertEqual(r.values["cut"], 0)
            XCTAssertEqual(r.saved?.status.state, .interrupted); XCTAssertNil(r.saved?.status.lastCompletedAt)
        }
    }
    func testSystemOverrideReleasesDischargeAndNeverAdvancesUntilControlResettles() throws {
        let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
        try r.tick(4, 12, system: true)
        XCTAssertEqual(r.values["cut"], 0)
        XCTAssertEqual(r.saved?.status.phase, .discharge)
        XCTAssertTrue(r.saved?.status.waitingForSystem == true)
        try r.tick(6, 12)
        XCTAssertEqual(r.saved?.status.phase, .discharge)
        try r.tick(8, 10)
        XCTAssertEqual(r.saved?.status.phase, .secondCharge)
    }
    func testOverrideEndingAtTenCannotRearmDischargeWhileControlIsUnsettled() throws {
        let r = Rig(); try r.start(); try r.tick(0); try r.tick(2, 100)
        try r.tick(4, 10, system: true)
        XCTAssertEqual(r.values["cut"], 0)
        try r.tick(6, 10)
        XCTAssertEqual(r.values["cut"], 0)
        XCTAssertEqual(r.saved?.status.state, .interrupted)
        XCTAssertEqual(r.saved?.status.endReason, .protection)
        XCTAssertNil(r.saved?.status.lastCompletedAt)
    }
    func testUnknownSchemaAndInconsistentResultsCannotLoad() throws {
        let r = Rig(); try r.start()
        var invalid = try XCTUnwrap(r.saved); invalid.schemaVersion = 2
        XCTAssertThrowsError(try BatteryCalibrationRuntime(record: invalid) { _ in })
        invalid.schemaVersion = 1; invalid.status.state = .completed
        XCTAssertThrowsError(try BatteryCalibrationRuntime(record: invalid) { _ in })
    }
    func testSMCStopReadbackCannotStandInForPhysicalStop() throws {
        var v = BatteryControlVerification(timeout: 10)
        XCTAssertFalse(try v.confirmPhysicalStop(target: 80, required: true, charging: true, now: 0))
        XCTAssertFalse(try v.confirmPhysicalStop(target: 80, required: true, charging: true, now: 9))
        XCTAssertThrowsError(try v.confirmPhysicalStop(target: 80, required: true, charging: true, now: 10))
        XCTAssertTrue(try v.confirmPhysicalStop(target: 80, required: true, charging: false, now: 11))
        XCTAssertTrue(try v.confirmPhysicalStop(target: 100, required: false, charging: true, now: 12))
    }
    func testSelectedAwakePolicyCoversCalibrationDischargeAndReleasesAfterCompletion() {
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 99
        sample.onAC = false; sample.adapterPhysicallyConnected = true
        var p = BatteryControlPreferences(); p.sleep = .untilLimit
        XCTAssertTrue(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: .automatic, calibrationActive: true))
        XCTAssertFalse(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: .automatic, calibrationActive: false))
        XCTAssertFalse(BatteryAwakePolicy.needed(enabled: false, telemetry: sample, preferences: p, mode: .automatic, calibrationActive: true))
        p.sleep = .unchanged
        XCTAssertFalse(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: .automatic, calibrationActive: true))
    }
    func testOrdinaryAwakeChargingAndTemporaryModesKeepTheirExistingBounds() {
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 79; sample.onAC = true
        var p = BatteryControlPreferences(); p.sleep = .untilLimit
        XCTAssertTrue(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: .automatic, calibrationActive: false))
        for mode: BatteryControlMode in [.discharge, .paused] {
            XCTAssertFalse(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: mode, calibrationActive: false))
        }
        sample.level = 80
        XCTAssertFalse(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: .automatic, calibrationActive: false))
        XCTAssertTrue(BatteryAwakePolicy.needed(enabled: true, telemetry: sample, preferences: p, mode: .topUp, calibrationActive: false))
    }
}
