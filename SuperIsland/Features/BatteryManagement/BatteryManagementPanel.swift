import AppKit
import SwiftUI

struct BatteryManagementPanel: View {
    @ObservedObject private var service: BatteryManagementService
    @ObservedObject private var manager = BatteryManager.shared
    @State private var section = 0
    @State private var hours = 6

    @MainActor init(service: BatteryManagementService? = nil, initialSection: Int = 0) {
        let resolvedService = service ?? .shared
        self.service = resolvedService
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        let surface = AnyView(
            BatterySettingsStack(spacing: 7, rows: [header, sectionContent, failureLine], alignment: .center))
        let presentation0 = AnyView(
            surface
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear {
                    service.setMetricsVisible("island", visible: true)
                    service.refreshTelemetry()
                }
                .onDisappear { service.setMetricsVisible("island", visible: false) }
                .background(service.display.reduceTransparency ? Color.black : Color.clear)
                .opacity(service.display.opacity)
                .modifier(BatteryEntryInteraction(service: service)))
        return presentation0
    }
    // Each section keeps one concrete boundary instead of expanding its
    // entire controls/trend/overview type into every parent presentation.
    private var sectionContent: AnyView {
        if service.notice != nil { return AnyView(BatteryStartupNotice()) }
        switch section {
        case 1: return service.display.popupFields.contains(.controls) ? AnyView(controls) : AnyView(hiddenContent)
        case 2: return service.display.popupFields.contains(.trend) ? AnyView(trend) : AnyView(hiddenContent)
        default: return AnyView(overview)
        }
    }
    private var header: AnyView {
        AnyView(
            BatterySettingsRow(spacing: 10, rows: [
                AnyView(HStack(spacing: 5) {
                    BatteryEntryIcon(
                        style: service.display.indicatorStyle, level: service.telemetry.level, charging: service.telemetry.charging,
                        symbol: manager.batteryIconName)
                    if service.display.showPercentage && service.display.popupFields.contains(.percentage) {
                        Text(service.telemetry.level.map { "\($0)%" } ?? "—")
                            .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }),
                AnyView(Spacer(minLength: 4)),
                AnyView(AnyView(BatterySettingsRow(spacing: 2, rows: [
                    sectionButton("概览", value: 0, identifier: "battery-section-overview"),
                    sectionButton("充电", value: 1, identifier: "battery-section-control"),
                    sectionButton("趋势", value: 2, identifier: "battery-section-trend"),
                ]))
                .padding(2).frame(width: 192)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
                .accessibilityElement(children: .contain).accessibilityLabel("电池分区")
                .dataAnnotationID("si.bm.sections")),
                AnyView(Spacer(minLength: 4)),
                AnyView(Button {
                    service.openSettings()
                } label: {
                    Label("电池设置", systemImage: "gearshape")
                }
                .font(.system(size: 10)).buttonStyle(.plain).dataAnnotationID("si.bm.settings-entry")),
            ]))
    }
    private func sectionButton(_ title: String, value: Int, identifier: String) -> AnyView {
        AnyView(AnyView(Button {
            section = value
        } label: {
            AnyView(Text(title).font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(section == value ? 1 : 0.7))
                .frame(maxWidth: .infinity, minHeight: 23)
                .contentShape(Rectangle()))
        }
        .buttonStyle(.plain))
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(section == value ? 0.14 : 0)))
        .accessibilityLabel(title).accessibilityIdentifier(identifier)
        .accessibilityAddTraits(section == value ? .isSelected : []))
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            if service.display.popupFields.contains(.source) {
                HStack {
                    Text(batterySupplyDescription(service.telemetry))
                    Spacer()
                    Text(batteryChargingDescription(service.telemetry))
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }
            if service.display.metrics.isEmpty {
                Text("可在电池设置中选择仪表指标").font(.caption).frame(maxHeight: .infinity)
            } else {
                BatteryMetricGrid(service: service, compact: true).dataAnnotationID("si.bm.metrics")
            }
            statusLine
        }.dataAnnotationID("si.bm.overview")
    }
    private var hiddenContent: some View {
        VStack(spacing: 8) {
            Text("此内容已在电池显示设置中隐藏").font(.caption).foregroundStyle(.secondary)
            statusLine
        }.frame(maxHeight: .infinity)
    }
    private var controls: some View {
        BatterySettingsStack(spacing: 7, rows: [AnyView(BatteryChargeLimitSlider(service: service)), AnyView(BatteryManualControls(service: service)), statusLine])
            .dataAnnotationID("si.bm.control")
    }
    private var trend: some View {
        VStack(spacing: 3) {
            trendHeader
            BatteryTrendChart(samples: manager.batteryHistory, hours: hours, limit: service.preferences.limit)
                .frame(maxHeight: .infinity)
        }.dataAnnotationID("si.bm.history")
    }
    private var trendHeader: AnyView {
        AnyView(
            HStack {
                Text("真实电量 · 上限\(service.preferences.limit)%").font(.system(size: 10))
                Spacer()
                Picker("趋势时间范围", selection: $hours) {
                    Text("6小时").tag(6)
                    Text("12小时").tag(12)
                    Text("24小时").tag(24)
                }
                .labelsHidden().frame(width: 100).controlSize(.mini).dataAnnotationID("si.bm.history-range")
            })
    }
    private var statusLine: AnyView {
        let summary = service.report.message + " · " + batteryDischargeRouteDescription(service)
        return AnyView(Text(summary).font(.system(size: 9)).foregroundStyle(service.enabled ? .white.opacity(0.6) : .orange)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(summary).accessibilityLabel("控制状态：" + summary))
    }
    private var failureLine: AnyView {
        guard let failure = service.report.lastFailure else { return AnyView(EmptyView()) }
        return AnyView(
            Text("失败记录：" + failure).font(.system(size: 9)).foregroundStyle(.orange)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(failure)
                .accessibilityLabel("独立失败记录：" + failure))
    }

}

/// Both native surfaces submit through the same service and share mode confirmation semantics.
struct BatteryManualControls: View {
    @ObservedObject var service: BatteryManagementService
    var showAutomatic = false
    @State private var message: String?
    @State private var showDischarge = false
    @State private var dischargeTarget: Int
    @State private var pendingMode: BatteryControlMode?
    @State private var pendingTarget: Int?

    @MainActor init(service: BatteryManagementService, showAutomatic: Bool = false) {
        self.service = service
        self.showAutomatic = showAutomatic
        _dischargeTarget = State(initialValue: service.minimumDischargeTarget)
    }
    var body: some View {
        let presentation0 = modeButtons
        let presentation1 = AnyView(
            presentation0
                .alert("电池管理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(message ?? "")
                })
        let presentation2 = AnyView(
            presentation1
                .confirmationDialog(
                    "停止校准并切换模式", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("停止校准并恢复", role: .destructive) {
                        let next = pendingMode
                        let target = pendingTarget
                        pendingMode = nil
                        pendingTarget = nil
                        Task {
                            do {
                                _ = try await service.cancelCalibration()
                                guard !service.calibrationActive else {
                                    message = "正在恢复校准前设置，请等待恢复确认后再切换模式。"
                                    return
                                }
                                if let next { _ = try await service.execute(mode: next, target: target) }
                            } catch { message = error.localizedDescription }
                        }
                    }
                } message: {
                    Text("本次校准不会记录成功；原设置恢复确认后再执行所选模式。")
                })
        let presentation3 = AnyView(
            presentation2
                .popover(isPresented: $showDischarge) {
                    AnyView(AnyView(VStack(alignment: .leading, spacing: 12) {
                        Text("放电至目标电量").font(.headline)
                        Stepper("\(dischargeTarget)%", value: $dischargeTarget, in: service.minimumDischargeTarget...99)
                            .disabled(service.reviewTrialActive)
                        Text(dischargeDescription)
                            .font(.caption).foregroundStyle(.secondary)
                        if dischargeTarget < service.minimumDischargeTarget {
                            Text("当前通道最低\(service.minimumDischargeTarget)%，原目标\(dischargeTarget)%未自动修改。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("取消") { showDischarge = false }
                            Spacer()
                            Button("开始放电") {
                                showDischarge = false
                                run(.discharge, target: dischargeTarget)
                            }
                            .disabled(dischargeTarget < service.minimumDischargeTarget || dischargeTarget >= (service.telemetry.level ?? 0))
                        }
                    }).padding(18).frame(width: 290))
                })
        return presentation3
    }
    private var modeButtons: AnyView {
        AnyView(
            AnyView(BatterySettingsRow(spacing: 9, rows: [
                AnyView(Button(service.mode == .discharge ? "停止放电" : "放电…") {
                    if service.mode == .discharge {
                        run(.automatic)
                    } else {
                        let minimum = service.minimumDischargeTarget
                        dischargeTarget =
                            service.reviewTrialActive
                            ? 80 : max(minimum, min(99, min(service.preferences.limit, (service.telemetry.level ?? (minimum + 1)) - 1)))
                        showDischarge = true
                    }
                }.disabled(
                    service.mode == .discharge
                        ? !service.canStopDischarge
                        : !service.canControl || !service.telemetry.adapterPresent || !service.report.dischargeSupported
                ).dataAnnotationID("si.bm.discharge")),
                AnyView(Button(service.mode == .topUp ? "停止充满" : "充满") { run(service.mode == .topUp ? .automatic : .topUp) }
                    .disabled(!service.canControl || !service.telemetry.adapterPresent || service.reviewTrialActive).dataAnnotationID(
                        "si.bm.top-up")),
                AnyView(Button(service.pauseRefreshPending ? "取消暂停并恢复" : service.mode == .paused ? "恢复充电" : "暂停充电") { run(service.mode == .paused ? .automatic : .paused) }
                    .disabled(service.mode == .paused ? !service.canResumeCharging : !service.canPauseCharging)
                    .help(service.mode != .paused && !service.report.capabilities.canPause(at: service.telemetry.level)
                        ? "当前电量或控制通道尚无法确认临时暂停充电。" : "临时暂停或恢复充电，保留长期上限。")
                    .dataAnnotationID("si.bm.pause")),
                AnyView(Group {
                    if showAutomatic {
                        Button("恢复自动") { run(.automatic) }
                            .disabled(service.mode == .automatic && !service.calibrationActive)
                    }
                }),
                AnyView(Spacer()),
                AnyView(Text(service.calibrationActive ? "校准" : service.mode.title).font(.system(size: 10)).foregroundStyle(.secondary)),
            ])).buttonStyle(.bordered).controlSize(.small)
                .disabled(!service.canControl && !service.canStopDischarge && !service.canCancelPauseRefresh).dataAnnotationID("si.bm.mode"))
    }
    private var dischargeDescription: String {
        batteryDischargeRouteDescription(service) + "；达到目标后恢复原来的长期上限，需持续接入适配器。"
    }
    private func run(_ mode: BatteryControlMode, target: Int? = nil) {
        if service.calibrationActive {
            pendingTarget = target
            pendingMode = mode
            return
        }
        Task { do { _ = try await service.execute(mode: mode, target: target) } catch { message = error.localizedDescription } }
    }
}

func batterySupplyDescription(_ telemetry: BatteryTelemetry) -> String {
    guard telemetry.hasBattery else { return "电池读数不可用" }
    guard let supplied = telemetry.powerSupplyObservation else { return "供电状态未知" }
    return supplied ? "电源适配器" : "电池供电"
}

struct BatteryChargeLimitSlider: View {
    @ObservedObject private var service: BatteryManagementService
    @State private var draft = 80.0
    @State private var editing = false
    @State private var showLowLimit = false
    @State private var error: String?
    @MainActor init(service: BatteryManagementService? = nil) { self.service = service ?? .shared }
    var body: some View {
        let surface = AnyView(
            HStack(spacing: 10) {
                Text("充电上限").font(.system(size: 11))
                Slider(
                    value: $draft, in: 20...(service.reviewTrialActive ? 85 : 100), step: 1,
                    onEditingChanged: { active in
                        editing = active
                        if !active { commit() }
                    }
                ).accessibilityLabel("充电上限").accessibilityValue("\(Int(draft))%")
                Text("\(Int(draft))%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().frame(
                    width: 38, alignment: .trailing)
            })
        let presentation0 = AnyView(
            surface
                .disabled(!service.canControl || service.calibrationActive)
                .onAppear { draft = Double(service.preferences.limit) }
                .onChange(of: service.preferences.limit) { _, value in if !editing { draft = Double(value) } })
        let presentation1 = AnyView(
            presentation0
                .modifier(BatteryLowLimitPrompt(service: service, isPresented: $showLowLimit)))
        let presentation2 = AnyView(
            presentation1
                .alert("无法设置上限", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(error ?? "")
                })
        return presentation2
    }
    private func commit() {
        let value = Int(draft)
        if value < 80 && !service.preferences.allowLowLimit {
            draft = Double(service.preferences.limit)
            showLowLimit = true
            return
        }
        do { try service.updatePreferences { $0.limit = value } } catch {
            self.error = error.localizedDescription
            draft = Double(service.preferences.limit)
        }
    }
}

struct BatteryStartupNotice: View {
    @ObservedObject private var service = BatteryManagementService.shared
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false
    private enum Focus: Hashable { case settings, close }
    @FocusState private var focused: Focus?
    var body: some View {
        let surface = AnyView(
            HStack(spacing: 10) {
                Image(systemName: service.enabled ? "checkmark.shield" : "exclamationmark.triangle").foregroundStyle(
                    service.enabled ? .green : .orange)
                noticeSettingsButton
                noticeCloseButton
            })
        let presentation0 = AnyView(
            surface
                .padding(.vertical, 5)
                .onHover { hovering = $0 }
                .task(id: service.notice) {
                    guard service.notice != nil else { return }
                    var remaining = service.enabled ? 5 : 8
                    while remaining > 0 {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        if !hovering && !appState.isHovering && focused == nil { remaining -= 1 }
                    }
                    service.closeNotice()
                }.dataAnnotationID("si.bm.startup-notice"))
        return presentation0
    }
    private var noticeSettingsButton: AnyView {
        AnyView(
            Button {
                service.closeNotice()
                service.openSettings()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.enabled ? "充电控制已启用" : "充电控制尚未启用").font(.system(size: 12, weight: .semibold))
                    Text(service.notice ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).focused($focused, equals: .settings))
    }
    private var noticeCloseButton: AnyView {
        AnyView(
            Button {
                service.closeNotice()
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.plain).focused($focused, equals: .close).accessibilityLabel("收起充电提示"))
    }

}

struct BatteryTrendChart: View {
    let samples: [BatteryHistorySample]
    let hours: Int
    let limit: Int
    private var filtered: [BatteryHistorySample] { samples.filter { $0.timestamp >= Date().addingTimeInterval(-Double(hours) * 3600) } }
    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy -> AnyView in
                if filtered.count < 2 {
                    return AnyView(
                        Text("样本不足；不补造历史电量").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity))
                } else {
                    return AnyView(
                        ZStack {
                            Path { p in
                                let y = proxy.size.height * (1 - Double(limit) / 100)
                                p.move(to: CGPoint(x: 0, y: y))
                                p.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            }.stroke(.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            Path { p in
                                let start = Date().addingTimeInterval(-Double(hours) * 3600)
                                var previous: BatteryHistorySample?
                                for sample in filtered {
                                    let x = sample.timestamp.timeIntervalSince(start) / (Double(hours) * 3600) * proxy.size.width
                                    let y = (1 - Double(sample.level) / 100) * proxy.size.height
                                    let point = CGPoint(x: max(0, min(proxy.size.width, x)), y: y)
                                    if let previous, sample.sessionID == previous.sessionID,
                                        sample.timestamp.timeIntervalSince(previous.timestamp) <= 660
                                    {
                                        p.addLine(to: point)
                                    } else {
                                        p.move(to: point)
                                    }
                                    previous = sample
                                }
                            }.stroke(.green, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        })
                }
            }
            Text(
                filtered.first.map { "已有样本从\($0.timestamp.formatted(date: .omitted, time: .shortened))开始 · 间断处不连线" } ?? "每5分钟保存一次；保留最近48小时"
            )
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }.accessibilityLabel("电池真实历史，\(filtered.count)个样本，目标上限\(limit)%")
    }
}

/// Intercept only secondary clicks; all primary clicks keep the island's
/// existing navigation and slider/button hit testing.
struct BatteryEntryInteraction: ViewModifier {
    let service: BatteryManagementService
    @State private var error: String?
    func body(content: Content) -> AnyView {
        AnyView(
            AnyView(content).overlay(
                BatteryRightClickSurface {
                    switch service.display.rightClickAction {
                    case .settings: service.openSettings()
                    case .same: AppState.shared.open()
                    case .pause:
                        guard !service.calibrationActive else {
                            error = "校准期间不能直接暂停，请先在电池设置中停止校准。"
                            return
                        }
                        Task {
                            do { _ = try await service.execute(mode: service.mode == .paused ? .automatic : .paused) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
            )
            .alert("电池管理", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(error ?? "")
            })
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

struct BatteryMetricGrid: View {
    @ObservedObject var service: BatteryManagementService
    let compact: Bool
    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: compact ? 7 : 12
        ) {
            ForEach(service.display.metrics) { metric in
                BatteryMetricReadout(
                    title: service.metricTitle(metric), value: service.metricValue(metric),
                    help: metric == .averagePower
                        ? service.averagePowerDescription
                        : metric == .systemInput || metric == .systemLoad ? "系统最近报告的功率，采样时刻与窗口未知；不是适配器额定值。" : metric.title,
                    compact: compact)
            }
        }
    }
}
private struct BatteryMetricReadout: View {
    let title: String
    let value: String
    let help: String
    let compact: Bool
    var body: some View {
        let caption = Text(title).font(compact ? .system(size: 10) : .caption).foregroundStyle(
            compact ? Color.white.opacity(0.55) : Color.secondary)
        let number = Text(value).font(compact ? .system(size: 12, weight: .medium, design: .rounded) : nil).monospacedDigit().help(help)
        let content: AnyView =
            compact
            ? AnyView(
                HStack(spacing: 7) {
                    caption
                    number
                }.lineLimit(1).minimumScaleFactor(0.8))
            : AnyView(
                VStack(alignment: .leading, spacing: 3) {
                    caption
                    number
                })
        return content.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 0 : 10)
            .background(.white.opacity(compact ? 0 : 0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct BatteryLowLimitPrompt: ViewModifier {
    @ObservedObject var service: BatteryManagementService
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content
            .alert("低充电限值", isPresented: $isPresented) {
                Button("取消", role: .cancel) {}
                Button("打开设置") {
                    service.focusLowLimit = true
                    service.openSettings()
                }
            } message: {
                Text(!service.report.capabilities.lowLimits
                    ? "当前控制通道尚未接通低于80%的限充，设置中的低值开关暂不可启用。原上限保持不变，可打开电池设置查看能力说明。"
                    : "默认最低80%。如需更低的长期上限，请先在电池设置中开启“允许充电至低于80%”。")
            }
    }
}

@MainActor
func batteryDischargeRouteDescription(_ service: BatteryManagementService) -> String {
    switch service.report.dischargeMechanism {
    case .nativeLimit: return "系统原生限值放电（不主动断供），最低\(service.minimumDischargeTarget)%"
    case .adapterCutoff: return "主动断供放电，最低\(service.minimumDischargeTarget)%"
    case nil: return "放电通道尚未确认"
    }
}

func batteryChargingDescription(_ telemetry: BatteryTelemetry) -> String {
    guard let charging = telemetry.chargingObservation else { return "充电状态未知" }
    return charging ? "正在充电" : "当前未充电"
}
