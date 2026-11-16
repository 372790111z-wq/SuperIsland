import XCTest
import SwiftUI
import ServiceManagement
@testable import SuperIsland

@MainActor
final class BatterySimpleProtectionTests: XCTestCase {
    final class Transport: BatteryManagementTransport {
        var authorization = SMAppService.Status.enabled
        var helperBundled = true
        var requests: [BatteryControlRequest] = []
        var releases = 0
        var held = false
        var heldKnown = true
        var failRenew = false
        var failRelease = false
        var version = BatteryControlReport.currentProtocolVersion
        var beforeReply: (() -> Void)?
        let epoch = UUID()
        func register() async throws { XCTFail("Tests must never register a helper") }
        func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
            var r = BatteryControlReport()
            r.available = true; r.mechanism = "SMC CHTE"; r.dischargeSupported = true
            r.minimumDischargeTarget = 20; r.protocolVersion = version; r.controlEpoch = epoch
            var success = true
            switch command {
            case .inspect, .refreshCapabilities: break
            case .renew(let request):
                try BatterySimpleProtectionPolicy.validate(request)
                requests.append(request); held = true; r.mode = request.mode
                r.leaseHeldByRequester = true
                let callback = beforeReply; beforeReply = nil; callback?()
                if failRenew { success = false; r.message = "injected renew failure" }
            case .release:
                releases += 1
                if !failRelease { held = false }
                r.leaseHeldByRequester = held; r.recoveryPending = held; success = !held
                r.message = held ? "injected pending restoration" : "restored"
            }
            r.controlHeld = heldKnown ? held : nil
            return (success, r)
        }
    }
    func store() -> UserDefaults {
        let name = "SuperIsland.SimpleTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }; return d
    }
    func service(_ t: Transport, _ d: UserDefaults, enabled: Bool = false) -> BatteryManagementService {
        if d.object(forKey: BatterySimplePreferences.key) == nil {
            var p = BatterySimplePreferences(); p.enabled = enabled; p.save(d)
        }
        return BatteryManagementService(defaults: d, client: t, telemetryReader: {
            var t = BatteryTelemetry(); t.hasBattery = true; t.level = 90; t.onAC = true; return t
        }, conflictChecker: { nil }, scheduleStarter: { XCTFail("Removed schedules must never start") })
    }
    func settle() async { for _ in 0..<80 { await Task.yield() } }

    func testFreshInstallAndRestartStayOff() async {
        let d = store(), t = Transport(), s = service(t, d)
        await s.attemptStartupForTesting()
        XCTAssertFalse(s.enabled); XCTAssertFalse(s.protectionRequested); XCTAssertTrue(t.requests.isEmpty)
        let next = service(t, d); await next.attemptStartupForTesting()
        XCTAssertTrue(t.requests.isEmpty)
    }
    func testExplicitOffPersistsAndRetryCannotEnable() async {
        let d = store(), t = Transport(), s = service(t, d, enabled: true)
        await s.attemptStartupForTesting(); XCTAssertTrue(s.enabled)
        s.setEnabled(false); await settle()
        XCTAssertFalse(s.enabled); XCTAssertFalse(BatterySimplePreferences.load(d).enabled)
        XCTAssertFalse(t.held)
        let count = t.requests.count
        s.retry(); await settle(); XCTAssertEqual(count, t.requests.count)
        let next = service(t, d); await next.attemptStartupForTesting()
        XCTAssertFalse(next.enabled); XCTAssertEqual(count, t.requests.count)
        s.shutdown()
    }
    func testLegacyMigrationArchivesOnceAndDoesNotEnableAdvancedRules() throws {
        let d = store()
        var old = BatteryControlPreferences(); old.limit = 85; old.sailing = true; old.automaticDischarge = true; old.lowPower = .always
        let data = try JSONEncoder().encode(old)
        d.set(data, forKey: "batteryManagement.preferences")
        let migrated = BatterySimplePreferences.load(d)
        XCTAssertEqual(migrated.limit, 85); XCTAssertFalse(migrated.enabled)
        XCTAssertTrue(migrated.migrationPending)
        d.set(Data("changed".utf8), forKey: "batteryManagement.preferences")
        _ = BatterySimplePreferences.load(d)
        XCTAssertEqual((d.dictionary(forKey: "batteryProtection.v1.legacyBackup")?["batteryManagement.preferences"] as? Data), data)
        let s = service(Transport(), d)
        XCTAssertEqual(s.preferences, BatterySimpleProtectionPolicy.preferences(limit: 85))
    }
    func testLowOrCorruptOldLimitRequiresExplicitChoice() throws {
        for corrupt in [false, true] {
            let d = store(); var old = BatteryControlPreferences(); old.limit = 60; old.allowLowLimit = true
            d.set(corrupt ? Data("bad".utf8) : try JSONEncoder().encode(old), forKey: "batteryManagement.preferences")
            let config = BatterySimplePreferences.load(d)
            XCTAssertTrue(config.needsLimitChoice); XCTAssertFalse(config.enabled)
        }
    }
    func testUnconfirmedOldControlAndOldHelperNeverAcquire() async {
        for scenario in 0...2 {
            let t = Transport(), d = store()
            if scenario == 0 { t.held = true }
            if scenario == 1 { t.heldKnown = false }
            if scenario == 2 { t.version -= 1 }
            let s = service(t, d, enabled: true); await s.attemptStartupForTesting()
            XCTAssertFalse(s.enabled); XCTAssertTrue(t.requests.isEmpty)
        }
    }
    func testCrashMarkerRequiresRecoveryObservationBeforeReacquire() async {
        let d = store(), t = Transport()
        var p = BatterySimplePreferences(); p.enabled = true; p.migrationPending = false; p.leaseMayExist = true; p.save(d)
        XCTAssertTrue(BatterySimplePreferences.load(d).recoveryPending)
        t.held = true
        let s = service(t, d); await s.attemptStartupForTesting()
        XCTAssertTrue(t.requests.isEmpty)
        t.held = false; s.retry(); await settle()
        XCTAssertTrue(s.enabled); XCTAssertEqual(t.requests.count, 1)
    }
    func testDraftIsNotAppliedUntilSaveAndOffSaveNeverAcquires() async throws {
        let d = store(), t = Transport(), s = service(t, d)
        s.limitDraft = 95
        XCTAssertEqual(s.preferences.limit, 80)
        try await s.applySimpleLimit()
        XCTAssertEqual(s.preferences.limit, 95); XCTAssertEqual(BatterySimplePreferences.load(d).limit, 95)
        XCTAssertTrue(t.requests.isEmpty); XCTAssertFalse(s.protectionRequested)
    }
    func testFailedLimitApplyRestoresSavedLimitAndReleases() async throws {
        let d = store(), t = Transport(), s = service(t, d, enabled: true)
        await s.attemptStartupForTesting(); t.failRenew = true; s.limitDraft = 95
        do { try await s.applySimpleLimit(); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(s.preferences.limit, 80); XCTAssertEqual(BatterySimplePreferences.load(d).limit, 80)
        XCTAssertFalse(t.held); XCTAssertFalse(s.enabled)
    }
    func testFailedOffRestorationIsDurableAndRetryDoesNotReacquire() async {
        let d = store(), t = Transport(), s = service(t, d, enabled: true)
        await s.attemptStartupForTesting(); t.failRelease = true
        s.setEnabled(false); await settle()
        XCTAssertTrue(s.simpleRecoveryPending); XCTAssertTrue(BatterySimplePreferences.load(d).recoveryPending)
        XCTAssertFalse(BatterySimplePreferences.load(d).enabled)
        let count = t.requests.count
        t.failRelease = false; s.retry(); await settle()
        XCTAssertFalse(s.simpleRecoveryPending); XCTAssertFalse(t.held); XCTAssertEqual(t.requests.count, count)
        s.shutdown()
    }
    func testOffDuringLateRenewCannotBeOverwritten() async {
        let d = store(), t = Transport(), s = service(t, d, enabled: true)
        t.beforeReply = { s.setEnabled(false) }
        await s.attemptStartupForTesting(); await settle()
        XCTAssertFalse(s.enabled); XCTAssertFalse(s.protectionRequested); XCTAssertFalse(t.held)
        s.shutdown()
    }
    func testManualDischargeValidatesTargetAndStopsOnSleep() async throws {
        let d = store(), t = Transport(), s = service(t, d, enabled: true)
        await s.attemptStartupForTesting()
        for target in [19, 90, 100] {
            do { _ = try await s.execute(mode: .discharge, target: target); XCTFail("Invalid target") } catch {}
        }
        _ = try await s.execute(mode: .discharge, target: 70)
        XCTAssertEqual(s.mode, .discharge); XCTAssertEqual(t.requests.last?.dischargeTarget, 70)
        s.handleSleep(); await settle()
        XCTAssertEqual(s.mode, .automatic); XCTAssertNil(t.requests.last?.dischargeTarget)
        XCTAssertTrue(t.requests.last?.sleeping == true)
        do { _ = try await s.execute(mode: .discharge, target: 70); XCTFail("Sleep cannot start discharge") } catch {}
        s.shutdown()
    }
    func testRemovedWritesRejectWithoutInvokingAutomation() async throws {
        let t = Transport(), s = service(t, store())
        for mode in [BatteryControlMode.topUp, .paused] {
            do { _ = try await s.execute(mode: mode); XCTFail("Removed mode") } catch {}
        }
        do { _ = try await s.startCalibration(); XCTFail("Removed calibration") } catch {}
        do { _ = try await s.performAutomation { XCTFail("Must not invoke closure"); return "bad" }; XCTFail("Removed automation") } catch {}
        XCTAssertThrowsError(try s.updatePreferences { $0.sailing = true })
        XCTAssertFalse(s.canStartCalibration); XCTAssertTrue(t.requests.isEmpty)
    }
    func testHelperAdmissionRejectsEveryLegacyFieldAndMissingWireVersion() throws {
        let original = BatteryControlRequest(owner: UUID(), preferences: .init())
        XCTAssertNoThrow(try BatterySimpleProtectionPolicy.validate(original))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "simpleProtectionVersion")
        let decoded = try JSONDecoder().decode(BatteryControlRequest.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.simpleProtectionVersion)
        XCTAssertThrowsError(try BatterySimpleProtectionPolicy.validate(decoded))
        let mutations: [(inout BatteryControlPreferences) -> Void] = [
            { $0.allowLowLimit = true }, { $0.automaticDischarge = true }, { $0.sailing = true },
            { $0.heatProtection = true }, { $0.sleep = .untilLimit }, { $0.lowPower = .always },
            { $0.highPowerScope = .adapter }, { $0.led = .green }, { $0.blinkWhileDischarging = true },
            { $0.limit = 79 }, { $0.limit = 101 }
        ]
        for mutate in mutations { var request = original; mutate(&request.preferences); XCTAssertThrowsError(try BatterySimpleProtectionPolicy.validate(request)) }
        for mode in [BatteryControlMode.paused, .topUp] { var request = original; request.mode = mode; XCTAssertThrowsError(try BatterySimpleProtectionPolicy.validate(request)) }
    }
    func testSleepRejectsDelayedDischargeButAllowsDeliberateNewOperationAfterWake() {
        var state = BatterySimpleSleepState()
        let r = BatteryControlRequest(owner: UUID(), preferences: .init(), mode: .discharge, dischargeTarget: 70)
        state.willSleep(r)
        XCTAssertEqual(state.normalize(r).mode, .automatic)
        state.didWake()
        var delayed = r; delayed.sleeping = true
        XCTAssertEqual(state.normalize(delayed).mode, .automatic)
        var deliberate = r; deliberate.operationID = UUID()
        XCTAssertEqual(state.normalize(deliberate).mode, .discharge)
        XCTAssertFalse(state.normalize(deliberate).sleeping)
    }
    func testDischargeArrivingDuringSleepCannotReplayAfterWake() {
        var state = BatterySimpleSleepState()
        state.willSleep(nil)
        let delayed = BatteryControlRequest(owner: UUID(), preferences: .init(), mode: .discharge, dischargeTarget: 70)
        XCTAssertEqual(state.normalize(delayed).mode, .automatic)
        state.didWake()
        XCTAssertEqual(state.normalize(delayed).mode, .automatic)
        var next = delayed; next.operationID = UUID()
        XCTAssertEqual(state.normalize(next).mode, .discharge)
    }
    func testArchivedScheduleCannotRunFromAnyEntry() async {
        var invoked = false
        let schedules = BatteryScheduleService(defaults: store(), execution: { _ in invoked = true; return "bad" })
        schedules.start(); XCTAssertNil(schedules.evaluate())
        do { _ = try await schedules.runNow(BatteryScheduledTask()); XCTFail("Removed task") } catch {}
        XCTAssertFalse(invoked)
    }
    func testDischargeStatusWaitsForActualNegativeCurrent() async throws {
        let d = store(), t = Transport()
        var config = BatterySimplePreferences(); config.enabled = true; config.save(d)
        var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 90
        sample.onAC = true; sample.charging = false; sample.current = 0
        let s = BatteryManagementService(defaults: d, client: t, telemetryReader: { sample }, conflictChecker: { nil }, scheduleStarter: {})
        await s.attemptStartupForTesting()
        _ = try await s.execute(mode: .discharge, target: 80)
        XCTAssertEqual(s.simpleStatus, "正在确认放电")
        sample.current = -500; s.refreshTelemetry()
        XCTAssertEqual(s.simpleStatus, "正在主动放电")
        sample.onAC = false; sample.level = nil; s.refreshTelemetry()
        XCTAssertTrue(s.canStopDischarge, "Unknown telemetry cannot remove the recovery action")
        _ = try await s.execute(mode: .automatic)
        XCTAssertEqual(s.mode, .automatic)
        sample.onAC = true; sample.level = 90; s.refreshTelemetry()
        XCTAssertEqual(s.simpleStatus, "当前未充电")
    }
    func testReadOnlyQueryUsesNewLimitWithoutMigratingOrWriting() throws {
        let d = store(); var old = BatteryControlPreferences(); old.limit = 85
        d.set(try JSONEncoder().encode(old), forKey: "batteryManagement.preferences")
        var new = BatterySimplePreferences(); new.limit = 92; new.save(d)
        let before = d.data(forKey: BatterySimplePreferences.key)
        let q = BatteryReadOnlyQueries(defaults: d)
        XCTAssertEqual(try q.limit(), 92)
        XCTAssertEqual(d.data(forKey: BatterySimplePreferences.key), before)
        XCTAssertNil(d.object(forKey: "batteryProtection.v1.legacyBackup"))
    }
    func testNativeSurfacesExposeSimpleControlsAndApplySharedDraft() async throws {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(policy) }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let d = store(), t = Transport(), s = service(t, d)
        await s.attemptStartupForTesting()
        for settings in [false, true] {
            let view = settings ? AnyView(BatteryManagementSettingsView(service: s).padding(20)) : AnyView(BatteryManagementPanel(service: s))
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(Color.black))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: settings ? 520 : 658, height: settings ? 500 : 350), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let probe = SimplePanelAXProbe(window: window, host: host)
            try await probe.wait { probe.text.contains("主动放电") && probe.text.contains("充电上限") }
            for removed in ["航海模式", "校准", "暂停充电", "定时任务", "MagSafe", "保持唤醒", "趋势"] {
                XCTAssertFalse(probe.text.contains(removed), "Removed control: \(removed)")
            }
            s.limitDraft = settings ? 92 : 82
            try await probe.wait { probe.button(identifier: "data-annotation-id=si.bm.simple.apply-limit") != nil }
            try probe.press(identifier: "data-annotation-id=si.bm.simple.apply-limit")
            try await probe.wait { s.preferences.limit == s.limitDraft }
            XCTAssertTrue(t.requests.isEmpty)
            XCTAssertEqual(s.preferences.limit, settings ? 92 : 82)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = settings ? "settings" : "island"
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/superisland-simple-\(name).png"))
            }
        }
    }

}

@MainActor
private final class SimplePanelAXProbe {
    let window: NSWindow
    let host: NSView
    init(window: NSWindow, host: NSView) { self.window = window; self.host = host }
    func string(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
    func nodes(allVisibleWindows: Bool = false) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(visit) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        if allVisibleWindows { NSApp.windows.filter(\.isVisible).forEach(visit) } else { visit(window); visit(host) }
        return result
    }
    var text: String {
        nodes().flatMap { object in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { string(object, $0) } }.joined(separator: " ")
    }
    func button(title: String? = nil, identifier: String? = nil, allVisibleWindows: Bool = false) -> NSObject? {
        nodes(allVisibleWindows: allVisibleWindows).first { object in
            guard string(object, "accessibilityRole") == "AXButton" else { return false }
            if let identifier { return string(object, "accessibilityIdentifier") == identifier }
            return string(object, "accessibilityLabel") == title || string(object, "accessibilityTitle") == title
        }
    }
    func press(title: String? = nil, identifier: String? = nil, allVisibleWindows: Bool = false) throws {
        let object = try XCTUnwrap(button(title: title, identifier: identifier, allVisibleWindows: allVisibleWindows), "Missing native button \(title ?? identifier ?? "?")")
        if let button = object as? NSButton {
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { XCTFail("Native press unavailable"); return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector))
    }
    // macOS remote alert elements can return false after dispatching AXPress.
    // Require the actual dialog/business transition rather than trusting that acknowledgment.
    func pressAlert(title: String, until ready: () -> Bool) async throws {
        let object = try XCTUnwrap(button(title: title, allVisibleWindows: true), "Missing native alert button \(title)")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { XCTFail("Native alert press unavailable"); return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        try await wait(ready)
    }
    func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Native view did not become ready: \(text)")
    }
}
