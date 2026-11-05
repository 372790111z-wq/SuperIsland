import XCTest
import ServiceManagement
@testable import SuperIsland

@MainActor
final class BatteryCalibrationServiceTests: XCTestCase {
    private final class Transport: BatteryManagementTransport {
        var authorization = SMAppService.Status.enabled
        var helperBundled = true
        var supported = true, settled = true
        var protocolVersion = BatteryControlReport.currentProtocolVersion
        var commands: [BatteryControlRequest] = []
        var releases = 0, time = 0.0
        let runtime = try! BatteryCalibrationRuntime { _ in }
        func register() async throws { XCTFail("Calibration must not register a helper") }
        func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
            var response = BatteryControlReport(); response.available = true
            response.mechanism = "SMC CHTE"; response.dischargeSupported = true
            response.protocolVersion = protocolVersion; response.calibrationSupported = supported
            switch command {
            case .inspect, .refreshCapabilities: break
            case .renew(let request):
                commands.append(request)
                try runtime.accept(request.calibration, owner: request.owner, preferences: request.preferences, supported: supported, date: Date())
                var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 80; sample.onAC = true
                sample.voltage = 12; sample.current = 0; time += 5
                try runtime.tick(telemetry: sample, sleeping: request.sleeping, systemCalibration: false, now: time, date: Date()) { _, _ in self.settled }
                response.mode = request.mode; response.leaseHeldByRequester = true
            case .release:
                releases += 1; try runtime.released(reason: .exit); response.leaseHeldByRequester = false
            }
            response.calibration = runtime.record?.status
            response.message = runtime.record?.status.title ?? "ready"
            return (true, response)
        }
    }
    private func service(_ transport: Transport, ac: Bool = true) -> BatteryManagementService {
        let domain = "SuperIsland.BM1.Calibration.\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        return BatteryManagementService(defaults: UserDefaults(suiteName: domain)!, client: transport,
            telemetryReader: { var sample = BatteryTelemetry(); sample.hasBattery = true; sample.level = 80; sample.onAC = ac; return sample },
            conflictChecker: { nil }, scheduleStarter: {})
    }
    func testStartAndCancelUseSharedRuntimeAndPreserveLongTermPreferences() async throws {
        let t = Transport(), s = service(t); await s.attemptStartupForTesting()
        let saved = s.preferences
        _ = try await s.startCalibration()
        XCTAssertTrue(s.calibrationActive); XCTAssertFalse(s.canStartCalibration)
        XCTAssertNotNil(t.commands.last?.calibration)
        XCTAssertThrowsError(try s.updatePreferences { $0.limit = 85 })
        do { _ = try await s.execute(mode: .topUp); XCTFail("Mode changes require stopping calibration") } catch {}
        _ = try await s.cancelCalibration()
        XCTAssertFalse(s.calibrationActive); XCTAssertTrue(s.canStartCalibration)
        XCTAssertEqual(s.report.calibration?.state, .interrupted)
        XCTAssertNil(s.report.calibration?.lastCompletedAt)
        XCTAssertEqual(s.preferences, saved); XCTAssertEqual(t.releases, 0)
    }
    func testUnsupportedDisconnectedAndOldHelperCannotStartCalibration() async throws {
        for scenario in 0...2 {
            let t = Transport()
            if scenario == 0 { t.supported = false }
            if scenario == 2 { t.protocolVersion = 4 }
            let s = service(t, ac: scenario != 1); await s.attemptStartupForTesting()
            let before = t.commands.count
            do { _ = try await s.startCalibration(); XCTFail("Unavailable calibration must be rejected") } catch {}
            XCTAssertEqual(t.commands.count, before)
            XCTAssertNil(t.runtime.record)
        }
    }
    func testPendingRestoreBlocksNewCycleAndModeChange() async throws {
        let t = Transport(), s = service(t); await s.attemptStartupForTesting()
        _ = try await s.startCalibration(); t.settled = false
        _ = try await s.cancelCalibration()
        XCTAssertTrue(s.calibrationActive)
        XCTAssertEqual(s.report.calibration?.state, .restoring)
        do { _ = try await s.startCalibration(); XCTFail("Restore is not complete") } catch {}
        do { _ = try await s.execute(mode: .automatic); XCTFail("Mode switch cannot bypass restoration") } catch {}
        t.settled = true; _ = try await s.cancelCalibration()
        XCTAssertFalse(s.calibrationActive)
    }
    func testNormalExitRestoresAndNeverMarksCalibrationSuccessful() async throws {
        let t = Transport(), s = service(t); await s.attemptStartupForTesting()
        _ = try await s.startCalibration()
        let canQuit = await s.prepareForTermination()
        XCTAssertTrue(canQuit); XCTAssertEqual(t.releases, 1)
        XCTAssertEqual(s.report.calibration?.state, .interrupted)
        XCTAssertNil(s.report.calibration?.lastCompletedAt)
    }
    func testTemporaryModeMustFinishBeforeStartingScheduledOrIntentCalibration() async throws {
        let t = Transport(), s = service(t); await s.attemptStartupForTesting()
        _ = try await s.execute(mode: .topUp)
        let count = t.commands.count
        do { _ = try await s.startCalibration(); XCTFail("Active temporary mode must not be silently replaced") } catch {}
        XCTAssertEqual(t.commands.count, count)
    }
}
