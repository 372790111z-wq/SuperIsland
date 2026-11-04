import XCTest
@testable import SuperIsland

final class BatteryProductionNativeLifecycleTests: XCTestCase {
    private func date(_ t: Double) -> Date { Date(timeIntervalSince1970: 2_000_000_000 + t) }
    private func telemetry(level: Int = 80, update: Double, read: Double) -> BatteryTelemetry {
        var value = BatteryTelemetry()
        value.hasBattery = true; value.level = level; value.onAC = true; value.charging = false
        value.current = 0; value.voltage = 12; value.temperature = 30
        value.reportedPower = .init(readAt: date(read), batteryUpdateTimeContext: date(update),
            inputWatts: 5, loadWatts: 5, batteryWatts: 0, counters: [:])
        return value
    }
    func testExitHoldRequiresTwoPostSubmissionUpdatesNotRepeatedReads() throws {
        var v = BatteryExitHoldVerification(target: 80, started: 0, submittedAt: date(0))
        XCTAssertFalse(try v.observe(telemetry(update: -1, read: 5), registered: [80], saved: 80, input: true, now: 5, date: date(5)))
        XCTAssertFalse(try v.observe(telemetry(update: 40, read: 45), registered: [80], saved: 80, input: true, now: 45, date: date(45)))
        XCTAssertFalse(try v.observe(telemetry(update: 40, read: 90), registered: [80], saved: 80, input: true, now: 90, date: date(90)))
        XCTAssertTrue(try v.observe(telemetry(update: 100, read: 105), registered: [80], saved: 80, input: true, now: 105, date: date(105)))
    }
    func testExitHoldUnknownChargingOrCurrentDoesNotAuthorizeTransfer() throws {
        var v = BatteryExitHoldVerification(target: 80, started: 0, submittedAt: date(0))
        var missing = telemetry(update: 40, read: 45); missing.current = nil
        XCTAssertFalse(try v.observe(missing, registered: [80], saved: 80, input: true, now: 45, date: date(45)))
        var unknown = BatteryTelemetry(); unknown.hasBattery = true; unknown.level = 80; unknown.onAC = true
        unknown.current = 0; unknown.reportedPower = telemetry(update: 100, read: 105).reportedPower
        XCTAssertNil(unknown.chargingObservation)
        XCTAssertFalse(try v.observe(unknown, registered: [80], saved: 80, input: true, now: 105, date: date(105)))
    }
    func testExitHoldTimeoutIsFiniteAndCannotBeExtendedByPolling() throws {
        var v = BatteryExitHoldVerification(target: 80, started: 0, submittedAt: date(0))
        XCTAssertThrowsError(try v.observe(telemetry(update: 151, read: 151), registered: [80], saved: 80, input: true, now: 151, date: date(151)))
    }
    func testStrictCalibrationAcceptsRealMinuteCadenceWithoutDuplicateProgress() throws {
        let runtime = try BatteryCalibrationRuntime(save: { _ in })
        try runtime.accept(.start(UUID()), owner: UUID(), preferences: .init(), supported: true, date: date(0))
        try runtime.tick(telemetry: telemetry(level: 99, update: 0, read: 0), sleeping: false, systemCalibration: false,
            now: 0, date: date(0), strictTelemetry: true) { _, _ in true }
        for t in [35.0, 58.0] {
            try runtime.tick(telemetry: telemetry(level: 100, update: 0, read: t), sleeping: false, systemCalibration: false,
                now: t, date: date(t), strictTelemetry: true) { _, _ in true }
            XCTAssertEqual(runtime.record?.status.phase, .firstCharge)
        }
        try runtime.tick(telemetry: telemetry(level: 100, update: 60, read: 60), sleeping: false, systemCalibration: false,
            now: 60, date: date(60), strictTelemetry: true) { _, _ in true }
        XCTAssertEqual(runtime.record?.status.phase, .discharge)
    }
    func testStrictCalibrationRejectsStaleOrUnknownPowerBeforeDriving() throws {
        let runtime = try BatteryCalibrationRuntime(save: { _ in })
        try runtime.accept(.start(UUID()), owner: UUID(), preferences: .init(), supported: true, date: date(0))
        var sample = telemetry(update: 0, read: 91)
        XCTAssertThrowsError(try runtime.tick(telemetry: sample, sleeping: false, systemCalibration: false,
            now: 91, date: date(91), strictTelemetry: true) { _, _ in XCTFail("stale drive"); return true })
        sample = telemetry(update: 92, read: 92); sample.current = nil
        XCTAssertThrowsError(try runtime.tick(telemetry: sample, sleeping: false, systemCalibration: false,
            now: 92, date: date(92), strictTelemetry: true) { _, _ in XCTFail("unknown drive"); return true })
    }
    func testStrictFiveStageCycleUsesFreshMinuteSamplesAndRestoresBeforeSuccess() throws {
        let runtime = try BatteryCalibrationRuntime(save: { _ in })
        try runtime.accept(.start(UUID()), owner: UUID(), preferences: .init(), supported: true, date: date(0))
        var actions: [Int] = [], restored = false
        for (index, level) in [80, 100, 10, 98, 100, 100, 100, 80].enumerated() {
            let t = Double(index * 60)
            try runtime.tick(telemetry: telemetry(level: level, update: t, read: t), sleeping: false, systemCalibration: false,
                now: t, date: date(t), strictTelemetry: true) { action, _ in
                switch action {
                case .drive(let decision): actions.append(decision.target)
                case .restorePreferences: restored = true
                case .yieldToSystem: XCTFail("Unexpected system override")
                }
                return true
            }
        }
        XCTAssertTrue(actions.contains(10)); XCTAssertTrue(restored)
        XCTAssertEqual(runtime.record?.status.state, .completed)
        XCTAssertNotNil(runtime.record?.status.lastCompletedAt)
    }
    func testLowBatteryThermalHoldNeverRaisesTargetToTwenty() throws {
        var preferences = BatteryControlPreferences(); preferences.heatProtection = true
        let request = BatteryControlRequest(owner: UUID(), preferences: preferences)
        for temperature: Double? in [50, nil] {
            var sample = telemetry(level: 10, update: 0, read: 0); sample.temperature = temperature
            var policy = BatteryControlPolicy()
            let decision = try policy.decide(request: request, snapshot: sample)
            XCTAssertTrue(decision.protectiveHold)
            XCTAssertEqual(try BatteryPreferencesLease.plannedTarget(decision, currentLevel: 10, calibrating: false), 10)
        }
    }
    func testOrdinaryLowTargetCannotBorrowCalibrationOrThermalPath() throws {
        let decision = BatteryControlDecision(target: 10, inhibit: true, forceDischarge: true, reason: "ordinary")
        XCTAssertThrowsError(try BatteryPreferencesLease.plannedTarget(decision, currentLevel: 80, calibrating: false))
        XCTAssertEqual(try BatteryPreferencesLease.plannedTarget(decision, currentLevel: 80, calibrating: true), 10)
    }
    func testUnknownConnectionDoesNotCompleteTemporaryRequest() throws {
        var request = BatteryControlRequest(owner: UUID(), preferences: .init()); request.mode = .topUp
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 80
        var policy = BatteryControlPolicy()
        XCTAssertThrowsError(try policy.decide(request: request, snapshot: sample))
    }
}
