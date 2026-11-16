import AppKit
import SwiftUI
import XCTest
@testable import SuperIsland

final class KeepAwakeCompletionCompatibilityTests: XCTestCase {
    func testLegacyCompletionPreferencePreservesAllOtherSettingsAndRollbackShape() throws {
        for flag in [true, false] {
            let old = Data("{\"acOnly\":false,\"minimumBattery\":35,\"respectLowPower\":false,\"screen\":\"off\",\"notifyCompletion\":\(flag)}".utf8)
            let prefs = try JSONDecoder().decode(KeepAwakeEngine.Preferences.self, from: old)
            XCTAssertFalse(prefs.acOnly); XCTAssertEqual(prefs.minimumBattery, 35)
            XCTAssertFalse(prefs.respectLowPower); XCTAssertEqual(prefs.screen, .off)
            let saved = try JSONEncoder().encode(prefs)
            let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            XCTAssertEqual(shape["notifyCompletion"] as? Bool, flag, "Older builds must still decode a saved preference object")
            XCTAssertEqual(try JSONDecoder().decode(KeepAwakeEngine.Preferences.self, from: saved), prefs)
        }
    }
    func testLegacyReminderFlagDoesNotChangeCompletionOrReleaseForAnySource() {
        for flag in [true, false] {
            for hardware in [KeepAwakeEngine.Environment.Hardware.notebook, .desktop, .unknown] {
                for source in KeepAwakeSource.all {
                    var engine = KeepAwakeEngine(); engine.preferences.notifyCompletion = flag
                    engine.setAutomatic(true)
                    let environment = KeepAwakeEngine.Environment(hardware: hardware, battery: 80, onAC: true)
                    let start = KeepAwakeEngine.Event(source: source.id, session: "session", sequence: 1,
                        state: .running, taskID: "task", startsTask: true)
                    let done = KeepAwakeEngine.Event(source: source.id, session: "session", sequence: 2,
                        state: .completed, taskID: "task", startsTask: false)
                    XCTAssertTrue(engine.receive(start, now: 0))
                    XCTAssertTrue(engine.receive(done, now: 1))
                    XCTAssertEqual(engine.sessions[done.storageKey]?.event.state, .completed)
                    XCTAssertFalse(engine.receive(done, now: 2), "Repeated terminal events must not create another completion")
                    XCTAssertEqual(engine.evaluate(now: 2, environment: environment).hold, hardware != .unknown)
                    XCTAssertFalse(engine.evaluate(now: 32, environment: environment).hold)
                }
            }
        }
    }
    @MainActor func testNativeSettingsExplainResultsWithoutReminderOrPermissionControls() async throws {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        for hardware in [KeepAwakeEngine.Environment.Hardware.notebook, .desktop, .unknown] {
            let name = "KA1CompletionUI-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let service = KeepAwakeService(defaults: defaults, root: root,
                environmentReader: { .init(hardware: hardware, battery: 80, onAC: true) })
            service.tick() // Master remains off: never acquire a power assertion.
            defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
            let host = NSHostingView(rootView: KeepAwakeSettingsView(service: service, initialTab: 2))
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            var seen = Set<ObjectIdentifier>(), values = Set<String>()
            func visit(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                for key in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    let selector = NSSelectorFromString(key)
                    if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String { values.insert(value) }
                }
                let children = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: children), let list = object.perform(children)?.takeUnretainedValue() as? [NSObject] { list.forEach(visit) }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            for _ in 0..<40 {
                seen.removeAll(); values.removeAll(); host.layoutSubtreeIfNeeded(); visit(window); visit(host)
                if values.contains("data-annotation-id=si.ka.completion-info") { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            if hardware == .desktop {
                XCTAssertFalse(values.contains(where: { $0.contains("合盖") || $0.contains("开盖") }))
                let menu = KeepAwakeMenuController(service: service).item().submenu
                XCTAssertNotNil(menu)
                XCTAssertFalse(menu?.items.contains(where: { !$0.isHidden && ($0.title.contains("合盖") || $0.title.contains("开盖")) }) ?? true)
            }
            XCTAssertTrue(values.contains("data-annotation-id=si.ka.completion-info"))
            XCTAssertFalse(values.contains("data-annotation-id=si.ka.notify"))
            XCTAssertFalse(values.contains("任务完成提醒")); XCTAssertFalse(values.contains("申请通知权限"))
            XCTAssertFalse(service.actualHold)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("SuperIslandCompletionUI")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(hardware).png"))
        }
    }

}
