import XCTest
@testable import SuperIsland

@MainActor
final class ModuleRefreshSchedulerTests: XCTestCase {
    func testVisibleSettingsKeepsSamplingWhileHiddenIslandJobsStayThrottled() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyMode: { .smart }, moduleVisibility: { _, _ in false })
        var visible = true, enabled = true
        scheduler.register(id: "settings", name: "Visible battery dashboard", module: .builtIn(.battery),
            policy: .interval(5, tolerance: 1), enabled: { enabled }, visibleOutsideIsland: { visible }, action: {})
        scheduler.register(id: "legacy", name: "Existing hidden job", module: .builtIn(.battery),
            policy: .interval(5, tolerance: 1), action: {})
        defer { scheduler.unregister(id: "settings"); scheduler.unregister(id: "legacy") }
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "settings"), 5)
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "legacy"), 30)
        visible = false; scheduler.refreshScheduling()
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "settings"), 30)
        enabled = false; scheduler.refreshScheduling()
        XCTAssertNil(scheduler.scheduledIntervalForTesting(id: "settings"))
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)
    }

    func testVisibleModuleUsesActiveRateAndLowPowerStillWins() {
        var visible = false, mode = EnergyMode.smart
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyMode: { mode }, moduleVisibility: { _, _ in visible })
        scheduler.register(id: "module", name: "Battery visibility", module: .builtIn(.battery), policy: .interval(5, tolerance: 1), action: {})
        defer { scheduler.unregister(id: "module") }
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "module"), 30)
        visible = true; scheduler.refreshScheduling()
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "module"), 5)
        mode = .lowPower; scheduler.refreshScheduling()
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "module"), 60)
    }

    func testVisibleDashboardDoesNotBypassLowPowerRefreshLimit() {
        var mode = EnergyMode.lowPower
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyMode: { mode })
        scheduler.register(id: "settings", name: "Visible dashboard", module: .builtIn(.battery),
            policy: .interval(5, tolerance: 1), visibleOutsideIsland: { true }, action: {})
        defer { scheduler.unregister(id: "settings") }
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "settings"), 60)
        mode = .normal; scheduler.refreshScheduling()
        XCTAssertEqual(scheduler.scheduledIntervalForTesting(id: "settings"), 5)
    }

    // Regression test for the main-thread freeze caused by leaked RunLoop timers.
    //
    // A module's refresh `action` can re-enter the scheduler (for example when a
    // refresh nudges AppState, which pushes a new activity state and triggers a
    // reschedule). The original implementation stored each Timer inside the Job
    // value type; `run(id:)` read a Job copy, invoked the action, then wrote the
    // stale copy back — clobbering any timer the re-entrant call had installed.
    // The clobbered timer stayed armed on RunLoop.main but lost its only owning
    // reference, so it could never be invalidated. Over days these orphans piled
    // up until __CFArmNextTimerInMode turned into an O(n) scan that pegged the
    // main thread and froze the UI.
    //
    // One job must own exactly one live timer no matter how often its action
    // re-enters the scheduler.
    func testReentrantActionDoesNotOrphanTimers() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var runCount = 0

        scheduler.register(
            id: "test.job",
            name: "Test Job",
            policy: .interval(0.05, tolerance: 0.01),
            enabled: { true }
        ) { [weak scheduler] in
            runCount += 1
            // Re-enter mid-run, the way a real module refresh can.
            scheduler?.refreshScheduling()
        }

        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        for _ in 0..<200 {
            scheduler.runNow(id: "test.job")
        }

        XCTAssertGreaterThan(runCount, 0, "action should have executed")
        XCTAssertEqual(
            scheduler.scheduledTimerCountForTesting,
            scheduler.jobCountForTesting,
            "live timers must track the number of jobs, never accumulate"
        )
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        scheduler.unregister(id: "test.job")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }

    // Repeated re-registration of the same id must not accumulate timers either.
    func testReRegisterKeepsSingleTimer() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)

        for _ in 0..<50 {
            scheduler.register(
                id: "test.job",
                name: "Test Job",
                policy: .interval(1, tolerance: 0.1),
                enabled: { true },
                action: {}
            )
        }

        XCTAssertEqual(scheduler.jobCountForTesting, 1)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        scheduler.unregister(id: "test.job")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }
}
