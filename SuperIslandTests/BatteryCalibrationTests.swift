import XCTest
@testable import SuperIsland

final class BatteryCalibrationTests: XCTestCase {
    private func sample(_ time: Double, current: Float? = 99, os: Float? = 99,
                        power: Float? = 0, charging: Bool = false) -> BatteryCalibrationSample {
        .init(uptime: time, currentPercentage: current, osPercentage: os,
              adapterConnected: true, systemCharging: charging, voltage: 12, current: 0, power: power)
    }
    private func hold() throws -> BatteryCalibrationSession {
        var s = try BatteryCalibrationSession(originalLimit: 80)
        s.observe(sample(0, os: 100), now: 0)
        s.observe(sample(2, current: 10), now: 2)
        s.observe(sample(4, os: 98), now: 4)
        XCTAssertEqual(s.phase, .hold)
        return s
    }
    func testSavedLimitValidationAndManualCompletionCannotSkipCycle() throws {
        for limit in [-1, 0, 19, 101, Int.max] {
            XCTAssertThrowsError(try BatteryCalibrationSession(originalLimit: limit))
        }
        var s = try BatteryCalibrationSession(originalLimit: 80)
        s.interrupt(.cycleFinished)
        s.acknowledgeRestoration(verified: true, now: 1)
        XCTAssertEqual(s.phase, .firstCharge); XCTAssertNil(s.completedAt)
    }
    func testFirstChargeUsesIndependentOSPercentageAndThreeQualifyingSamples() throws {
        var s = try BatteryCalibrationSession(originalLimit: 80)
        s.observe(sample(0, current: 100, os: 97), now: 0)
        XCTAssertEqual(s.phase, .firstCharge)
        s.observe(sample(2, os: 98, power: 0.1), now: 2)
        s.observe(sample(4, os: 98, power: 0.1), now: 4)
        XCTAssertEqual(s.phase, .firstCharge)
        s.observe(sample(6, os: 98, power: 0.1), now: 6)
        XCTAssertEqual(s.phase, .discharge)
    }
    func testDischargeUsesTruncatedCurrentSourceAndRechargeUsesOSSource() throws {
        var s = try BatteryCalibrationSession(originalLimit: 80)
        s.observe(sample(0, os: 100), now: 0)
        s.observe(sample(2, current: 11, os: 0), now: 2)
        XCTAssertEqual(s.phase, .discharge)
        s.observe(sample(4, current: 10.9, os: 80), now: 4)
        XCTAssertEqual(s.phase, .secondCharge)
        s.observe(sample(6, current: 100, os: 97.99), now: 6)
        XCTAssertEqual(s.phase, .secondCharge)
        s.observe(sample(8, current: 97, os: 98), now: 8)
        XCTAssertEqual(s.phase, .hold); XCTAssertNil(s.completedAt)
    }
    func testHoldPowerBoundaryAndChargingFlagMatchReferencePredicate() throws {
        var s = try hold()
        s.observe(sample(6, power: 0.1), now: 6)
        s.observe(sample(8, power: 0.1), now: 8)
        s.observe(sample(10, power: 0.100001), now: 10)
        XCTAssertEqual(s.noInflowSamples, 0)
        s.observe(sample(12, power: 0.1, charging: true), now: 12)
        XCTAssertEqual(s.unreadablePowerSamples, 1)
        for time in [14.0, 16, 18] { s.observe(sample(time, power: 0.1), now: time) }
        XCTAssertEqual(s.phase, .returnToLimit); XCTAssertNil(s.completedAt)
    }
    func testUnreadablePowerFallbackUsesIntegerElapsedStrictlyBeyond3600() throws {
        var s = try hold()
        // Start=4:3600.999seconds must still wait after three invalid reads.
        for time in [3600.0, 3602, 3604.999] {
            s.observe(sample(time, power: nil), now: time)
        }
        XCTAssertEqual(s.unreadablePowerSamples, 3); XCTAssertEqual(s.phase, .hold)
        s.observe(sample(3607, power: nil), now: 3607)
        XCTAssertEqual(s.phase, .returnToLimit)
    }
    func testValidInflowResetsBothFallbackAndNoInflowWindows() throws {
        var s = try hold()
        s.observe(sample(6, power: nil), now: 6)
        s.observe(sample(8, power: nil), now: 8)
        s.observe(sample(10, power: 1, charging: true), now: 10)
        XCTAssertEqual(s.unreadablePowerSamples, 0); XCTAssertEqual(s.noInflowSamples, 0)
        s.observe(sample(12), now: 12); s.observe(sample(14), now: 14)
        s.observe(sample(16, os: 97), now: 16)
        XCTAssertEqual(s.noInflowSamples, 0); XCTAssertEqual(s.phase, .hold)
    }
    func testDuplicateFastOldFutureAndOutOfOrderReadsCannotEarnSamples() throws {
        var s = try hold()
        s.observe(sample(6), now: 6)
        s.observe(sample(6), now: 7); s.observe(sample(7), now: 7)
        s.observe(sample(5), now: 7)
        XCTAssertEqual(s.noInflowSamples, 1)
        s.observe(sample(10), now: 8)
        XCTAssertEqual(s.noInflowSamples, 0)
        s.observe(sample(8), now: 25)
        XCTAssertEqual(s.noInflowSamples, 0)
        s.observe(sample(26), now: 26); s.observe(sample(28), now: 28)
        XCTAssertEqual(s.phase, .hold)
        s.observe(sample(30), now: 30); XCTAssertEqual(s.phase, .returnToLimit)
    }
    func testNonFinitePowerAndInvalidPercentageNeverCountAsNoInflow() throws {
        for invalid in [Float.nan, .infinity, -.infinity] {
            var p = sample(6, power: invalid)
            XCTAssertFalse(p.validPower)
            p = sample(6); p.voltage = invalid; XCTAssertFalse(p.validPower)
            p = sample(6); p.current = invalid; XCTAssertFalse(p.validPower)
        }
        for invalid: Float? in [nil, .nan, .infinity, -1, 101] {
            var s = try BatteryCalibrationSession(originalLimit: 80)
            for t in [0.0, 2, 4] { s.observe(sample(t, os: invalid), now: t) }
            XCTAssertEqual(s.phase, .firstCharge)
        }
        var p = sample(0); p.voltage = 0; XCTAssertFalse(p.validPower)
    }
    func testSystemOverrideYieldsWithoutAdvancingAndDoesNotEarnFallbackTime() throws {
        var s = try hold()
        for t in [6.0, 8, 10] { s.observe(sample(t), now: t, systemCalibration: true) }
        XCTAssertEqual(s.phase, .hold); XCTAssertTrue(s.waitingForSystemCalibration)
        s.observe(sample(12, power: nil), now: 12)
        XCTAssertFalse(s.waitingForSystemCalibration); XCTAssertEqual(s.unreadablePowerSamples, 1)
        s.observe(sample(14), now: 14); s.observe(sample(16), now: 16)
        XCTAssertEqual(s.phase, .hold)
        s.observe(sample(18), now: 18); XCTAssertEqual(s.phase, .returnToLimit)
    }
    func testClockRollbackCannotInheritConsecutiveReadsOrHoldElapsed() throws {
        var s = try hold()
        s.observe(sample(3600, power: nil), now: 3600)
        s.observe(sample(3602, power: nil), now: 3602)
        s.observe(sample(1, power: nil), now: 1)
        s.observe(sample(3, power: nil), now: 3)
        s.observe(sample(5, power: nil), now: 5)
        XCTAssertEqual(s.phase, .hold); XCTAssertNil(s.completedAt)
    }
    func testInvalidUptimeAndLongSamplingGapsResetConsecutiveEvidence() throws {
        var s = try hold()
        s.observe(sample(6), now: 6); s.observe(sample(8), now: 8)
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            s.observe(sample(invalid), now: invalid)
            XCTAssertEqual(s.noInflowSamples, 0)
        }
        s.observe(sample(10), now: 10); s.observe(sample(12), now: 12)
        s.observe(sample(28), now: 28)
        XCTAssertEqual(s.phase, .hold); XCTAssertEqual(s.noInflowSamples, 1)
        s.observe(sample(30), now: 30); XCTAssertEqual(s.phase, .hold)
    }
    func testFullCycleOnlyRecordsSuccessAfterSavedLimitAndVerifiedRestoration() throws {
        var s = try hold()
        for t in [6.0, 8, 10] { s.observe(sample(t), now: t) }
        s.acknowledgeRestoration(verified: true, now: 11)
        XCTAssertEqual(s.phase, .returnToLimit)
        s.observe(sample(12, current: 81), now: 12)
        XCTAssertEqual(s.phase, .returnToLimit)
        s.observe(sample(14, current: 80), now: 14)
        XCTAssertEqual(s.phase, .restoring); XCTAssertNil(s.completedAt)
        s.acknowledgeRestoration(verified: false, now: 15)
        XCTAssertEqual(s.phase, .restoring)
        s.acknowledgeRestoration(verified: true, now: .nan)
        XCTAssertEqual(s.phase, .restoring)
        s.acknowledgeRestoration(verified: true, now: 16)
        XCTAssertEqual(s.phase, .completed); XCTAssertEqual(s.completedAt, 16)
    }
    func testEveryPhaseCanInterruptAndRetryRestorationWithoutSuccessRecord() throws {
        for stage in 0...4 {
            for reason: BatteryCalibrationSession.EndReason in [.cancelled, .protection, .permissionLost, .exit, .timeout, .unplugged] {
                var s = try BatteryCalibrationSession(originalLimit: 80)
                if stage >= 1 { s.observe(sample(0, os: 100), now: 0) }
                if stage >= 2 { s.observe(sample(2, current: 10), now: 2) }
                if stage >= 3 { s.observe(sample(4, os: 98), now: 4) }
                if stage >= 4 { for t in [6.0, 8, 10] { s.observe(sample(t), now: t) } }
                s.interrupt(reason)
                XCTAssertEqual(s.phase, .restoring); XCTAssertEqual(s.endReason, reason)
                s.observe(sample(20, current: 0, os: 100), now: 20)
                s.acknowledgeRestoration(verified: false, now: 21)
                XCTAssertEqual(s.phase, .restoring)
                s.acknowledgeRestoration(verified: true, now: 22)
                XCTAssertEqual(s.phase, .interrupted); XCTAssertNil(s.completedAt)
            }
        }
    }
    func testPhysicalUnplugAndCancellationDuringSuccessfulRestoreDoNotRecordSuccess() throws {
        var s = try hold()
        var unplug = sample(6); unplug.adapterConnected = false
        s.observe(unplug, now: 6)
        XCTAssertEqual(s.phase, .restoring); XCTAssertEqual(s.endReason, .unplugged)
        var finishing = try hold()
        for t in [6.0, 8, 10] { finishing.observe(sample(t), now: t) }
        finishing.observe(sample(12, current: 80), now: 12)
        finishing.interrupt(.cancelled)
        finishing.acknowledgeRestoration(verified: true, now: 14)
        XCTAssertEqual(finishing.phase, .interrupted); XCTAssertNil(finishing.completedAt)
    }
}
