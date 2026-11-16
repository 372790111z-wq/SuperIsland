import SwiftUI

struct BatteryManagementSettingsView: View {
    @ObservedObject private var service: BatteryManagementService
    @MainActor init(service: BatteryManagementService? = nil) { self.service = service ?? .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("电池保护").font(.system(size: 22, weight: .bold))
            Text("管理充电上限，需要时主动放电。").foregroundStyle(.secondary)
            BatterySimpleProtectionView(service: service, surface: "settings")
        }.accessibilityElement(children: .contain).dataAnnotationID("si.bm.simple.settings")
    }
}

struct BatterySettingsStack: View {
    let spacing: CGFloat
    let rows: [AnyView]
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
    }
}

// Fixed-position rows share one concrete layout. Controls keep their original
// bindings and parent-owned state; conditional-size rows retain their builders.
struct BatterySettingsRow: View {
    var spacing: CGFloat? = nil
    let rows: [AnyView]
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
    }
}
