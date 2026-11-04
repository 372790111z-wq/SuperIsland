import XCTest
import ServiceManagement
@testable import SuperIsland

final class BatteryNativeDrainVerificationTests: XCTestCase {
    private func registration(_ fields: String = "", target: Int = 80) -> String {
        "Battery level limits: ({ Terminated = 0; chargeSocLimitSoc = \(target); \(fields) })"
    }
    func testDrainRegistrationRequiresSameManualTargetAndAffirmativeFlag() {
        let fields = "chargeSocLimitReason = manualChargeLimit; chargeSocLimitDrain = 1;"
        XCTAssertEqual(BatteryNativeRegistration.manualDrainMatches(registration(fields), target: 80), true)
        XCTAssertEqual(BatteryNativeRegistration.manualDrainMatches(registration(fields, target: 81), target: 80), false)
        XCTAssertEqual(BatteryNativeRegistration.manualDrainMatches(registration(fields.replacingOccurrences(of: " = 1", with: " = 0")), target: 80), false)
        XCTAssertEqual(BatteryNativeRegistration.manualDrainMatches(registration(fields.replacingOccurrences(of: "manualChargeLimit", with: "optimizedChargeLimit")), target: 80), false)
        XCTAssertNil(BatteryNativeRegistration.manualDrainMatches(registration(), target: 80))
        XCTAssertNil(BatteryNativeRegistration.manualDrainMatches("unavailable", target: 80))
        XCTAssertNil(BatteryNativeRegistration.manualDrainMatches(registration(fields + "chargeSocLimitSoc = 81;"), target: 80))
    }
    func testTerminatedForeignRegistrationCannotInvalidateCurrentManualDrain() {
        let text = "Battery level limits: ({ Terminated = 1; chargeSocLimitSoc = 90; }, { Terminated = 0; chargeSocLimitSoc = 80; chargeSocLimitReason = manualChargeLimit; chargeSocLimitDrain = 1; })"
        XCTAssertEqual(BatteryNativeRegistration.manualDrainMatches(text, target: 80), true)
    }
    func testCurrentWithoutMatchingRegistrationNeverConfirmsDischarge() throws {
        var v = BatteryNativeDrainVerification(responseTimeout: 10)
        let id = UUID()
        XCTAssertFalse(try v.observe(active: true, operationID: id, current: -2, registered: nil, now: 0))
        XCTAssertFalse(try v.observe(active: true, operationID: id, current: -2, registered: false, now: 9))
        XCTAssertThrowsError(try v.observe(active: true, operationID: id, current: -2, registered: false, now: 10))
    }
    func testRegistrationAndZeroOrMissingCurrentNeverConfirmsDischarge() throws {
        var v = BatteryNativeDrainVerification(responseTimeout: 10)
        let id = UUID()
        for (offset, amps) in [Double?.none, 0, 1, .nan, .infinity].enumerated() {
            XCTAssertFalse(try v.observe(active: true, operationID: id, current: amps, registered: true, now: Double(offset)))
        }
        XCTAssertThrowsError(try v.observe(active: true, operationID: id, current: 0, registered: true, now: 10))
    }
    func testARealDischargeCanLaterStallAndMustNotKeepPreviousSuccess() throws {
        var v = BatteryNativeDrainVerification(responseTimeout: 10)
        let id = UUID()
        XCTAssertTrue(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 0))
        XCTAssertFalse(try v.observe(active: true, operationID: id, current: 0, registered: true, now: 2))
        XCTAssertThrowsError(try v.observe(active: true, operationID: id, current: 0, registered: true, now: 12))
    }
    func testHeartbeatsCannotExtendReviewMaximumAndCancellationResetsIt() throws {
        var v = BatteryNativeDrainVerification()
        let id = UUID()
        XCTAssertTrue(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 0, maximumDuration: 600))
        XCTAssertTrue(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 599, maximumDuration: 600))
        XCTAssertThrowsError(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 600, maximumDuration: 600))
        XCTAssertFalse(try v.observe(active: false, operationID: id, current: 0, registered: true, now: 601))
        XCTAssertTrue(try v.observe(active: true, operationID: UUID(), current: -1, registered: true, now: 602, maximumDuration: 600))
    }
    func testBackwardClockFailsRatherThanExtendingAnActiveReview() throws {
        var v = BatteryNativeDrainVerification()
        let id = UUID()
        _ = try v.observe(active: true, operationID: id, current: -1, registered: true, now: 20)
        XCTAssertThrowsError(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 19))
    }
    func testPreparationAndSystemOverrideCannotMoveTheOriginalDeadline() throws {
        var v = BatteryNativeDrainVerification()
        let id = UUID()
        try v.prepare(active: true, operationID: id, now: 0, maximumDuration: 600)
        XCTAssertTrue(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 50, maximumDuration: 600))
        XCTAssertFalse(try v.observe(active: true, operationID: id, current: 2, registered: nil, now: 500, suspended: true, maximumDuration: 600))
        XCTAssertThrowsError(try v.observe(active: true, operationID: id, current: -1, registered: true, now: 600, maximumDuration: 600))
    }
    func testFirstCauseSurvivesRecoveryProgressAndASecondError() throws {
        var report = BatteryControlReport()
        report.preserveFailure(stage: "native read", detail: "query=limit pid=123 phase=querying\nfailed")
        report.message = "正在恢复"
        report.preserveFailure(stage: "恢复自有控制", detail: "second error")
        report.message = "恢复完成"
        let decoded = try JSONDecoder().decode(BatteryControlReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.lastFailure, "native read：query=limit pid=123 phase=queryingfailed")
        XCTAssertEqual(decoded.message, "恢复完成")
    }
}

@MainActor
final class BatteryNativeDrainCapabilityBoundaryTests: XCTestCase {
    func testColdAutomationRejects79BeforeSubmittingAnyRenew() async throws {
        let defaults = UserDefaults(suiteName: "BM1.NativeDrain.\(UUID())")!
        let transport = NativeDrainBoundaryTransport()
        var telemetry = BatteryTelemetry(); telemetry.hasBattery = true; telemetry.level = 81; telemetry.onAC = true
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { telemetry }, conflictChecker: { nil })
        defer { service.shutdown() }
        do {
            _ = try await service.performAutomation { try await service.execute(mode: .discharge, target: 79) }
            XCTFail("native79 must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("80")) }
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testNativeScheduleRejectsLowTargetsAtSaveAndExecution() async throws {
        let defaults = UserDefaults(suiteName: "BM1.NativeDrain.Schedule.\(UUID())")!
        var report = BatteryControlReport(); report.mechanism = "macOS Charge Limit"; report.minimumDischargeTarget = 80
        let state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(), telemetry: .init(), report: report, enabled: false)
        var submissions = 0
        let schedule = BatteryScheduleService(defaults: defaults, execution: { _ in submissions += 1; return "accepted" }, observation: { state })
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 79
        XCTAssertThrowsError(try schedule.save(task))
        do { _ = try await schedule.runNow(task); XCTFail("native79 must be refused") } catch {}
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(schedule.tasks.isEmpty)
    }
    func testNativeScheduleDoesNotFinishWhileBatteryStillDischargesAtTarget() async throws {
        let defaults = UserDefaults(suiteName: "BM1.NativeDrain.StopProof.\(UUID())")!
        let now = Date()
        var report = BatteryControlReport(); report.available = true; report.dischargeSupported = true; report.mode = .discharge
        report.mechanism = "macOS Charge Limit"; report.minimumDischargeTarget = 80; report.dischargeMechanism = .nativeLimit
        var telemetry = BatteryTelemetry(); telemetry.hasBattery = true; telemetry.level = 81
        telemetry.onAC = true; telemetry.charging = false; telemetry.current = -2; telemetry.timestamp = now
        var state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(), telemetry: telemetry, report: report, enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in "accepted" }, observation: { state })
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await schedules.runNow(task)
        state.telemetry.level = 80; state.report.mode = .automatic
        state.report.completedOperationID = state.operationID; state.report.completionReason = .targetReached
        schedules.evaluate()
        XCTAssertNotEqual(schedules.runs.first?.status, "已完成")
        XCTAssertTrue(schedules.runs.first?.detail.contains("等待实际电流") == true)
        let stored = try XCTUnwrap(defaults.data(forKey: "batteryManagement.scheduleStore"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let savedRuns = try XCTUnwrap(envelope["runs"] as? [[String: Any]])
        XCTAssertTrue((savedRuns.first?["detail"] as? String)?.contains("等待实际电流") == true)
        state.telemetry.current = 0
        schedules.evaluate()
        XCTAssertEqual(schedules.runs.first?.status, "已完成")
        XCTAssertFalse(schedules.runs.first?.detail.contains("恢复适配器供电") == true)
    }
}

@MainActor
private final class NativeDrainBoundaryTransport: BatteryManagementTransport {
    var authorization: SMAppService.Status { .enabled }
    var helperBundled: Bool { true }
    var requests: [BatteryControlRequest] = []
    func register() async throws {}
    func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
        var report = BatteryControlReport(); report.available = true
        report.mechanism = "macOS Charge Limit"; report.minimumDischargeTarget = 80
        report.dischargeSupported = true; report.dischargeMechanism = .nativeLimit
        if case .renew(let request) = command { requests.append(request); report.leaseHeldByRequester = true }
        if case .release = command { report.leaseHeldByRequester = false }
        return (true, report)
    }
}
