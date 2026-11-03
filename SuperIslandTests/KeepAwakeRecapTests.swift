import AppKit
import CoreGraphics
import XCTest
import Combine
@testable import SuperIsland

final class KeepAwakeRecapTests: XCTestCase {
    @MainActor func testUnchangedOpenLidFramesDoNotPublishUIOrQueryLockState() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "KA2-Idle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        var lockReads = 0
        let controller = KeepAwakeRecapController(defaults: defaults, root: root,
            isLocked: { lockReads += 1; return false })
        controller.start(installUI: false); await controller.flush()
        controller.observe(frame(0, closed: false, enabled: false, hold: false)); await controller.flush()
        var notifications = 0
        let subscription = controller.objectWillChange.sink { notifications += 1 }
        let previousReads = lockReads
        for tick in 1...1_000 { controller.observe(frame(Double(tick), closed: false, enabled: false, hold: false)) }
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(lockReads, previousReads)
        controller.observe(frame(1_001, closed: false, enabled: true, hold: false))
        XCTAssertGreaterThan(notifications, 0, "Real changes must still reach menus and settings")
        subscription.cancel(); await controller.prepareForTermination()
    }
    @MainActor func testUnchangedPanelPreferenceDoesNotInvalidateRenderedContent() throws {
        let panel = KeepAwakeRecapPanel(summary: try XCTUnwrap(completed().latest), autoShow: true, editable: true, toggle: { _ in true })
        var notifications = 0
        let subscription = panel.presentation.objectWillChange.sink { notifications += 1 }
        for _ in 0..<1_000 { panel.updatePreference(true, editable: true) }
        XCTAssertEqual(notifications, 0)
        panel.updatePreference(false, editable: false)
        XCTAssertEqual(notifications, 2)
        subscription.cancel(); panel.dismiss()
    }
    @MainActor func testRecapUsesUpperScreenAreaAndRespectsExternalScreenOrigin() {
        let size = NSSize(width: 300, height: 350)
        for frame in [NSRect(x: 0, y: 30, width: 1440, height: 850),
                      NSRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            let point = KeepAwakeRecapPanel.frameOrigin(size: size, visibleFrame: frame)
            XCTAssertEqual(point.x + size.width / 2, frame.midX)
            XCTAssertEqual(point.y + size.height, frame.maxY - 64)
            XCTAssertTrue(frame.contains(NSRect(origin: point, size: size)))
        }
        let small = NSRect(x: 100, y: 40, width: 320, height: 370)
        let point = KeepAwakeRecapPanel.frameOrigin(size: size, visibleFrame: small)
        XCTAssertTrue(small.contains(NSRect(origin: point, size: size)))
        XCTAssertEqual(point.y, small.minY)
    }
    func testConsoleSessionUsesPublicKeyAndFailsClosed() {
        XCTAssertFalse(KeepAwakeRecapController.sessionLocked([kCGSessionOnConsoleKey as String: true]))
        XCTAssertTrue(KeepAwakeRecapController.sessionLocked([kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(KeepAwakeRecapController.sessionLocked([kCGSessionOnConsoleKey as String: false]))
        XCTAssertTrue(KeepAwakeRecapController.sessionLocked(nil))
        XCTAssertTrue(KeepAwakeRecapController.sessionLocked([:]))
    }
    typealias R = KeepAwakeRecap
    func stamp(_ t: Double, awake: Double? = nil, wall: Double? = nil) -> R.Stamp { .init(continuous:t, awake:awake ?? t, wall:wall ?? 1_800_000_000+t) }
    func task(_ key: String = "a", source: String = "codex-desktop", kind: R.Kind = .user, state: R.State = .running, started: Bool = true) -> R.TaskInput {
        .init(id:KeepAwakeHookContract.anonymousIdentity(source+key), source:source, kind:kind, state:state, started:started)
    }
    func frame(_ t: Double, closed: Bool? = true, enabled: Bool = true, hold: Bool = true, tasks: [R.TaskInput] = [], awake: Double? = nil, complete: Bool = true) -> R.Frame {
        .init(stamp:stamp(t,awake:awake),notebook:true,closed:closed,enabled:enabled,actualHold:hold,lidRequired:true,lidApplied:hold,released:!hold,protection:false,error:false,automatic:true,tasks:tasks,completeTasks:complete)
    }
    func begin(_ tasks: [R.TaskInput] = []) -> R {
        var r=R(); r.observe(frame(0,closed:false,hold:false,tasks:tasks)); r.observe(frame(1,tasks:tasks)); return r
    }
    func completed() -> R {
        var r=begin([task()]); r.observe(frame(2,hold:false,tasks:[task(state:.completed)]));r.observe(frame(3,closed:false,hold:false));return r
    }
    @MainActor func testFirstThermalObservationPersistsBeforeOrdinaryCheckpoint() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "KA2-Thermal-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let controller = KeepAwakeRecapController(defaults: defaults, root: root, isLocked: { false })
        controller.start(installUI: false); await controller.flush()
        controller.observe(frame(0, closed: false, hold: false))
        controller.observe(frame(1)); await controller.flush()
        var hot = frame(2, hold: false); hot.protection = true; hot.thermalProtection = true; hot.thermalLevel = 3
        controller.observe(hot); await controller.flush()
        let saved = try JSONDecoder().decode(R.self, from: Data(contentsOf: root.appendingPathComponent("Recap/summary.json")))
        XCTAssertEqual(saved.current?.firstThermalProtection?.stamp, stamp(2))
        XCTAssertEqual(saved.current?.firstThermalProtection?.level, 3)
        await controller.prepareForTermination()
    }

    @MainActor func testFirstLowPowerObservationPersistsAndLegacySummaryStillLoads() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "KA2-LowPower-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let controller = KeepAwakeRecapController(defaults: defaults, root: root, isLocked: { false })
        controller.start(installUI: false); await controller.flush()
        controller.observe(frame(0, closed: false, hold: false)); controller.observe(frame(1)); await controller.flush()
        var low = frame(2, hold: false); low.protection = true; low.lowPowerProtection = true
        controller.observe(low); await controller.flush()
        let data = try Data(contentsOf: root.appendingPathComponent("Recap/summary.json"))
        let saved = try JSONDecoder().decode(R.self, from: data)
        XCTAssertEqual(saved.current?.firstLowPowerProtection, stamp(2))
        low.stamp = stamp(3); controller.observe(low)
        XCTAssertEqual(controller.ledger.current?.firstLowPowerProtection, stamp(2))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var current = try XCTUnwrap(legacy["current"] as? [String: Any]); current.removeValue(forKey: "firstLowPowerProtection"); legacy["current"] = current
        XCTAssertNil(try JSONDecoder().decode(R.self, from: JSONSerialization.data(withJSONObject: legacy)).current?.firstLowPowerProtection)
        await controller.prepareForTermination()
    }

    func testThermalObservationIsBoundedAndOlderSummariesStillDecode() throws {
        var recap = begin([task()])
        var hot = frame(2, hold: false, tasks: [task()])
        hot.protection = true; hot.thermalProtection = true; hot.thermalLevel = 2
        recap.observe(hot)
        for i in 3...1000 {
            hot.stamp = stamp(Double(i)); hot.thermalLevel = 3; recap.observe(hot)
        }
        let first = try XCTUnwrap(recap.current?.firstThermalProtection)
        XCTAssertEqual(first.stamp, stamp(2)); XCTAssertEqual(first.level, 2)
        let data = try JSONEncoder().encode(recap)
        XCTAssertEqual(try JSONDecoder().decode(R.self, from: data).current?.firstThermalProtection, first)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var cycle = try XCTUnwrap(legacy["current"] as? [String: Any]); cycle.removeValue(forKey: "firstThermalProtection")
        legacy["current"] = cycle
        XCTAssertNil(try JSONDecoder().decode(R.self, from: JSONSerialization.data(withJSONObject: legacy)).current?.firstThermalProtection)
    }

    func testConcurrentIntervalsAreNotSummedAndReleaseGraceCounts() throws {
        var r=R();r.observe(frame(0,closed:false,hold:false))
        for t in 1...1140 {
            r.observe(frame(Double(t),hold:t<841,tasks:[task(state:t<601 ? .running:.completed),task("b",state:t<811 ? .running:.completed)]))
        }
        r.observe(frame(1141,closed:false,hold:false,tasks:[task("new-after-open")]))
        let s=try XCTUnwrap(r.latest)
        XCTAssertEqual(s.duration,1140);XCTAssertEqual(s.holdDuration,840);XCTAssertEqual(s.userTasks.count,2)
        XCTAssertTrue(s.userTasks.allSatisfy{$0.state == .completed});XCTAssertEqual(s.power,.released)
    }
    func testSnapshotCannotAdmitPostOpenNewTasksOrChangeOldResults() throws {
        var r=completed();let old=r.latest
        for t in 4...20 { r.observe(frame(Double(t),closed:false,tasks:[task("post")])) }
        XCTAssertEqual(r.latest,old);XCTAssertNil(r.current)
    }
    func testTerminalBeforeCloseAndUnstartedWaitingDoNotInventTasks() throws {
        let old=task(state:.completed),waiting=task("wait",state:.waiting,started:false)
        var r=begin([old,waiting]);r.observe(frame(2,closed:false,hold:false))
        XCTAssertTrue(try XCTUnwrap(r.latest).tasks.isEmpty)
    }
    func testSameTaskAcrossRefreshDeduplicatesButCrossSourceDoesNotMerge() throws {
        var r=begin([task(),task(source:"codex-cli")]);for t in 2...20 {r.observe(frame(Double(t),tasks:[task(),task(source:"codex-cli")]))}
        r.observe(frame(21,closed:false));XCTAssertEqual(r.latest?.tasks.count,2)
        XCTAssertEqual(Set(r.latest!.tasks.map(\.ordinal)).count,2)
    }
    func testMissingTaskBecomesUnknownNeverCompleted() {
        var r=begin([task()]);r.observe(frame(2,tasks:[]));r.observe(frame(3,closed:false))
        XCTAssertEqual(r.latest?.tasks.first?.state,.unknown)
    }
    func testPartialEventsDoNotMarkOtherTasksLost() {
        var r=begin([task(),task("b")]);r.observe(frame(2,tasks:[task(state:.completed)],complete:false));r.observe(frame(3,closed:false))
        XCTAssertEqual(r.latest?.tasks.last?.state,.running)
    }
    func testWaitingUnknownFailedCancelledAndCompletedStayDistinct() throws {
        var r=begin([task(),task("b"),task("c"),task("d"),task("e")]);
        r.observe(frame(2,tasks:[task(state:.waiting),task("b",state:.unknown),task("c",state:.failed),task("d",state:.cancelled),task("e",state:.completed)]));r.observe(frame(3,closed:false))
        let s=try XCTUnwrap(r.latest);XCTAssertEqual(s.userTasks.filter{$0.state == .completed}.count,1);XCTAssertEqual(s.userTasks.filter{$0.state.terminal}.count,3);XCTAssertEqual(s.power,.holding)
    }
    func testBackgroundIsExcludedAndUnclassifiedIsExplicit() throws {
        var r=begin([task(kind:.background),task("b",kind:.unclassified)]);r.observe(frame(2,closed:false));let s=try XCTUnwrap(r.latest)
        XCTAssertTrue(s.userTasks.isEmpty);XCTAssertEqual(s.auxiliary.count,2);XCTAssertTrue(s.incomplete);XCTAssertTrue(s.hasReasonToShow)
        var empty=R();empty.observe(frame(0,closed:false,hold:false));empty.observe(frame(1,hold:false,tasks:[task(kind:.background)]));empty.observe(frame(2,closed:false,hold:false));XCTAssertFalse(empty.latest!.hasReasonToShow)
    }
    func testUnknownLidOrHoldCoverageIsNotZero() {
        var r=begin();r.observe(frame(2,closed:nil));r.observe(frame(3,closed:false,hold:false))
        XCTAssertNil(r.latest?.duration);XCTAssertNil(r.latest?.holdDuration);XCTAssertEqual(R.durationText(r.latest?.holdDuration),"—")
    }
    func testStartupWhileAlreadyClosedIsIncompleteAndNeverAutomatic() {
        var r=R();r.observe(frame(10));r.observe(frame(11,closed:false));XCTAssertNil(r.latest?.duration);XCTAssertFalse(r.latest!.autoEligible)
    }
    func testSamplingStallIsNotAssumedContinuousHolding() {
        var r=begin();r.observe(frame(60));r.observe(frame(61,closed:false));XCTAssertNil(r.latest?.holdDuration)
    }
    func testWallClockChangesDoNotChangeDurationsOrTimelineOrderClock() throws {
        var r=begin()
        for t in 2...60 {var f=frame(Double(t));f.stamp.wall=1_800_000_000-Double(t)*10;r.observe(f)}
        var end=frame(61,closed:false);end.stamp.wall=1_700_000_000;r.observe(end)
        XCTAssertEqual(r.latest?.duration,60);XCTAssertEqual(r.latest?.holdDuration,60)
    }
    func testRequestAcceptedDoesNotProveSleep() {
        var r=begin();r.sleepRequestAccepted(stamp(2));r.observe(frame(3,closed:false,hold:false));XCTAssertTrue(r.latest!.sleepRequested);XCTAssertNil(r.latest?.sleepAt)
    }
    private func kernelFrame(_ t: Double, sleep: Double, wake: Double, awake: Double, closed: Bool = true) -> R.Frame {
        var value = frame(t, closed: closed, hold: false, awake: awake)
        value.kernelSleepTime = 1_800_000_000 + sleep
        value.kernelWakeTime = 1_800_000_000 + wake
        return value
    }
    func testCapturedThreeSleepsSurviveDarkWakeWithoutWorkspaceCallbacks() throws {
        var r = begin(); r.observe(frame(2, hold: false)); r.willSleep(stamp(5))
        r.observe(kernelFrame(606, sleep: 10, wake: 605, awake: 11))
        r.observe(kernelFrame(1533, sleep: 616, wake: 1532, awake: 22))
        r.observe(kernelFrame(9075, sleep: 8070, wake: 9074, awake: 6560))
        XCTAssertEqual(r.current?.sleepCount, 3)
        XCTAssertNil(r.current?.sleepStart, "The old willSleep anchor must not span several DarkWakes")
        r.observe(kernelFrame(10_000, sleep: 8070, wake: 9074, awake: 7485, closed: false))
        r.didWake(stamp(10_001, awake: 7486))
        let cycle = try XCTUnwrap(r.latest)
        XCTAssertEqual(cycle.sleepCount, 3)
        XCTAssertEqual(cycle.sleepAt, 1_800_000_010)
        XCTAssertEqual(cycle.timeline.filter { $0.title == "已确认系统实际休眠" }.count, 3)
        XCTAssertEqual(cycle.timeline.filter { $0.title.contains("仍合盖，内核已确认") }.count, 3)
        XCTAssertTrue(r.validate())
        let restored = try JSONDecoder().decode(R.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(restored.latest?.sleepCount, 3)
        XCTAssertTrue(restored.validate())
    }
    func testNotificationFirstAndKernelFirstBothDeduplicateTheSameSleep() {
        for notificationFirst in [false, true] {
            var r = begin(); r.observe(frame(2, hold: false)); r.willSleep(stamp(5))
            if notificationFirst { r.didWake(stamp(605, awake: 10)) }
            r.observe(kernelFrame(606, sleep: 10, wake: 605, awake: 11))
            if !notificationFirst { r.didWake(stamp(607, awake: 12)) }
            for t in 608...620 { r.observe(kernelFrame(Double(t), sleep: 10, wake: 605, awake: Double(t)-595)) }
            XCTAssertEqual(r.current?.sleepCount, 1)
            XCTAssertEqual(r.current?.sleepAt, 1_800_000_010)
            XCTAssertEqual(r.current?.timeline.filter { $0.title == "已确认系统实际休眠" }.count, 1)
        }
    }
    func testFirstOpenFrameCanConfirmFinalSleepButLaterOpenFramesCannotRewriteIt() {
        var r = begin(); r.observe(frame(2, hold: false))
        r.observe(kernelFrame(606, sleep: 10, wake: 605, awake: 11, closed: false))
        XCTAssertEqual(r.latest?.sleepCount, 1)
        let frozen = r.latest
        r.observe(kernelFrame(1000, sleep: 700, wake: 900, awake: 205, closed: false))
        XCTAssertEqual(r.latest, frozen)
    }
    func testOldInvalidFutureAndRegressingKernelPairsCannotInventSleep() {
        var r = begin(); r.observe(frame(2, hold: false))
        for pair in [(-100.0, 0.0), (20, 19), (3, 1000), (Double.nan, 10), (3, Double.infinity)] {
            r.observe(kernelFrame(20, sleep: pair.0, wake: pair.1, awake: 20))
        }
        XCTAssertEqual(r.current?.sleepCount, 0)
        r.observe(kernelFrame(606, sleep: 10, wake: 605, awake: 11))
        r.observe(kernelFrame(607, sleep: 5, wake: 600, awake: 12))
        XCTAssertEqual(r.current?.sleepCount, 1)
        XCTAssertTrue(r.validate())
    }
    func testKernelSleepWhileHoldingDoesNotClaimContinuousHold() {
        var r = begin([task()])
        var value = kernelFrame(606, sleep: 10, wake: 605, awake: 11)
        value.actualHold = true; value.lidApplied = true; value.tasks = [task()]
        r.observe(value); r.observe(frame(607, closed: false, hold: false, awake: 12))
        XCTAssertEqual(r.latest?.sleepCount, 1)
        XCTAssertNil(r.latest?.holdDuration)
        XCTAssertEqual(r.latest?.tasks.first?.state, .running)
    }
    func testKernelEvidenceIsBoundedAndLegacySummaryWithoutItStillDecodes() throws {
        var r = begin(); r.observe(frame(2, hold: false))
        for i in 1...100 {
            let t = Double(i * 10)
            r.observe(kernelFrame(t+1, sleep: t-5, wake: t, awake: t-Double(i*5)+1))
        }
        r.observe(frame(1002, closed: false, hold: false, awake: 502))
        XCTAssertEqual(r.latest?.sleepCount, 100)
        XCTAssertLessThanOrEqual(r.latest!.timeline.count, R.timelineLimit)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        var latest = try XCTUnwrap(json["latest"] as? [String: Any]); latest.removeValue(forKey: "lastSleepEvidence"); json["latest"] = latest
        let restored = try JSONDecoder().decode(R.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.validate()); XCTAssertEqual(restored.latest?.sleepCount, 100)
    }
    func testCPUDeferralExplainsOnlyAllowedAggregateTypesAndNeverStoresClientText() throws {
        var r = begin()
        r.sleepRequestDeferred(stamp(2), cpuBlocked: true, blockingTypes: ["BackgroundTask", "BackgroundTask", "private task content"])
        let title = try XCTUnwrap(r.current?.timeline.last?.title)
        XCTAssertTrue(title.contains("后台维护")); XCTAssertTrue(title.contains("暂缓"))
        XCTAssertFalse(title.contains("private")); XCTAssertNil(r.current?.sleepAt)
        XCTAssertFalse(r.current!.sleepRequested)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(r), as: UTF8.self).contains("private task content"))
    }
    func testRestoredInterruptedCycleCannotBackfillOldKernelPairAsAnotherSleep() throws {
        var r = begin(); r.observe(frame(2, hold: false)); r.willSleep(stamp(5)); r.didWake(stamp(605, awake: 10))
        r = try JSONDecoder().decode(R.self, from: JSONEncoder().encode(r))
        r.resumeAfterRelaunch()
        r.observe(kernelFrame(606, sleep: 10, wake: 605, awake: 11))
        XCTAssertEqual(r.current?.sleepCount, 1)
        XCTAssertTrue(r.current!.interrupted)
        XCTAssertEqual(r.current?.lastSleepEvidence?.kernel, false)
    }
    func testWallClockRollbackDuringNotificationSleepKeepsStoreValidAndMarksUncertainty() {
        var r = begin(); r.observe(frame(2, hold: false)); r.willSleep(stamp(5))
        r.didWake(stamp(605, awake: 10, wall: 1_700_000_000))
        XCTAssertEqual(r.current?.sleepCount, 1, "Monotonic clocks still prove suspension")
        XCTAssertNil(r.current?.lastSleepEvidence)
        XCTAssertTrue(r.current!.issues.contains("休眠期间系统时间发生变化，起止时间未确认"))
        XCTAssertTrue(r.validate())
    }
    func testDelayedHistoricalKernelProofDoesNotStopAccountingForNewHold() {
        var r = begin(); r.observe(frame(2, hold: false))
        r.observe(frame(606, hold: false, awake: 11))
        r.observe(frame(607, hold: true, awake: 12))
        let before = r.current!.heldSeconds
        var delayed = kernelFrame(608, sleep: 10, wake: 605, awake: 13)
        delayed.actualHold = true; delayed.lidApplied = true
        r.observe(delayed)
        XCTAssertEqual(r.current?.sleepCount, 1)
        XCTAssertEqual(r.current!.heldSeconds, before + 1, accuracy: 0.001)
        XCTAssertFalse(r.current!.issues.contains("保持期间检测到休眠，部分保持时段未确认"))
    }
    @MainActor func testControllerPersistsThreeKernelSleepsAndDoesNotReopenAfterFreeze() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "KA2-Kernel-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = KeepAwakeRecapController(defaults: defaults, root: root, isLocked: { false })
        controller.start(installUI: false); await controller.flush()
        controller.observe(frame(0, closed: false, hold: false)); controller.observe(frame(1, hold: false))
        controller.observe(kernelFrame(606, sleep: 10, wake: 605, awake: 11))
        controller.observe(kernelFrame(1533, sleep: 616, wake: 1532, awake: 22))
        controller.observe(kernelFrame(9075, sleep: 8070, wake: 9074, awake: 6560))
        controller.observe(kernelFrame(10_000, sleep: 8070, wake: 9074, awake: 7485, closed: false))
        await controller.flush()
        let saved = try JSONDecoder().decode(R.self, from: Data(contentsOf: root.appendingPathComponent("Recap/summary.json")))
        XCTAssertEqual(saved.latest?.sleepCount, 3)
        XCTAssertEqual(controller.latest?.sleepCount, 3)
        let frozen = controller.latest
        controller.didWake(stamp(10_001, awake: 7486))
        XCTAssertEqual(controller.latest, frozen)
        await controller.prepareForTermination()
    }
    func testCPUDeferralPersistsWithoutClaimingRequestAcceptanceOrSleep() throws {
        var r = begin()
        r.sleepRequestDeferred(stamp(2), cpuBlocked: true)
        r.sleepRequestDeferred(stamp(3), cpuBlocked: true)
        XCTAssertFalse(r.current!.sleepRequested); XCTAssertNil(r.current!.sleepAt)
        XCTAssertEqual(r.current!.timeline.filter { $0.title.contains("CPU") }.count, 1)
        let restored = try JSONDecoder().decode(KeepAwakeRecap.self, from: JSONEncoder().encode(r))
        XCTAssertTrue(restored.validate())
        XCTAssertFalse(restored.current!.sleepRequested); XCTAssertNil(restored.current!.sleepAt)
    }
    func testUnknownCPUDeferralCannotCreateCycleOrAlterClosedCycle() {
        var r = KeepAwakeRecap()
        r.sleepRequestDeferred(stamp(1), cpuBlocked: nil)
        XCTAssertNil(r.current); XCTAssertNil(r.latest)
        r = begin(); r.observe(frame(3, closed: false, hold: false))
        let latest = r.latest
        r.sleepRequestDeferred(stamp(4), cpuBlocked: nil)
        XCTAssertEqual(r.latest, latest)
    }
    func testWillSleepWithNoSuspensionCannotClaimActualSleep() {
        var r=begin();r.willSleep(stamp(2));r.didWake(stamp(3));r.observe(frame(4,closed:false,hold:false));XCTAssertNil(r.latest?.sleepAt)
    }
    func testMaintenanceWakeConfirmsSleepWithoutEndingCycleOrPopup() {
        var r=begin();let id=r.current!.id;r.willSleep(stamp(2));r.didWake(stamp(602,awake:2))
        XCTAssertNil(r.latest);XCTAssertEqual(r.current?.id,id);XCTAssertEqual(r.current?.sleepCount,1)
        r.observe(frame(603,closed:false,hold:false,awake:3));XCTAssertNotNil(r.latest?.sleepAt);XCTAssertEqual(r.latest?.holdDuration,1)
    }
    func testLateWakeMayOnlyFillImmediatelyClosedSummaryAtFrozenCutoff() {
        var r=begin();r.willSleep(stamp(2));r.observe(frame(602,closed:false,hold:false,awake:2));let end=r.latest?.end
        r.didWake(stamp(603,awake:3));XCTAssertNotNil(r.latest?.sleepAt);XCTAssertEqual(r.latest?.end,end)
        var late=begin();late.willSleep(stamp(2));late.observe(frame(602,closed:false,hold:false,awake:2));late.didWake(stamp(606,awake:6));XCTAssertNil(late.latest?.sleepAt)
    }
    func testOrdinaryStopCannotPretendHelperReleased() {
        var r=begin();var pending=frame(2,hold:false);pending.released=false;r.observe(pending);r.observe(frame(3,closed:false,hold:false));XCTAssertEqual(r.latest?.power,.unconfirmed)
    }
    func testMasterOffDuringCycleCannotReplayOnReenable() {
        var r=begin([task()]);r.observe(frame(2,enabled:false));r.observe(frame(3));r.observe(frame(4,closed:false));XCTAssertFalse(r.latest!.autoEligible)
        r.observe(frame(5));r.observe(frame(6,closed:false));XCTAssertTrue(r.latest!.autoEligible)
    }
    func testRelaunchKeepsLastManualSummaryButNeverReplaysOrFakesBoundary() {
        var r=completed();r.resumeAfterRelaunch();XCTAssertNotNil(r.latest);XCTAssertFalse(r.latest!.autoEligible)
        var interrupted=begin([task()]);interrupted.resumeAfterRelaunch();interrupted.observe(frame(20,closed:false,hold:false));XCTAssertNil(interrupted.latest?.end);XCTAssertNil(interrupted.latest?.holdDuration);XCTAssertTrue(interrupted.latest!.interrupted)
    }
    func testOnlyLatestFinishedCycleIsRetained() {
        var r=completed();let old=r.latest!.id;r.observe(frame(4));r.observe(frame(5,closed:false));XCTAssertNotEqual(r.latest?.id,old);XCTAssertNil(r.current)
    }
    func testDesktopNeverCreatesLidCycle() {
        var r=R();var f=frame(1);f.notebook=false;r.observe(f);XCTAssertNil(r.current);XCTAssertNil(r.latest)
    }
    func testCapacityAndMalformedMetadataCannotBecomeCompleteStatistics() {
        var r=begin();let tasks=(0...R.taskLimit).map{task(String($0))};r.observe(frame(2,tasks:tasks));r.observe(frame(3,closed:false));XCTAssertEqual(r.latest?.tasks.count,R.taskLimit);XCTAssertTrue(r.latest!.incomplete)
        XCTAssertFalse(R.validTask(.init(id:"private/path",source:"codex-desktop",kind:.user,state:.running,started:true)))
    }
    func testLongCycleRemainsBoundedAndFormatsHours() throws {
        var r=begin([task()]);for t in stride(from:2,through:90_002,by:5){r.observe(frame(Double(t),tasks:[task()]))};r.observe(frame(90_003,closed:false));XCTAssertEqual(r.latest?.tasks.count,1);XCTAssertLessThanOrEqual(r.latest!.timeline.count,R.timelineLimit);XCTAssertTrue(R.durationText(r.latest?.duration).contains("小时"));XCTAssertTrue(r.validate())
    }
    private func root() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("KA2-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return url
    }
    func testPrivateAtomicStoreBoundedToCurrentAndLastAndRejectsStaleWrites() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let store=KeepAwakeRecapStore(root:root);_ = try await store.load()
        let first=completed();var second=first;second.observe(frame(4));second.observe(frame(5,closed:false))
        let saved = try await store.save(second,revision:2), stale = try await store.save(first,revision:1)
        XCTAssertTrue(saved);XCTAssertFalse(stale)
        let restored = try await store.load();XCTAssertEqual(restored.latest?.id,second.latest?.id)
        let file=root.appendingPathComponent("Recap/summary.json");let attrs=try FileManager.default.attributesOfItem(atPath:file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let raw=String(decoding:try Data(contentsOf:file),as:UTF8.self);XCTAssertFalse(raw.contains("transcript"));XCTAssertFalse(raw.contains(root.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("Recap").path),["summary.json"])
    }
    func testStoreRejectsSymlinksAndCorruptRecords() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let store=KeepAwakeRecapStore(root:root);_ = try await store.load()
        let target=root.appendingPathComponent("unrelated");try Data("untouched".utf8).write(to:target);try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Recap/summary.json"),withDestinationURL:target)
        do{_ = try await store.load();XCTFail("symlink accepted")}catch{}
        _ = try await store.save(completed(),revision:1);XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"untouched")
        try Data("invalid".utf8).write(to:root.appendingPathComponent("Recap/summary.json"));do{_ = try await store.load();XCTFail("corrupt accepted")}catch{}
    }
    @MainActor func testPreferenceFailureAndMasterOffPreserveChoice() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let name="KA2-"+UUID().uuidString;let defaults=UserDefaults(suiteName:name)!;defer{defaults.removePersistentDomain(forName:name)}
        var locked=false;let c=KeepAwakeRecapController(defaults:defaults,root:root,isLocked:{locked},preferenceWriter:{_ in false});c.start(installUI:false);await c.flush()
        c.observe(frame(0,closed:false,enabled:false,hold:false));XCTAssertFalse(c.setAutoShow(false));XCTAssertTrue(c.autoShow)
        c.observe(frame(1,closed:false,hold:false));XCTAssertFalse(c.setAutoShow(false));XCTAssertNotNil(c.preferenceError);XCTAssertTrue(c.autoShow)
        c.observe(frame(2));c.observe(frame(3,closed:false));XCTAssertTrue(c.canOpen);locked=true;XCTAssertFalse(c.canOpen)
        c.shutdown();await c.flush()
    }
    @MainActor func testUnpreparedStorageDoesNotSilentlyClearPersistenceFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        let name = "KA2-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let c = KeepAwakeRecapController(defaults: defaults, root: root, isLocked: { false })
        c.start(installUI: false); await c.flush()
        XCTAssertNotNil(c.storageError)
        c.observe(frame(0, closed: false, hold: false)); c.observe(frame(1))
        await c.flush()
        XCTAssertNotNil(c.storageError)
        XCTAssertTrue(c.ledger.current?.issues.contains("回顾记录未能保存") == true)
        c.shutdown(); await c.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recap/summary.json").path))
    }
    @MainActor func testAutomaticPresentationWaitsForUnlockIsOncePerCycleAndManualCanReopen() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let name="KA2-"+UUID().uuidString;let defaults=UserDefaults(suiteName:name)!;defer{defaults.removePersistentDomain(forName:name)}
        var locked=true;var presentations=[Bool]()
        let c=KeepAwakeRecapController(defaults:defaults,root:root,isLocked:{locked},presenter:{_,manual in presentations.append(manual);return true})
        c.start();await c.flush();c.observe(frame(0,closed:false,hold:false));c.observe(frame(1,tasks:[task()]));c.observe(frame(2,closed:false))
        XCTAssertTrue(presentations.isEmpty);locked=false;c.observe(frame(3,closed:false));XCTAssertEqual(presentations,[false])
        c.observe(frame(4,closed:false));XCTAssertEqual(presentations.count,1);c.openLatest();XCTAssertEqual(presentations,[false,true])
        c.observe(frame(5,tasks:[task()]));c.observe(frame(6,closed:false));XCTAssertEqual(presentations,[false,true,false])
        await c.prepareForTermination()
    }
    @MainActor func testMasterOrPreferenceOffCancelsDeferredOldPopupAndPreferencePersists() async throws {
        let root=try root();defer{try? FileManager.default.removeItem(at:root)};let name="KA2-"+UUID().uuidString;let defaults=UserDefaults(suiteName:name)!;defer{defaults.removePersistentDomain(forName:name)}
        var locked=true;var count=0
        let c=KeepAwakeRecapController(defaults:defaults,root:root,isLocked:{locked},presenter:{_,_ in count += 1;return true})
        c.start();await c.flush();c.observe(frame(0,closed:false,hold:false));c.observe(frame(1));c.observe(frame(2,closed:false));c.observe(frame(3,closed:false,enabled:false));locked=false;c.observe(frame(4,closed:false));XCTAssertEqual(count,0)
        XCTAssertTrue(c.setAutoShow(false));c.observe(frame(5));c.observe(frame(6,closed:false));XCTAssertEqual(count,0);c.openLatest();XCTAssertEqual(count,1)
        await c.prepareForTermination()
        let restored=KeepAwakeRecapController(defaults:defaults,root:root,isLocked:{false},presenter:{_,_ in count += 1;return true});restored.start();await restored.flush();restored.observe(frame(10,closed:false,hold:false));XCTAssertFalse(restored.autoShow);XCTAssertEqual(count,1);await restored.prepareForTermination()
    }
    func testReleaseCauseDoesNotInventAutomaticTaskCompletion() {
        var r=begin([task()]);r.observe(frame(2,enabled:false,hold:false,tasks:[task()]));r.observe(frame(3,closed:false,enabled:false,hold:false));XCTAssertEqual(r.latest?.releaseReason,.manual);XCTAssertEqual(r.latest?.tasks.first?.state,.running)
    }
    @MainActor func testNativePanelStartsPassiveHasOpaqueBackgroundAndClosesWithoutPreferenceChange() throws {
        let s=try XCTUnwrap(completed().latest);var changes=0
        let p=KeepAwakeRecapPanel(summary:s,autoShow:true,editable:true,toggle:{_ in changes += 1;return true})
        XCTAssertFalse(p.panel.canBecomeKey);XCTAssertFalse(p.panel.canBecomeMain);XCTAssertTrue(p.panel.isOpaque)
        XCTAssertTrue(p.panel.styleMask.contains(.nonactivatingPanel));XCTAssertEqual(p.panel.accessibilityIdentifier(),"data-annotation-id=si.ka.recap")
        _ = p.present(manual:false);XCTAssertTrue(p.panel.isVisible);p.dismiss();XCTAssertFalse(p.panel.isVisible);XCTAssertEqual(changes,0)
        _ = p.present(manual:true);XCTAssertTrue(p.panel.canBecomeKey);p.panel.cancelOperation(nil);XCTAssertFalse(p.panel.isVisible)
    }
    @MainActor func testOpenPanelCanReceiveLateSleepProofOnlyForSameFrozenCycle() throws {
        var r = begin()
        r.willSleep(stamp(2)); r.observe(frame(602, closed: false, hold: false, awake: 2))
        let snapshot = try XCTUnwrap(r.latest)
        let p = KeepAwakeRecapPanel(summary: snapshot, autoShow: true, editable: true, toggle: { _ in true })
        XCTAssertNil(p.presentation.summary.sleepAt)
        r.didWake(stamp(603, awake: 3)); p.updateSummary(r.latest)
        XCTAssertNotNil(p.presentation.summary.sleepAt)
        XCTAssertEqual(p.presentation.summary.end, snapshot.end)
        r.observe(frame(604)); r.observe(frame(605, closed: false))
        p.updateSummary(r.latest)
        XCTAssertEqual(p.presentation.summary.id, snapshot.id)
        p.dismiss()
    }
    @MainActor func testNativeRecapCardsExposeIDsAndRenderOpaqueInBothAppearances() async throws {
        let summary = try XCTUnwrap(completed().latest)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/KA2NativeValidation/NativeViews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var evidence: [String: [String]] = [:]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let p = KeepAwakeRecapPanel(summary: summary, autoShow: true, editable: true, toggle: { _ in true })
            p.panel.appearance = NSAppearance(named: appearance)
            _ = p.present(manual: true)
            // Activate only the XCTest fixture to let AppKit publish its AX
            // tree. Production automatic presentation remains nonactivating.
            NSApp.activate(ignoringOtherApps: true)
            defer { p.dismiss() }
            let view = try XCTUnwrap(p.panel.contentView)
            view.layoutSubtreeIfNeeded()
            var seen = Set<ObjectIdentifier>(), ids = Set<String>()
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                let id = NSSelectorFromString("accessibilityIdentifier")
                if object.responds(to: id), let value = object.perform(id)?.takeUnretainedValue() as? String { ids.insert(value) }
                let children = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] { values.forEach(visit) }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            // NSPanel can omit its host from in-process window children while
            // inactive. Inspect the rendered content as well as the window.
            let suffixes = ["metrics", "summary", "power", "tasks", "timeline", "explanation", "close", "auto"]
            let required = Set(suffixes.map { "data-annotation-id=si.ka.recap." + $0 })
            // SwiftUI may render before AppKit publishes its AX children.
            // Await that observable readiness, retaining the same assertions
            // and a bounded timeout instead of assuming a fixed 100ms delay.
            for attempt in 0..<40 {
                seen.removeAll(); ids.removeAll()
                view.layoutSubtreeIfNeeded(); visit(p.panel); visit(view)
                if required.isSubset(of: ids) { break }
                if attempt < 39 { try await Task.sleep(for: .milliseconds(50)) }
            }
            for suffix in suffixes {
                XCTAssertTrue(ids.contains("data-annotation-id=si.ka.recap." + suffix), "Missing native group: \(suffix)")
            }
            XCTAssertTrue(p.panel.isOpaque)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(appearance.rawValue + ".png"))
            // Export native logical size as well, so a Retina screenshot is
            // not mistaken for a window twice its actual dimensions.
            let logical = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            logical.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: logical)
            try XCTUnwrap(logical.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("1x-" + appearance.rawValue + ".png"))
            evidence[appearance.rawValue] = ids.sorted()
        }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("recap-accessibility.json"))
        // Return this XCTest host to the background after the explicit AX
        // inspection. Otherwise later nonactivation tests inherit our focus.
        NSApp.hide(nil)
        try await Task.sleep(for: .milliseconds(150))
        NSApp.unhideWithoutActivation()
    }
}
