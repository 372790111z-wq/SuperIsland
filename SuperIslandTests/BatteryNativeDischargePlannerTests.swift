import XCTest
#if canImport(SuperIsland)
@testable import SuperIsland
#endif

final class BatteryNativeDischargePlannerTests: XCTestCase {
    private func request(_ mode: BatteryControlMode = .discharge, target: Int = 80, limit: Int = 80) -> BatteryControlRequest {
        var preferences = BatteryControlPreferences(); preferences.limit = limit
        return .init(owner: UUID(), preferences: preferences, mode: mode, dischargeTarget: mode == .discharge ? target : nil)
    }
    func testExplicitDischargeUsesItsTargetWithoutNeutralizingOrCutoff() throws {
        let decision = BatteryControlDecision(target: 80, inhibit: true, forceDischarge: true, reason: "fixture")
        let result = try BatteryNativeDischargePlanner.targets(decision: decision, request: request(), currentLevel: 85)
        XCTAssertEqual(result, ["nativeAPIEnabled": 1, "nativeAPILimit": 80])
        XCTAssertNil(result["CHIE"]); XCTAssertNil(result["CH0I"]); XCTAssertNil(result["CH0J"])
        XCTAssertNotEqual(result["nativeAPILimit"], 85); XCTAssertNotEqual(result["nativeAPILimit"], 100)
    }
    func testDifferentExplicitTargetIsNotReplacedByFixedNeutralLimit() throws {
        let result = try BatteryNativeDischargePlanner.targets(
            decision: .init(target: 85, inhibit: true, forceDischarge: true, reason: "fixture"),
            request: request(target: 85, limit: 90), currentLevel: 95)
        XCTAssertEqual(result["nativeAPILimit"], 85)
    }
    func testLowExplicitTargetIsRejectedEvenWhenDecisionWouldHaveUsedSupportedNeutralValue() {
        let decision = BatteryControlDecision(target: 79, inhibit: true, forceDischarge: true, reason: "fixture")
        XCTAssertThrowsError(try BatteryNativeDischargePlanner.targets(decision: decision, request: request(target: 79), currentLevel: 85))
    }
    func testLowAutomaticPreferenceAndOutOfRangeDecisionAreRejectedWithoutClamp() {
        var low = request(.automatic, limit: 79); low.preferences.allowLowLimit = true; low.preferences.automaticDischarge = true
        XCTAssertThrowsError(try BatteryNativeDischargePlanner.targets(
            decision: .init(target: 79, inhibit: true, forceDischarge: true, reason: "fixture"), request: low, currentLevel: 85))
        XCTAssertThrowsError(try BatteryNativeDischargePlanner.targets(
            decision: .init(target: 101, forceDischarge: true, reason: "fixture"), request: request(), currentLevel: 100))
    }
    func testOrdinaryAutomaticPolicyHoldsCurrentWithoutUnrequestedDrain() throws {
        var policy = BatteryControlPolicy(), telemetry = BatteryTelemetry()
        telemetry.hasBattery = true; telemetry.level = 85; telemetry.onAC = true
        let request = request(.automatic)
        let decision = try policy.decide(request: request, snapshot: telemetry)
        XCTAssertFalse(decision.forceDischarge)
        let result = try BatteryNativeDischargePlanner.targets(decision: decision, request: request, currentLevel: telemetry.level)
        XCTAssertEqual(result["nativeAPILimit"], 85)
    }
    func testCancelPolicyHoldsCurrentAndDoesNotRestoreLowerLongTermLimit() throws {
        var policy = BatteryControlPolicy(), telemetry = BatteryTelemetry()
        telemetry.hasBattery = true; telemetry.level = 81; telemetry.onAC = true
        let old = request(), next = request(.automatic)
        policy.configure(previous: old, next: next)
        let decision = try policy.decide(request: next, snapshot: telemetry)
        let result = try BatteryNativeDischargePlanner.targets(decision: decision, request: next, currentLevel: telemetry.level)
        XCTAssertEqual(result["nativeAPILimit"], 81)
        XCTAssertEqual(next.preferences.limit, 80)
    }
    func testExplicitlyEnabledAutomaticDischargeCanUseNativeTarget() throws {
        var policy = BatteryControlPolicy(), telemetry = BatteryTelemetry(), request = request(.automatic)
        telemetry.hasBattery = true; telemetry.level = 85; telemetry.onAC = true
        request.preferences.automaticDischarge = true
        let decision = try policy.decide(request: request, snapshot: telemetry)
        XCTAssertTrue(decision.forceDischarge)
        let result = try BatteryNativeDischargePlanner.targets(decision: decision, request: request, currentLevel: telemetry.level)
        XCTAssertEqual(result["nativeAPILimit"], 80)
    }
    func testPauseBelowNativeFloorDoesNotBecomeAnEightyPercentChargeRequest() {
        XCTAssertThrowsError(try BatteryNativeDischargePlanner.targets(
            decision: .init(target: 79, inhibit: true, reason: "fixture"), request: request(.paused), currentLevel: 79))
    }
    func testMissingOrInvalidMeasuredLevelIsNeverReplacedWithTarget() {
        for level in [Int?.none, -1, 101] {
            XCTAssertThrowsError(try BatteryNativeDischargePlanner.targets(
                decision: .init(target: 80, reason: "fixture"), request: request(.automatic), currentLevel: level))
        }
    }
    func testNativePathRejectsCalibrationAndImmediateProtection() {
        var calibration = request(.automatic); calibration.calibration = .start(UUID())
        var heat = request(.automatic); heat.preferences.heatProtection = true
        var sleep = request(.automatic); sleep.preferences.sleep = .pause
        for request in [calibration, heat, sleep] {
            XCTAssertThrowsError(try BatteryNativeDischargePlanner.targets(
                decision: .init(target: 80, reason: "fixture"), request: request, currentLevel: 85))
        }
    }
    func testNativeNewOwnershipAddsNoCutoffWhileHistoricalCutoffCanRestoreZero() throws {
        let fresh = try BatteryCutoffTargets.make(key: "CHIE", forceDischarge: false, ownedKeys: [], read: { _ in 0 })
        XCTAssertTrue(fresh.isEmpty)
        let historical = try BatteryCutoffTargets.make(key: "CHIE", forceDischarge: false, ownedKeys: ["CHIE"], read: { _ in XCTFail("Owned recovery uses its lease"); return 8 })
        XCTAssertEqual(historical, ["CHIE": 0])
        let legacy = try BatteryCutoffTargets.make(key: "CHIE", forceDischarge: true, ownedKeys: [], read: { _ in 0 })
        XCTAssertEqual(legacy, ["CHIE": 8])
    }
    func testNativeRouteDoesNotTakeOverExternalAdapterCutoff() {
        XCTAssertThrowsError(try BatteryCutoffTargets.make(key: "CHIE", forceDischarge: false, ownedKeys: [], read: { _ in 8 }))
    }

}
