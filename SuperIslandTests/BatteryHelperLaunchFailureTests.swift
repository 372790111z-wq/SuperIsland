import XCTest
@testable import SuperIsland

final class BatteryHelperLaunchFailureTests: XCTestCase {
    private let parent = "com.workview.SuperIsland.BM1Debug", build = "20261102070936"
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BatteryHelperLaunch/" + name + ".txt"), encoding: .utf8)
    }
    func testActualFailedJobQualifiesButRunningJobDoesNot() throws {
        XCTAssertTrue(BatteryHelperLaunchFailure.confirmed(try fixture("failed"), parent: parent, build: build))
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(try fixture("running"), parent: parent, build: build))
    }
    func testSameHiddenCdhashDataDoesNotDetermineEligibility() throws {
        let failed = try fixture("failed"), running = try fixture("running")
        XCTAssertTrue(failed.contains("\"$in\"")); XCTAssertTrue(running.contains("\"$in\""))
        XCTAssertTrue(BatteryHelperLaunchFailure.confirmed(failed, parent: parent, build: build))
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(running, parent: parent, build: build))
    }
    func testUnifiedLocalIdentitySupportsRepairWithoutAcceptingOtherParents() throws {
        let unified = "com.workview.SuperIsland.WE1Debug"
        let text = try fixture("failed").replacingOccurrences(of: parent, with: unified)
        XCTAssertTrue(BatteryHelperLaunchFailure.confirmed(text, parent: unified, build: build))
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(text, parent: parent, build: build))
    }
    func testOtherLabelParentBuildOrExecutableCannotBeRebound() throws {
        let original = try fixture("failed")
        for text in [original.replacingOccurrences(of: "system/com.workview.SuperIsland.BatteryManagementHelper", with: "system/other"),
                     original.replacingOccurrences(of: "parent bundle identifier = " + parent, with: "parent bundle identifier = other"),
                     original.replacingOccurrences(of: "parent bundle version = " + build, with: "parent bundle version = newer"),
                     original.replacingOccurrences(of: "Contents/MacOS/BatteryManagementHelper (mode: 2)", with: "/tmp/helper (mode: 0)")] {
            XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(text, parent: parent, build: build))
        }
    }
    func testPidInitializedActiveOrSuccessfulExitAreNotARepairSignal() throws {
        let original = try fixture("failed")
        for text in [original.replacingOccurrences(of: "\tactive count = 0", with: "\tactive count = 1"),
                     original.replacingOccurrences(of: "\truns =", with: "\tpid = 123\n\truns ="),
                     original.replacingOccurrences(of: "\truns =", with: "\tinitialized = 1\n\truns ="),
                     original.replacingOccurrences(of: "\truns =", with: "\tpid=123\n\truns ="),
                     original.replacingOccurrences(of: "78: EX_CONFIG", with: "0"),
                     original.replacingOccurrences(of: "spawn failed", with: "running")] {
            XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(text, parent: parent, build: build))
        }
    }
    func testMissingContradictoryTruncatedAndOversizedOutputRemainsUnknown() throws {
        let original = try fixture("failed")
        for text in ["", "Could not find service", String(original.dropLast(4)), original + String(repeating: "x", count: 16_385),
                     original.replacingOccurrences(of: "\tactive count = 0", with: "\tactive count = 0\n\tactive count = 1"),
                     original.replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: "last exit code = 78: EX_CONFIG\n\tlast exit reason = OS_REASON_WATCHDOG"),
                     original.replacingOccurrences(of: "needs LWCR update | ", with: ""),
                     original.replacingOccurrences(of: "managed_by = com.apple.xpc.ServiceManagement", with: "managed_by = other")] {
            XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(text, parent: parent, build: build))
        }
    }
    func testOnlyKnownPrelaunchFailureReasonQualifies() throws {
        let original = try fixture("failed")
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(original.replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: "last exit reason = OS_REASON_CODESIGNING"), parent: parent, build: build),
            "Signing failure precedes invalidation; rebinding here consumes the repair too early")
        for reason in ["last exit code = 1", "last exit reason = OS_REASON_WATCHDOG", "last exit code = (never exited)"] {
            XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(original.replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: reason), parent: parent, build: build))
        }
    }
    func testUnknownParentOrBuildCannotAuthorizeRepair() throws {
        let original = try fixture("failed")
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(original, parent: "other", build: build))
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(original, parent: parent, build: "unknown"))
    }
    func testInvalidPackageFailsProbeWithoutAnAuthorizationOrWrite() async {
        let result = await BatteryHelperLaunchFailure.probe(bundle: URL(fileURLWithPath: "/nonexistent/BM1-probe.app"), parent: parent, build: build)
        XCTAssertFalse(result)
    }
    func testWaitsForSameRecordInvalidationBeforeAuthorizingRepair() async throws {
        let failed = try fixture("failed")
        let signing = failed.replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: "last exit reason = OS_REASON_CODESIGNING")
        var reads = 0, pauses = 0
        let ready = await BatteryHelperLaunchFailure.awaitInvalidation(parent: parent, build: build, read: {
            reads += 1; return reads < 3 ? signing : failed
        }, pause: { pauses += 1 })
        XCTAssertTrue(ready); XCTAssertEqual(reads, 3); XCTAssertEqual(pauses, 2)
    }
    func testSigningFailureAloneHasBoundedWaitAndDoesNotAuthorizeRepair() async throws {
        let signing = try fixture("failed").replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: "last exit reason = OS_REASON_CODESIGNING")
        var reads = 0, pauses = 0
        let ready = await BatteryHelperLaunchFailure.awaitInvalidation(parent: parent, build: build, attempts: 3,
            read: { reads += 1; return signing }, pause: { pauses += 1 })
        XCTAssertFalse(ready); XCTAssertEqual(reads, 3); XCTAssertEqual(pauses, 2)
    }
    func testJobReplacementRunningOrMissingDuringWaitCannotAuthorizeRepair() async throws {
        let failed = try fixture("failed")
        let signing = failed.replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: "last exit reason = OS_REASON_CODESIGNING")
        let different = failed.replacingOccurrences(of: "EF6CFBE1-CFB7-47FD-8D0A-EA138C4B03B2", with: UUID().uuidString)
        for next in [different, try fixture("running"), "", "Could not find service"] {
            var reads = 0
            let ready = await BatteryHelperLaunchFailure.awaitInvalidation(parent: parent, build: build,
                read: { reads += 1; return reads == 1 ? signing : next }, pause: {})
            XCTAssertFalse(ready); XCTAssertEqual(reads, 2)
        }
    }
    func testCancelledObservationAndInvalidRecordIdentityDoNotRepair() async throws {
        let failed = try fixture("failed")
        let signing = failed.replacingOccurrences(of: "last exit code = 78: EX_CONFIG", with: "last exit reason = OS_REASON_CODESIGNING")
        var reads = 0
        let ready = await BatteryHelperLaunchFailure.awaitInvalidation(parent: parent, build: build,
            read: { reads += 1; return signing }, pause: { throw CancellationError() })
        XCTAssertFalse(ready); XCTAssertEqual(reads, 1)
        let malformed = failed.replacingOccurrences(of: "EF6CFBE1-CFB7-47FD-8D0A-EA138C4B03B2", with: "invalid")
        XCTAssertFalse(BatteryHelperLaunchFailure.confirmed(malformed, parent: parent, build: build))
    }
}
