import SwiftUI

struct BatteryExpandedView: View {
    @ObservedObject private var manager = BatteryManager.shared
    @EnvironmentObject var appState: AppState

    @ObservedObject private var control = BatteryManagementService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        let surface = AnyView(
            expandedContent)
        return AnyView(
            surface
                .opacity(manager.isLowBattery && appState.currentState != .fullExpanded ? pulseOpacity : 1.0)
                .background(control.display.reduceTransparency ? Color.black : Color.clear)
                .modifier(BatteryEntryInteraction(service: control))
                .onAppear {
                    control.setMetricsVisible("expanded", visible: true)
                    control.refreshTelemetry()
                    if manager.isLowBattery && !reduceMotion {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            pulseOpacity = 0.6
                        }
                    }
                }
                .onDisappear { control.setMetricsVisible("expanded", visible: false) })
    }

    private var expandedContent: AnyView {
        if appState.currentState == .fullExpanded { return AnyView(fullExpandedView) }
        if control.notice != nil { return AnyView(BatteryStartupNotice()) }
        return AnyView(defaultExpandedView)
    }

    private var defaultExpandedView: some View {
        HStack(spacing: 16) {
            BatteryEntryIcon(
                style: control.display.indicatorStyle, level: control.telemetry.level,
                charging: control.telemetry.charging, symbol: manager.batteryIconName
            )
            .scaleEffect(2).frame(width: 50, height: 35)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if control.display.showPercentage && control.display.popupFields.contains(.percentage) {
                        Text(manager.hasBattery ? "\(manager.batteryLevel)%" : "—")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    Spacer()

                    if control.display.popupFields.contains(.source) {
                        Text(manager.powerSource).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    }
                    Button {
                        control.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain).accessibilityLabel("电池设置")
                }

                batteryBar

                if control.runtimeMinutes != nil {
                    Text(control.metricTitle(.remaining) + " " + control.metricValue(.remaining))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    private var fullExpandedView: some View {
        BatteryManagementPanel()
    }

    private var batteryBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.15))

                RoundedRectangle(cornerRadius: 4)
                    .fill(batteryColor)
                    .frame(width: geometry.size.width * CGFloat(manager.batteryLevel) / 100)
                    .animation(.easeInOut(duration: 0.5), value: manager.batteryLevel)
            }
        }
        .frame(height: 8)
    }

    private var batteryColor: Color {
        if manager.isCharging { return .green }
        if manager.batteryLevel <= 10 { return .red }
        if manager.batteryLevel <= 20 { return .yellow }
        return .white
    }
}
