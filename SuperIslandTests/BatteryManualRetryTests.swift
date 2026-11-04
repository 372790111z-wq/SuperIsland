import XCTest
import Darwin
@testable import SuperIsland

final class BatteryManualRetryTests: XCTestCase {
    private func request() -> BatteryControlRequest {
        .init(owner: UUID(), preferences: .init(), mode: .discharge, dischargeTarget: 83)
    }
    func testMissedFailureWindowAndRandomNewOperationCannotReplay() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request()
        latch.fail(owner: old.owner, operation: old.operationID, reason: "fence failed")
        XCTAssertThrowsError(try latch.accept(old, recovered: true))
        var random = old; random.operationID = UUID()
        XCTAssertThrowsError(try latch.accept(random, recovered: true))
        XCTAssertTrue(latch.required)
        XCTAssertNotNil(disk)
    }
    func testExactAcknowledgmentNeedsRecoveryAndNewOperation() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request()
        latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        var retry = old; retry.acknowledgedFaultID = latch.faultID
        XCTAssertThrowsError(try latch.accept(retry, recovered: true))
        retry.operationID = UUID()
        XCTAssertThrowsError(try latch.accept(retry, recovered: false))
        try latch.accept(retry, recovered: true)
        XCTAssertFalse(latch.required)
        XCTAssertNotNil(disk, "Accepted record must not be deleted before a possible crash")
    }
    func testHelperRestartInvalidatesPendingAndAcceptedAcknowledgments() throws {
        for accepted in [false, true] {
            var disk: Data?
            let first = BatteryManualRetry(load: { disk }, save: { disk = $0 })
            let old = request()
            first.fail(owner: old.owner, operation: old.operationID, reason: "failed")
            var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = first.faultID
            if accepted { try first.accept(retry, recovered: true) }
            let restarted = BatteryManualRetry(load: { disk }, save: { disk = $0 })
            XCTAssertTrue(restarted.required)
            XCTAssertNotEqual(restarted.faultID, retry.acknowledgedFaultID)
            XCTAssertThrowsError(try restarted.accept(retry, recovered: true))
        }
    }
    func testSecondFailureRejectsPreviouslyAcceptedToken() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "one")
        var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = latch.faultID
        try latch.accept(retry, recovered: true)
        latch.fail(owner: retry.owner, operation: retry.operationID, reason: "two")
        retry.operationID = UUID()
        XCTAssertThrowsError(try latch.accept(retry, recovered: true))
    }
    func testCorruptUnreadableAndUnknownSchemaAreNotAbsence() throws {
        for bytes in [Data(), Data("{}".utf8), Data("{\"schema\":99}".utf8)] {
            let latch = BatteryManualRetry(load: { bytes }, save: { _ in XCTFail("Must preserve corrupt evidence") })
            XCTAssertFalse(latch.durable); XCTAssertTrue(latch.required); XCTAssertNil(latch.faultID)
            XCTAssertThrowsError(try latch.accept(request(), recovered: true))
        }
        let latch = BatteryManualRetry(load: { throw CocoaError(.fileReadNoPermission) }, save: { _ in XCTFail() })
        XCTAssertFalse(latch.durable); XCTAssertTrue(latch.required)
    }
    func testFaultOrAcceptanceSaveFailureNeverOpensAdmission() throws {
        var disk: Data?, fail = true
        let latch = BatteryManualRetry(load: { disk }, save: { if fail { throw CocoaError(.fileWriteNoPermission) }; disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        XCTAssertFalse(latch.durable); XCTAssertTrue(latch.required)
        XCTAssertThrowsError(try latch.accept(request(), recovered: true))
        fail = false
        let second = BatteryManualRetry(load: { nil }, save: { if fail { throw CocoaError(.fileWriteNoPermission) }; disk = $0 })
        second.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = second.faultID
        fail = true
        XCTAssertThrowsError(try second.accept(retry, recovered: true))
        XCTAssertFalse(second.durable); XCTAssertTrue(second.required)
    }
    func testAcceptedAcknowledgmentCannotReplayOldOperationOrChangeBinding() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = latch.faultID
        try latch.accept(retry, recovered: true)
        XCTAssertThrowsError(try latch.validate(old, recovered: true))
        var wrong = retry; wrong.owner = UUID()
        XCTAssertThrowsError(try latch.validate(wrong, recovered: true))
        wrong = retry; wrong.operationID = UUID()
        XCTAssertThrowsError(try latch.validate(wrong, recovered: true))
        XCTAssertNoThrow(try latch.validate(retry.withoutFaultAcknowledgment, recovered: false))
        let completed = BatteryCompletedRequest(retry.withoutFaultAcknowledgment)
        XCTAssertEqual(completed.normalize(retry.withoutFaultAcknowledgment).mode, .automatic)
    }
    func testPersistenceCanRecoverWithoutChangingFaultOrAcknowledgingIt() throws {
        var disk: Data?, fail = true
        let latch = BatteryManualRetry(load: { disk }, save: { if fail { throw CocoaError(.fileWriteNoPermission) }; disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        let original = latch.record?.id
        XCTAssertFalse(latch.durable)
        fail = false; latch.retryPersistence()
        XCTAssertTrue(latch.durable); XCTAssertTrue(latch.required)
        XCTAssertEqual(latch.faultID, original)
        XCTAssertThrowsError(try latch.validate(old, recovered: true))
    }
    func testWatchdogAfterRecoveryNeverResumesPolicyWithoutAcknowledgment() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "supply timeout")
        var restores = 0, applies = 0
        // First recovery remains pending; next completes. Neither permits B
        // verification or policy, even without any new incoming heartbeat.
        for _ in 0..<3 {
            if latch.handleRecovery({ restores += 1 }) { continue }
            applies += 1
        }
        XCTAssertEqual(restores, 3); XCTAssertEqual(applies, 0)
        XCTAssertTrue(latch.required)
        XCTAssertThrowsError(try latch.handleRecovery { throw CocoaError(.fileWriteNoPermission) })
        XCTAssertTrue(latch.required)
    }
    func testResolvedFaultAllowsAutomaticRestartButKeepsOldOperationRejected() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = latch.faultID
        try latch.accept(retry, recovered: true)
        try latch.releasedSuccessfully()
        let restarted = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        XCTAssertFalse(restarted.required)
        XCTAssertThrowsError(try restarted.validate(old, recovered: true))
        XCTAssertThrowsError(try restarted.validate(retry.withoutFaultAcknowledgment, recovered: true))
        XCTAssertNoThrow(try restarted.validate(request(), recovered: true))
    }
    func testUnacknowledgedReleaseCannotResolveFault() throws {
        var disk: Data?
        let latch = BatteryManualRetry(load: { disk }, save: { disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        try latch.releasedSuccessfully()
        XCTAssertTrue(latch.required)
        XCTAssertTrue(BatteryManualRetry(load: { disk }, save: { disk = $0 }).required)
    }
    func testEpochRejectsEveryPriorHelperRequestIncludingLaterOperation() throws {
        var r = request(); let first = UUID(), second = UUID()
        XCTAssertThrowsError(try r.validateEpoch(first))
        r.controlEpoch = first
        XCTAssertNoThrow(try r.validateEpoch(first))
        XCTAssertThrowsError(try r.validateEpoch(second))
        r.operationID = UUID()
        XCTAssertThrowsError(try r.validateEpoch(second))
        r.controlEpoch = second
        XCTAssertNoThrow(try r.validateEpoch(second))
    }
    func testFailedResolvedSaveBecomesANewFaultRatherThanClearingIt() throws {
        var disk: Data?, fail = false
        let latch = BatteryManualRetry(load: { disk }, save: { if fail { throw CocoaError(.fileWriteNoPermission) }; disk = $0 })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "one")
        var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = latch.faultID
        try latch.accept(retry, recovered: true)
        fail = true
        XCTAssertThrowsError(try latch.releasedSuccessfully())
        latch.fail(owner: retry.owner, operation: retry.operationID, reason: "two")
        fail = false; latch.retryPersistence()
        XCTAssertTrue(latch.required)
        XCTAssertNotEqual(latch.faultID, retry.acknowledgedFaultID)
    }
    func testFaultRecordPersistsAndPulseReceiptIsUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pulse = directory.appendingPathComponent("pause-refresh-v1.consumed")
        try Data("consumed".utf8).write(to: pulse)
        let store = BatteryLeaseJournalStore(directory: directory, owner: getuid(), name: "manual-retry")
        let latch = BatteryManualRetry(load: store.load, save: { try store.save($0) })
        let old = request(); latch.fail(owner: old.owner, operation: old.operationID, reason: "failed")
        var retry = old; retry.operationID = UUID(); retry.acknowledgedFaultID = latch.faultID
        try latch.accept(retry, recovered: true)
        XCTAssertEqual(try Data(contentsOf: pulse), Data("consumed".utf8))
        XCTAssertNotNil(try store.load())
    }
}
