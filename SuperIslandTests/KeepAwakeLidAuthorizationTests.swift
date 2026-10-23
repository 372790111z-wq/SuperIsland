import XCTest
import ServiceManagement
@testable import SuperIsland

final class KeepAwakeLidAuthorizationTests: XCTestCase {
    @MainActor
    func testNotFoundExplicitAuthorizationActuallyRegisters() async {
        var status: SMAppService.Status = .notFound
        var registrations = 0
        var settingsOpened = 0
        let transport = AuthorizationTransport()
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1; status = .enabled },
            openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        await settle()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied, "Registration cannot claim an applied power lease")
    }

    @MainActor
    func testNotRegisteredRegistersThenRequiresUserApproval() async {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var settingsOpened = 0
        let transport = AuthorizationTransport()
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1; status = .requiresApproval },
            openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertTrue(client.requiresApproval)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testRegisterErrorKeepsDisabledAndPreservesOnlyDomainAndCode() async {
        var status: SMAppService.Status = .enabled
        var registrations = 0
        var settingsOpened = 0
        let transport = AuthorizationTransport()
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: {
                registrations += 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "PRIVATE-TOKEN-FROM-DESCRIPTION",
                    NSFilePathErrorKey: "/Users/private-test/secret-file"
                ])
            }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        await settle()
        XCTAssertTrue(client.enabled)
        status = .notFound
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertTrue(client.message.contains("SMAppServiceErrorDomain"))
        XCTAssertTrue(client.message.contains("3"))
        XCTAssertFalse(client.message.contains("PRIVATE-TOKEN"))
        XCTAssertFalse(client.message.contains("private-test"))
    }

    @MainActor
    func testRequiresApprovalOpensSettingsWithoutRegisteringOrEnabling() async {
        var status: SMAppService.Status = .enabled
        var registrations = 0
        var settingsOpened = 0
        let transport = AuthorizationTransport()
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        await settle()
        XCTAssertTrue(client.enabled)
        status = .requiresApproval
        client.authorize()
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
    }

    @MainActor
    func testEnabledServiceIsNotRegisteredAgain() async {
        var registrations = 0
        var settingsOpened = 0
        let transport = AuthorizationTransport()
        let client = KeepAwakeLidClient(serviceStatus: { .enabled }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        await settle()
        client.authorize()
        await settle()
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
    }

    @MainActor
    func testUnresolvedStatusAfterRegisterDoesNotPretendEnabled() async {
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { .notFound }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.message.contains("状态 3"))
    }

    @MainActor
    func testUnsignedPackageCannotRequestRegistrationOrSettings() async {
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { .notFound }, signingRequirement: { _ in nil },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testEnabledRegistrationWaitsForReachableStatusBeforeBecomingReady() async {
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        let client = client(transport)
        client.authorize()
        XCTAssertTrue(client.busy)
        XCTAssertFalse(client.enabled)
        client.apply(hold: true)
        XCTAssertTrue(transport.renewReplies.isEmpty)
        XCTAssertTrue(transport.releaseReplies.isEmpty)
        transport.statusReplies[0](true, "ready")
        await settle()
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.busy)
        XCTAssertTrue(transport.renewReplies.isEmpty)
        XCTAssertTrue(transport.releaseReplies.isEmpty)
    }

    @MainActor
    func testEnabledButUnspawnableServiceNeverBecomesReady() async {
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        let client = client(transport)
        client.authorize()
        transport.errors[0](CocoaError(.xpcConnectionInvalid))
        await settle()
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.busy)
        XCTAssertFalse(client.shouldPrepareForTermination, "A status failure must not invent an owned power lease")
        transport.statusReplies[0](true, "late reply")
        await settle()
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testStatusTimeoutDoesNotPretendEnabledOrPendingPowerRecovery() async {
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        let client = client(transport, timeout: 0.01)
        client.authorize()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.busy)
        XCTAssertFalse(client.shouldPrepareForTermination)
        XCTAssertTrue(client.message.contains("未响应"))
    }

    @MainActor
    func testStatusRejectionDoesNotPretendEnabled() async {
        let transport = AuthorizationTransport()
        transport.statusSuccess = false
        let client = client(transport)
        client.authorize()
        await settle()
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.shouldPrepareForTermination)
    }

    @MainActor
    func testAuthorizationRemovedDuringStatusCheckCannotBeReenabledByReply() async {
        var status: SMAppService.Status = .enabled
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy, requestTimeout: 1)
        client.authorize()
        status = .requiresApproval
        transport.statusReplies[0](true, "ready")
        await settle()
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertTrue(client.requiresApproval)
    }

    @MainActor
    func testDisableCancelsStatusCheckAndRejectsItsLateSuccess() async {
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        let client = client(transport)
        client.authorize()
        client.disable()
        XCTAssertFalse(client.busy)
        transport.statusReplies[0](true, "ready")
        await settle()
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.shouldPrepareForTermination)
        XCTAssertTrue(transport.releaseReplies.isEmpty)
    }

    @MainActor
    func testLateStatusErrorDoesNotCancelARealRenewal() async {
        let transport = AuthorizationTransport()
        let client = client(transport)
        client.authorize()
        await settle()
        client.apply(hold: true)
        XCTAssertEqual(transport.renewReplies.count, 1)
        transport.errors[0](CocoaError(.xpcConnectionInterrupted))
        await settle()
        XCTAssertTrue(client.enabled)
        XCTAssertTrue(client.busy)
        transport.renewReplies[0](true, "applied")
        await settle()
        XCTAssertTrue(client.applied)
    }

    @MainActor
    func testRevokeCancelsStatusButStillRequiresOwnerCheckedAcknowledgement() async {
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        transport.autoRelease = true
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 })
        client.authorize()
        await client.revoke()
        XCTAssertEqual(unregistrations, 1)
        XCTAssertEqual(transport.releaseReplies.count, 1)
        transport.statusReplies[0](true, "another owner has an active lease")
        await settle()
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.busy)
        XCTAssertFalse(client.message.contains("已恢复"))
    }

    @MainActor
    func testUnspawnableServiceRemainsRegisteredWithoutConfirmedRelease() async {
        let transport = AuthorizationTransport()
        transport.autoStatus = false
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 })
        client.authorize()
        transport.errors[0](CocoaError(.xpcConnectionInvalid))
        await settle()
        let revoke = Task { await client.revoke() }
        await settle()
        transport.errors[1](CocoaError(.xpcConnectionInvalid))
        await revoke.value
        XCTAssertEqual(unregistrations, 0)
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertTrue(client.shouldPrepareForTermination)
        XCTAssertTrue(client.message.contains("辅助程序保留"))
        XCTAssertFalse(client.message.contains("已恢复"))
    }

    @MainActor
    func testForeignLeaseStatusCannotAuthorizeUnregister() async {
        let transport = AuthorizationTransport()
        transport.statusMessage = "合盖租约已应用"
        transport.autoRelease = true
        transport.releaseSuccess = false
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 })
        client.authorize()
        await settle()
        XCTAssertFalse(client.applied)
        await client.revoke()
        XCTAssertEqual(unregistrations, 0)
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertTrue(client.message.contains("辅助程序保留"))
        XCTAssertFalse(client.message.contains("已恢复"))
    }

    @MainActor
    func testNoReleaseResponseKeepsHelperRegisteredEvenWithoutOwnRenewal() async {
        let transport = AuthorizationTransport()
        var unregistrations = 0
        let client = client(transport, timeout: 0.01, unregister: { unregistrations += 1 })
        client.authorize()
        await settle()
        await client.revoke()
        XCTAssertEqual(unregistrations, 0, "An unowned lease must retain its independent recovery daemon")
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.message.contains("辅助程序保留"))
        XCTAssertFalse(client.busy)
    }

    @MainActor
    func testStaleOwnerReleaseAcknowledgementCannotCompleteRevocation() async {
        let transport = AuthorizationTransport()
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 })
        let revoke = Task { await client.revoke() }
        await settle()
        XCTAssertTrue(client.busy)
        client.disable()
        transport.releaseReplies[0](true, "released")
        await revoke.value
        XCTAssertEqual(unregistrations, 0)
        XCTAssertFalse(client.busy)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testOwnedLeaseIsConfirmedReleasedBeforeUnregistering() async {
        let transport = AuthorizationTransport()
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 })
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.renewReplies[0](true, "applied")
        await settle()
        transport.autoRelease = true
        await client.revoke()
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertEqual(unregistrations, 1)
        XCTAssertFalse(client.applied)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.message.contains("已确认释放"))
    }

    @MainActor
    func testUncertainRenewalCannotUnregisterUntilItsReleaseIsConfirmed() async {
        let transport = AuthorizationTransport()
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 })
        client.authorize()
        await settle()
        client.apply(hold: true)
        transport.errors[1](CocoaError(.xpcConnectionInterrupted))
        await settle()
        transport.autoRelease = true
        transport.releaseSuccess = false
        await client.revoke()
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertEqual(unregistrations, 0)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.shouldPrepareForTermination)
        XCTAssertTrue(client.message.contains("辅助程序保留"))
        transport.releaseSuccess = true
        await client.revoke()
        XCTAssertEqual(transport.releaseReplies.count, 2)
        XCTAssertEqual(unregistrations, 1)
        XCTAssertFalse(client.shouldPrepareForTermination)
    }

    @MainActor
    func testUnregisterFailurePreservesOnlyDomainAndCodeWithoutFalseRecovery() async {
        let transport = AuthorizationTransport()
        transport.autoRelease = true
        let client = client(transport, unregister: {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "PRIVATE-TOKEN-AND-PATH"])
        })
        await client.revoke()
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertTrue(client.message.contains("SMAppServiceErrorDomain"))
        XCTAssertTrue(client.message.contains("9"))
        XCTAssertFalse(client.message.contains("PRIVATE-TOKEN"))
        XCTAssertFalse(client.message.contains("恢复完成"))
    }

    @MainActor
    func testAuthorizationCannotStartDuringUnregister() async {
        let transport = AuthorizationTransport()
        transport.autoRelease = true
        var unregisterReply: CheckedContinuation<Void, Never>?
        let client = client(transport, unregister: {
            await withCheckedContinuation { unregisterReply = $0 }
        })
        let revoke = Task { await client.revoke() }
        let deadline = KeepAwakeClock.now() + 1
        while unregisterReply == nil && KeepAwakeClock.now() < deadline { await Task.yield() }
        guard let reply = unregisterReply else { revoke.cancel(); XCTFail("Unregister did not start"); return }
        XCTAssertTrue(client.busy)
        client.authorize()
        XCTAssertTrue(transport.statusReplies.isEmpty)
        XCTAssertFalse(client.enabled)
        reply.resume()
        await revoke.value
        XCTAssertFalse(client.busy)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    private func client(_ transport: AuthorizationTransport, timeout: TimeInterval = 1,
                        unregister: @escaping () async throws -> Void = {}) -> KeepAwakeLidClient {
        KeepAwakeLidClient(serviceStatus: { .enabled }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy, requestTimeout: timeout,
            unregisterService: unregister)
    }

    @MainActor
    private func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
}

private final class AuthorizationTransport: NSObject, KeepAwakeHelperProtocol {
    var errors: [(Error) -> Void] = []
    var disconnects: [() -> Void] = []
    var statusReplies: [(Bool, String) -> Void] = []
    var renewReplies: [(Bool, String) -> Void] = []
    var releaseReplies: [(Bool, String) -> Void] = []
    var autoStatus = true
    var statusSuccess = true
    var statusMessage = "ready"
    var autoRelease = false
    var releaseSuccess = true

    func proxy(error: @escaping (Error) -> Void, disconnected: @escaping () -> Void) throws -> KeepAwakeHelperProtocol {
        errors.append(error); disconnects.append(disconnected); return self
    }
    func status(reply: @escaping (Bool, String) -> Void) {
        statusReplies.append(reply)
        if autoStatus { reply(statusSuccess, statusMessage) }
    }
    func renew(owner: String, acOnly: Bool, minimumBattery: Int, respectLowPower: Bool,
               reply: @escaping (Bool, String) -> Void) { renewReplies.append(reply) }
    func release(owner: String, reply: @escaping (Bool, String) -> Void) {
        releaseReplies.append(reply)
        if autoRelease { reply(releaseSuccess, releaseSuccess ? "released" : "recovery failed") }
    }
}
