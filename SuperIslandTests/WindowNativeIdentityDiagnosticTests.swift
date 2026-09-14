import Foundation
import XCTest
@testable import SuperIsland

final class WindowNativeIdentityDiagnosticTests: XCTestCase {
    func testDeadlineDoesNotFreeTheOutstandingWorkerSlot() {
        var gate = WindowNativeIdentityDiagnosticAdmission()
        let first = gate.begin(now: 0)!
        // Reporting expired at 0.5s cannot admit another blocked AX operation.
        XCTAssertNil(gate.begin(now: 5_000_000_000))
        gate.workerFinished(sampleID: first)
        XCTAssertNotNil(gate.begin(now: 5_000_000_000))
    }

    func testOldCompletionCannotReleaseANewerSample() {
        var gate = WindowNativeIdentityDiagnosticAdmission()
        let first = gate.begin(now: 0)!
        gate.workerFinished(sampleID: first)
        let second = gate.begin(now: 2_000_000_000)!
        gate.workerFinished(sampleID: first)
        XCTAssertEqual(gate.inFlightID, second)
        XCTAssertNil(gate.begin(now: 4_000_000_000))
    }

    func testTwoSecondThrottleAndClockRollbackAreFailClosed() {
        var gate = WindowNativeIdentityDiagnosticAdmission()
        let first = gate.begin(now: 1_000_000_000)!
        gate.workerFinished(sampleID: first)
        XCTAssertNil(gate.begin(now: 999_999_999))
        XCTAssertNil(gate.begin(now: 2_999_999_999))
        XCTAssertNotNil(gate.begin(now: 3_000_000_000))
    }

    func testReadReturningAfterDeadlineIsNotCurrent() {
        var budget = WindowNativeIdentityDiagnosticBudget(startedAt: 100)
        XCTAssertTrue(budget.reserveRead(now: 100))
        XCTAssertTrue(budget.isCurrent(now: 500_000_099))
        XCTAssertFalse(budget.isCurrent(now: 500_000_100))
        XCTAssertEqual(budget.stopReason, "expiredUnknown")
        XCTAssertFalse(budget.reserveRead(now: 500_000_101))
        XCTAssertEqual(budget.reads, 1)
    }

    func testReadBudgetNeverAdmitsAnExtraIPC() {
        var budget = WindowNativeIdentityDiagnosticBudget(startedAt: 0)
        for _ in 0..<20 { XCTAssertTrue(budget.reserveRead(now: 1)) }
        XCTAssertFalse(budget.reserveRead(now: 2))
        XCTAssertEqual(budget.reads, 20)
        XCTAssertEqual(budget.stopReason, "readBudgetUnknown")
    }

    func testRoleTextCannotEscapeTheFixedCodesAndURLsMatchExactly() {
        XCTAssertEqual(WindowNativeIdentityDiagnosticPolicy.roleCode("AXButton"), "button")
        XCTAssertEqual(WindowNativeIdentityDiagnosticPolicy.roleCode("private user content"), "unknown")
        let candidates = [
            WindowNativeIdentityDiagnosticCandidate(pid: 10, bundleURL: URL(fileURLWithPath: "/Applications/WeChat.app")),
            WindowNativeIdentityDiagnosticCandidate(pid: 20, bundleURL: URL(fileURLWithPath: "/Applications/WeChat-Work2.app"))
        ]
        XCTAssertEqual(WindowNativeIdentityDiagnosticPolicy.matchingPIDs(
            url: URL(fileURLWithPath: "/Applications/WeChat-Work2.app"), candidates: candidates
        ), [20])
        XCTAssertTrue(WindowNativeIdentityDiagnosticPolicy.matchingPIDs(
            url: URL(fileURLWithPath: "/Applications/WeChat-Work2.app/Contents"), candidates: candidates
        ).isEmpty)
        XCTAssertTrue(WindowNativeIdentityDiagnosticPolicy.matchingPIDs(
            url: URL(string: "https://example.com/Applications/WeChat.app"), candidates: candidates
        ).isEmpty)
    }
}
