import XCTest
import ServiceManagement
@testable import SuperIsland

final class KeepAwakeHelperRecoveryTests: XCTestCase {
    func testOwnedLeaseAlreadyAtBaselineDoesNotReportCorruptionOrReapply() throws {
        let owner = UUID().uuidString
        var power = 0, writes = 0
        var saved: KeepAwakeLease.Journal?
        let lease = KeepAwakeLease(journal: nil, readPower: { power }, writePower: { power = $0; writes += 1 }, save: { saved = $0 })
        try lease.renew(owner: owner, now: 0)
        power = 0 // System/another tool already restored the original value.
        XCTAssertThrowsError(try lease.renew(owner: owner, now: 30))
        XCTAssertNil(lease.journal)
        XCTAssertNil(saved)
        XCTAssertEqual(writes, 1, "Do not overwrite an external restoration")
        XCTAssertEqual(power, 0)
    }

    func testExpiryReportsOnlyAConfirmedRestorationAndRejectsUnknownPower() throws {
        let owner = UUID().uuidString
        let journal = KeepAwakeLease.Journal(owner: owner, baseline: 0, applied: 1, expires: 10)
        var value = 2, saved: KeepAwakeLease.Journal? = journal
        let lease = KeepAwakeLease(journal: journal, readPower: { value }, writePower: { _ in XCTFail("must not overwrite unknown power") }, save: { saved = $0 })
        XCTAssertThrowsError(try lease.expire(now: 10))
        XCTAssertNotNil(saved)
        value = 0 // Read back baseline: already restored, no global write.
        XCTAssertTrue(try lease.expire(now: 11))
        XCTAssertNil(saved)
        XCTAssertFalse(try lease.expire(now: 12))
    }

    func testMalformedRecoveryRecordCannotWritePowerOrDisappear() throws {
        for journal in [
            KeepAwakeLease.Journal(owner: UUID().uuidString, baseline: 1, applied: 1, expires: 10),
            .init(owner: "invalid", baseline: 0, applied: 1, expires: 10),
            .init(owner: UUID().uuidString, baseline: 0, applied: 1, expires: .nan),
            .init(owner: UUID().uuidString, baseline: 0, applied: 0, expires: 10)
        ] {
            let lease = KeepAwakeLease(journal: journal, readPower: { 0 }, writePower: { _ in XCTFail("bad record must not write") }, save: { _ in XCTFail("retain unknown recovery intent") })
            XCTAssertThrowsError(try lease.recover())
            XCTAssertNotNil(lease.journal)
        }
    }

    @MainActor func testServiceAutomaticallyRecoversOnlyAfterSafeTimeAndHelperReply() async throws {
        let transport = HelperTransport(), lid = client(transport)
        lid.authorize(); await settle()
        var environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true, lowPower: true)
        var now = 0.0
        let name = "KA-LowPower-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, lidClient: lid,
            environmentReader: { environment }, policyClock: { now }, awakeClock: { now })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.setEnabled(true)
        XCTAssertTrue(service.engine.hasLowPowerProtection)
        environment.lowPower = false; now = 1; service.tick()
        now = 30; service.tick(); await settle()
        XCTAssertTrue(service.engine.hasLowPowerProtection)
        transport.autoStatus = false
        now = 31; service.tick(); await settle()
        XCTAssertTrue(service.recoveryInProgress)
        XCTAssertTrue(service.engine.hasLowPowerProtection)
        transport.statusReplies.last?(true, "ready")
        await settle(); await settle()
        XCTAssertNil(service.engine.protection)
        XCTAssertTrue(service.engine.enabled)
        XCTAssertFalse(service.actualHold, "No task was admitted: recovery must not invent keeping")
        XCTAssertTrue(transport.releaseReplies.isEmpty, "No owned renewal: do not release a foreign lease")
    }

    @MainActor func testThermalChangeDuringAutomaticRecoveryCannotClearProtection() async throws {
        let transport = HelperTransport(), lid = client(transport)
        lid.authorize(); await settle()
        var environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true, lowPower: true)
        var now = 0.0
        let name = "KA-LowPowerRace-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, lidClient: lid,
            environmentReader: { environment }, policyClock: { now }, awakeClock: { now })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.setEnabled(true)
        environment.lowPower = false; now = 1; service.tick()
        transport.autoStatus = false; now = 31; service.tick(); await settle()
        environment.thermalUnsafe = true
        transport.statusReplies.last?(true, "ready")
        await settle(); await settle()
        XCTAssertTrue(service.engine.hasThermalProtection)
        XCTAssertFalse(service.actualHold)
        XCTAssertFalse(service.recoveryInProgress)
    }

    @MainActor func testAutomaticRecoveryFailureIsBoundedAndNeverResumesKeeping() async throws {
        let transport = HelperTransport(), lid = client(transport)
        lid.authorize(); await settle()
        var environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true, lowPower: true)
        var now = 0.0
        let name = "KA-LowPowerFailure-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, lidClient: lid,
            environmentReader: { environment }, policyClock: { now }, awakeClock: { now })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.setEnabled(true); environment.lowPower = false; now = 1; service.tick()
        transport.statusSuccess = false
        for value in [31.0, 91, 151, 1000] {
            now = value; service.tick(); await settle(); await settle()
            XCTAssertTrue(service.engine.hasLowPowerProtection)
            XCTAssertFalse(service.actualHold)
        }
        XCTAssertEqual(transport.statusReplies.count, 4, "Authorization plus at most three recovery checks")
    }

    @MainActor func testManualStopWinsAgainstLateAutomaticRecoveryReply() async throws {
        let transport = HelperTransport(), lid = client(transport)
        lid.authorize(); await settle()
        var environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true, lowPower: true)
        var now = 0.0
        let name = "KA-LowPowerStop-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, lidClient: lid,
            environmentReader: { environment }, policyClock: { now }, awakeClock: { now })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.setEnabled(true); environment.lowPower = false; now = 1; service.tick()
        transport.autoStatus = false; now = 31; service.tick(); await settle()
        service.stop(); transport.statusReplies.last?(true, "late ready")
        await settle(); await settle()
        XCTAssertFalse(service.engine.enabled)
        XCTAssertTrue(service.engine.hasLowPowerProtection)
        XCTAssertFalse(service.actualHold)
    }

    @MainActor func testSleepDuringRecoveryNeedsAFreshSafeWindowAfterWaking() async throws {
        let transport = HelperTransport(), lid = client(transport)
        lid.authorize(); await settle()
        var environment = KeepAwakeEngine.Environment(hardware: .notebook, battery: 80, onAC: true, lowPower: true)
        var now = 0.0, awake = 0.0
        let name = "KA-LowPowerWake-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, lidClient: lid,
            environmentReader: { environment }, policyClock: { now }, awakeClock: { awake })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.setEnabled(true); environment.lowPower = false; now = 1; awake = 1; service.tick()
        transport.autoStatus = false; now = 31; awake = 31; service.tick(); await settle()
        now = 631; awake = 32
        transport.statusReplies.last?(true, "reply after sleep")
        await settle(); await settle()
        XCTAssertTrue(service.engine.hasLowPowerProtection)
        XCTAssertFalse(service.actualHold)
        now = 660; awake = 61; service.tick(); await settle()
        XCTAssertFalse(service.recoveryInProgress)
        now = 661; awake = 62; service.tick(); await settle()
        XCTAssertTrue(service.recoveryInProgress)
        transport.statusReplies.last?(true, "fresh ready")
        await settle(); await settle()
        XCTAssertNil(service.engine.protection)
    }

    func testRejectedOwnerCannotMutateAnActiveLeaseOrItsRecoveryIntent() throws {
        let owner = UUID().uuidString
        var power = 0
        var saved: KeepAwakeLease.Journal?
        var writes = 0
        let lease = KeepAwakeLease(journal: nil, readPower: { power }, writePower: {
            writes += 1; power = $0
        }, save: { saved = $0 })
        try lease.renew(owner: owner, now: 0)
        let original = saved
        for operation in [
            { try lease.renew(owner: UUID().uuidString, now: 1) },
            { try lease.release(owner: UUID().uuidString) },
            { try lease.release(owner: "invalid") }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual((error as? KeepAwakeLease.Failure)?.isRequestRejection, true)
            }
        }
        XCTAssertEqual(saved, original)
        XCTAssertEqual(power, 1)
        XCTAssertEqual(writes, 1)
        try lease.renew(owner: owner, now: 30)
        XCTAssertEqual(saved?.expires, 210)
        XCTAssertFalse(KeepAwakeLease.Failure.conflict.isRequestRejection)
        XCTAssertFalse(KeepAwakeLease.Failure.writeFailed.isRequestRejection)
    }

    @MainActor
    func testLateErrorFromCompletedRequestDoesNotCancelNewRequest() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.renewReplies[0](true, "applied")
        await settle()
        XCTAssertTrue(client.applied)
        client.apply(hold: false)
        XCTAssertTrue(client.busy)
        transport.errors[1](CocoaError(.xpcConnectionInterrupted))
        await settle()
        XCTAssertTrue(client.busy)
        XCTAssertTrue(client.enabled)
        transport.releaseReplies[0](true, "released")
        await settle()
        XCTAssertFalse(client.busy)
        XCTAssertFalse(client.applied)
        XCTAssertTrue(client.enabled)
    }

    @MainActor
    func testIdleTransportInterruptionClearsAppliedAndCanRecoverExplicitly() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.renewReplies[0](true, "applied")
        await settle()
        transport.disconnects[0]()
        await settle()
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.shouldPrepareForTermination)
        transport.autoRelease = true
        let recovered = await client.recoverAndEnable()
        XCTAssertTrue(recovered)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertEqual(transport.renewReplies.count, 1, "Recovery must wait for the service decision before renewing")
        client.apply(hold: true)
        XCTAssertEqual(transport.renewReplies.count, 2)
        // An old transport's invalidation cannot clear its replacement request.
        transport.disconnects[0]()
        await settle()
        XCTAssertTrue(client.busy)
        transport.renewReplies[1](true, "applied")
        await settle()
        XCTAssertTrue(client.applied)
    }

    @MainActor
    func testRecoveryDoesNotAuthorizeOrEnableLidSupportWithoutPriorIntent() async {
        let transport = HelperTransport()
        let client = client(transport, status: .notRegistered)
        let recovered = await client.recoverAndEnable()
        XCTAssertTrue(recovered)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(transport.errors.isEmpty)
    }

    @MainActor
    func testExplicitRecoveryClearsARejectedRenewalOnlyAfterConfirmedRelease() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.renewReplies[0](false, "protection stopped")
        await settle()
        XCTAssertFalse(client.enabled)
        transport.autoRelease = true
        let recovered = await client.recoverAndEnable()
        XCTAssertTrue(recovered)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertEqual(transport.releaseReplies.count, 1)
    }

    @MainActor
    func testRecoveryFailureKeepsLidDisabledAndPendingRecovery() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.renewReplies[0](false, "failed")
        await settle()
        transport.autoRelease = true
        transport.releaseSuccess = false
        let recovered = await client.recoverAndEnable()
        XCTAssertFalse(recovered)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.shouldPrepareForTermination)
    }

    @MainActor
    func testManualDisableDuringRecoveryCannotBeUndoneByLateReply() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.renewReplies[0](true, "applied")
        await settle()
        let recovery = Task { await client.recoverAndEnable() }
        await settle()
        XCTAssertEqual(transport.releaseReplies.count, 1)
        client.disable()
        transport.releaseReplies[0](true, "released")
        let recovered = await recovery.value
        XCTAssertFalse(recovered)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testRecoveryWithoutAnyRenewalOnlyChecksReachability() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        let recovered = await client.recoverAndEnable()
        XCTAssertTrue(recovered)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertEqual(transport.statusReplies.count, 2)
        XCTAssertTrue(transport.releaseReplies.isEmpty)
        XCTAssertFalse(client.message.contains("恢复已确认"))
    }

    @MainActor
    func testRecoveryStatusFailureWithoutRenewalDoesNotInventPowerRecovery() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        transport.statusSuccess = false
        let recovered = await client.recoverAndEnable()
        XCTAssertFalse(recovered)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.shouldPrepareForTermination)
        XCTAssertTrue(transport.releaseReplies.isEmpty)
    }

    @MainActor
    func testDisableDuringRecoveryStatusCheckCannotBeUndoneByLateReply() async {
        let transport = HelperTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        transport.autoStatus = false
        let recovery = Task { await client.recoverAndEnable() }
        await settle()
        XCTAssertEqual(transport.statusReplies.count, 2)
        client.disable()
        transport.statusReplies[1](true, "late ready")
        let recovered = await recovery.value
        XCTAssertFalse(recovered)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.shouldPrepareForTermination)
        XCTAssertTrue(transport.releaseReplies.isEmpty)
    }

    @MainActor
    private func client(_ transport: HelperTransport, status: SMAppService.Status = .enabled) -> KeepAwakeLidClient {
        KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: { error, disconnected in
                transport.errors.append(error)
                transport.disconnects.append(disconnected)
                return transport
            }, requestTimeout: 1)
    }

    @MainActor
    private func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
}

private final class HelperTransport: NSObject, KeepAwakeHelperProtocol {
    var errors: [(Error) -> Void] = []
    var disconnects: [() -> Void] = []
    var statusReplies: [(Bool, String) -> Void] = []
    var renewReplies: [(Bool, String) -> Void] = []
    var releaseReplies: [(Bool, String) -> Void] = []
    var autoRelease = false
    var releaseSuccess = true
    var autoStatus = true
    var statusSuccess = true
    func status(reply: @escaping (Bool, String) -> Void) {
        statusReplies.append(reply)
        if autoStatus { reply(statusSuccess, "test-only") }
    }
    func renew(owner: String, acOnly: Bool, minimumBattery: Int, respectLowPower: Bool,
               reply: @escaping (Bool, String) -> Void) { renewReplies.append(reply) }
    func release(owner: String, reply: @escaping (Bool, String) -> Void) {
        releaseReplies.append(reply)
        if autoRelease { reply(releaseSuccess, releaseSuccess ? "released" : "recovery failed") }
    }
}
