import ApplicationServices
import XCTest
@testable import SuperIsland

final class WindowAXExactRecoveryTests: XCTestCase {
    func testDisplayedRowGuardSurvivesHoverStateClearedDuringDelayedHide() {
        var hoverRevision: WindowAXLifecycleRevision? = WindowAXLifecycleRevision()
        var currentRevision = hoverRevision
        var performed = 0
        let rowAction = WindowAXLifecycleActionPolicy.guardedAction(
            captured: hoverRevision, current: { currentRevision }, action: { performed += 1 }
        )
        hoverRevision = nil // cancelHoverPipeline during 320 ms hide grace
        rowAction() // Entering the still-visible, live card remains usable.
        XCTAssertEqual(performed, 1)
        currentRevision = nil // Observer removed before UI retirement dispatch.
        rowAction()
        XCTAssertEqual(performed, 1)
        currentRevision = WindowAXLifecycleRevision() // Reinstalled observer, same numeric generation.
        rowAction()
        XCTAssertEqual(performed, 1)
        XCTAssertNil(hoverRevision)
    }

    func testRecoveredActionRejectsRemovedObserverAndRetiredOrReplacedProxyBeforeNotification() {
        let captured = WindowAXLifecycleRevision()
        XCTAssertTrue(WindowAXLifecycleActionPolicy.isCurrent(captured: captured, current: captured))
        XCTAssertFalse(WindowAXLifecycleActionPolicy.isCurrent(captured: captured, current: nil))
        XCTAssertFalse(WindowAXLifecycleActionPolicy.isCurrent(captured: captured, current: captured.advanced()))
        XCTAssertFalse(WindowAXLifecycleActionPolicy.isCurrent(captured: captured, current: WindowAXLifecycleRevision()))
        // Ordinary apps without a successfully installed observer retain their
        // existing exact-AX validation path; recovery never admits these apps.
        XCTAssertTrue(WindowAXLifecycleActionPolicy.isCurrent(captured: nil, current: nil))
    }

    func testAcceptsOnlyAnExactLiveOrderedInWindowRoot() {
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(requestedPID: 0, actualPID: 0))
        XCTAssertFalse(accepts(actualPID: 99))
        XCTAssertFalse(accepts(actualWindowID: 0))
        XCTAssertFalse(accepts(actualWindowID: 11))
        XCTAssertFalse(accepts(roleResult: .cannotComplete))
        XCTAssertFalse(accepts(role: kAXGroupRole as String))
        XCTAssertFalse(accepts(role: kAXSheetRole as String))
        XCTAssertFalse(accepts(role: nil))
        XCTAssertFalse(accepts(isOrderedIn: false))
        XCTAssertFalse(accepts(isOrderedIn: nil))
        XCTAssertFalse(accepts(processIsCurrent: false))
    }

    func testLookupErrorsDoNotTreatTransportFailuresAsMissingTokens() {
        for error in [AXError.illegalArgument, .invalidUIElement, .attributeUnsupported, .notImplemented, .noValue] {
            XCTAssertTrue(WindowAXExactRecoveryPolicy.isDefinitiveLookupFailure(error))
        }
        for error in [AXError.success, .failure, .cannotComplete, .apiDisabled] {
            XCTAssertFalse(WindowAXExactRecoveryPolicy.isDefinitiveLookupFailure(error))
        }
    }

    func testRemoteTokenHasExactLittleEndianLayout() {
        XCTAssertEqual(
            Array(WindowAXExactRecoveryPolicy.token(
                processIdentifier: 0x12345678,
                elementID: 0x1122334455667788
            )),
            [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0,
             0x6f, 0x63, 0x6f, 0x63, 0x88, 0x77, 0x66, 0x55,
             0x44, 0x33, 0x22, 0x11]
        )
    }

    func testSparseNamespaceContinuesAcrossBoundedAttempts() {
        var cursor = WindowAXRecoveryScanCursor()
        var visited: [UInt64] = []
        let resolve: (UInt64, Set<CGWindowID>) -> WindowAXRecoveryLookup<String> = { id, _ in
            visited.append(id)
            return id == 4 ? .found(windowID: 10, element: "root") : .definiteMiss
        }
        let first = cursor.scan(targets: [10], maximumCandidates: 2, shouldContinue: { true }, resolve: resolve)
        XCTAssertTrue(first.elements.isEmpty)
        XCTAssertEqual(first.attempts, 2)
        XCTAssertEqual(cursor.nextElementID, 2)
        let second = cursor.scan(targets: [10], maximumCandidates: 3, shouldContinue: { true }, resolve: resolve)
        XCTAssertEqual(second.elements, [10: "root"])
        XCTAssertEqual(visited, [0, 1, 2, 3, 4])
        XCTAssertEqual(cursor.knownElementIDs, [10: 4])
    }

    func testBudgetExpiringInsideCandidateKeepsThatCandidateForNextAttempt() {
        var cursor = WindowAXRecoveryScanCursor()
        var hasBudget = true
        var visited: [UInt64] = []
        let first = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { hasBudget }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            hasBudget = false // Simulate time consumed by this candidate's AX IPC.
            return .inconclusive
        }
        XCTAssertTrue(first.elements.isEmpty)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertEqual(cursor.nextElementID, 0)
        hasBudget = true
        let second = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { hasBudget }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return .found(windowID: 10, element: "root")
        }
        XCTAssertEqual(visited, [0, 0])
        XCTAssertEqual(second.elements, [10: "root"])
    }

    func testCancellationInsideCandidatePreservesOnlyItsUnfinishedPosition() {
        var cursor = WindowAXRecoveryScanCursor()
        var cancelled = false
        var visited: [UInt64] = []
        let first = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { !cancelled }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            if id == 0 { return .definiteMiss }
            cancelled = true
            return .inconclusive
        }
        XCTAssertTrue(first.elements.isEmpty)
        XCTAssertEqual(cursor.nextElementID, 1)
        cancelled = false
        let second = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { !cancelled }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return .found(windowID: 10, element: "root")
        }
        XCTAssertEqual(visited, [0, 1, 1])
        XCTAssertEqual(second.elements, [10: "root"])
    }

    func testNoBudgetOrCandidateAllowanceDoesNotCallResolver() {
        for maximumCandidates in [0, 8] {
            var cursor = WindowAXRecoveryScanCursor()
            let result = cursor.scan(targets: [10], maximumCandidates: maximumCandidates, shouldContinue: { maximumCandidates == 0 }) { _, _ -> WindowAXRecoveryLookup<String> in
                XCTFail("A cancelled or exhausted scan must not issue another lookup")
                return .definiteMiss
            }
            XCTAssertEqual(result.attempts, 0)
            XCTAssertEqual(cursor.nextElementID, 0)
        }
    }

    func testKnownRootTransientFailureRetainsHintAndStopsWithoutScanningMore() {
        var cursor = WindowAXRecoveryScanCursor()
        _ = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            id == 2 ? .found(windowID: 10, element: "root") : .definiteMiss
        }
        var visited: [UInt64] = []
        let unavailable = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return .inconclusive
        }
        XCTAssertTrue(unavailable.elements.isEmpty)
        XCTAssertEqual(unavailable.attempts, 1)
        XCTAssertEqual(visited, [2])
        XCTAssertEqual(cursor.knownElementIDs, [10: 2])
        XCTAssertEqual(cursor.nextElementID, 3)
        let recovered = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return .found(windowID: 10, element: "new proxy")
        }
        XCTAssertEqual(visited, [2, 2])
        XCTAssertEqual(recovered.elements, [10: "new proxy"])
    }

    func testKnownRootDefiniteFailureFindsReplacementAndUpdatesHint() {
        var cursor = WindowAXRecoveryScanCursor()
        _ = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            id == 2 ? .found(windowID: 10, element: "old") : .definiteMiss
        }
        var visited: [UInt64] = []
        let result = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return id == 3 ? .found(windowID: 10, element: "replacement") : .definiteMiss
        }
        XCTAssertEqual(visited, [2, 3])
        XCTAssertEqual(result.elements, [10: "replacement"])
        XCTAssertEqual(cursor.knownElementIDs, [10: 3])
    }

    func testNewTargetRestartsNamespaceInsteadOfSkippingItsEarlierRoot() {
        var cursor = WindowAXRecoveryScanCursor()
        _ = cursor.scan(targets: [10], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            id == 4 ? .found(windowID: 10, element: "later root") : .definiteMiss
        }
        var visited: [UInt64] = []
        let result = cursor.scan(targets: [20], maximumCandidates: 8, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return id == 1 ? .found(windowID: 20, element: "earlier root") : .definiteMiss
        }
        XCTAssertEqual(visited, [0, 1])
        XCTAssertEqual(result.elements, [20: "earlier root"])
        XCTAssertEqual(cursor.knownElementIDs, [10: 4, 20: 1])
    }

    func testRemovingTargetsDoesNotLoseNamespaceProgress() {
        var cursor = WindowAXRecoveryScanCursor()
        _ = cursor.scan(targets: [10, 20], maximumCandidates: 3, shouldContinue: { true }) { _, _ -> WindowAXRecoveryLookup<String> in .definiteMiss }
        var visited: [UInt64] = []
        _ = cursor.scan(targets: [20], maximumCandidates: 1, shouldContinue: { true }) { id, _ -> WindowAXRecoveryLookup<String> in
            visited.append(id)
            return .definiteMiss
        }
        XCTAssertEqual(visited, [3])
        XCTAssertEqual(cursor.nextElementID, 4)
    }

    func testFoundRootIsRemovedFromPendingAndUnrequestedResultsAreIgnored() {
        var cursor = WindowAXRecoveryScanCursor()
        var pendingSets: [Set<CGWindowID>] = []
        let result = cursor.scan(targets: [10, 20], maximumCandidates: 3, shouldContinue: { true }) { id, pending -> WindowAXRecoveryLookup<String> in
            pendingSets.append(pending)
            switch id {
            case 0: return .found(windowID: 10, element: "first")
            case 1: return .found(windowID: 99, element: "wrong")
            default: return .found(windowID: 20, element: "second")
            }
        }
        XCTAssertEqual(pendingSets, [[10, 20], [20], [20]])
        XCTAssertEqual(result.elements, [10: "first", 20: "second"])
        XCTAssertNil(cursor.knownElementIDs[99])
    }

    private func accepts(
        requestedPID: pid_t = 42,
        actualPID: pid_t = 42,
        actualWindowID: CGWindowID = 10,
        roleResult: AXError = .success,
        role: String? = kAXWindowRole as String,
        isOrderedIn: Bool? = true,
        processIsCurrent: Bool = true
    ) -> Bool {
        WindowAXExactRecoveryPolicy.accepts(
            requestedPID: requestedPID, actualPID: actualPID,
            requestedWindowIDs: [10], actualWindowID: actualWindowID,
            roleResult: roleResult, role: role, isOrderedIn: isOrderedIn,
            processIsCurrent: processIsCurrent
        )
    }
}
