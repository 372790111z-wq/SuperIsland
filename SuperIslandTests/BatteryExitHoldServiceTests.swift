import XCTest
import ServiceManagement
@testable import SuperIsland

@MainActor
final class BatteryExitHoldServiceTests: XCTestCase {
    private final class Transport: BatteryManagementTransport {
        var authorization = SMAppService.Status.enabled
        var helperBundled = true
        var prepares = 0, releases = 0, renewals = 0
        var failRelease = false
        var prepareReply: (() async throws -> (Bool, BatteryControlReport))?
        var mechanism = BatteryControlCapabilities.Backend.nativePreferences.rawValue
        func register() async throws {}
        func snapshot() -> BatteryControlReport {
            var report = BatteryControlReport()
            report.available = true; report.mechanism = mechanism
            report.dischargeSupported = true; report.minimumDischargeTarget = 20
            report.leaseHeldByRequester = true
            return report
        }
        func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
            var report = snapshot()
            switch command {
            case .inspect: report.leaseHeldByRequester = false
            case .renew(let request): renewals += 1; report.mode = request.mode
            case .release:
                releases += 1; report.recoveryPending = failRelease
                report.leaseHeldByRequester = failRelease
                return (!failRelease, report)
            }
            return (true, report)
        }
        func prepareExitHold(owner: UUID) async throws -> (Bool, BatteryControlReport) {
            prepares += 1
            if let prepareReply { return try await prepareReply() }
            var report = snapshot(); report.exitHoldReady = true
            return (true, report)
        }
    }
    private func service(_ transport: Transport, timeout: TimeInterval = 150) -> BatteryManagementService {
        let domain = "SuperIsland.BM1.ExitHold.\(UUID())", defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return BatteryManagementService(defaults: defaults, client: transport, telemetryReader: {
            BatteryTelemetry.decode(["BatteryInstalled": true, "CurrentCapacity": 80, "MaxCapacity": 100,
                "ExternalConnected": true, "AppleRawExternalConnected": true, "IsCharging": false,
                "InstantAmperage": 0], readAt: Date())
        }, conflictChecker: { nil }, scheduleStarter: {}, exitPreparationTimeout: timeout)
    }
    func testDefaultQuitRestoresWithoutPreparingPersistentHold() async {
        let transport = Transport(), service = service(transport)
        await service.attemptStartupForTesting()
        let result = await service.prepareForTermination()
        XCTAssertTrue(result); XCTAssertEqual(transport.prepares, 0); XCTAssertEqual(transport.releases, 1)
    }
    func testConfirmedHandoffPreservesPreferencesAndShutdownDoesNotRelease() async {
        let transport = Transport(), service = service(transport)
        await service.attemptStartupForTesting()
        let preferences = service.preferences
        var settingsOpened = 0; service.openSettings = { settingsOpened += 1 }
        service.updateDisplay { $0.pauseOnExit = true }
        let result = await service.prepareForTermination()
        XCTAssertTrue(result); XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(service.preferences, preferences); XCTAssertFalse(service.exitPreparationInProgress)
        service.shutdown(); await Task.yield()
        XCTAssertEqual(transport.prepares, 1); XCTAssertEqual(transport.releases, 0)
    }
    func testUserCancellationRetractsAcceptedButUnconfirmedRequest() async {
        let transport = Transport(), service = service(transport)
        await service.attemptStartupForTesting(); service.updateDisplay { $0.pauseOnExit = true }
        transport.prepareReply = {
            service.cancelExitPreparation()
            var report = transport.snapshot(); report.exitHoldReady = false
            return (true, report)
        }
        let result = await service.prepareForTermination()
        XCTAssertFalse(result); XCTAssertEqual(transport.releases, 1)
        XCTAssertFalse(service.shouldPrepareForTermination); XCTAssertFalse(service.exitPreparationInProgress)
    }
    func testLostReplyStillReleasesAndRefusesQuit() async {
        let transport = Transport(), service = service(transport)
        await service.attemptStartupForTesting(); service.updateDisplay { $0.pauseOnExit = true }
        transport.prepareReply = { throw BatteryControlError.unavailable("reply lost after possible handoff") }
        let result = await service.prepareForTermination()
        XCTAssertFalse(result); XCTAssertEqual(transport.releases, 1)
    }
    func testFailureToRecoverRetainsObligation() async {
        let transport = Transport(), service = service(transport, timeout: 0)
        await service.attemptStartupForTesting(); service.updateDisplay { $0.pauseOnExit = true }
        transport.failRelease = true
        let result = await service.prepareForTermination()
        XCTAssertFalse(result); XCTAssertTrue(service.shouldPrepareForTermination)
        XCTAssertTrue(service.report.message.contains("恢复尚未确认"))
    }
    func testAnotherModuleVetoRetractsCompletedHandoff() async {
        let transport = Transport(), service = service(transport)
        await service.attemptStartupForTesting(); service.updateDisplay { $0.pauseOnExit = true }
        let result = await service.prepareForTermination(); XCTAssertTrue(result)
        await service.cancelPreparedTermination()
        XCTAssertEqual(transport.releases, 1); XCTAssertFalse(service.shouldPrepareForTermination)
        service.shutdown(); await Task.yield(); XCTAssertEqual(transport.releases, 1)
    }
    func testReadyFromWrongProtocolOrUnownedLeaseCannotAuthorizeQuit() async {
        for wrongProtocol in [true, false] {
            let transport = Transport(), service = service(transport, timeout: 0.01)
            await service.attemptStartupForTesting(); service.updateDisplay { $0.pauseOnExit = true }
            transport.prepareReply = {
                var report = transport.snapshot(); report.exitHoldReady = true
                if wrongProtocol { report.protocolVersion = 0 } else { report.leaseHeldByRequester = false }
                return (true, report)
            }
            let result = await service.prepareForTermination()
            XCTAssertFalse(result); XCTAssertEqual(transport.releases, 1)
        }
    }
    func testOptInDoesNotStartControlOnBackgroundQueryLaunch() async {
        let transport = Transport(), service = service(transport)
        service.updateDisplay { $0.pauseOnExit = true }
        XCTAssertFalse(service.shouldPrepareForTermination)
        let result = await service.prepareForTermination()
        XCTAssertTrue(result); XCTAssertEqual(transport.prepares, 0); XCTAssertEqual(transport.renewals, 0)
    }
    func testOldDisplayPreferencesDecodeExitHoldAsOff() throws {
        let value = try JSONDecoder().decode(BatteryDisplayPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(value.pauseOnExit)
        var enabled = value; enabled.pauseOnExit = true
        XCTAssertTrue(try JSONDecoder().decode(BatteryDisplayPreferences.self, from: JSONEncoder().encode(enabled)).pauseOnExit)
    }
    func testReadOnlyPreviewCannotTransferExitHold() async {
        do { _ = try await BatteryReadOnlyPreviewTransport().prepareExitHold(owner: UUID()); XCTFail("Read-only transport accepted a mutation") }
        catch {}
    }
}
