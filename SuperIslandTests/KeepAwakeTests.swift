import XCTest
import CryptoKit

final class KeepAwakeLocalSourceTests: XCTestCase {
    @MainActor func testTimedOutSampleCannotOverwriteReplacement() async throws {
        try XCTSkipIf(KeepAwakeSource.all.first { $0.id == "kimi-code-desktop" }!.isDeferred, "Kimi integration deferred by user; keep regression for future re-enablement")
        let name = "KA1Timeout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "first sample started")
        var pending: CheckedContinuation<KeepAwakeKimiMonitor.Snapshot, Never>?
        var calls = 0
        let service = KeepAwakeService(defaults: defaults, root: root) {
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { pending = $0; started.fulfill() }
            }
            return .init(state: nil, message: "replacement unknown")
        }
        service.start(); defer { service.shutdown() }
        try service.connect(KeepAwakeSource.all.first { $0.id == "kimi-code-desktop" }!)
        await fulfillment(of: [started], timeout: 2)
        let now = KeepAwakeClock.now()
        service.pollLocalSource(now: now + 21)
        XCTAssertEqual(service.localSourceStatus, "本机检查超时；状态未知")
        service.pollLocalSource(now: now + 27)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(service.localSourceStatus, "replacement unknown")
        pending?.resume(returning: .init(state: .running, message: "obsolete running"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(service.localSourceStatus, "replacement unknown")
        XCTAssertTrue(service.engine.sessions.isEmpty)
        XCTAssertFalse(service.actualHold)
    }
    func testPortDiscoveryCompletesAcrossRepeatedAsyncCalls() async {
        let done = expectation(description: "real lsof exits repeatedly without a cross-thread Foundation wait")
        let task = Task {
            for _ in 0..<4 { _ = await KeepAwakeKimiMonitor.listeningPorts(pid: getpid()) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 12)
        task.cancel()
    }
    func testInstalledVersionReadsAnInPlaceUpdateWithoutBundleCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["1.0.1", "1.1.1"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
            XCTAssertEqual(KeepAwakeKimiMonitor.installedVersion(at: root), version)
        }
    }
    func page(_ count: Int, extra: [String: Any] = [:]) throws -> Data {
        var item: [String: Any] = ["id": "private-test-session", "archived": false]
        item.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["code": 0, "data": [
            "total": count, "items": count > 0 ? [item] : [], "has_more": count > 1, "next_page_token": NSNull()
        ]])
    }
    func testRetainsOriginalSourcesAndSeparatesTenNewForms() {
        let old = ["claude-code", "claude-cowork", "codex-cli", "codex-desktop", "opencode", "gemini-cli", "pi", "copilot-cli", "hermes-cli", "hermes-gateway", "cursor", "cursor-agent", "cline", "aider", "conductor", "goose", "windsurf"]
        XCTAssertEqual(Array(KeepAwakeSource.all.prefix(17).map(\.id)), old)
        XCTAssertEqual(KeepAwakeSource.all.count, 27)
        XCTAssertEqual(Set(KeepAwakeSource.all.map(\.id)).count, 27)
        XCTAssertFalse(KeepAwakeSource.all.first { $0.id == "kimi-code-cli" }!.canConnect)
        XCTAssertFalse(KeepAwakeSource.all.first { $0.id == "kimi-code-desktop" }!.canConnect)
    }
    func testLocalQueryIsOnlyLoopbackWithMinimalProjection() throws {
        let url = try XCTUnwrap(KeepAwakeKimiMonitor.requestURL(port: 12345, status: "running"))
        XCTAssertEqual(url.host, "127.0.0.1")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(.init(name: "fields", value: "id,archived")))
        XCTAssertTrue(query.contains(.init(name: "page_size", value: "1")))
        XCTAssertNil(KeepAwakeKimiMonitor.requestURL(port: 12345, status: "messages"))
        XCTAssertNil(KeepAwakeKimiMonitor.requestURL(port: -1, status: "running"))
    }
    func testPortDiscoveryRejectsWildcardRemoteAndMalformedListeners() {
        XCTAssertEqual(KeepAwakeKimiMonitor.ports(from: "p99\nn*:123\nn127.0.0.1:42\nn127.0.0.1:42\nn192.168.1.1:80\nn127.0.0.1:70000\nn127.0.0.1:123/path\n"), [42])
    }
    func testStatusParserRejectsBusinessErrorOrPrivateContent() throws {
        XCTAssertEqual(try KeepAwakeKimiMonitor.count(from: page(0)), 0)
        XCTAssertEqual(try KeepAwakeKimiMonitor.count(from: page(20)), 20)
        XCTAssertThrowsError(try KeepAwakeKimiMonitor.count(from: page(1, extra: ["meta": ["last_prompt": "PRIVATE"]])))
        XCTAssertThrowsError(try KeepAwakeKimiMonitor.count(from: Data("{\"code\":401,\"data\":{\"total\":0}}".utf8)))
        XCTAssertThrowsError(try KeepAwakeKimiMonitor.count(from: Data("{\"code\":0,\"data\":{\"total\":1,\"items\":[],\"has_more\":false}}".utf8)))
        XCTAssertThrowsError(try KeepAwakeKimiMonitor.count(from: Data(repeating: 32, count: 8193)))
    }
    func testParallelRunningWinsOverWaitingWithoutInventingCompletion() {
        XCTAssertEqual(KeepAwakeKimiMonitor.state(running: 1, approval: 3, question: 4), .running)
        XCTAssertEqual(KeepAwakeKimiMonitor.state(running: 0, approval: 1, question: 0), .waiting)
        XCTAssertEqual(KeepAwakeKimiMonitor.state(running: 0, approval: 0, question: 1), .waiting)
        XCTAssertEqual(KeepAwakeKimiMonitor.state(running: 0, approval: 0, question: 0), .idle)
    }
    func testRepeatedLocalSnapshotsKeepLongTaskThroughWaiting() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        let env = KeepAwakeEngine.Environment(hardware: .desktop, battery: nil, onAC: nil, lowPower: false, thermalUnsafe: false)
        for time in stride(from: 0, through: 600, by: 5) {
            engine.receive(.init(source: "kimi-code-desktop", session: "desktop-aggregate", sequence: UInt64(time + 1), state: .running), now: Double(time))
            XCTAssertTrue(engine.evaluate(now: Double(time), environment: env).hold)
        }
        engine.receive(.init(source: "kimi-code-desktop", session: "desktop-aggregate", sequence: 606, state: .waiting), now: 605)
        engine.receive(.init(source: "kimi-code-desktop", session: "desktop-aggregate", sequence: 621, state: .waiting), now: 620)
        XCTAssertTrue(engine.evaluate(now: 634, environment: env).hold)
        XCTAssertTrue(engine.evaluate(now: 635, environment: env).hold)
    }
    @MainActor func testDisconnectInvalidatesInflightLocalRead() async throws {
        try XCTSkipIf(KeepAwakeSource.all.first { $0.id == "kimi-code-desktop" }!.isDeferred, "Kimi integration deferred by user; keep regression for future re-enablement")
        let name = "KA1LocalTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let service = KeepAwakeService(defaults: defaults, root: root)
        service.start(); defer { service.shutdown() }
        let source = try XCTUnwrap(KeepAwakeSource.all.first { $0.id == "kimi-code-desktop" })
        try service.connect(source); try service.disconnect(source)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(service.connections.contains(source.id))
        XCTAssertTrue(service.engine.sessions.isEmpty)
        XCTAssertFalse(service.actualHold)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("credentials/kimi-code-desktop.json").path))
    }
    @MainActor func testDeferredKimiDoesNotRestoreConnectOrPoll() async throws {
        let name = "KA1Deferred-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        defaults.set(["kimi-code-desktop", "kimi-code-cli"], forKey: "keepAwake.sources.v1")
        var samples = 0
        let service = KeepAwakeService(defaults: defaults, root: root) {
            samples += 1; return .init(state: .running, message: "must not be sampled")
        }
        service.start(); defer { service.shutdown() }
        for source in KeepAwakeSource.all.filter(\.isDeferred) {
            XCTAssertThrowsError(try service.connect(source))
            XCTAssertEqual(service.sourceStatus(source), "暂缓接入")
        }
        service.pollLocalSource(now: KeepAwakeClock.now() + 100)
        await Task.yield()
        XCTAssertEqual(samples, 0)
        XCTAssertTrue(service.connections.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "keepAwake.sources.v1"), [])
        XCTAssertFalse(service.actualHold)
    }
}
@testable import SuperIsland

final class KeepAwakeEngineTests: XCTestCase {
    let desktop = KeepAwakeEngine.Environment(hardware: .desktop)
    func event(_ session: String = "a", sequence: UInt64 = 1, state: KeepAwakeEngine.TaskState = .running, source: String = "claude-code") -> KeepAwakeEngine.Event {
        .init(source: source, session: session, sequence: sequence, state: state)
    }
    func testDefaultOffDoesNotHoldWithValidTask() {
        var engine = KeepAwakeEngine(); engine.receive(event(), now: 0)
        XCTAssertFalse(engine.evaluate(now: 1, environment: desktop).hold)
    }
    func testAutomaticRequiresTaskNotOnlyEnable() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        XCTAssertFalse(engine.evaluate(now: 0, environment: desktop).hold)
        engine.receive(event(), now: 0)
        XCTAssertTrue(engine.evaluate(now: 1, environment: desktop).hold)
    }
    func testParallelSessionCompletionCannotStopOtherRunningSession() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        engine.receive(event("a"), now: 0); engine.receive(event("b"), now: 0)
        engine.receive(event("a", sequence: 2, state: .completed), now: 2)
        engine.receive(event("b", sequence: 2), now: 30)
        XCTAssertTrue(engine.evaluate(now: 33, environment: desktop).hold)
        engine.receive(event("b", sequence: 3, state: .waiting), now: 35)
        XCTAssertTrue(engine.evaluate(now: 64.9, environment: desktop).hold)
        XCTAssertTrue(engine.evaluate(now: 65, environment: desktop).hold)
        engine.receive(event("b", sequence: 4, state: .completed), now: 70)
        XCTAssertFalse(engine.evaluate(now: 100, environment: desktop).hold)
    }
    func testWaitingRemainsHeldWithoutAReleaseTimer() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        engine.receive(event(), now: 0)
        engine.receive(event(sequence: 2, state: .waiting), now: 5)
        engine.receive(event(sequence: 3, state: .waiting), now: 25)
        XCTAssertTrue(engine.evaluate(now: 35, environment: desktop).hold)
    }
    func testNewRunCancelsRelease() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        engine.receive(event(), now: 0)
        engine.receive(event(sequence: 2, state: .completed), now: 5)
        engine.receive(event(sequence: 3), now: 20)
        XCTAssertTrue(engine.evaluate(now: 36, environment: desktop).hold)
    }
    func testOutOfOrderAndDuplicateCannotResurrectCompletedSession() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true)
        engine.receive(event(), now: 0); engine.receive(event(sequence: 3, state: .completed), now: 5)
        XCTAssertFalse(engine.receive(event(sequence: 2), now: 40))
        XCTAssertFalse(engine.receive(event(sequence: 3), now: 40))
        XCTAssertFalse(engine.evaluate(now: 40, environment: desktop).hold)
    }
    func testLostSignalRemainsHeldAndNeverClaimsCompletion() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true); engine.receive(event(), now: 10)
        XCTAssertEqual(engine.evaluate(now: 55, environment: desktop).title, "任务状态待核实 · 继续保持")
        XCTAssertTrue(engine.evaluate(now: 189.99, environment: desktop).hold)
        let end = engine.evaluate(now: 190, environment: desktop)
        XCTAssertTrue(end.hold); XCTAssertEqual(end.title, "任务状态待核实 · 继续保持")
        XCTAssertTrue(engine.evaluate(now: 500, environment: desktop).hold)
    }
    func testLateCompletionStartsTheFinalReleaseDelay() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true); engine.receive(event(), now: 0)
        engine.receive(event(sequence: 2, state: .completed), now: 500)
        XCTAssertTrue(engine.evaluate(now: 501, environment: desktop).hold)
        XCTAssertFalse(engine.evaluate(now: 530, environment: desktop).hold)
    }
    func testManualExpiryWhilePausedDoesNotResume() {
        var engine = KeepAwakeEngine(); engine.startManual(minutes: 30, now: 0); engine.togglePause(now: 1700)
        XCTAssertFalse(engine.evaluate(now: 1800, environment: desktop).hold)
        XCTAssertFalse(engine.enabled); XCTAssertFalse(engine.evaluate(now: 3500, environment: desktop).hold)
    }
    func testManualSelectionWaitsForStartAndIndefiniteNeedsStop() {
        var engine = KeepAwakeEngine(); engine.setEnabled(true); engine.selectMode(.manual)
        XCTAssertFalse(engine.evaluate(now: 0, environment: desktop).hold)
        engine.startManual(minutes: 0, now: 0)
        XCTAssertTrue(engine.evaluate(now: 999999, environment: desktop).hold)
        engine.stop(); XCTAssertFalse(engine.evaluate(now: 1000000, environment: desktop).hold)
    }
    func testPauseImmediatelyReleasesThenReevaluates() {
        var engine = KeepAwakeEngine(); engine.startManual(minutes: 120, now: 0); engine.togglePause(now: 10)
        XCTAssertFalse(engine.evaluate(now: 11, environment: desktop).hold)
        XCTAssertTrue(engine.evaluate(now: 1810, environment: desktop).hold)
    }
    func testBatteryBoundaryAndLatchCannotBeBypassedByOffOn() {
        var engine = KeepAwakeEngine(); engine.startManual(minutes: 0, now: 0)
        var book = KeepAwakeEngine.Environment(hardware: .notebook, battery: 20, onAC: true)
        XCTAssertTrue(engine.evaluate(now: 0, environment: book).hold)
        book.battery = 19; XCTAssertFalse(engine.evaluate(now: 1, environment: book).hold)
        book.battery = 21; engine.stop(); engine.startManual(minutes: 0, now: 2)
        XCTAssertFalse(engine.evaluate(now: 3, environment: book).hold)
        XCTAssertTrue(engine.resume(environment: book)); XCTAssertTrue(engine.evaluate(now: 4, environment: book).hold)
    }
    func testACLowPowerThermalAndUnknownFailClosed() {
        let cases: [KeepAwakeEngine.Environment] = [
            .init(hardware: .notebook, battery: 90, onAC: false),
            .init(hardware: .notebook, battery: 90, onAC: true, lowPower: true),
            .init(hardware: .desktop, thermalUnsafe: true), .init(), .init(hardware: .notebook)
        ]
        for environment in cases {
            var engine = KeepAwakeEngine(); engine.startManual(minutes: 0, now: 0)
            XCTAssertFalse(engine.evaluate(now: 0, environment: environment).hold)
            XCTAssertFalse(engine.resume(environment: environment))
        }
    }
    func testDesktopDoesNotInventBatteryProtection() {
        var engine = KeepAwakeEngine(); engine.startManual(minutes: 60, now: 0)
        XCTAssertTrue(engine.evaluate(now: 0, environment: desktop).hold)
    }
    func testDisconnectInvalidatesActiveSessionAndTombstone() {
        var engine = KeepAwakeEngine(); engine.setAutomatic(true); engine.receive(event(), now: 0)
        engine.disconnect(source: "claude-code")
        XCTAssertTrue(engine.sessions.isEmpty); XCTAssertFalse(engine.evaluate(now: 1, environment: desktop).hold)
    }
    func testUnknownSourceAndUnboundedSessionsRejected() {
        var engine = KeepAwakeEngine()
        XCTAssertFalse(engine.receive(event(source: "made-up"), now: 0))
        for i in 0..<KeepAwakeEngine.sessionLimit { XCTAssertTrue(engine.receive(event(String(i)), now: 0)) }
        XCTAssertFalse(engine.receive(event("overflow"), now: 0))
    }
}

final class KeepAwakeIntegrationTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KA1Tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func writeEnvelope(mailbox: KeepAwakeMailbox, key: String? = nil, generation: String? = nil, issuedAt: Double = 100) throws {
        let credential = try XCTUnwrap(mailbox.credentials["claude-code"])
        var value = KeepAwakeMailbox.Envelope(generation: generation ?? credential.generation,
            event: .init(source: "claude-code", session: "safe-session", sequence: 1, state: .running), issuedAt: issuedAt, mac: "")
        value.mac = Data(HMAC<SHA256>.authenticationCode(for: value.authenticatedBytes,
            using: SymmetricKey(data: Data(base64Encoded: key ?? credential.key)!))).base64EncodedString()
        try JSONEncoder().encode(value).write(to: mailbox.inbox.appendingPathComponent(UUID().uuidString + ".json"))
    }
    func testMailboxAcceptsOnlyAuthenticatedFreshCurrentGeneration() throws {
        var mailbox = KeepAwakeMailbox(root: directory)
        try mailbox.connect(source: "claude-code")
        try writeEnvelope(mailbox: mailbox)
        XCTAssertEqual(mailbox.read(now: 100).count, 1)
        try writeEnvelope(mailbox: mailbox, key: Data(repeating: 0, count: 32).base64EncodedString())
        try writeEnvelope(mailbox: mailbox, generation: "retired")
        try writeEnvelope(mailbox: mailbox, issuedAt: 1)
        XCTAssertTrue(mailbox.read(now: 100).isEmpty)
    }
    func testDisconnectAndReconnectInvalidateOldCapabilities() throws {
        var mailbox = KeepAwakeMailbox(root: directory); try mailbox.connect(source: "claude-code")
        try writeEnvelope(mailbox: mailbox); try mailbox.disconnect(source: "claude-code")
        try mailbox.connect(source: "claude-code")
        XCTAssertTrue(mailbox.read(now: 100).isEmpty)
    }
    func testMailboxRejectsSymlinkAndDoesNotReadOrRemoveTarget() throws {
        var mailbox = KeepAwakeMailbox(root: directory); try mailbox.connect(source: "claude-code")
        let privateFile = directory.appendingPathComponent("private")
        try Data("secret".utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(at: mailbox.inbox.appendingPathComponent("fake.json"), withDestinationURL: privateFile)
        XCTAssertTrue(mailbox.read(now: 100).isEmpty)
        XCTAssertEqual(try String(contentsOf: privateFile), "secret")
    }
    func testHookMergeIsIdempotentAndDisconnectPreservesOtherHooks() throws {
        let source = KeepAwakeSource.all[0]
        let settings = KeepAwakeHookInstaller.path(source: source, home: directory)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = ["theme": "dark", "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo existing"]]]]]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        for _ in 0..<2 { try KeepAwakeHookInstaller.install(source: source, credential: directory.appendingPathComponent("credential'file"), home: directory, executable: URL(fileURLWithPath: "/usr/bin/true")) }
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let hooks = installed["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["Stop"]?.count, 2)
        XCTAssertEqual(installed["theme"] as? String, "dark")
        try KeepAwakeHookInstaller.uninstall(source: source, home: directory)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let stop = (restored["hooks"] as! [String: [[String: Any]]])["Stop"]!
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual((stop[0]["hooks"] as! [[String: String]])[0]["command"], "echo existing")
    }
    func testMalformedHookConfigIsNotOverwritten() throws {
        let source = KeepAwakeSource.all[0], path = KeepAwakeHookInstaller.path(source: KeepAwakeSource.all[0], home: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"hooks\":[]}".utf8); try bytes.write(to: path)
        XCTAssertThrowsError(try KeepAwakeHookInstaller.install(source: source, credential: directory, home: directory, executable: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testGeminiHookTimeoutUsesMillisecondsWithoutChangingOtherSettings() throws {
        let source = try XCTUnwrap(KeepAwakeSource.all.first { $0.id == "gemini-cli" })
        try KeepAwakeHookInstaller.install(source: source, credential: directory.appendingPathComponent("credentials"), home: directory, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: KeepAwakeHookInstaller.path(source: source, home: directory))) as! [String: Any]
        let entries = (root["hooks"] as! [String: [[String: Any]]])["BeforeAgent"]!
        let command = (entries[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(command["timeout"] as? Int, 5000)
    }
    func testShellQuoteDoesNotInterpretMetacharacters() {
        XCTAssertEqual(KeepAwakeHookInstaller.shellQuote("a'b $HOME `pwd`"), "'a'\\''b $HOME `pwd`'")
    }
}

@MainActor
final class KeepAwakePowerTests: XCTestCase {
    func testOwnOrdinaryAssertionIsAcquiredAndReleased() {
        let power = KeepAwakePower()
        defer { power.apply(hold: false, policy: .system, notebook: false) }
        power.apply(hold: true, policy: .system, notebook: false)
        XCTAssertTrue(power.isHolding); XCTAssertNotEqual(power.systemID, 0)
        XCTAssertEqual(power.displayID, 0)
        let id = power.systemID
        power.apply(hold: true, policy: .system, notebook: false)
        XCTAssertEqual(power.systemID, id)
        power.apply(hold: false, policy: .system, notebook: false)
        XCTAssertFalse(power.isHolding); XCTAssertEqual(power.systemID, 0)
    }
}

final class KeepAwakeLeaseTests: XCTestCase {
    let owner = UUID().uuidString
    func testLeaseWritesIntentFirstAndRestoresAtExpiry() throws {
        var power = 0, journal: KeepAwakeLease.Journal?
        let lease = KeepAwakeLease(journal: nil, readPower: { power }, writePower: { value in
            XCTAssertNotNil(journal); power = value
        }, save: { journal = $0 })
        try lease.renew(owner: owner, now: 10)
        XCTAssertEqual(power, 1); XCTAssertEqual(journal?.expires, 190)
        try lease.expire(now: 189); XCTAssertEqual(power, 1)
        try lease.expire(now: 190); XCTAssertEqual(power, 0); XCTAssertNil(journal)
    }
    func testRenewalExtendsOnlyBoundedLease() throws {
        var power = 0
        let lease = KeepAwakeLease(journal: nil, readPower: { power }, writePower: { power = $0 }, save: { _ in })
        try lease.renew(owner: owner, now: 0); try lease.renew(owner: owner, now: 30)
        XCTAssertEqual(lease.journal?.expires, 210)
        XCTAssertThrowsError(try lease.renew(owner: UUID().uuidString, now: 31))
        XCTAssertThrowsError(try lease.release(owner: UUID().uuidString))
        try lease.release(owner: owner); XCTAssertEqual(power, 0)
    }
    func testHelperRestartRecoversInsteadOfResuming() throws {
        var power = 1, persisted: KeepAwakeLease.Journal? = .init(owner: owner, baseline: 0, applied: 1, expires: 999999)
        let lease = KeepAwakeLease(journal: persisted, readPower: { power }, writePower: { power = $0 }, save: { persisted = $0 })
        try lease.recover(); XCTAssertEqual(power, 0); XCTAssertNil(persisted)
    }
    func testPreexistingOtherToolOverrideIsNotOwnedOrReverted() {
        let lease = KeepAwakeLease(journal: nil, readPower: { 1 }, writePower: { _ in XCTFail("must not write") }, save: { _ in XCTFail("must not own") })
        XCTAssertThrowsError(try lease.renew(owner: owner, now: 0))
        XCTAssertNil(lease.journal)
    }
    func testConflictDoesNotOverwriteOrEraseRecoveryRecord() {
        let journal = KeepAwakeLease.Journal(owner: owner, baseline: 0, applied: 1, expires: 100)
        let lease = KeepAwakeLease(journal: journal, readPower: { 2 }, writePower: { _ in XCTFail("must not overwrite") }, save: { _ in XCTFail("must retain record") })
        XCTAssertThrowsError(try lease.recover()); XCTAssertEqual(lease.journal, journal)
    }
    func testPersistenceFailurePreventsPowerMutation() {
        let lease = KeepAwakeLease(journal: nil, readPower: { 0 }, writePower: { _ in XCTFail("intent was not durable") }, save: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try lease.renew(owner: owner, now: 0)); XCTAssertNil(lease.journal)
    }
    func testPowerFailureKeepsDurableRecoveryIntent() {
        var journal: KeepAwakeLease.Journal?
        let lease = KeepAwakeLease(journal: nil, readPower: { 0 }, writePower: { _ in throw CocoaError(.fileWriteUnknown) }, save: { journal = $0 })
        XCTAssertThrowsError(try lease.renew(owner: owner, now: 0)); XCTAssertNotNil(journal)
    }
    func testRecoveryReadbackFailureNeverClearsJournal() {
        let journal = KeepAwakeLease.Journal(owner: owner, baseline: 0, applied: 1, expires: 100)
        let lease = KeepAwakeLease(journal: journal, readPower: { 1 }, writePower: { _ in }, save: { _ in XCTFail("not restored") })
        XCTAssertThrowsError(try lease.recover()); XCTAssertNotNil(lease.journal)
    }
    func testCrashBeforePowerWriteIsIdempotentRecovery() throws {
        var stored: KeepAwakeLease.Journal? = .init(owner: owner, baseline: 0, applied: 1, expires: 100)
        let lease = KeepAwakeLease(journal: stored, readPower: { 0 }, writePower: { _ in XCTFail("already original") }, save: { stored = $0 })
        try lease.recover(); try lease.recover(); XCTAssertNil(stored)
    }
}

final class KeepAwakeEventToolTests: XCTestCase {
    func testCodexMetadataLifecycleDoesNotInventCompletionOrEndParent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KA1Codex-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var mailbox = KeepAwakeMailbox(root: directory)
        for source in ["codex-cli", "codex-desktop"] {
            try mailbox.connect(source: source)
            let cases: [(String, String, KeepAwakeEngine.TaskState?)] = [
                ("SessionStart", "", nil), ("UserPromptSubmit", "", .running),
                ("PreToolUse", "Bash", .running), ("PermissionRequest", "Bash", .waiting),
                ("PostToolUse", "Bash", .running), ("PreToolUse", "request_user_input", .waiting),
                ("PreCompact", "", .running), ("PostCompact", "", .running),
                ("SubagentStart", "", nil), ("SubagentStop", "", nil),
                ("Stop", "", .idle), ("Interrupt", "", .idle), ("SessionEnd", "", .idle),
                ("UnknownFutureEvent", "", nil)
            ]
            for (name, tool, expected) in cases {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
                process.arguments = ["--superisland-ka1", source, mailbox.credentialsDirectory.appendingPathComponent(source + ".json").path]
                process.standardInput = input; process.standardOutput = output
                let payload: [String: Any] = ["session_id": "private-parent", "hook_event_name": name,
                    "tool_name": tool, "prompt": "PRIVATE-PROMPT", "last_assistant_message": "PRIVATE-ANSWER",
                    "transcript_path": "/private/transcript", "stop_hook_active": true]
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
                try input.fileHandleForWriting.close(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "{}")
                for file in try FileManager.default.contentsOfDirectory(at: mailbox.inbox, includingPropertiesForKeys: nil) {
                    let raw = try String(contentsOf: file)
                    for privateValue in ["private-parent", "PRIVATE-PROMPT", "PRIVATE-ANSWER", "/private/transcript"] {
                        XCTAssertFalse(raw.contains(privateValue))
                    }
                }
                let events = mailbox.read()
                XCTAssertEqual(events.count, expected == nil ? 0 : 1, name)
                XCTAssertEqual(events.first?.state, expected, name)
                if expected != nil { XCTAssertEqual(events.first?.source, source) }
            }
        }
    }
    func testRealToolRedactsPayloadAndAuthenticatesEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KA1ToolTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var mailbox = KeepAwakeMailbox(root: directory); try mailbox.connect(source: "claude-code")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        process.arguments = ["--superisland-ka1", "claude-code", mailbox.credentialsDirectory.appendingPathComponent("claude-code.json").path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let privateText = "PRIVATE-PROMPT-MUST-NOT-LEAVE-STDIN"
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": "private-session", "hook_event_name": "UserPromptSubmit", "prompt": privateText, "cwd": "/private/work"])
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload.prefix(15))
        Thread.sleep(forTimeInterval: 0.02)
        try input.fileHandleForWriting.write(contentsOf: payload.dropFirst(15)); try input.fileHandleForWriting.close()
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: mailbox.inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let raw = try String(contentsOf: XCTUnwrap(files.first))
        XCTAssertFalse(raw.contains(privateText)); XCTAssertFalse(raw.contains("private-session")); XCTAssertFalse(raw.contains("/private/work"))
        let events = mailbox.read()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.state, .running)
        XCTAssertEqual(events.first?.session.count, 64)
    }
    func testGeminiEmitsNoOpJSONWhenDisconnected() throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        process.arguments = ["--superisland-ka1", "gemini-cli", "/nonexistent-KA1-test-credential"]
        process.standardInput = input; process.standardOutput = output
        try process.run(); try input.fileHandleForWriting.close(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "{}")
    }
    func testUnknownHookCannotBeInterpretedAsCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KA1ToolUnknown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var mailbox = KeepAwakeMailbox(root: directory); try mailbox.connect(source: "claude-code")
        let process = Process(), input = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        process.arguments = ["--superisland-ka1", "claude-code", mailbox.credentialsDirectory.appendingPathComponent("claude-code.json").path]
        process.standardInput = input
        try process.run(); try input.fileHandleForWriting.write(contentsOf: Data("{\"session_id\":\"s\",\"hook_event_name\":\"UnknownFutureEvent\"}".utf8)); try input.fileHandleForWriting.close()
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0); XCTAssertTrue(mailbox.read().isEmpty)
    }
}


final class KeepAwakePublicHookTests: XCTestCase {
    func payload(_ event: String, tool: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["session_id": "test-session", "hook_event_name": event]
        value["tool_name"] = tool
        return value
    }
    func testWorkWaitAndResumeEvents() {
        for event in ["UserPromptSubmit", "PostToolUse", "ElicitationResult"] {
            XCTAssertEqual(KeepAwakeHookContract.state(payload(event)), "running")
        }
        XCTAssertEqual(KeepAwakeHookContract.state(payload("PreToolUse", tool: "Bash")), "running")
        XCTAssertEqual(KeepAwakeHookContract.state(payload("PreToolUse", tool: "AskUserQuestion")), "waiting")
        XCTAssertEqual(KeepAwakeHookContract.state(payload("PermissionRequest")), "waiting")
    }
    func testSessionStartAndUnknownEventsCannotInventActivity() {
        for event in ["SessionStart", "SubagentStop", "Heartbeat", "FutureEvent", "Notification"] {
            XCTAssertNil(KeepAwakeHookContract.state(payload(event)))
        }
        XCTAssertNil(KeepAwakeHookContract.state(payload("PreToolUse")))
        XCTAssertNil(KeepAwakeHookContract.state(["hook_event_name": "UserPromptSubmit"]))
        XCTAssertNil(KeepAwakeHookContract.state(["session_id": String(repeating: "a", count: 1025), "hook_event_name": "UserPromptSubmit"]))
    }
    func testStopDoesNotClaimCompletionAndToolInterruptionKeepsParentRunning() {
        for event in ["Stop", "StopFailure", "SessionEnd", "Interrupt"] {
            XCTAssertEqual(KeepAwakeHookContract.state(payload(event)), "idle")
        }
        var event = payload("PostToolUseFailure")
        event["is_interrupt"] = true
        XCTAssertEqual(KeepAwakeHookContract.state(event), "running")
    }
    func testExtraFieldsAndVersionDoNotRequireExactVersionAdaptation() {
        var event = payload("UserPromptSubmit")
        event["version"] = "future-version"
        event["unknown_field"] = ["anything": true]
        XCTAssertEqual(KeepAwakeHookContract.state(event), "running")
        event = payload("Notification")
        for kind in ["permission_prompt", "agent_needs_input"] {
            event["notification_type"] = kind
            XCTAssertEqual(KeepAwakeHookContract.state(event), "waiting")
        }
        event["notification_type"] = "agent_completed"
        XCTAssertEqual(KeepAwakeHookContract.state(event), "idle")
    }
    func testDesktopAndCLIIdentityCannotBeInterchanged() {
        XCTAssertTrue(KeepAwakeHookContract.accepts(source: "qoder-desktop", bundleID: "com.qodercn.app"))
        XCTAssertFalse(KeepAwakeHookContract.accepts(source: "qoder-cli", bundleID: "com.qodercn.app"))
        XCTAssertFalse(KeepAwakeHookContract.accepts(source: "qoder-desktop", bundleID: "dev.zcode.app"))
        for id in KeepAwakeHookContract.sources {
            XCTAssertTrue(KeepAwakeSource.all.first { $0.id == id }!.canConnect, "Desktop hooks can be opted into as explicit candidates")
            let cli = id.replacingOccurrences(of: "-desktop", with: "-cli")
            XCTAssertFalse(KeepAwakeSource.all.first { $0.id == cli }!.canConnect)
        }
    }
    func testObservedDesktopQuestionSequencesStayHeldThroughWaitAndUnconfirmedStop() throws {
        for source in ["workbuddy-desktop", "zcode-desktop"] {
            var engine = KeepAwakeEngine()
            engine.setAutomatic(true)
            let environment = KeepAwakeEngine.Environment(hardware: .desktop)
            var sequence: UInt64 = 0
            func deliver(_ input: [String: Any], at time: Double) throws {
                let state = try XCTUnwrap(KeepAwakeHookContract.state(input).flatMap(KeepAwakeEngine.TaskState.init(rawValue:)))
                sequence += 1
                XCTAssertTrue(engine.receive(.init(source: source, session: "observed-sequence", sequence: sequence, state: state), now: time))
            }
            try deliver(payload("UserPromptSubmit"), at: 0)
            XCTAssertTrue(engine.evaluate(now: 1, environment: environment).hold)
            if source == "workbuddy-desktop" {
                var notification = payload("Notification")
                notification["notification_type"] = "permission_prompt"
                try deliver(notification, at: 5)
            } else {
                try deliver(payload("PreToolUse", tool: "AskUserQuestion"), at: 5)
                try deliver(payload("PermissionRequest", tool: "AskUserQuestion"), at: 6)
            }
            XCTAssertTrue(engine.evaluate(now: 35, environment: environment).hold)
            // WorkBuddy emits PreToolUse for the question only after the answer;
            // ZCode emits it before presenting the question. Both then emit Post.
            if source == "workbuddy-desktop" {
                try deliver(payload("PreToolUse", tool: "AskUserQuestion"), at: 40)
            }
            try deliver(payload("PostToolUse", tool: "AskUserQuestion"), at: 40)
            XCTAssertTrue(engine.evaluate(now: 40, environment: environment).hold)
            try deliver(payload("PreToolUse", tool: "Bash"), at: 45)
            try deliver(payload("PostToolUse", tool: "Bash"), at: 56)
            try deliver(payload("Stop"), at: 60)
            XCTAssertTrue(engine.evaluate(now: 89, environment: environment).hold)
            XCTAssertTrue(engine.evaluate(now: 90, environment: environment).hold)
            XCTAssertTrue(engine.evaluate(now: 86_400, environment: environment).hold)
            XCTAssertEqual(engine.sessions.values.first?.event.state, .idle)
        }
    }

    func testDesktopHookCandidateMergesAndRemovesOnlyOwnedCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KA1PublicHook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for family in ["qoder", "workbuddy"] {
            let source = KeepAwakeSource(id: family + "-desktop", name: family, integration: "test", hookFamily: family)
            let path = KeepAwakeHookInstaller.path(source: source, home: root)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original: [String: Any] = ["theme": "preserve", "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo original"]]]]]]
            try JSONSerialization.data(withJSONObject: original).write(to: path)
            for _ in 0..<2 {
                try KeepAwakeHookInstaller.install(source: source, credential: root.appendingPathComponent("credential"), home: root, executable: URL(fileURLWithPath: "/usr/bin/true"))
            }
            let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            let hooks = installed["hooks"] as! [String: [[String: Any]]]
            XCTAssertEqual(hooks["Stop"]?.count, 2)
            XCTAssertEqual(hooks["PermissionRequest"]?.count, 1)
            try KeepAwakeHookInstaller.uninstall(source: source, home: root)
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            XCTAssertEqual(restored["theme"] as? String, "preserve")
            let entries = (restored["hooks"] as! [String: [[String: Any]]])["Stop"]!
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual((entries[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, "echo original")
        }
    }
}
