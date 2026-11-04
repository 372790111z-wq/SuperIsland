import XCTest
import IOKit.pwr_mgt
@testable import SuperIsland

@MainActor
final class BatteryDisplaySleepTests: XCTestCase {
    func testNeverAcquiresOnlyOneOwnAssertionAndSystemReleasesOnlyIt() {
        let fixture = Fixture()
        fixture.update(.never); fixture.update(.never)
        XCTAssertEqual(fixture.holds, 1); XCTAssertTrue(fixture.controller.isHoldingDisplay)
        fixture.update(.system)
        XCTAssertEqual(fixture.releases, [71]); XCTAssertFalse(fixture.controller.isHoldingDisplay)
        XCTAssertEqual(fixture.offCalls, 0)
    }
    func testInactiveOrSleepingReleasesOwnAssertionWithoutTurningOff() {
        for awake in [true, false] {
            let fixture = Fixture(); fixture.update(.never)
            fixture.controller.update(active: !awake, awake: awake, policy: .never)
            XCTAssertFalse(fixture.controller.isHoldingDisplay)
            XCTAssertEqual(fixture.releases, [71]); XCTAssertEqual(fixture.offCalls, 0)
        }
    }
    func testFiveMinuteBoundaryAndOneRequestPerIdlePeriod() async {
        let fixture = Fixture(); fixture.idle = 299.9; fixture.update(.after5)
        await fixture.drain(); XCTAssertEqual(fixture.offCalls, 0)
        fixture.idle = 300; fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 1); XCTAssertTrue(fixture.controller.offRequested)
        for value in [301.0, 500, 900] { fixture.idle = value; fixture.update(.after5) }
        await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        XCTAssertTrue(fixture.controller.reason?.contains("不代表系统已确认") == true)
        fixture.idle = 0.1; fixture.update(.after5)
        fixture.idle = 300; fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 2)
    }
    func testTimedWaitingHoldsBeforeEarlierSystemTimeoutThenReleasesBeforeOff() async {
        for policy in [BatteryDisplaySleepPolicy.after5, .after15] {
            let fixture = Fixture(); fixture.idle = 0
            fixture.update(policy)
            XCTAssertTrue(fixture.controller.isHoldingDisplay)
            XCTAssertEqual(fixture.events, ["hold"])
            fixture.idle = 60; fixture.update(policy)
            XCTAssertEqual(fixture.holds, 1, "A one-minute system idle timeout remains blocked by this own assertion")
            fixture.idle = (policy == .after5 ? 300 : 900)
            fixture.update(policy); await fixture.drain()
            XCTAssertEqual(fixture.events, ["hold", "release:71", "off"])
            XCTAssertFalse(fixture.controller.isHoldingDisplay)
        }
    }
    func testTimedWaitingLetsKA1OffWinAndNeverReacquiresWhileItIsActive() async {
        let fixture = Fixture(); fixture.idle = 10; fixture.update(.after5)
        XCTAssertTrue(fixture.controller.isHoldingDisplay)
        fixture.conflict = .off; fixture.update(.after5)
        XCTAssertFalse(fixture.controller.isHoldingDisplay)
        fixture.update(.after5); fixture.idle = 500; fixture.update(.after5)
        await fixture.drain()
        XCTAssertEqual(fixture.holds, 1); XCTAssertEqual(fixture.releases, [71]); XCTAssertEqual(fixture.offCalls, 0)
    }
    func testTimedWaitingReleaseFailurePreventsOffUntilOwnReleaseIsConfirmed() async {
        let fixture = Fixture(); fixture.idle = 10; fixture.update(.after5)
        fixture.releaseFailure = true; fixture.idle = 300
        fixture.update(.after5); await fixture.drain()
        XCTAssertTrue(fixture.controller.isHoldingDisplay); XCTAssertEqual(fixture.offCalls, 0)
        XCTAssertTrue(fixture.controller.reason?.contains("释放尚未确认") == true)
        fixture.releaseFailure = false; fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.events, ["hold", "release:71", "release:71", "off"])
    }
    func testRealInputAfterOffRebuildsWaitingAssertionAndInvalidEnvironmentReleasesIt() async {
        let fixture = Fixture(); fixture.idle = 400
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        fixture.idle = 0; fixture.update(.after5)
        XCTAssertTrue(fixture.controller.isHoldingDisplay)
        fixture.environment = .init(displayCount: nil, externalDisplayCount: nil)
        fixture.update(.after5)
        XCTAssertFalse(fixture.controller.isHoldingDisplay); XCTAssertEqual(fixture.releases, [71])
    }
    func testUnobservedInputDuringLongInactiveGapRequiresARecentInputBeforeRearming() async {
        let fixture = Fixture(); fixture.uptime = 1000; fixture.idle = 400
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        fixture.controller.update(active: false, awake: true, policy: .after5)
        fixture.uptime = 10_000; fixture.idle = 500
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        XCTAssertNotNil(fixture.controller.reason)
        fixture.idle = 0; fixture.update(.after5)
        fixture.idle = 300; fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 2)
    }
    func testSleepDoesNotRearmWithoutInputAndClockRollbackRemainsUnknown() async {
        let fixture = Fixture(); fixture.uptime = 1000; fixture.idle = 400
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        fixture.controller.update(active: true, awake: false, policy: .after5)
        fixture.uptime = 2000; fixture.idle = 1400
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        fixture.uptime = 1999; fixture.idle = 1400
        fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 1); XCTAssertTrue(fixture.controller.reason?.contains("无法确认用户输入时间") == true)
        fixture.uptime = 2001; fixture.idle = 1401
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
    }
    func testSmallClockSamplingDriftCannotRearmAndInvalidUptimeCannotTurnOff() async {
        let fixture = Fixture(); fixture.uptime = 1000; fixture.idle = 400
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        fixture.uptime = 1015; fixture.idle = 414.6
        fixture.update(.after5); await fixture.drain(); XCTAssertEqual(fixture.offCalls, 1)
        for invalid in [-1.0, Double.nan, .infinity] {
            let invalidFixture = Fixture(); invalidFixture.uptime = invalid; invalidFixture.idle = 500
            invalidFixture.update(.after5); await invalidFixture.drain()
            XCTAssertEqual(invalidFixture.offCalls, 0); XCTAssertNotNil(invalidFixture.controller.reason)
        }
        let inconsistent = Fixture(); inconsistent.uptime = 100; inconsistent.idle = 500
        inconsistent.update(.after5); await inconsistent.drain(); XCTAssertEqual(inconsistent.offCalls, 0)
    }
    func testFifteenMinutePolicyDoesNotUseFiveMinuteBoundary() async {
        let fixture = Fixture(); fixture.idle = 899.9; fixture.update(.after15)
        await fixture.drain(); XCTAssertEqual(fixture.offCalls, 0)
        fixture.idle = 900; fixture.update(.after15); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 1)
    }
    func testUnknownOrExternalDisplaysPreventOff() async {
        for environment in [BatteryDisplaySleepController.Environment(displayCount: 2, externalDisplayCount: 1),
                            .init(displayCount: nil, externalDisplayCount: nil),
                            .init(displayCount: 0, externalDisplayCount: 0)] {
            let fixture = Fixture(); fixture.environment = environment
            fixture.idle = 1000; fixture.update(.after5); await fixture.drain()
            XCTAssertEqual(fixture.offCalls, 0); XCTAssertNotNil(fixture.controller.reason)
        }
    }
    func testAllKA1ScreenConflictsBlockBatteryOffRequests() async {
        for conflict in [BatteryDisplaySleepController.Conflict.awake, .off, .unknown] {
            let fixture = Fixture(); fixture.conflict = conflict; fixture.idle = 1000
            fixture.update(.after5); await fixture.drain()
            XCTAssertEqual(fixture.offCalls, 0); XCTAssertNotNil(fixture.controller.reason)
        }
    }
    func testKA1OffAndUnknownPreventNeverAssertion() {
        for conflict in [BatteryDisplaySleepController.Conflict.off, .unknown] {
            let fixture = Fixture(); fixture.conflict = conflict; fixture.update(.never)
            XCTAssertEqual(fixture.holds, 0); XCTAssertNotNil(fixture.controller.reason)
        }
    }
    func testKA1ConflictReleasesPreviouslyHeldOwnAssertion() {
        let fixture = Fixture(); fixture.update(.never)
        fixture.conflict = .off; fixture.update(.never)
        XCTAssertEqual(fixture.releases, [71]); XCTAssertFalse(fixture.controller.isHoldingDisplay)
    }
    func testInvalidIdleValuesCannotTurnOffOrRearm() async {
        for invalid in [Double.nan, .infinity, .greatestFiniteMagnitude, -1] {
            let fixture = Fixture(); fixture.idle = invalid; fixture.update(.after5)
            await fixture.drain(); XCTAssertEqual(fixture.offCalls, 0)
            XCTAssertNotNil(fixture.controller.reason)
        }
        let fixture = Fixture(); fixture.idle = nil; fixture.update(.after5)
        await fixture.drain(); XCTAssertEqual(fixture.offCalls, 0)
    }
    func testFailedOffDoesNotRetryOnEveryTickOrTransientControlLoss() async {
        let fixture = Fixture(); fixture.offFailure = true; fixture.idle = 500
        fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 1)
        XCTAssertTrue(fixture.controller.reason?.contains("未确认") == true)
        fixture.controller.update(active: false, awake: true, policy: .after5)
        fixture.idle = 600; fixture.update(.after5); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 1)
        XCTAssertTrue(fixture.controller.reason?.contains("未确认") == true)
        fixture.update(.after15); fixture.idle = 901; fixture.update(.after15); await fixture.drain()
        XCTAssertEqual(fixture.offCalls, 2)
    }
    func testReleaseFailureKeepsOwnershipAndPreventsOffUntilRetrySucceeds() async {
        let fixture = Fixture(); fixture.update(.never); fixture.releaseFailure = true
        fixture.idle = 1000; fixture.update(.after5); await fixture.drain()
        XCTAssertTrue(fixture.controller.isHoldingDisplay); XCTAssertEqual(fixture.offCalls, 0)
        XCTAssertTrue(fixture.controller.reason?.contains("释放尚未确认") == true)
        fixture.releaseFailure = false; fixture.update(.after5); await fixture.drain()
        XCTAssertFalse(fixture.controller.isHoldingDisplay); XCTAssertEqual(fixture.offCalls, 1)
        XCTAssertEqual(fixture.releases, [71, 71])
    }
    func testAcquireFailureNeverClaimsHolding() {
        let fixture = Fixture(); fixture.holdFailure = true; fixture.update(.never)
        XCTAssertFalse(fixture.controller.isHoldingDisplay); XCTAssertNotNil(fixture.controller.reason)
        fixture.controller.shutdown(); XCTAssertTrue(fixture.releases.isEmpty)
    }
    func testImmediatePreflightRejectsInputHotPlugAndKA1ChangesBeforeActionStarts() async {
        for change in 0..<3 {
            let fixture = Fixture(); fixture.idle = 400; fixture.update(.after5)
            switch change {
            case 0: fixture.idle = 0
            case 1: fixture.environment = .init(displayCount: 2, externalDisplayCount: 1)
            default: fixture.conflict = .awake
            }
            await fixture.drain()
            XCTAssertEqual(fixture.offCalls, 0)
            XCTAssertTrue(fixture.controller.reason?.contains("执行前") == true)
        }
    }
    func testInactiveAndPolicyChangeKeepCancellationUncertaintyVisible() async {
        let fixture = Fixture(); fixture.suspendOff = true; fixture.idle = 400
        fixture.update(.after5); await fixture.drain()
        XCTAssertNotNil(fixture.pendingOff)
        fixture.controller.update(active: false, awake: true, policy: .after5)
        XCTAssertTrue(fixture.controller.reason?.contains("已请求取消") == true)
        fixture.controller.update(active: false, awake: true, policy: .system)
        XCTAssertTrue(fixture.controller.reason?.contains("尚未确认") == true)
        fixture.pendingOff?.resume(throwing: CancellationError()); fixture.pendingOff = nil
        await fixture.drain()
        XCTAssertTrue(fixture.controller.reason?.contains("已请求取消") == true)
    }
    func testShutdownCancelsOwnedPendingActionAndIgnoresItsLateResult() async {
        let fixture = Fixture(); fixture.suspendOff = true; fixture.idle = 400
        fixture.update(.after5); await fixture.drain()
        XCTAssertNotNil(fixture.pendingOff)
        fixture.controller.shutdown()
        fixture.pendingOff?.resume(throwing: BatteryControlError.unavailable("late result")); fixture.pendingOff = nil
        await fixture.drain()
        XCTAssertFalse(fixture.controller.reason?.contains("late result") == true)
        XCTAssertEqual(fixture.offCalls, 1)
    }
}

@MainActor
private final class Fixture {
    var environment = BatteryDisplaySleepController.Environment(displayCount: 1, externalDisplayCount: 0)
    var idle: TimeInterval? = 0
    var uptime: TimeInterval = 10_000
    var conflict = BatteryDisplaySleepController.Conflict.none
    var holds = 0, offCalls = 0
    var releases: [IOPMAssertionID] = []
    var events: [String] = []
    var holdFailure = false, releaseFailure = false, offFailure = false, suspendOff = false
    var pendingOff: CheckedContinuation<Void, Error>?
    lazy var controller = BatteryDisplaySleepController(environment: { self.environment }, idleTime: { self.idle }, uptime: { self.uptime },
        keepAwakeConflict: { self.conflict }, hold: {
            self.holds += 1; self.events.append("hold")
            if self.holdFailure { throw BatteryControlError.unavailable("injected hold rejection") }
            return 71
        }, release: { id in
            self.releases.append(id); self.events.append("release:\(id)")
            if self.releaseFailure { throw BatteryControlError.unavailable("injected release rejection") }
        }, turnOff: {
            self.offCalls += 1; self.events.append("off")
            if self.suspendOff { try await withCheckedThrowingContinuation { self.pendingOff = $0 } }
            if self.offFailure { throw BatteryControlError.unavailable("injected timeout; exit unconfirmed") }
        })
    func update(_ policy: BatteryDisplaySleepPolicy) { controller.update(active: true, awake: true, policy: policy) }
    func drain() async { for _ in 0..<30 { await Task.yield() } }
}
