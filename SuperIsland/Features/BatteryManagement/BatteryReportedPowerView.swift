import SwiftUI

struct BatteryReportedPowerView: View {
    var state: BatteryReportedPowerWindow.State
    var supply: Bool?
    var body: some View {
        GroupBox("电源流向") {
            BatterySettingsStack(
                spacing: 10,
                rows: [
                    AnyView(Text("最近系统功率报告").font(.subheadline.weight(.medium))),
                    readings,
                    AnyView(Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)),
                    readTimes,
                ]
            ).padding(8)
        }.dataAnnotationID("si.bm.power-report")
    }
    private var readings: AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 14) {
                reading("系统输入", channel: .input)
                reading("系统报告负载", channel: .load)
                reading("电池报告功率", channel: .battery)
            })
    }
    private var readTimes: AnyView {
        guard let report = state.report else { return AnyView(EmptyView()) }
        return AnyView(
            BatterySettingsStack(
                spacing: 10,
                rows: [
                    AnyView(
                        Text("读取于\(report.readAt.formatted(date: .omitted, time: .standard))；功率采样时刻未提供，暂不展示实时流向。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)),
                    reportChangeTime,
                ]))
    }
    private var reportChangeTime: AnyView {
        guard let changed = state.lastNewReportObservedAt else { return AnyView(EmptyView()) }
        return AnyView(
            Text("观察到新报告：\(changed.formatted(date: .omitted, time: .standard))。这不是传感器采样时间。")
                .font(.caption).foregroundStyle(.secondary))
    }
    private func reading(_ title: String, channel: BatteryReportedPower.Channel) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(state.report?.formatted(channel) ?? "—").font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine))
    }
    private var explanation: String {
        guard let report = state.report else { return "系统尚未提供功率报告；缺失读数保持未知。" }
        if report.readExpired(at: Date()) { return "最近一次读取已超过时限，显示的是上次报告；请刷新读数。" }
        if !report.complete { return "部分功率读数缺失或异常，保留可读取的数值，不推导缺失数据。" }
        if report.contradictsSupply(supply) { return "报告与当前供电状态不一致，可能仍是旧数据；无法判断实时流向。" }
        if report.inconsistent { return "报告中的功率存在差异，保留原数值，不据此推导流向。" }
        return "系统报告可能延迟；按已核对的功率量纲换算为约数。电池正值表示报告充入、负值表示报告放出，适配器额定值另列。"
    }
}
