import AppKit
import SwiftUI

/// Keep selectable status text's accessibility value in AppKit. SwiftUI's
/// label resolution was recursive in the observed crash; the exact triggering
/// view was not recoverable from the stack. Do not place a SwiftUI label
/// override around this representable: the field owns its label and value.
struct BatteryStatusText: NSViewRepresentable {
    var text: String
    var failure = false

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        Self.update(field, text: text, failure: failure)
    }
    static func update(_ field: NSTextField, text: String, failure: Bool) {
        field.stringValue = text
        field.font = .systemFont(ofSize: failure ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        field.textColor = failure ? .systemOrange : .labelColor
        field.setAccessibilityLabel(text)
        field.setAccessibilityIdentifier(failure ? "si.bm.failure-record" : "si.bm.control-status")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(1, size?.height ?? nsView.intrinsicContentSize.height))
    }
}
