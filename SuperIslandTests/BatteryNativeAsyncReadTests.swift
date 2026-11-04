import XCTest
@testable import SuperIsland

final class BatteryNativeAsyncReadTests: XCTestCase {
    func testReplyCanArriveBeforeWaitingAndCannotBeReplaced() throws {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: 1)
        XCTAssertTrue(reply.complete(.success(81)))
        XCTAssertFalse(reply.complete(.success(85)))
        XCTAssertEqual(try reply.wait(), 81)
        XCTAssertEqual(try reply.wait(), 81)
    }

    func testReplyFromBackgroundQueueDoesNotNeedMainRunLoop() throws {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: 1)
        DispatchQueue.global().async { reply.complete(.success(80)) }
        XCTAssertEqual(try reply.wait(), 80)
    }

    func testTimeoutSealsResultAndLateReplyIsRejected() throws {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: 0.02)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try reply.wait()) { XCTAssertTrue($0.localizedDescription.contains("超时")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        XCTAssertFalse(reply.complete(.success(85)))
        XCTAssertThrowsError(try reply.wait()) { XCTAssertTrue($0.localizedDescription.contains("超时")) }
    }

    func testCallbackAfterDeadlineBeforeWaitCannotBecomeSuccess() throws {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: 0.01)
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertFalse(reply.complete(.success(85)))
        XCTAssertThrowsError(try reply.wait()) { XCTAssertTrue($0.localizedDescription.contains("超时")) }
    }

    func testConcurrentCallbacksKeepExactlyOneResult() throws {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: 1)
        let callbacks = DispatchGroup()
        let accepted = BatteryNativeAsyncAcceptedCounter()
        for value in 80...100 {
            callbacks.enter()
            DispatchQueue.global().async {
                if reply.complete(.success(value)) {
                    accepted.increment()
                }
                callbacks.leave()
            }
        }
        XCTAssertEqual(callbacks.wait(timeout: .now() + 1), .success)
        let value = try reply.wait()
        XCTAssertTrue((80...100).contains(value))
        XCTAssertEqual(accepted.value, 1)
    }

    func testErrorSurvivesAndCannotBeReplacedByLaterSuccess() throws {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: 1)
        let error = NSError(domain: "BatteryAsyncTest", code: 42)
        XCTAssertTrue(reply.complete(.failure(error)))
        XCTAssertFalse(reply.complete(.success(80)))
        XCTAssertThrowsError(try reply.wait()) {
            XCTAssertEqual(($0 as NSError).domain, error.domain)
            XCTAssertEqual(($0 as NSError).code, 42)
        }
    }

    func testInvalidDeadlinesAreRejected() {
        for interval in [0, -1, .nan, .infinity, 4] {
            XCTAssertThrowsError(try BatteryNativeAsyncReply<Int>(timeout: interval))
        }
    }

    func testOnlyThreeBaseQueriesAreAccepted() {
        for query in [BatteryNativeReadQuery.supported, .enabled, .limit] {
            XCTAssertTrue(BatteryNativeAsyncValidation.acceptsQuery(query))
        }
        for query in [BatteryNativeReadQuery.transport, .supportedAsync, .enabledAsync, .limitAsync] {
            XCTAssertFalse(BatteryNativeAsyncValidation.acceptsQuery(query))
            XCTAssertThrowsError(try BatteryNativeAsyncValidation.result(query: query, rawValue: 1, error: nil).get())
        }
    }

    func testRawCallbackValuesAreValidatedWithoutIntegerOverflow() throws {
        XCTAssertEqual(try BatteryNativeAsyncValidation.result(query: .supported, rawValue: 0, error: nil).get(), 0)
        XCTAssertEqual(try BatteryNativeAsyncValidation.result(query: .enabled, rawValue: 1, error: nil).get(), 1)
        for value: UInt64 in [0, 79, 101, .max] {
            XCTAssertThrowsError(try BatteryNativeAsyncValidation.result(query: .limit, rawValue: value, error: nil).get())
        }
        for value: UInt64 in [2, .max] {
            XCTAssertThrowsError(try BatteryNativeAsyncValidation.result(query: .enabled, rawValue: value, error: nil).get())
        }
        for value: UInt64 in [80, 81, 100] {
            XCTAssertEqual(try BatteryNativeAsyncValidation.result(query: .limit, rawValue: value, error: nil).get(), Int(value))
        }
    }

    func testNSErrorAlwaysRejectsAnOtherwiseValidValue() {
        let error = NSError(domain: "BatteryAsyncTest", code: 12)
        for query in [BatteryNativeReadQuery.supported, .enabled, .limit] {
            XCTAssertThrowsError(try BatteryNativeAsyncValidation.result(query: query, rawValue: query == .limit ? 80 : 1, error: error).get()) {
                XCTAssertEqual(($0 as NSError).domain, "BatteryAsyncTest")
                XCTAssertEqual(($0 as NSError).code, 12)
            }
        }
    }
}

private final class BatteryNativeAsyncAcceptedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
