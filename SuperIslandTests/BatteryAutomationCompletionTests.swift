import XCTest
import ServiceManagement
@testable import SuperIsland

@MainActor
final class BatteryAutomationCompletionTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SuperIsland.BM1.AutomationCompletion.\(UUID())")!
    }
    private func telemetry(now: Date = Date(), level: Int = 85) -> BatteryTelemetry {
        var result = BatteryTelemetry(); result.hasBattery = true; result.onAC = true
        result.level = level; result.current = 0; result.timestamp = now
        return result
    }
    func testColdWriteSubmitsOnlyItsExplicitRequestAndNeverStartsSchedules() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        var scheduleStarts = 0
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil },
            scheduleStarter: { scheduleStarts += 1 })
        defer { service.shutdown(); defaults.removeObject(forKey: "batteryManagement.preferences") }
        _ = try await service.performAutomation { try await service.setLimitFromAutomation(85) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.preferences.limit, 85)
        XCTAssertEqual(transport.requests.first?.mode, .automatic)
        XCTAssertEqual(scheduleStarts, 0)
        XCTAssertTrue(service.enabled)
        XCTAssertNil(defaults.data(forKey: "batteryManagement.scheduleStore"))
    }
    func testSuccessfulNoOpColdAutomationNeverEnablesDefaultControl() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil })
        defer { service.shutdown() }
        _ = try await service.performAutomation { "No active calibration to cancel" }
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(service.shouldPrepareForTermination)
    }
    func testColdWriteDoesNotStartSavedDisplayPolicyOrKeepAwakeWork() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        var holds = 0, offs = 0, keepAwakeReads = 0
        let screen = BatteryDisplaySleepController(environment: { .init(displayCount: 1, externalDisplayCount: 0) },
            idleTime: { 1000 }, keepAwakeConflict: { keepAwakeReads += 1; return .none },
            hold: { holds += 1; return 19 }, release: { _ in }, turnOff: { offs += 1 })
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil }, scheduleStarter: {}, displaySleepController: screen)
        defer { service.shutdown() }
        service.updateDisplay { $0.screenSleepPolicy = .never }
        _ = try await service.performAutomation { try await service.setLimitFromAutomation(85) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(holds, 0); XCTAssertEqual(offs, 0); XCTAssertEqual(keepAwakeReads, 0)
        XCTAssertTrue(service.displaySleepStatus?.contains("仅保存") == true)
    }
    func testRejectedColdWriteCannotLeaveControllerReadyForDefaultHeartbeat() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil })
        defer { service.shutdown() }
        do {
            _ = try await service.performAutomation { try await service.setLimitFromAutomation(10) }
            XCTFail("Invalid action must be rejected")
        } catch {}
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(defaults.data(forKey: "batteryManagement.preferences"))
    }
    func testWriteIntentDoesNotUndoManualOffInSameProcess() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil })
        defer { service.shutdown() }
        service.start(automaticallyEnable: false)
        service.setEnabled(false)
        for _ in 0..<50 where service.busy { await Task.yield() }
        do {
            _ = try await service.performAutomation { try await service.execute(mode: .paused) }
            XCTFail("Explicit manual disable must survive Intent invocation")
        } catch {}
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testManualOffWhileInspectIsSuspendedIsNotOverwritten() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        transport.suspendInspection = true
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil })
        defer { service.shutdown(); transport.finishInspection() }
        let request = Task { try await service.performAutomation { try await service.execute(mode: .paused) } }
        for _ in 0..<100 where transport.inspection == nil { await Task.yield() }
        XCTAssertNotNil(transport.inspection)
        service.setEnabled(false)
        transport.finishInspection()
        do { _ = try await request.value; XCTFail("Changed control choice must invalidate inspection") } catch {}
        XCTAssertFalse(service.enabled)
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testManualRunClaimsHistoryAndDischargeWaitsForTargetAndRecovery() async throws {
        let defaults = isolatedDefaults(), now = Date()
        var report = BatteryControlReport(); report.available = true; report.mechanism = "SMC CHTE"; report.dischargeSupported = true; report.mode = .discharge
        report.timestamp = now; report.ownedAdapterCutoff = true; report.cutoffPhase = .discharging
        var state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(),
            telemetry: telemetry(now: now, level: 85), report: report, enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in "accepted" }, observation: { state })
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await schedules.runNow(task)
        XCTAssertEqual(schedules.runs.count, 1)
        XCTAssertEqual(schedules.runs.first?.status, "已提交")
        state.telemetry.level = 80; state.report.mode = .automatic
        state.report.completedOperationID = state.operationID; state.report.completionReason = .targetReached
        state.report.recoveryPending = true; state.report.cutoffPhase = .restoring
        schedules.verifyPending()
        XCTAssertEqual(schedules.runs.first?.status, "恢复中")
        state.report.recoveryPending = false; state.report.ownedAdapterCutoff = false; state.report.cutoffPhase = nil
        schedules.verifyPending()
        XCTAssertEqual(schedules.runs.first?.status, "已完成")
        XCTAssertNil(schedules.runs.first?.verification)
    }
    func testOldHelperWithoutCompletionCapabilityRejectsScheduledDischargeBeforeExecution() async throws {
        let defaults = isolatedDefaults(), now = Date()
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(BatteryControlReport())) as? [String: Any])
        object.removeValue(forKey: "completionReceiptsSupported")
        let legacy = try JSONDecoder().decode(BatteryControlReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.completionReceiptsSupported)
        let state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(), telemetry: telemetry(now: now), report: legacy, enabled: true)
        var requests = 0
        let schedules = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in requests += 1; return "unexpected" }, observation: { state })
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await schedules.runNow(task)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(schedules.runs.first?.status, "未执行")
        XCTAssertTrue(schedules.runs.first?.detail.contains("需更新辅助程序") == true)
        XCTAssertNil(schedules.runs.first?.verification)
    }
    func testRegistrationReceiptIsNotDischargeCompletionAndNewOperationInterrupts() async throws {
        let defaults = isolatedDefaults(), now = Date()
        var report = BatteryControlReport(); report.available = true; report.mechanism = "SMC CHTE"; report.dischargeSupported = true; report.mode = .automatic
        report.timestamp = now; report.registeredTarget = 80
        var state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(),
            telemetry: telemetry(now: now, level: 85), report: report, enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in "accepted" }, observation: { state })
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await schedules.runNow(task)
        XCTAssertEqual(schedules.runs.first?.status, "已提交")
        state.operationID = UUID(); schedules.verifyPending()
        XCTAssertEqual(schedules.runs.first?.status, "已中止")
    }
    func testEarlyUnplugFollowedByNaturalDropAndReconnectionCannotClaimTargetSuccess() async throws {
        let defaults = isolatedDefaults(), now = Date()
        var report = BatteryControlReport(); report.available = true; report.mechanism = "SMC CHTE"; report.dischargeSupported = true; report.mode = .discharge; report.timestamp = now
        var state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(),
            telemetry: telemetry(now: now, level: 85), report: report, enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in "accepted" }, observation: { state })
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await schedules.runNow(task)
        state.telemetry.level = 80; state.telemetry.onAC = true; state.report.mode = .automatic
        schedules.verifyPending()
        XCTAssertEqual(schedules.runs.first?.status, "已提交", "Target plus automatic mode is insufficient")
        state.report.completedOperationID = state.operationID; state.report.completionReason = .powerDisconnected
        schedules.verifyPending()
        XCTAssertEqual(schedules.runs.first?.status, "已中止")
    }
    func testRestartKeepsPendingResultUnknownWithoutReplaying() async throws {
        let defaults = isolatedDefaults(), now = Date()
        var report = BatteryControlReport(); report.available = true; report.mechanism = "SMC CHTE"; report.dischargeSupported = true; report.mode = .discharge; report.timestamp = now
        let state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(),
            telemetry: telemetry(now: now), report: report, enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in "accepted" }, observation: { state })
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var task = BatteryScheduledTask(); task.action = .discharge
        _ = try await schedules.runNow(task)
        var requests = 0
        let relaunched = BatteryScheduleService(defaults: defaults, now: { now }, execution: { _ in requests += 1; return "unexpected" })
        XCTAssertEqual(relaunched.runs.first?.status, "结果未确认")
        XCTAssertNil(relaunched.runs.first?.verification)
        XCTAssertNil(relaunched.evaluate())
        XCTAssertEqual(requests, 0)
    }
    func testInvalidAnchorCannotEraseSavedScheduleEnvelope() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        let schedules = BatteryScheduleService(defaults: defaults, execution: { _ in "unused" })
        var task = BatteryScheduledTask(); task.anchor = Date().addingTimeInterval(3600)
        try schedules.save(task)
        let saved = defaults.data(forKey: "batteryManagement.scheduleStore")
        var invalid = task; invalid.anchor = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try schedules.save(invalid))
        XCTAssertEqual(defaults.data(forKey: "batteryManagement.scheduleStore"), saved)
        XCTAssertEqual(schedules.tasks.count, 1)
        XCTAssertEqual(schedules.tasks.first?.anchor, task.anchor)
    }
    func testConcurrentManualRequestsCannotSubmitTwice() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        var pending: CheckedContinuation<String, Error>?
        var requests = 0
        let schedules = BatteryScheduleService(defaults: defaults, execution: { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        let first = Task { try await schedules.runNow(.init()) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        do { _ = try await schedules.runNow(.init()); XCTFail("Concurrent request must be rejected") } catch {}
        pending?.resume(returning: "accepted"); pending = nil
        _ = try await first.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(schedules.runs.count, 1)
    }
    func testManualConflictRecordsPendingConfirmationAndNeverAutoCancels() async throws {
        let defaults = isolatedDefaults()
        var attempts = 0
        let schedules = BatteryScheduleService(defaults: defaults, execution: { _ in
            attempts += 1; throw BatteryControlError.conflict("calibration active")
        })
        defer { defaults.removeObject(forKey: "batteryManagement.scheduleStore") }
        do { _ = try await schedules.runNow(.init()); XCTFail("Conflict must propagate") } catch {}
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(schedules.runs.first?.status, "待确认")
    }
    func testUnsupportedFeaturesRejectBeforePersistenceAndCanBeTurnedOff() async throws {
        let defaults = isolatedDefaults(), transport = AutomationCompletionTransport()
        transport.dischargeSupported = false
        let service = BatteryManagementService(defaults: defaults, client: transport,
            telemetryReader: { self.telemetry() }, conflictChecker: { nil })
        defer { service.shutdown(); defaults.removeObject(forKey: "batteryManagement.preferences") }
        _ = try await service.performAutomation { try await service.setLimitFromAutomation(85) }
        XCTAssertThrowsError(try service.updatePreferences { $0.automaticDischarge = true })
        XCTAssertThrowsError(try service.updatePreferences { $0.sailing = true })
        XCTAssertThrowsError(try service.updatePreferences { $0.led = .green })
        XCTAssertThrowsError(try service.updatePreferences { $0.blinkWhileDischarging = true })
        XCTAssertNoThrow(try service.updatePreferences { $0.automaticDischarge = false; $0.sailing = false; $0.led = .system; $0.blinkWhileDischarging = false })
        XCTAssertFalse(service.preferences.automaticDischarge)
        XCTAssertFalse(service.preferences.sailing)
        XCTAssertEqual(service.preferences.led, .system)
    }
}

@MainActor
private final class AutomationCompletionTransport: BatteryManagementTransport {
    var authorization = SMAppService.Status.enabled
    var helperBundled = true
    var requests: [BatteryControlRequest] = []
    var suspendInspection = false
    var inspection: CheckedContinuation<(Bool, BatteryControlReport), Error>?
    var dischargeSupported = true
    func register() async throws { XCTFail("Automation never registers") }
    func makeReport() -> BatteryControlReport {
        var report = BatteryControlReport(); report.available = true; report.mechanism = "SMC CHTE"
        report.dischargeSupported = dischargeSupported
        return report
    }
    func finishInspection() {
        let continuation = inspection; inspection = nil
        continuation?.resume(returning: (true, makeReport()))
    }
    func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
        var report = makeReport()
        switch command {
        case .inspect:
            if suspendInspection { return try await withCheckedThrowingContinuation { inspection = $0 } }
        case .renew(let request):
            requests.append(request); report.mode = request.mode
            report.registeredTarget = request.preferences.limit; report.nativeSavedLimit = request.preferences.limit
        case .release: break
        }
        return (true, report)
    }
}
