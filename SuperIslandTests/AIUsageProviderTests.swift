import XCTest
@testable import SuperIsland

final class AIUsageProviderTests: XCTestCase {
    private final class Pending {
        var cancelled = false
        let complete: (CodexUsageFetchResult) -> Void
        init(_ complete: @escaping (CodexUsageFetchResult) -> Void) { self.complete = complete }
    }
    private final class Deadline {
        let delay: TimeInterval
        let fire: () -> Void
        var cancelled = false
        init(delay: TimeInterval, fire: @escaping () -> Void) { self.delay = delay; self.fire = fire }
    }
    private final class Harness {
        var now = Date(timeIntervalSince1970: 10_000)
        var credential: CodexUsageCredential? = .init(token: "test-token-A", accountID: "test-account-A")
        var summary: CodexUsageSample?
        var requests: [Pending] = []
        var deadlines: [Deadline] = []
        var logs: [String] = []
        var changed = 0
        var credentialReads = 0
        var queuedWork: [() -> Void] = []
        var deferWork = false
        lazy var service = CodexUsageService(dependencies: .init(
            now: { self.now },
            credential: { self.credentialReads += 1; return self.credential },
            localSummary: { _, _ in self.summary },
            fetch: { _, completion in
                let request = Pending(completion)
                self.requests.append(request)
                return CodexUsageCancellation { request.cancelled = true }
            },
            scheduleTimeout: { delay, fire in
                let deadline = Deadline(delay: delay, fire: fire)
                self.deadlines.append(deadline)
                return CodexUsageCancellation { deadline.cancelled = true }
            },
            work: { work in if self.deferWork { self.queuedWork.append(work) } else { work() } },
            onChange: { self.changed += 1 },
            log: { self.logs.append($0) }
        ))
        func snapshot() -> [String: Any] { service.snapshot() }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func succeed(used: Double = 20) {
            requests.last!.complete(.response(status: 200, data: AIUsageProviderTests.apiData(used: used), retryAfter: nil))
        }
        func fail(_ error: CodexUsageError) { requests.last!.complete(.failure(error)) }
        func status() -> String? { snapshot()["status"] as? String }
        func remaining() -> Double? { (snapshot()["primary"] as? [String: Any])?["remainingPercent"] as? Double }
    }

    private static func apiData(used: Double = 20) -> Data {
        Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(used),\"limit_window_seconds\":604800,\"reset_at\":20000}},\"credits\":{\"unlimited\":true}}".utf8)
    }
    private func good(_ harness: Harness) {
        _ = harness.snapshot()
        harness.succeed()
        XCTAssertEqual(harness.status(), "ready")
    }

    func testSuccessTransientFailureRecoveryPreservesOnlyRealSuccessTime() {
        let h = Harness()
        let first = h.snapshot()
        XCTAssertEqual(first["status"] as? String, "loading")
        XCTAssertTrue(first["updatedAt"] is NSNull)
        h.succeed(used: 37)
        XCTAssertEqual(h.remaining(), 63)
        let initialDate = h.snapshot()["updatedAt"] as? Double
        h.advance(300)
        XCTAssertEqual(h.status(), "stale")
        XCTAssertEqual(h.requests.count, 2)
        h.fail(.timeout)
        XCTAssertEqual(h.status(), "stale")
        XCTAssertEqual(h.remaining(), 63)
        XCTAssertEqual(h.snapshot()["updatedAt"] as? Double, initialDate)
        XCTAssertEqual(h.snapshot()["errorCode"] as? String, "timeout")
        h.advance(15)
        _ = h.snapshot()
        h.succeed(used: 50)
        XCTAssertEqual(h.remaining(), 50)
        XCTAssertEqual(h.status(), "ready")
        XCTAssertEqual(h.snapshot()["updatedAt"] as? Double, h.now.timeIntervalSince1970)
        XCTAssertTrue(h.snapshot()["errorCode"] is NSNull)
    }

    func testFirstFailureNeverInventsAZeroOrSuccessTimestamp() {
        let h = Harness()
        _ = h.snapshot()
        h.fail(.network)
        let state = h.snapshot()
        XCTAssertEqual(state["status"] as? String, "unavailable")
        XCTAssertEqual(state["available"] as? Bool, false)
        XCTAssertTrue(state["primary"] is NSNull)
        XCTAssertTrue(state["updatedAt"] is NSNull)
        XCTAssertEqual(state["nextRetryAt"] as? Double, h.now.timeIntervalSince1970 + 15)
    }

    func testTransientRetryBackoffIs15Then30Then60AndCapped() {
        let h = Harness()
        for delay: Double in [15, 30, 60, 60, 60] {
            _ = h.snapshot()
            h.fail(.network)
            let next = h.snapshot()["nextRetryAt"] as? Double
            XCTAssertEqual(next, h.now.timeIntervalSince1970 + delay)
            let count = h.requests.count
            h.advance(delay - 1)
            _ = h.snapshot()
            XCTAssertEqual(h.requests.count, count)
            h.advance(1)
        }
    }

    func testAuthenticationFailureClearsHistoryAndAvoidsFastRetries() {
        let h = Harness()
        good(h)
        h.advance(300)
        _ = h.snapshot()
        h.requests.last!.complete(.response(status: 401, data: Data(), retryAfter: nil))
        let state = h.snapshot()
        XCTAssertEqual(state["errorCode"] as? String, "auth")
        XCTAssertEqual(state["status"] as? String, "unavailable")
        XCTAssertTrue(state["updatedAt"] is NSNull)
        h.advance(299)
        for _ in 0..<20 { _ = h.snapshot() }
        XCTAssertEqual(h.requests.count, 2)
        h.credential = .init(token: "renewed-token", accountID: "test-account-A")
        _ = h.snapshot()
        XCTAssertEqual(h.requests.count, 3, "A changed credential can retry without waiting for the auth cooldown")
    }

    func testAccountSwitchClearsCachedValueBeforeItsNewRequestCompletes() {
        let h = Harness()
        good(h)
        h.credential = .init(token: "test-token-B", accountID: "test-account-B")
        let notifications = h.changed
        _ = h.snapshot()
        XCTAssertGreaterThan(h.changed, notifications, "The UI is invalidated as soon as a changed account is detected")
        let state = h.snapshot()
        XCTAssertEqual(state["status"] as? String, "loading")
        XCTAssertTrue(state["primary"] is NSNull)
        XCTAssertTrue(state["updatedAt"] is NSNull)
        h.succeed(used: 90)
        XCTAssertEqual(h.remaining(), 10)
    }

    func testLatePreviousAccountResponseCannotEnterNewAccountCache() {
        let h = Harness()
        _ = h.snapshot()
        let old = h.requests[0]
        h.credential = .init(token: "test-token-B", accountID: "test-account-B")
        old.complete(.response(status: 200, data: Self.apiData(used: 1), retryAfter: nil))
        XCTAssertEqual(h.status(), "loading")
        XCTAssertTrue(h.snapshot()["primary"] is NSNull)
        XCTAssertEqual(h.requests.count, 2)
        h.succeed(used: 80)
        old.complete(.response(status: 200, data: Self.apiData(used: 1), retryAfter: nil))
        XCTAssertEqual(h.remaining(), 20)
    }

    func testRotatedTokenDiscardsItsOldInflightResponseAndCanRetryImmediately() {
        let h = Harness()
        _ = h.snapshot()
        let old = h.requests[0]
        h.credential = .init(token: "renewed-token-A", accountID: "test-account-A")
        old.complete(.response(status: 200, data: Self.apiData(used: 5), retryAfter: nil))
        XCTAssertEqual(h.status(), "loading")
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertTrue(h.snapshot()["primary"] is NSNull)
        h.succeed(used: 40)
        XCTAssertEqual(h.remaining(), 60)
        XCTAssertGreaterThanOrEqual(h.credentialReads, 4)
    }

    func testSignOutClearsHistoryAndNeverMakesAnUnauthenticatedRequest() {
        let h = Harness()
        good(h)
        h.credential = nil
        _ = h.snapshot()
        let state = h.snapshot()
        XCTAssertEqual(state["errorCode"] as? String, "no-credentials")
        XCTAssertTrue(state["primary"] is NSNull)
        XCTAssertEqual(h.requests.count, 1)
    }

    func testTimeoutCancelsRequestAndIgnoresLateCompletion() {
        let h = Harness()
        _ = h.snapshot()
        XCTAssertEqual(h.deadlines[0].delay, 10)
        h.deadlines[0].fire()
        XCTAssertTrue(h.requests[0].cancelled)
        XCTAssertEqual(h.snapshot()["errorCode"] as? String, "timeout")
        h.requests[0].complete(.response(status: 200, data: Self.apiData(), retryAfter: nil))
        XCTAssertEqual(h.status(), "unavailable")
        XCTAssertTrue(h.snapshot()["updatedAt"] is NSNull)
    }

    func testSuccessfulCompletionCancelsDeadlineAndIgnoresLateTimeout() {
        let h = Harness()
        good(h)
        XCTAssertTrue(h.deadlines[0].cancelled)
        h.deadlines[0].fire()
        XCTAssertEqual(h.status(), "ready")
        XCTAssertTrue(h.snapshot()["errorCode"] is NSNull)
    }

    func testSnapshotIsNonblockingAndRefreshIsSingleFlight() {
        let h = Harness()
        h.deferWork = true
        let service = h.service // Initialize the fixture before concurrent access.
        DispatchQueue.concurrentPerform(iterations: 30) { _ in _ = service.snapshot() }
        XCTAssertEqual(h.status(), "loading")
        XCTAssertEqual(h.queuedWork.count, 1)
        XCTAssertEqual(h.credentialReads, 0)
        XCTAssertEqual(h.requests.count, 0)
        h.deferWork = false
        h.queuedWork.removeFirst()()
        for _ in 0..<30 { _ = h.snapshot() }
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.credentialReads, 1)
    }

    func testStaleSnapshotExpiresEvenDuringRetryAfterWait() {
        let h = Harness()
        good(h)
        h.advance(899)
        _ = h.snapshot()
        h.requests.last!.complete(.response(status: 429, data: Data(), retryAfter: "300"))
        XCTAssertEqual(h.status(), "stale")
        h.advance(2)
        let state = h.snapshot()
        XCTAssertEqual(state["status"] as? String, "unavailable")
        XCTAssertTrue(state["primary"] is NSNull)
        XCTAssertTrue(state["updatedAt"] is NSNull)
        XCTAssertEqual(h.requests.count, 2)
    }

    func testRateLimitRespectsBoundedRetryAfter() {
        let h = Harness()
        _ = h.snapshot()
        h.requests.last!.complete(.response(status: 429, data: Data(), retryAfter: "99999"))
        XCTAssertEqual(h.snapshot()["nextRetryAt"] as? Double, h.now.timeIntervalSince1970 + 300)
        XCTAssertEqual(h.snapshot()["errorCode"] as? String, "rate-limited")
        XCTAssertNil(CodexUsageService.retryDelay("NaN", now: h.now))
        XCTAssertNil(CodexUsageService.retryDelay("-1", now: h.now))
    }

    func testInvalidPayloadCannotBecome100Percent() {
        let invalid = [
            "{}", "{\"rate_limit\":{}}",
            "{\"rate_limit\":{\"primary_window\":{\"limit_window_seconds\":300}}}",
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":true,\"limit_window_seconds\":300}}}",
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":-1,\"limit_window_seconds\":300}}}",
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":101,\"limit_window_seconds\":300}}}",
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":20,\"limit_window_seconds\":0}}}",
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\"20\",\"limit_window_seconds\":300}}}",
            "{\"rate_limit\":{\"primary_window\":{\"used_percent\":NaN,\"limit_window_seconds\":300}}}"
        ]
        for value in invalid { XCTAssertNil(CodexUsageParser.api(Data(value.utf8), at: Date()), value) }
        let fractional = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":20,\"limit_window_seconds\":61}}}".utf8)
        XCTAssertNil(CodexUsageParser.api(fractional, at: Date()))
        let h = Harness()
        _ = h.snapshot()
        h.requests[0].complete(.response(status: 200, data: Data("{}".utf8), retryAfter: nil))
        XCTAssertEqual(h.snapshot()["errorCode"] as? String, "invalid-response")
    }

    func testOneWeeklyWindowRemainsSingleAndCreditsAreNotUnlimitedUsage() {
        let h = Harness()
        good(h)
        let state = h.snapshot()
        XCTAssertEqual((state["primary"] as? [String: Any])?["windowMinutes"] as? Double, 10080)
        XCTAssertTrue(state["secondary"] is NSNull)
        XCTAssertEqual(state["unlimited"] as? Bool, false)
        XCTAssertEqual(state["creditsUnlimited"] as? Bool, true)
        XCTAssertEqual(h.remaining(), 80)
    }

    private func summaryData(account: String? = "test-account-A", time: Double = 9990, remaining: Any = 75) throws -> Data {
        var root: [String: Any] = ["updatedAt": time, "primary": ["remainingPercent": remaining, "windowMinutes": 10080]]
        if let account { root["accountId"] = account }
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testLocalSummaryRequiresMatchingIdentityFreshTimestampAndValidNumbers() throws {
        let credential = CodexUsageCredential(token: "fake", accountID: "test-account-A")
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertNotNil(CodexUsageParser.local(try summaryData(), credential: credential, at: now))
        XCTAssertNil(CodexUsageParser.local(try summaryData(account: nil), credential: credential, at: now))
        XCTAssertNil(CodexUsageParser.local(try summaryData(account: "different"), credential: credential, at: now))
        XCTAssertNil(CodexUsageParser.local(try summaryData(time: 9700), credential: credential, at: now))
        XCTAssertNil(CodexUsageParser.local(try summaryData(time: 11000), credential: credential, at: now))
        XCTAssertNil(CodexUsageParser.local(try summaryData(remaining: true), credential: credential, at: now))
        XCTAssertNil(CodexUsageParser.local(try summaryData(remaining: -1), credential: credential, at: now))
    }

    func testNearExpirySummaryDoesNotReceiveAnotherFullFiveMinuteTTL() throws {
        let h = Harness()
        h.summary = CodexUsageParser.local(try summaryData(time: 9710), credential: h.credential!, at: h.now)
        _ = h.snapshot()
        XCTAssertEqual(h.status(), "ready")
        XCTAssertEqual(h.snapshot()["updatedAt"] as? Double, 9710)
        XCTAssertEqual(h.snapshot()["nextRetryAt"] as? Double, 10010)
        XCTAssertEqual(h.requests.count, 0)
        h.summary = nil
        h.advance(10)
        _ = h.snapshot()
        XCTAssertEqual(h.requests.count, 1)
    }

    func testDiagnosticsNeverIncludeCredentialsOrAccountIdentifier() {
        let h = Harness()
        good(h)
        h.advance(300)
        _ = h.snapshot()
        h.fail(.network)
        let output = h.logs.joined(separator: "\n")
        XCTAssertTrue(output.contains("stale: network"))
        XCTAssertFalse(output.contains("test-token"))
        XCTAssertFalse(output.contains("test-account"))
    }
}
