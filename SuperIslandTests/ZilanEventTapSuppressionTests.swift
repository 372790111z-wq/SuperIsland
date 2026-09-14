import CoreGraphics
import Foundation
import XCTest
@testable import SuperIsland

final class ZilanEventTapSuppressionTests: XCTestCase {
    func testCaptureAndLeaseAreMutuallyExclusiveUntilPairedEnd() {
        let state = ZilanEventTapInteractionState()
        XCTAssertTrue(state.beginCapture())
        XCTAssertFalse(state.beginSuppression(requestID: "lease"))
        XCTAssertTrue(state.isCapturing)
        state.endCapture()
        XCTAssertTrue(state.beginSuppression(requestID: "lease"))
        XCTAssertFalse(state.beginCapture())
        state.endSuppression(requestID: "unrelated")
        XCTAssertFalse(state.beginCapture())
        state.endSuppression(requestID: "lease")
        XCTAssertTrue(state.beginCapture())
    }

    func testStaleReleaseCannotUnsuppressReplacementLease() {
        let state = ZilanEventTapInteractionState()
        XCTAssertTrue(state.beginSuppression(requestID: "first"))
        state.endSuppression(requestID: "first")
        XCTAssertTrue(state.beginSuppression(requestID: "second"))
        state.endSuppression(requestID: "first")
        XCTAssertFalse(state.beginCapture())
        state.endSuppression(requestID: "second")
        XCTAssertTrue(state.beginCapture())
    }

    func testConcurrentCaptureAndAcquisitionCannotBothSucceed() async {
        for _ in 0..<100 {
            let state = ZilanEventTapInteractionState()
            async let capture = Task.detached { state.beginCapture() }.value
            async let lease = Task.detached { state.beginSuppression(requestID: "lease") }.value
            let winners = await [capture, lease].filter { $0 }.count
            XCTAssertEqual(winners, 1)
        }
    }

    func testMissionControlRetainsExistingCapturedGestureWhenLeaseIsRefused() {
        let state = MissionControlCloseInteractionState()
        state.updateVisibleRegion(CGRect(x: 10, y: 40, width: 30, height: 30))
        XCTAssertEqual(state.decision(for: .leftMouseDown, location: CGPoint(x: 20, y: 50)), .consumeAndTrigger)
        state.updateVisibleRegion(nil)
        XCTAssertFalse(state.beginZilanSuppression(requestID: "lease"))
        XCTAssertEqual(state.decision(for: .leftMouseDragged, location: CGPoint(x: 1207, y: 16)), .consume)
        XCTAssertEqual(state.decision(for: .leftMouseUp, location: CGPoint(x: 1207, y: 16)), .consume)
        XCTAssertTrue(state.beginZilanSuppression(requestID: "lease"))
    }

    func testMissionControlLeasePassesEveryPointerEventAndCannotStartCapture() {
        let state = MissionControlCloseInteractionState()
        let inside = CGPoint(x: 20, y: 50)
        state.updateVisibleRegion(CGRect(x: 10, y: 40, width: 30, height: 30))
        XCTAssertTrue(state.beginZilanSuppression(requestID: "lease"))
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved] {
            XCTAssertEqual(state.decision(for: type, location: inside), .suppressedPassThrough)
        }
        state.endZilanSuppression(requestID: "stale")
        XCTAssertEqual(state.decision(for: .leftMouseDown, location: inside), .suppressedPassThrough)
        state.endZilanSuppression(requestID: "lease")
        XCTAssertEqual(state.decision(for: .leftMouseDown, location: inside), .consumeAndTrigger)
        XCTAssertEqual(state.decision(for: .leftMouseUp, location: inside), .consume)
    }

    func testMissionControlTapResetDoesNotEndAnUnrelatedLease() {
        let state = MissionControlCloseInteractionState()
        XCTAssertTrue(state.beginZilanSuppression(requestID: "lease"))
        state.reset()
        XCTAssertEqual(state.decision(for: .leftMouseDragged, location: .zero), .suppressedPassThrough)
        state.endZilanSuppression(requestID: "lease")
        XCTAssertEqual(state.decision(for: .leftMouseDragged, location: .zero), .passThrough)
    }

    @MainActor
    func testSecondTapRefusalRollsBackFirstAndPreservesCapturedGesture() {
        let missionControl = MissionControlCloseInteractionState()
        let pointer = ZilanEventTapInteractionState()
        let commandTab = WindowCommandTabMonitor(zilanPointerInteraction: pointer)
        XCTAssertTrue(pointer.beginCapture())
        let accepted = ZilanSuppressionAcquisition.acquire([
            .init(acquire: { missionControl.beginZilanSuppression(requestID: "lease") },
                  rollback: { missionControl.endZilanSuppression(requestID: "lease") }),
            .init(acquire: { commandTab.beginZilanSuppression(requestID: "lease") },
                  rollback: { commandTab.endZilanSuppression(requestID: "lease") }),
        ])
        XCTAssertFalse(accepted)
        XCTAssertTrue(pointer.isCapturing)
        XCTAssertEqual(missionControl.decision(for: .leftMouseDragged, location: .zero), .passThrough)
        pointer.endCapture()
        XCTAssertTrue(commandTab.beginZilanSuppression(requestID: "next"))
        commandTab.endZilanSuppression(requestID: "next")
    }

    @MainActor
    func testPanelRefusalRollsBackBothTapsAndAppStateBeforeReturning() {
        let appState = AppState(synchronizesRuntimeEnergyState: false)
        let missionControl = MissionControlCloseInteractionState()
        let pointer = ZilanEventTapInteractionState()
        let commandTab = WindowCommandTabMonitor(zilanPointerInteraction: pointer)
        let lease = ZilanSuppressionLease(requestID: "lease", targetIdentityHash: "test",
            expiresAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_900_000_000)
        let accepted = ZilanSuppressionAcquisition.acquire([
            .init(acquire: { appState.beginZilanSuppression(lease) },
                  rollback: { appState.endZilanSuppression(requestID: lease.requestID) }),
            .init(acquire: {
                ZilanSuppressionAcquisition.acquire([
                    .init(acquire: { missionControl.beginZilanSuppression(requestID: lease.requestID) },
                          rollback: { missionControl.endZilanSuppression(requestID: lease.requestID) }),
                    .init(acquire: { commandTab.beginZilanSuppression(requestID: lease.requestID) },
                          rollback: { commandTab.endZilanSuppression(requestID: lease.requestID) }),
                ])
            }, rollback: {
                commandTab.endZilanSuppression(requestID: lease.requestID)
                missionControl.endZilanSuppression(requestID: lease.requestID)
            }),
            .init(acquire: { false }, rollback: { XCTFail("unacquired panel must not be released") }),
        ])
        XCTAssertFalse(accepted)
        XCTAssertFalse(appState.isZilanInteractionSuppressed)
        XCTAssertEqual(missionControl.decision(for: .leftMouseDragged, location: .zero), .passThrough)
        XCTAssertTrue(pointer.beginCapture())
        pointer.endCapture()
    }

    @MainActor
    func testCommandTabUsesTheSameCaptureStateAsItsLeaseBoundary() {
        let state = ZilanEventTapInteractionState()
        let monitor = WindowCommandTabMonitor(zilanPointerInteraction: state)
        XCTAssertTrue(state.beginCapture())
        XCTAssertFalse(monitor.beginZilanSuppression(requestID: "lease"))
        XCTAssertTrue(state.isCapturing)
        state.endCapture()
        XCTAssertTrue(monitor.beginZilanSuppression(requestID: "lease"))
        XCTAssertFalse(state.beginCapture())
        monitor.endZilanSuppression(requestID: "stale")
        XCTAssertFalse(state.beginCapture())
        monitor.endZilanSuppression(requestID: "lease")
        XCTAssertTrue(state.beginCapture())
        state.endCapture()
    }
}
