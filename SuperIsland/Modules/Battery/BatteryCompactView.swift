import SwiftUI

struct BatteryCompactView: View {
    @ObservedObject private var manager = BatteryManager.shared
    @ObservedObject private var control = BatteryManagementService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let surface = AnyView(
            HStack(spacing: CGFloat(control.display.indicatorSpacing)) {
                BatteryEntryIcon(
                    style: control.display.indicatorStyle, level: control.telemetry.level,
                    charging: control.telemetry.charging, symbol: manager.batteryIconName
                )
                .symbolEffect(.pulse, isActive: manager.isLowBattery && !reduceMotion)
                ForEach(control.display.entryStatistics.filter { $0 != .percentage || control.display.showPercentage }) { statistic in
                    Text(control.entryValue(statistic))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white).lineLimit(1)
                }
            })
        return AnyView(
            surface
                .lineLimit(1).minimumScaleFactor(0.8)
                .help(
                    control.display.entryStatistics.filter { $0 != .percentage || control.display.showPercentage }.map {
                        $0.title + "：" + control.entryValue($0)
                    }.joined(separator: " · ")
                )
                .modifier(BatteryEntryInteraction(service: control))
                .onAppear {
                    control.setMetricsVisible("compact", visible: true)
                    control.refreshTelemetry()
                }
                .onDisappear { control.setMetricsVisible("compact", visible: false) })
    }

}

struct BatteryEntryIcon: View {
    let style: BatteryIndicatorStyle
    let level: Int?
    let charging: Bool
    let symbol: String
    private var color: Color { charging ? .green : (level ?? 100) <= 10 ? .red : (level ?? 100) <= 20 ? .yellow : .green }
    var body: AnyView {
        let content: AnyView
        if style == .ios {
            content = AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.8), lineWidth: 1).frame(width: 22, height: 12)
                    iosFill
                    if charging && level != nil { Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.black) }
                }.frame(width: 25, height: 14))
        } else {
            content = AnyView(
                Image(systemName: level == nil ? "battery.0percent" : symbol).font(.system(size: 14))
                    .foregroundStyle(style == .colored && level != nil ? color : .white)
                    .overlay { if level == nil { Text("?").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) } })
        }
        return AnyView(content.accessibilityLabel(level == nil ? "电池电量未知" : "电池"))
    }
    private var iosFill: AnyView {
        if let level {
            return AnyView(
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: proxy.size.width * CGFloat(min(100, max(0, level))) / 100)
                }.frame(width: 18, height: 8))
        }
        return AnyView(Text("?").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
    }
}
