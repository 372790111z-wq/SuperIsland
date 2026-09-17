import ApplicationServices
import XCTest
@testable import SuperIsland

@MainActor
final class WindowMinimizationSessionControllerTests: XCTestCase {
    private typealias Controller = WindowMinimizationSessionController

    func testAcceptedMinimizeWithStaleFalseReadbackStillRestoresTheOwnedWindow() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        fixture.onWrite = { window, value in
            if !value { window.minimized = false }
            return .success
        }
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertTrue(controller.hasActiveSession)
        window.minimized = true // The target app finishes its animation later.
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false)])
        XCTAssertEqual(fixture.raised, [1])
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testAcceptedMinimizeWithUnknownReadbackRetainsOwnershipAcrossRetry() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        fixture.onWrite = { window, value in
            window.minimized = value ? nil : false
            return .success
        }
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, failed: 1)
        XCTAssertTrue(controller.hasActiveSession)
        XCTAssertEqual(fixture.writes, [.init(1, true)])

        window.minimized = true
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false)])
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testSecondPressBeforeMinimizeAnimationEndsIssuesCompensatingRestore() {
        let fixture = Fixture()
        fixture.addWindow(1)
        fixture.onWrite = { _, _ in .success } // Reads stay false during the animation.
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false)])
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testSettledDelayedRestoreAllowsNextPressToStartANewBatch() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        fixture.onWrite = { window, value in
            if value { window.minimized = true }
            return .success
        }
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertTrue(controller.hasActiveSession)
        window.minimized = false
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false), .init(1, true)])
        XCTAssertTrue(controller.hasActiveSession)
    }

    func testUnknownRestoreReadbackNeverClearsOrRewritesThePendingRequest() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        fixture.onWrite = { window, value in
            window.minimized = value ? true : nil
            return .success
        }
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false)])
        XCTAssertTrue(controller.hasActiveSession)

        window.minimized = false
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertEqual(fixture.writes.last, .init(1, true))
    }

    func testInitiallyMinimizedAndUnknownWindowsAreNotAdopted() {
        let fixture = Fixture()
        let alreadyMinimized = fixture.addWindow(1, minimized: true)
        let unknown = fixture.addWindow(2, minimized: nil)
        fixture.addWindow(3)
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1, failed: 1)
        unknown.minimized = true
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(3, true), .init(3, false)])
        XCTAssertEqual(alreadyMinimized.minimized, true)
        XCTAssertEqual(unknown.minimized, true)
    }

    func testRejectedMinimizeIsExcludedFromTheBatchEvenIfItLaterMinimizes() {
        let fixture = Fixture()
        fixture.addWindow(1)
        let rejected = fixture.addWindow(2)
        fixture.onWrite = { window, value in
            if window.id == 2 { return .cannotComplete }
            window.minimized = value
            return .success
        }
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1, failed: 1)
        rejected.minimized = true // A separate user/app action is not owned.
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(2, true), .init(1, false)])
        XCTAssertEqual(rejected.minimized, true)
    }

    func testUnknownBeforeRestorePreservesConfirmedMinimizeWithoutMutation() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        window.minimized = nil
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, failed: 1)
        XCTAssertTrue(controller.hasActiveSession)
        XCTAssertEqual(fixture.writes, [.init(1, true)])

        window.minimized = true
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testFailedRestoreRemainsOwnedAndRetriesInsteadOfStartingAnotherBatch() {
        let fixture = Fixture()
        fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        fixture.onWrite = { _, _ in .cannotComplete }
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, failed: 1)
        XCTAssertTrue(controller.hasActiveSession)
        XCTAssertTrue(fixture.activated.isEmpty)

        fixture.onWrite = nil
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false), .init(1, false)])
        XCTAssertEqual(fixture.activated, [101])
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testTerminatedPendingRestoreDoesNotAdoptNewApplicationsOnNextPress() {
        let fixture = Fixture()
        fixture.addWindow(1, pid: 101)
        fixture.onWrite = { window, value in
            if value { window.minimized = true }
            return .success
        }
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)

        fixture.runningPIDs.remove(101)
        let newWindow = fixture.addWindow(2, pid: 202)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, missing: 1)
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false)])
        XCTAssertEqual(newWindow.minimized, false)
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testRestoreActiveSessionClearsSettledRequestWithoutStartingANewBatch() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        fixture.onWrite = { window, value in
            if value { window.minimized = true }
            return .success
        }
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, pending: 1)
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, pending: 1)
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, pending: 1)
        XCTAssertEqual(fixture.activated, [101])
        window.minimized = false
        assertRestored(controller.restoreActiveSession()!, confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false), .init(1, false), .init(1, false)])
        XCTAssertEqual(fixture.activated, [101])
        XCTAssertFalse(controller.hasActiveSession)
        XCTAssertNil(controller.restoreActiveSession())
    }

    func testOtherModeKeepsFocusedExcludedAndOwnWindowsOutsideItsBatch() {
        let fixture = Fixture()
        let focused = fixture.addWindow(1)
        fixture.focused = focused.element
        fixture.addWindow(2, pid: 202)
        fixture.addWindow(3)
        fixture.addWindow(4, pid: 999)
        let controller = fixture.controller()

        assertMinimized(controller.toggle(mode: .others, excludingBundleIdentifiers: ["test.202"]), confirmed: 1, mode: .others)
        // Either toggle restores the existing batch rather than replacing it.
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1, mode: .others)
        XCTAssertEqual(fixture.writes, [.init(3, true), .init(3, false)])
    }

    private func assertMinimized(
        _ outcome: Controller.Outcome, confirmed: Int, pending: Int = 0, failed: Int = 0,
        mode: Controller.Mode = .all, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .minimized(actualMode, succeeded, actualPending, actualFailed) = outcome else {
            return XCTFail("Expected minimized outcome, got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(actualMode, mode, file: file, line: line)
        XCTAssertEqual(succeeded, confirmed, file: file, line: line)
        XCTAssertEqual(actualPending, pending, file: file, line: line)
        XCTAssertEqual(actualFailed, failed, file: file, line: line)
    }

    private func assertRestored(
        _ outcome: Controller.Outcome, confirmed: Int, pending: Int = 0,
        failed: Int = 0, missing: Int = 0, mode: Controller.Mode = .all,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .restored(actualMode, succeeded, actualPending, actualFailed, actualMissing) = outcome else {
            return XCTFail("Expected restored outcome, got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(actualMode, mode, file: file, line: line)
        XCTAssertEqual(succeeded, confirmed, file: file, line: line)
        XCTAssertEqual(actualPending, pending, file: file, line: line)
        XCTAssertEqual(actualFailed, failed, file: file, line: line)
        XCTAssertEqual(actualMissing, missing, file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        struct Write: Equatable {
            let id: Int
            let minimized: Bool
            init(_ id: Int, _ minimized: Bool) { self.id = id; self.minimized = minimized }
        }

        final class Window {
            let id: Int
            let pid: pid_t
            let element: AXUIElement
            var minimized: Bool?

            init(id: Int, pid: pid_t, minimized: Bool?) {
                self.id = id
                self.pid = pid
                self.minimized = minimized
                // Opaque test tokens only. Every AX read/write is replaced by
                // the environment below; no request is sent to these PIDs.
                element = AXUIElementCreateApplication(pid_t(1_000_000 + id))
            }
        }

        var windows: [Window] = []
        var runningPIDs: Set<pid_t> = []
        var writes: [Write] = []
        var raised: [Int] = []
        var activated: [pid_t] = []
        var focused: AXUIElement?
        var onWrite: ((Window, Bool) -> AXError)?

        @discardableResult
        func addWindow(_ id: Int, pid: pid_t = 101, minimized: Bool? = false) -> Window {
            let window = Window(id: id, pid: pid, minimized: minimized)
            windows.append(window)
            runningPIDs.insert(pid)
            return window
        }

        private func window(_ element: AXUIElement) -> Window {
            windows.first { CFEqual($0.element, element) }!
        }

        func controller() -> Controller {
            Controller(environment: .init(
                ownProcessIdentifier: 999,
                applications: {
                    self.runningPIDs.sorted().map {
                        .init(processIdentifier: $0, bundleIdentifier: "test.\($0)")
                    }
                },
                frontmostProcessIdentifier: { 101 },
                isApplicationRunning: { self.runningPIDs.contains($0) },
                activateApplication: { self.activated.append($0) },
                windowOrder: { Dictionary(uniqueKeysWithValues: self.windows.enumerated().map { ($1.id, $0) }) },
                focusedWindow: { self.focused },
                windows: { pid in (true, self.windows.filter { $0.pid == pid }.map(\.element)) },
                processIdentifier: { self.window($0).pid },
                isOrdinaryWindow: { _ in true },
                windowNumber: { self.window($0).id },
                identifier: { "test.window.\(self.window($0).id)" },
                minimized: { self.window($0).minimized },
                canMinimize: { _ in true },
                setMinimized: { element, value in
                    let window = self.window(element)
                    self.writes.append(.init(window.id, value))
                    if let onWrite = self.onWrite { return onWrite(window, value) }
                    window.minimized = value
                    return .success
                },
                raiseWindow: { self.raised.append(self.window($0).id) },
                now: { Date(timeIntervalSince1970: 100) }
            ))
        }
    }
}
