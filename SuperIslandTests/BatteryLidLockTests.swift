import XCTest
import Darwin
#if !BATTERY_LID_LOCK_STANDALONE
import Combine
import ServiceManagement
#endif
@testable import SuperIsland

@MainActor
final class BatteryLidLockTests: XCTestCase {
    func testRequiresObservedOpenToClosedAndRequestsOncePerEdge() async {
        let f = Fixture(); f.current.closed = true; f.update(); await f.drain()
        XCTAssertEqual(f.requests, 0)
        f.current.closed = false; f.update(); f.current.closed = true; f.update()
        await f.drain(); XCTAssertEqual(f.requests, 1)
        for _ in 0..<5 { f.controller.observe(); f.update() }
        await f.drain(); XCTAssertEqual(f.requests, 1)
        f.current.closed = false; f.update(); f.current.closed = true; f.update()
        await f.drain(); XCTAssertEqual(f.requests, 2)
    }
    func testZeroReceiptAndSpoofedNotificationCannotProveLock() async {
        let f = Fixture(); f.edge(); await f.drain()
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.controller.status, "锁屏未确认；未重复提交本次合盖请求。")
        f.controller.observe(); await f.drain()
        XCTAssertEqual(f.requests, 1)
    }
    func testFreshLockReadbackIsSeparateFromZeroNonzeroAndFailedReceipt() async {
        for result in [Int32(0), 1, -1] {
            let f = Fixture(); f.result = result
            f.afterRequest = { f.current.lock = .locked }
            f.edge(); await f.drain()
            XCTAssertEqual(f.requests, 1)
            XCTAssertTrue(f.controller.status?.hasPrefix("已读回系统锁屏") == true)
            XCTAssertEqual(f.controller.status?.contains("回执异常"), result != 0)
        }
        let f = Fixture(); f.failure = true; f.afterRequest = { f.current.lock = .locked }
        f.edge(); await f.drain()
        XCTAssertTrue(f.controller.status?.contains("回执异常") == true)
    }
    func testUnknownBreaksEdgeInsteadOfReplayingWhenKnownAgain() async {
        for value in [BatteryLidLockFacts(closed: nil, session: 9, lock: .unlocked),
                      .init(closed: true, session: nil, lock: .unlocked),
                      .init(closed: true, session: 9, lock: .unknown)] {
            let f = Fixture(); f.update(); f.current = value; f.update()
            XCTAssertNotNil(f.controller.availabilityReason)
            f.current = .init(closed: true, session: 9, lock: .unlocked); f.update()
            await f.drain(); XCTAssertEqual(f.requests, 0)
        }
    }
    func testUnavailableImageConsumesNoEdgeAndCannotCatchUpWhileClosed() async {
        let f = Fixture(); f.update(); f.unavailable = "image changed"
        f.current.closed = true; f.update(); XCTAssertEqual(f.controller.availabilityReason, "image changed")
        f.unavailable = nil; f.update(); await f.drain(); XCTAssertEqual(f.requests, 0)
    }
    func testAlreadyLockedAndChangedSessionDoNotSubmit() async {
        let locked = Fixture(); locked.update(); locked.current.lock = .locked
        locked.current.closed = true; locked.update(); await locked.drain(); XCTAssertEqual(locked.requests, 0)
        let switched = Fixture(); switched.update(); switched.current.session = 10
        switched.current.closed = true; switched.update(); await switched.drain(); XCTAssertEqual(switched.requests, 0)
    }
    func testDisableSleepAndOpenBeforeTaskStartsPreventSubmission() async {
        for state in 0..<4 {
            let f = Fixture(); f.edge()
            switch state {
            case 0: f.controller.update(active: false, awake: true, enabled: true)
            case 1: f.controller.update(active: true, awake: false, enabled: true)
            case 2: f.controller.update(active: true, awake: true, enabled: false)
            default: f.current.closed = false; f.update()
            }
            await f.drain(); XCTAssertEqual(f.requests, 0)
            f.current.closed = true; f.update(); await f.drain()
            XCTAssertEqual(f.requests, state == 3 ? 1 : 0, "A newly observed open/close is a new edge; waking while still closed is not")
        }
    }
    func testPreflightRechecksFactsAndPlatformBeforeSpawn() async {
        for state in 0..<3 {
            let f = Fixture(); f.edge()
            if state == 0 { f.current.closed = false }
            if state == 1 { f.current.session = 10 }
            if state == 2 { f.unavailable = "unsupported" }
            await f.drain(); XCTAssertEqual(f.requests, 0)
            XCTAssertTrue(f.controller.status?.contains("未提交") == true)
        }
    }
    func testPendingCommandIsNotDuplicatedAndCancellationNeverBecomesSuccess() async {
        let f = Fixture(); f.blocked = true; f.edge(); await f.drain()
        XCTAssertEqual(f.requests, 1)
        f.current.closed = false; f.update(); f.current.closed = true; f.update()
        await f.drain(); XCTAssertEqual(f.requests, 1)
        f.current.lock = .locked; f.finish?.resume(); f.finish = nil
        await f.drain()
        XCTAssertTrue(f.controller.status?.contains("不能承诺撤销") == true)
        XCTAssertFalse(f.controller.status?.hasPrefix("已读回") == true)
        f.update(); await f.drain(); XCTAssertEqual(f.requests, 1)
    }
    func testSessionSwitchWhileRequestRunsInvalidatesResultAndNoWakeCatchup() async {
        let f = Fixture(); f.blocked = true; f.edge(); await f.drain()
        f.current.session = 10; f.update()
        f.current.lock = .locked; f.finish?.resume(); f.finish = nil; await f.drain()
        XCTAssertFalse(f.controller.status?.hasPrefix("已读回") == true)
        f.controller.update(active: true, awake: false, enabled: true)
        f.current.lock = .unlocked; f.update(); await f.drain()
        XCTAssertEqual(f.requests, 1)
    }
    func testInterruptedHintInvalidatesEvenBeforeSessionFactsChange() async {
        let f = Fixture(); f.edge(); f.event?(.interrupted)
        await f.drain(); XCTAssertEqual(f.requests, 0)
        f.event?(.changed); await f.drain(); XCTAssertEqual(f.requests, 0)
    }
    func testCancellationDuringThrowingConfirmationWaitPreservesUnconfirmedWarning() async {
        let f = Fixture(); f.afterWait = { f.controller.shutdown() }; f.waitFailure = true
        f.edge(); await f.drain()
        XCTAssertEqual(f.requests, 1)
        XCTAssertTrue(f.controller.status?.contains("不能承诺撤销") == true)
    }
    func testShutdownRemovesOnlyOwnEventsAndDisablesFurtherObservations() async {
        let f = Fixture(); f.update(); XCTAssertEqual(f.installs, 1)
        f.controller.shutdown(); XCTAssertEqual(f.removals, 1)
        f.current.closed = true; f.controller.observe(); await f.drain(); XCTAssertEqual(f.requests, 0)
        f.controller.shutdown(); XCTAssertEqual(f.removals, 1)
    }
    func testExplicitRegistryFalseAndProducerAbsentFlagsEstablishUnlocked() {
        let p = ParserFixture()
        XCTAssertEqual(p.parse().lock, .unlocked)
        XCTAssertEqual(p.parse().session, 9)
        p.session["CGSSessionScreenIsLocked"] = false
        p.user["CGSSessionScreenIsLocked"] = false
        XCTAssertEqual(p.parse().lock, .unlocked)
    }
    func testAllFreshLockSourcesMustAgreeAndSleepRegistryAloneIsInsufficient() {
        let p = ParserFixture(); p.registryLock = true
        XCTAssertEqual(p.parse().lock, .unknown)
        p.session["CGSSessionScreenIsLocked"] = true
        XCTAssertEqual(p.parse().lock, .unknown)
        p.user["CGSSessionScreenIsLocked"] = true
        p.session["CGSSessionScreenLockedTime"] = 900
        p.user["CGSSessionScreenLockedTime"] = 900
        XCTAssertEqual(p.parse().lock, .locked)
        p.registryLock = false
        XCTAssertEqual(p.parse().lock, .unknown)
    }
    func testFutureMissingMismatchedOrMalformedLockTimesAreNotConfirmed() {
        for time: Any? in [nil, 1001, -1, 0, true, "900", Double.nan] {
            let p = ParserFixture(); p.registryLock = true
            p.session["CGSSessionScreenIsLocked"] = true; p.user["CGSSessionScreenIsLocked"] = true
            p.session["CGSSessionScreenLockedTime"] = time; p.user["CGSSessionScreenLockedTime"] = time
            XCTAssertEqual(p.parse().lock, .unknown)
        }
        let mismatch = ParserFixture(); mismatch.registryLock = true
        mismatch.session["CGSSessionScreenIsLocked"] = true; mismatch.user["CGSSessionScreenIsLocked"] = true
        mismatch.session["CGSSessionScreenLockedTime"] = 900; mismatch.user["CGSSessionScreenLockedTime"] = 901
        XCTAssertEqual(mismatch.parse().lock, .unknown)
        let stale = ParserFixture(); stale.session["CGSSessionScreenLockedTime"] = 900
        XCTAssertEqual(stale.parse().lock, .unknown)
    }
    func testMissingMalformedOrNonBooleanLockFactsFailClosed() {
        for value: Any? in [nil, 0, 1, "false", NSNull()] {
            let p = ParserFixture(); p.registryLock = value
            XCTAssertEqual(p.parse().lock, .unknown)
        }
        for key in ["session", "console"] {
            for value: Any in [0, "true", NSNull()] {
                let p = ParserFixture()
                if key == "session" { p.session["CGSSessionScreenIsLocked"] = value }
                else { p.user["CGSSessionScreenIsLocked"] = value }
                XCTAssertEqual(p.parse().lock, .unknown)
            }
        }
    }
    func testWrongUidAuditConsoleLoginAndAmbiguousSessionsAreUnknown() {
        for key in ["kCGSSessionUserIDKey", "kCGSSessionAuditIDKey", "kCGSSessionOnConsoleKey", "kCGSessionLoginDoneKey"] {
            for whereInvalid in 0..<2 {
                let p = ParserFixture()
                if whereInvalid == 0 { p.session.removeValue(forKey: key) }
                else { p.user.removeValue(forKey: key) }
                XCTAssertEqual(p.parse().lock, .unknown, key)
            }
        }
        let wrong = ParserFixture(); wrong.user["kCGSSessionAuditIDKey"] = 10
        XCTAssertEqual(wrong.parse().lock, .unknown)
        let multiple = ParserFixture(); multiple.extra = [multiple.user]
        XCTAssertEqual(multiple.parse().lock, .unknown)
        let foreign = ParserFixture(); foreign.user["kCGSSessionUserIDKey"] = 502
        XCTAssertEqual(foreign.parse().lock, .unknown)
        let p = ParserFixture()
        XCTAssertEqual(BatteryLidLockSystem.parse(registry: nil, session: p.session, uid: 501, closed: false).lock, .unknown)
        XCTAssertEqual(BatteryLidLockSystem.parse(registry: [:], session: nil, uid: 501, closed: false).lock, .unknown)
    }
    func testMalformedWorkerParametersFailBeforeSystemFunction() {
        for args in [[], ["app", BatteryLidLockWorker.argument],
                     ["app", BatteryLidLockWorker.argument, "09", "1"],
                     ["app", BatteryLidLockWorker.argument, "9", "-1"],
                     ["app", "other", "9", "1"]] {
            XCTAssertEqual(BatteryLidLockWorker.run(arguments: args), 77)
        }
    }
    func testTransportRunsOffMainThreadWithFixedLimitsAndStrictReceiptShape() async throws {
        let executable = URL(fileURLWithPath: "/fixture/app")
        let value = try await BatteryLidLockWorker.transport(9, deadline: 100, executable: executable) { path, arguments, timeout, maximum in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(path, executable)
            XCTAssertEqual(arguments, [BatteryLidLockWorker.argument, "9", "100"])
            XCTAssertEqual(timeout, 2.5); XCTAssertEqual(maximum, 4096)
            return Data("{\"schema\":1,\"result\":-12}".utf8)
        }
        XCTAssertEqual(value, -12)
        for text in ["{}", "{\"schema\":2,\"result\":0}", "{\"schema\":1,\"result\":true}", String(repeating: "x", count: 4097)] {
            do {
                _ = try await BatteryLidLockWorker.transport(9, deadline: 100, executable: executable) { _, _, _, _ in Data(text.utf8) }
                XCTFail("Malformed/oversized worker reply accepted")
            } catch { }
        }
    }
    func testSharedTransportReallyBoundsHungChildAndNonzeroReply() async {
        for code in ["import time;time.sleep(5)", "import os;os.write(1,b'{\"schema\":1,\"result\":0}');os._exit(7)"] {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await BatteryLidLockWorker.transport(9, deadline: 100, executable: URL(fileURLWithPath: "/fixture/app")) { _, _, timeout, maximum in
                    try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                                    arguments: ["-c", code], timeout: timeout, maximumOutput: maximum)
                }
                XCTFail("Hung/failed child became a successful receipt")
            } catch { }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4)
        }
    }
    func testCancelledTransportNeverStartsChild() async {
        let task = Task { @MainActor in
            await Task.yield()
            return try await BatteryLidLockWorker.transport(9, deadline: 100, executable: URL(fileURLWithPath: "/fixture/app")) { _, _, _, _ in
                XCTFail("Cancelled task started a child"); return Data()
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    }

    @MainActor private final class Fixture {
        var current = BatteryLidLockFacts(closed: false, session: 9, lock: .unlocked)
        var unavailable: String?, requests = 0, result: Int32 = 0, failure = false, blocked = false
        var afterRequest: (() -> Void)?, afterWait: (() -> Void)?, waitFailure = false
        var finish: CheckedContinuation<Void, Never>?
        var event: ((BatteryLidLockController.Event) -> Void)?
        var installs = 0, removals = 0
        lazy var controller = BatteryLidLockController(facts: { self.current }, available: { self.unavailable }, request: { _ in
            self.requests += 1
            if self.blocked { await withCheckedContinuation { self.finish = $0 } }
            self.afterRequest?()
            if self.failure { throw NSError(domain: "fixture", code: 1) }
            return self.result
        }, wait: { self.afterWait?(); if self.waitFailure { throw CancellationError() } }, installEvents: { callback in
            self.event = callback; self.installs += 1; return { self.removals += 1 }
        })
        func update() { controller.update(active: true, awake: true, enabled: true) }
        func edge() { update(); current.closed = true; update() }
        func drain() async { for _ in 0..<30 { await Task.yield() } }
    }
    private final class ParserFixture {
        var registryLock: Any? = false
        var session: [String: Any] = ["kCGSSessionUserIDKey": 501, "kCGSSessionAuditIDKey": 9,
                                     "kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
        lazy var user = session
        var extra: [[String: Any]] = []
        func parse() -> BatteryLidLockFacts {
            BatteryLidLockSystem.parse(registry: ["IOConsoleLocked": registryLock as Any, "IOConsoleUsers": [user] + extra],
                                       session: session, uid: 501, closed: false, now: 1000)
        }
    }
}

#if !BATTERY_LID_LOCK_STANDALONE
@MainActor
final class BatteryLidLockServiceIntegrationTests: XCTestCase {
    func testLegacyDisplayDecodeDefaultsLidLockOff() throws {
        let display = try JSONDecoder().decode(BatteryDisplayPreferences.self, from: Data("{\"screenSleepPolicy\":\"never\"}".utf8))
        XCTAssertFalse(display.lockOnLidClose)
        XCTAssertFalse(BatteryDisplayPreferences().lockOnLidClose)
    }
    func testDefaultFalseNeverStartsLidObserverOrRequest() async {
        let f = ServiceFixture(savedEnabled: false); defer { f.stop() }
        f.service.start(); await f.drain()
        XCTAssertTrue(f.service.enabled)
        XCTAssertEqual(f.probe.installs, 0)
        f.probe.facts.closed = true; f.controller.observe(); await f.drain()
        XCTAssertEqual(f.probe.requests, 0)
    }
    func testColdWriteAndDeferredLaunchCannotActivateSavedLidPreference() async throws {
        let f = ServiceFixture(savedEnabled: true); defer { f.stop() }
        _ = try await f.service.performAutomation { try await f.service.setLimitFromAutomation(85) }
        XCTAssertEqual(f.transport.renewals, 1)
        XCTAssertTrue(f.service.enabled)
        XCTAssertEqual(f.probe.installs, 0)
        f.probe.facts.closed = true; f.controller.observe(); await f.drain()
        XCTAssertEqual(f.probe.requests, 0)
        // A normal reopen starts observation, but cannot replay the closed lid.
        f.service.start(automaticallyEnable: true); await f.drain()
        XCTAssertEqual(f.probe.installs, 1); XCTAssertEqual(f.probe.requests, 0)
    }
    func testManualOffCancelsBeforeAsyncReleaseAndLateReceiptCannotSucceed() async {
        let f = ServiceFixture(savedEnabled: true); defer { f.stop() }
        f.probe.block = true
        f.service.start(); await f.drain()
        f.probe.facts.closed = true; f.controller.observe(); await f.drain()
        XCTAssertEqual(f.probe.requests, 1); XCTAssertNotNil(f.probe.pending)
        f.service.setEnabled(false)
        XCTAssertFalse(f.service.enabled)
        XCTAssertEqual(f.probe.removals, 1)
        XCTAssertTrue(f.service.lidLockStatus.contains("不能承诺撤销"))
        f.probe.facts.lock = .locked; f.probe.finish(); await f.drain()
        XCTAssertFalse(f.service.lidLockStatus.hasPrefix("已读回"))
    }
    func testTurningPreferenceOffImmediatelyRemovesObserverAndForwardsStatus() async {
        let f = ServiceFixture(savedEnabled: true); defer { f.stop() }
        f.service.start(); await f.drain()
        var changes = 0
        let observation = f.service.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        f.probe.facts.closed = true; f.controller.observe()
        XCTAssertGreaterThan(changes, 0)
        f.service.updateDisplay { $0.lockOnLidClose = false }
        XCTAssertEqual(f.probe.removals, 1)
        await f.drain(); XCTAssertEqual(f.probe.requests, 0)
        let stored = try? JSONDecoder().decode(BatteryDisplayPreferences.self, from: f.defaults.data(forKey: "batteryManagement.display") ?? Data())
        XCTAssertEqual(stored?.lockOnLidClose, false)
    }
    func testShutdownCannotBeUndoneByLateRenewal() async {
        let f = ServiceFixture(savedEnabled: true); defer { f.stop() }
        f.transport.suspendRenewal = true
        f.service.start(); await f.drain()
        XCTAssertNotNil(f.transport.pending)
        f.service.shutdown()
        f.transport.finish(); await f.drain()
        XCTAssertEqual(f.probe.installs, 0)
        f.probe.facts.closed = true; f.controller.observe(); await f.drain()
        XCTAssertEqual(f.probe.requests, 0)
    }
    func testShutdownDuringInspectionNeverSubmitsRenewal() async {
        let f = ServiceFixture(savedEnabled: true); defer { f.stop() }
        f.transport.suspendInspection = true
        f.service.start(); await f.drain()
        XCTAssertNotNil(f.transport.pending)
        f.service.shutdown()
        f.transport.finish(); await f.drain()
        XCTAssertEqual(f.transport.renewals, 0)
        XCTAssertFalse(f.service.enabled)
        XCTAssertEqual(f.probe.installs, 0)
    }
    func testManualOffDuringInspectionNeverSubmitsRenewal() async {
        let f = ServiceFixture(savedEnabled: true); defer { f.stop() }
        f.transport.suspendInspection = true
        f.service.start(); await f.drain()
        XCTAssertNotNil(f.transport.pending)
        f.service.setEnabled(false)
        f.transport.finish(); await f.drain()
        XCTAssertEqual(f.transport.renewals, 0)
        XCTAssertFalse(f.service.enabled)
        XCTAssertEqual(f.probe.installs, 0)
    }

    @MainActor private final class ServiceProbe {
        var facts = BatteryLidLockFacts(closed: false, session: 9, lock: .unlocked)
        var installs = 0, removals = 0, requests = 0, block = false
        var pending: CheckedContinuation<Void, Never>?
        func finish() { let saved = pending; pending = nil; saved?.resume() }
    }
    @MainActor private final class ServiceFixture {
        let domain = "SuperIsland.BM1.LidLockIntegration.\(UUID())"
        let defaults: UserDefaults
        let probe = ServiceProbe()
        let transport = LidServiceTransport()
        let controller: BatteryLidLockController
        let service: BatteryManagementService
        init(savedEnabled: Bool) {
            defaults = UserDefaults(suiteName: domain)!
            var display = BatteryDisplayPreferences(); display.lockOnLidClose = savedEnabled
            defaults.set(try! JSONEncoder().encode(display), forKey: "batteryManagement.display")
            let probe = self.probe
            controller = BatteryLidLockController(facts: { probe.facts }, available: { nil }, request: { _ in
                probe.requests += 1
                if probe.block { await withCheckedContinuation { probe.pending = $0 } }
                return 0
            }, wait: {}, installEvents: { _ in probe.installs += 1; return { probe.removals += 1 } })
            var sample = BatteryTelemetry(); sample.hasBattery = true; sample.onAC = true; sample.level = 85
            let telemetry = sample
            let screen = BatteryDisplaySleepController(keepAwakeConflict: { .none },
                hold: { XCTFail("No real display assertion"); return 1 }, release: { _ in XCTFail("No real display release") },
                turnOff: { XCTFail("No real display sleep") })
            service = BatteryManagementService(defaults: defaults, client: transport,
                telemetryReader: { telemetry }, conflictChecker: { nil }, authorizationOpener: { XCTFail("No system authorization") },
                scheduleStarter: {}, displaySleepController: screen, lidLockController: controller)
        }
        func drain() async { for _ in 0..<100 { await Task.yield() } }
        func stop() {
            probe.finish(); transport.finish(); service.shutdown()
            defaults.removePersistentDomain(forName: domain)
        }
    }
    @MainActor private final class LidServiceTransport: BatteryManagementTransport {
        var authorization = SMAppService.Status.enabled
        var helperBundled = true
        var renewals = 0, suspendRenewal = false, suspendInspection = false
        var pending: CheckedContinuation<(Bool, BatteryControlReport), Error>?
        func register() async throws { XCTFail("No real registration") }
        private func report() -> BatteryControlReport {
            var report = BatteryControlReport(); report.available = true; report.mechanism = "SMC CHTE"
            report.leaseHeldByRequester = true
            return report
        }
        func finish() { let saved = pending; pending = nil; saved?.resume(returning: (true, report())) }
        func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
            switch command {
            case .renew:
                renewals += 1
                if suspendRenewal { return try await withCheckedThrowingContinuation { pending = $0 } }
            case .release:
                var released = report(); released.leaseHeldByRequester = false
                return (true, released)
            case .inspect:
                if suspendInspection { return try await withCheckedThrowingContinuation { pending = $0 } }
            }
            return (true, report())
        }
    }
}
#endif
