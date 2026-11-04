import XCTest
@testable import SuperIsland

final class BatteryPreferences79WorkerContractTests: XCTestCase {
    private typealias IO = BatteryPreferences79IO
    private typealias Key = BatteryPreferences79Transaction.Key
    private typealias Value = BatteryPreferences79Transaction.Value

    func testAbsentLegacyFlagsAreOnlyPermittedDuringRestoration() throws {
        for key in [Key.isEngaged, .isManuallyChargeLimited] {
            XCTAssertThrowsError(try IO.validateDesired(.absent, for: key, restoring: false))
            XCTAssertNoThrow(try IO.validateDesired(.absent, for: key, restoring: true))
            for enabled in [Value.integer(1), .real(1), .bool(true)] {
                XCTAssertNoThrow(try IO.validateDesired(enabled, for: key, restoring: false))
                XCTAssertNoThrow(try IO.validateDesired(enabled, for: key, restoring: true))
            }
            for invalid in [Value.integer(0), .bool(false), .integer(2), .string("1"), .real(.nan), .date(Date())] {
                for restoring in [false, true] {
                    XCTAssertThrowsError(try IO.validateDesired(invalid, for: key, restoring: restoring))
                }
            }
        }
    }
    func testFeatureStateCannotBeRemovedOrDisabledInEitherDirection() throws {
        for restoring in [false, true] {
            for invalid in [Value.absent, .integer(0), .bool(false), .integer(2), .string("1")] {
                XCTAssertThrowsError(try IO.validateDesired(invalid, for: .mclFeatureState, restoring: restoring))
            }
            XCTAssertNoThrow(try IO.validateDesired(.integer(1), for: .mclFeatureState, restoring: restoring))
        }
    }
    func testManualTargetIsFixed79ForApplyAnd80ForRestore() throws {
        for restoring in [false, true] {
            let target = restoring ? 80 : 79
            XCTAssertNoThrow(try IO.validateDesired(.integer(Int64(target)), for: .mclLimitValue, restoring: restoring))
            for invalid in [Value.integer(Int64(restoring ? 79 : 80)), .integer(78), .integer(81), .absent, .bool(true), .real(.nan)] {
                XCTAssertThrowsError(try IO.validateDesired(invalid, for: .mclLimitValue, restoring: restoring))
            }
        }
        XCTAssertFalse(BatteryNativeReadQuery.limit.accepts(79))
        XCTAssertTrue(BatteryNativeReadQuery.limit.accepts(80))
    }
    func testSignalRequiresEveryStrongKeyIncludingExplicitAbsence() throws {
        let restoration: [Key: Value] = [.mclLimitValue: .integer(80), .mclFeatureState: .integer(1),
                                        .isEngaged: .absent, .isManuallyChargeLimited: .absent]
        XCTAssertNoThrow(try IO.validateSignal(restoration, restoring: true))
        XCTAssertThrowsError(try IO.validateSignal(restoration, restoring: false))
        for key in restoration.keys {
            var missing = restoration; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try IO.validateSignal(missing, restoring: true))
        }
        var extra = restoration; extra[.modeOfOperation] = .integer(7)
        XCTAssertThrowsError(try IO.validateSignal(extra, restoring: true))
        for key in [Key.mclFeatureState, .isEngaged, .isManuallyChargeLimited] {
            var disabled = restoration; disabled[key] = .bool(false)
            XCTAssertThrowsError(try IO.validateSignal(disabled, restoring: true))
        }
    }
    func testApplySignalStillRequiresBothLegacyFlagsEnabled() throws {
        var apply: [Key: Value] = [.mclLimitValue: .integer(79), .mclFeatureState: .integer(1),
                                  .isEngaged: .integer(1), .isManuallyChargeLimited: .bool(true)]
        XCTAssertNoThrow(try IO.validateSignal(apply, restoring: false))
        for key in [Key.isEngaged, .isManuallyChargeLimited] {
            var absent = apply; absent[key] = .absent
            XCTAssertThrowsError(try IO.validateSignal(absent, restoring: false))
        }
        apply[.mclLimitValue] = .integer(80)
        XCTAssertThrowsError(try IO.validateSignal(apply, restoring: false))
    }
    func testGuardKeysAndNewOverridesRemainUnwritable() throws {
        for restoring in [false, true] {
            for key in [Key.initialChargeLimitSetDate, .disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC, .modeOfOperation] {
                XCTAssertThrowsError(try IO.validateDesired(.absent, for: key, restoring: restoring))
                XCTAssertThrowsError(try IO.validateDesired(.integer(1), for: key, restoring: restoring))
            }
            XCTAssertNoThrow(try IO.validateDesired(.absent, for: .mclTempDisabledUntilDate, restoring: restoring))
            XCTAssertThrowsError(try IO.validateDesired(.real(1), for: .mclTempDisabledUntilDate, restoring: restoring))
        }
    }
    func testDeletionAndOriginalComparisonSurviveFixedIOPayloadCoding() throws {
        let request = IO.Write(desired: .absent, expected: .integer(1),
            guards: [.initialChargeLimitSetDate: .real(802769612.70032), .disabledUntil: .absent,
                     .mclOverridenUntilDate: .absent, .mclSavedTargetSoC: .absent],
            bootID: "fixture-boot", expiresContinuous: 12.9, controlDeadline: 70, restoring: true)
        let decoded: IO.Write = try IO.decode(IO.encode(request))
        XCTAssertEqual(decoded.desired, .absent); XCTAssertEqual(decoded.expected, .integer(1))
        XCTAssertTrue(decoded.restoring)
        XCTAssertNoThrow(try IO.validateDesired(decoded.desired, for: .isEngaged, restoring: decoded.restoring))
    }
}
