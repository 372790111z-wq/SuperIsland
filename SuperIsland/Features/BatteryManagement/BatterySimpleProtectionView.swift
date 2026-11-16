import SwiftUI

/// Both native entry points share the service's draft, request and readback.
struct BatterySimpleProtectionView: View {
    @ObservedObject var service: BatteryManagementService
    @ObservedObject private var battery = BatteryManager.shared
    var surface: String
    @State private var confirmOff = false
    @State private var dischargeSheet = false
    @State private var dischargeDraft = "80"
    @State private var error: String?
    @State private var authorizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if battery.presence == .absent && !service.simpleRecoveryPending {
                Label("此设备没有内置电池，无需电池保护。", systemImage: "powerplug")
                    .foregroundStyle(.secondary)
            } else {
                summary
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("电池保护").font(.headline)
                        Text(service.protectionRequested ? "充电上限 \(service.preferences.limit)%" : "关闭后重启也保持关闭")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("电池保护", isOn: Binding(get: { service.protectionRequested }, set: { value in
                        if value { service.setEnabled(true) } else { confirmOff = true }
                    })).labelsHidden().toggleStyle(.switch)
                        .disabled(service.busy || service.authorizing || (service.simpleRecoveryPending && !service.protectionRequested))
                        .dataAnnotationID("si.bm.simple.enabled")
                }
                limit
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.mode == .discharge ? "放电至 \(service.simpleDischargeTarget ?? 80)%" : "主动放电").font(.headline)
                        Text(service.mode == .discharge ? "停止后恢复上限管理" : service.simpleDischargeReason)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(service.mode == .discharge ? "停止放电" : "开始放电") {
                        if service.mode == .discharge { run { _ = try await service.execute(mode: .automatic) } }
                        else {
                            dischargeDraft = String(max(service.minimumDischargeTarget, min(service.preferences.limit, (service.telemetry.level ?? 81) - 1)))
                            error = nil; dischargeSheet = true
                        }
                    }.disabled(service.mode == .discharge ? !service.canStopDischarge : !service.simpleCanDischarge)
                        .dataAnnotationID(service.mode == .discharge ? "si.bm.simple.stop-discharge" : "si.bm.simple.discharge")
                }
                notices
            }
        }
        .onAppear { service.setMetricsVisible(surface, visible: true); service.refreshTelemetry() }
        .onDisappear { service.setMetricsVisible(surface, visible: false) }
        .confirmationDialog("关闭电池保护？", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("关闭并恢复") { service.setEnabled(false) }
            Button("取消", role: .cancel) {}
        } message: { Text("将停止主动放电并解除 SuperIsland 的限制。关闭后重启也不会自动开启；恢复结果会显示在本页。") }
        .confirmationDialog("授权电池保护", isPresented: $authorizing, titleVisibility: .visible) {
            Button("继续系统授权") { Task { await service.authorize() } }
            Button("取消", role: .cancel) {}
        } message: { Text("需要注册 SuperIsland 自有辅助程序才能控制充电。已有控制必须先恢复；系统批准由你本人完成。只有已明确开启保护时，授权成功后才会继续启用。") }
        .sheet(isPresented: $dischargeSheet) { dischargeDialog }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Image(systemName: service.telemetry.charging ? "battery.75percent.bolt" : "battery.75percent")
                .font(.system(size: 28)).foregroundStyle(.green)
            Text(service.telemetry.level.map { "\($0)%" } ?? "—").font(.system(size: 30, weight: .semibold, design: .rounded))
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(battery.presence == .unknown ? "电池信息暂不可用" : service.simpleStatus).font(.caption).foregroundStyle(service.enabled ? Color.green : .secondary)
                Text(batterySupplyDescription(service.telemetry)).font(.caption2).foregroundStyle(.secondary)
                Text(batteryChargingDescription(service.telemetry)).font(.caption2).foregroundStyle(.secondary)
            }
        }.dataAnnotationID("si.bm.simple.status")
    }
    private var limit: some View {
        VStack(spacing: 9) {
            HStack { Text("充电上限"); Spacer(); Text("\(service.limitDraft)%").monospacedDigit() }
            Slider(value: Binding(get: { Double(service.limitDraft) }, set: { service.limitDraft = Int($0) }), in: 80...100, step: 1)
                .disabled(!service.simpleCanEdit || service.mode == .discharge)
                .accessibilityLabel("充电上限").dataAnnotationID("si.bm.simple.limit")
            HStack { Text("80%"); Spacer(); Text("100%") }.font(.caption2).foregroundStyle(.secondary)
            if service.limitDraft != service.preferences.limit || service.simple.needsLimitChoice {
                HStack {
                    Text(service.protectionRequested ? "尚未应用" : "仅保存，开启后生效").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(service.protectionRequested ? "应用" : "保存") { run { try await service.applySimpleLimit() } }
                        .disabled(!service.simpleCanEdit || service.mode == .discharge)
                        .dataAnnotationID("si.bm.simple.apply-limit")
                }
            }
        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private var notices: some View {
        if service.busy { ProgressView("正在确认操作结果…").controlSize(.small) }
        if service.simpleRecoveryPending || service.simple.needsLimitChoice || (service.protectionRequested && !service.enabled) || error != nil {
            VStack(alignment: .leading, spacing: 7) {
                Text(error ?? (service.simple.needsLimitChoice ? "原上限暂不支持，请重新选择并保存。" : service.report.message))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("重新检查 / 重试") { error = nil; Task { await service.recheckStatus() } }
                    .disabled(service.busy || service.authorizing).dataAnnotationID("si.bm.simple.retry")
            }.accessibilityElement(children: .contain).dataAnnotationID("si.bm.simple.notice")
        }
        if service.report.protocolVersion != BatteryControlReport.currentProtocolVersion || !service.report.available && !service.enabled {
            HStack {
                Text(service.authorizationDescription).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("设置权限") { authorizing = true }.disabled(service.authorizing || service.busy)
            }
        }
    }
    private var dischargeDialog: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("主动放电").font(.title3.bold())
            Text("接着电源，将电量降低到指定目标。你可以随时停止。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("放电至")
                TextField("目标百分比", text: $dischargeDraft).frame(width: 70)
                    .dataAnnotationID("si.bm.simple.discharge-target")
                Text("%")
            }
            Text("目标需低于当前电量，最低 \(max(20, service.minimumDischargeTarget))%。结束后恢复 \(service.preferences.limit)% 上限管理；目标更低时可能重新充电。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dischargeSheet = false; error = nil }.keyboardShortcut(.cancelAction)
                Button("开始放电") {
                    guard let target = Int(dischargeDraft), target >= max(20, service.minimumDischargeTarget),
                          let current = service.telemetry.level, target < current else {
                        error = "请输入低于当前电量的有效整数目标。"; return
                    }
                    dischargeSheet = false
                    run { _ = try await service.execute(mode: .discharge, target: target) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 360)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

func batterySupplyDescription(_ telemetry: BatteryTelemetry) -> String {
    guard telemetry.hasBattery else { return "电池读数不可用" }
    guard let supplied = telemetry.powerSupplyObservation else { return "供电状态未知" }
    return supplied ? "电源适配器" : "电池供电"
}
func batteryChargingDescription(_ telemetry: BatteryTelemetry) -> String {
    guard let charging = telemetry.chargingObservation else { return "充电状态未知" }
    return charging ? "正在充电" : "当前未充电"
}
