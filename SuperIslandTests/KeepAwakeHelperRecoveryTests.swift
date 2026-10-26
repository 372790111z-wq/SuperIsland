import XCTest
import ServiceManagement
@testable import SuperIsland

final class KeepAwakeHelperRecoveryTests: XCTestCase {
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
