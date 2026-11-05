import XCTest
import ServiceManagement
import Combine
@testable import SuperIsland

final class KeepAwakeLidAuthorizationTests: XCTestCase {
    @MainActor func testAlDenteConflictUsesRunningIdentityAndHelperNotInstallation() {
        XCTAssertNil(KeepAwakeLidConflict.reason(bundleIDs: [], helperPaths: []))
        for id in KeepAwakeLidConflict.alDenteIDs {
            XCTAssertNotNil(KeepAwakeLidConflict.reason(bundleIDs: [id], helperPaths: []))
        }
        XCTAssertNotNil(KeepAwakeLidConflict.reason(bundleIDs: [], helperPaths: [KeepAwakeLidConflict.helperPath]))
        XCTAssertNil(KeepAwakeLidConflict.reason(bundleIDs: ["com.example.AlDente"], helperPaths: ["/tmp/AlDente"]))
        XCTAssertNotNil(KeepAwakeLidConflict.reason(bundleIDs: [], helperPaths: [], inventoryComplete: false))
    }

    @MainActor func testConflictPreventsAuthorizationAndSavedIntentRestoreWithoutRegistration() async {
        for restoring in [false, true] {
            var registrations = 0, saved = true
            let transport = AuthorizationTransport()
            let client = client(transport, readIntent: { saved }, saveIntent: { saved = $0 },
                register: { registrations += 1 }, conflict: { "AlDente conflict" })
            if restoring { client.restoreAuthorizedIntent() } else { client.authorize() }
            await settle()
            XCTAssertFalse(client.enabled); XCTAssertFalse(saved)
            XCTAssertEqual(registrations, 0); XCTAssertTrue(transport.statusReplies.isEmpty)
            XCTAssertTrue(transport.renewReplies.isEmpty); XCTAssertTrue(transport.releaseReplies.isEmpty)
            XCTAssertEqual(client.message, "AlDente conflict")
        }
    }

    @MainActor func testConflictDuringStatusCannotBeOverriddenByLateSuccess() async {
        var conflict: String?
        let transport = AuthorizationTransport(); transport.autoStatus = false
        let client = client(transport, conflict: { conflict })
        client.authorize()
        conflict = "AlDente conflict"
        transport.statusReplies[0](true, "late ready"); await settle()
        XCTAssertFalse(client.enabled); XCTAssertFalse(client.applied)
        XCTAssertEqual(client.message, conflict)
        XCTAssertTrue(transport.renewReplies.isEmpty)
    }

    @MainActor func testRunningConflictReleasesOnlyOwnedLeaseAndRequiresExplicitRecovery() async {
        var conflict: String?, saved = false
        let transport = AuthorizationTransport()
        let client = client(transport, readIntent: { saved }, saveIntent: { saved = $0 }, conflict: { conflict })
        client.authorize(); await settle()
        client.apply(hold: true); transport.renewReplies[0](true, "applied"); await settle()
        conflict = "AlDente conflict"; client.apply(hold: true)
        XCTAssertFalse(client.enabled); XCTAssertFalse(saved)
        XCTAssertEqual(transport.releaseReplies.count, 1)
        transport.releaseReplies[0](true, "released"); await settle()
        XCTAssertFalse(client.hasPendingRelease); XCTAssertFalse(client.applied)
        conflict = nil
        for _ in 0..<5 { client.apply(hold: true); client.restoreAuthorizedIntent() }
        XCTAssertFalse(client.enabled); XCTAssertEqual(transport.renewReplies.count, 1)
        XCTAssertFalse(client.releasedForCompletionSleep)
        let automaticRecovery = await client.recoverAndEnable(allowConflictRecovery: false)
        XCTAssertFalse(automaticRecovery); XCTAssertFalse(client.enabled); XCTAssertFalse(saved)
        let recovered = await client.recoverAndEnable()
        XCTAssertTrue(recovered); XCTAssertTrue(client.enabled); XCTAssertTrue(saved)
        client.apply(hold: true); XCTAssertEqual(transport.renewReplies.count, 2)
    }

    @MainActor func testConflictDuringRenewWaitsForReplyAndStillReleasesUnknownLease() async {
        for renewalSucceeded in [false, true] {
            var conflict: String?
            let transport = AuthorizationTransport()
            let client = client(transport, conflict: { conflict })
            client.authorize(); await settle(); client.apply(hold: true)
            conflict = "AlDente conflict"; client.apply(hold: true)
            XCTAssertTrue(transport.releaseReplies.isEmpty, "Do not abandon the in-flight owner reply")
            transport.renewReplies[0](renewalSucceeded, "renew reply"); await settle()
            XCTAssertEqual(transport.releaseReplies.count, 1)
            transport.releaseReplies[0](true, "released"); await settle()
            XCTAssertFalse(client.enabled); XCTAssertFalse(client.hasPendingRelease)
            XCTAssertEqual(client.message, conflict)
        }
    }

    @MainActor func testConflictReleaseFailureIsRetainedWithoutTickRetryOrSleepPermission() async {
        var conflict: String?
        let transport = AuthorizationTransport()
        let client = client(transport, conflict: { conflict })
        client.authorize(); await settle(); client.apply(hold: true)
        transport.renewReplies[0](true, "applied"); await settle()
        conflict = "AlDente conflict"; client.apply(hold: true)
        transport.releaseReplies[0](false, "unknown"); await settle()
        for _ in 0..<5 { client.apply(hold: true) }
        XCTAssertEqual(transport.releaseReplies.count, 1)
        XCTAssertTrue(client.hasPendingRelease); XCTAssertFalse(client.releasedForCompletionSleep)
        client.retryRelease(); XCTAssertEqual(transport.releaseReplies.count, 2)
        transport.releaseReplies[1](true, "released"); await settle()
        XCTAssertFalse(client.enabled); XCTAssertFalse(client.hasPendingRelease)
        let recovered = await client.recoverAndEnable()
        XCTAssertFalse(recovered)
    }

    @MainActor func testConflictAppearingDuringExplicitRecoveryCannotReenable() async {
        var conflict: String?
        let transport = AuthorizationTransport()
        let client = client(transport, conflict: { conflict })
        client.authorize(); await settle()
        transport.autoStatus = false
        let recovery = Task { @MainActor in await client.recoverAndEnable() }
        await settle()
        conflict = "AlDente conflict"
        transport.statusReplies.last?(true, "ready"); await settle()
        let recovered = await recovery.value
        XCTAssertFalse(recovered); XCTAssertFalse(client.enabled)
        XCTAssertTrue(transport.renewReplies.isEmpty)
    }

    @MainActor func testLidConflictLeavesOrdinaryKeepingAndModuleEnabled() async throws {
        var conflict: String?
        let transport = AuthorizationTransport(); transport.autoRelease = true
        let lid = client(transport, conflict: { conflict })
        lid.authorize(); await settle()
        let name = "KA-LidConflict-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let service = KeepAwakeService(defaults: defaults, root: root, codexAvailability: { false }, lidClient: lid,
            environmentReader: { .init(hardware: .notebook, battery: 80, onAC: true) })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.manual(minutes: 30)
        XCTAssertTrue(service.actualHold)
        transport.renewReplies.last?(true, "applied"); await settle()
        conflict = "AlDente conflict"; service.tick(); await settle()
        XCTAssertTrue(service.engine.enabled); XCTAssertTrue(service.actualHold)
        XCTAssertFalse(lid.enabled); XCTAssertFalse(lid.applied)
        XCTAssertFalse(lid.releasedForCompletionSleep)
    }
    @MainActor func testStableDisabledServiceTicksDoNotInvalidateSettingsOrMenus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KA-Idle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "KA-Idle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        var statusReads = 0
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in },
            serviceStatus: { statusReads += 1; return .notRegistered }, signingRequirement: { _ in nil }, conflictReader: { nil })
        let service = KeepAwakeService(defaults: defaults, root: root, codexAvailability: { false }, lidClient: client)
        service.start(); await service.recap.flush(); service.tick(); await service.recap.flush()
        var notifications = 0
        let subscription = service.objectWillChange.sink { notifications += 1 }
        let previousReads = statusReads
        for _ in 0..<10 { service.tick() }
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(statusReads - previousReads, service.isNotebook ? 10 : 0,
                       "At most one registration check per notebook tick; desktop Macs need no lid polling")
        subscription.cancel(); service.shutdown(); await service.recap.flush()
    }
    @MainActor func testRegistrationUIReadsAreCachedButRefreshObservesRevocation() {
        var status = SMAppService.Status.enabled
        var queries = 0
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in },
            serviceStatus: { queries += 1; return status }, signingRequirement: { _ in nil }, conflictReader: { nil })
        XCTAssertEqual(queries, 1)
        for _ in 0..<1_000 { XCTAssertTrue(client.registered); XCTAssertFalse(client.requiresApproval) }
        XCTAssertEqual(queries, 1)
        status = .requiresApproval; client.refreshRegistrationStatus()
        XCTAssertTrue(client.registered); XCTAssertTrue(client.requiresApproval)
        XCTAssertEqual(queries, 2)
        status = .notRegistered; client.refreshRegistrationStatus()
        XCTAssertFalse(client.registered); XCTAssertFalse(client.requiresApproval)
    }
    @MainActor
    func testSuccessfulAuthorizationPersistsOnlyAfterSignedStatusReply() async {
        var saved = false
        let transport = AuthorizationTransport(); transport.autoStatus = false
        let client = client(transport, readIntent: { saved }, saveIntent: { saved = $0 })
        client.authorize()
        XCTAssertFalse(saved)
        transport.statusReplies[0](true, "ready")
        await settle()
        XCTAssertTrue(saved)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
    }

    @MainActor
    func testNormalShutdownPreservesChoiceAndNewClientRevalidatesBeforeReady() async {
        var saved = false
        let firstTransport = AuthorizationTransport()
        let first = client(firstTransport, readIntent: { saved }, saveIntent: { saved = $0 })
        first.authorize(); await settle()
        first.suspendForShutdown()
        XCTAssertTrue(saved)
        XCTAssertFalse(first.enabled)
        let secondTransport = AuthorizationTransport(); secondTransport.autoStatus = false
        let second = client(secondTransport, readIntent: { saved }, saveIntent: { saved = $0 })
        second.restoreAuthorizedIntent()
        XCTAssertFalse(second.enabled)
        second.apply(hold: true)
        XCTAssertTrue(secondTransport.renewReplies.isEmpty)
        secondTransport.statusReplies[0](true, "ready"); await settle()
        XCTAssertTrue(second.enabled)
        XCTAssertFalse(second.applied)
        XCTAssertTrue(secondTransport.releaseReplies.isEmpty)
    }

    @MainActor
    func testNoStoredChoiceDoesNotContactOrRegisterHelper() {
        var registrations = 0, settings = 0
        let transport = AuthorizationTransport()
        let client = client(transport, register: { registrations += 1 }, settings: { settings += 1 })
        client.restoreAuthorizedIntent()
        XCTAssertEqual(registrations, 0); XCTAssertEqual(settings, 0)
        XCTAssertTrue(transport.statusReplies.isEmpty)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testRestoreNeverRegistersOrPromptsWhenSystemAuthorizationIsMissing() {
        for status in [SMAppService.Status.notRegistered, .notFound, .requiresApproval] {
            var registrations = 0, settings = 0
            let transport = AuthorizationTransport()
            let client = client(transport, readIntent: { true }, status: { status },
                                register: { registrations += 1 }, settings: { settings += 1 })
            client.restoreAuthorizedIntent()
            XCTAssertEqual(registrations, 0); XCTAssertEqual(settings, 0)
            XCTAssertTrue(transport.statusReplies.isEmpty)
            XCTAssertFalse(client.enabled)
        }
    }

    @MainActor
    func testExplicitDisableForgetsChoiceAndLateRestoreCannotReenableIt() async {
        var saved = true
        let transport = AuthorizationTransport(); transport.autoStatus = false
        let client = client(transport, readIntent: { saved }, saveIntent: { saved = $0 })
        client.restoreAuthorizedIntent()
        client.disable()
        transport.statusReplies[0](true, "late ready"); await settle()
        XCTAssertFalse(saved); XCTAssertFalse(client.enabled)
        client.restoreAuthorizedIntent()
        XCTAssertEqual(transport.statusReplies.count, 1)
    }

    @MainActor
    func testFailedRestoreCannotClaimReadinessOrAnAppliedLease() async {
        var saved = true
        let transport = AuthorizationTransport(); transport.statusSuccess = false
        let client = client(transport, readIntent: { saved }, saveIntent: { saved = $0 })
        client.restoreAuthorizedIntent(); await settle()
        XCTAssertTrue(saved, "A transient status failure must not change the user's saved choice")
        XCTAssertFalse(client.enabled); XCTAssertFalse(client.applied)
        XCTAssertFalse(client.shouldPrepareForTermination)
    }

    @MainActor
    func testRevokeForgetsChoiceEvenWhenRecoveryRequiresManualAttention() async {
        var saved = true
        let transport = AuthorizationTransport(); transport.autoRelease = true; transport.releaseSuccess = false
        var unregistrations = 0
        let client = client(transport, unregister: { unregistrations += 1 },
                            readIntent: { saved }, saveIntent: { saved = $0 })
        await client.revoke()
        XCTAssertFalse(saved); XCTAssertEqual(unregistrations, 0)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.message.contains("辅助程序保留"))
    }

    @MainActor
    func testNotFoundExplicitAuthorizationActuallyRegisters() async {
        var status: SMAppService.Status = .notFound
        var registrations = 0
        var settingsOpened = 0
        let transport = AuthorizationTransport()
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1; status = .enabled },
            openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1; status = .requiresApproval },
            openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: {
                registrations += 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "PRIVATE-TOKEN-FROM-DESCRIPTION",
                    NSFilePathErrorKey: "/Users/private-test/secret-file"
                ])
            }, openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .enabled }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy,
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notFound }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notFound }, signingRequirement: { _ in nil },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 }, conflictReader: { nil })
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
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy, requestTimeout: 1, conflictReader: { nil })
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
    func testCompletionSleepWaitsForOwnedReleaseAcknowledgement() async {
        let transport = AuthorizationTransport()
        let client = client(transport)
        client.authorize(); await settle()
        client.apply(hold: true)
        XCTAssertFalse(client.releasedForCompletionSleep)
        transport.renewReplies[0](true, "applied"); await settle()
        XCTAssertFalse(client.releasedForCompletionSleep)
        client.apply(hold: false)
        XCTAssertFalse(client.releasedForCompletionSleep, "A queued release is not a release acknowledgement")
        transport.releaseReplies[0](true, "released"); await settle()
        XCTAssertTrue(client.releasedForCompletionSleep)
        client.disable()
        XCTAssertFalse(client.releasedForCompletionSleep)
    }

    @MainActor
    func testFailedReleaseCannotAuthorizeCompletionSleep() async {
        let transport = AuthorizationTransport()
        let client = client(transport)
        client.authorize(); await settle()
        client.apply(hold: true)
        transport.renewReplies[0](true, "applied"); await settle()
        client.apply(hold: false)
        transport.releaseReplies[0](false, "unconfirmed"); await settle()
        XCTAssertFalse(client.releasedForCompletionSleep)
    }

    @MainActor
    private func client(_ transport: AuthorizationTransport, timeout: TimeInterval = 1,
                        unregister: @escaping () async throws -> Void = {},
                        readIntent: @escaping () -> Bool = { false }, saveIntent: @escaping (Bool) -> Void = { _ in },
                        status: @escaping () -> SMAppService.Status = { .enabled },
                        register: @escaping () throws -> Void = {}, settings: @escaping () -> Void = {},
                        conflict: @escaping () -> String? = { nil }) -> KeepAwakeLidClient {
        KeepAwakeLidClient(readEnabledIntent: readIntent, saveEnabledIntent: saveIntent, serviceStatus: status, signingRequirement: { _ in "test-only" },
            remoteProxyFactory: transport.proxy, requestTimeout: timeout,
            registerService: register, unregisterService: unregister, openSystemSettings: settings, conflictReader: conflict)
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
