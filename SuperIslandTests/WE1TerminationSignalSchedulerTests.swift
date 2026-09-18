import XCTest
@testable import SuperIsland

@MainActor
final class WE1TerminationSignalSchedulerTests: XCTestCase {
    func testRepeatedSignalsQueueOneTerminationWithoutCallingItInline() {
        var callbacks: [WE1TerminationSignalScheduler.Operation] = []
        let scheduler = WE1TerminationSignalScheduler { callbacks.append($0) }
        var calls = 0
        for _ in 0..<3 {
            scheduler.request(isTerminationDeferred: { false }) { calls += 1 }
        }
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(calls, 0)
        callbacks.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testSignalDuringTerminationDoesNotNestAndCancellationAllowsRetry() {
        var callbacks: [WE1TerminationSignalScheduler.Operation] = []
        let scheduler = WE1TerminationSignalScheduler { callbacks.append($0) }
        var calls = 0
        scheduler.request(isTerminationDeferred: { false }) {
            calls += 1
            scheduler.terminationDidBegin()
            scheduler.request(isTerminationDeferred: { false }) { calls += 10 }
        }
        callbacks.removeFirst()()
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(calls, 1)

        // Returning from terminate models AppKit cancelling the first quit.
        scheduler.request(isTerminationDeferred: { false }) { calls += 1 }
        XCTAssertEqual(callbacks.count, 1)
        callbacks.removeFirst()()
        XCTAssertEqual(calls, 2)
    }

    func testAlreadyDeferredQuitDoesNotQueueAnotherTermination() {
        var callbacks: [WE1TerminationSignalScheduler.Operation] = []
        let scheduler = WE1TerminationSignalScheduler { callbacks.append($0) }
        scheduler.request(isTerminationDeferred: { true }) {
            XCTFail("Must use the existing deferred quit")
        }
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testDeferredQuitIsRecheckedWhenQueuedSignalRuns() {
        var callbacks: [WE1TerminationSignalScheduler.Operation] = []
        let scheduler = WE1TerminationSignalScheduler { callbacks.append($0) }
        var deferred = false
        var calls = 0
        scheduler.request(isTerminationDeferred: { deferred }) { calls += 1 }
        deferred = true
        callbacks.removeFirst()()
        XCTAssertEqual(calls, 0)

        deferred = false
        scheduler.request(isTerminationDeferred: { deferred }) { calls += 1 }
        callbacks.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testRegularQuitSupersedesQueuedSignalEvenIfItCancelsBeforeCallback() {
        var callbacks: [WE1TerminationSignalScheduler.Operation] = []
        let scheduler = WE1TerminationSignalScheduler { callbacks.append($0) }
        var calls = 0
        scheduler.request(isTerminationDeferred: { false }) { calls += 10 }
        scheduler.terminationDidBegin()
        // A later explicit signal is a new request; the stale callback must
        // neither invoke termination nor clear the new request's ownership.
        scheduler.request(isTerminationDeferred: { false }) { calls += 1 }
        XCTAssertEqual(callbacks.count, 2)
        callbacks.removeFirst()()
        XCTAssertEqual(calls, 0)
        callbacks.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testQueuedRequestDoesNotRetainSchedulerOrTerminateAfterRelease() {
        var callbacks: [WE1TerminationSignalScheduler.Operation] = []
        var scheduler: WE1TerminationSignalScheduler? = .init { callbacks.append($0) }
        weak var weakScheduler = scheduler
        scheduler?.request(isTerminationDeferred: { false }) {
            XCTFail("Released owner cannot request termination")
        }
        scheduler = nil
        XCTAssertNil(weakScheduler)
        callbacks.removeFirst()()
    }
}
