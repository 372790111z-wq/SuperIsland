import XCTest
import ServiceManagement
@testable import SuperIsland

@MainActor
final class BatteryPreferenceCompatibilityTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "BatteryCompatibilityTests." + UUID().uuidString
        let result = UserDefaults(suiteName: name)!
        result.removePersistentDomain(forName: name)
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
    private func native() -> BatteryControlReport {
        var result = BatteryControlReport()
        result.available = true; result.mechanism = "macOS Charge Limit"
        result.dischargeSupported = true; result.minimumDischargeTarget = 80
        result.calibrationSupported = false
        return result
    }
    private func legacy() -> BatteryControlPreferences {
        var result = BatteryControlPreferences()
        result.limit = 70; result.allowLowLimit = true
        result.heatProtection = true; result.sleep = .pause
        return result
    }
    private func telemetry() -> BatteryTelemetry {
        var result = BatteryTelemetry()
        result.hasBattery = true; result.onAC = true; result.level = 80; result.current = 0
        return result
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    func testPartialRepairChangesOnlyTheExplicitlyResolvedField() {
        let old = legacy(); var next = old; next.heatProtection = false
        XCTAssertTrue(BatteryPreferenceCompatibility.isPartialRepair(from: old, to: next, report: native()))
        XCTAssertEqual(next.limit, 70); XCTAssertEqual(next.sleep, .pause)
        XCTAssertThrowsError(try BatteryPreferenceCompatibility.validate(next, report: native()))
    }
    func testRepairCannotChangeAnotherStillUnsupportedTarget() {
        let old = legacy(); var next = old
        next.heatProtection = false; next.limit = 75
        XCTAssertFalse(BatteryPreferenceCompatibility.isPartialRepair(from: old, to: next, report: native()))
    }
    func testRepairCannotEnableANewUnsupportedRuleOrChangeUnrelatedValues() {
        let old = legacy(); var next = old
        next.heatProtection = false; next.led = .green
        XCTAssertFalse(BatteryPreferenceCompatibility.isPartialRepair(from: old, to: next, report: native()))
        next = old; next.heatProtection = false; next.maximumTemperature = 36
        XCTAssertFalse(BatteryPreferenceCompatibility.isPartialRepair(from: old, to: next, report: native()))
    }
    func testRepairCannotPersistStructurallyInvalidPreferences() {
        let old = legacy(); var next = old
        next.heatProtection = false; next.allowLowLimit = false
        XCTAssertFalse(BatteryPreferenceCompatibility.isPartialRepair(from: old, to: next, report: native()))
    }
    func testReviewRetainsOtherRulesWhileOneIsExplicitlyRemoved() {
        var report = native(); report.nativeCutoffReviewTrial = true
        var old = legacy(); old.lowPower = .always
        var next = old; next.heatProtection = false
        XCTAssertTrue(BatteryPreferenceCompatibility.isPartialRepair(from: old, to: next, report: report))
        XCTAssertEqual(next.lowPower, .always); XCTAssertEqual(next.sleep, .pause)
    }
    func testServiceCanRepairCombinationWithoutAnyNewControlSubmission() async throws {
        let store = defaults(), transport = CompatibilityTransport(report: native())
        try store.set(JSONEncoder().encode(legacy()), forKey: "batteryManagement.preferences")
        let service = BatteryManagementService(defaults: store, client: transport,
            telemetryReader: telemetry, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.start(); await settle()
        XCTAssertFalse(service.enabled)
        let previous = transport.requests.count
        XCTAssertEqual(previous, 1)
        try service.updatePreferences { $0.heatProtection = false }; await settle()
        XCTAssertEqual(service.preferences.limit, 70)
        XCTAssertEqual(service.preferences.sleep, .pause)
        XCTAssertEqual(transport.requests.count, previous)
        XCTAssertTrue(service.report.message.contains("充电上限"))
        try service.updatePreferences { $0.sleep = .unchanged }; await settle()
        try service.updatePreferences { $0.limit = 80; $0.allowLowLimit = false }; await settle()
        XCTAssertEqual(transport.requests.count, previous)
        XCTAssertFalse(service.enabled)
        let persisted = try JSONDecoder().decode(BatteryControlPreferences.self,
            from: XCTUnwrap(store.data(forKey: "batteryManagement.preferences")))
        XCTAssertEqual(persisted, service.preferences)
        service.setEnabled(true); await settle()
        XCTAssertTrue(service.enabled)
        XCTAssertEqual(transport.requests.count, previous + 1)
    }
    func testPartialRepairCannotDisplaceAnExistingControllerLease() async throws {
        let store = defaults(), transport = CompatibilityTransport(report: native())
        transport.acceptUnsupported = true
        try store.set(JSONEncoder().encode(legacy()), forKey: "batteryManagement.preferences")
        let service = BatteryManagementService(defaults: store, client: transport,
            telemetryReader: telemetry, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.start(); await settle()
        XCTAssertTrue(service.enabled)
        let before = service.preferences, requests = transport.requests.count
        XCTAssertThrowsError(try service.updatePreferences { $0.heatProtection = false })
        XCTAssertEqual(service.preferences, before)
        XCTAssertEqual(transport.requests.count, requests)
        XCTAssertEqual(transport.releases, 0)
    }
    func testDisabledLegacyTaskCanBeSavedButCannotBeEnabledOrExecuted() async throws {
        var task = BatteryScheduledTask(); task.action = .limit; task.target = 70; task.enabled = false
        var requests = 0
        let state = BatteryScheduleObservation(operationID: UUID(), preferences: legacy(),
            telemetry: telemetry(), report: native(), enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults(), execution: { _ in requests += 1; return "unexpected" }, observation: { state })
        try schedules.save(task)
        XCTAssertEqual(schedules.tasks.first?.target, 70)
        schedules.setEnabled(task.id, true)
        XCTAssertFalse(try XCTUnwrap(schedules.tasks.first).enabled)
        XCTAssertNotNil(schedules.configurationError)
        do { _ = try await schedules.runNow(task); XCTFail("Unsupported target must be rejected") } catch {}
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(schedules.runs.first?.status, "未执行")
    }
    func testCalibrationKnownUnsupportedIsNotDispatched() async throws {
        var task = BatteryScheduledTask(); task.action = .calibrate
        var requests = 0
        let state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(),
            telemetry: telemetry(), report: native(), enabled: true)
        let schedules = BatteryScheduleService(defaults: defaults(), execution: { _ in requests += 1; return "unexpected" }, observation: { state })
        XCTAssertThrowsError(try schedules.save(task))
        task.enabled = false; try schedules.save(task)
        do { _ = try await schedules.runNow(task); XCTFail("Calibration is unsupported") } catch {}
        XCTAssertEqual(requests, 0); XCTAssertEqual(schedules.runs.first?.status, "未执行")
    }
    func testUnknownCapabilityDoesNotInventPermanentCalibrationRejection() throws {
        var task = BatteryScheduledTask(); task.action = .calibrate
        let state = BatteryScheduleObservation(operationID: UUID(), preferences: .init(),
            telemetry: telemetry(), report: .init(), enabled: false)
        let schedules = BatteryScheduleService(defaults: defaults(), execution: { _ in "unused" }, observation: { state })
        try schedules.save(task)
        XCTAssertEqual(schedules.tasks.first?.action, .calibrate)
    }
    func testFuturePauseIsNotRejectedOnlyBecauseCurrentChargeIsLow() {
        var task = BatteryScheduledTask(); task.action = .pause
        XCTAssertNil(BatteryPreferenceCompatibility.taskWarning(task, report: native()))
    }
    func testReviewTaskEnvelopeRemainsNarrowAndOldTargetIsNotClamped() {
        var report = native(); report.nativeCutoffReviewTrial = true
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 79
        XCTAssertNotNil(BatteryPreferenceCompatibility.taskWarning(task, report: report))
        XCTAssertEqual(task.target, 79)
        task.action = .topUp
        XCTAssertNotNil(BatteryPreferenceCompatibility.taskWarning(task, report: report))
    }
    func testFailedTaskDeletionRetainsTaskAndCachedStore() throws {
        let domain = "BatteryScheduleFlushTests." + UUID().uuidString
        let store = try XCTUnwrap(UnflushedDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        let schedules = BatteryScheduleService(defaults: store, execution: { _ in "unused" })
        let task = BatteryScheduledTask()
        try schedules.save(task)
        let original = schedules.tasks, encoded = store.data(forKey: "batteryManagement.scheduleStore")
        store.refuse = true
        schedules.delete(task.id)
        XCTAssertEqual(schedules.tasks, original)
        XCTAssertEqual(store.data(forKey: "batteryManagement.scheduleStore"), encoded)
        XCTAssertTrue(schedules.configurationError?.contains("未确认保存") == true)
        store.refuse = false
        schedules.delete(task.id)
        XCTAssertTrue(schedules.tasks.isEmpty)
        XCTAssertNil(schedules.configurationError)
    }
    func testFailedHistoryClearRetainsRecordsAndCachedStore() async throws {
        let domain = "BatteryScheduleFlushTests." + UUID().uuidString
        let store = try XCTUnwrap(UnflushedDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        let schedules = BatteryScheduleService(defaults: store, execution: { _ in "fake submitted" })
        _ = try await schedules.runNow(BatteryScheduledTask())
        XCTAssertEqual(schedules.runs.count, 1)
        let original = schedules.runs, encoded = store.data(forKey: "batteryManagement.scheduleStore")
        store.refuse = true
        schedules.clearHistory()
        XCTAssertEqual(schedules.runs, original)
        XCTAssertEqual(store.data(forKey: "batteryManagement.scheduleStore"), encoded)
        XCTAssertTrue(schedules.configurationError?.contains("未确认保存") == true)
        store.refuse = false
        schedules.clearHistory()
        XCTAssertTrue(schedules.runs.isEmpty)
        XCTAssertNil(schedules.configurationError)
    }
    func testIntelUnsupportedProtectionCannotAlterActivePreferencesOrLease() async throws {
        var r = native(); r.mechanism = "Intel BCLM"; r.dischargeSupported = false
        let transport = CompatibilityTransport(report: r), store = defaults()
        let service = BatteryManagementService(defaults: store, client: transport,
            telemetryReader: telemetry, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.start(); await settle()
        XCTAssertTrue(service.enabled)
        let requests = transport.requests.count, old = service.preferences
        XCTAssertThrowsError(try service.updatePreferences { $0.heatProtection = true })
        XCTAssertThrowsError(try service.updatePreferences { $0.sleep = .pause })
        XCTAssertEqual(service.preferences, old); XCTAssertEqual(transport.requests.count, requests)
        XCTAssertEqual(transport.releases, 0); XCTAssertTrue(service.enabled)
    }
    func testUnknownRouteCannotBecomeInteractiveFromAnAvailableBadge() async throws {
        var r = native(); r.mechanism = "unrecognized future backend"
        let transport = CompatibilityTransport(report: r)
        let service = BatteryManagementService(defaults: defaults(), client: transport,
            telemetryReader: telemetry, conflictChecker: { nil }, scheduleStarter: {})
        defer { service.shutdown() }
        service.start(); await settle()
        XCTAssertFalse(service.canControl); XCTAssertFalse(service.canPauseCharging)
        let requests = transport.requests.count, old = service.mode
        do { _ = try await service.execute(mode: .paused); XCTFail("Unknown backend must not receive a new control") } catch {}
        XCTAssertEqual(service.mode, old); XCTAssertEqual(transport.requests.count, requests)
    }

}

private final class UnflushedDefaults: UserDefaults, @unchecked Sendable {
    var refuse = false
    override func synchronize() -> Bool { refuse ? false : super.synchronize() }
}

@MainActor
private final class CompatibilityTransport: BatteryManagementTransport {
    var authorization: SMAppService.Status { .enabled }
    var helperBundled: Bool { true }
    var report: BatteryControlReport
    var requests: [BatteryControlRequest] = []
    var releases = 0
    var acceptUnsupported = false
    init(report: BatteryControlReport) { self.report = report }
    func register() async throws {}
    func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
        var reply = report; reply.timestamp = Date()
        switch command {
        case .inspect: return (true, reply)
        case .release:
            releases += 1; reply.leaseHeldByRequester = false; reply.registeredTarget = nil
            return (true, reply)
        case .renew(let request):
            requests.append(request)
            if !acceptUnsupported {
                do { try BatteryPreferenceCompatibility.validate(request.preferences, report: reply) }
                catch { reply.message = error.localizedDescription; reply.leaseHeldByRequester = false; return (false, reply) }
            }
            reply.mode = request.mode; reply.registeredTarget = request.preferences.limit
            reply.nativeSavedLimit = request.preferences.limit; reply.leaseHeldByRequester = true
            return (true, reply)
        }
    }
}
