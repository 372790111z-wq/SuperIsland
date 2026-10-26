import XCTest
@testable import SuperIsland

@MainActor
final class ChromeFullScreenMenuGateTests: XCTestCase {
    func testTemporaryMenuUnavailabilityWaitsAndDispatchesOnce() async {
        var time: TimeInterval = 0
        var sends = 0
        let result = await ChromeFullScreenMenuGate.request(isCurrent: { true }, attempt: {
            if time < 0.32 { return .waiting }
            sends += 1
            return .sent
        }, now: { time }, pause: { time += 0.08; return true })
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(sends, 1)
        XCTAssertGreaterThanOrEqual(time, 0.32)
    }

    func testAmbiguousAXDispatchNeverRetriesToggle() async {
        var attempts = 0
        let result = await ChromeFullScreenMenuGate.request(isCurrent: { true }, attempt: {
            attempts += 1; return .uncertain
        }, pause: { XCTFail("Must observe result, not retry dispatch"); return false })
        XCTAssertEqual(result, .uncertain)
        XCTAssertEqual(attempts, 1)
    }

    func testLateStateChangeWhileWaitingDoesNotSendToggle() async {
        var time: TimeInterval = 0
        let result = await ChromeFullScreenMenuGate.request(isCurrent: { true }, attempt: {
            time < 0.24 ? .waiting : .alreadySatisfied
        }, now: { time }, pause: { time += 0.08; return true })
        XCTAssertEqual(result, .alreadySatisfied)
    }

    func testFocusChangeOrTerminatedTargetStopsImmediately() async {
        for state in [ChromeFullScreenMenuGate.Outcome.targetChanged, .targetGone] {
            let result = await ChromeFullScreenMenuGate.request(isCurrent: { true }, attempt: { state },
                pause: { XCTFail("Do not reactivate or retry another target"); return false })
            XCTAssertEqual(result, state)
        }
    }

    func testPersistentUnavailableMenuHasBoundedWait() async {
        var time: TimeInterval = 0
        let result = await ChromeFullScreenMenuGate.request(isCurrent: { true }, attempt: { .waiting },
            now: { time }, pause: { time += 0.08; return true })
        XCTAssertEqual(result, .timedOut)
        XCTAssertGreaterThanOrEqual(time, 4)
        XCTAssertLessThan(time, 4.09)
    }

    func testGenerationChangeDuringWaitPreventsDispatch() async {
        var current = true
        var attempts = 0
        let result = await ChromeFullScreenMenuGate.request(isCurrent: { current }, attempt: {
            attempts += 1; return .waiting
        }, pause: { current = false; return true })
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(attempts, 1)
    }

    func testCancelledPauseDoesNotDispatch() async {
        let result = await ChromeFullScreenMenuGate.request(isCurrent: { true }, attempt: { .waiting }, pause: { false })
        XCTAssertEqual(result, .interrupted)
    }

    func testReleaseDiagnosticsAreLimitedToLocalIdentityAndFullScreenStages() {
        for component in ["fullScreenDisplayMove", "chromeFullScreenRequest"] {
            XCTAssertTrue(WindowInteractionDiagnosticAdmission.allows(bundleIdentifier: "com.workview.SuperIsland.WE1Debug", component: component, debugBuild: false))
            XCTAssertFalse(WindowInteractionDiagnosticAdmission.allows(bundleIdentifier: "com.workview.SuperIsland", component: component, debugBuild: false))
        }
        XCTAssertFalse(WindowInteractionDiagnosticAdmission.allows(bundleIdentifier: "com.workview.SuperIsland.WE1Debug", component: "dock", debugBuild: false))
        XCTAssertTrue(WindowInteractionDiagnosticAdmission.allows(bundleIdentifier: "com.workview.SuperIsland.WE1Debug", component: "dock", debugBuild: true))
    }
}
