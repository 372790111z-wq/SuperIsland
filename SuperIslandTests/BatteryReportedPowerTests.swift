import XCTest
import ServiceManagement
import AppKit
import SwiftUI
@testable import SuperIsland

final class BatteryReportedPowerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_793_347_200)
    private func report(_ input: Any = 33400, _ load: Any = 33400, _ battery: Any = 0,
                        time: Double = 0, counts: [String: Int64] = [:], errors: Int = 0) throws -> BatteryReportedPower {
        var d: [String: Any] = ["SystemPowerIn": input, "SystemLoad": load, "BatteryPower": battery, "PowerTelemetryErrorCount": errors]
        for (key, value) in counts { d[key] = value }
        return try XCTUnwrap(BatteryReportedPower.decode(d, readAt: base.addingTimeInterval(time), batteryUpdateTime: nil))
    }
    func testCapturedPositiveInputAndOffACReportsRetainSignsAndZero() throws {
        let hold = try report()
        XCTAssertEqual(hold.inputWatts, 33.4); XCTAssertEqual(hold.loadWatts, 33.4); XCTAssertEqual(hold.batteryWatts, 0)
        XCTAssertTrue(hold.complete); XCTAssertFalse(hold.inconsistent)
        let off = try report(0, 14516, -14516)
        XCTAssertEqual(off.inputWatts, 0); XCTAssertEqual(off.loadWatts, 14.516); XCTAssertEqual(off.batteryWatts, -14.516)
        XCTAssertFalse(off.inconsistent)
    }
    func testSyntheticChargingAndHybridExerciseSignsWithoutInferringAnUnknownCorner() throws {
        let charging = try report(45000, 15000, 30000)
        let hybrid = try report(15000, 30000, -15000)
        XCTAssertEqual(charging.batteryWatts, 30); XCTAssertEqual(hybrid.batteryWatts, -15)
        XCTAssertFalse(charging.inconsistent); XCTAssertFalse(hybrid.inconsistent)
        let partial = try XCTUnwrap(BatteryReportedPower.decode(["SystemLoad": 15000, "BatteryPower": 30000], readAt: base, batteryUpdateTime: nil))
        XCTAssertNil(partial.inputWatts); XCTAssertFalse(partial.complete)
    }
    func testTelemetryKeepsReportedPowerIndependentOfRatedPowerAndBatteryEstimate() throws {
        let date = Date()
        let s = BatteryTelemetry.decode(["BatteryInstalled": true, "ExternalConnected": true,
            "Voltage": 12400, "InstantAmperage": 1000, "AdapterDetails": ["Watts": 68],
            "PowerTelemetryData": ["SystemPowerIn": 33400, "SystemLoad": 33400, "BatteryPower": 0]], readAt: date)
        XCTAssertEqual(s.power, 12.4); XCTAssertEqual(s.adapterWatts, 68)
        XCTAssertEqual(s.reportedPower?.inputWatts, 33.4); XCTAssertEqual(s.reportedPower?.batteryWatts, 0)
        XCTAssertEqual(s.reportedPower?.readAt, s.timestamp)
        XCTAssertEqual(BatteryMetric.adapter.value(s), "68 W")
        XCTAssertEqual(BatteryMetric.systemInput.value(s), "约33.4 W")
        let missing = BatteryTelemetry.decode(["BatteryInstalled": true, "AdapterDetails": ["Watts": 68]])
        XCTAssertNil(missing.reportedPower); XCTAssertEqual(BatteryMetric.systemInput.value(missing), "—")
    }
    func testMissingWrongTypesNonfiniteAndInvalidRangesDoNotBecomeZero() throws {
        XCTAssertNil(BatteryReportedPower.decode(nil, readAt: base, batteryUpdateTime: nil))
        XCTAssertNil(BatteryReportedPower.decode("not a dictionary", readAt: base, batteryUpdateTime: nil))
        for invalid: Any in [true, false, "33400", Double.nan, Double.infinity, -1, 1_000_001] {
            let r = try report(invalid)
            XCTAssertNil(r.inputWatts); XCTAssertFalse(r.complete); XCTAssertEqual(r.loadWatts, 33.4)
            XCTAssertEqual(r.formatted(.input, at: base), "—")
        }
        XCTAssertNil(try report(0, -1, 0).loadWatts)
        XCTAssertNil(try report(0, 0, Double.nan).batteryWatts)
    }
    func testUnrelatedEnergyAndRatedFieldsCannotFillMissingPowerChannels() throws {
        let r = try XCTUnwrap(BatteryReportedPower.decode(["SystemLoad": 20989,
            "SystemEnergyConsumed": 5830, "WallEnergyEstimate": 6262, "AdapterEfficiencyLoss": 432,
            "Watts": 68], readAt: base, batteryUpdateTime: nil))
        XCTAssertEqual(r.loadWatts, 20.989); XCTAssertNil(r.inputWatts); XCTAssertNil(r.batteryWatts)
    }
    func testCumulativeErrorsAndIndependentCountersDoNotInvalidateObservedZero() throws {
        let r = try report(counts: ["SystemPowerInAccumulatorCount": 120, "SystemLoadAccumulatorCount": 118, "BatteryPowerAccumulatorCount": 16_693], errors: 9)
        XCTAssertTrue(r.complete); XCTAssertEqual(r.batteryWatts, 0); XCTAssertEqual(r.cumulativeErrorCount, 9)
        XCTAssertEqual(r.counters["SystemLoadAccumulatorCount"], 118)
    }
    func testParentUpdateTimeIsOnlyContextAndDoesNotRenewNewReportTime() throws {
        var w = BatteryReportedPowerWindow()
        var first = try report(); first.batteryUpdateTimeContext = base.addingTimeInterval(-56)
        w.record(first)
        var next = first; next.readAt = base.addingTimeInterval(14); next.batteryUpdateTimeContext = base
        w.record(next)
        XCTAssertNil(w.state.lastNewReportObservedAt)
        XCTAssertEqual(w.state.report?.readAt, next.readAt)
        XCTAssertEqual(w.state.report?.batteryUpdateTimeContext, base)
    }
    func testRepeatedReadsNeverRefreshTheNewReportObservation() throws {
        var w = BatteryReportedPowerWindow()
        w.record(try report(time: 0)); w.record(try report(time: 14))
        XCTAssertEqual(w.state.firstObservedAt, base); XCTAssertNil(w.state.lastNewReportObservedAt)
        w.record(try report(20989, 20989, 0, time: 20))
        XCTAssertEqual(w.state.lastNewReportObservedAt, base.addingTimeInterval(20))
        w.record(try report(20989, 20989, 0, time: 30, errors: 1))
        XCTAssertEqual(w.state.lastNewReportObservedAt, base.addingTimeInterval(20))
    }
    func testPublishingCountsCanAdvanceWithoutTheZeroBatteryCount() throws {
        var w = BatteryReportedPowerWindow()
        w.record(try report(time: 0, counts: ["SystemPowerInAccumulatorCount": 100, "BatteryPowerAccumulatorCount": 16_693]))
        w.record(try report(time: 14, counts: ["SystemPowerInAccumulatorCount": 219, "BatteryPowerAccumulatorCount": 16_693]))
        XCTAssertEqual(w.state.lastNewReportObservedAt, base.addingTimeInterval(14))
        XCTAssertEqual(w.state.report?.batteryWatts, 0)
    }
    func testCounterResetOrLossRestartsObservationWithoutClaimingFreshness() throws {
        var w = BatteryReportedPowerWindow()
        w.record(try report(time: 0, counts: ["SystemPowerInAccumulatorCount": 100]))
        w.record(try report(time: 1, counts: ["SystemPowerInAccumulatorCount": 101]))
        XCTAssertNotNil(w.state.lastNewReportObservedAt)
        w.record(try report(time: 2, counts: ["SystemPowerInAccumulatorCount": 1]))
        XCTAssertNil(w.state.lastNewReportObservedAt); XCTAssertEqual(w.state.firstObservedAt, base.addingTimeInterval(2))
        w.record(try report(time: 3))
        XCTAssertNil(w.state.lastNewReportObservedAt); XCTAssertEqual(w.state.firstObservedAt, base.addingTimeInterval(3))
    }
    func testSleepGapClockRollbackAndMissingSnapshotDoNotCarryFreshnessForward() throws {
        var w = BatteryReportedPowerWindow()
        w.record(try report(time: 0)); w.record(try report(20000, 20000, 0, time: 1))
        w.record(try report(10000, 10000, 0, time: 122))
        XCTAssertNil(w.state.lastNewReportObservedAt)
        w.record(try report(time: 2)); XCTAssertEqual(w.state.firstObservedAt, base.addingTimeInterval(2))
        XCTAssertNil(w.state.lastNewReportObservedAt)
        w.record(nil); XCTAssertNil(w.state.report); XCTAssertNil(w.state.firstObservedAt)
    }
    func testContradictionAndInternalDisagreementNeverRewriteReportedNumbers() throws {
        let r = try report(33400, 5000, 0)
        XCTAssertTrue(r.inconsistent); XCTAssertTrue(r.contradictsSupply(false))
        XCTAssertFalse(r.contradictsSupply(nil)); XCTAssertFalse(r.contradictsSupply(true))
        XCTAssertEqual(r.inputWatts, 33.4); XCTAssertEqual(r.loadWatts, 5)
        XCTAssertFalse(try report(0, 0, 0).inconsistent)
    }
    func testExpiredOrFutureReadHasAnExplicitLastReportLabel() throws {
        let r = try report()
        XCTAssertFalse(r.readExpired(at: base.addingTimeInterval(120)))
        XCTAssertTrue(r.readExpired(at: base.addingTimeInterval(121)))
        XCTAssertTrue(r.readExpired(at: base.addingTimeInterval(-1)))
        XCTAssertEqual(r.formatted(.input, at: base.addingTimeInterval(121)), "上次约33.4 W")
        XCTAssertNil(BatteryReportedPower.decode([:], readAt: Date(timeIntervalSince1970: .nan), batteryUpdateTime: nil))
    }
    func testPowerReportAndCountersSurviveTelemetryRoundTrip() throws {
        var s = BatteryTelemetry(); s.reportedPower = try report(counts: ["SystemLoadAccumulatorCount": 100])
        let decoded = try JSONDecoder().decode(BatteryTelemetry.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.reportedPower, s.reportedPower)
    }
}

@MainActor
final class BatteryReportedPowerServiceTests: XCTestCase {
    private final class NoControlTransport: BatteryManagementTransport {
        var calls = 0
        var authorization = SMAppService.Status.notRegistered
        var helperBundled = false
        func register() async throws { calls += 1; XCTFail("Power reports must not register helpers") }
        func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
            calls += 1; XCTFail("Power reports must not contact helpers"); return (false, .init())
        }
    }
    func testMetricRefreshAndSelectionUseSameReadOnlySnapshotWithoutControlRequests() throws {
        let domain = "BM1ReportedPower.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let t = NoControlTransport()
        let time = Date()
        var sample = BatteryTelemetry.decode(["BatteryInstalled": true,
            "PowerTelemetryData": ["SystemPowerIn": 33400, "SystemLoad": 33400, "BatteryPower": 0]], readAt: time)
        let s = BatteryManagementService(defaults: defaults, client: t, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        defer { s.shutdown() }
        s.refreshTelemetry()
        XCTAssertEqual(s.reportedPower.report, s.telemetry.reportedPower)
        s.updateDisplay { $0.metrics = [.systemInput, .systemLoad, .power, .temperature, .voltage, .current, .health] }
        XCTAssertEqual(s.display.metrics.count, 6)
        XCTAssertEqual(BatteryMetric.systemLoad.value(s.telemetry), s.reportedPower.report?.formatted(.load))
        sample = BatteryTelemetry.decode(["BatteryInstalled": true,
            "PowerTelemetryData": ["SystemPowerIn": 20989, "SystemLoad": 20989, "BatteryPower": 0]], readAt: time.addingTimeInterval(1))
        s.refreshTelemetry()
        XCTAssertEqual(s.reportedPower.lastNewReportObservedAt, time.addingTimeInterval(1))
        XCTAssertEqual(t.calls, 0); XCTAssertFalse(s.enabled)
    }
    func testNativePowerReportExposesNumbersAndUnknownSamplingWithoutLiveArrows() async throws {
        var w = BatteryReportedPowerWindow()
        let report = try XCTUnwrap(BatteryReportedPower.decode(["SystemPowerIn": 33400, "SystemLoad": 33400, "BatteryPower": 0], readAt: Date(), batteryUpdateTime: nil))
        w.record(report)
        let host = NSHostingView(rootView: BatteryReportedPowerView(state: w.state, supply: true).padding(20))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "BM1 功率报告只读验证"; window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func texts() -> [String] {
            var seen = Set<ObjectIdentifier>(), result: [String] = []
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                for key in ["accessibilityLabel", "accessibilityValue"] {
                    let sel = NSSelectorFromString(key)
                    if object.responds(to: sel), let text = object.perform(sel)?.takeUnretainedValue() as? String { result.append(text) }
                }
                let sel = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: sel), let children = object.perform(sel)?.takeUnretainedValue() as? [NSObject] { children.forEach(visit) }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            visit(window); return result
        }
        var values: [String] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); values = texts()
            let ready = values.joined()
            if ["33.4 W", "0.0 W", "暂不展示实时流向", "采样时刻未提供"].allSatisfy(ready.contains) { break }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        let text = values.joined(separator: "\n")
        XCTAssertTrue(text.contains("33.4 W")); XCTAssertTrue(text.contains("0.0 W"))
        XCTAssertTrue(text.contains("暂不展示实时流向"))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/bm1-reported-power/native-accessibility.txt")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: output, atomically: true, encoding: .utf8)
    }
}
