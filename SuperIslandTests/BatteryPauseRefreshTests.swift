import XCTest
@testable import SuperIsland

final class BatteryPauseRefreshTests: XCTestCase {
    func testSealedPackageRequiresMatchingIdentityFlagAndCompileGate() {
        let we1: [String: Any] = ["CFBundleIdentifier": "com.workview.SuperIsland.WE1Debug", "WE1PauseRefreshTrial": true]
        let bm1: [String: Any] = ["CFBundleIdentifier": "com.workview.SuperIsland.BM1Debug", "BM1PauseRefreshTrial": true]
        XCTAssertEqual(BatteryManagementIdentity.pauseRefreshClient(info: we1, reviewBuild: false, unifiedBuild: true), "com.workview.SuperIsland.WE1Debug")
        XCTAssertEqual(BatteryManagementIdentity.pauseRefreshClient(info: bm1, reviewBuild: true, unifiedBuild: false), "com.workview.SuperIsland.BM1Debug")
        for info in [we1, bm1] {
            XCTAssertNil(BatteryManagementIdentity.pauseRefreshClient(info: info, reviewBuild: false, unifiedBuild: false))
        }
        XCTAssertNil(BatteryManagementIdentity.pauseRefreshClient(info: we1, reviewBuild: true, unifiedBuild: false))
        XCTAssertNil(BatteryManagementIdentity.pauseRefreshClient(info: bm1, reviewBuild: false, unifiedBuild: true))
        for identifier in ["com.workview.SuperIsland", "other", "com.workview.SuperIsland.BM1Debug"] {
            var bad = we1; bad["CFBundleIdentifier"] = identifier
            XCTAssertNil(BatteryManagementIdentity.pauseRefreshClient(info: bad, reviewBuild: true, unifiedBuild: true))
        }
        for key in ["BM1DiagnosticsOnly", "BM1NativeCutoffTrial", "BM1Preferences79Review", "BM1PauseRefreshTrial"] {
            var bad = we1; bad[key] = true
            XCTAssertNil(BatteryManagementIdentity.pauseRefreshClient(info: bad, reviewBuild: true, unifiedBuild: true))
        }
        var missing = we1; missing.removeValue(forKey: "WE1PauseRefreshTrial")
        XCTAssertNil(BatteryManagementIdentity.pauseRefreshClient(info: missing, reviewBuild: false, unifiedBuild: true))
    }
    func testDefaultBuildHasNoPulseEvenWithSealedInfo() {
        #if !BATTERY_REVIEW && !BATTERY_PAUSE_REFRESH
        XCTAssertFalse(BatteryManagementIdentity.pauseRefreshBuilds.review)
        XCTAssertFalse(BatteryManagementIdentity.pauseRefreshBuilds.unified)
        #endif
    }
    private let owner = UUID()
    private enum Fault: Error { case injected }
    private func telemetry(update: Double = 1001, charging: Bool = false, current: Double = 0) -> BatteryTelemetry {
        BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100,
            "ExternalConnected": true, "IsCharging": charging, "InstantAmperage": current * 1000,
            "UpdateTime": update, "PowerTelemetryData": [:]], readAt: Date(timeIntervalSince1970: update))
    }
    private func verifier() -> BatteryPauseRefresh.Verification {
        .init(operationID: UUID(), target: 80, started: 10, submittedAt: Date(timeIntervalSince1970: 1000),
            baselineUpdate: Date(timeIntervalSince1970: 999))
    }
    func testFreshStoppedEvidenceNeedsStableIntervalAndInput() throws {
        var v = verifier()
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: true, input: true, now: 11, date: Date(timeIntervalSince1970: 1001)))
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: true, input: nil, now: 20, date: Date(timeIntervalSince1970: 1010)))
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: true, input: true, now: 21, date: Date(timeIntervalSince1970: 1011)))
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: true, input: true, now: 26, date: Date(timeIntervalSince1970: 1016)))
        XCTAssertTrue(try v.observe(telemetry(), activeMatches: true, input: true, now: 31, date: Date(timeIntervalSince1970: 1021)))
    }
    func testStalePositiveUnknownAndMismatchingEvidenceCannotPass() throws {
        var variants = [telemetry(update: 999), telemetry(charging: true), telemetry(current: 0.01), telemetry(current: .nan)]
        var unknown = telemetry(); unknown.current = nil; variants.append(unknown)
        XCTAssertNil(telemetry(current: .nan).current, "Non-finite telemetry cannot become zero current")
        for t in variants {
            var v = verifier()
            XCTAssertFalse(try v.observe(t, activeMatches: true, input: true, now: 21, date: Date(timeIntervalSince1970: 1011)))
            XCTAssertFalse(try v.observe(t, activeMatches: true, input: true, now: 41, date: Date(timeIntervalSince1970: 1031)))
        }
        var v = verifier()
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: false, input: true, now: 21, date: Date(timeIntervalSince1970: 1011)))
    }
    func testPendingTickNeverFallsThroughToApplyAndCancellationBypassesPauseProof() throws {
        let v = verifier()
        var r = BatteryControlRequest(owner: owner, preferences: .init(), mode: .paused, operationID: v.operationID)
        var applies = 0, observations = 0, cancellations = 0
        func tick(_ t: BatteryTelemetry) throws {
            if try BatteryPauseRefresh.handlePending(v, request: r, telemetry: t,
                observe: { target in XCTAssertEqual(target, 80); observations += 1 },
                cancel: { cancellations += 1 }) { return }
            applies += 1
        }
        var out = telemetry(); out.level = 78
        XCTAssertThrowsError(try tick(out))
        XCTAssertEqual(applies, 0); XCTAssertEqual(observations, 0)
        try tick(telemetry()); XCTAssertEqual(observations, 1); XCTAssertEqual(applies, 0)
        r.mode = .automatic; r.operationID = UUID()
        try tick(out) // Cancel can always release, even when no B evidence exists.
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(applies, 0)
    }
    func testFailedReleasePreservesIntentForWatchdog() throws {
        var raw = 0, clock = 10.0, refuseRelease = true
        let lease = BatteryOverrideLease(read: { _ in raw }, write: { _, value in
            if value == 0 && refuseRelease { throw Fault.injected }; raw = value
        }, save: { _ in })
        try lease.renew(owner: owner, now: clock)
        XCTAssertThrowsError(try lease.pulseCHIE(owner: owner, admit: {}, now: { clock }, wait: { clock += $0 }))
        XCTAssertEqual(raw, 8); XCTAssertEqual(lease.journal?.entries["CHIE"]?.expected, 8)
        refuseRelease = false; try lease.releaseCHIEImmediately()
        XCTAssertEqual(raw, 0)
    }
    func testObservationGapsCannotCountAsStableSupplyOrPause() throws {
        var v = verifier()
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: true, input: true, now: 11, date: Date(timeIntervalSince1970: 1001)))
        XCTAssertFalse(try v.observe(telemetry(), activeMatches: true, input: true, now: 80, date: Date(timeIntervalSince1970: 1070)))
        let s = try BatteryCutoffSession { _ in }
        try s.armPausePulse(owner: owner, pulse: .init(operationID: UUID(), target: 80, submittedAt: Date()), now: 10)
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 11))
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 80))
    }
    func testClockAndRangeChangesFail() throws {
        for (now, date) in [(9.0,999.0),(101.0,1091.0),(21.0,1050.0)] {
            var v = verifier()
            XCTAssertThrowsError(try v.observe(telemetry(), activeMatches: true, input: true, now: now, date: Date(timeIntervalSince1970: date)))
        }
        var v = verifier(), out = telemetry(); out.level = 78
        XCTAssertThrowsError(try v.observe(out, activeMatches: true, input: true, now: 11, date: Date(timeIntervalSince1970: 1001)))
    }
    func testTicketRemainsConsumedAcrossNewObjectsAndOperations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try BatteryPauseRefreshTicket(directory: directory, owner: getuid()).consume(operationID: UUID())
        XCTAssertThrowsError(try BatteryPauseRefreshTicket(directory: directory, owner: getuid()).consume(operationID: UUID()))
        try Data().write(to: directory.appendingPathComponent("pause-refresh-v1.consumed"))
        XCTAssertThrowsError(try BatteryPauseRefreshTicket(directory: directory, owner: getuid()).consume(operationID: UUID()))
    }
    func testPulseHasNoCheckpointBetweenWritesAndCountsWriteLatency() throws {
        var raw = 0, clock = 10.0, events: [String] = []
        let lease = BatteryOverrideLease(read: { _ in raw }, write: { _, value in
            events.append("write\(value)"); raw = value; if value == 8 { clock += 0.2 }
        }, save: { _ in events.append("save") })
        try lease.renew(owner: owner, now: 10)
        let elapsed = try lease.pulseCHIE(owner: owner, admit: {}, now: { clock }, wait: { amount in
            XCTAssertEqual(amount, 0.3, accuracy: 0.0001); events.append("wait"); clock += amount
        })
        XCTAssertEqual(elapsed, 0.5, accuracy: 0.0001)
        XCTAssertEqual(raw, 0)
        XCTAssertEqual(Array(events[2...4]), ["write8", "wait", "write0"])
        XCTAssertEqual(lease.journal?.entries["CHIE"]?.expected, 0)
        XCTAssertThrowsError(try lease.pulseCHIE(owner: owner, admit: {}, now: { clock }, wait: { _ in }))
    }
    func testPulseUsesDedicatedCommandsAndOnlyReadsAfterRelease() throws {
        var raw = 0, clock = 10.0, events: [String] = []
        let lease = BatteryOverrideLease(read: { _ in events.append("read"); return raw },
            write: { _, value in events.append("generalWrite"); raw = value }, save: { _ in events.append("save") })
        try lease.renew(owner: owner, now: clock)
        _ = try lease.pulseCHIE(owner: owner, admit: {}, now: { clock }, wait: { clock += $0 },
            writePulse: { value in events.append("command\(value)"); raw = value })
        let start = try XCTUnwrap(events.firstIndex(of: "command8"))
        XCTAssertEqual(events[start + 1], "command0", "No read/fsync/general writer between commands")
        XCTAssertFalse(events.contains("generalWrite")); XCTAssertEqual(raw, 0)
    }
    func testSaveFailureBeforeIntentDoesNotWrite() throws {
        var writes = 0, fail = false
        let lease = BatteryOverrideLease(read: { _ in 0 }, write: { _, _ in writes += 1 }, save: { _ in if fail { throw Fault.injected } })
        try lease.renew(owner: owner, now: 10); fail = true
        XCTAssertThrowsError(try lease.pulseCHIE(owner: owner, admit: {}, now: { 10 }, wait: { _ in }))
        XCTAssertEqual(writes, 0)
    }
    func testLostWriteEightReplyStillReleases() throws {
        var raw = 0, writes: [Int] = []
        let lease = BatteryOverrideLease(read: { _ in raw }, write: { _, value in
            raw = value; writes.append(value); if value == 8 { throw Fault.injected }
        }, save: { _ in })
        try lease.renew(owner: owner, now: 10)
        XCTAssertThrowsError(try lease.pulseCHIE(owner: owner, admit: {}, now: { 10 }, wait: { _ in XCTFail("Must release immediately") }))
        XCTAssertEqual(writes, [8, 0]); XCTAssertEqual(raw, 0)
    }
    func testDiskFullAfterPulseAndAtRestartCannotBlockRelease() throws {
        var raw = 0, clock = 10.0, fail = false
        let lease = BatteryOverrideLease(read: { _ in raw }, write: { _, value in raw = value }, save: { _ in if fail { throw Fault.injected } })
        try lease.renew(owner: owner, now: clock)
        XCTAssertThrowsError(try lease.pulseCHIE(owner: owner, admit: {}, now: { clock }, wait: { clock += $0; fail = true }))
        XCTAssertEqual(raw, 0)
        raw = 8
        let restart = BatteryOverrideLease(journal: lease.journal, read: { _ in raw }, write: { _, value in raw = value }, save: { _ in throw Fault.injected })
        XCTAssertThrowsError(try restart.releaseCHIEImmediately())
        XCTAssertEqual(raw, 0)
        XCTAssertNotNil(restart.journal)
    }
    func testLongWriteDoesNotAddSleepAndIsNotSuccess() throws {
        var raw = 0, clock = 10.0
        let lease = BatteryOverrideLease(read: { _ in raw }, write: { _, value in raw = value; if value == 8 { clock += 2 } }, save: { _ in })
        try lease.renew(owner: owner, now: clock)
        XCTAssertThrowsError(try lease.pulseCHIE(owner: owner, admit: {}, now: { clock }, wait: { _ in XCTFail("No extra sleep") }))
        XCTAssertEqual(raw, 0)
    }
    func testForeignRegisterAndWrongOwnerAreNotOverwritten() throws {
        var writes = 0
        let journal = BatteryOverrideLease.Journal(owner: owner, entries: ["CHIE": .init(original: 0, expected: 8, prior: 0)])
        let lease = BatteryOverrideLease(journal: journal, read: { _ in 2 }, write: { _, _ in writes += 1 }, save: { _ in })
        XCTAssertThrowsError(try lease.releaseCHIEImmediately())
        XCTAssertThrowsError(try lease.releaseCHIEImmediately(owner: UUID()))
        XCTAssertEqual(writes, 0)
    }
    func testPulseSupplyRecoveryDoesNotInventOffOrPauseSuccess() throws {
        var saved: BatteryCutoffSession.Record?
        let s = try BatteryCutoffSession { saved = $0 }
        try s.armPausePulse(owner: owner, pulse: .init(operationID: UUID(), target: 80, submittedAt: Date()), now: 10)
        XCTAssertFalse(try s.observeRecovery(powered: true, controlsMatch: true, now: 11))
        XCTAssertFalse(s.record!.observedPowerOff)
        // Restart and cancellation only need A, never B, before restoring prefs.
        let restarted = try BatteryCutoffSession(record: saved) { _ in }
        try restarted.beginRecovery(owner: owner, releasingLease: true, now: 20)
        XCTAssertFalse(try restarted.observeRecovery(powered: true, controlsMatch: true, now: 21))
        XCTAssertFalse(try restarted.observeRecovery(powered: true, controlsMatch: true, now: 26))
        XCTAssertTrue(try restarted.observeRecovery(powered: true, controlsMatch: true, now: 31))
        let old = try BatteryCutoffSession { _ in }
        try old.arm(owner: owner, powered: true, now: 10)
        try old.beginRecovery(owner: owner, releasingLease: true, now: 11)
        XCTAssertFalse(try old.observeRecovery(powered: true, controlsMatch: true, now: 12))
        XCTAssertFalse(try old.observeRecovery(powered: true, controlsMatch: true, now: 32))
    }
    func testAdmissionRefusesUnknownOrOutOfScopeStates() throws {
        var r = BatteryControlRequest(owner: owner, preferences: .init(), mode: .paused)
        let t = telemetry(update: 1000, charging: true, current: 1)
        func validate(_ r: BatteryControlRequest, input: Bool? = true, registrations: Set<Int>? = [85]) throws {
            try BatteryPauseRefresh.validate(r, telemetry: t, target: 80, saved: 80, registered: registrations,
                input: input, calibrationActive: false, now: Date(timeIntervalSince1970: 1001))
        }
        XCTAssertNoThrow(try validate(r))
        XCTAssertThrowsError(try validate(r, input: nil))
        XCTAssertThrowsError(try validate(r, registrations: nil))
        XCTAssertThrowsError(try validate(r, registrations: [100]))
        r.preferences.sailing = true; XCTAssertThrowsError(try validate(r))
        r.preferences.sailing = false; r.mode = .automatic; XCTAssertThrowsError(try validate(r))
    }
}
