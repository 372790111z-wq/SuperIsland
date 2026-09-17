import XCTest
@testable import SuperIsland

final class FinderShortcutPressGateTests: XCTestCase {
    private let finder = FinderShortcutPressGate.Context(pid: 123, keyCode: 2, modifiers: 512)

    func testHeldKeyDoesNotDeleteNextSelection() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        XCTAssertTrue(gate.press(generation: gate.generation))
        for _ in 0..<50 { XCTAssertFalse(gate.press(generation: gate.generation)) }
        gate.observeRelease(keyIsDown: false)
        XCTAssertTrue(gate.press(generation: gate.generation))
    }

    func testModifierReleaseWhileBaseKeyHeldDoesNotRearm() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        XCTAssertTrue(gate.press(generation: gate.generation))
        gate.observeRelease(keyIsDown: true)
        XCTAssertFalse(gate.press(generation: gate.generation))
    }

    func testReturningToFinderWithKeyHeldWaitsForRelease() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: true)
        XCTAssertFalse(gate.press(generation: gate.generation))
        gate.observeRelease(keyIsDown: false)
        XCTAssertTrue(gate.press(generation: gate.generation))
    }

    func testOldQueuedPressCannotOperateOnNewActivation() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        let previous = gate.generation
        gate.invalidate()
        gate.configure(finder, keyIsDown: false)
        XCTAssertFalse(gate.isCurrent(previous))
        XCTAssertFalse(gate.press(generation: previous))
        XCTAssertTrue(gate.press(generation: gate.generation))
    }

    func testShortcutChangeInvalidatesPreviousChord() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        let previous = gate.generation
        gate.configure(.init(pid: finder.pid, keyCode: 3, modifiers: 512), keyIsDown: true)
        XCTAssertFalse(gate.press(generation: previous))
        XCTAssertFalse(gate.press(generation: gate.generation))
        gate.observeRelease(keyIsDown: false)
        XCTAssertTrue(gate.press(generation: gate.generation))
    }

    func testUnrelatedPreferenceRefreshDoesNotResetHeldKey() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        XCTAssertTrue(gate.press(generation: gate.generation))
        let current = gate.generation
        gate.configure(finder, keyIsDown: false)
        XCTAssertEqual(current, gate.generation)
        XCTAssertFalse(gate.press(generation: current))
    }

    func testDisabledContextCannotExecute() {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        let previous = gate.generation
        gate.configure(nil, keyIsDown: false)
        XCTAssertFalse(gate.press(generation: previous))
        XCTAssertFalse(gate.press(generation: gate.generation))
    }

    func testVisibilityToggleNeedsNewPressCycle() {
        var gate = WindowVisibilityPressGate()
        XCTAssertTrue(gate.press(1))
        XCTAssertFalse(gate.press(1))
        XCTAssertTrue(gate.press(2))
        gate.release(1)
        XCTAssertTrue(gate.press(1))
        XCTAssertFalse(gate.press(2))
        gate.reset()
        XCTAssertTrue(gate.press(2))
    }

    func testQueuedRepeatsAreCoalescedBeforeMainActorDelivery() {
        var queue = FinderShortcutQueuedPressGate()
        let first = queue.enqueuePress()!
        XCTAssertNil(queue.enqueuePress())
        XCTAssertTrue(queue.isCurrent(first))
        queue.release()
        XCTAssertFalse(queue.isCurrent(first))
    }

    func testOldQueuedPressCannotBorrowANewPhysicalPress() {
        var queue = FinderShortcutQueuedPressGate()
        let old = queue.enqueuePress()!
        queue.release()
        let next = queue.enqueuePress()!
        XCTAssertFalse(queue.isCurrent(old))
        XCTAssertTrue(queue.isCurrent(next))
    }

    func testClaimedQuickPressSurvivesPhysicalReleaseWithinOriginalDeadline() throws {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        let generation = gate.generation
        let lifetime = try XCTUnwrap(FinderShortcutEventLifetime(eventTime: 10, now: 10.05))
        XCTAssertTrue(gate.press(generation: generation))
        gate.observeRelease(keyIsDown: false)
        XCTAssertTrue(gate.isCurrent(generation))
        XCTAssertTrue(lifetime.isCurrent(now: 10.15))
        XCTAssertFalse(lifetime.isCurrent(now: 10.25))
    }

    func testQueuedPressMustBeClaimedWithinShortEventAge() {
        XCTAssertNotNil(FinderShortcutEventLifetime(eventTime: 0, now: 0.100))
        XCTAssertNil(FinderShortcutEventLifetime(eventTime: 0, now: 0.101))
        XCTAssertNil(FinderShortcutEventLifetime(eventTime: 10, now: 11))
    }

    func testLateClaimDoesNotRestartTheOperationDeadline() throws {
        let lifetime = try XCTUnwrap(FinderShortcutEventLifetime(eventTime: 0, now: 0.09))
        XCTAssertTrue(lifetime.isCurrent(now: 0.249))
        XCTAssertFalse(lifetime.isCurrent(now: 0.250))
        XCTAssertFalse(lifetime.isCurrent(now: 0.30))
    }

    func testInvalidOrFutureEventTimesCannotAuthorizeAnAction() throws {
        XCTAssertNil(FinderShortcutEventLifetime(eventTime: 10.01, now: 10))
        XCTAssertNil(FinderShortcutEventLifetime(eventTime: -1, now: 0))
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(FinderShortcutEventLifetime(eventTime: value, now: 0))
            XCTAssertNil(FinderShortcutEventLifetime(eventTime: 0, now: value))
        }
        let lifetime = try XCTUnwrap(FinderShortcutEventLifetime(eventTime: 10, now: 10))
        XCTAssertFalse(lifetime.isCurrent(now: 9.99))
        XCTAssertFalse(lifetime.isCurrent(now: .nan))
        XCTAssertFalse(lifetime.isCurrent(now: .infinity))
    }

    func testReleasedQueuedTicketCannotBorrowFreshNextCycleOrDeadline() throws {
        var queue = FinderShortcutQueuedPressGate()
        let old = try XCTUnwrap(queue.enqueuePress())
        queue.release()
        let next = try XCTUnwrap(queue.enqueuePress())
        XCTAssertFalse(queue.isCurrent(old))
        XCTAssertTrue(queue.isCurrent(next))
        XCTAssertNil(FinderShortcutEventLifetime(eventTime: 10, now: 10.2))
        XCTAssertNotNil(FinderShortcutEventLifetime(eventTime: 10.18, now: 10.2))
    }

    func testClaimedPressStillRequiresCurrentFinderActivation() throws {
        var gate = FinderShortcutPressGate()
        gate.configure(finder, keyIsDown: false)
        let generation = gate.generation
        let lifetime = try XCTUnwrap(FinderShortcutEventLifetime(eventTime: 0, now: 0.01))
        XCTAssertTrue(gate.press(generation: generation))
        gate.invalidate()
        gate.configure(finder, keyIsDown: false)
        XCTAssertTrue(lifetime.isCurrent(now: 0.02))
        XCTAssertFalse(gate.isCurrent(generation))
    }
}
