import AppKit
import SwiftUI

struct BatteryManagementPanel: View {
    @ObservedObject private var service: BatteryManagementService
    @MainActor init(service: BatteryManagementService? = nil, initialSection: Int = 0) {
        self.service = service ?? .shared
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BatterySimpleProtectionView(service: service, surface: "island")
                HStack { Spacer(); Button("电池设置 ↗") { service.openSettings() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .dataAnnotationID("si.bm.simple.settings-entry") }
            }.padding(.horizontal, 22).padding(.vertical, 12)
        }
        // The island has a fixed black surface even when macOS uses light mode.
        // Scope semantic text and control colors here, not on the shared settings view.
        .environment(\.colorScheme, .dark)
        .dataAnnotationID("si.bm.simple.panel")
    }
}

/// Preserve the entry's settings action without any hidden power command.
struct BatteryEntryInteraction: ViewModifier {
    let service: BatteryManagementService
    func body(content: Content) -> some View {
        content.overlay(BatteryRightClickSurface { service.openSettings() })
    }
}
private struct BatteryRightClickSurface: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }
    func updateNSView(_ view: SecondaryClickView, context: Context) { view.action = action }
    final class SecondaryClickView: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { action() }
    }
}
