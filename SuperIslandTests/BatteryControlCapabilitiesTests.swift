import XCTest
@testable import SuperIsland

final class BatteryControlCapabilitiesTests: XCTestCase {
    private func report(_ mechanism: String = "SMC CHTE", minimum: Int? = nil) -> BatteryControlReport {
        var r = BatteryControlReport(); r.mechanism = mechanism; r.available = true
        r.dischargeSupported = true; r.minimumDischargeTarget = minimum
        r.calibrationSupported = true; r.ledSupported = true; r.highPowerSupported = true
        return r
    }
    private func request(_ mode: BatteryControlMode = .automatic) -> BatteryControlRequest {
        .init(owner: UUID(), preferences: .init(), mode: mode, dischargeTarget: mode == .discharge ? 80 : nil)
    }
    private func sample(_ level: Int = 82) -> BatteryTelemetry {
        var result = BatteryTelemetry(); result.hasBattery = true; result.level = level; result.onAC = true
        return result
    }
    func testUnknownRouteCannotAcquireChargingFromUnrelatedPositiveFlags() {
        let capabilities = report("unrecognized future backend").capabilities
        XCTAssertNil(capabilities.minimumLimit); XCTAssertNil(capabilities.minimumDischargeTarget)
        XCTAssertFalse(capabilities.calibration); XCTAssertFalse(capabilities.immediatePause)
        for mode in BatteryControlMode.allCases {
            XCTAssertThrowsError(try capabilities.validate(request(mode), currentLevel: 82))
        }
    }
    func testNativeRangeAndCalibrationClaimsCannotBeExpandedByAReport() {
        let r = report("macOS Charge Limit", minimum: 20)
        XCTAssertNil(r.capabilities.minimumDischargeTarget, "Contradictory declarations fail closed")
        XCTAssertFalse(r.capabilities.calibration)
        var low = request(); low.preferences.limit = 79; low.preferences.allowLowLimit = true
        XCTAssertThrowsError(try r.capabilities.validate(low, currentLevel: 82))
        var calibration = request(); calibration.calibration = .start(UUID())
        XCTAssertThrowsError(try r.capabilities.validate(calibration, currentLevel: 82))
    }
    func testMalformedDischargeFloorIsNotReplacedWithAPermissiveDefault() {
        for minimum in [-1, 0, 19, 100, Int.max] {
            XCTAssertNil(report(minimum: minimum).capabilities.minimumDischargeTarget)
        }
        XCTAssertEqual(report().capabilities.minimumDischargeTarget, 20, "Old reports can omit a known route's floor")
        XCTAssertEqual(report("macOS Charge Limit").capabilities.minimumDischargeTarget, 80)
    }
    func testDeclaredHigherFloorAppliesToAutomaticDischargeAndSailingToo() {
        let cap = report(minimum: 90).capabilities
        var r = request(); r.preferences.automaticDischarge = true
        XCTAssertTrue(cap.issues(r.preferences).contains(.automaticDischarge))
        r.preferences.limit = 95; r.preferences.sailing = true; r.preferences.sailingLower = 85
        XCTAssertTrue(cap.issues(r.preferences).contains(.sailing))
        XCTAssertFalse(cap.canSail(lower: 85, upper: 95))
        r.preferences.sailingLower = 90
        XCTAssertTrue(cap.issues(r.preferences).isEmpty)
    }
    func testIntelLimitDoesNotProveInstantPauseDischargeOrCalibration() {
        let cap = report("Intel BCLM").capabilities
        XCTAssertEqual(cap.minimumLimit, 20); XCTAssertTrue(cap.canPause(at: 70))
        XCTAssertFalse(cap.immediatePause); XCTAssertNil(cap.minimumDischargeTarget); XCTAssertFalse(cap.calibration)
        var r = request(); r.preferences.heatProtection = true
        XCTAssertThrowsError(try cap.validate(r, currentLevel: 82))
        r.preferences.heatProtection = false; r.preferences.sleep = .pause
        XCTAssertThrowsError(try cap.validate(r, currentLevel: 82))
    }
    func testPauseNeedsAnActualInRangeLevelAndKeepsLongTermPreferences() throws {
        let cap = report("macOS Charge Limit").capabilities, paused = request(.paused)
        for level in [Int?.none, -1, 19, 79, 101] {
            XCTAssertFalse(cap.canPause(at: level))
            XCTAssertThrowsError(try cap.validate(paused, currentLevel: level))
        }
        try cap.validate(paused, currentLevel: 81)
        XCTAssertEqual(paused.preferences.limit, 80); XCTAssertFalse(paused.preferences.allowLowLimit)
        XCTAssertTrue(report().capabilities.canPause(at: 70))
    }
    func testSealedReviewCannotInheritOtherCapabilitiesFromALooserRoute() {
        var r = report(); r.nativeCutoffReviewTrial = true
        let cap = r.capabilities
        XCTAssertNil(cap.backend, "Review cannot borrow another backend's controls")
        XCTAssertFalse(cap.lowLimits); XCTAssertFalse(cap.immediatePause); XCTAssertFalse(cap.calibration)
        XCTAssertFalse(cap.led); XCTAssertFalse(cap.highPower); XCTAssertFalse(cap.canSail(lower: 80, upper: 85))
        XCTAssertThrowsError(try cap.validate(request(.topUp), currentLevel: 82))
        var low = request(.discharge); low.dischargeTarget = 79
        XCTAssertThrowsError(try cap.validate(low, currentLevel: 82))
    }
    func testDisabledDischargeDoesNotBecomeAvailableFromAMinimumDeclaration() {
        var r = report(minimum: 20); r.dischargeSupported = false
        XCTAssertNil(r.capabilities.minimumDischargeTarget); XCTAssertFalse(r.capabilities.calibration)
        XCTAssertThrowsError(try r.capabilities.validate(request(.discharge), currentLevel: 82))
    }
    func testUnrelatedLedOrEnergyCapabilityIsNotInferredFromChargeBackend() {
        var r = report(); r.ledSupported = false; r.highPowerSupported = false
        var p = BatteryControlPreferences(); p.led = .green; p.highPowerScope = .always
        let issues = r.capabilities.issues(p)
        XCTAssertTrue(issues.contains(.led)); XCTAssertTrue(issues.contains(.highPower))
        XCTAssertTrue(r.capabilities.immediatePause)
    }
    func testOldReportRoundTripRetainsWireCompatibilityWithoutNewCapabilities() throws {
        let r = try JSONDecoder().decode(BatteryControlReport.self, from: JSONEncoder().encode(report("macOS Charge Limit")))
        XCTAssertEqual(r.capabilities.minimumLimit, 80); XCTAssertFalse(r.capabilities.immediatePause)
        XCTAssertEqual(r.protocolVersion, BatteryControlReport.currentProtocolVersion)
    }
    @MainActor func testUnknownFutureTaskCanBeKeptWithoutGrantingExecution() {
        let r = BatteryControlReport()
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 70
        XCTAssertNil(BatteryPreferenceCompatibility.taskWarning(task, report: r))
        task.action = .calibrate
        XCTAssertNil(BatteryPreferenceCompatibility.taskWarning(task, report: r))
        XCTAssertThrowsError(try r.capabilities.validate(request(), currentLevel: 82))
    }
    @MainActor func testTaskUsesTheSameDeclaredDischargeFloorAndIntelCalibrationRule() {
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 85
        XCTAssertNotNil(BatteryPreferenceCompatibility.taskWarning(task, report: report(minimum: 90)))
        task.action = .calibrate
        XCTAssertNotNil(BatteryPreferenceCompatibility.taskWarning(task, report: report("Intel BCLM")))
    }
    func testEveryImplementedRoutePreflightsTargetsAndPreservesAnExistingLeaseOnFailure() throws {
        for mechanism in ["SMC CHTE", "SMC CH0B/CH0C", "macOS Charge Limit", "Intel BCLM"] {
            var reads = 0, writes = 0, saves = 0, planned = 0
            let old = request()
            let lease = BatteryOverrideLease(read: { _ in reads += 1; return 0 },
                write: { _, _ in writes += 1 }, save: { _ in saves += 1 })
            try lease.renew(owner: old.owner, now: 10)
            let original = lease.journal, expiry = lease.expires
            let policy = BatteryControlPolicy()
            var proposed = old; proposed.preferences.limit = 85
            XCTAssertThrowsError(try BatteryControlAdmission.preflight(proposed, previous: old,
                policy: policy, capabilities: report(mechanism).capabilities, telemetry: sample(),
                calibrationActive: false, ownsAdapterCutoff: { false }, validateTargets: { _ in
                    planned += 1; throw BatteryControlError.recovery("original register cannot be restored")
                }))
            XCTAssertEqual(planned, 1, mechanism)
            XCTAssertEqual(lease.journal?.owner, original?.owner); XCTAssertEqual(lease.journal?.entries.count, 0)
            XCTAssertEqual(lease.expires, expiry); XCTAssertEqual(saves, 1)
            XCTAssertEqual(reads, 0); XCTAssertEqual(writes, 0)
        }
    }
    func testUnsupportedRequestIsRejectedBeforeAnyOwnershipReadOrTargetPlanning() {
        var r = request(); r.preferences.led = .green
        var status = report(); status.ledSupported = false
        XCTAssertThrowsError(try BatteryControlAdmission.preflight(r, previous: nil,
            policy: .init(), capabilities: status.capabilities, telemetry: sample(), calibrationActive: false,
            ownsAdapterCutoff: { XCTFail("No ownership read for an unsupported request"); return false },
            validateTargets: { _ in XCTFail("No planning for an unsupported request") }))
    }
    func testPreflightDoesNotMutateTheRunningSailingPolicy() throws {
        var policy = BatteryControlPolicy(), old = request()
        old.preferences.sailing = true; old.preferences.sailingLower = 70
        _ = try policy.decide(request: old, snapshot: sample(80))
        XCTAssertTrue(policy.sailingWaiting)
        var next = old; next.preferences.sailing = false
        try BatteryControlAdmission.preflight(next, previous: old, policy: policy,
            capabilities: report().capabilities, telemetry: sample(75), calibrationActive: false,
            ownsAdapterCutoff: { false }, validateTargets: { _ in })
        XCTAssertTrue(policy.sailingWaiting, "A rejected later plan must leave the live hysteresis unchanged")
    }
    func testActiveCalibrationHeartbeatDoesNotPlanOrdinaryTargetsOverItsSession() throws {
        try BatteryControlAdmission.preflight(request(), previous: nil, policy: .init(),
            capabilities: report().capabilities, telemetry: sample(), calibrationActive: true,
            ownsAdapterCutoff: { XCTFail("Calibration owns this observation"); return false },
            validateTargets: { _ in XCTFail("Do not replace calibration with ordinary targets") })
    }
}

final class BatteryCapabilityProbeTests: XCTestCase {
    func testTransientFailureRecoversWithoutBecomingUnsupported() {
        var probe = BatteryCapabilityProbe()
        probe.complete(supported: false, error: "timeout", now: 0)
        XCTAssertEqual(probe.status, .failed)
        var reads = 0
        XCTAssertFalse(probe.retry(explicit: false, idle: true, now: 14, clock: { 14 }) { reads += 1; return true })
        XCTAssertTrue(probe.retry(explicit: false, idle: true, now: 15, clock: { 19 }) { reads += 1; return true })
        XCTAssertEqual(reads, 1); XCTAssertEqual(probe.status, .supported); XCTAssertNil(probe.failure)
        XCTAssertFalse(probe.retry(explicit: true, idle: true, now: 100, clock: { 100 }) { XCTFail("Already supported"); return true })
    }
    func testRepeatedFailureExhaustsAutomaticBudgetButExplicitRetryWorks() {
        var probe = BatteryCapabilityProbe()
        probe.complete(supported: false, error: "launch timeout", now: 0)
        for now in [15.0, 30] {
            XCTAssertTrue(probe.retry(explicit: false, idle: true, now: now, clock: { now }) {
                throw BatteryControlError.unavailable("child still unreaped")
            })
            XCTAssertEqual(probe.status, .failed)
        }
        XCTAssertEqual(probe.attempts, 3)
        XCTAssertFalse(probe.retry(explicit: false, idle: true, now: 300, clock: { 300 }) { XCTFail(); return true })
        XCTAssertTrue(probe.retry(explicit: true, idle: true, now: 300, clock: { 304 }) { true })
        XCTAssertEqual(probe.status, .supported)
    }
    func testCooldownStartsAfterQueryCompletionAndBlocksRepeatedClicks() {
        var probe = BatteryCapabilityProbe()
        probe.complete(supported: false, error: "timeout", now: 0)
        XCTAssertTrue(probe.retry(explicit: true, idle: true, now: 2, clock: { 6 }) { false })
        XCTAssertEqual(probe.status, .unsupported)
        XCTAssertFalse(probe.retry(explicit: true, idle: true, now: 7.99, clock: { 8 }) { XCTFail(); return true })
        XCTAssertTrue(probe.retry(explicit: true, idle: true, now: 8, clock: { 8 }) { true })
    }
    func testNegativeResultDoesNotPollForever() {
        var probe = BatteryCapabilityProbe()
        probe.complete(supported: false, error: nil, now: 0)
        XCTAssertEqual(probe.status, .unsupported)
        XCTAssertFalse(probe.retry(explicit: false, idle: true, now: 100, clock: { 100 }) { XCTFail(); return true })
        var report = BatteryControlReport(); report.capabilityProbeStatus = probe.status
        XCTAssertFalse(report.capabilityDetectionPending)
        report.capabilityProbeStatus = .failed
        XCTAssertTrue(report.capabilityDetectionPending)
        XCTAssertThrowsError(try report.capabilities.validate(.init(owner: UUID(), preferences: .init()), currentLevel: 80))
    }
    func testEveryOwnershipAndRecoveryBoundaryPreventsEvenARead() {
        for index in 0..<8 {
            let idle = BatteryCapabilityProbe.isIdle(recoveryKnown: index != 0,
                infrastructureReady: index != 1, leaseHeld: index == 2, cutoffHeld: index == 3,
                calibrationActive: index == 4, requestActive: index == 5, exitHoldActive: index == 6,
                experimentPending: index == 7)
            XCTAssertFalse(idle)
            var probe = BatteryCapabilityProbe(); probe.complete(supported: false, error: "timeout", now: 0)
            for explicit in [false, true] {
                XCTAssertFalse(probe.retry(explicit: explicit, idle: idle, now: 100, clock: { 100 }) { XCTFail("Active boundary \(index)"); return true })
            }
            XCTAssertEqual(probe.attempts, 1)
        }
        XCTAssertTrue(BatteryCapabilityProbe.isIdle(recoveryKnown: true, infrastructureReady: true,
            leaseHeld: false, cutoffHeld: false, calibrationActive: false, requestActive: false,
            exitHoldActive: false, experimentPending: false))
    }
    func testProbeSuccessCannotClearDurableManualFault() throws {
        var saved: Data?
        let retry = BatteryManualRetry(load: { nil }, save: { saved = $0 })
        retry.fail(owner: UUID(), operation: UUID(), reason: "control failure")
        let fault = retry.faultID, before = saved
        var probe = BatteryCapabilityProbe(); probe.complete(supported: false, error: "timeout", now: 0)
        XCTAssertTrue(probe.retry(explicit: true, idle: true, now: 10, clock: { 10 }) { true })
        XCTAssertTrue(retry.required); XCTAssertEqual(retry.faultID, fault); XCTAssertEqual(saved, before)
        XCTAssertThrowsError(try retry.validate(.init(owner: UUID(), preferences: .init()), recovered: true))
    }
    func testOptionalStatusDecodesOldReportsWithoutAssumingSupport() throws {
        var report = BatteryControlReport(); report.capabilityProbeStatus = .failed; report.capabilityProbeFailure = "timeout"
        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(BatteryControlReport.self, from: encoded), report)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "capabilityProbeStatus"); json.removeValue(forKey: "capabilityProbeFailure")
        let old = try JSONDecoder().decode(BatteryControlReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.capabilityDetectionPending); XCTAssertFalse(old.available)
    }
}
