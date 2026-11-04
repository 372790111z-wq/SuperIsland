import XCTest
@testable import SuperIsland

final class BatteryPreferencesLeaseTests: XCTestCase {
    typealias T = BatteryPreferencesLease
    typealias K = T.Key
    typealias V = T.Value
    final class Fixture {
        var values: T.Snapshot = Dictionary(uniqueKeysWithValues: K.allCases.map { ($0, V.absent) })
        var disk: BatteryOverrideLease.Journal?
        var writes = 0
        var signals = 0
        var failSave = false
        var failWrite = false
        var failSignal = false
        var registered: Set<Int>? = [80]
        var now: Double = 1
        let owner = UUID()
        init() {
            values[.mclLimitValue] = .integer(80)
            values[.mclFeatureState] = .real(1)
            values[.initialChargeLimitSetDate] = .real(1234)
        }
        func lease() -> BatteryOverrideLease {
            let lease = BatteryOverrideLease(journal: disk, read: { _ in 0 }, write: { _, _ in XCTFail("Unexpected register write") }, save: { next in
                if self.failSave { throw BatteryControlError.recovery("save") }
                self.disk = next
            })
            lease.preferencesIO = .init(snapshot: { self.values }, write: { key, desired, expected, guards, restoring in
                XCTAssertNotNil(self.disk?.preferences)
                XCTAssertEqual(self.disk?.preferences?.expected[key], desired)
                XCTAssertEqual(self.disk?.preferences?.prior[key], expected)
                XCTAssertEqual(self.values[key], expected)
                XCTAssertTrue(guards.allSatisfy({ self.values[$0.key] == $0.value }))
                self.writes += 1
                self.values[key] = desired
                if self.failWrite { throw BatteryControlError.recovery("write reply lost") }
            }, signal: { _, _, _ in
                self.signals += 1
                XCTAssertTrue([T.Phase.signalIntent, .restoreSignalIntent].contains(self.disk!.preferences!.phase))
                if self.failSignal { throw BatteryControlError.recovery("signal") }
            })
            lease.confirmPreferences = { try T.restored($0, snapshot: self.values, registrations: self.registered) }
            return lease
        }
        func active(_ target: Int = 79) throws -> BatteryOverrideLease {
            let lease = lease()
            try lease.renew(owner: owner, now: now)
            try lease.applyPreferences(target: target, owner: owner, now: { self.now })
            return lease
        }
    }
    func testTargetChangesKeepFirstTypedBaseline() throws {
        let f = Fixture(), original = f.values, lease = try f.active()
        try lease.applyPreferences(target: 70, owner: f.owner, now: { f.now })
        try lease.applyPreferences(target: 81, owner: f.owner, now: { f.now })
        XCTAssertEqual(lease.journal?.schemaVersion, 4)
        XCTAssertEqual(lease.journal?.preferences?.original[.mclFeatureState], .real(1))
        XCTAssertEqual(lease.journal?.preferences?.original[.isEngaged], .absent)
        XCTAssertTrue(try lease.release(owner: f.owner))
        for key in K.direct { XCTAssertEqual(f.values[key], original[key]) }
        XCTAssertNil(f.disk)
    }
    func testRepeatedTargetDoesNotRewriteOrSignal() throws {
        let f = Fixture(), lease = try f.active(), writes = f.writes, signals = f.signals
        try lease.applyPreferences(target: 79, owner: f.owner, now: { f.now })
        XCTAssertEqual(f.writes, writes); XCTAssertEqual(f.signals, signals)
    }
    func testSaveFailurePreventsMutation() throws {
        let f = Fixture(), lease = f.lease()
        try lease.renew(owner: f.owner, now: 1); f.failSave = true
        XCTAssertThrowsError(try lease.applyPreferences(target: 79, owner: f.owner, now: { 1 }))
        XCTAssertEqual(f.writes, 0); XCTAssertEqual(f.signals, 0)
    }
    func testLostWriteReplyRetainsIntentAndCanRestore() throws {
        let f = Fixture(), lease = f.lease()
        try lease.renew(owner: f.owner, now: 1); f.failWrite = true
        XCTAssertThrowsError(try lease.applyPreferences(target: 79, owner: f.owner, now: { 1 }))
        XCTAssertFalse(try XCTUnwrap(lease.journal?.preferences?.prior).isEmpty)
        XCTAssertThrowsError(try lease.applyPreferences(target: 81, owner: f.owner, now: { 1 }))
        f.failWrite = false
        XCTAssertTrue(try lease.release(owner: f.owner))
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
    }
    func testLostSignalIsRestoreOnlyEvenAfterRenewal() throws {
        let f = Fixture(), lease = f.lease(); f.failSignal = true
        try lease.renew(owner: f.owner, now: 1)
        XCTAssertThrowsError(try lease.applyPreferences(target: 79, owner: f.owner, now: { 1 }))
        try lease.renew(owner: f.owner, now: 2)
        XCTAssertThrowsError(try lease.applyPreferences(target: 79, owner: f.owner, now: { 2 }))
        f.failSignal = false
        XCTAssertTrue(try lease.release(owner: f.owner))
    }
    func testLeaseExpiryPreventsNewTarget() throws {
        let f = Fixture(), lease = try f.active(), count = f.writes
        f.now = 47
        XCTAssertThrowsError(try lease.applyPreferences(target: 70, owner: f.owner, now: { f.now }))
        XCTAssertEqual(f.writes, count)
        XCTAssertTrue(try lease.release(owner: f.owner))
    }
    func testForeignOwnerCannotChangeOrRelease() throws {
        let f = Fixture(), lease = try f.active(), count = f.writes
        XCTAssertThrowsError(try lease.applyPreferences(target: 70, owner: UUID(), now: { 1 }))
        XCTAssertThrowsError(try lease.release(owner: UUID()))
        XCTAssertEqual(f.writes, count); XCTAssertNotNil(f.disk)
    }
    func testMissingAndDisabledOriginalsRestoreExactly() throws {
        let f = Fixture()
        f.values[.mclLimitValue] = .absent; f.values[.mclFeatureState] = .bool(false)
        f.registered = []
        let lease = try f.active(20)
        XCTAssertTrue(try lease.release(owner: f.owner))
        XCTAssertEqual(f.values[.mclLimitValue], .absent)
        XCTAssertEqual(f.values[.mclFeatureState], .bool(false))
    }
    func testUnknownRegistrationDoesNotClearResponsibility() throws {
        let f = Fixture(), lease = try f.active()
        f.registered = nil
        XCTAssertFalse(try lease.release(owner: f.owner)); XCTAssertNotNil(f.disk)
        let count = f.writes
        f.registered = [80]
        XCTAssertTrue(try lease.release(owner: f.owner)); XCTAssertEqual(f.writes, count)
    }
    func testActiveApplicationPolicyReassertsAfterSystemSliderWithoutReplacingBaseline() throws {
        let f = Fixture(), lease = try f.active(80)
        f.values[.mclLimitValue] = .integer(85)
        try lease.applyPreferences(target: 80, owner: f.owner, now: { 1 })
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80))
        XCTAssertEqual(lease.journal?.preferences?.original[.mclLimitValue], .integer(80))
        f.values[.mclLimitValue] = .integer(85)
        XCTAssertThrowsError(try lease.release(owner: f.owner))
        XCTAssertEqual(f.values[.mclLimitValue], .integer(85)); XCTAssertNotNil(f.disk)
    }
    func testSystemOverrideBlocksMutationAndRetainsRestore() throws {
        let f = Fixture(), lease = try f.active(), count = f.writes
        f.values[.mclOverridenUntilDate] = .real(2000)
        XCTAssertThrowsError(try lease.applyPreferences(target: 70, owner: f.owner, now: { 1 }))
        XCTAssertThrowsError(try lease.release(owner: f.owner))
        XCTAssertEqual(f.writes, count); XCTAssertNotNil(f.disk)
    }
    func testDerivedSystemTimelineIsNotRewound() throws {
        let f = Fixture(), lease = try f.active()
        f.values[.checkpoint] = .dictionary(["new": .date(Date(timeIntervalSince1970: 1))])
        let newer = f.values[.checkpoint]
        XCTAssertTrue(try lease.release(owner: f.owner))
        XCTAssertEqual(f.values[.checkpoint], newer)
    }
    func testRestartRestoresOriginalBaselineInsteadOfTarget() throws {
        let f = Fixture(); _ = try f.active(20)
        let restarted = f.lease()
        XCTAssertTrue(try restarted.release())
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80)); XCTAssertNil(f.disk)
    }
    func testMissingInitialDateFailsBeforeWrites() throws {
        let f = Fixture(); f.values[.initialChargeLimitSetDate] = .absent
        XCTAssertThrowsError(try f.active()); XCTAssertEqual(f.writes, 0)
    }
    func testLegacyIntegerSchemaDecodesWithoutTypedRecord() throws {
        let data = Data(#"{"owner":"00000000-0000-0000-0000-000000000001","entries":{},"schemaVersion":3}"#.utf8)
        let journal = try JSONDecoder().decode(BatteryOverrideLease.Journal.self, from: data)
        XCTAssertNil(journal.preferences); XCTAssertEqual(journal.schemaVersion, 3)
    }
    func testDetachedHoldSkipsOrdinaryExpiryButRestorationClearsDetachBeforeWaiting() throws {
        let f = Fixture(), lease = try f.active()
        XCTAssertThrowsError(try lease.detachExitHold(owner: f.owner, confirmed: false))
        try lease.detachExitHold(owner: f.owner, confirmed: true)
        try lease.expire(now: 999)
        XCTAssertEqual(lease.journal?.detachedExitHold, true)
        XCTAssertThrowsError(try lease.applyPreferences(target: 70, owner: f.owner, now: { 1 }))
        f.registered = nil
        XCTAssertFalse(try lease.release(owner: f.owner))
        XCTAssertNotEqual(lease.journal?.detachedExitHold, true)
        XCTAssertEqual(lease.journal?.preferences?.phase, .awaitingConfirmation)
        f.registered = [80]
        XCTAssertTrue(try lease.release(owner: f.owner)); XCTAssertNil(f.disk)
    }
    func testDetachedHoldRestartRestoresInsteadOfRecreatingHold() throws {
        let f = Fixture(), lease = try f.active()
        try lease.detachExitHold(owner: f.owner, confirmed: true)
        let restarted = f.lease()
        XCTAssertTrue(try restarted.release())
        XCTAssertEqual(f.values[.mclLimitValue], .integer(80)); XCTAssertNil(f.disk)
    }
    func testPreferencesCapabilitiesSeparateThermalFromSleep() throws {
        let capabilities = BatteryControlCapabilities(backend: .nativePreferences, dischargeSupported: true,
            minimumDischargeTarget: 20, led: false, highPower: false, calibration: true, reviewTrial: false)
        XCTAssertEqual(capabilities.minimumLimit, 20); XCTAssertTrue(capabilities.thermalPause)
        XCTAssertFalse(capabilities.immediatePause); XCTAssertTrue(capabilities.calibration)
        var request = BatteryControlRequest(owner: UUID(), preferences: .init())
        request.mode = .discharge; request.dischargeTarget = 10
        XCTAssertThrowsError(try capabilities.validate(request, currentLevel: 80))
    }
}
