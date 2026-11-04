import XCTest
@testable import SuperIsland

@MainActor
final class BatteryObservationCompletionTests: XCTestCase {
    private func sample(now: Date, level: Int = 85, connected: Bool? = true, charging: Bool? = false) -> BatteryTelemetry {
        var fields: [String: Any] = ["BatteryInstalled": true, "CurrentCapacity": level,
                                     "MaxCapacity": 100, "InstantAmperage": 0]
        if let connected { fields["ExternalConnected"] = connected; fields["AppleRawExternalConnected"] = connected }
        if let charging { fields["IsCharging"] = charging }
        return BatteryTelemetry.decode(fields, readAt: now)
    }
    private func state(now: Date, mode: BatteryControlMode) -> BatteryScheduleObservation {
        var report = BatteryControlReport()
        report.available = true; report.mechanism = "SMC CHTE"; report.dischargeSupported = true
        report.mode = mode; report.timestamp = now
        return .init(operationID: UUID(), preferences: .init(), telemetry: sample(now: now), report: report, enabled: true)
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "SuperIsland.BM1.ObservationCompletion.\(UUID())")! }

    func testReadOnlyStatusDistinguishesMissingChargingFlagFromFalse() async {
        let now = Date(), store = defaults()
        for flag: Bool? in [nil, false, true] {
            let query = BatteryReadOnlyQueries(defaults: store,
                readTelemetry: { self.sample(now: now, charging: flag) }, inspect: { .init() })
            let text = await query.status()
            let expected = flag.map { $0 ? "正在充电" : "当前未充电" } ?? "充电状态未知"
            XCTAssertTrue(text.contains(expected))
            if flag == nil { XCTAssertFalse(text.contains("当前未充电")) }
        }
        XCTAssertNil(store.data(forKey: "batteryManagement.preferences"))
        XCTAssertNil(store.data(forKey: "batteryManagement.scheduleStore"))
    }

    func testPauseNeedsObservedNotChargingAndFiniteCurrentWhileConnected() async throws {
        let now = Date(), store = defaults()
        defer { store.removeObject(forKey: "batteryManagement.scheduleStore") }
        var observed = state(now: now, mode: .paused)
        observed.telemetry = sample(now: now, charging: nil)
        let scheduler = BatteryScheduleService(defaults: store, now: { now }, execution: { _ in "accepted" }, observation: { observed })
        var task = BatteryScheduledTask(); task.action = .pause
        _ = try await scheduler.runNow(task)
        XCTAssertEqual(scheduler.runs.first?.status, "已提交")
        observed.telemetry = sample(now: now, connected: nil)
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "已提交")
        observed.telemetry = sample(now: now); observed.telemetry.current = -.infinity
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "已提交")
        observed.telemetry.current = 0
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "已应用")
    }

    func testUnknownPowerCannotAbortPendingDischarge() async throws {
        let now = Date(), store = defaults()
        defer { store.removeObject(forKey: "batteryManagement.scheduleStore") }
        var observed = state(now: now, mode: .discharge)
        observed.telemetry = sample(now: now, connected: nil)
        let scheduler = BatteryScheduleService(defaults: store, now: { now }, execution: { _ in "accepted" }, observation: { observed })
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await scheduler.runNow(task)
        XCTAssertEqual(scheduler.runs.first?.status, "已提交")
        XCTAssertNotNil(scheduler.runs.first?.verification)
        observed.telemetry = sample(now: now, connected: false)
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "已中止")
    }

    func testTopUpFullAndAutomaticWithUnknownPowerCannotBecomeCompleted() async throws {
        let now = Date(), store = defaults()
        defer { store.removeObject(forKey: "batteryManagement.scheduleStore") }
        var observed = state(now: now, mode: .topUp)
        observed.telemetry = sample(now: now, level: 100)
        let scheduler = BatteryScheduleService(defaults: store, now: { now }, execution: { _ in "accepted" }, observation: { observed })
        var task = BatteryScheduledTask(); task.action = .topUp
        _ = try await scheduler.runNow(task)
        XCTAssertEqual(scheduler.runs.first?.status, "保持满电")
        observed.report.mode = .automatic
        observed.report.completedOperationID = observed.operationID; observed.report.completionReason = .powerDisconnected
        observed.telemetry = sample(now: now, level: 100, connected: nil)
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "待确认")
        XCTAssertNotNil(scheduler.runs.first?.verification)
        XCTAssertTrue(scheduler.runs.first?.detail.contains("未知") == true)
        observed.telemetry = sample(now: now, level: 100, connected: false)
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "已完成")
        XCTAssertNil(scheduler.runs.first?.verification)
    }

    func testTopUpCannotClaimCompletionWithoutItsOwnCompletionReceipt() async throws {
        let now = Date(), store = defaults()
        defer { store.removeObject(forKey: "batteryManagement.scheduleStore") }
        var observed = state(now: now, mode: .topUp)
        observed.telemetry = sample(now: now, level: 100)
        let scheduler = BatteryScheduleService(defaults: store, now: { now }, execution: { _ in "accepted" }, observation: { observed })
        var task = BatteryScheduledTask(); task.action = .topUp
        _ = try await scheduler.runNow(task)
        observed.report.mode = .automatic; observed.report.completedOperationID = UUID()
        observed.report.completionReason = .powerDisconnected
        observed.telemetry = sample(now: now, level: 100, connected: false)
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "结果未确认")
        XCTAssertFalse(scheduler.runs.first?.detail.contains("已观察满电并断开") == true)
    }

    func testNativeDischargeNeedsObservedChargeStateBeforeCompleting() async throws {
        let now = Date(), store = defaults()
        defer { store.removeObject(forKey: "batteryManagement.scheduleStore") }
        var observed = state(now: now, mode: .discharge)
        observed.report.mechanism = "macOS Charge Limit"
        observed.report.dischargeMechanism = .nativeLimit
        let scheduler = BatteryScheduleService(defaults: store, now: { now }, execution: { _ in "accepted" }, observation: { observed })
        var task = BatteryScheduledTask(); task.action = .discharge; task.target = 80
        _ = try await scheduler.runNow(task)
        observed.telemetry = sample(now: now, level: 80, charging: nil)
        observed.report.mode = .automatic; observed.report.ownedAdapterCutoff = false
        observed.report.completedOperationID = observed.operationID; observed.report.completionReason = .targetReached
        scheduler.verifyPending()
        XCTAssertNotEqual(scheduler.runs.first?.status, "已完成")
        observed.telemetry = sample(now: now, level: 80, charging: false)
        scheduler.verifyPending()
        XCTAssertEqual(scheduler.runs.first?.status, "已完成")
    }
}
