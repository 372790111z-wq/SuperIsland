import AppKit
import SwiftUI
import XCTest
@testable import SuperIsland

@MainActor
final class BatteryStatusAccessibilityTests: XCTestCase {
    func testSelectableFailureLabelAndValueRemainIndependentAcrossUpdates() {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        for index in 0..<500 {
            let text = index % 2 == 0 ? "失败记录：PID身份未确认（errno=3） \(index)" : "恢复已确认 \(index)"
            BatteryStatusText.update(field, text: text, failure: index % 2 == 0)
            XCTAssertEqual(field.accessibilityLabel(), text)
            XCTAssertEqual(field.accessibilityValue() as? String, text)
            XCTAssertTrue(field.isSelectable)
        }
    }
    func testHostedStatusAndFailureAccessibilityTraversal() async throws {
        let host = NSHostingView(rootView: VStack {
            BatteryStatusText(text: "恢复已确认")
            BatteryStatusText(text: "失败记录：PID身份未确认（errno=3）", failure: true)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        var labels = Set<String>(), seen = Set<ObjectIdentifier>()
        func walk(_ item: Any, depth: Int = 0) -> Int {
            guard let node = item as? NSObject else { return 0 }
            guard seen.insert(ObjectIdentifier(node)).inserted else { return 0 }
            guard depth < 32 else { XCTFail("Accessibility tree contains a cycle"); return 0 }
            // SwiftUI's private AX nodes expose ObjC accessibility selectors
            // without formally conforming to NSAccessibilityProtocol.
            func read(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue()
            }
            if let label = read("accessibilityLabel") as? String { labels.insert(label) }
            _ = read("accessibilityValue")
            let children = (read("accessibilityChildren") as? [Any] ?? []) + ((node as? NSView)?.subviews ?? [])
            return 1 + children.reduce(0) { $0 + walk($1, depth: depth + 1) }
        }
        for _ in 0..<100 { seen.removeAll(); XCTAssertGreaterThan(walk(host), 0) }
        XCTAssertTrue(labels.contains("失败记录：PID身份未确认（errno=3）"))
        XCTAssertTrue(labels.contains("恢复已确认"))
    }
}
