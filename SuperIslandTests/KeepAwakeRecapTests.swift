import AppKit
import CoreGraphics
import XCTest
@testable import SuperIsland

final class KeepAwakeRecapTests: XCTestCase {
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
