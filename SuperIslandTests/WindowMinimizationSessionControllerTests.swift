import ApplicationServices
import XCTest
@testable import SuperIsland

@MainActor
final class WindowMinimizationSessionControllerTests: XCTestCase {
    private typealias Controller = WindowMinimizationSessionController

    func testDesktopFocusRestoresFrontmostBatchApplicationInsteadOfFinder() {
        let fixture = Fixture()
        fixture.frontmostPID = 303 // Finder owns the desktop, with no focused ordinary window.
        fixture.addWindow(1, pid: 101)
        fixture.addWindow(2, pid: 202)
        fixture.addWindow(3, pid: 303) // A background Finder window is also in the batch.
        let controller = fixture.controller()
        for _ in 0..<3 {
            assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 3)
            assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 3)
        }
        XCTAssertEqual(fixture.activated, [101, 101, 101])
        XCTAssertEqual(fixture.raised, [3, 2, 1, 3, 2, 1, 3, 2, 1])
    }

    func testDesktopFallbackSkipsFailedRestoresAndInitiallyMinimizedWindows() {
        let fixture = Fixture()
        fixture.frontmostPID = 303
        fixture.runningPIDs.insert(303)
        fixture.addWindow(0, pid: 404, minimized: true)
        fixture.addWindow(1, pid: 101)
        fixture.addWindow(2, pid: 202)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 2)
        fixture.onWrite = { window, value in
            guard window.id != 1 else { return .cannotComplete }
            window.minimized = value
            return .success
        }
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1, failed: 1)
        XCTAssertEqual(fixture.activated, [202])
        XCTAssertTrue(controller.hasActiveSession)
        XCTAssertFalse(fixture.writes.contains(.init(0, false)))
    }

    func testDesktopFallbackActivatesAcceptedAsynchronousRestore() {
        let fixture = Fixture()
        fixture.frontmostPID = 303
        fixture.runningPIDs.insert(303)
        fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        fixture.onWrite = { _, _ in .success }
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertEqual(fixture.activated, [101])
    }

    func testOrdinaryFocusedFinderWindowKeepsFinderActivation() {
        let fixture = Fixture()
        fixture.frontmostPID = 303
        fixture.addWindow(1)
        fixture.focused = fixture.addWindow(2, pid: 303).element
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 2)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 2)
        XCTAssertEqual(fixture.activated, [303])
    }

    func testOtherModeKeepsFocusedApplicationEvenWhenNotInBatch() {
        let fixture = Fixture()
        fixture.frontmostPID = 303
        fixture.focused = fixture.addWindow(1, pid: 303).element
        fixture.addWindow(2)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .others, excludingBundleIdentifiers: []), confirmed: 1, mode: .others)
        assertRestored(controller.toggle(mode: .others, excludingBundleIdentifiers: []), confirmed: 1, mode: .others)
        XCTAssertEqual(fixture.activated, [303])
    }

    func testOtherModeFailedRestoreDoesNotActivateFocusedApplication() {
        let fixture = Fixture()
        fixture.frontmostPID = 303
        fixture.focused = fixture.addWindow(1, pid: 303).element
        fixture.addWindow(2)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .others, excludingBundleIdentifiers: []), confirmed: 1, mode: .others)
        fixture.onWrite = { _, _ in .cannotComplete }
        assertRestored(controller.toggle(mode: .others, excludingBundleIdentifiers: []), confirmed: 0, failed: 1, mode: .others)
        XCTAssertTrue(fixture.activated.isEmpty)
    }

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

    func testManuallyRestoredBatchAllowsNextPressToMinimizeAgain() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        let alreadyMinimized = fixture.addWindow(2, minimized: true)
        let controller = fixture.controller()

        for _ in 0..<3 {
            assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
            window.minimized = false // Restored through Dock or a window preview.
        }

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, true), .init(1, true)])
        XCTAssertEqual(alreadyMinimized.minimized, true)
        assertRestored(controller.restoreActiveSession()!, confirmed: 1)
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testPartiallyManuallyRestoredBatchOnlyRestoresRemainingMembers() {
        let fixture = Fixture()
        let manuallyRestored = fixture.addWindow(1)
        let remaining = fixture.addWindow(2)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 2)
        manuallyRestored.minimized = false
        let newWindow = fixture.addWindow(3)

        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(2, true), .init(2, false)])
        XCTAssertEqual(manuallyRestored.minimized, false)
        XCTAssertEqual(remaining.minimized, false)
        XCTAssertEqual(newWindow.minimized, false)
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testRecreatedAXProxyWithSameNativeWindowIDCanStartNextBatch() {
        let fixture = Fixture()
        let original = fixture.addWindow(1)
        original.identifier = nil // Codex does not expose AXIdentifier.
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        original.isLive = false
        let replacement = fixture.addWindow(2)
        replacement.windowNumber = original.windowNumber
        replacement.identifier = nil
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true), .init(2, true)])
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertEqual(fixture.writes.last, .init(2, false))
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testMissingOldWindowNeverAdoptsNewWindowWhileRetiringBatch() {
        let fixture = Fixture()
        let original = fixture.addWindow(1)
        original.identifier = nil
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        original.isLive = false
        let newWindow = fixture.addWindow(2)

        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, failed: 1)
        fixture.date.addTimeInterval(0.25)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, failed: 1)
        fixture.date.addTimeInterval(0.25)
        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, missing: 1)

        XCTAssertEqual(fixture.writes, [.init(1, true)])
        XCTAssertEqual(newWindow.minimized, false)
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testObservedDelayedMinimizeThenDockRestoreAllowsNewBatch() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        fixture.onWrite = { _, _ in .success }
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertNotNil(fixture.minimizationObservation)

        fixture.minimizationObservation?() // Initial false readback is inconclusive.
        XCTAssertTrue(controller.hasActiveSession)
        XCTAssertNotNil(fixture.minimizationObservation)
        window.minimized = true // Codex finishes its asynchronous animation.
        fixture.minimizationObservation?()
        XCTAssertNil(fixture.minimizationObservation)
        window.minimized = false // User restores through Dock.
        fixture.onWrite = nil

        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, true)])
        XCTAssertNil(fixture.minimizationObservation)
    }

    func testPendingObservationStopsOnCompensatingRestoreAndReset() {
        let fixture = Fixture()
        fixture.addWindow(1)
        fixture.onWrite = { _, _ in .success }
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertNotNil(fixture.minimizationObservation)

        assertRestored(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        XCTAssertNil(fixture.minimizationObservation)
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 0, pending: 1)
        XCTAssertNotNil(fixture.minimizationObservation)
        controller.resetWithoutRestoring()
        XCTAssertNil(fixture.minimizationObservation)
        XCTAssertFalse(controller.hasActiveSession)
    }

    func testDiagnosticSnapshotUsesStoredStateWithoutEnvironmentCalls() {
        let fixture = Fixture()
        fixture.addWindow(1)
        let anonymous = fixture.addWindow(2)
        anonymous.windowNumber = nil
        anonymous.identifier = nil
        fixture.onWrite = { window, value in
            if window.id == 1 { window.minimized = value }
            return .success
        }
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1, pending: 1)
        let callsBeforeSnapshot = fixture.environmentCalls

        for _ in 0..<3 {
            XCTAssertEqual(controller.diagnosticSnapshot, .init(
                retainedCount: 2, minimizeRequestedCount: 1, minimizedCount: 1,
                restoreRequestedCount: 0, unidentifiedCount: 1, missingObservationCount: 0
            ))
            XCTAssertEqual(controller.lastRestoreDiagnostics, .init())
        }

        XCTAssertEqual(fixture.environmentCalls, callsBeforeSnapshot)
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(2, true)])
        XCTAssertTrue(fixture.raised.isEmpty)
        XCTAssertTrue(fixture.activated.isEmpty)
    }

    func testRestoreDiagnosticsDistinguishAnonymousUnavailableWithoutRetiringIt() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        window.windowNumber = nil
        window.identifier = nil
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        window.ordinary = false
        window.inSnapshot = false

        for _ in 0..<2 {
            assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
            XCTAssertEqual(controller.lastRestoreDiagnostics, .init(unidentifiedUnavailable: 1))
            XCTAssertEqual(controller.diagnosticSnapshot.retainedCount, 1)
            XCTAssertEqual(controller.diagnosticSnapshot.unidentifiedCount, 1)
        }
        XCTAssertEqual(fixture.writes, [.init(1, true)])
    }

    func testRestoreDiagnosticsDistinguishFailedSnapshotFromAmbiguousIdentity() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        window.ordinary = false
        window.inSnapshot = false
        fixture.snapshotAvailable = false

        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(snapshotUnavailable: 1))

        fixture.snapshotAvailable = true
        fixture.addWindow(2).windowNumber = 1
        fixture.addWindow(3).windowNumber = 1
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(identityAmbiguous: 1))
        XCTAssertEqual(controller.diagnosticSnapshot.retainedCount, 1)
        XCTAssertEqual(fixture.writes, [.init(1, true)])
    }

    func testRestoreDiagnosticsObserveExistingMissingRetirementThreshold() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        window.ordinary = false
        window.inSnapshot = false

        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(missingPending: 1))
        XCTAssertEqual(controller.diagnosticSnapshot.missingObservationCount, 1)
        fixture.clock += 0.2
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.diagnosticSnapshot.missingObservationCount, 2)
        fixture.clock += 0.3
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, missing: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(missingRetired: 1))
        XCTAssertEqual(controller.diagnosticSnapshot, .init())
        XCTAssertNil(controller.restoreActiveSession())
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init())
        XCTAssertEqual(fixture.writes, [.init(1, true)])
    }

    func testRestoreDiagnosticsDistinguishUnreadableNotSettableAndRejectedWrite() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        window.minimized = nil
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(minimizedUnreadable: 1))
        XCTAssertEqual(fixture.writes, [.init(1, true)])

        window.minimized = true
        window.canMinimize = false
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(restoreNotSettable: 1))
        XCTAssertEqual(fixture.writes, [.init(1, true)])

        window.canMinimize = true
        fixture.onWrite = { _, _ in .cannotComplete }
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, failed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(restoreWriteFailed: 1))
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false)])
        XCTAssertTrue(controller.hasActiveSession)
        XCTAssertTrue(fixture.activated.isEmpty)
    }

    func testRestoreDiagnosticsResetPerAttemptAndObserveDelayedCompletion() {
        let fixture = Fixture()
        let window = fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        fixture.onWrite = { _, _ in .success }

        for _ in 0..<2 {
            assertRestored(controller.restoreActiveSession()!, confirmed: 0, pending: 1)
            XCTAssertEqual(controller.lastRestoreDiagnostics, .init(restorePending: 1))
            XCTAssertEqual(controller.diagnosticSnapshot.restoreRequestedCount, 1)
        }
        window.minimized = nil
        assertRestored(controller.restoreActiveSession()!, confirmed: 0, pending: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(minimizedUnreadable: 1))
        XCTAssertEqual(fixture.writes, [.init(1, true), .init(1, false), .init(1, false)])

        window.minimized = false
        assertRestored(controller.restoreActiveSession()!, confirmed: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(restored: 1))
        XCTAssertEqual(controller.diagnosticSnapshot, .init())
        XCTAssertEqual(fixture.activated, [101])
        XCTAssertNil(controller.restoreActiveSession())
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init())
    }

    func testRestoreDiagnosticsCountTerminatedOwnerWithoutAdditionalMutation() {
        let fixture = Fixture()
        fixture.addWindow(1)
        let controller = fixture.controller()
        assertMinimized(controller.toggle(mode: .all, excludingBundleIdentifiers: []), confirmed: 1)
        fixture.runningPIDs.remove(101)

        assertRestored(controller.restoreActiveSession()!, confirmed: 0, missing: 1)
        XCTAssertEqual(controller.lastRestoreDiagnostics, .init(applicationTerminated: 1))
        XCTAssertEqual(controller.diagnosticSnapshot, .init())
        XCTAssertEqual(fixture.writes, [.init(1, true)])
        XCTAssertTrue(fixture.activated.isEmpty)
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
            var windowNumber: Int?
            var identifier: String?
            var isLive = true
            var ordinary = true
            var inSnapshot = true
            var canMinimize = true

            init(id: Int, pid: pid_t, minimized: Bool?) {
                self.id = id
                self.pid = pid
                self.minimized = minimized
                windowNumber = id
                identifier = "test.window.\(id)"
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
        var frontmostPID: pid_t? = 101
        var focused: AXUIElement?
        var onWrite: ((Window, Bool) -> AXError)?
        var date = Date(timeIntervalSince1970: 100)
        var minimizationObservation: (@MainActor () -> Void)?
        var snapshotAvailable = true
        var clock: TimeInterval {
            get { date.timeIntervalSince1970 }
            set { date = Date(timeIntervalSince1970: newValue) }
        }
        var environmentCalls: [String] = []

        private func observe<Value>(_ operation: String, _ read: () -> Value) -> Value {
            environmentCalls.append(operation)
            return read()
        }

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
                    self.observe("applications") {
                        self.runningPIDs.sorted().map {
                            .init(processIdentifier: $0, bundleIdentifier: "test.\($0)")
                        }
                    }
                },
                frontmostProcessIdentifier: { self.observe("frontmost") { self.frontmostPID } },
                isApplicationRunning: { pid in self.observe("running") { self.runningPIDs.contains(pid) } },
                activateApplication: { pid in self.observe("activate") { self.activated.append(pid) } },
                windowOrder: {
                    self.observe("windowOrder") {
                        Dictionary(uniqueKeysWithValues: self.windows.enumerated().map { ($1.id, $0) })
                    }
                },
                focusedWindow: { self.observe("focused") { self.focused } },
                windows: { pid in
                    self.observe("windows") {
                        (self.snapshotAvailable, self.windows.filter { $0.pid == pid && $0.inSnapshot && $0.isLive }.map(\.element))
                    }
                },
                processIdentifier: { element in self.observe("pid") { self.window(element).pid } },
                isOrdinaryWindow: { element in self.observe("ordinary") { self.window(element).ordinary && self.window(element).isLive } },
                windowNumber: { element in self.observe("number") { self.window(element).isLive ? self.window(element).windowNumber : nil } },
                identifier: { element in self.observe("identifier") { self.window(element).isLive ? self.window(element).identifier : nil } },
                minimized: { element in self.observe("minimized") { self.window(element).minimized } },
                canMinimize: { element in self.observe("settable") { self.window(element).canMinimize } },
                setMinimized: { element, value in
                    self.environmentCalls.append("setMinimized")
                    let window = self.window(element)
                    self.writes.append(.init(window.id, value))
                    if let onWrite = self.onWrite { return onWrite(window, value) }
                    window.minimized = value
                    return .success
                },
                raiseWindow: { element in self.observe("raise") { self.raised.append(self.window(element).id) } },
                now: { self.observe("now") { self.date } },
                observeMinimizationCompletion: { observe in
                    self.minimizationObservation = observe
                    return { self.minimizationObservation = nil }
                }
            ))
        }
    }
}
