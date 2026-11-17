import AppKit
import XCTest
import ServiceManagement
import SwiftUI
@testable import SuperIsland

final class FeatureMasterSwitchTests: XCTestCase {
    @MainActor private final class Fixture {
        let name = "MS1-" + UUID().uuidString
        let defaults: UserDefaults
        let root: URL
        let pasteboard = NSPasteboard.withUniqueName()
        var capture: [String: ScreenshotLinePrefs.Value] = [:]
        var writes = 0
        var rejectWrites = false
        init() throws {
            defaults = UserDefaults(suiteName: name)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults.set(false, forKey: "screenshotLine.watch")
            defaults.set(false, forKey: "screenshotLine.peek")
        }
        func line() -> ScreenshotLineFeature {
            ScreenshotLineFeature(defaults: defaults, supportDirectory: root, pasteboard: pasteboard,
                readCapture: { [unowned self] in capture[$0] ?? .init() },
                writeCapture: { [unowned self] key, value in
                    writes += 1; if !rejectWrites { capture[key] = value }
                })
        }
        func dispose() {
            defaults.removePersistentDomain(forName: name)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        func image(_ byte: UInt8 = 32) throws -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            memset(rep.bitmapData!, Int32(byte), rep.bytesPerRow * rep.pixelsHigh)
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        func copyImage(_ byte: UInt8 = 32) throws {
            let item = NSPasteboardItem(); item.setData(try image(byte), forType: .png)
            pasteboard.clearContents(); pasteboard.writeObjects([item])
        }
        func snapshot(original: ScreenshotLinePrefs.Value, owned: ScreenshotLinePrefs.Value) throws {
            let data = try JSONEncoder().encode(ScreenshotLinePrefs.Snapshot(original: ["location": original], owned: ["location": owned]))
            try data.write(to: root.appendingPathComponent("takeover-snapshot.json"))
        }
    }
    @MainActor private func wait(_ seconds: Double = 0.8) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    @MainActor func testIndependentIconPreferencesPersistWithoutChangingFeatureState() throws {
        let f = try Fixture(); defer { f.dispose() }
        XCTAssertTrue(FeatureMenuBarIcon.screenshotLine.isVisible(in: f.defaults))
        XCTAssertTrue(FeatureMenuBarIcon.keepAwake.isVisible(in: f.defaults))
        XCTAssertFalse(FeatureMenuBarIcon.battery.isVisible(in: f.defaults))
        for enabled in [false, true] {
            for key in ["screenshotLine.enabled", "keepAwake.enabled", "batteryProtection.v1.enabled", "general.showMenuBarIcon"] {
                f.defaults.set(enabled, forKey: key)
            }
            for feature in FeatureMenuBarIcon.allCases {
                for visible in [false, true] {
                    let before = f.defaults.dictionaryRepresentation()
                    f.defaults.set(visible, forKey: feature.key)
                    let reloaded = try XCTUnwrap(UserDefaults(suiteName: f.name))
                    XCTAssertEqual(feature.isVisible(in: reloaded), visible)
                    for (key, value) in before where key != feature.key {
                        XCTAssertEqual(reloaded.object(forKey: key) as? NSObject, value as? NSObject)
                    }
                }
            }
        }
    }
    @MainActor func testIconObserverReactsOnlyToPresentationPreferences() async throws {
        let f = try Fixture(); defer { f.dispose() }
        var changes: [FeatureMenuBarVisibility] = []
        let observer = FeatureMenuBarVisibilityObserver(defaults: f.defaults) { changes.append($0) }
        XCTAssertEqual(changes.count, 1)
        f.defaults.set(true, forKey: "keepAwake.enabled"); observer.refresh()
        f.defaults.set(false, forKey: "general.showMenuBarIcon"); observer.refresh()
        XCTAssertEqual(changes.count, 1)
        f.defaults.set(false, forKey: FeatureMenuBarIcon.keepAwake.key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: f.defaults)
        try await wait(0.08)
        XCTAssertEqual(changes.count, 2); XCTAssertFalse(changes.last!.keepAwake)
        observer.refresh(); XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(f.defaults.bool(forKey: "keepAwake.enabled"))
    }
    @MainActor func testWakeIconVisibilityNeverChangesEnablementOrCreatesDuplicates() throws {
        let f = try Fixture(); defer { f.dispose() }
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notRegistered })
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        let controller = KeepAwakeMenuController(service: service)
        defer { controller.setStatusItemVisible(false); service.shutdown() }
        for enabled in [false, true] {
            service.setEnabled(enabled)
            for _ in 0..<3 {
                controller.setStatusItemVisible(true)
                let first = try XCTUnwrap(controller.statusItem)
                controller.setStatusItemVisible(true); XCTAssertTrue(first === controller.statusItem)
                controller.setStatusItemVisible(false); XCTAssertNil(controller.statusItem)
                controller.setStatusItemVisible(false); XCTAssertNil(controller.statusItem)
                XCTAssertEqual(service.engine.enabled, enabled)
            }
        }
    }
    @MainActor func testScreenshotIconVisibilityDoesNotStopCaptureOrEnableDisabledFeature() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.defaults.set("none", forKey: "screenshotLine.shortcut")
        f.defaults.set(false, forKey: FeatureMenuBarIcon.screenshotLine.key)
        let line = f.line(); line.start(appName: "MS1Test", installUI: true)
        defer { line.stop() }
        XCTAssertNil(line.statusItem, "A hidden startup preference must not flash a new item")
        for enabled in [false, true] {
            line.setEnabled(enabled)
            for _ in 0..<3 {
                line.setMenuBarIconVisible(true)
                let item = try XCTUnwrap(line.statusItem)
                line.setMenuBarIconVisible(true); XCTAssertTrue(item === line.statusItem)
                line.setMenuBarIconVisible(false); XCTAssertNil(line.statusItem)
                XCTAssertEqual(line.isEnabled, enabled); XCTAssertEqual(f.writes, 0)
            }
        }
        line.stop(); line.setMenuBarIconVisible(true); XCTAssertNil(line.statusItem)
        line.start(appName: "MS1Test", installUI: true); XCTAssertNil(line.statusItem)
    }
    @MainActor func testBatteryIconReadOnlyLifecycleAndDesktopGuard() throws {
        var snapshot = BatteryStatusMenuController.Snapshot(presence: .present, level: 72, charging: false)
        var opened = 0
        let controller = BatteryStatusMenuController(read: { snapshot }, openSettings: { opened += 1 })
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        let first = try XCTUnwrap(controller.statusItem)
        controller.refresh(); XCTAssertTrue(first === controller.statusItem)
        XCTAssertEqual(first.button?.toolTip, "电池 72%")
        snapshot.level = nil; controller.refresh()
        XCTAssertEqual(first.button?.toolTip, "电池电量暂不可用")
        XCTAssertEqual(snapshot.symbol, "questionmark.circle")
        XCTAssertEqual(opened, 0)
        first.menu?.performActionForItem(at: 2); XCTAssertEqual(opened, 1)
        snapshot.presence = .absent; controller.refresh(); XCTAssertNil(controller.statusItem)
        snapshot.presence = .present; controller.refresh(); XCTAssertNotNil(controller.statusItem)
        controller.setVisible(false); snapshot.level = 80; controller.refresh(); XCTAssertNil(controller.statusItem)
        XCTAssertEqual(opened, 1)
    }

    @MainActor func testNativeDisplayTogglesUpdateIconsWithoutEnablingFeatures() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.defaults.set(false, forKey: "screenshotLine.enabled")
        f.defaults.set("none", forKey: "screenshotLine.shortcut")
        let line = f.line(); line.start(appName: "MS1Test", installUI: true)
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notRegistered })
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        let wake = KeepAwakeMenuController(service: service)
        let battery = BatteryStatusMenuController(read: { .init(presence: .present, level: 80, charging: false) }, openSettings: {})
        let observer = FeatureMenuBarVisibilityObserver(defaults: f.defaults) { state in
            line.setMenuBarIconVisible(state.screenshotLine); wake.setStatusItemVisible(state.keepAwake); battery.setVisible(state.battery)
        }
        defer { withExtendedLifetime(observer) {}; line.stop(); wake.setStatusItemVisible(false); battery.setVisible(false); service.shutdown() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: VStack {
            FeatureMenuBarToggle(.screenshotLine); FeatureMenuBarToggle(.keepAwake); FeatureMenuBarToggle(.battery)
        }.padding(20).defaultAppStorage(f.defaults))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func controls() -> [String: NSObject] {
            var seen = Set<ObjectIdentifier>(), result: [String: NSObject] = [:]
            func text(_ object: NSObject, _ key: String) -> String? {
                let selector = NSSelectorFromString(key)
                return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
            }
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                if text(object, "accessibilityRole") == "AXCheckBox", let id = text(object, "accessibilityIdentifier") { result[id] = object }
                let selector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(visit) }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            visit(window); visit(host); return result
        }
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if controls().count == 3 { break }
            try await wait(0.025)
        }
        for feature in FeatureMenuBarIcon.allCases {
            for _ in 0..<2 {
                let previous = feature.isVisible(in: f.defaults)
                let node = try XCTUnwrap(controls()["data-annotation-id=" + feature.annotationID])
                let selector = NSSelectorFromString("accessibilityPerformPress")
                XCTAssertTrue(node.responds(to: selector))
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector))
                try await wait(0.12)
                XCTAssertEqual(feature.isVisible(in: f.defaults), !previous)
                XCTAssertEqual(line.statusItem != nil, FeatureMenuBarIcon.screenshotLine.isVisible(in: f.defaults))
                XCTAssertEqual(wake.statusItem != nil, FeatureMenuBarIcon.keepAwake.isVisible(in: f.defaults))
                XCTAssertEqual(battery.statusItem != nil, FeatureMenuBarIcon.battery.isVisible(in: f.defaults))
                XCTAssertFalse(line.isEnabled); XCTAssertFalse(service.engine.enabled); XCTAssertEqual(f.writes, 0)
            }
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "IndependentMenuBarToggles"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testScreenshotDisableRetainsFilesPreferencesAndPersistedIntentWithoutClipboardReplay() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.defaults.set(true, forKey: "screenshotLine.clipboard")
        f.defaults.set(2, forKey: "screenshotLine.size")
        let line = f.line(); defer { line.stop() }
        XCTAssertTrue(line.isEnabled, "Existing installs migrate enabled")
        line.start(appName: "MS1Test", installUI: false)
        try f.copyImage(); try await wait()
        XCTAssertEqual(line.items.count, 1)
        let saved = try XCTUnwrap(line.items.first)
        let imageBytes = try Data(contentsOf: saved.url)
        let indexBytes = try Data(contentsOf: f.root.appendingPathComponent("index.json"))
        line.setEnabled(false)
        try f.copyImage()
        let disabledClipboard = f.pasteboard.changeCount
        try await wait()
        line.toggleLine()
        line.copy(saved); line.close(saved); line.trash(saved)
        line.setShortcut("none"); line.resetWatchFolder()
        XCTAssertNotEqual(line.shortcut, "none")
        XCTAssertFalse(line.lineExpanded)
        XCTAssertEqual(line.items.count, 1)
        XCTAssertEqual(try Data(contentsOf: saved.url), imageBytes)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("index.json")), indexBytes)
        XCTAssertEqual(f.pasteboard.changeCount, disabledClipboard, "Off must not clear the clipboard")
        XCTAssertTrue(line.clipboardEnabled); XCTAssertFalse(line.watchEnabled); XCTAssertEqual(line.lineSize, 2)
        line.stop()
        let reopened = f.line(); defer { reopened.stop() }
        reopened.start(appName: "MS1Test", installUI: false)
        XCTAssertFalse(reopened.isEnabled); XCTAssertEqual(reopened.items, line.items)
        reopened.setEnabled(true); try await wait()
        XCTAssertEqual(reopened.items.count, 1, "Off-period copy establishes the new baseline")
        try f.copyImage(200); try await wait()
        XCTAssertEqual(reopened.items.count, 2, "A new image after re-enabling is still collected")
        XCTAssertEqual(f.writes, 0, "A master toggle must not take over system screenshots")
    }

    @MainActor func testScreenshotWatcherIgnoresOffPeriodAndLateCallbacksAcrossRestart() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let folder = f.root.appendingPathComponent("Watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        f.defaults.set(folder.path, forKey: "screenshotLine.watchFolder")
        f.defaults.set(true, forKey: "screenshotLine.watch")
        let line = f.line(); defer { line.stop() }
        try f.image().write(to: folder.appendingPathComponent("before.png"))
        line.start(appName: "MS1Test", installUI: false)
        try await wait(0.3)
        try f.image().write(to: folder.appendingPathComponent("pending.png"))
        try await wait(1.1) // Seen once, not yet stable; disable while pending.
        line.setEnabled(false)
        try f.image().write(to: folder.appendingPathComponent("off.png"))
        try await wait(1.2)
        XCTAssertTrue(line.items.isEmpty)
        line.setEnabled(true); try await wait(2.4)
        XCTAssertTrue(line.items.isEmpty, "Neither old pending callbacks nor off-period files may replay")
        try f.image().write(to: folder.appendingPathComponent("new.png"))
        try await wait(2.5)
        XCTAssertEqual(line.items.map { $0.url.lastPathComponent }, ["new.png"])
    }

    @MainActor func testScreenshotRecoveryFailureBlocksReenableAndRetryPreservesOffIntent() throws {
        let f = try Fixture(); defer { f.dispose() }
        let original = ScreenshotLinePrefs.Value(text: "/original"), owned = ScreenshotLinePrefs.Value(text: "/owned")
        try f.snapshot(original: original, owned: owned)
        f.capture["location"] = owned; f.rejectWrites = true
        let line = f.line(); defer { line.stop() }
        line.start(appName: "MS1Test", installUI: false)
        XCTAssertFalse(line.isEnabled); XCTAssertTrue(line.recoveryPending); XCTAssertNotNil(line.recoveryError)
        line.setEnabled(true); XCTAssertFalse(line.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("takeover-snapshot.json").path))
        f.rejectWrites = false; line.restoreTakeover()
        XCTAssertFalse(line.recoveryPending); XCTAssertNil(line.recoveryError); XCTAssertFalse(line.isEnabled)
        XCTAssertEqual(f.capture["location"], original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("takeover-snapshot.json").path))
        let writes = f.writes
        line.setEnabled(true)
        XCTAssertTrue(line.isEnabled); XCTAssertFalse(line.takeoverActive); XCTAssertEqual(f.writes, writes)
    }

    @MainActor func testScreenshotRecoveryNeverOverwritesThirdPartyAndSurvivesRestart() throws {
        let f = try Fixture(); defer { f.dispose() }
        let original = ScreenshotLinePrefs.Value(text: "/original")
        try f.snapshot(original: original, owned: .init(text: "/owned"))
        f.capture["location"] = .init(text: "/third-party")
        let line = f.line(); line.start(appName: "MS1Test", installUI: false)
        XCTAssertTrue(line.recoveryPending); XCTAssertEqual(f.writes, 0)
        line.stop()
        let reopened = f.line(); defer { reopened.stop() }
        reopened.start(appName: "MS1Test", installUI: false)
        XCTAssertTrue(reopened.recoveryPending); XCTAssertFalse(reopened.isEnabled)
        f.capture["location"] = original; reopened.restoreTakeover()
        XCTAssertFalse(reopened.recoveryPending); XCTAssertEqual(f.writes, 0)
    }

    @MainActor func testCorruptScreenshotRecoveryDoesNotDiscardCredentialsOrReportSuccess() throws {
        let f = try Fixture(); defer { f.dispose() }
        let url = f.root.appendingPathComponent("takeover-snapshot.json")
        let bytes = Data("invalid snapshot".utf8); try bytes.write(to: url)
        let line = f.line(); defer { line.stop() }
        line.start(appName: "MS1Test", installUI: false)
        XCTAssertFalse(line.isEnabled); XCTAssertTrue(line.recoveryPending)
        line.restoreTakeover()
        XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertEqual(f.writes, 0)
        XCTAssertNotNil(line.recoveryError)
    }

    func testWakeMasterOffDoesNotCompleteTasksOrResurrectManualTimer() {
        var engine = KeepAwakeEngine()
        let environment = KeepAwakeEngine.Environment(hardware: .desktop)
        engine.setAutomatic(true)
        let event = KeepAwakeEngine.Event(source: "codex-desktop", session: "real", sequence: 1, state: .running)
        XCTAssertTrue(engine.receive(event, now: 0))
        engine.stop()
        XCTAssertFalse(engine.evaluate(now: 100, environment: environment).hold)
        XCTAssertTrue(engine.sessions.values.contains(where: \.isUnfinished))
        XCTAssertEqual(engine.completionSleepPhase(now: 100, environment: environment), .inactive)
        engine.setEnabled(true)
        XCTAssertTrue(engine.evaluate(now: 101, environment: environment).hold)
        engine.startManual(minutes: 30, now: 102); engine.togglePause(now: 103)
        engine.setEnabled(false); engine.setEnabled(true)
        XCTAssertNil(engine.manualDeadline); XCTAssertNil(engine.pauseDeadline)
        XCTAssertFalse(engine.evaluate(now: 104, environment: environment).hold)
    }

    @MainActor func testWakePendingLeaseBlocksAllEnableEntrypointsAndRetriesWithoutReenabling() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let transport = MasterSwitchTransport()
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in },
            serviceStatus: { .enabled }, signingRequirement: { _ in "test" }, remoteProxyFactory: { _, _ in transport }, conflictReader: { nil })
        client.authorize(); try await wait(0.05)
        client.apply(hold: true); transport.renewReply?(true, "held"); try await wait(0.05)
        XCTAssertTrue(client.hasPendingRelease)
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        defer { service.shutdown() }
        service.setEnabled(false)
        transport.releaseReplies[0](false, "failed"); try await wait(0.05)
        service.tick()
        XCTAssertTrue(service.releasePending); XCTAssertFalse(service.canEnable)
        XCTAssertTrue(service.decision.title.contains("恢复失败"))
        service.setEnabled(true); service.automatic(true); service.manual(minutes: 30)
        XCTAssertFalse(service.engine.enabled)
        service.retryRelease()
        XCTAssertEqual(transport.releaseReplies.count, 2)
        transport.releaseReplies[1](true, "restored"); try await wait(0.05)
        service.tick()
        XCTAssertFalse(service.releasePending); XCTAssertFalse(service.engine.enabled)
        XCTAssertFalse(client.hasPendingRelease); XCTAssertTrue(service.canEnable)
        XCTAssertEqual(transport.renewCount, 1, "Retry must not obtain a new lease")
    }

    @MainActor func testMenusShareSettingsStateAndCannotBypassDisabledControls() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let line = f.line(); line.start(appName: "MS1Test", installUI: false); defer { line.stop() }
        let menu = NSMenu(); line.menuNeedsUpdate(menu)
        let master = try XCTUnwrap(menu.items.firstIndex { $0.title == "启用截图挂绳" })
        menu.performActionForItem(at: master)
        XCTAssertFalse(line.isEnabled)
        line.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items[master].state, .off)
        XCTAssertTrue(menu.items[master].isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "展开挂绳" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "接收剪贴板图片" }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == "打开截图挂绳设置" }).isEnabled)
        menu.performActionForItem(at: master)
        XCTAssertTrue(line.isEnabled)
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notRegistered })
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        defer { service.shutdown() }
        let controller = KeepAwakeMenuController(service: service)
        let wakeMenu = try XCTUnwrap(controller.item().submenu)
        let wakeMaster = try XCTUnwrap(wakeMenu.items.firstIndex { $0.title == "启用保持唤醒" })
        wakeMenu.performActionForItem(at: wakeMaster)
        XCTAssertTrue(service.engine.enabled)
        try await wait(0.15)
        XCTAssertEqual(wakeMenu.items[wakeMaster].state, .on)
        service.setEnabled(false); try await wait(0.15)
        XCTAssertEqual(wakeMenu.items[wakeMaster].state, .off)
        XCTAssertTrue(wakeMenu.items[wakeMaster].isEnabled)
        XCTAssertTrue(try XCTUnwrap(wakeMenu.items.first { $0.title == "管理保持唤醒…" }).isEnabled)
    }

    @MainActor func testMultipleWakeMenusStaySynchronizedWithoutReplacingTrackedRows() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notRegistered })
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        defer { service.shutdown() }
        let controller = KeepAwakeMenuController(service: service)
        let first = try XCTUnwrap(controller.item().submenu)
        let standalone = controller.makeMenu()
        let rebuiltMain = try XCTUnwrap(controller.item().submenu)
        let menus = [first, standalone, rebuiltMain]
        let originalRows = menus.map { $0.items.map(ObjectIdentifier.init) }
        func master(_ menu: NSMenu) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.first { $0.title == "启用保持唤醒" })
        }
        service.setEnabled(true); try await wait(0.15)
        for menu in menus { XCTAssertEqual(try master(menu).state, .on) }
        standalone.performActionForItem(at: try XCTUnwrap(standalone.items.firstIndex { $0.title == "启用保持唤醒" }))
        try await wait(0.15)
        for menu in menus {
            XCTAssertEqual(try master(menu).state, .off)
            XCTAssertTrue(try master(menu).isEnabled)
            controller.menuWillOpen(menu)
        }
        XCTAssertEqual(menus.map { $0.items.map(ObjectIdentifier.init) }, originalRows,
                       "A live/tracking menu must update in place, even after rebuilding another main menu")
        weak var transient: NSMenu?
        autoreleasepool { let menu = controller.makeMenu(); transient = menu }
        XCTAssertNil(transient, "Controller must not retain menus removed by App menu rebuilds")
    }

    @MainActor func testStandaloneWakeStatusItemIsIdempotentAndSurvivesModuleOff() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notRegistered })
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        defer { service.shutdown() }
        let controller = KeepAwakeMenuController(service: service)
        let item = controller.installStandaloneStatusItem()
        // A dedicated temporary status item, removed below; no installed App,
        // system permission, task or user preference is changed by this test.
        item.button?.setAccessibilityLabel("MS1 临时回归图标")
        defer { NSStatusBar.system.removeStatusItem(item) }
        XCTAssertTrue(item === controller.installStandaloneStatusItem())
        XCTAssertTrue(item.isVisible)
        XCTAssertNotNil(item.button?.image)
        let menu = try XCTUnwrap(item.menu)
        XCTAssertNotNil(menu.items.first { $0.title == "启用保持唤醒" })
        XCTAssertNil(menu.items.first { $0.title == "保持唤醒" }, "Standalone menu directly exposes actions")
        service.setEnabled(true); try await wait(0.15)
        service.setEnabled(false); try await wait(0.15)
        XCTAssertTrue(item === controller.installStandaloneStatusItem())
        XCTAssertTrue(item.isVisible, "Turning off the feature must keep its re-enable entry point")
        XCTAssertTrue(item.button?.toolTip?.contains("已关闭") == true)
        XCTAssertEqual(menu.items.first { $0.title == "启用保持唤醒" }?.state, .off)
    }

    @MainActor func testNativeSettingsRenderVisibleOffStateAndReadableTabs() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let line = f.line(); line.start(appName: "MS1Test", installUI: false); defer { line.stop() }
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in }, serviceStatus: { .notRegistered })
        let service = KeepAwakeService(defaults: f.defaults, root: f.root, codexAvailability: { false }, lidClient: client)
        defer { service.shutdown() }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/FeatureMasterSwitchesValidation/NativeViews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render<V: View>(_ view: V, name: String, width: CGFloat = 960) async throws {
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded(); try await wait(0.1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            try png.write(to: output.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await render(ScreenshotLineSettingsView(line: line), name: "screenshot-on")
        line.setEnabled(false)
        try await render(ScreenshotLineSettingsView(line: line), name: "screenshot-off")
        try await render(ScreenshotLineSettingsView(line: line), name: "screenshot-off-narrow", width: 640)
        service.setEnabled(true)
        try await render(KeepAwakeSettingsView(service: service).padding(24), name: "wake-on")
        service.setEnabled(false)
        for tab in 0...2 {
            try await render(KeepAwakeSettingsView(service: service, initialTab: tab).padding(24), name: "wake-off-tab-\(tab)")
        }
        try await render(KeepAwakeSettingsView(service: service).padding(24), name: "wake-off-narrow", width: 640)
    }

    @MainActor func testWakeNoOwnedLeaseRetryDoesNotContactHelper() {
        let transport = MasterSwitchTransport()
        let client = KeepAwakeLidClient(readEnabledIntent: { false }, saveEnabledIntent: { _ in },
            serviceStatus: { .notRegistered }, remoteProxyFactory: { _, _ in transport }, conflictReader: { nil })
        client.retryOwnedRelease()
        XCTAssertFalse(client.hasPendingRelease); XCTAssertTrue(transport.releaseReplies.isEmpty)
    }
}

private final class MasterSwitchTransport: NSObject, KeepAwakeHelperProtocol {
    var renewReply: ((Bool, String) -> Void)?
    var renewCount = 0
    var releaseReplies: [(Bool, String) -> Void] = []
    func status(reply: @escaping (Bool, String) -> Void) { reply(true, "ready") }
    func renew(owner: String, acOnly: Bool, minimumBattery: Int, respectLowPower: Bool, reply: @escaping (Bool, String) -> Void) {
        renewCount += 1; renewReply = reply
    }
    func release(owner: String, reply: @escaping (Bool, String) -> Void) { releaseReplies.append(reply) }
}
