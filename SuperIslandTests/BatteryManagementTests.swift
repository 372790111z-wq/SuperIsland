import XCTest
import ServiceManagement
import SwiftUI
import AppKit
import CoreFoundation
import os
@testable import SuperIsland

final class BatteryManagementPolicyTests: XCTestCase {
    func testOwnedCutoffDoesNotCompleteBeforeMeasuredTargetDespiteBothACFlagsFalse() throws {
        var policy = BatteryControlPolicy(), r = request(.discharge)
        r.dischargeTarget = 80
        let off = sample(82, ac: false)
        let draining = try policy.decide(request: r, snapshot: off, ownsAdapterCutoff: true)
        XCTAssertFalse(draining.completed); XCTAssertTrue(draining.forceDischarge)
        let unplugged = try policy.decide(request: r, snapshot: off)
        XCTAssertEqual(unplugged.completionReason, .powerDisconnected)
        XCTAssertTrue(unplugged.completed,
            "An unowned loss of adapter power must keep the ordinary unplug behavior")
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(80, ac: false), ownsAdapterCutoff: true).completed)
        var missing = off; missing.level = nil
        XCTAssertThrowsError(try policy.decide(request: r, snapshot: missing, ownsAdapterCutoff: true))
        missing.level = -1
        XCTAssertThrowsError(try policy.decide(request: r, snapshot: missing, ownsAdapterCutoff: true))
    }
    func testNativeDischargeKeepsLogicalLowGoalSeparateFromChargeAPIFloor() throws {
        var policy = BatteryControlPolicy()
        var r = request(.discharge); r.preferences.limit = 85; r.dischargeTarget = 70
        let draining = try policy.decide(request: r, snapshot: sample(80))
        XCTAssertTrue(draining.forceDischarge)
        XCTAssertEqual(draining.target, 70)
        XCTAssertEqual(draining.nativeTarget(currentLevel: 80), 100)
        var disconnected = sample(75, ac: false); disconnected.adapterPhysicallyConnected = true
        XCTAssertFalse(try policy.decide(request: r, snapshot: disconnected).completed)
        let reached = try policy.decide(request: r, snapshot: sample(70))
        XCTAssertTrue(reached.completed); XCTAssertEqual(reached.target, 85)
        XCTAssertFalse(reached.forceDischarge)
        XCTAssertEqual(reached.nativeTarget(currentLevel: 70), 85)
        var paused = BatteryControlPolicy()
        let pause = try paused.decide(request: request(.paused), snapshot: sample(70))
        XCTAssertEqual(pause.nativeTarget(currentLevel: 70), 70, "A pause must not be turned into adapter-cutoff discharge")
    }
    func testHardwareReadbackWaitsForASettlingValueWithoutWritingAgain() throws {
        var clock = 0.0, reads = 0
        XCTAssertTrue(try BatteryHardwareReadback.matches(expected: [2], timeout: 1, read: {
            reads += 1
            return clock >= 0.15 ? [2] : [4]
        }, now: { clock }, wait: { clock += $0 }))
        XCTAssertGreaterThan(reads, 1)
        XCTAssertLessThanOrEqual(clock, 1)
    }
    func testHardwareReadbackTimeoutAndOtherRegistersRemainBounded() throws {
        var clock = 0.0
        XCTAssertFalse(try BatteryHardwareReadback.matches(expected: [2], timeout: 1,
            read: { [4] }, now: { clock }, wait: { clock += $0 }))
        XCTAssertEqual(clock, 1, accuracy: 0.000001)
        var waited = false
        XCTAssertFalse(try BatteryHardwareReadback.matches(expected: [1], timeout: 0,
            read: { [0] }, wait: { _ in waited = true }))
        XCTAssertFalse(waited)
    }
    func testHardwareReadbackDoesNotHideReadErrorsOrAcceptAnUnboundedWindow() {
        var waited = false
        XCTAssertThrowsError(try BatteryHardwareReadback.matches(expected: [2], timeout: 1,
            read: { throw BatteryControlError.unavailable("sensor unavailable") }, wait: { _ in waited = true }))
        XCTAssertFalse(waited)
        var read = false
        XCTAssertFalse(try BatteryHardwareReadback.matches(expected: [2], timeout: .infinity,
            read: { read = true; return [2] }))
        XCTAssertFalse(read)
    }
    func testLEDControlUsesBinaryConfirmedGreenAndKeepsSystemUnowned() {
        // Hardware regression:3 was accepted as a write but read back as4.
        // The installed reference app's enum Green=1 invokes SMC value2.
        XCTAssertEqual(BatteryLED.green.controlValue(reachedLimit: false), 2)
        XCTAssertEqual(BatteryLED.atLimit.controlValue(reachedLimit: true), 2)
        XCTAssertEqual(BatteryLED.atLimit.controlValue(reachedLimit: false), 4)
        XCTAssertEqual(BatteryLED.orange.controlValue(reachedLimit: true), 4)
        XCTAssertNil(BatteryLED.system.controlValue(reachedLimit: true))
    }
    func testRegistrationReadbackRejectsConflictsAndMalformedOutput() {
        XCTAssertEqual(BatteryNativeRegistration.parse("No battery level limits set"), [])
        XCTAssertNil(BatteryNativeRegistration.parse("command failed"))
        XCTAssertNil(BatteryNativeRegistration.parse("Battery level limits: ({ chargeSocLimitSoc = 80; })"))
        XCTAssertNil(BatteryNativeRegistration.parse("Battery level limits: ({ Terminated = 0; chargeSocLimitSoc = 999; })"))
        XCTAssertEqual(BatteryNativeRegistration.parse("Battery level limits: ({ Terminated = 0; chargeSocLimitSoc = 80; }, { Terminated = 0; chargeSocLimitSoc = 85; })"), [80, 85])
        XCTAssertEqual(BatteryNativeRegistration.parse("Battery level limits: ({ Terminated = 0; chargeSocLimitSoc = 80; }, { Terminated = 0; chargeSocLimitSoc = 80; }, { Terminated = 1; chargeSocLimitSoc = 85; })"), [80])
    }
    func testRegistrationAndActualStopHaveIndependentDeadlines() throws {
        var check = BatteryControlVerification(timeout: 10)
        XCTAssertEqual(try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [80], savedManualLimit: 80, systemOverride: false, now: 0), .waitingForStop)
        // A repeated matching acknowledgement cannot reset the physical deadline.
        _ = try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [80], savedManualLimit: 80, systemOverride: false, now: 9)
        XCTAssertThrowsError(try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [80], savedManualLimit: 80, systemOverride: false, now: 10))
    }
    func testRegistrationLagCannotHideContinuingChargeOrSavedManualLimitDisagreement() throws {
        var check = BatteryControlVerification(timeout: 10)
        _ = try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [], savedManualLimit: 85, systemOverride: false, now: 0)
        _ = try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [80], savedManualLimit: 80, systemOverride: false, now: 9)
        XCTAssertThrowsError(try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [80], savedManualLimit: 80, systemOverride: false, now: 10))
        var inconsistent = BatteryControlVerification(timeout: 10)
        XCTAssertEqual(try inconsistent.observe(target: 85, mustStop: false, charging: true, onAC: true, registrations: [85], savedManualLimit: 80, systemOverride: false, now: 0), .waitingForRegistration)
        XCTAssertThrowsError(try inconsistent.observe(target: 85, mustStop: false, charging: true, onAC: true, registrations: [85], savedManualLimit: 80, systemOverride: false, now: 10))
    }
    func testVerifiedHoldDoesNotClaimThatAnUnstartedChargeIsCharging() throws {
        var check = BatteryControlVerification()
        XCTAssertEqual(try check.observe(target: 80, mustStop: true, charging: false, onAC: true, registrations: [80], savedManualLimit: 80, systemOverride: false, now: 0), .holding)
        XCTAssertEqual(try check.observe(target: 85, mustStop: false, charging: false, onAC: true, registrations: [85], savedManualLimit: 85, systemOverride: false, now: 1), .waitingForCharge)
    }
    func testNonEightyManualLimitDoesNotTimeoutAfterConfirmedRegistrationAndStop() throws {
        // Device regression: optimization threshold100 must not stand in for
        // the separate manual getter81. This API intentionally takes only MCL.
        var check = BatteryControlVerification(timeout: 90)
        XCTAssertEqual(try check.observe(target: 81, mustStop: true, charging: false, onAC: true,
            registrations: [81], savedManualLimit: 81, systemOverride: false, now: 0), .holding)
        XCTAssertEqual(try check.observe(target: 81, mustStop: true, charging: false, onAC: true,
            registrations: [81], savedManualLimit: 81, systemOverride: false, now: 180), .holding)
        // A matching manual preference and registration never prove a stop.
        XCTAssertEqual(try check.observe(target: 81, mustStop: true, charging: true, onAC: true,
            registrations: [81], savedManualLimit: 81, systemOverride: false, now: 181), .waitingForStop)
        XCTAssertThrowsError(try check.observe(target: 81, mustStop: true, charging: true, onAC: true,
            registrations: [81], savedManualLimit: 81, systemOverride: false, now: 271))
    }
    func testMatchingRegistrationCannotSubstituteForUnreadableManualLimit() throws {
        var check = BatteryControlVerification(timeout: 90)
        XCTAssertEqual(try check.observe(target: 81, mustStop: true, charging: false, onAC: true,
            registrations: [81], savedManualLimit: nil, systemOverride: false, now: 0), .waitingForRegistration)
        XCTAssertThrowsError(try check.observe(target: 81, mustStop: true, charging: false, onAC: true,
            registrations: [81], savedManualLimit: nil, systemOverride: false, now: 90))
    }
    func testSystemOverrideAndUnplugResetObservationWindows() throws {
        var check = BatteryControlVerification(timeout: 10)
        _ = try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [], savedManualLimit: 100, systemOverride: false, now: 0)
        XCTAssertEqual(try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [], savedManualLimit: 100, systemOverride: true, now: 100), .systemOverride)
        XCTAssertNoThrow(try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [], savedManualLimit: 100, systemOverride: false, now: 101))
        XCTAssertEqual(try check.observe(target: 80, mustStop: true, charging: false, onAC: false, registrations: [], savedManualLimit: nil, systemOverride: false, now: 200), .unplugged)
        XCTAssertNoThrow(try check.observe(target: 80, mustStop: true, charging: true, onAC: true, registrations: [], savedManualLimit: 100, systemOverride: false, now: 201))
    }
    func testIndependentAdapterSignalRetainsValidityAndDisconnectSentinel() {
        XCTAssertEqual(BatteryPhysicalAdapterSignal.decode(.init(type: "si8 ", bytes: [4])), true)
        XCTAssertEqual(BatteryPhysicalAdapterSignal.decode(.init(type: "si8 ", bytes: [0xff])), false)
        XCTAssertNil(BatteryPhysicalAdapterSignal.decode(nil))
        XCTAssertNil(BatteryPhysicalAdapterSignal.decode(.init(type: "ui8 ", bytes: [0])))
        XCTAssertNil(BatteryPhysicalAdapterSignal.decode(.init(type: "si8 ", bytes: [])))
        XCTAssertNil(BatteryPhysicalAdapterSignal.decode(.init(type: "si8 ", bytes: [0, 0])))
    }
    func testConnectionCandidateDoesNotAuthorizeControlDuringCutoff() {
        let fields: [String: Any] = ["BatteryInstalled": true, "CurrentCapacity": 82, "MaxCapacity": 100,
            "ExternalConnected": false, "AppleRawExternalConnected": false]
        let snapshot = BatteryTelemetry.decode(fields, physicalAdapter: .init(type: "si8 ", bytes: [4]))
        XCTAssertEqual(snapshot.adapterConnectionCandidate, true)
        XCTAssertFalse(snapshot.onAC)
        XCTAssertFalse(snapshot.adapterPresent) // Independence under cutoff remains unverified.
    }
    func testConnectionCandidateCannotOverrideActualPowerFlags() {
        let snapshot = BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 82, "MaxCapacity": 100,
            "ExternalConnected": true, "AppleRawExternalConnected": true], physicalAdapter: .init(type: "si8 ", bytes: [0xff]))
        XCTAssertEqual(snapshot.adapterConnectionCandidate, false)
        XCTAssertTrue(snapshot.onAC); XCTAssertTrue(snapshot.adapterPresent)
    }
    func testFailedCandidateReadDoesNotInventConnectionDuringCutoff() {
        let fields: [String: Any] = ["BatteryInstalled": true, "CurrentCapacity": 82, "MaxCapacity": 100,
            "ExternalConnected": false, "AppleRawExternalConnected": false]
        let missing = BatteryTelemetry.decode(fields)
        let malformed = BatteryTelemetry.decode(fields, physicalAdapter: .init(type: "si8 ", bytes: []))
        XCTAssertNil(missing.adapterConnectionCandidate); XCTAssertFalse(missing.adapterPresent)
        XCTAssertNil(malformed.adapterConnectionCandidate); XCTAssertFalse(malformed.adapterPresent)
    }
    private func sample(_ level: Int = 60, ac: Bool = true, temperature: Double? = 30) -> BatteryTelemetry {
        var s = BatteryTelemetry(); s.hasBattery = true; s.level = level; s.onAC = ac; s.temperature = temperature; return s
    }
    private func request(_ mode: BatteryControlMode = .automatic) -> BatteryControlRequest {
        .init(owner: UUID(), preferences: .init(), mode: mode)
    }
    func testPauseBelowEightyPreservesLongTermSettingsAndResumes() throws {
        var policy = BatteryControlPolicy(), r = request(.paused)
        let saved = r.preferences
        let pause = try policy.decide(request: r, snapshot: sample(60))
        XCTAssertTrue(pause.inhibit); XCTAssertFalse(pause.forceDischarge)
        XCTAssertEqual(pause.target, 60); XCTAssertEqual(pause.nativeTarget(currentLevel: 60), 60)
        XCTAssertEqual(r.preferences, saved); XCTAssertFalse(r.preferences.allowLowLimit)
        r.mode = .automatic
        let resume = try policy.decide(request: r, snapshot: sample(60))
        XCTAssertEqual(resume.target, 80); XCTAssertFalse(resume.inhibit)
    }
    func testOrdinaryLimitDoesNotActivelyDrainAboveLimit() throws {
        var policy = BatteryControlPolicy()
        let decision = try policy.decide(request: request(), snapshot: sample(90))
        XCTAssertTrue(decision.inhibit); XCTAssertFalse(decision.forceDischarge)
        XCTAssertEqual(decision.nativeTarget(currentLevel: 90), 90, "A native target of80 here would actively drain rather than pause")
        XCTAssertEqual(try policy.decide(request: request(), snapshot: sample(88)).nativeTarget(currentLevel: 88), 88)
    }
    func testDelayedGaugeCannotRaiseAnAutomaticChargeCeiling() throws {
        var policy = BatteryControlPolicy(), r = request(); r.preferences.limit = 85
        _ = try policy.decide(request: r, snapshot: sample(80))
        XCTAssertEqual(try policy.decide(request: r, snapshot: sample(85)).nativeTarget(currentLevel: 85), 85)
        XCTAssertEqual(try policy.decide(request: r, snapshot: sample(86)).nativeTarget(currentLevel: 86), 85)
    }
    func testPauseDoesNotChaseAChargingGaugeUpwardWhileSystemSettles() throws {
        var policy = BatteryControlPolicy(); let r = request(.paused)
        _ = try policy.decide(request: r, snapshot: sample(82))
        XCTAssertEqual(try policy.decide(request: r, snapshot: sample(83)).nativeTarget(currentLevel: 83), 82)
        XCTAssertEqual(try policy.decide(request: r, snapshot: sample(81)).nativeTarget(currentLevel: 81), 81)
    }
    func testAutomaticDischargeOnlyAboveLimitAndNeverBelowSafetyFloor() throws {
        var policy = BatteryControlPolicy(), r = request(); r.preferences.automaticDischarge = true
        let high = try policy.decide(request: r, snapshot: sample(90))
        XCTAssertTrue(high.forceDischarge); XCTAssertEqual(high.nativeTarget(currentLevel: 90), 100)
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(80)).forceDischarge)
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(10)).forceDischarge)
    }
    func testManualDischargeCompletesAtTargetAndReturnsOriginalLimit() throws {
        var policy = BatteryControlPolicy(), r = request(.discharge); r.dischargeTarget = 50
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(60)).forceDischarge)
        let reached = try policy.decide(request: r, snapshot: sample(50))
        XCTAssertEqual(reached.completionReason, .targetReached)
        XCTAssertTrue(reached.completed); XCTAssertFalse(reached.forceDischarge); XCTAssertEqual(reached.target, 80)
    }
    func testTopUpPersistsAtFullUntilUnplugged() throws {
        var policy = BatteryControlPolicy(); let r = request(.topUp)
        let full = try policy.decide(request: r, snapshot: sample(100))
        XCTAssertEqual(full.target, 100); XCTAssertFalse(full.completed)
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(100, ac: false)).completed)
    }
    func testSailingHysteresisAndNewCycle() throws {
        var policy = BatteryControlPolicy(), r = request(); r.preferences.sailing = true
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(75)).inhibit)
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(80)).inhibit)
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(75)).inhibit)
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(70)).inhibit)
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(19)).inhibit)
    }
    func testUnrelatedLEDPreferenceCannotResetSailingOrThermalProtection() throws {
        var sailing = BatteryControlPolicy(), r = request(); r.preferences.sailing = true
        _ = try sailing.decide(request: r, snapshot: sample(80))
        var next = r; next.preferences.led = .green
        sailing.configure(previous: r, next: next)
        XCTAssertTrue(try sailing.decide(request: next, snapshot: sample(75)).inhibit)
        var heat = BatteryControlPolicy(); r.preferences.heatProtection = true
        _ = try heat.decide(request: r, snapshot: sample(60, temperature: 36), now: 0)
        next = r; next.preferences.led = .orange
        heat.configure(previous: r, next: next)
        XCTAssertTrue(try heat.decide(request: next, snapshot: sample(60, temperature: 34), now: 100).inhibit)
    }
    func testReturningFromTopUpDoesNotReuseAnEarlierAutomaticCeiling() throws {
        var policy = BatteryControlPolicy(), automatic = request(); automatic.preferences.limit = 85
        _ = try policy.decide(request: automatic, snapshot: sample(80))
        var full = automatic; full.mode = .topUp
        policy.configure(previous: automatic, next: full)
        _ = try policy.decide(request: full, snapshot: sample(100))
        policy.configure(previous: full, next: automatic)
        XCTAssertEqual(try policy.decide(request: automatic, snapshot: sample(100)).nativeTarget(currentLevel: 100), 100)
    }
    func testHeatHysteresisMissingSensorAndResumption() throws {
        var policy = BatteryControlPolicy(), r = request(); r.preferences.heatProtection = true
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(60, temperature: 35), now: 0).inhibit)
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(60, temperature: 34), now: 299).inhibit)
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(60, temperature: 34), now: 300).inhibit)
        XCTAssertFalse(try policy.decide(request: r, snapshot: sample(60, temperature: 36), now: 599).inhibit)
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(60, temperature: 36), now: 600).inhibit)
        XCTAssertTrue(try policy.decide(request: r, snapshot: sample(60, temperature: nil), now: 601).inhibit)
    }
    func testSleepPauseRetainsLongTermLimitAndWakeRestores() throws {
        var policy = BatteryControlPolicy(), r = request(); r.preferences.sleep = .pause; r.sleeping = true
        XCTAssertEqual(try policy.decide(request: r, snapshot: sample(60)).target, 60)
        r.sleeping = false
        XCTAssertEqual(try policy.decide(request: r, snapshot: sample(60)).target, 80)
    }
    func testRejectsUnknownBatteryAndInvalidRanges() throws {
        var policy = BatteryControlPolicy(), r = request()
        XCTAssertThrowsError(try policy.decide(request: r, snapshot: .init()))
        r.preferences.limit = 60; XCTAssertThrowsError(try r.validate())
        r.preferences.allowLowLimit = true; XCTAssertNoThrow(try r.validate())
        r.preferences.limit = 19; XCTAssertThrowsError(try r.validate())
        r.preferences.limit = 80; r.preferences.sailing = true; r.preferences.sailingLower = 80
        XCTAssertThrowsError(try r.validate())
        r.preferences.sailing = false; r.preferences.maximumTemperature = .nan; XCTAssertThrowsError(try r.validate())
    }
    func testUnplugCannotLeaveATemporaryModeActive() throws {
        var policy = BatteryControlPolicy()
        for mode in [BatteryControlMode.discharge, .paused, .topUp] {
            var r = request(mode); r.dischargeTarget = 30
            let decision = try policy.decide(request: r, snapshot: sample(50, ac: false))
            XCTAssertTrue(decision.completed); XCTAssertFalse(decision.forceDischarge)
        }
    }
    func testDischargeKeepsItsModeWhenTheConnectedAdapterIsTemporarilyInhibited() throws {
        var policy = BatteryControlPolicy(), request = request(.discharge)
        request.dischargeTarget = 50
        let discharging = BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100,
            "ExternalConnected": false, "AppleRawExternalConnected": true, "IsCharging": false])
        XCTAssertFalse(discharging.onAC); XCTAssertTrue(discharging.adapterPresent)
        let decision = try policy.decide(request: request, snapshot: discharging)
        XCTAssertTrue(decision.forceDischarge); XCTAssertFalse(decision.completed)
        var unplugged = discharging; unplugged.adapterPhysicallyConnected = false
        XCTAssertTrue(try policy.decide(request: request, snapshot: unplugged).completed)
    }
    func testPauseBelowSafetyFloorCannotPretendToSucceed() {
        var policy = BatteryControlPolicy()
        XCTAssertThrowsError(try policy.decide(request: request(.paused), snapshot: sample(10)))
    }
    func testNestedMacOS27TelemetryAndSignedCurrent() {
        let s = BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100, "Voltage": 12_500,
            "InstantAmperage": NSNumber(value: Int64(-1_000)), "CycleCount": 54,
            "BatteryData": ["DesignCapacity": 6_249, "FullChargeCapacity": 5_762, "RemainingCapacity": 4_590]])
        XCTAssertEqual(s.level, 80); XCTAssertEqual(s.current, -1)
        XCTAssertEqual(s.power, -12.5); XCTAssertEqual(s.fullCapacity, 5_762)
        XCTAssertEqual(s.health!, 92.2, accuracy: 0.1)
        XCTAssertNil(s.temperature, "A missing sensor must not become0°C")
        XCTAssertNil(BatteryTelemetry.decode([:]).level)
    }
    func testTemperatureAndCapacitySanity() {
        let s = BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 5_000, "MaxCapacity": 10_000, "Temperature": 3_500])
        XCTAssertEqual(s.level, 50); XCTAssertEqual(s.temperature, 35)
        XCTAssertNil(BatteryTelemetry.decode(["Temperature": 123_456, "Voltage": -10]).temperature)
    }
    func testACLimitHoldDoesNotShowAnExtrapolatedNineHundredHourRuntime() {
        let s = BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100,
                                         "ExternalConnected": true, "IsCharging": false, "AvgTimeToEmpty": 55_092])
        XCTAssertNil(s.minutesRemaining)
        let charging = BatteryTelemetry.decode(["BatteryInstalled": true, "ExternalConnected": true,
                                                 "IsCharging": true, "AvgTimeToFull": 30])
        XCTAssertEqual(charging.minutesRemaining, 30)
    }
}

final class BatteryManagementLeaseTests: XCTestCase {
    func testRemovingFailedReplacementRestoresThePreviousOwnedValue() throws {
        var value = 80
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in
            if v == 90 { throw CocoaError(.fileWriteNoPermission) }; value = v
        }, save: { _ in })
        try lease.renew(owner: owner, now: 0)
        try lease.apply(["limit": 85], owner: owner)
        XCTAssertThrowsError(try lease.apply(["limit": 90], owner: owner))
        try lease.apply([:], owner: owner)
        XCTAssertEqual(value, 80)
        XCTAssertTrue(lease.journal?.entries.isEmpty == true)
    }
    func testLegacyJournalKeepsUncertainExternalValuesAndRecoversKnownOwnedValues() throws {
        let owner = UUID()
        let encoded = "{\"owner\":\"\(owner.uuidString)\",\"entries\":{\"limit\":{\"original\":80,\"expected\":85}}}"
        let old = try JSONDecoder().decode(BatteryOverrideLease.Journal.self, from: Data(encoded.utf8))
        XCTAssertNil(old.schemaVersion)
        var value = 85
        let lease = BatteryOverrideLease(journal: old, read: { _ in value }, write: { _, v in value = v }, save: { _ in })
        try lease.release(); XCTAssertEqual(value, 80)
        var uncertain = old; uncertain.entries["limit"]?.expected = 80
        value = 90
        let uncertainLease = BatteryOverrideLease(journal: uncertain, read: { _ in value }, write: { _, v in value = v }, save: { _ in })
        XCTAssertThrowsError(try uncertainLease.release()); XCTAssertEqual(value, 90)
    }
    func testFailedReplacementStillRestoresThePreviouslyAppliedOwnedValue() throws {
        var value = 80
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in
            if v == 90 { throw CocoaError(.fileWriteNoPermission) }; value = v
        }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 85], owner: owner)
        XCTAssertThrowsError(try lease.apply(["limit": 90], owner: owner))
        XCTAssertEqual(value, 85)
        try lease.release(); XCTAssertEqual(value, 80); XCTAssertNil(lease.journal)
    }
    func testFailedWriteBackToOriginalIsNotMistakenForAnUnchangedRegister() throws {
        var value = 80, failNextRestore = false
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in
            if v == 80 && failNextRestore { failNextRestore = false; throw CocoaError(.fileWriteNoPermission) }
            value = v
        }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 85], owner: owner)
        failNextRestore = true
        XCTAssertThrowsError(try lease.apply(["limit": 80], owner: owner))
        XCTAssertEqual(value, 85)
        try lease.release(); XCTAssertEqual(value, 80)
    }
    func testAnObservedButUnchangedRegisterCreatesNoRestoreObligation() throws {
        var value = 80
        let owner = UUID(), lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in value = v }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80], owner: owner)
        value = 90 // Somebody else changed a register we never overrode.
        try lease.release(); XCTAssertEqual(value, 90); XCTAssertNil(lease.journal)
    }
    func testDurableIntentPrecedesWriteAndOriginalIsRestored() throws {
        var values = ["limit": 95], saved: BatteryOverrideLease.Journal?
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { values[$0]! }, write: { key, value in
            XCTAssertEqual(saved?.entries[key]?.original, 95)
            XCTAssertEqual(saved?.entries[key]?.expected, value)
            values[key] = value
        }, save: { saved = $0 })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80], owner: owner)
        XCTAssertEqual(values["limit"], 80)
        try lease.apply(["limit": 90], owner: owner)
        XCTAssertEqual(saved?.entries["limit"]?.original, 95)
        // Recovery's write still has the original durable intent, not a new one.
        let recovery = BatteryOverrideLease(journal: saved, read: { values[$0]! }, write: { values[$0] = $1 }, save: { saved = $0 })
        try recovery.release()
        XCTAssertEqual(values["limit"], 95); XCTAssertNil(saved)
    }
    func testCannotStealOwnerOrReleaseAnotherInstancesLease() throws {
        let owner = UUID(), other = UUID()
        var value = 100
        let lease = BatteryOverrideLease(read: { _ in value }, write: { _, new in value = new }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80], owner: owner)
        XCTAssertThrowsError(try lease.renew(owner: other, now: 1))
        XCTAssertThrowsError(try lease.apply(["limit": 20], owner: other))
        XCTAssertThrowsError(try lease.release(owner: other)); XCTAssertEqual(value, 80)
    }
    func testExternalChangeIsNeverOverwrittenEvenOnExpiry() throws {
        var value = 100, saved: BatteryOverrideLease.Journal?
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { _ in value }, write: { _, n in value = n }, save: { saved = $0 })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80], owner: owner)
        value = 70
        XCTAssertThrowsError(try lease.apply(["limit": 90], owner: owner))
        XCTAssertThrowsError(try lease.expire(now: 50)); XCTAssertEqual(value, 70); XCTAssertNotNil(saved)
        value = 80
        try lease.release(); XCTAssertEqual(value, 100); XCTAssertNil(saved)
    }
    func testCrashBetweenIntentAndWriteIsRecoverable() throws {
        let owner = UUID()
        let journal = BatteryOverrideLease.Journal(owner: owner, entries: ["limit": .init(original: 100, expected: 80)])
        var writes = 0
        let lease = BatteryOverrideLease(journal: journal, read: { _ in 100 }, write: { _, _ in writes += 1 }, save: { _ in })
        try lease.release(); XCTAssertEqual(writes, 0); XCTAssertNil(lease.journal)
    }
    func testUnchangedRenewalDoesNotWriteOrFsyncEveryTick() throws {
        var saves = 0, writes = 0
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { _ in 80 }, write: { _, _ in writes += 1 }, save: { _ in saves += 1 })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80], owner: owner)
        let baseline = saves
        for i in 1...10 { try lease.renew(owner: owner, now: Double(i)); try lease.apply(["limit": 80], owner: owner) }
        XCTAssertEqual(saves, baseline); XCTAssertEqual(writes, 0)
    }
    func testSaveFailureCannotReachHardware() throws {
        var writes = 0
        let lease = BatteryOverrideLease(read: { _ in 100 }, write: { _, _ in writes += 1 }, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try lease.renew(owner: UUID(), now: 0)); XCTAssertEqual(writes, 0)
    }
    func testRemovedOptionalSettingRestoresOnlyItsOwnRegister() throws {
        var values = ["limit": 100, "led": 2]
        let owner = UUID(), lease = BatteryOverrideLease(read: { values[$0]! }, write: { values[$0] = $1 }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80, "led": 3], owner: owner)
        try lease.apply(["limit": 80], owner: owner)
        XCTAssertEqual(values["led"], 2); XCTAssertEqual(values["limit"], 80)
        XCTAssertNil(lease.journal?.entries["led"])
    }
    func testLeaseExpiresOnlyAfterLastAcknowledgedRenewal() throws {
        var value = 100
        let owner = UUID(), lease = BatteryOverrideLease(read: { _ in value }, write: { _, v in value = v }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.apply(["limit": 80], owner: owner)
        try lease.renew(owner: owner, now: 30)
        try lease.expire(now: 74); XCTAssertEqual(value, 80)
        try lease.expire(now: 75); XCTAssertEqual(value, 100)
    }
}

final class BatteryManagementScheduleTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    @MainActor func testQueuedDisabledOrDeletedTaskNeverReachesExecutor() async throws {
        for deleting in [false, true] {
            let defaults = UserDefaults(suiteName: "SuperIsland.BM1.ScheduleQueue.\(UUID())")!
            defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
            var clock = Date(timeIntervalSince1970: 2_000_000_000)
            let executor = BatteryScheduleTestExecutor()
            defer { executor.finishFirst() }
            let service = BatteryScheduleService(defaults: defaults, now: { clock }, execution: executor.execute)
            var first = BatteryScheduledTask(); first.name = "first"; first.anchor = clock.addingTimeInterval(60)
            var second = first; second.id = UUID(); second.name = "queued"
            try service.save(first); try service.save(second)
            clock = first.anchor
            let drain = try XCTUnwrap(service.evaluate())
            for _ in 0..<100 where executor.pending == nil { await Task.yield() }
            XCTAssertNotNil(executor.pending)
            if deleting { service.delete(second.id) } else { service.setEnabled(second.id, false) }
            executor.finishFirst(); await drain.value
            XCTAssertEqual(executor.requests.map(\.id), [first.id])
            XCTAssertFalse(service.runs.contains { $0.taskID == second.id })
        }
    }
    @MainActor func testQueuedEditDoesNotSubmitStaleParameters() async throws {
        let defaults = UserDefaults(suiteName: "SuperIsland.BM1.ScheduleEdit.\(UUID())")!
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let executor = BatteryScheduleTestExecutor()
        defer { executor.finishFirst() }
        let service = BatteryScheduleService(defaults: defaults, now: { clock }, execution: executor.execute)
        var first = BatteryScheduledTask(); first.anchor = clock.addingTimeInterval(60)
        var second = first; second.id = UUID(); second.action = .limit; second.target = 80
        try service.save(first); try service.save(second)
        clock = first.anchor
        let drain = try XCTUnwrap(service.evaluate())
        for _ in 0..<100 where executor.pending == nil { await Task.yield() }
        XCTAssertNotNil(executor.pending)
        second.target = 85; second.anchor = clock.addingTimeInterval(3600)
        try service.save(second)
        executor.finishFirst(); await drain.value
        XCTAssertEqual(executor.requests.map(\.id), [first.id])
        XCTAssertEqual(service.tasks.first { $0.id == second.id }?.target, 85)
        XCTAssertEqual(service.tasks.first { $0.id == second.id }?.nextDue, second.anchor)
    }
    @MainActor func testQueuedTaskUsesDispatchTimeForLateness() async throws {
        let defaults = UserDefaults(suiteName: "SuperIsland.BM1.ScheduleLate.\(UUID())")!
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let executor = BatteryScheduleTestExecutor()
        defer { executor.finishFirst() }
        let service = BatteryScheduleService(defaults: defaults, now: { clock }, execution: executor.execute)
        var first = BatteryScheduledTask(); first.anchor = clock.addingTimeInterval(60)
        var second = first; second.id = UUID()
        try service.save(first); try service.save(second)
        clock = first.anchor
        let drain = try XCTUnwrap(service.evaluate())
        for _ in 0..<100 where executor.pending == nil { await Task.yield() }
        XCTAssertNotNil(executor.pending)
        clock = clock.addingTimeInterval(120)
        executor.finishFirst(); await drain.value
        XCTAssertEqual(executor.requests.map(\.id), [first.id])
        XCTAssertEqual(service.runs.first { $0.taskID == second.id }?.status, "已跳过")
        XCTAssertEqual(service.runs.first { $0.taskID == second.id }?.timestamp, clock)
    }
    func testMonthEndDoesNotDrift() {
        var task = BatteryScheduledTask(); task.timeZoneID = "UTC"; task.repetition = .monthly; task.anchor = date("2026-01-31T09:00:00Z")
        XCTAssertEqual(task.next(after: date("2026-02-01T00:00:00Z")), date("2026-02-28T09:00:00Z"))
        XCTAssertEqual(task.next(after: date("2026-03-01T00:00:00Z")), date("2026-03-31T09:00:00Z"))
    }
    func testAnnualLeapDayPreservesOriginalAnchor() {
        var task = BatteryScheduledTask(); task.timeZoneID = "UTC"; task.repetition = .yearly; task.anchor = date("2024-02-29T09:00:00Z")
        XCTAssertEqual(task.next(after: date("2025-01-01T00:00:00Z")), date("2025-02-28T09:00:00Z"))
        XCTAssertEqual(task.next(after: date("2028-01-01T00:00:00Z")), date("2028-02-29T09:00:00Z"))
    }
    func testFortnightKeepsItsPhaseAcrossLongAbsence() {
        var task = BatteryScheduledTask(); task.timeZoneID = "UTC"; task.repetition = .fortnightly; task.anchor = date("2026-01-01T09:00:00Z")
        XCTAssertEqual(task.next(after: date("2026-02-01T00:00:00Z")), date("2026-02-12T09:00:00Z"))
    }
    func testDSTMissingTimeMovesForwardAndRepeatRunsOnce() {
        var task = BatteryScheduledTask(); task.timeZoneID = "America/New_York"; task.repetition = .daily; task.anchor = date("2026-03-07T07:30:00Z")
        XCTAssertEqual(task.next(after: date("2026-03-08T05:00:00Z")), date("2026-03-08T07:00:00Z"))
        task.anchor = date("2026-10-31T05:30:00Z")
        XCTAssertEqual(task.next(after: date("2026-11-01T04:00:00Z")), date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(task.next(after: date("2026-11-01T05:30:00Z")), date("2026-11-02T06:30:00Z"))
    }
    func testOneShotAndInvalidZoneAreExplicit() {
        var task = BatteryScheduledTask(); task.anchor = date("2026-01-01T09:00:00Z")
        XCTAssertNil(task.next(after: date("2026-01-02T09:00:00Z")))
        task.repetition = .daily; task.timeZoneID = "not/a/timezone"
        XCTAssertNil(task.next(after: date("2026-01-02T09:00:00Z")))
    }
    func testCatchUpChoosesLatestInstanceRatherThanAWeekOldOccurrence() {
        var task = BatteryScheduledTask(); task.timeZoneID = "UTC"; task.repetition = .daily
        task.anchor = date("2026-01-01T09:00:00Z"); task.nextDue = task.anchor; task.catchUp = true
        XCTAssertEqual(task.latestDue(at: date("2026-01-08T10:00:00Z")), date("2026-01-08T09:00:00Z"))
    }
    @MainActor func testSaveAndRelaunchPreserveOneEnvelope() throws {
        let defaults = UserDefaults(suiteName: "SuperIsland.BM1.Tests.\(UUID())")!
        // Use this exact suite's volatile test state only.
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        let service = BatteryScheduleService(defaults: defaults)
        var task = BatteryScheduledTask(); task.anchor = Date().addingTimeInterval(3600); task.repetition = .daily
        try service.save(task)
        XCTAssertEqual(BatteryScheduleService(defaults: defaults).tasks.first?.id, task.id)
        service.delete(task.id)
        XCTAssertTrue(BatteryScheduleService(defaults: defaults).tasks.isEmpty)
    }
    @MainActor func testInvalidPreferenceCannotPersistOrBecomeApplied() throws {
        let defaults = UserDefaults(suiteName: "SuperIsland.BM1.PreferenceTests.\(UUID())")!
        defer { defaults.removeObject(forKey: "batteryManagement.preferences") }
        let service = BatteryManagementService(defaults: defaults)
        XCTAssertFalse(service.enabled)
        XCTAssertThrowsError(try service.updatePreferences { $0.limit = 50 })
        XCTAssertNil(defaults.data(forKey: "batteryManagement.preferences"))
        XCTAssertEqual(service.preferences.limit, 80)
        XCTAssertEqual(SettingsPane.batteryManagement.title, "电池管理")
        XCTAssertEqual(SettingsPane.general.title, "通用")
    }
}

@MainActor
private final class BatteryScheduleTestExecutor {
    var requests: [BatteryScheduledTask] = []
    var pending: CheckedContinuation<String, Error>?
    func execute(_ task: BatteryScheduledTask) async throws -> String {
        requests.append(task)
        if requests.count == 1 {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return "isolated test request accepted"
    }
    func finishFirst() {
        let continuation = pending; pending = nil
        continuation?.resume(returning: "isolated test request accepted")
    }
}

@MainActor
private final class BatteryTestTransport: BatteryManagementTransport {
    // One fake daemon instance keeps the same epoch, like the real report.
    let controlEpoch = UUID()
    var authorization = SMAppService.Status.enabled
    var helperBundled = true
    var registrationFailure: Error?
    var registered = 0
    var renewals: [BatteryControlRequest] = []
    var releases = 0
    var inspectCount = 0
    var failRenewal = false
    var controlFault = false
    var failRelease = false
    var pendingReleaseCount = 0
    var pendingReleasePhase = BatteryCutoffSession.Phase.restoring
    var holdRenewal = false
    var mechanism = "SMC CHTE" // Explicit fake supported route, never an unknown-name capability.
    var highPowerSupported = false
    var proveCutoff = false, proveLease = true
    var completeDischarge = false
    var nativeCutoffTrial = false
    var protocolVersion: Int? = BatteryControlReport.currentProtocolVersion
    var held: CheckedContinuation<(Bool, BatteryControlReport), Error>?
    var holdRegistration = false
    var heldRegistration: CheckedContinuation<Void, Error>?
    var inspectReport: BatteryControlReport?
    var inspectReply: (() async throws -> (Bool, BatteryControlReport))?
    var renewalReply: ((BatteryControlRequest) -> (Bool, BatteryControlReport))?
    var releaseReply: (() async throws -> (Bool, BatteryControlReport))?
    func register() async throws {
        registered += 1
        if let registrationFailure { throw registrationFailure }
        if holdRegistration { try await withCheckedThrowingContinuation { heldRegistration = $0 } }
    }
    func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
        var report = BatteryControlReport(); report.available = true; report.dischargeSupported = true; report.mechanism = mechanism
        report.protocolVersion = protocolVersion
        report.controlEpoch = controlEpoch
        report.nativeCutoffReviewTrial = nativeCutoffTrial
        report.highPowerSupported = highPowerSupported
        report.requiresManualRetry = controlFault
        switch command {
        case .inspect:
            inspectCount += 1
            if let inspectReply { return try await inspectReply() }
            return (true, inspectReport ?? report)
        case .renew(let request):
            renewals.append(request)
            if holdRenewal { holdRenewal = false; return try await withCheckedThrowingContinuation { held = $0 } }
            if let renewalReply { return renewalReply(request) }
            if failRenewal { report.available = false; report.message = "write failed"; return (false, report) }
            report.mode = request.mode; report.registeredTarget = request.preferences.limit; report.message = "registered target"
            if request.mode == .discharge, completeDischarge { report.mode = .automatic }
            if request.mode == .discharge, proveCutoff {
                report.ownedAdapterCutoff = true; report.cutoffPhase = .discharging
                report.leaseHeldByRequester = proveLease
            }
            return (true, report)
        case .release:
            releases += 1
            if let releaseReply { return try await releaseReply() }
            if pendingReleaseCount > 0 {
                pendingReleaseCount -= 1
                report.recoveryPending = true; report.cutoffPhase = pendingReleasePhase
                report.leaseHeldByRequester = true; report.available = false
                report.message = "Waiting for actual supply recovery"
                return (false, report)
            }
            report.leaseHeldByRequester = failRelease
            report.recoveryPending = failRelease; report.message = failRelease ? "restore failed" : "restored"
            return (!failRelease, report)
        }
    }
}

private final class BatteryRepairUnflushedDefaults: UserDefaults, @unchecked Sendable {
    override func synchronize() -> Bool { false }
}

@MainActor
private final class BatteryTestRegistration: BatteryHelperRegistering {
    var status = SMAppService.Status.enabled
    var events: [String] = []
    var requiresApproval = true
    var unregisterError: Error?
    var failedLaunch = false
    var probe: (() async -> Bool)?
    func failedLaunchNeedsRebind() async -> Bool { await probe?() ?? failedLaunch }
    func unregister() async throws {
        events.append("unregister")
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
    func register() throws {
        events.append("register")
        if requiresApproval {
            status = .requiresApproval
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        }
        status = .enabled
    }
}

@MainActor
final class BatteryReadOnlyQueryTests: XCTestCase {
    func testUIReadOnlyPreviewRejectsEveryMutatingTransportOperation() async throws {
        let transport = BatteryReadOnlyPreviewTransport()
        let (_, report) = try await transport.call(.inspect)
        XCTAssertFalse(report.available); XCTAssertFalse(transport.helperBundled)
        do { try await transport.register(); XCTFail("Preview must never register") } catch {}
        for command in [BatteryManagementClient.Command.renew(.init(owner: UUID(), preferences: .init())), .release(UUID())] {
            do { _ = try await transport.call(command); XCTFail("Preview must reject mutation") } catch {}
        }
    }
    func testQueriesReadSavedAndObservedStateWithoutControlOrPreferenceWrites() async throws {
        let domain = "SuperIsland.BM1.ReadQueries.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var saved = BatteryControlPreferences(); saved.limit = 85
        let data = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: "batteryManagement.preferences")
        let transport = BatteryTestTransport()
        let queries = BatteryReadOnlyQueries(defaults: defaults,
            readTelemetry: { var s = BatteryTelemetry(); s.hasBattery = true; s.level = 79; s.temperature = 34.5; s.charging = false; return s },
            inspect: {
                let (_, report) = try await transport.call(.inspect)
                var result = report; result.registeredTarget = 82; result.nativeSavedLimit = 81
                return result
            })
        XCTAssertEqual(try queries.level(), 79)
        XCTAssertEqual(try queries.temperature(), 34.5)
        XCTAssertEqual(try queries.limit(), 85)
        XCTAssertEqual(transport.inspectCount, 0)
        let status = await queries.status()
        XCTAssertTrue(status.contains("当前未充电"))
        XCTAssertTrue(status.contains("长期上限85%"))
        XCTAssertTrue(status.contains("系统登记目标82%"))
        XCTAssertTrue(status.contains("系统手动上限读回81%"))
        XCTAssertEqual(transport.inspectCount, 1)
        XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertEqual(transport.releases, 0); XCTAssertEqual(transport.registered, 0)
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.preferences"), data)
        XCTAssertNil(defaults.object(forKey: "batteryManagement.scheduleStore"))
    }

    func testUnavailableSensorsAndCorruptPreferencesDoNotInventValues() throws {
        let domain = "SuperIsland.BM1.ReadQueryMissing.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let queries = BatteryReadOnlyQueries(defaults: defaults, readTelemetry: { .init() }, inspect: { XCTFail("Must not inspect for these queries"); return .init() })
        XCTAssertThrowsError(try queries.level())
        XCTAssertThrowsError(try queries.temperature())
        XCTAssertEqual(try queries.limit(), 80, "A new user has the defined default target")
        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: "batteryManagement.preferences")
        XCTAssertThrowsError(try queries.limit())
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.preferences"), corrupt)
    }

    func testStatusRetainsTelemetryAndReportsHelperFailureWithoutClaimingAnAppliedTarget() async {
        let domain = "SuperIsland.BM1.ReadQueryFailure.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let queries = BatteryReadOnlyQueries(defaults: defaults,
            readTelemetry: { var s = BatteryTelemetry(); s.hasBattery = true; s.charging = true; return s },
            inspect: { throw BatteryControlError.unavailable("helper disconnected") })
        let status = await queries.status()
        XCTAssertTrue(status.contains("正在充电")); XCTAssertTrue(status.contains("helper disconnected"))
        XCTAssertFalse(status.contains("系统登记目标80%"))
    }
}

final class BatteryEnergyModeTests: XCTestCase {
    func testExistingPreferencesWithoutHighPowerKeepAllStoredValues() throws {
        var p = BatteryControlPreferences(); p.limit = 85; p.lowPower = .adapter; p.sailing = true
        let original = try JSONEncoder().encode(p)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "highPower")
        let decoded = try JSONDecoder().decode(BatteryControlPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.limit, 85); XCTAssertEqual(decoded.lowPower, .adapter)
        XCTAssertTrue(decoded.sailing); XCTAssertEqual(decoded.highPowerScope, .never)
    }
    func testConflictingScopesAreRejectedInsteadOfPickingASilentPriority() {
        for low in BatteryEnergyScope.allCases {
            for high in BatteryEnergyScope.allCases {
                var p = BatteryControlPreferences(); p.lowPower = low; p.highPowerScope = high
                let overlap = [false, true].contains { low.applies(onAC: $0) && high.applies(onAC: $0) }
                if overlap { XCTAssertThrowsError(try BatteryEnergyTargets.make(preferences: p, highPowerSupported: true)) }
                else { XCTAssertNoThrow(try BatteryEnergyTargets.make(preferences: p, highPowerSupported: true)) }
            }
        }
    }
    func testPerSourceModesUseOneRestorableKeyAndNeverBothOldAndNewKeys() throws {
        var p = BatteryControlPreferences(); p.lowPower = .battery; p.highPowerScope = .adapter
        XCTAssertEqual(try BatteryEnergyTargets.make(preferences: p, highPowerSupported: true), ["powerModeBattery": 1, "powerModeAC": 2])
        p.lowPower = .never; p.highPowerScope = .never
        XCTAssertEqual(try BatteryEnergyTargets.make(preferences: p, highPowerSupported: true), [:])
        p.lowPower = .always
        XCTAssertEqual(try BatteryEnergyTargets.make(preferences: p, highPowerSupported: false), ["lowPowerBattery": 1, "lowPowerAC": 1])
        p.lowPower = .never; p.highPowerScope = .adapter
        XCTAssertThrowsError(try BatteryEnergyTargets.make(preferences: p, highPowerSupported: false))
    }
    func testConfigurationRequiresBothSourcesAndNonConflictingExplicitFlags() throws {
        let valid = "Battery Power:\n lowpowermode 1\n highpowermode 0\nAC Power:\n lowpowermode 0\n highpowermode 1\n"
        let config = try XCTUnwrap(BatteryEnergyConfiguration.parse(valid))
        XCTAssertTrue(config.highPowerSupported)
        XCTAssertEqual(config.battery.mode, 1); XCTAssertEqual(config.adapter.mode, 2)
        let contradiction = valid.replacingOccurrences(of: "lowpowermode 1\n highpowermode 0", with: "lowpowermode 1\n highpowermode 1")
        XCTAssertFalse(try XCTUnwrap(BatteryEnergyConfiguration.parse(contradiction)).highPowerSupported)
        let missing = valid.replacingOccurrences(of: " highpowermode 0\n", with: "")
        XCTAssertFalse(try XCTUnwrap(BatteryEnergyConfiguration.parse(missing)).highPowerSupported)
        XCTAssertNil(BatteryEnergyConfiguration.parse("AC Power:\n lowpowermode 0\n highpowermode 0"))
    }
    func testAmbiguousMalformedOrOutOfRangeConfigurationNeverAuthorizesModes() {
        let base = "Battery Power:\n lowpowermode 0\n highpowermode 0\nAC Power:\n lowpowermode 0\n highpowermode 0\n"
        for invalid in [base + " highpowermode 1\n", base + "AC Power:\n highpowermode 1\n", base.replacingOccurrences(of: "highpowermode 0", with: "highpowermode 2"), base.replacingOccurrences(of: "lowpowermode 0", with: "lowpowermode nope")] {
            XCTAssertNil(BatteryEnergyConfiguration.parse(invalid))
        }
        XCTAssertFalse(BatteryEnergyConfiguration.advertisesHighPower("Capabilities for AC Power:\n lowpowermode\n"))
        XCTAssertFalse(BatteryEnergyConfiguration.advertisesHighPower("not highpowermode"))
        XCTAssertTrue(BatteryEnergyConfiguration.advertisesHighPower("Capabilities for AC Power:\n highpowermode\n"))
    }
    func testReleasingEnergyTargetsRestoresBothOriginalModes() throws {
        var values = ["powerModeBattery": 1, "powerModeAC": 0]
        let owner = UUID()
        let lease = BatteryOverrideLease(read: { values[$0]! }, write: { values[$0] = $1 }, save: { _ in })
        try lease.renew(owner: owner, now: 0)
        var p = BatteryControlPreferences(); p.highPowerScope = .adapter
        try lease.apply(BatteryEnergyTargets.make(preferences: p, highPowerSupported: true), owner: owner)
        XCTAssertEqual(values, ["powerModeBattery": 0, "powerModeAC": 2])
        p.highPowerScope = .never
        try lease.apply(BatteryEnergyTargets.make(preferences: p, highPowerSupported: true), owner: owner)
        XCTAssertEqual(values, ["powerModeBattery": 1, "powerModeAC": 0])
        XCTAssertTrue(lease.journal?.entries.isEmpty == true)
    }
}

final class BatteryPowerWindowTests: XCTestCase {
    private func sample(_ time: TimeInterval, _ watts: Double) -> BatteryTelemetry {
        var value = BatteryTelemetry()
        value.timestamp = Date(timeIntervalSince1970: 2_000_000_000 + time)
        value.hasBattery = true; value.voltage = 1; value.current = watts
        return value
    }
    func testIrregularSamplesUseObservedTimeRatherThanSampleCount() throws {
        var window = BatteryPowerWindow()
        window.record(sample(0, 0)); window.record(sample(5, 100)); window.record(sample(15, 100))
        let result = try XCTUnwrap(window.summary(at: sample(15, 0).timestamp))
        XCTAssertEqual(result.watts, 1250.0 / 15, accuracy: 0.0001)
        XCTAssertEqual(result.coverage, 15)
    }
    func testWindowClipsBoundaryAndNeverExtrapolatesToCurrentTime() throws {
        var window = BatteryPowerWindow()
        for t in stride(from: 0, through: 70, by: 10) { window.record(sample(Double(t), Double(t))) }
        let result = try XCTUnwrap(window.summary(at: sample(75, 0).timestamp))
        XCTAssertEqual(result.coverage, 55)
        XCTAssertEqual(result.watts, 42.5, accuracy: 0.0001)
        XCTAssertNil(window.summary(at: sample(100, 0).timestamp))
    }
    func testMissingSensorOrSleepGapRequiresFreshCoverage() {
        var window = BatteryPowerWindow()
        window.record(sample(0, -10)); window.record(sample(10, -10))
        XCTAssertNotNil(window.summary(at: sample(10, 0).timestamp))
        var missing = sample(15, 0); missing.current = nil
        window.record(missing)
        XCTAssertNil(window.summary(at: missing.timestamp))
        window.record(sample(20, -10)); window.record(sample(25, -10))
        XCTAssertNil(window.summary(at: sample(25, 0).timestamp))
        window.record(sample(30, -10))
        XCTAssertEqual(window.summary(at: sample(30, 0).timestamp)?.watts, -10)
        window.record(sample(100, -10))
        XCTAssertNil(window.summary(at: sample(100, 0).timestamp))
    }
    func testRepeatedReadsDoNotBiasAverageAndClockRollbackResetsWindow() throws {
        var window = BatteryPowerWindow()
        window.record(sample(0, 10)); window.record(sample(10, 10))
        window.record(sample(10, 100))
        XCTAssertEqual(try XCTUnwrap(window.summary(at: sample(10, 0).timestamp)).watts, 10)
        window.record(sample(-20, -5))
        XCTAssertNil(window.summary(at: sample(-20, 0).timestamp))
        window.record(sample(-10, -5))
        XCTAssertEqual(window.summary(at: sample(-10, 0).timestamp)?.watts, -5)
    }
    func testSignedZeroAndInvalidPowerStayDistinctFromUnavailable() {
        var window = BatteryPowerWindow()
        window.record(sample(0, 0)); window.record(sample(10, 0))
        XCTAssertEqual(window.summary(at: sample(10, 0).timestamp)?.watts, 0)
        window.record(sample(15, .nan))
        XCTAssertNil(window.summary(at: sample(15, 0).timestamp))
        window.record(sample(20, .infinity))
        XCTAssertNil(window.summary(at: sample(20, 0).timestamp))
    }
}

@MainActor
final class BatteryManagementServiceTests: XCTestCase {
    func testDiagnosticClientRejectsMutationsBeforeAuthorizationOrXPC() async {
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered
        let client = BatteryManagementClient(registrar: registrar, diagnosticsOnly: true)
        for command in [BatteryManagementClient.Command.renew(.init(owner: UUID(), preferences: .init())), .release(UUID())] {
            do { _ = try await client.call(command); XCTFail("Diagnostic launch cannot mutate hardware") }
            catch { XCTAssertTrue(error.localizedDescription.contains("只读诊断")) }
        }
        do { _ = try await client.call(.inspect); XCTFail("Fake registrar intentionally has no authorization") }
        catch { XCTAssertFalse(error.localizedDescription.contains("只读诊断"), "Inspect must pass the diagnostic gate") }
        XCTAssertTrue(registrar.events.isEmpty)
    }
    func testProtocolEightCannotSupplyTrustedCutoffCancellationContext() async {
        let t = BatteryTestTransport(); t.protocolVersion = 8
        let s = service(t); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        XCTAssertFalse(s.enabled); XCTAssertTrue(t.renewals.isEmpty)
    }
    func testOperationIdentityStaysStableOnRenewalAndChangesForExplicitRepeat() async throws {
        let transport = BatteryTestTransport()
        var snapshot = BatteryTelemetry(); snapshot.hasBattery = true; snapshot.level = 82; snapshot.onAC = true
        let s = service(transport, telemetry: { snapshot }); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        _ = try await s.execute(mode: .discharge, target: 80)
        let first = try XCTUnwrap(transport.renewals.last)
        await s.attemptStartupForTesting()
        XCTAssertEqual(transport.renewals.last, first, "A lease renewal must retain the operation identity")
        transport.completeDischarge = true
        await s.attemptStartupForTesting()
        XCTAssertEqual(s.mode, .automatic)
        await s.attemptStartupForTesting()
        let automatic = try XCTUnwrap(transport.renewals.last)
        XCTAssertEqual(automatic.mode, .automatic); XCTAssertNil(automatic.dischargeTarget)
        XCTAssertEqual(automatic.operationID, first.operationID)
        transport.completeDischarge = false
        _ = try await s.execute(mode: .discharge, target: 80)
        let repeatAction = try XCTUnwrap(transport.renewals.last)
        XCTAssertNotEqual(repeatAction.operationID, first.operationID)
        XCTAssertEqual(repeatAction.dischargeTarget, first.dischargeTarget)
        XCTAssertEqual(repeatAction.owner, first.owner)
    }
    func testEnergySuggestionSuppressionCoversPendingDischargeAndClearsAfterReturn() async throws {
        let transport = BatteryTestTransport()
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 82; sample.onAC = true
        let s = service(transport, telemetry: { sample })
        defer { s.shutdown() }
        await s.attemptStartupForTesting()
        XCTAssertFalse(s.suppressesEnergySuggestions, "Ordinary battery operation must retain suggestions")
        transport.holdRenewal = true
        let operation = Task { try await s.execute(mode: .discharge, target: 80) }
        for _ in 0..<200 where transport.held == nil { await Task.yield() }
        XCTAssertNotNil(transport.held)
        XCTAssertTrue(s.suppressesEnergySuggestions, "The OS event may arrive before the helper reply")
        var reply = BatteryControlReport(); reply.available = true; reply.mechanism = "SMC CHTE"; reply.mode = .discharge
        reply.ownedAdapterCutoff = true; reply.cutoffPhase = .discharging; reply.leaseHeldByRequester = true
        transport.held?.resume(returning: (true, reply)); transport.held = nil
        _ = try await operation.value
        XCTAssertTrue(s.suppressesEnergySuggestions)
        _ = try await s.execute(mode: .automatic)
        XCTAssertFalse(s.suppressesEnergySuggestions)
    }
    func testFailedDischargeThatReleasedItsLeaseDoesNotSuppressLaterEnergySuggestions() async {
        let transport = BatteryTestTransport()
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 82; sample.onAC = true
        let s = service(transport, telemetry: { sample })
        defer { s.shutdown() }
        await s.attemptStartupForTesting()
        transport.failRenewal = true
        do { _ = try await s.execute(mode: .discharge, target: 80); XCTFail("Expected rejected renewal") } catch {}
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.shouldPrepareForTermination)
        XCTAssertFalse(s.suppressesEnergySuggestions, "A stale requested mode must not suppress future real unplug events")
    }
    func testOwnCutoffCanBeStoppedButCannotStartAnotherModeWithoutAC() async throws {
        let t = BatteryTestTransport(); t.proveCutoff = true
        var snapshot = BatteryTelemetry(); snapshot.hasBattery = true; snapshot.level = 82; snapshot.onAC = true
        let s = service(t, telemetry: { snapshot }); defer { s.shutdown() }
        await s.attemptStartupForTesting(); _ = try await s.execute(mode: .discharge, target: 80)
        snapshot.onAC = false; s.refreshTelemetry()
        XCTAssertTrue(s.canStopDischarge)
        let count = t.renewals.count
        do { _ = try await s.execute(mode: .topUp); XCTFail("Cutoff ownership cannot authorize a new charge mode") } catch {}
        XCTAssertEqual(t.renewals.count, count)
        _ = try await s.execute(mode: .automatic)
        XCTAssertEqual(t.renewals.last?.mode, .automatic); XCTAssertEqual(s.mode, .automatic)
    }
    func testRestrictedReviewRejectsUnavailableChoicesBeforePersistenceOrXPC() async throws {
        let transport = BatteryTestTransport(); transport.nativeCutoffTrial = true; transport.mechanism = "macOS Charge Limit"
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 81; sample.onAC = true
        let s = service(transport, telemetry: { sample }); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        XCTAssertTrue(s.reviewTrialActive)
        let before = s.preferences, count = transport.renewals.count
        let edits: [(inout BatteryControlPreferences) -> Void] = [
            { $0.limit = 86 }, { $0.automaticDischarge = true }, { $0.sailing = true },
            { $0.sleep = .untilLimit }, { $0.lowPower = .always }, { $0.led = .green }]
        for edit in edits {
            XCTAssertThrowsError(try s.updatePreferences(edit))
            XCTAssertEqual(s.preferences, before)
        }
        do { _ = try await s.execute(mode: .topUp); XCTFail("Restricted review cannot start100% charging") } catch {}
        do { _ = try await s.execute(mode: .discharge, target: 79); XCTFail("Restricted review must reject a different target before XPC") } catch {}
        XCTAssertEqual(s.mode, .automatic)
        XCTAssertEqual(transport.renewals.count, count)
        let host = NSHostingView(rootView: BatteryManagementPanel(service: s, initialSection: 1).padding(16).background(Color.black))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 624, height: 216), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "充满") != nil }
        let topUp = try XCTUnwrap(probe.button(title: "充满"))
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        XCTAssertTrue(topUp.responds(to: selector))
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertFalse(unsafeBitCast(topUp.method(for: selector), to: Enabled.self)(topUp, selector))
        let slider = try XCTUnwrap(probe.nodes().first { probe.string($0, "accessibilityRole") == "AXSlider" })
        let maximum = NSSelectorFromString("accessibilityMaxValue")
        XCTAssertTrue(slider.responds(to: maximum))
        XCTAssertEqual((slider.perform(maximum)?.takeUnretainedValue() as? NSNumber)?.intValue, 85)
    }
    func testNormalControlKeepsItsApprovedLimitAndTopUpChoices() async throws {
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Charge Limit"
        let s = service(transport); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        XCTAssertFalse(s.reviewTrialActive)
        _ = try await s.changeFromAutomation { $0.limit = 90 }
        _ = try await s.execute(mode: .topUp)
        XCTAssertEqual(s.preferences.limit, 90)
        XCTAssertEqual(transport.renewals.last?.mode, .topUp)
    }
    func testAllBatterySectionsRemainVisibleAndNativePressesPreserveControlContext() async throws {
        let transport = BatteryTestTransport()
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 82; sample.onAC = true
        sample.temperature = 31; sample.voltage = 12.5; sample.current = 0; sample.cycles = 55; sample.charging = false
        let s = service(transport, telemetry: { sample }); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        var settingsOpened = 0; s.openSettings = { settingsOpened += 1 }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: BatteryManagementPanel(service: s).padding(16).background(Color.black))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 624, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let probe = BatteryPanelAXProbe(window: window, host: host)
            try await probe.wait { probe.button(identifier: "battery-section-trend") != nil }
            for title in ["概览", "充电", "趋势"] {
                XCTAssertNotNil(probe.button(title: title), "All three labels must exist in both system appearances")
            }
            func capture(_ section: String) throws {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("build/bm1-battery-sections/\(appearance.rawValue)-\(section).png")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try image.write(to: output)
            }
            try capture("overview")
            try probe.press(identifier: "battery-section-control")
            try await probe.wait { probe.text.contains("充电上限") && probe.button(title: "放电…") != nil }
            try capture("controls")
            if appearance == .aqua {
                let renewals = transport.renewals.count
                try probe.press(title: "放电…")
                try await probe.wait { probe.button(title: "取消", allVisibleWindows: true) != nil }
                try probe.press(title: "取消", allVisibleWindows: true)
                try await probe.wait { probe.button(title: "开始放电", allVisibleWindows: true) == nil }
                XCTAssertEqual(transport.renewals.count, renewals, "Cancelling the target popover must never submit a control")
            }
            try probe.press(identifier: "battery-section-trend")
            try await probe.wait { probe.text.contains("真实电量") }
            try capture("trend")
            try probe.press(identifier: "battery-section-overview")
            try await probe.wait { probe.text.contains("当前未充电") }
            try probe.press(title: "电池设置")
            XCTAssertEqual(s.preferences.limit, 80)
            XCTAssertEqual(s.display.metrics.count, 6)
        }
        XCTAssertEqual(settingsOpened, 2)
        XCTAssertEqual(transport.renewals.count, 1, "Navigation and settings entry must preserve the current control request")
    }
    func testNativeStopButtonRemainsEnabledDuringOwnedCutoffAndPressesSameService() async throws {
        let t = BatteryTestTransport(); t.proveCutoff = true
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 82; sample.onAC = true
        let s = service(t, telemetry: { sample }); defer { s.shutdown() }
        await s.attemptStartupForTesting(); _ = try await s.execute(mode: .discharge, target: 80)
        sample.onAC = false; s.refreshTelemetry()
        let host = NSHostingView(rootView: BatteryManagementPanel(service: s, initialSection: 1).padding(16))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func text(_ object: NSObject, _ key: String) -> String? {
            let selector = NSSelectorFromString(key)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
        }
        func elements() -> [NSObject] {
            var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                result.append(object)
                let selector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(visit) }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            visit(window); return result
        }
        func bool(_ object: NSObject, _ key: String) throws -> Bool {
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { XCTFail("Missing native accessibility method: \(key)"); return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var buttons: [NSObject] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            buttons = elements().filter { text($0, "accessibilityRole") == "AXButton" }
            if buttons.contains(where: { text($0, "accessibilityLabel") == "停止放电" || text($0, "accessibilityTitle") == "停止放电" }) { break }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        func named(_ name: String) throws -> NSObject {
            try XCTUnwrap(buttons.first { text($0, "accessibilityLabel") == name || text($0, "accessibilityTitle") == name }, "Native buttons: \(buttons.map { text($0, "accessibilityLabel") ?? text($0, "accessibilityTitle") ?? "?" }); AX nodes: \(elements().map { [text($0, "accessibilityRole") ?? "nil", text($0, "accessibilityLabel") ?? text($0, "accessibilityIdentifier") ?? "nil"] })")
        }
        let stop = try named("停止放电")
        XCTAssertTrue(try bool(stop, "isAccessibilityEnabled"))
        XCTAssertFalse(try bool(named("充满"), "isAccessibilityEnabled"))
        XCTAssertFalse(try bool(named("暂停充电"), "isAccessibilityEnabled"))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/bm1-cutoff-trust/native-owned-cutoff.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: output)
        XCTAssertTrue(try bool(stop, "accessibilityPerformPress"))
        for _ in 0..<100 where s.mode != .automatic { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(s.mode, .automatic)
        XCTAssertEqual(t.renewals.last?.mode, .automatic)
        XCTAssertEqual(t.releases, 0, "The button uses the same automatic restoration path")
    }
    func testMissingCutoffOrOwnerProofCannotBypassAdapterGuard() async throws {
        for scenario in 0...1 {
            let t = BatteryTestTransport(); t.proveCutoff = scenario == 1; t.proveLease = false
            var snapshot = BatteryTelemetry(); snapshot.hasBattery = true; snapshot.level = 82; snapshot.onAC = true
            let s = service(t, telemetry: { snapshot }); defer { s.shutdown() }
            await s.attemptStartupForTesting(); _ = try await s.execute(mode: .discharge, target: 80)
            snapshot.onAC = false; s.refreshTelemetry()
            XCTAssertFalse(s.canStopDischarge)
            let count = t.renewals.count
            do { _ = try await s.execute(mode: .automatic); XCTFail("No proof cannot permit a mode change") } catch {}
            XCTAssertEqual(t.renewals.count, count)
        }
    }
    func testInstalledProtocolThreeCannotSilentlyIgnoreNewPowerPreferences() async {
        let transport = BatteryTestTransport(); transport.protocolVersion = 3
        let service = service(transport)
        await service.attemptStartupForTesting()
        XCTAssertEqual(transport.inspectCount, 1)
        XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(service.report.message.contains("版本不兼容"))
    }

    func testHighPowerAutomationUsesVerifiedCapabilityAndPreservesLongTermLimit() async throws {
        let transport = BatteryTestTransport(); transport.highPowerSupported = true
        let service = service(transport)
        await service.attemptStartupForTesting()
        _ = try await service.setHighPowerFromAutomation(.adapter)
        XCTAssertEqual(transport.renewals.last?.preferences.highPowerScope, .adapter)
        XCTAssertEqual(service.preferences.limit, 80)
        _ = try await service.setHighPowerFromAutomation(.never)
        XCTAssertEqual(transport.renewals.last?.preferences.highPowerScope, .never)
    }

    func testUnsupportedHighPowerCannotBeSavedOrSubmittedAtStartup() async throws {
        let transport = BatteryTestTransport(), running = service(transport)
        await running.attemptStartupForTesting()
        let count = transport.renewals.count
        do { _ = try await running.setHighPowerFromAutomation(.always); XCTFail("Unsupported power mode must fail") } catch {}
        XCTAssertEqual(running.preferences.highPowerScope, .never)
        XCTAssertEqual(transport.renewals.count, count)
        let domain = "SuperIsland.BM1.StoredHighPower.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var p = BatteryControlPreferences(); p.highPowerScope = .adapter
        defaults.set(try JSONEncoder().encode(p), forKey: "batteryManagement.preferences")
        let cold = BatteryTestTransport()
        let service = BatteryManagementService(defaults: defaults, client: cold,
            telemetryReader: { var s = BatteryTelemetry(); s.hasBattery = true; s.level = 80; s.onAC = true; return s }, conflictChecker: { nil })
        await service.attemptStartupForTesting()
        XCTAssertTrue(cold.renewals.isEmpty); XCTAssertFalse(service.enabled)
        XCTAssertTrue(service.report.message.contains("高功率能力"))
    }

    func testBackgroundOrUnknownLaunchDoesNotInspectRenewOrStartSchedules() async throws {
        for launch in [Optional(false), nil] {
            let domain = "SuperIsland.BM1.QueryLaunch.\(UUID())"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let transport = BatteryTestTransport()
            var starts = 0
            let service = BatteryManagementService(defaults: defaults, client: transport,
                telemetryReader: { var s = BatteryTelemetry(); s.hasBattery = true; s.level = 80; s.onAC = true; return s },
                conflictChecker: { nil }, scheduleStarter: { starts += 1 })
            defer { service.shutdown() }
            service.start(automaticallyEnable: BatteryStartupContext.automaticallyEnables(defaultLaunch: launch))
            service.retry()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertFalse(service.enabled)
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(transport.inspectCount, 0)
            XCTAssertTrue(transport.renewals.isEmpty)
            XCTAssertEqual(transport.releases, 0)
            XCTAssertEqual(transport.registered, 0)
        }
    }

    func testExplicitStatusRefreshReadsHelperWithoutEnablingControl() async {
        let transport = BatteryTestTransport(), service = service(transport)
        service.start(automaticallyEnable: false)
        defer { service.shutdown() }
        await service.recheckStatus()
        XCTAssertEqual(transport.inspectCount, 1)
        XCTAssertTrue(service.report.available)
        XCTAssertEqual(service.report.mechanism, transport.mechanism)
        XCTAssertTrue(service.report.message.contains("充电控制保持关闭"))
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertEqual(transport.releases, 0)
        XCTAssertEqual(transport.registered, 0)
        XCTAssertEqual(service.preferences.limit, 80)
    }

    func testRepeatedStatusRefreshDoesNotAcknowledgeForeignFaultOrRecovery() async {
        let transport = BatteryTestTransport(), service = service(transport)
        service.start(automaticallyEnable: false)
        defer { service.shutdown() }
        var report = BatteryControlReport()
        report.protocolVersion = BatteryControlReport.currentProtocolVersion
        report.recoveryPending = true; report.requiresManualRetry = true
        report.message = "other recovery is pending"
        transport.inspectReport = report
        await service.recheckStatus()
        await service.recheckStatus()
        XCTAssertEqual(transport.inspectCount, 2)
        XCTAssertTrue(service.report.recoveryPending)
        XCTAssertEqual(service.report.requiresManualRetry, true)
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertEqual(transport.releases, 0)
    }

    func testExplicitStatusRefreshRejectsMissingPermissionAndIncompatibleReply() async {
        let transport = BatteryTestTransport(), service = service(transport)
        transport.authorization = .requiresApproval
        await service.recheckStatus()
        XCTAssertEqual(transport.inspectCount, 0)
        XCTAssertFalse(service.report.available)
        XCTAssertEqual(transport.registered, 0)
        transport.authorization = .enabled
        transport.protocolVersion = nil
        await service.recheckStatus()
        XCTAssertFalse(service.report.available)
        XCTAssertTrue(service.report.message.contains("版本不兼容"))
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.renewals.isEmpty)
    }

    func testExplicitStatusRefreshExposesFailureWithoutStartingRecovery() async {
        let transport = BatteryTestTransport(), service = service(transport)
        transport.inspectReply = { throw BatteryControlError.unavailable("inspection disconnected") }
        await service.recheckStatus()
        XCTAssertFalse(service.busy)
        XCTAssertFalse(service.report.available)
        XCTAssertTrue(service.report.message.contains("inspection disconnected"))
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertEqual(transport.releases, 0)
    }

    func testLateStatusRefreshCannotOverrideExplicitOffOrShutdown() async throws {
        for shuttingDown in [false, true] {
            let transport = BatteryTestTransport(), service = service(transport)
            var held: CheckedContinuation<(Bool, BatteryControlReport), Error>?
            transport.inspectReply = { try await withCheckedThrowingContinuation { held = $0 } }
            let pending = Task { await service.recheckStatus() }
            for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
            let reply = try XCTUnwrap(held)
            await service.recheckStatus() // Busy: no overlapping query.
            XCTAssertEqual(transport.inspectCount, 1)
            if shuttingDown { service.shutdown() } else { service.setEnabled(false) }
            var stale = BatteryControlReport(); stale.available = true
            stale.protocolVersion = BatteryControlReport.currentProtocolVersion
            stale.message = "stale inspection"
            reply.resume(returning: (true, stale))
            await pending.value
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(service.enabled)
            XCTAssertFalse(service.report.message.contains("stale inspection"))
            XCTAssertTrue(transport.renewals.isEmpty)
            XCTAssertEqual(transport.releases, 0)
        }
    }

    func testExplicitEnableDuringStatusRefreshIsNotLost() async throws {
        let transport = BatteryTestTransport(), service = service(transport)
        var held: CheckedContinuation<(Bool, BatteryControlReport), Error>?
        transport.inspectReply = { try await withCheckedThrowingContinuation { held = $0 } }
        let pending = Task { await service.recheckStatus() }
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        let reply = try XCTUnwrap(held)
        service.setEnabled(true)
        transport.inspectReply = nil
        var stale = BatteryControlReport(); stale.message = "stale inspection"
        reply.resume(returning: (true, stale))
        await pending.value
        for _ in 0..<100 where !service.enabled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(service.enabled)
        XCTAssertEqual(transport.renewals.count, 1)
        XCTAssertEqual(transport.renewals.first?.preferences.limit, 80)
        XCTAssertFalse(service.report.message.contains("stale inspection"))
        service.shutdown()
    }

    func testNativeRecheckButtonRefreshesDisabledController() async throws {
        let transport = BatteryTestTransport(), service = service(transport)
        service.start(automaticallyEnable: false)
        defer { service.shutdown() }
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service)
            .padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "重新检查") != nil }
        try probe.press(title: "重新检查")
        try await probe.wait { probe.text.contains("充电控制保持关闭") }
        XCTAssertEqual(transport.inspectCount, 1)
        XCTAssertTrue(probe.text.contains(transport.mechanism))
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertEqual(transport.releases, 0)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/bm1-readonly-status-refresh/native-recheck.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
    }

    func testDeferredLaunchReopenWaitsForControlBeforeStartingSchedules() async throws {
        let domain = "SuperIsland.BM1.QueryReopen.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let transport = BatteryTestTransport(); transport.holdRenewal = true
        var starts = 0
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { var s = BatteryTelemetry(); s.hasBattery = true; s.level = 80; s.onAC = true; return s },
            conflictChecker: { nil }, scheduleStarter: { starts += 1 })
        defer { service.shutdown() }
        service.start(automaticallyEnable: false)
        service.start(automaticallyEnable: true)
        for _ in 0..<100 where transport.held == nil { await Task.yield() }
        XCTAssertNotNil(transport.held)
        XCTAssertEqual(starts, 0, "A due task must not run before startup control is ready")
        var report = BatteryControlReport(); report.available = true
        transport.held?.resume(returning: (true, report)); transport.held = nil
        for _ in 0..<100 where starts == 0 { await Task.yield() }
        XCTAssertTrue(service.enabled)
        XCTAssertEqual(starts, 1)
        service.start(automaticallyEnable: true)
        XCTAssertEqual(transport.renewals.count, 1)
    }

    func testReopenCannotUndoManualDisableInBackgroundStartedProcess() async throws {
        let domain = "SuperIsland.BM1.QueryDisable.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let transport = BatteryTestTransport()
        var starts = 0
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { var s = BatteryTelemetry(); s.hasBattery = true; s.level = 80; s.onAC = true; return s },
            conflictChecker: { nil }, scheduleStarter: { starts += 1 })
        defer { service.shutdown() }
        service.start(automaticallyEnable: false)
        service.setEnabled(false)
        service.start(automaticallyEnable: true)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(service.enabled); XCTAssertTrue(transport.renewals.isEmpty)
        XCTAssertEqual(starts, 0)
        service.setEnabled(true)
        for _ in 0..<100 where starts == 0 { await Task.yield() }
        XCTAssertTrue(service.enabled); XCTAssertEqual(starts, 1)
    }

    func testConfirmedSameBuildLaunchFailureRebindsOnceAndKeepsApprovalRetry() async throws {
        let name = "BM1.RebindOnce.\(UUID())", key = "batteryManagement.helperRegistrationBuild"
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: key)
        let registrar = BatteryTestRegistration(); registrar.failedLaunch = true
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        do { try await client.register(); XCTFail("Approval expected") } catch {}
        XCTAssertEqual(registrar.events, ["unregister", "register"])
        XCTAssertEqual(defaults.string(forKey: "batteryManagement.helperLaunchRepairAttemptBuild"), "9")
        registrar.status = .enabled; registrar.requiresApproval = false
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register()
        XCTAssertEqual(registrar.events, ["unregister", "register", "register"])
    }
    func testApprovalPendingAndUnknownLaunchNeverCauseARepair() async throws {
        for status in [SMAppService.Status.enabled, .requiresApproval, .notRegistered] {
            let name = "BM1.RebindUnknown.\(UUID())", defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
            let registrar = BatteryTestRegistration(); registrar.requiresApproval = false; registrar.status = status
            registrar.probe = { if registrar.status == .requiresApproval { XCTFail("Approval wait is not a failed launch") }; return false }
            try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register()
            XCTAssertEqual(registrar.events, ["register"])
            XCTAssertNil(defaults.string(forKey: "batteryManagement.helperLaunchRepairAttemptBuild"))
        }
    }
    func testInvalidatedUnregisteredJobCanRepairOnlyWithIndependentFailureEvidence() async throws {
        for status in [SMAppService.Status.notRegistered, .notFound] {
            let name = "BM1.InvalidatedStatus.\(UUID())", defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
            let registrar = BatteryTestRegistration(); registrar.status = status; registrar.failedLaunch = true
            do { try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register(); XCTFail("Approval expected") } catch {}
            XCTAssertEqual(registrar.events, ["unregister", "register"])
            XCTAssertEqual(defaults.string(forKey: "batteryManagement.helperLaunchRepairAttemptBuild"), "9")
            registrar.status = .enabled; registrar.requiresApproval = false
            try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register()
            XCTAssertEqual(registrar.events, ["unregister", "register", "register"])
        }
    }
    func testPendingApprovalIsNotInspectedOrUnregisteredEvenWhenFailureFlagExists() async throws {
        let name = "BM1.PendingApproval.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.status = .requiresApproval
        registrar.probe = { XCTFail("Do not probe a pending approval as an invalidation"); return true }
        do { try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register(); XCTFail("Approval expected") } catch {}
        XCTAssertEqual(registrar.events, ["register"])
        XCTAssertNil(defaults.string(forKey: "batteryManagement.helperLaunchRepairAttemptBuild"))
    }
    func testChangedReceiptWhileProbeYieldsCannotBeOverwritten() async throws {
        let name = "BM1.RebindRace.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.requiresApproval = false
        registrar.probe = { defaults.set("newer", forKey: "batteryManagement.helperRegistrationBuild"); return true }
        do { try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register(); XCTFail("Changed receipt must abort") } catch {}
        XCTAssertTrue(registrar.events.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "batteryManagement.helperRegistrationBuild"), "newer")
    }
    func testApprovalStateChangingDuringProbeDoesNotUnregister() async throws {
        let name = "BM1.RebindApprovalRace.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.requiresApproval = false
        registrar.probe = { registrar.status = .requiresApproval; return true }
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register()
        XCTAssertEqual(registrar.events, ["register"])
    }
    func testConcurrentRegisterCannotRepeatARebind() async throws {
        let name = "BM1.RebindConcurrent.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.requiresApproval = false
        var pending: CheckedContinuation<Bool, Never>?
        registrar.probe = { await withCheckedContinuation { pending = $0 } }
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        let first = Task { try await client.register() }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        do { try await client.register(); XCTFail("Concurrent registration must reject") } catch {}
        pending?.resume(returning: true); pending = nil
        try await first.value
        XCTAssertEqual(registrar.events, ["unregister", "register"])
    }
    func testCancellationDuringProbeDoesNotUnregisterOrMarkRepairAttempt() async throws {
        let name = "BM1.RebindCancelled.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); var pending: CheckedContinuation<Bool, Never>?
        registrar.probe = { await withCheckedContinuation { pending = $0 } }
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        let task = Task { try await client.register() }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        task.cancel(); pending?.resume(returning: true); pending = nil
        do { try await task.value; XCTFail("Cancelled registration must reject") } catch {}
        XCTAssertTrue(registrar.events.isEmpty)
        XCTAssertNil(defaults.string(forKey: "batteryManagement.helperLaunchRepairAttemptBuild"))
    }
    func testUnregisterFailureCannotLoopSameBuildLaunchRepair() async throws {
        let name = "BM1.RebindFailed.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.failedLaunch = true
        registrar.unregisterError = NSError(domain: NSCocoaErrorDomain, code: 1)
        do { try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register(); XCTFail("Unregister must fail") } catch {}
        XCTAssertEqual(registrar.events, ["unregister"])
        registrar.unregisterError = nil; registrar.requiresApproval = false
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register()
        XCTAssertEqual(registrar.events, ["unregister", "register"])
    }
    func testRepairRecordSaveFailureCannotUnregister() async throws {
        let name = "BM1.RebindFlush.\(UUID())", defaults = BatteryRepairUnflushedDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.failedLaunch = true
        do { try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register(); XCTFail("Unconfirmed persistence must abort before unregister") } catch {}
        XCTAssertTrue(registrar.events.isEmpty)
    }
    func testTwoClientsShareOnePersistentRepairAttempt() async throws {
        let name = "BM1.RebindTwoClients.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("9", forKey: "batteryManagement.helperRegistrationBuild")
        let registrar = BatteryTestRegistration(); registrar.requiresApproval = false
        registrar.probe = { await Task.yield(); return true }
        let first = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        let second = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        async let a: Void = first.register()
        async let b: Void = second.register()
        _ = try await (a, b)
        XCTAssertEqual(registrar.events.filter { $0 == "unregister" }.count, 1)
        XCTAssertEqual(registrar.events.filter { $0 == "register" }.count, 2)
    }
    func testFailureAppearingOnlyAfterRegisterIsRepairedWithoutAnotherInvocation() async throws {
        let name = "BM1.RebindPostRegister.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered
        registrar.requiresApproval = false; registrar.failedLaunch = true
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register()
        XCTAssertEqual(registrar.events, ["register", "unregister", "register"])
        XCTAssertEqual(defaults.string(forKey: "batteryManagement.helperLaunchRepairAttemptBuild"), "9")
    }
    func testPostRegistrationProbeCannotOverwriteANewerReceipt() async throws {
        let name = "BM1.RebindPostRace.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered; registrar.requiresApproval = false
        registrar.probe = { defaults.set("newer", forKey: "batteryManagement.helperRegistrationBuild"); return true }
        do { try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9").register(); XCTFail("Changed receipt must abort") } catch {}
        XCTAssertEqual(registrar.events, ["register"])
        XCTAssertEqual(defaults.string(forKey: "batteryManagement.helperRegistrationBuild"), "newer")
    }
    func testApprovalRetryAndRelaunchDoNotUnregisterTheApprovedRecord() async throws {
        let domain = "SuperIsland.BM1.RegistrationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let registrar = BatteryTestRegistration()
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        do { try await client.register(); XCTFail("Expected system approval") } catch {}
        registrar.requiresApproval = false; registrar.status = .enabled
        try await client.register()
        let relaunched = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "9")
        try await relaunched.register()
        XCTAssertEqual(registrar.events, ["unregister", "register", "register", "register"])
        let updated = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "10")
        try await updated.register()
        XCTAssertEqual(Array(registrar.events.suffix(2)), ["unregister", "register"])
    }
    func testChangedBuildRefreshesOldReceiptEvenWhenSystemSaysNotRegistered() async throws {
        let domain = "SuperIsland.BM1.StaleRegistration.\(UUID())", key = "batteryManagement.helperRegistrationBuild"
        let defaults = UserDefaults(suiteName: domain)!; defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("old-build", forKey: key)
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered; registrar.requiresApproval = false
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build")
        try await client.register()
        XCTAssertEqual(registrar.events, ["unregister", "register"])
        XCTAssertEqual(defaults.string(forKey: key), "new-build")
    }
    func testFailedOldRecordRefreshDoesNotAdvanceReceiptOrSubmitRegistration() async throws {
        let domain = "SuperIsland.BM1.FailedRefresh.\(UUID())", key = "batteryManagement.helperRegistrationBuild"
        let defaults = UserDefaults(suiteName: domain)!; defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("old-build", forKey: key)
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered; registrar.requiresApproval = false
        registrar.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build")
        do { try await client.register(); XCTFail("Refresh failure must be visible") } catch {}
        XCTAssertEqual(registrar.events, ["unregister"]); XCTAssertEqual(defaults.string(forKey: key), "old-build")
        registrar.unregisterError = nil
        try await client.register()
        XCTAssertEqual(registrar.events, ["unregister", "unregister", "register"])
        XCTAssertEqual(defaults.string(forKey: key), "new-build")
    }
    func testOnlyDocumentedNotFoundFromUnregisteredServiceIsIdempotent() async throws {
        let domain = "SuperIsland.BM1.AlreadyRemoved.\(UUID())", key = "batteryManagement.helperRegistrationBuild"
        let defaults = UserDefaults(suiteName: domain)!; defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("old-build", forKey: key)
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered; registrar.requiresApproval = false
        registrar.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorJobNotFound))
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build").register()
        XCTAssertEqual(registrar.events, ["unregister", "register"])
        XCTAssertEqual(defaults.string(forKey: key), "new-build")
    }
    func testUnregisterErrorDomainAndLiveStatusCannotBeIgnored() async throws {
        for wrongDomain in [true, false] {
            let domain = "SuperIsland.BM1.RefreshErrors.\(UUID())", key = "batteryManagement.helperRegistrationBuild"
            let defaults = UserDefaults(suiteName: domain)!; defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set("old-build", forKey: key)
            let registrar = BatteryTestRegistration(); registrar.requiresApproval = false
            registrar.status = wrongDomain ? .notRegistered : .enabled
            registrar.unregisterError = NSError(domain: wrongDomain ? NSCocoaErrorDomain : "SMAppServiceErrorDomain",
                                                 code: Int(kSMErrorJobNotFound))
            do {
                try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build").register()
                XCTFail("Unverified refresh cannot register")
            } catch {}
            XCTAssertEqual(registrar.events, ["unregister"]); XCTAssertEqual(defaults.string(forKey: key), "old-build")
        }
    }
    func testApprovalRetryWithTransientNotRegisteredDoesNotRefreshAgain() async throws {
        let domain = "SuperIsland.BM1.TransientApproval.\(UUID())", key = "batteryManagement.helperRegistrationBuild"
        let defaults = UserDefaults(suiteName: domain)!; defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("old-build", forKey: key)
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered
        let first = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build")
        do { try await first.register(); XCTFail("Expected approval") } catch {}
        XCTAssertEqual(defaults.string(forKey: key), "new-build")
        registrar.status = .notRegistered; registrar.requiresApproval = false
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build").register()
        XCTAssertEqual(registrar.events, ["unregister", "register", "register"])
    }
    func testFirstInstallWithoutReceiptDoesNotUnregister() async throws {
        let domain = "SuperIsland.BM1.FirstRegistration.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!; defer { defaults.removePersistentDomain(forName: domain) }
        let registrar = BatteryTestRegistration(); registrar.status = .notRegistered; registrar.requiresApproval = false
        try await BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new-build").register()
        XCTAssertEqual(registrar.events, ["register"])
    }
    func testQuitDuringRegistrationCannotReactivateControl() async throws {
        let transport = BatteryTestTransport()
        let service = service(transport)
        await service.attemptStartupForTesting()
        transport.holdRegistration = true
        let authorization = Task { await service.authorize() }
        for _ in 0..<100 where transport.heldRegistration == nil { try await Task.sleep(for: .milliseconds(5)) }
        let termination = Task { await service.prepareForTermination() }
        await Task.yield()
        transport.heldRegistration?.resume(); transport.heldRegistration = nil
        await authorization.value
        let safeToQuit = await termination.value
        XCTAssertTrue(safeToQuit); XCTAssertFalse(service.enabled)
        XCTAssertEqual(transport.renewals.count, 1)
    }
    func testRegistrationRefreshCannotRemoveAHelperWithUnrestoredChanges() async {
        let transport = BatteryTestTransport()
        let service = service(transport)
        await service.attemptStartupForTesting()
        transport.failRelease = true
        await service.authorize()
        XCTAssertEqual(transport.registered, 0)
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(service.report.recoveryPending)
    }
    func testRefreshRestoresFirstAndBlocksControlUntilRegistrationFinishes() async throws {
        let transport = BatteryTestTransport()
        let service = service(transport)
        await service.attemptStartupForTesting()
        transport.holdRegistration = true
        let authorization = Task { await service.authorize() }
        for _ in 0..<100 where transport.heldRegistration == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(transport.heldRegistration)
        XCTAssertTrue(service.authorizing); XCTAssertFalse(service.canControl)
        XCTAssertEqual(transport.releases, 1)
        service.setEnabled(true); service.retry()
        XCTAssertThrowsError(try service.updatePreferences { $0.limit = 85 })
        XCTAssertEqual(transport.renewals.count, 1)
        transport.heldRegistration?.resume(); transport.heldRegistration = nil
        await authorization.value
        for _ in 0..<100 where !service.enabled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(service.authorizing); XCTAssertTrue(service.enabled)
        XCTAssertEqual(transport.renewals.count, 2)
    }
    func testLatchedControlFaultRequiresAnExplicitRetry() async throws {
        let transport = BatteryTestTransport(); transport.controlFault = true
        let service = service(transport)
        await service.attemptStartupForTesting()
        XCTAssertFalse(service.enabled); XCTAssertTrue(transport.renewals.isEmpty)
        // Ordinary refresh/startup cannot quietly reactivate a failed backend.
        await service.attemptStartupForTesting()
        XCTAssertTrue(transport.renewals.isEmpty)
        transport.controlFault = false
        service.retry()
        for _ in 0..<100 where !service.enabled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(service.enabled); XCTAssertEqual(transport.renewals.count, 1)
    }
    func testRenewResponseFaultStopsEvenWhenHeartbeatSkippedInspection() async throws {
        let transport = BatteryTestTransport(); let service = service(transport)
        await service.attemptStartupForTesting()
        XCTAssertTrue(service.enabled)
        let old = try XCTUnwrap(transport.renewals.last)
        let id = UUID()
        transport.renewalReply = { _ in
            var r = BatteryControlReport(); r.available = true; r.requiresManualRetry = true
            r.manualRetryID = id; r.leaseHeldByRequester = false
            return (true, r) // Even a nominally successful RPC cannot hide fault.
        }
        let before = transport.inspectCount
        await service.attemptStartupForTesting()
        XCTAssertEqual(transport.inspectCount, before)
        XCTAssertFalse(service.enabled)
        XCTAssertEqual(service.report.manualRetryID, id)
        XCTAssertNil(transport.renewals.last?.acknowledgedFaultID)
        XCTAssertEqual(transport.renewals.last?.operationID, old.operationID)
        var fault = BatteryControlReport(); fault.available = true; fault.requiresManualRetry = true
        fault.manualRetryID = id; fault.mechanism = "SMC CHTE"
        transport.inspectReport = fault
        transport.renewalReply = { request in
            XCTAssertEqual(request.acknowledgedFaultID, id)
            XCTAssertNotEqual(request.operationID, old.operationID)
            var r = BatteryControlReport(); r.available = true; r.mechanism = "SMC CHTE"
            return (true, r)
        }
        service.retry()
        for _ in 0..<100 where !service.enabled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(service.enabled)
        service.shutdown()
    }
    func testOlderOrUnknownHelperCannotReceiveAControlRequest() async throws {
        var oldReport = BatteryControlReport()
        oldReport.protocolVersion = nil
        XCTAssertNil(try JSONDecoder().decode(BatteryControlReport.self, from: JSONEncoder().encode(oldReport)).protocolVersion)
        let incompatibleVersions: [Int?] = [nil] + (1..<BatteryControlReport.currentProtocolVersion).map { Optional($0) } + [BatteryControlReport.currentProtocolVersion + 1]
        for version in incompatibleVersions {
            let transport = BatteryTestTransport(); transport.protocolVersion = version
            let service = service(transport)
            await service.attemptStartupForTesting()
            XCTAssertFalse(service.enabled)
            XCTAssertTrue(transport.renewals.isEmpty)
            XCTAssertEqual(transport.releases, 0)
            XCTAssertTrue(service.report.message.contains("版本不兼容"))
        }
    }
    func testNativeLimitCannotAcceptUnsupportedLowTargetOrHeatProtection() async {
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Charge Limit"
        let service = service(transport); await service.attemptStartupForTesting()
        XCTAssertThrowsError(try service.updatePreferences { $0.allowLowLimit = true; $0.limit = 79 })
        XCTAssertThrowsError(try service.updatePreferences { $0.heatProtection = true })
        XCTAssertEqual(service.preferences.limit, 80); XCTAssertFalse(service.preferences.heatProtection)
    }
    func testNativePauseBelowEightyDoesNotMutateModeOrSubmitARequest() async {
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Charge Limit"
        let service = service(transport); await service.attemptStartupForTesting()
        do { _ = try await service.execute(mode: .paused); XCTFail("Unsupported native pause cannot report success") } catch {}
        XCTAssertEqual(service.mode, .automatic); XCTAssertEqual(transport.renewals.count, 1)
    }
    private func service(_ transport: BatteryTestTransport, conflict: String? = nil, telemetry: (() -> BatteryTelemetry)? = nil) -> BatteryManagementService {
        let domain = "SuperIsland.BM1.ServiceTests.\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        return BatteryManagementService(defaults: UserDefaults(suiteName: domain)!, client: transport, telemetryReader: telemetry ?? {
            var s = BatteryTelemetry(); s.hasBattery = true; s.level = 60; s.onAC = true; s.temperature = 30; return s
        }, conflictChecker: { conflict })
    }
    func testAutomaticStartNeverRegistersOrBypassesMissingAuthorization() async {
        let transport = BatteryTestTransport(); transport.authorization = .notRegistered
        let service = service(transport)
        await service.attemptStartupForTesting()
        XCTAssertFalse(service.enabled); XCTAssertEqual(transport.registered, 0); XCTAssertTrue(transport.renewals.isEmpty)
    }
    func testPendingAuthorizationErrorSurvivesAnAutomaticRefresh() async {
        let transport = BatteryTestTransport(); transport.authorization = .notFound
        transport.registrationFailure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let domain = "SuperIsland.BM1.AuthorizationTests.\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        var opened = 0
        let service = BatteryManagementService(defaults: UserDefaults(suiteName: domain)!, client: transport,
            telemetryReader: { var s = BatteryTelemetry(); s.hasBattery = true; s.level = 80; s.onAC = true; return s },
            conflictChecker: { nil }, authorizationOpener: { opened += 1 })
        await service.authorize()
        await service.attemptStartupForTesting()
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(service.report.message.contains("系统授权未完成"))
        XCTAssertEqual(service.report.message.components(separatedBy: "系统授权未完成").count - 1, 1,
            "An automatic refresh must retain the error exactly once")
        XCTAssertTrue(service.authorizationDescription.contains("等待注册"))
        XCTAssertFalse(service.enabled); XCTAssertTrue(transport.renewals.isEmpty)
    }
    func testConflictingToolPreventsEvenAnAuthorizedRenewal() async {
        let transport = BatteryTestTransport(), service = service(transport, conflict: "AlDente")
        await service.attemptStartupForTesting()
        XCTAssertFalse(service.enabled); XCTAssertTrue(transport.renewals.isEmpty); XCTAssertTrue(service.report.message.contains("AlDente"))
    }
    func testFailedWriteAttemptsRestorationAndKeepsFailureVisible() async {
        let transport = BatteryTestTransport(); transport.failRenewal = true
        let service = service(transport)
        await service.attemptStartupForTesting()
        XCTAssertFalse(service.enabled); XCTAssertEqual(transport.releases, 1)
        XCTAssertTrue(service.report.message.contains("write failed")); XCTAssertFalse(service.report.recoveryPending)
    }
    func testTerminationWaitsForPendingRecoveryAndPreventsNewControl() async throws {
        let transport = BatteryTestTransport(), service = service(transport)
        await service.attemptStartupForTesting()
        transport.pendingReleaseCount = 3
        let termination = Task { await service.prepareForTermination() }
        for _ in 0..<100 where transport.releases < 2 { await Task.yield() }
        XCTAssertFalse(service.canControl)
        let renewals = transport.renewals.count
        service.setEnabled(true); service.retry()
        XCTAssertThrowsError(try service.updatePreferences { $0.limit = 85 })
        let safe = await termination.value
        XCTAssertTrue(safe); XCTAssertFalse(service.shouldPrepareForTermination)
        XCTAssertEqual(transport.renewals.count, renewals)
        XCTAssertEqual(transport.releases, 4)
    }
    func testAttentionRecoveryBlocksQuitWithoutContinuingRetryLoop() async {
        let transport = BatteryTestTransport(), service = service(transport)
        await service.attemptStartupForTesting()
        transport.pendingReleaseCount = 100; transport.pendingReleasePhase = .attention
        let safe = await service.prepareForTermination()
        XCTAssertFalse(safe); XCTAssertTrue(service.shouldPrepareForTermination)
        XCTAssertEqual(transport.releases, 2, "Do not spend the normal-quit window retrying an attention state")
    }
    func testFailedRestorationDoesNotPermitNormalTermination() async {
        let transport = BatteryTestTransport(), service = service(transport)
        await service.attemptStartupForTesting()
        transport.failRelease = true
        let safe = await service.prepareForTermination()
        XCTAssertFalse(safe); XCTAssertTrue(service.shouldPrepareForTermination); XCTAssertTrue(service.report.recoveryPending)
    }
    func testNewLimitWinsOverLateStartupResponse() async throws {
        let transport = BatteryTestTransport(); transport.holdRenewal = true
        let service = service(transport)
        let startup = Task { await service.attemptStartupForTesting() }
        while transport.held == nil { await Task.yield() }
        try service.updatePreferences { $0.limit = 90 }
        var old = BatteryControlReport(); old.available = true; old.registeredTarget = 80; old.mode = .topUp
        transport.held?.resume(returning: (true, old)); transport.held = nil
        await startup.value
        XCTAssertEqual(transport.renewals.map(\.preferences.limit), [80, 90])
        XCTAssertEqual(service.preferences.limit, 90); XCTAssertEqual(service.report.registeredTarget, 90)
        XCTAssertEqual(service.mode, .automatic, "Late callbacks cannot replace the current mode")
    }
    func testTurningOffDuringRenewalRestoresRatherThanReenabling() async {
        let transport = BatteryTestTransport(); transport.holdRenewal = true
        let service = service(transport)
        let startup = Task { await service.attemptStartupForTesting() }
        while transport.held == nil { await Task.yield() }
        service.setEnabled(false)
        var old = BatteryControlReport(); old.available = true
        transport.held?.resume(returning: (true, old)); transport.held = nil
        await startup.value
        XCTAssertFalse(service.enabled); XCTAssertEqual(transport.releases, 1)
        XCTAssertFalse(service.shouldPrepareForTermination)
    }
}


@MainActor
final class BatteryEnergySuggestionGuardTests: XCTestCase {
    private let lastPromptKey = "energy.lowPowerSuggestion.lastPromptAt"
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func testManagedTaskSuppressesBothReasonsWithoutConsumingCooldownThenNormalUnplugCanPrompt() async {
        let domain = "SuperIsland.BM1.EnergyGuard.\(UUID())"
        // Every test owns a separate disposable domain; no application settings change.
        let isolated = UserDefaults(suiteName: domain)!
        defer { isolated.removePersistentDomain(forName: domain) }
        var managed = true, shown = 0, handled = 0
        let presenter = EnergySuggestionPresenter(defaults: isolated, context: {
            .init(lowPowerEnabled: false, doNotAskAgain: false, managedBatteryTask: managed)
        }, present: { _ in shown += 1; return .alertSecondButtonReturn }, handleResponse: { _ in handled += 1 })
        presenter.suggestLowPower(reason: .battery); presenter.suggestLowPower(reason: .sustainedActivity)
        await drainMainQueue()
        XCTAssertEqual(shown, 0); XCTAssertNil(isolated.object(forKey: lastPromptKey))
        managed = false; presenter.suggestLowPower(reason: .battery)
        await drainMainQueue()
        XCTAssertEqual(shown, 1); XCTAssertEqual(handled, 1)
        XCTAssertGreaterThan(isolated.double(forKey: lastPromptKey), 0)
    }
    func testTaskStartingAfterQueueingCancelsPromptWithoutConsumingCooldown() async {
        let domain = "SuperIsland.BM1.EnergyRace.\(UUID())"
        let isolated = UserDefaults(suiteName: domain)!
        defer { isolated.removePersistentDomain(forName: domain) }
        var managed = false, shown = 0
        let presenter = EnergySuggestionPresenter(defaults: isolated, context: {
            .init(lowPowerEnabled: false, doNotAskAgain: false, managedBatteryTask: managed)
        }, present: { _ in shown += 1; return .alertSecondButtonReturn }, handleResponse: { _ in })
        presenter.suggestLowPower(reason: .battery)
        managed = true
        await drainMainQueue()
        XCTAssertEqual(shown, 0); XCTAssertNil(isolated.object(forKey: lastPromptKey))
        managed = false; presenter.suggestLowPower(reason: .battery)
        await drainMainQueue(); XCTAssertEqual(shown, 1)
    }
    func testQueuedUserOptOutAndExistingLowPowerAreRespected() async {
        for lowPower in [false, true] {
            let domain = "SuperIsland.BM1.EnergyOptOut.\(UUID())"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            var optedOut = false, low = false, shown = 0
            let presenter = EnergySuggestionPresenter(defaults: defaults, context: {
                .init(lowPowerEnabled: low, doNotAskAgain: optedOut, managedBatteryTask: false)
            }, present: { _ in shown += 1; return .alertFirstButtonReturn }, handleResponse: { _ in XCTFail("No user action should be fabricated") })
            presenter.suggestLowPower(reason: .battery)
            if lowPower { low = true } else { optedOut = true }
            await drainMainQueue()
            XCTAssertEqual(shown, 0); XCTAssertNil(defaults.object(forKey: lastPromptKey))
        }
    }
    func testCooldownAndUserChoiceArePreserved() async {
        let domain = "SuperIsland.BM1.EnergyCooldown.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let previous = Date().timeIntervalSince1970 - 3600
        defaults.set(previous, forKey: lastPromptKey)
        var shown = 0, responses: [NSApplication.ModalResponse] = []
        let presenter = EnergySuggestionPresenter(defaults: defaults, context: {
            .init(lowPowerEnabled: false, doNotAskAgain: false, managedBatteryTask: false)
        }, present: { _ in shown += 1; return .alertThirdButtonReturn }, handleResponse: { responses.append($0) })
        presenter.suggestLowPower(reason: .battery); await drainMainQueue()
        XCTAssertEqual(shown, 0); XCTAssertEqual(defaults.double(forKey: lastPromptKey), previous)
        defaults.set(previous - 86400, forKey: lastPromptKey)
        presenter.suggestLowPower(reason: .battery); await drainMainQueue()
        XCTAssertEqual(shown, 1); XCTAssertEqual(responses, [.alertThirdButtonReturn])
        presenter.suggestLowPower(reason: .battery); await drainMainQueue()
        XCTAssertEqual(shown, 1)
    }
    func testLeaseHeartbeatFiresInNativeMenuTrackingAndModalModes() {
        for mode in [RunLoop.Mode.eventTracking, .modalPanel] {
            let observations = OSAllocatedUnfairLock(initialState: [String]())
            let cfMode = CFRunLoopMode(rawValue: mode.rawValue as CFString)
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), cfMode)
            let timer = BatteryManagementService.makeLeaseHeartbeat(interval: 0.02) {
                let current = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()).map { $0.rawValue as String } ?? "unknown"
                observations.withLock { $0.append(current) }
            }
            defer { timer.invalidate() }
            CFRunLoopRunInMode(cfMode, 0.1, false)
            let modes = observations.withLock { $0 }
            XCTAssertFalse(modes.isEmpty, "Native menu/modal modes must not starve lease renewal")
            XCTAssertTrue(modes.allSatisfy { $0 == mode.rawValue })
        }
    }
}

final class BatteryNativeReadProcessTests: XCTestCase {
    func testRealChildOutputIsReadAndDecoded() throws {
        let data = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "{\"schema\":1,\"value\":85}"])
        XCTAssertEqual(try BatteryNativeReadTransport.decode(data, query: .limit), 85)
    }
    func testFragmentedOutputWaitsForLaterReadableEvents() throws {
        let program = "import sys,time;sys.stdout.write('{\"schema\":1,');sys.stdout.flush();time.sleep(0.08);sys.stdout.write('\"value\":80}');sys.stdout.flush()"
        let data = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", program])
        XCTAssertEqual(try BatteryNativeReadTransport.decode(data, query: .limit), 80)
    }
    func testBlockedReadWorkerHasADeadlineAndItsOwnedProcessIsReaped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BM1ReadTimeout-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid.txt")
        let program = "import os,sys,time;open(sys.argv[1],'w').write(str(os.getpid()));time.sleep(10)"
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", program, pidFile.path], timeout: 0.4)) { error in
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1, "A timed-out owned worker must not remain alive")
        XCTAssertEqual(errno, ESRCH)
    }
    func testFullPipeCannotBlockTheDaemonAndOutputIsCapped() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["oversized"], maximumOutput: 128)) { error in
            XCTAssertTrue(error.localizedDescription.contains("过长"), "Overflow must not wait for a pipe-full timeout")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testUnknownMalformedAndOutOfRangeRepliesNeverBecomeNativeState() throws {
        for text in ["", "{}", "{\"schema\":2,\"value\":80}", "{\"schema\":1,\"value\":true}",
                     "{\"schema\":1,\"value\":79}", "{\"schema\":1,\"value\":101}",
                     "{\"schema\":1,\"value\":80,\"error\":\"unavailable\"}"] {
            XCTAssertThrowsError(try BatteryNativeReadTransport.decode(Data(text.utf8), query: .limit))
        }
        XCTAssertThrowsError(try BatteryNativeReadTransport.decode(Data("{\"schema\":1,\"value\":85}".utf8), query: .enabled))
        XCTAssertEqual(try BatteryNativeReadTransport.decode(Data("{\"schema\":1,\"value\":0}".utf8), query: .enabled), 0)
        XCTAssertThrowsError(try BatteryNativeReadTransport(executable: nil))
        XCTAssertThrowsError(try BatteryNativeReadTransport(executable: URL(fileURLWithPath: "/usr/bin/printf")))
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [], timeout: .infinity))
    }
}

@MainActor
private final class BatteryPanelAXProbe {
    let window: NSWindow
    let host: NSView
    init(window: NSWindow, host: NSView) { self.window = window; self.host = host }
    func string(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
    func nodes(allVisibleWindows: Bool = false) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(visit) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        if allVisibleWindows { NSApp.windows.filter(\.isVisible).forEach(visit) } else { visit(window) }
        return result
    }
    var text: String {
        nodes().flatMap { object in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { string(object, $0) } }.joined(separator: " ")
    }
    func button(title: String? = nil, identifier: String? = nil, allVisibleWindows: Bool = false) -> NSObject? {
        nodes(allVisibleWindows: allVisibleWindows).first { object in
            guard string(object, "accessibilityRole") == "AXButton" else { return false }
            if let identifier { return string(object, "accessibilityIdentifier") == identifier }
            return string(object, "accessibilityLabel") == title || string(object, "accessibilityTitle") == title
        }
    }
    func press(title: String? = nil, identifier: String? = nil, allVisibleWindows: Bool = false) throws {
        let object = try XCTUnwrap(button(title: title, identifier: identifier, allVisibleWindows: allVisibleWindows), "Missing native button \(title ?? identifier ?? "?")")
        if let button = object as? NSButton {
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { XCTFail("Native press unavailable"); return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
    // macOS remote alert elements can return false after dispatching AXPress.
    // Require the actual dialog/business transition rather than trusting that acknowledgment.
    func pressAlert(title: String, until ready: () -> Bool) async throws {
        let object = try XCTUnwrap(button(title: title, allVisibleWindows: true), "Missing native alert button \(title)")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { XCTFail("Native alert press unavailable"); return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        try await wait(ready)
    }
    func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Native view did not become ready: \(text)")
    }
}

final class BatteryDisplayCompletionTests: XCTestCase {
    func testLegacyDisplayDecodingPreservesExistingPreferencesAndSuppliesNewDefaults() throws {
        let data = Data(#"{"metrics":["voltage","temperature"],"showPercentage":false,"showAtStartup":false,"backgroundMetrics":true,"includeBackgroundProcesses":true,"consumerThreshold":7,"opacity":0.7,"rightClickSettings":false}"#.utf8)
        let value = try JSONDecoder().decode(BatteryDisplayPreferences.self, from: data)
        XCTAssertEqual(value.metrics, [.voltage, .temperature])
        XCTAssertFalse(value.showPercentage); XCTAssertFalse(value.showAtStartup)
        XCTAssertTrue(value.backgroundMetrics); XCTAssertTrue(value.includeBackgroundProcesses)
        XCTAssertEqual(value.consumerThreshold, 7); XCTAssertEqual(value.opacity, 0.7)
        XCTAssertEqual(value.rightClickAction, .same)
        XCTAssertEqual(value.averageMinutes, 15); XCTAssertEqual(value.popupFields, BatteryPopupField.allCases)
    }
    func testDisplayRoundTripPreservesEmptySelectionsAndOrder() throws {
        var value = BatteryDisplayPreferences()
        value.metrics = [.remaining, .current]; value.entryStatistics = [.power, .temperature, .percentage]
        value.popupFields = []; value.runtimeMode = .instant; value.averageMinutes = 60
        value.indicatorStyle = .ios; value.rightClickAction = .pause; value.refreshInterval = 20
        let decoded = try JSONDecoder().decode(BatteryDisplayPreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
    func testDisplayNormalizationBoundsAndDeduplicatesWithoutChangingOrder() {
        var value = BatteryDisplayPreferences()
        value.metrics = [.voltage, .voltage, .power, .health, .remaining, .cycles, .current, .adapter]
        value.entryStatistics = [.power, .power, .state]; value.popupFields = [.controls, .controls]
        value.indicatorSpacing = -4; value.refreshInterval = 100; value.averageMinutes = 9; value.opacity = .nan
        value.normalize()
        XCTAssertEqual(value.metrics, [.voltage, .power, .health, .remaining, .cycles, .current])
        XCTAssertEqual(value.entryStatistics, [.power, .state]); XCTAssertEqual(value.popupFields, [.controls])
        XCTAssertEqual(value.indicatorSpacing, 0); XCTAssertEqual(value.refreshInterval, 20)
        XCTAssertEqual(value.averageMinutes, 15); XCTAssertEqual(value.opacity, 1)
    }
    func testResetEntryDisplayDoesNotResetMetricsControlOrSamplingPreferences() {
        var value = BatteryDisplayPreferences()
        value.metrics = [.current]; value.entryStatistics = []; value.indicatorStyle = .colored
        value.refreshInterval = 20; value.indicatorSpacing = 19; value.popupFields = []
        value.resetEntryDisplay()
        XCTAssertEqual(value.entryStatistics, [.percentage, .state]); XCTAssertEqual(value.indicatorStyle, .native)
        XCTAssertEqual(value.metrics, [.current]); XCTAssertEqual(value.refreshInterval, 20)
        XCTAssertEqual(value.indicatorSpacing, 19); XCTAssertTrue(value.popupFields.isEmpty)
    }
    private func battery() -> BatteryTelemetry {
        var s = BatteryTelemetry(); s.hasBattery = true; s.onAC = false
        s.remainingCapacity = 4000; s.fullCapacity = 5000; s.voltage = 12; s.current = -1
        return s
    }
    func testRuntimeUsesRealChargeVoltageAndSelectedPower() {
        let s = battery()
        XCTAssertEqual(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .instant, average: nil), 240)
        XCTAssertEqual(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .average, average: .init(watts: -24, coverage: 30, dischargeOnly: true)), 120)
    }
    func testRuntimeUnavailableForUnknownPowerSupplyZeroPowerOrMissingCapacity() {
        var s = battery(); s.current = 0
        XCTAssertNil(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .instant, average: nil))
        s = battery(); s.onAC = true
        XCTAssertNil(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .instant, average: nil))
        s = battery(); s.remainingCapacity = nil
        XCTAssertNil(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .instant, average: nil))
        s = BatteryTelemetry(); s.hasBattery = true; s.voltage = 12; s.current = -1; s.remainingCapacity = 4000; s.fullCapacity = 5000
        XCTAssertNil(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .instant, average: nil))
    }
    func testRuntimeNeverMixesChargeTimeWithBatteryRuntimeOrMixedSignAverages() {
        var s = battery(); s.charging = true; s.onAC = true; s.minutesRemaining = 38
        XCTAssertEqual(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .average, average: nil), 38)
        s = battery()
        XCTAssertNil(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .average, average: .init(watts: -12, coverage: 30, dischargeOnly: false)))
        XCTAssertNil(BatteryRuntimeEstimate.minutes(snapshot: s, mode: .average, average: nil))
    }
    func testLongWindowStoresRealCoverageAndCanChangeSelectionWithoutFabrication() throws {
        var window = BatteryPowerWindow(window: 3600, maximumGap: 45)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        for t in stride(from: 0, through: 1800, by: 20) {
            var s = battery(); s.timestamp = start.addingTimeInterval(Double(t)); window.record(s)
        }
        let last = start.addingTimeInterval(1800)
        XCTAssertEqual(try XCTUnwrap(window.summary(at: last, window: 300)).coverage, 300)
        XCTAssertEqual(try XCTUnwrap(window.summary(at: last, window: 3600)).coverage, 1800)
        XCTAssertEqual(try XCTUnwrap(window.summary(at: last, window: 3600)).watts, -12)
        XCTAssertNil(window.summary(at: last.addingTimeInterval(46), window: 3600))
    }
    @MainActor
    func testNativeHiddenPopupContentRetainsSettingsAndRecoveryStatus() async throws {
        let name = "BatteryDisplayHidden.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let sample = battery(), transport = BatteryTestTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.updateDisplay { $0.popupFields = []; $0.metrics = [] }
        var opened = 0; service.openSettings = { opened += 1 }
        let host = NSHostingView(rootView: BatteryManagementPanel(service: service, initialSection: 1).padding(16).background(Color.black))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 624, height: 216), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.text.contains("此内容已在电池显示设置中隐藏") }
        XCTAssertNil(probe.button(title: "暂停充电"))
        XCTAssertTrue(probe.text.contains(service.report.message))
        try probe.press(title: "电池设置"); XCTAssertEqual(opened, 1)
        try probe.press(identifier: "battery-section-trend")
        try await probe.wait { probe.text.contains("此内容已在电池显示设置中隐藏") }
        XCTAssertTrue(transport.renewals.isEmpty)
    }
    @MainActor
    func testNativeDashboardUsesSelectedMetricsAndDisplayPageExposesConfirmedOptions() async throws {
        let name = "BatteryDisplayDashboard.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let sample = battery(), transport = BatteryTestTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.updateDisplay { $0.metrics = [.voltage, .current] }
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.text.contains("12.00 V") && probe.text.contains("-1.00 A") }
        XCTAssertFalse(probe.text.contains("循环次数"))
        try probe.press(title: "显示与面板")
        try await probe.wait { probe.text.contains("现有电池入口显示") && probe.text.contains("清除统计项") }
        XCTAssertTrue(probe.text.contains("电池图标样式")); XCTAssertTrue(probe.text.contains("读数更新间隔"))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/bm1-frontend-completion")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("display-settings.png"))
            }
        }
        try probe.press(title: "清除统计项")
        XCTAssertTrue(service.display.entryStatistics.isEmpty)
        try probe.press(title: "重置显示")
        XCTAssertEqual(service.display.entryStatistics, [.percentage, .state])
        XCTAssertTrue(transport.renewals.isEmpty)
    }
    @MainActor
    func testNativeSettingsManualModesUseSharedServiceAndCancelWithoutWriting() async throws {
        let name = "BatteryManualSettings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var sample = battery(); sample.level = 82; sample.onAC = true
        let transport = BatteryTestTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.attemptStartupForTesting()
        let original = service.preferences
        let host = NSHostingView(rootView: ScrollView {
            BatteryManagementSettingsView(service: service).padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        }.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "充电控制") != nil }
        try probe.press(title: "充电控制")
        try await probe.wait { probe.button(title: "放电…") != nil }
        for title in ["充满", "暂停充电", "恢复自动"] { XCTAssertNotNil(probe.button(title: title)) }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/bm1-frontend-completion/charge-settings-manual-modes.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: output)
        let before = transport.renewals.count
        try probe.press(title: "放电…")
        try await probe.wait { probe.button(title: "取消", allVisibleWindows: true) != nil }
        try probe.press(title: "取消", allVisibleWindows: true)
        try await probe.wait { probe.button(title: "开始放电", allVisibleWindows: true) == nil }
        XCTAssertEqual(transport.renewals.count, before)
        try probe.press(title: "充满")
        try await probe.wait { service.mode == .topUp && !service.busy }
        XCTAssertEqual(transport.renewals.last?.mode, .topUp)
        try probe.press(title: "恢复自动")
        try await probe.wait { service.mode == .automatic && !service.busy }
        try probe.press(title: "暂停充电")
        try await probe.wait { service.mode == .paused && !service.busy }
        try probe.press(title: "恢复充电")
        try await probe.wait { service.mode == .automatic && !service.busy }
        XCTAssertEqual(service.preferences, original)
        XCTAssertEqual(transport.renewals.last?.mode, .automatic)
    }
    @MainActor
    func testNativeNumericLowLimitPromptsWithoutWritingAndCalibrationDisablesInputs() async throws {
        let name = "BatteryNumericLimit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var sample = battery(); sample.level = 82; sample.onAC = true
        let transport = BatteryTestTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.attemptStartupForTesting()
        var settingsOpened = 0; service.openSettings = { settingsOpened += 1 }
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "充电控制") != nil }
        try probe.press(title: "充电控制")
        try await probe.wait { probe.button(title: "应用") != nil }
        func field() throws -> NSObject {
            try XCTUnwrap(probe.nodes().first { probe.string($0, "accessibilityIdentifier") == "battery-limit-number" && probe.string($0, "accessibilityRole") == "AXTextField" })
        }
        let initialRequests = transport.renewals.count
        for action in ["取消", "打开设置"] {
            let input = try field()
            let nativeField = try XCTUnwrap((input as? NSTextField) ?? ((input as? NSTextFieldCell)?.controlView as? NSTextField), "Numeric control must support native text editing: \(type(of: input))")
            nativeField.selectText(nil)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText("70", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            window.makeFirstResponder(nil)
            try await probe.wait { probe.string(input, "accessibilityValue") == "70" }
            try probe.press(title: "应用")
            try await probe.wait { probe.button(title: action, allVisibleWindows: true) != nil }
            try await probe.pressAlert(title: action) {
                probe.button(title: "打开设置", allVisibleWindows: true) == nil
                    && (action == "取消" || settingsOpened == 1)
            }
            XCTAssertEqual(service.preferences.limit, 80)
            XCTAssertFalse(service.preferences.allowLowLimit)
            XCTAssertEqual(transport.renewals.count, initialRequests)
        }
        XCTAssertEqual(settingsOpened, 1)
        var report = service.report
        report.calibration = .init(id: UUID(), state: .active, phase: .firstCharge, originalLimit: 80, startedAt: Date())
        transport.inspectReport = report
        transport.renewalReply = { _ in (true, report) }
        await service.recheckStatus()
        try await probe.wait { service.calibrationActive && !service.busy }
        XCTAssertFalse(try nativeControlEnabled(field()))
        XCTAssertFalse(try nativeControlEnabled(XCTUnwrap(probe.button(title: "应用"))))
        let slider = try XCTUnwrap(probe.nodes().first { probe.string($0, "accessibilityRole") == "AXSlider" })
        XCTAssertFalse(try nativeControlEnabled(slider))
        XCTAssertEqual(transport.renewals.count, initialRequests + 1, "Enabled status recheck renews the existing lease with the active calibration report")
    }
    @MainActor
    func testNativePreferencesSettingsUseCapabilityGatesInsteadOfEightyPercentAssumption() async throws {
        let name = "BatteryPreferencesUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var sample = battery(); sample.level = 82; sample.onAC = true
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Preferences Limit"
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.recheckStatus()
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "充电控制") != nil }
        try probe.press(title: "充电控制")
        try await probe.wait { probe.text.contains("到阈值提交暂停并核验实际停充") }
        for id in ["si.bm.low-limit", "si.bm.heat"] {
            let toggle = try XCTUnwrap(probe.nodes().first {
                probe.string($0, "accessibilityIdentifier") == "data-annotation-id=" + id
                    && probe.string($0, "accessibilityRole") == "AXCheckBox"
            })
            XCTAssertTrue(try nativeControlEnabled(toggle))
        }
        XCTAssertFalse(probe.text.contains("当前最低80%"))
        XCTAssertFalse(probe.text.contains("本机原生通道仅支持80–100%"))
        try probe.press(title: "捷径")
        try await probe.wait { probe.text.contains("快捷指令与面板使用同一能力限制") }
        XCTAssertFalse(probe.text.contains("低于80%的限充与暂停暂不可用"))
        XCTAssertTrue(transport.renewals.isEmpty)
    }
    @MainActor
    func testNativeExitHoldRequiresConfirmationAndCanRemoveUnsupportedSavedOption() async throws {
        let name = "BatteryExitHoldUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var sample = battery(); sample.level = 82; sample.onAC = true
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Preferences Limit"
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.recheckStatus()
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "睡眠行为") != nil }
        try probe.press(title: "睡眠行为")
        func toggle() throws -> NSObject {
            try XCTUnwrap(probe.nodes().first {
                probe.string($0, "accessibilityIdentifier") == "data-annotation-id=si.bm.pause-on-exit"
                    && probe.string($0, "accessibilityRole") == "AXCheckBox"
            })
        }
        func pressToggle() throws {
            let node = try toggle(), selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(node.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector))
        }
        try await probe.wait { probe.text.contains("退出时保持停充") }
        XCTAssertFalse(service.display.pauseOnExit)
        XCTAssertTrue(try nativeControlEnabled(toggle()))
        try pressToggle()
        try await probe.wait { probe.button(title: "启用退出停充", allVisibleWindows: true) != nil }
        XCTAssertFalse(service.display.pauseOnExit, "Opening confirmation cannot enable an exit policy")
        try await probe.pressAlert(title: "取消") {
            probe.button(title: "启用退出停充", allVisibleWindows: true) == nil && !service.display.pauseOnExit
        }
        XCTAssertFalse(service.display.pauseOnExit)
        try pressToggle()
        try await probe.wait { probe.button(title: "启用退出停充", allVisibleWindows: true) != nil }
        try await probe.pressAlert(title: "启用退出停充") {
            service.display.pauseOnExit && probe.button(title: "启用退出停充", allVisibleWindows: true) == nil
        }
        transport.mechanism = "macOS Charge Limit"
        await service.recheckStatus()
        try await probe.wait { !service.report.capabilities.exitHoldSupported }
        XCTAssertTrue(try nativeControlEnabled(toggle()), "A saved option must remain removable after capability loss")
        try pressToggle()
        try await probe.wait { !service.display.pauseOnExit }
        XCTAssertFalse(try nativeControlEnabled(toggle()))
        XCTAssertTrue(transport.renewals.isEmpty, "Preferences UI never prepares hardware exit hold")
    }
    @MainActor
    func testNativeSupplyUnknownIsNeverPresentedAsBatteryPower() async throws {
        let name = "BatteryUnknownSupply.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var sample = BatteryTelemetry(); sample.hasBattery = true
        let service = BatteryManagementService(defaults: defaults, client: BatteryTestTransport(), telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        for settings in [false, true] {
            let view = settings ? AnyView(BatteryManagementSettingsView(service: service)) : AnyView(BatteryManagementPanel(service: service))
            let host = NSHostingView(rootView: view.padding(16))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            let probe = BatteryPanelAXProbe(window: window, host: host)
            try await probe.wait { probe.text.contains("供电状态未知") && probe.text.contains("充电状态未知") }
            XCTAssertFalse(probe.nodes().contains { probe.string($0, "accessibilityValue") == "当前未充电" || probe.string($0, "accessibilityLabel") == "当前未充电" })
            XCTAssertFalse(probe.nodes().contains { probe.string($0, "accessibilityValue") == "电池供电" || probe.string($0, "accessibilityLabel") == "电池供电" })
        }
        XCTAssertEqual(batterySupplyDescription(BatteryTelemetry()), "电池读数不可用")
        sample.onAC = false; XCTAssertEqual(batterySupplyDescription(sample), "电池供电")
        sample.onAC = true; XCTAssertEqual(batterySupplyDescription(sample), "电源适配器")
        sample.charging = false; XCTAssertEqual(batteryChargingDescription(sample), "当前未充电")
        sample.charging = true; XCTAssertEqual(batteryChargingDescription(sample), "正在充电")
    }
    @MainActor
    func testNativePauseBelowEightyIsDisabledWithoutChangingLongTermSettings() async throws {
        let name = "BatteryNativePauseUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var sample = battery(); sample.level = 60; sample.onAC = true
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Charge Limit"
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.attemptStartupForTesting()
        let original = service.preferences, requests = transport.renewals.count
        let host = NSHostingView(rootView: BatteryManagementPanel(service: service, initialSection: 1).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 624, height: 216), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "暂停充电") != nil }
        let pause = try XCTUnwrap(probe.button(title: "暂停充电"))
        XCTAssertFalse(try nativeControlEnabled(pause))
        XCTAssertTrue(try nativeControlEnabled(XCTUnwrap(probe.button(title: "充满"))))
        XCTAssertEqual(service.preferences, original)
        XCTAssertEqual(transport.renewals.count, requests)
        // A new pause is unavailable below80, but an existing pause must
        // retain its recovery action if the next real reading falls below80.
        sample.level = 80; service.refreshTelemetry()
        _ = try await service.execute(mode: .paused)
        sample.level = 60; service.refreshTelemetry()
        try await probe.wait { probe.button(title: "恢复充电") != nil }
        XCTAssertTrue(try nativeControlEnabled(XCTUnwrap(probe.button(title: "恢复充电"))))
        try probe.press(title: "恢复充电")
        try await probe.wait { service.mode == .automatic }
        XCTAssertEqual(service.preferences, original)
    }
    @MainActor
    func testNativeSavedHeatRuleCanBeTurnedOffWithoutReenablingUnsupportedControl() async throws {
        let name = "BatteryNativeOldHeatUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var saved = BatteryControlPreferences(); saved.heatProtection = true
        defaults.set(try JSONEncoder().encode(saved), forKey: "batteryManagement.preferences")
        var sample = battery(); sample.level = 80; sample.onAC = true
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Charge Limit"
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.attemptStartupForTesting()
        service.setEnabled(false)
        let deadline = Date().addingTimeInterval(5)
        while (service.enabled || service.busy) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.enabled); XCTAssertFalse(service.busy)
        let requests = transport.renewals.count
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "充电控制") != nil }
        try probe.press(title: "充电控制")
        try await probe.wait { probe.text.contains("此处仅显示已保存的阈值") }
        let heat = try XCTUnwrap(probe.nodes().first { probe.string($0, "accessibilityIdentifier") == "data-annotation-id=si.bm.heat" && probe.string($0, "accessibilityRole") == "AXCheckBox" && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) })
        XCTAssertTrue(try nativeControlEnabled(heat))
        XCTAssertTrue(service.preferences.heatProtection, "Showing unavailable controls must preserve old preferences")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(unsafeBitCast(heat.method(for: selector), to: Press.self)(heat, selector))
        try await probe.wait { !service.preferences.heatProtection }
        let disabledHeat = try XCTUnwrap(probe.nodes().first { probe.string($0, "accessibilityIdentifier") == "data-annotation-id=si.bm.heat" && probe.string($0, "accessibilityRole") == "AXCheckBox" && $0.responds(to: NSSelectorFromString("isAccessibilityEnabled")) })
        XCTAssertFalse(try nativeControlEnabled(disabledHeat))
        saved.heatProtection = false
        XCTAssertEqual(service.preferences, saved)
        XCTAssertEqual(transport.renewals.count, requests, "Repairing a disabled rule cannot start a hardware request")
    }
    @MainActor
    func testNativeLidLockLeafIdentifierIsUniqueAndSleepPickerRepairsOriginalBinding() async throws {
        let name = "BatteryNativeSleepPickerUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var saved = BatteryControlPreferences(); saved.sleep = .pause
        defaults.set(try JSONEncoder().encode(saved), forKey: "batteryManagement.preferences")
        var sample = battery(); sample.level = 80; sample.onAC = true
        let transport = BatteryTestTransport(); transport.mechanism = "macOS Charge Limit"
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        await service.attemptStartupForTesting()
        service.setEnabled(false)
        let deadline = Date().addingTimeInterval(5)
        while (service.enabled || service.busy) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.enabled); XCTAssertFalse(service.busy)
        let requests = transport.renewals.count
        let host = NSHostingView(rootView: BatteryManagementSettingsView(service: service).padding(16))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 1300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "睡眠行为") != nil }
        try probe.press(title: "睡眠行为")
        try await probe.wait { probe.text.contains("合盖时锁定屏幕") }
        let lidNodes = probe.nodes().filter { probe.string($0, "accessibilityIdentifier") == "data-annotation-id=si.bm.lid-lock" }
        XCTAssertEqual(lidNodes.count, 1, "A leaf ID must identify exactly one rendered native control")
        let lid = try XCTUnwrap(lidNodes.first)
        XCTAssertEqual(probe.string(lid, "accessibilityRole"), "AXCheckBox")
        XCTAssertEqual((lid.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber)?.intValue, 0)
        XCTAssertEqual(probe.nodes().filter { probe.string($0, "accessibilityIdentifier") == "data-annotation-id=si.bm.settings" }.count, 1,
                       "The parent page ID belongs to its title, not every child")
        XCTAssertFalse(service.display.lockOnLidClose)
        XCTAssertEqual(service.preferences.sleep, .pause, "Rendering must retain the unavailable old value")
        let unchanged = try XCTUnwrap(probe.nodes().first {
            probe.string($0, "accessibilityRole") == "AXRadioButton" && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                && (probe.string($0, "accessibilityLabel") == "照原样继续" || probe.string($0, "accessibilityTitle") == "照原样继续")
        })
        XCTAssertTrue(try nativeControlEnabled(unchanged))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(unsafeBitCast(unchanged.method(for: press), to: Press.self)(unchanged, press))
        try await probe.wait { service.preferences.sleep == .unchanged }
        saved.sleep = .unchanged
        XCTAssertEqual(service.preferences, saved)
        XCTAssertEqual(transport.renewals.count, requests)
        XCTAssertFalse(service.display.lockOnLidClose, "The test never enables or presses lid locking")
    }
    @MainActor
    private func nativeControlEnabled(_ object: NSObject) throws -> Bool {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { throw NSError(domain: "BatteryNativeUI", code: 1) }
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Enabled.self)(object, selector)
    }
    @MainActor
    func testNativeUnifiedSettingsPreservesBatteryGeneralAndRequestedPaneNavigation() async throws {
        let host = NSHostingView(rootView: SettingsView(initialPane: .batteryManagement).environmentObject(AppState.shared))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
        let probe = BatteryPanelAXProbe(window: window, host: host)
        try await probe.wait { probe.button(title: "仪表板") != nil }
        try probe.press(title: "通用")
        try await probe.wait { probe.text.contains("登录时启动") && probe.button(title: "仪表板") == nil }
        NotificationCenter.default.post(name: .superIslandSettingsPaneRequested, object: SettingsPane.batteryManagement.rawValue)
        try await probe.wait { probe.button(title: "仪表板") != nil }
        try probe.press(title: "通用")
        try await probe.wait { probe.text.contains("登录时启动") }
        try probe.press(title: "电池管理")
        try await probe.wait { probe.button(title: "仪表板") != nil }
    }
    @MainActor
    func testServicePersistsSelectedMetricsAndUpdatesFormatterWithoutControlWrite() throws {
        let name = "BatteryDisplayCompletionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = BatteryTestTransport()
        let snapshot = battery()
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: { snapshot }, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.refreshTelemetry()
        service.updateDisplay {
            $0.metrics = [.remaining, .voltage]; $0.runtimeMode = .instant
            $0.entryStatistics = [.power, .percentage]; $0.popupFields = []
        }
        XCTAssertEqual(service.metricTitle(.remaining), "预计电池续航")
        XCTAssertEqual(service.metricValue(.remaining), "约4时0分")
        XCTAssertEqual(service.entryValue(.power), "-12.0 W")
        let stored = try JSONDecoder().decode(BatteryDisplayPreferences.self, from: XCTUnwrap(defaults.data(forKey: "batteryManagement.display")))
        XCTAssertEqual(stored.metrics, [.remaining, .voltage]); XCTAssertTrue(stored.popupFields.isEmpty)
        XCTAssertTrue(transport.renewals.isEmpty)
    }
}


@MainActor
final class BatteryTargetAuthorityTests: XCTestCase {
    private func nativeSnapshot(_ limit: Int) -> BatteryControlReport {
        var report = BatteryControlReport()
        report.available = true; report.mechanism = "macOS Charge Limit"
        report.nativeSavedLimit = limit; report.registeredTarget = limit
        report.dischargeSupported = true; report.minimumDischargeTarget = 80
        report.dischargeMechanism = .nativeLimit; report.leaseHeldByRequester = true
        report.message = "系统读回目标\(limit)%；不表示已应用请求目标"
        return report
    }
    private func fixture(_ transport: BatteryTestTransport) throws -> (BatteryManagementService, UserDefaults) {
        let domain = "BM1.TargetAuthority.\(UUID())", defaults = UserDefaults(suiteName: domain)!
        defaults.set(try JSONEncoder().encode(BatteryControlPreferences()), forKey: "batteryManagement.preferences")
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        let service = BatteryManagementService(defaults: defaults, client: transport, telemetryReader: {
            var s = BatteryTelemetry(); s.hasBattery = true; s.level = 82; s.onAC = true; s.current = 0; return s
        }, conflictChecker: { nil })
        return (service, defaults)
    }
    func testRepeatedSystemReadbacksNeverReplaceSavedPolicy() async throws {
        let t = BatteryTestTransport(); var systemLimit = 85
        t.inspectReport = nativeSnapshot(systemLimit)
        t.renewalReply = { request in var r = self.nativeSnapshot(systemLimit); r.mode = request.mode; return (true, r) }
        let (s, defaults) = try fixture(t); defer { s.shutdown() }
        let before = defaults.data(forKey: "batteryManagement.preferences")
        await s.attemptStartupForTesting()
        XCTAssertEqual(s.report.nativeSavedLimit, 85); XCTAssertEqual(s.preferences.limit, 80)
        systemLimit = 95
        await s.attemptStartupForTesting()
        XCTAssertEqual(s.report.nativeSavedLimit, 95); XCTAssertEqual(s.report.registeredTarget, 95)
        XCTAssertEqual(s.preferences.limit, 80)
        XCTAssertEqual(t.renewals.map(\.preferences.limit), [80, 80])
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.preferences"), before)
    }
    func testNewInAppLimitRemainsAuthoritativeWhileSystemStillReports85() async throws {
        let t = BatteryTestTransport(); t.inspectReport = nativeSnapshot(85)
        t.renewalReply = { request in var r = self.nativeSnapshot(85); r.mode = request.mode; return (true, r) }
        let (s, defaults) = try fixture(t); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        try s.updatePreferences { $0.limit = 90 }
        for _ in 0..<100 where t.renewals.last?.preferences.limit != 90 { await Task.yield() }
        XCTAssertEqual(s.preferences.limit, 90); XCTAssertEqual(t.renewals.last?.preferences.limit, 90)
        XCTAssertEqual(s.report.nativeSavedLimit, 85, "Fact remains distinct from requested policy")
        let saved = try JSONDecoder().decode(BatteryControlPreferences.self, from: XCTUnwrap(defaults.data(forKey: "batteryManagement.preferences")))
        XCTAssertEqual(saved.limit, 90)
    }
    func testExternalConflictStopsControlWithoutAdopting85() async throws {
        let t = BatteryTestTransport(); t.inspectReport = nativeSnapshot(80); t.failRelease = true
        t.renewalReply = { _ in
            var r = self.nativeSnapshot(85); r.available = false; r.recoveryPending = true
            r.requiresManualRetry = true; r.message = "系统目标被外部修改，控制权未确认"
            return (false, r)
        }
        let (s, defaults) = try fixture(t); defer { s.shutdown() }
        let before = defaults.data(forKey: "batteryManagement.preferences")
        await s.attemptStartupForTesting()
        XCTAssertFalse(s.enabled); XCTAssertFalse(s.canControl); XCTAssertTrue(s.report.recoveryPending)
        XCTAssertEqual(s.preferences.limit, 80); XCTAssertEqual(s.report.nativeSavedLimit, 85)
        XCTAssertEqual(t.renewals.map(\.preferences.limit), [80]); XCTAssertEqual(t.releases, 1)
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.preferences"), before)
    }
    func testTemporaryTopUpReturnsToPolicyWithoutSaving100() async throws {
        let t = BatteryTestTransport(); t.inspectReport = nativeSnapshot(80)
        t.renewalReply = { request in
            var r = self.nativeSnapshot(request.mode == .topUp ? 100 : request.preferences.limit)
            r.mode = request.mode; return (true, r)
        }
        let (s, defaults) = try fixture(t); defer { s.shutdown() }
        let before = defaults.data(forKey: "batteryManagement.preferences")
        await s.attemptStartupForTesting()
        _ = try await s.execute(mode: .topUp)
        XCTAssertEqual(s.report.nativeSavedLimit, 100); XCTAssertEqual(s.preferences.limit, 80)
        _ = try await s.execute(mode: .automatic)
        XCTAssertEqual(s.report.nativeSavedLimit, 80); XCTAssertEqual(s.preferences.limit, 80)
        XCTAssertEqual(t.renewals.map(\.preferences.limit), [80, 80, 80])
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.preferences"), before)
    }
    func testSystemCalibrationReadbackDoesNotBecomeLongTermPolicy() async throws {
        let t = BatteryTestTransport(); var calibration = nativeSnapshot(100); calibration.systemCalibration = true
        t.inspectReport = calibration; t.renewalReply = { _ in (true, calibration) }
        let (s, defaults) = try fixture(t); defer { s.shutdown() }
        let before = defaults.data(forKey: "batteryManagement.preferences")
        await s.attemptStartupForTesting()
        XCTAssertTrue(s.report.systemCalibration); XCTAssertEqual(s.report.nativeSavedLimit, 100)
        XCTAssertEqual(s.preferences.limit, 80); XCTAssertEqual(t.renewals.last?.preferences.limit, 80)
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.preferences"), before)
    }
    func testOwnedLeaseRejectsForeign85AndResumesOnlyAfterMatchingOwnership() throws {
        var actual = 95, writes: [Int] = [], disk: BatteryOverrideLease.Journal?
        let owner = UUID(), key = "nativeAPILimit"
        let lease = BatteryOverrideLease(read: { _ in actual }, write: { _, value in actual = value; writes.append(value) }, save: { disk = $0 })
        try lease.renew(owner: owner, now: 0); try lease.apply([key: 80], owner: owner)
        actual = 85
        XCTAssertThrowsError(try lease.apply([key: 80], owner: owner))
        XCTAssertThrowsError(try lease.apply([key: 90], owner: owner), "A new policy is not proof of hardware ownership")
        XCTAssertThrowsError(try lease.release(owner: owner))
        XCTAssertEqual(actual, 85); XCTAssertEqual(writes, [80])
        XCTAssertEqual(disk?.entries[key]?.expected, 80); XCTAssertEqual(disk?.entries[key]?.original, 95)
        actual = 80 // Independently regained the previously owned state.
        try lease.apply([key: 90], owner: owner)
        XCTAssertEqual(actual, 90); XCTAssertEqual(writes, [80, 90])
        XCTAssertEqual(disk?.entries[key]?.expected, 90); XCTAssertEqual(disk?.entries[key]?.original, 95)
    }
}


@MainActor
final class BatteryPauseRefreshInteractionTests: XCTestCase {
    private func fixture(_ t: BatteryTestTransport, telemetry: @escaping () -> BatteryTelemetry) throws -> BatteryManagementService {
        let domain = "BatteryPauseUI." + UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        defaults.set(try JSONEncoder().encode(BatteryControlPreferences()), forKey: "batteryManagement.preferences")
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return BatteryManagementService(defaults: defaults, client: t, telemetryReader: telemetry, conflictChecker: { nil }, scheduleStarter: {})
    }
    private func sample() -> BatteryTelemetry {
        var s = BatteryTelemetry(); s.hasBattery = true; s.level = 80; s.onAC = true; s.current = 1; return s
    }
    private func pending(_ request: BatteryControlRequest) -> BatteryControlReport {
        var r = BatteryControlReport(); r.mode = request.mode; r.mechanism = "macOS Preferences Limit"
        r.available = request.mode != .paused; r.leaseHeldByRequester = true
        r.pauseRefreshOperationID = request.mode == .paused ? request.operationID : nil
        r.recoveryPending = request.mode == .paused
        r.message = "已提交，正在验证供电与暂停"; return r
    }
    func testExplicitOffBeforeStartupSurvivesLaterActivationAndReopen() async throws {
        let t = BatteryTestTransport(); let s = try fixture(t, telemetry: sample); defer { s.shutdown() }
        s.setEnabled(false)
        s.start(automaticallyEnable: false)
        s.start(automaticallyEnable: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(s.enabled); XCTAssertTrue(t.renewals.isEmpty)
    }
    func testExplicitEnableBeforeStartupInstallsRecurringLeaseRenewal() async throws {
        let t = BatteryTestTransport(); let renewed = expectation(description: "Real heartbeat renews after initial explicit enable")
        renewed.assertForOverFulfill = false
        var renewals = 0
        t.renewalReply = { request in
            renewals += 1
            if renewals >= 2 { renewed.fulfill() }
            var report = self.pending(request); report.available = true; return (true, report)
        }
        let s = try fixture(t, telemetry: sample); defer { s.shutdown() }
        XCTAssertTrue(t.renewals.isEmpty)
        s.setEnabled(true) // No prior start call: this is the actual broken route.
        await fulfillment(of: [renewed], timeout: 20)
        XCTAssertGreaterThanOrEqual(t.renewals.count, 2)
        XCTAssertTrue(s.enabled)
    }
    func testAcceptedPendingPauseCanCancelWithoutAdapterOrNewRenew() async throws {
        let t = BatteryTestTransport(); var sample = sample()
        t.renewalReply = { (true, self.pending($0)) }
        let s = try fixture(t, telemetry: { sample }); defer { s.shutdown() }
        await s.attemptStartupForTesting()
        let message = try await s.execute(mode: .paused)
        XCTAssertTrue(message.contains("正在验证")); XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.pauseRefreshPending); XCTAssertFalse(s.canControl); XCTAssertTrue(s.canCancelPauseRefresh)
        sample.onAC = false
        s.refreshTelemetry()
        XCTAssertTrue(s.canResumeCharging)
        let count = t.renewals.count
        _ = try await s.execute(mode: .automatic)
        XCTAssertEqual(t.renewals.count, count); XCTAssertEqual(t.releases, 1)
        XCTAssertFalse(s.enabled); XCTAssertFalse(s.pauseRefreshPending)
        XCTAssertEqual(s.preferences.limit, 80)
    }
    func testPendingReleaseDoesNotClaimRecoveryOrReenable() async throws {
        let t = BatteryTestTransport(); t.renewalReply = { (true, self.pending($0)) }
        let s = try fixture(t, telemetry: sample); defer { s.shutdown() }
        await s.attemptStartupForTesting(); _ = try await s.execute(mode: .paused)
        t.pendingReleaseCount = 3
        let count = t.renewals.count
        let message = try await s.execute(mode: .automatic)
        XCTAssertTrue(message.contains("正在恢复")); XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.report.recoveryPending); XCTAssertEqual(t.renewals.count, count)
    }
    func testNewEnableDuringCancellationCannotReceiveStaleClosedMessage() async throws {
        let t = BatteryTestTransport(); t.renewalReply = { (true, self.pending($0)) }
        let s = try fixture(t, telemetry: sample); defer { s.shutdown() }
        await s.attemptStartupForTesting(); _ = try await s.execute(mode: .paused)
        var held: CheckedContinuation<(Bool, BatteryControlReport), Error>?
        t.releaseReply = { try await withCheckedThrowingContinuation { held = $0 } }
        let cancel = Task { try await s.execute(mode: .automatic) }
        for _ in 0..<100 where held == nil { await Task.yield() }
        guard let continuation = held else { XCTFail("Release did not start"); cancel.cancel(); return }
        s.setEnabled(true)
        var restored = BatteryControlReport(); restored.available = true
        restored.leaseHeldByRequester = false; restored.mechanism = "macOS Preferences Limit"
        continuation.resume(returning: (true, restored)); t.releaseReply = nil
        do { _ = try await cancel.value; XCTFail("Stale cancellation result was accepted") } catch {}
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.mode, .automatic)
        XCTAssertFalse(s.report.message.contains("控制已关闭"))
    }
    func testRepeatedOffSyncDuringCancellationDoesNotInvalidateSameIntent() async throws {
        let t = BatteryTestTransport(); t.renewalReply = { (true, self.pending($0)) }
        let s = try fixture(t, telemetry: sample); defer { s.shutdown() }
        await s.attemptStartupForTesting(); _ = try await s.execute(mode: .paused)
        var held: CheckedContinuation<(Bool, BatteryControlReport), Error>?
        t.releaseReply = { try await withCheckedThrowingContinuation { held = $0 } }
        let cancel = Task { try await s.execute(mode: .automatic) }
        for _ in 0..<100 where held == nil { await Task.yield() }
        guard let continuation = held else { XCTFail("Release did not start"); cancel.cancel(); return }
        s.setEnabled(false) // Queues sync/revision without introducing a new operation.
        var restored = BatteryControlReport(); restored.available = true
        restored.leaseHeldByRequester = false; restored.mechanism = "macOS Preferences Limit"
        continuation.resume(returning: (true, restored)); t.releaseReply = nil
        let message = try await cancel.value
        XCTAssertFalse(s.enabled); XCTAssertTrue(message.contains("已取消暂停并恢复"))
    }
    func testWrongOperationMissingOwnershipAndFailureNeverCountAsAcceptedPause() async throws {
        for variant in 0..<4 {
            let t = BatteryTestTransport()
            t.renewalReply = { request in
                var r = self.pending(request)
                if request.mode == .paused {
                    if variant == 0 { r.pauseRefreshOperationID = UUID() }
                    if variant == 1 { r.leaseHeldByRequester = nil }
                    if variant == 2 { r.lastFailure = "failed" }
                    if variant == 3 { r.requiresManualRetry = true }
                }
                return (true, r)
            }
            let s = try fixture(t, telemetry: sample); defer { s.shutdown() }
            await s.attemptStartupForTesting()
            do { _ = try await s.execute(mode: .paused); XCTFail("Unverified pending was accepted") } catch {}
            XCTAssertFalse(s.pauseRefreshPending); XCTAssertFalse(s.canCancelPauseRefresh)
        }
    }
}
