import AppKit
import SwiftUI

private enum BatterySettingsSection: String, CaseIterable, Identifiable {
    case dashboard = "仪表板"
    case charge = "充电控制"
    case sleep = "睡眠行为"
    case energy = "能源使用"
    case schedule = "定时设置"
    case shortcuts = "捷径"
    case display = "显示与面板"
    case other = "其他"
    var id: String { rawValue }
}

struct BatteryManagementSettingsView: View {
    @ObservedObject private var service: BatteryManagementService
    @ObservedObject private var manager = BatteryManager.shared
    @ObservedObject private var schedules = BatteryScheduleService.shared
    @State private var section = BatterySettingsSection.dashboard
    @State private var limitDraft = "80"
    @State private var showLowLimit = false
    @State private var message: String?
    @State private var authorize = false
    @State private var confirmCalibrationStart = false
    @State private var confirmCalibrationStop = false
    @State private var confirmRaiseLimit = false
    @State private var confirmDefaults = false
    @State private var confirmPauseOnExit = false
    @State private var editingTask: BatteryScheduledTask?
    @State private var pendingRun: BatteryScheduledTask?
    @State private var deleteTask: BatteryScheduledTask?
    @State private var clearRuns = false
    @State private var quitting: BatteryConsumerApp?
    @FocusState private var lowLimitFocused: Bool

    @MainActor init(service: BatteryManagementService? = nil) { self.service = service ?? .shared }

    var body: some View {
        // Erase between presentation layers so dialog metadata does not
        // duplicate the complete eight-section settings tree. State stays here.
        let surface = AnyView(
            BatterySettingsStack(
                spacing: 18,
                rows: [
                    AnyView(Text("电池管理").font(.system(size: 22, weight: .bold)).dataAnnotationID("si.bm.settings")),
                    AnyView(status),
                    AnyView(
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                            ForEach(BatterySettingsSection.allCases) { item in
                                Button {
                                    section = item
                                } label: {
                                    Text(item.rawValue).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(
                                        .vertical, 7
                                    )
                                    .background(
                                        section == item ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }),
                    AnyView(content),
                ]))
        let presentation0 = AnyView(
            surface
                .modifier(BatteryLowLimitPrompt(service: service, isPresented: $showLowLimit))
                .onAppear {
                    service.setMetricsVisible("settings", visible: true)
                    service.refreshTelemetry()
                    limitDraft = String(service.preferences.limit)
                    focusRequested()
                }
                .onDisappear { service.setMetricsVisible("settings", visible: false) }
                .onChange(of: service.focusLowLimit) { _, _ in focusRequested() }
                .onChange(of: service.preferences.limit) { _, value in limitDraft = String(value) })
        let presentation1 = AnyView(
            presentation0
                .confirmationDialog("授权电池辅助程序", isPresented: $authorize, titleVisibility: .visible) {
                    Button("继续系统授权") { Task { await service.authorize() } }
                } message: {
                    Text(
                        "将注册SuperIsland自有的电池辅助程序，用于限充、放电和能源模式。已注册时先确认本功能的控制变更已恢复，再注销旧登记并重新注册。辅助程序仅接受固定控制参数，并在主程序失联45秒后尝试恢复自身变更。系统可能要求管理员批准。此操作不会停止其他电池工具；实际充放电和恢复仍需验证。"
                    )
                })
        let presentation2 = AnyView(
            presentation1
                .confirmationDialog("开始电池校准", isPresented: $confirmCalibrationStart, titleVisibility: .visible) {
                    Button("开始完整校准") {
                        Task { do { _ = try await service.startCalibration() } catch { message = error.localizedDescription } }
                    }
                } message: {
                    Text("将保存长期上限，依次充至100%、放至10%、再次充满、确认满电完成，再返回原上限。请持续连接电源，过程可能耗时数小时。可随时停止；退出、失联或重启会尝试恢复自有变更，不会自动继续深度放电。")
                })
        let presentation3 = AnyView(
            presentation2
                .confirmationDialog("停止电池校准", isPresented: $confirmCalibrationStop, titleVisibility: .visible) {
                    Button("停止并恢复原设置", role: .destructive) {
                        Task { do { _ = try await service.cancelCalibration() } catch { message = error.localizedDescription } }
                    }
                } message: {
                    Text("本次不会记录校准成功。恢复结果将在电池状态中显示，尚未确认恢复时不能开启另一个校准或切换模式。")
                })
        let presentation4 = AnyView(
            presentation3
                .confirmationDialog("关闭低充电限值", isPresented: $confirmRaiseLimit, titleVisibility: .visible) {
                    Button("调整至80%并关闭") {
                        change {
                            $0.limit = 80
                            $0.allowLowLimit = false
                        }
                    }
                } message: {
                    Text("当前长期上限低于80%。关闭后将先调整至80%，临时模式仍按独立规则处理。")
                })
        let presentation5 = AnyView(
            presentation4
                .confirmationDialog("恢复电池偏好默认值", isPresented: $confirmDefaults, titleVisibility: .visible) {
                    Button("恢复默认偏好") {
                        change { $0 = .init() }
                        service.updateDisplay { $0 = .init() }
                    }
                } message: {
                    Text("恢复限值和显示偏好；任务、历史和辅助程序授权保留。硬件变更仍需经过控制和回读。")
                })
        let presentation6 = AnyView(
            presentation5
                .confirmationDialog(
                    "停止校准后运行任务", isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("停止校准并运行", role: .destructive) {
                        let task = pendingRun
                        pendingRun = nil
                        Task {
                            do {
                                _ = try await service.cancelCalibration()
                                guard !service.calibrationActive, !service.report.recoveryPending else {
                                    message = "校准原设置尚未确认恢复，未运行任务。请等待恢复后重试。"
                                    return
                                }
                                if let task { message = try await schedules.runNow(task) }
                            } catch { message = error.localizedDescription }
                        }
                    }
                    Button("忽略本次任务", role: .cancel) { pendingRun = nil }
                } message: {
                    Text("当前校准正在运行；继续会停止本次校准，确认原设置恢复后再运行所选任务。")
                })
        let presentation7 = AnyView(
            presentation6
                .confirmationDialog(
                    "删除任务", isPresented: Binding(get: { deleteTask != nil }, set: { if !$0 { deleteTask = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        if let task = deleteTask { schedules.delete(task.id) }
                        deleteTask = nil
                    }
                } message: {
                    Text("删除该定时任务，保留既有执行历史。")
                })
        let presentation8 = AnyView(
            presentation7
                .confirmationDialog("清空任务历史", isPresented: $clearRuns, titleVisibility: .visible) {
                    Button("清空历史", role: .destructive) { schedules.clearHistory() }
                })
        let presentation9 = AnyView(
            presentation8
                .confirmationDialog(
                    "退出应用", isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } }), titleVisibility: .visible
                ) {
                    Button("正常退出应用") {
                        if let consumer = quitting, let application = manager.application(for: consumer), !application.terminate() {
                            message = "应用没有接受退出请求；没有强制结束。"
                        }
                        quitting = nil
                    }
                } message: {
                    Text("向所选普通应用发送正常退出请求；未保存内容由该应用自行确认。")
                })
        let presentation10 = AnyView(
            presentation9
                .alert("电池管理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(message ?? "")
                })
        let presentation11 = AnyView(
            presentation10
                .sheet(item: $editingTask) { task in BatteryTaskEditor(task: task, service: service) { editingTask = nil } })
        let presentation12 = AnyView(
            presentation11
                .alert("退出时保持停充", isPresented: $confirmPauseOnExit) {
                    Button("取消", role: .cancel) {}
                    Button("启用退出停充") {
                        guard service.report.capabilities.exitHoldSupported else {
                            message = "当前控制通道无法确认退出停充，未开启此选项。"
                            return
                        }
                        service.updateDisplay { $0.pauseOnExit = true }
                    }
                } message: {
                    Text("正常退出前将核实停充，保持至下次启用充电控制或辅助程序、系统重启；不保证无限保持。崩溃或失联仍按45秒租约恢复。准备失败时会阻止退出，可关闭此选项后重试。")
                })
        return presentation12
    }
    private var status: some View {
        GroupBox {
            BatterySettingsStack(
                spacing: 9,
                rows: [
                    AnyView(
                        BatterySettingsRow(rows: [
                            AnyView(Label(
                                service.enabled ? "充电控制已启用" : "充电控制尚未启用",
                                systemImage: service.enabled ? "checkmark.shield" : "exclamationmark.triangle"
                            )
                            .font(.headline).foregroundStyle(service.enabled ? .green : .orange)),
                            AnyView(Spacer()),
                            service.busy || service.authorizing
                                ? AnyView(ProgressView().controlSize(.small)) : AnyView(EmptyView()),
                            AnyView(Toggle("启用充电控制", isOn: Binding(get: { service.enabled }, set: service.setEnabled)).labelsHidden().toggleStyle(
                                .switch
                            ).disabled(service.busy || service.authorizing).dataAnnotationID("si.bm.master-toggle"))
                        ])),
                    AnyView(BatteryStatusText(text: service.report.message)),
                    failureRecord,
                    AnyView(Group {
                        if service.exitPreparationInProgress {
                            BatterySettingsRow(rows: [
                                AnyView(ProgressView().controlSize(.small)),
                                AnyView(Text("正在等待系统电池采样确认停充，可取消退出并恢复。")
                                    .font(.caption).foregroundStyle(.secondary)),
                                AnyView(Spacer()),
                                AnyView(Button("取消退出并恢复") { service.cancelExitPreparation() }
                                    .dataAnnotationID("si.bm.cancel-exit")),
                            ])
                        }
                    }),
                    AnyView(
                        BatterySettingsRow(rows: [
                            AnyView(Text("长期上限\(service.preferences.limit)% · \(service.report.mechanism) · \(batteryDischargeRouteDescription(service))").font(
                                .caption
                            ).foregroundStyle(
                                .secondary)),
                            AnyView(Spacer()),
                            AnyView(Button("重新检查") { Task { await service.recheckStatus() } }.disabled(service.busy || service.authorizing)),
                            AnyView(Button("系统授权…") { authorize = true }.disabled(service.busy || service.authorizing)),
                        ])),
                    AnyView(
                        Group {
                            if service.report.recoveryPending {
                                Text("恢复尚未确认。请保留辅助程序并重新检查；关闭开关不能代替恢复成功。")
                                    .font(.caption).foregroundStyle(.orange).dataAnnotationID("si.bm.recovery")
                            }
                        }),
                ]
            ).padding(8)
        }.dataAnnotationID("si.bm.master")
    }
    private var failureRecord: AnyView {
        let failures = [service.report.lastFailure, service.report.capabilityProbeFailure].compactMap { $0 }
        guard !failures.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(DisclosureGroup("诊断详情") {
            BatteryStatusText(text: failures.joined(separator: "\n"), failure: true)
                .textSelection(.enabled)
        }.font(.caption).foregroundStyle(.secondary))
    }
    // Keep the eight heterogeneous settings sections behind one view boundary.
    // Editing state lives on this parent, so switching sections preserves it
    // without propagating each section's full generic type through the window.
    private var content: AnyView {
        switch section {
        case .dashboard: return AnyView(dashboard)
        case .charge: return AnyView(charging)
        case .sleep: return AnyView(sleep)
        case .energy: return AnyView(energy)
        case .schedule: return AnyView(schedule)
        case .shortcuts: return AnyView(shortcuts)
        case .display: return AnyView(display)
        case .other: return AnyView(other)
        }
    }
    private var dashboard: some View {
        BatterySettingsStack(
            spacing: 14,
            rows: [
                AnyView(
                    HStack {
                        Text(service.telemetry.level.map { "\($0)%" } ?? "—").font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        VStack(alignment: .leading) {
                            Text(batterySupplyDescription(service.telemetry))
                            Text(batteryChargingDescription(service.telemetry)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("刷新读数") {
                            service.refreshTelemetry()
                            manager.refreshTopBatteryConsumers()
                        }
                    }),
                AnyView(
                    BatteryMetricGrid(service: service, compact: false).dataAnnotationID("si.bm.dashboard")),
                AnyView(
                    Text(
                        "来源：AppleSmartBattery / SMC TB0T · \(service.telemetry.timestamp.formatted(date: .omitted, time: .standard))。—表示传感器或字段不可用。电池功率为电压×电流，正值充入、负值放出；适配器为额定值。"
                    )
                    .font(.caption).foregroundStyle(.secondary)),
                AnyView(runtimeChoices),
                AnyView(Text(service.averagePowerDescription).font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    Text("电池续航按当前剩余容量×实测电压÷放电功率粗略估算，并非系统保证时间；仅在电池供电、功率有效时显示。充电时单独显示系统预计充满时间。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(Group { if service.display.metrics.isEmpty { Text("未选择仪表指标，请在显示与面板中添加。").foregroundStyle(.secondary) } }),
                AnyView(
                    Text(
                        "容量：\(service.telemetry.fullCapacity.map(String.init) ?? "—") / 设计\(service.telemetry.designCapacity.map(String.init) ?? "—") mAh。硬件电量仅供统计，充电控制使用macOS百分比。"
                    )
                    .font(.caption).foregroundStyle(.secondary)),
                AnyView(BatteryReportedPowerView(state: service.reportedPower, supply: service.telemetry.powerSupplyObservation)),
            ])
    }
    private var runtimeChoices: AnyView {
        AnyView(
            BatterySettingsRow(rows: [
                AnyView(BatteryDisplayPicker(
                    title: "续航估算方式", choices: BatteryRuntimeMode.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                    selection: rawDisplayBinding(\.runtimeMode))),
                AnyView(BatteryDisplayPicker(
                    title: "平均时间窗口", choices: [5, 15, 30, 60].map { .init(id: String($0), title: "\($0)分钟") },
                    selection: Binding(
                        get: { String(service.display.averageMinutes) },
                        set: { value in if let minutes = Int(value) { service.updateDisplay { $0.averageMinutes = minutes } } })
                )
                .disabled(service.display.runtimeMode == .instant)),
            ]))
    }
    private var charging: some View {
        BatterySettingsStack(
            spacing: 14,
            rows: [
                AnyView(
                    Group {
                        if service.reviewTrialActive {
                            Text("本验证包：上限80–85%、手动放电目标固定80%；\(batteryDischargeRouteDescription(service))。暂停与恢复可用，充满、自动放电、航海、校准和能源模式暂未开放。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }),
                AnyView(chargeLimitCard),
                AnyView(GroupBox("手动控制") {
                    BatteryManualControls(service: service, showAutomatic: true).padding(8)
                }),
                AnyView(chargeProtectionCard),
                AnyView(chargeCalibrationCard),
            ]
        ).dataAnnotationID("si.bm.charge-settings")
    }
    private var chargeLimitCard: AnyView {
        AnyView(
            GroupBox("充电上限") {
                BatterySettingsStack(
                    spacing: 12,
                    rows: [
                        AnyView(BatteryChargeLimitSlider(service: service)),
                        AnyView(
                            HStack {
                                TextField("上限百分比", text: $limitDraft).frame(width: 70).textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("battery-limit-number")
                                    .disabled(service.busy || service.authorizing || service.calibrationActive)
                                Text("%")
                                Button("应用") {
                                    guard let value = Int(limitDraft) else {
                                        message = "请输入整数百分比。"
                                        return
                                    }
                                    if (20..<80).contains(value) && !service.preferences.allowLowLimit {
                                        limitDraft = String(service.preferences.limit)
                                        showLowLimit = true
                                        return
                                    }
                                    change { $0.limit = value }
                                }.disabled(service.busy || service.authorizing || service.calibrationActive)
                                Spacer()
                                Text(service.canControl ? "按设备能力提交并读回" : "仅保存偏好；尚未应用").font(.caption).foregroundStyle(.secondary)
                            }),
                        AnyView(
                            Toggle(
                                "允许充电至低于80%",
                                isOn: Binding(
                                    get: { service.preferences.allowLowLimit },
                                    set: { value in
                                        if !value && service.preferences.limit < 80 {
                                            confirmRaiseLimit = true
                                        } else {
                                            change { $0.allowLowLimit = value }
                                        }
                                    })
                            ).focused($lowLimitFocused).disabled(!service.report.capabilities.lowLimits && !service.preferences.allowLowLimit).dataAnnotationID("si.bm.low-limit")),
                        AnyView(
                            Group {
                                if service.report.usesNativeLimit && !service.report.capabilities.lowLimits {
                                    Text("本机原生通道仅支持80–100%。低值、即时热保护与睡眠停充尚未接通兼容控制通道，不会仅修改偏好后宣称已经生效。")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }),
                        AnyView(
                            Text(service.report.usesNativeLimit && !service.report.capabilities.lowLimits
                                ? "当前最低80%；原有低值偏好不会自动修改。系统Charge Limit可能延迟约一分钟，系统校准也可能临时超过上限。"
                                : "开启后可设20–100%；实际范围与暂停精度仍取决于系统及设备。系统Charge Limit可能延迟约一分钟，校准期间可临时超过上限。")
                                .font(.caption).foregroundStyle(.secondary)),
                    ]
                ).padding(8)
            })
    }
    private var chargeProtectionCard: AnyView {
        AnyView(
            GroupBox("自动控制与保护") {
                BatterySettingsStack(
                    spacing: 12,
                    rows: [
                        AnyView(Toggle("高于上限时自动放电", isOn: preference(\.automaticDischarge)).disabled((service.reviewTrialActive || service.report.capabilities.minimumDischargeTarget == nil) && !service.preferences.automaticDischarge)),
                        AnyView(
                            Toggle("航海模式", isOn: preference(\.sailing)).disabled(service.sailingConfigurationWarning != nil && !service.preferences.sailing).dataAnnotationID(
                                "si.bm.sailing")),
                        AnyView(
                            Stepper(
                                "航海下限 \(service.preferences.sailingLower)%", value: preference(\.sailingLower),
                                in: service.minimumDischargeTarget...99).disabled(service.reviewTrialActive)),
                        AnyView(
                            Group {
                                if let warning = service.sailingConfigurationWarning {
                                    Text(warning)
                                    .font(.caption).foregroundStyle(.orange)
                                }
                            }),
                        AnyView(
                            Toggle("过热时暂停充电", isOn: preference(\.heatProtection)).disabled(!service.report.capabilities.thermalPause && !service.preferences.heatProtection).dataAnnotationID(
                                "si.bm.heat")),
                        AnyView(
                            Stepper(
                                "保护阈值 \(Int(service.preferences.maximumTemperature))°C", value: preference(\.maximumTemperature),
                                in: 25...50, step: 1).disabled(!service.report.capabilities.thermalPause)),
                        AnyView(
                            Text(!service.report.capabilities.thermalPause
                                ? "当前控制通道无法执行即时过热停充；此处仅显示已保存的阈值，不表示保护已生效。可关闭原有规则；系统硬件保护始终优先。"
                                : "到阈值提交暂停并核验实际停充，每5分钟重新检查；恢复后至少充电5分钟。系统响应可能延迟，温度缺失时保护暂停，系统硬件保护始终优先。实际停止与恢复仍需本机验证。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)),
                    ]
                ).padding(8)
            })
    }
    private var chargeCalibrationCard: AnyView {
        AnyView(
            GroupBox("校准") {
                BatterySettingsStack(
                    spacing: 10,
                    rows: [
                        AnyView(Text("100% → 10% → 100% → 保持 → 原上限").font(.callout)),
                        AnyView(
                            HStack {
                                Button("开始校准") { confirmCalibrationStart = true }
                                    .disabled(!service.canStartCalibration).dataAnnotationID("si.bm.calibration-start")
                                if service.report.calibration?.isActive == true {
                                    Button("停止校准…") { confirmCalibrationStop = true }.disabled(service.busy)
                                }
                            }),
                        AnyView(
                            Group {
                                if let calibration = service.report.calibration {
                                    Text(calibration.title).font(.callout)
                                    if let completed = calibration.lastCompletedAt {
                                        Text("上次成功校准：" + completed.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }),
                        AnyView(
                            Group {
                                if !service.report.capabilities.calibration {
                                    Text("当前辅助程序或设备不支持完整校准；需充电、主动放电与可恢复的控制通道。")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }),
                        AnyView(
                            Text(service.report.systemCalibration ? "当前：macOS正在执行系统校准，可能临时充至100%。" : "macOS系统校准：当前未观察到充满覆盖信号。")
                                .font(.caption).foregroundStyle(.secondary)),
                    ]
                ).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.dataAnnotationID("si.bm.calibration"))
    }
    private var sleep: some View {
        BatterySettingsStack(
            spacing: 14,
            rows: [
                AnyView(
                    AnyView(BatteryDisplayPicker(
                        title: "睡眠期间", choices: BatterySleepPolicy.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                        selection: batteryRawChoiceBinding(preference(\.sleep)),
                        disabledIDs: Set(BatterySleepPolicy.allCases.filter {
                            ($0 == .pause && !service.report.capabilities.immediatePause) || (service.reviewTrialActive && $0 != .unchanged)
                        }.map(\.rawValue))
                    )).pickerStyle(.radioGroup).dataAnnotationID("si.bm.sleep-policy")),
                AnyView(
                    Text((!service.report.capabilities.immediatePause ? "当前控制通道不支持睡眠时即时停充，可将已保存的睡眠停充规则改为照原样继续。" : "")
                        + (service.reviewTrialActive ? "本验证包仅开放照原样继续，原策略不会自动修改。" : "")
                        + "上限前保持唤醒仅创建本功能自己的空闲休眠断言，不取消保持唤醒模块或其他应用的断言；不保证主动睡眠和合盖运行。系统Charge Limit由固件执行，旧SMC路径睡眠期间仍需实机验证。")
                        .font(.caption).foregroundStyle(.secondary).dataAnnotationID("si.bm.sleep")),
                AnyView(
                    Toggle("退出时保持停充", isOn: Binding(
                        get: { service.display.pauseOnExit },
                        set: { value in
                            if value { confirmPauseOnExit = true }
                            else { service.updateDisplay { $0.pauseOnExit = false } }
                        }))
                        .disabled(!service.report.capabilities.exitHoldSupported && !service.display.pauseOnExit)
                        .dataAnnotationID("si.bm.pause-on-exit")),
                AnyView(Text(service.report.capabilities.exitHoldSupported
                    ? "正常退出前确认停充；下次启用或辅助程序、系统重启时恢复。准备失败会阻止退出，可关闭此选项重试。崩溃失联仍按45秒租约恢复。"
                    : "当前通道不支持可核验的退出停充；可以关闭已保存的选项，退出仍按恢复流程处理。")
                    .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    BatteryDisplayPicker(
                        title: "不活动时关闭显示屏", choices: BatteryDisplaySleepPolicy.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                        selection: rawDisplayBinding(\.screenSleepPolicy))),
                AnyView(
                    Text("仅本轮充电控制已启用且系统醒着时执行，使用本功能自己的显示休眠断言；保持唤醒模块的KA1优先。外接显示器或状态未知时不会主动关闭屏幕，不修改系统电源偏好。").font(.caption).foregroundStyle(
                        .secondary)),
                AnyView(Text(service.displaySleepStatus ?? "显示屏策略：跟随系统").font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    Toggle("合盖时锁定屏幕", isOn: displayBinding(\.lockOnLidClose))
                        .disabled(service.lidLockAvailabilityReason != nil && !service.display.lockOnLidClose)
                        .dataAnnotationID("si.bm.lid-lock")),
                AnyView(
                    Text("仅在本轮充电控制启用且系统醒着观察到新的合盖事件时请求锁屏；仍遵循系统睡眠行为，锁定后需本人解锁。关闭开关可停止后续请求，已发送的请求可能无法撤销。实际锁屏尚未验收。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    Text(service.lidLockAvailabilityReason ?? service.lidLockStatus)
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(Button("查看现有保持唤醒设置") { AppDelegate.showSettingsWindow(initialPane: .keepAwake) }),
            ]
        )
    }
    private var energy: some View {
        BatterySettingsStack(
            spacing: 14,
            rows: [
                AnyView(
                    AnyView(BatteryDisplayPicker(
                        title: "低功耗模式", choices: BatteryEnergyScope.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                        selection: batteryRawChoiceBinding(preference(\.lowPower)),
                        disabledIDs: Set(BatteryEnergyScope.allCases.filter { service.reviewTrialActive && $0 != .never }.map(\.rawValue))
                    )).dataAnnotationID("si.bm.energy-mode")),
                AnyView(
                    Text("“从不”释放本功能持有的能源偏好，恢复修改前状态；不会强行关闭用户原有低功耗设置。其他选项分别作用于电池和适配器配置，辅助程序将读回确认。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    BatteryDisplayPicker(
                        title: "高功率模式", choices: BatteryEnergyScope.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                        selection: batteryRawChoiceBinding(preference(\.highPowerScope)),
                        disabledIDs: Set(BatteryEnergyScope.allCases.filter {
                            $0 != .never && (service.reviewTrialActive || service.report.highPowerSupported != true)
                        }.map(\.rawValue))
                    )),
                AnyView(
                    Text(
                        service.report.highPowerSupported == true
                            ? "低功耗与高功率在同一电源范围内互斥。两项均为“从不”时释放本功能的能源设置，恢复修改前状态。"
                            : "当前设备尚无可确认的高功率控制与恢复能力，暂不可用；不会尝试探写。"
                    )
                    .font(.caption).foregroundStyle(.secondary)),
                AnyView(Toggle("后台更新仪表读数", isOn: displayBinding(\.backgroundMetrics))),
                AnyView(
                    Toggle("包含后台进程", isOn: displayBinding(\.includeBackgroundProcesses)).onChange(
                        of: service.display.includeBackgroundProcesses
                    ) { _, _ in manager.refreshTopBatteryConsumers() }),
                AnyView(
                    Stepper(
                        "应用影响阈值 \(service.display.consumerThreshold, specifier: "%.0f")", value: displayBinding(\.consumerThreshold),
                        in: 0...100)),
                AnyView(
                    HStack {
                        Text("高耗能应用与进程").font(.headline)
                        Spacer()
                        Button("刷新") { manager.refreshTopBatteryConsumers() }
                    }),
                AnyView(
                    Text("此处为top提供的power影响分数或CPU百分比，不是单应用瓦数。空列表表示没有有效采样或没有符合筛选的进程。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    ForEach(manager.topBatteryConsumers.filter { $0.impactScore >= service.display.consumerThreshold }) { consumer in
                        HStack {
                            Text(consumer.appName)
                            Spacer()
                            Text(consumer.formattedImpact).monospacedDigit().foregroundStyle(.secondary)
                            if manager.application(for: consumer) != nil { Button("退出…") { quitting = consumer } }
                        }.padding(.vertical, 4)
                    }),
            ]
        ).dataAnnotationID("si.bm.energy")
    }
    private var schedule: some View {
        BatterySettingsStack(
            spacing: 12,
            rows: [
                AnyView(
                    BatterySettingsRow(rows: [
                        AnyView(Text("定时任务").font(.headline)),
                        AnyView(Spacer()),
                        AnyView(Button("新建任务") { editingTask = .init() }.dataAnnotationID("si.bm.schedule-new")),
                    ])),
                AnyView(
                    Text("仅在SuperIsland运行时调度；唤醒后可按任务选择补做最近24小时内的一次实例。保存时区后按该时区执行，月末取当月最后一天，夏令时重复时间仅执行第一次。最多100项任务、200条历史。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    Menu("从模板新建") {
                        Button("周一05:00充满") { template(name: "周一充满", action: .topUp, repeatMode: .weekly, weekday: 2, hour: 5) }.disabled(batteryScheduledActionWarning(.topUp, service: service) != nil)
                        Button("周六07:00充满") { template(name: "周末充满", action: .topUp, repeatMode: .weekly, weekday: 7, hour: 7) }.disabled(batteryScheduledActionWarning(.topUp, service: service) != nil)
                        Button("每月校准") { template(name: "每月校准", action: .calibrate, repeatMode: .monthly) }.disabled(batteryScheduledActionWarning(.calibrate, service: service) != nil)
                        Button("每两周校准") { template(name: "两周校准", action: .calibrate, repeatMode: .fortnightly) }.disabled(batteryScheduledActionWarning(.calibrate, service: service) != nil)
                    }),
                AnyView(Group { if let error = schedules.configurationError { Text(error).font(.caption).foregroundStyle(.red) } }),
                AnyView(Group { if schedules.tasks.isEmpty { Text("尚未创建任务").foregroundStyle(.secondary) } }),
                AnyView(
                    ForEach(schedules.tasks) { task in
                        AnyView(BatterySettingsStack(
                            spacing: 5,
                            rows: [
                                AnyView(
                                    BatterySettingsRow(rows: [
                                        AnyView(Toggle(task.name, isOn: Binding(get: { task.enabled }, set: { schedules.setEnabled(task.id, $0) }))
                                            .disabled(!task.enabled && service.scheduleCapabilityWarning(task) != nil)),
                                        AnyView(Spacer()),
                                        AnyView(Button("编辑") { editingTask = task }),
                                        AnyView(Button("删除…") { deleteTask = task }),
                                    ])),
                                AnyView(
                                    Text(
                                        "\(task.action.title) · \(task.repetition.title) · \(task.timeZoneID) · \(task.nextDue?.formatted() ?? "没有下一次")"
                                            + (service.scheduleCapabilityWarning(task).map {
                                                " · " + $0
                                            } ?? "")
                                    )
                                    .font(.caption).foregroundStyle(
                                        service.scheduleCapabilityWarning(task) == nil
                                            ? Color.secondary : .orange)),
                                AnyView(
                                    Button("立即运行") {
                                        if service.calibrationActive {
                                            pendingRun = task
                                        } else {
                                            Task {
                                                do { message = try await schedules.runNow(task) } catch {
                                                    message = error.localizedDescription
                                                }
                                            }
                                        }
                                    }.disabled(service.busy || service.scheduleCapabilityWarning(task) != nil)),
                            ]
                        ).padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)))
                    }),
                AnyView(
                    BatterySettingsRow(rows: [
                        AnyView(Text("执行历史").font(.headline)),
                        AnyView(Spacer()),
                        AnyView(Button("清空历史…") { clearRuns = true }.disabled(schedules.runs.isEmpty)),
                    ])),
                AnyView(
                    ForEach(schedules.runs.prefix(20)) { run in
                        BatterySettingsStack(
                            spacing: 3,
                            rows: [
                                AnyView(Text("\(run.name) · \(run.status)").font(.callout)),
                                AnyView(Text(run.timestamp.formatted() + " · " + run.detail).font(.caption).foregroundStyle(.secondary)),
                            ])
                    }),
            ]
        ).dataAnnotationID("si.bm.schedule")
    }
    private var shortcuts: some View {
        BatterySettingsStack(
            spacing: 12,
            rows: [
                AnyView(Text("苹果快捷指令").font(.headline)),
                AnyView(
                    Text("在“快捷指令”App的SuperIsland操作中查看以下12项。查询只返回真实读数；写入使用同一授权、参数和冲突检查。未支持或未授权时返回明确错误。系统发现与逐项调用仍需在签名应用中验证。")
                        .font(.callout).foregroundStyle(.secondary)),
                AnyView(
                    ForEach(
                        [
                            "充满电池", "暂停充电", "放电至目标", "开始电池校准", "设置充电上限", "获取电池电量", "获取充电上限", "获取充电状态", "获取电池温度", "设置MagSafe灯色", "设置低功耗模式",
                            "设置高功率模式",
                        ], id: \.self
                    ) { Text($0).font(.callout) }),
                AnyView(
                    Text("完整校准、限充、暂停、放电、MagSafe及高功率操作按当前设备能力提供；不支持时明确返回错误。快捷指令与面板使用同一能力限制。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    Button("打开快捷指令") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                        .dataAnnotationID("si.bm.open-shortcuts")),
            ]
        ).dataAnnotationID("si.bm.shortcuts")
    }
    private var display: AnyView {
        AnyView(
            BatterySettingsStack(
                spacing: 14,
                rows: [
                    AnyView(popupDisplay),
                    AnyView(entryDisplay),
                    AnyView(metricDisplay),
                ]
            ).dataAnnotationID("si.bm.display"))
    }
    private var popupDisplay: AnyView {
        AnyView(
            GroupBox("电池展开面板") {
                BatterySettingsStack(
                    spacing: 9,
                    rows: [
                        AnyView(Toggle("显示百分比", isOn: displayBinding(\.showPercentage)).dataAnnotationID("si.bm.display-percentage")),
                        AnyView(Toggle("启动时显示充电控制结果", isOn: displayBinding(\.showAtStartup))),
                        AnyView(
                            Text("提醒在灵动岛内短暂展开；悬停或键盘聚焦时保留，点击进入电池设置。失败原因始终保留在状态区。")
                                .font(.caption).foregroundStyle(.secondary)),
                        AnyView(Toggle("降低透明度", isOn: displayBinding(\.reduceTransparency))),
                        AnyView(
                            HStack {
                                Text("面板透明度")
                                Slider(value: displayBinding(\.opacity), in: 0.5...1)
                            }),
                        AnyView(
                            BatteryDisplaySelection(
                                choices: BatteryPopupField.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                selected: service.display.popupFields.map(\.rawValue)
                            ) { id, selected in
                                guard let field = BatteryPopupField(rawValue: id) else { return }
                                service.updateDisplay {
                                    if selected { $0.popupFields.append(field) } else { $0.popupFields.removeAll { $0 == field } }
                                }
                            }),
                        AnyView(Text("隐藏内容后，电池设置入口和控制状态仍保留。").font(.caption).foregroundStyle(.secondary)),
                    ]
                ).padding(8)
            })
    }
    private var entryDisplay: AnyView {
        AnyView(
            GroupBox("现有电池入口显示") {
                BatterySettingsStack(
                    spacing: 9,
                    rows: [
                        AnyView(
                            BatteryDisplayPicker(
                                title: "电池图标样式", choices: BatteryIndicatorStyle.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                selection: rawDisplayBinding(\.indicatorStyle))),
                        AnyView(entryStatisticsDisplay),
                        AnyView(
                            Text("入口宽度沿用灵动岛，空间不足时省略文字；悬停可查看全部已选读数。macOS 条件尚无可确认数据源，显示—。")
                                .font(.caption).foregroundStyle(.secondary)),
                        AnyView(
                            Stepper("显示间距 \(service.display.indicatorSpacing) px", value: displayBinding(\.indicatorSpacing), in: 0...20)),
                        AnyView(
                            Stepper("读数更新间隔 \(service.display.refreshInterval) 秒", value: displayBinding(\.refreshInterval), in: 2...20)),
                        AnyView(
                            Text("仅影响仪表采样，仍遵循全局节能与可见性策略；不改变辅助程序控制心跳。")
                                .font(.caption).foregroundStyle(.secondary)),
                        AnyView(
                            BatteryDisplayPicker(
                                title: "右击电池入口", choices: BatteryRightClickAction.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                selection: rawDisplayBinding(\.rightClickAction))),
                        AnyView(
                            HStack {
                                Button("重置显示") { service.updateDisplay { $0.resetEntryDisplay() } }
                                Button("清除统计项") { service.updateDisplay { $0.entryStatistics = [] } }
                            }),
                    ]
                ).padding(8)
            })
    }
    private var entryStatisticsDisplay: AnyView {
        AnyView(
            BatterySettingsStack(
                spacing: 9,
                rows: [
                    AnyView(
                        BatteryDisplaySelection(
                            choices: BatteryEntryStatistic.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                            selected: service.display.entryStatistics.map(\.rawValue)
                        ) { id, selected in
                            guard let statistic = BatteryEntryStatistic(rawValue: id) else { return }
                            service.updateDisplay {
                                if selected {
                                    $0.entryStatistics.append(statistic)
                                } else {
                                    $0.entryStatistics.removeAll { $0 == statistic }
                                }
                            }
                        }),
                    AnyView(
                        BatteryDisplayOrder(choices: service.display.entryStatistics.map { .init(id: $0.rawValue, title: $0.title) }) {
                            id, offset in
                            if let statistic = BatteryEntryStatistic(rawValue: id) { moveEntry(statistic, offset: offset) }
                        }),
                ]))
    }
    private func moveEntry(_ statistic: BatteryEntryStatistic, offset: Int) {
        service.updateDisplay {
            guard let index = $0.entryStatistics.firstIndex(of: statistic), $0.entryStatistics.indices.contains(index + offset) else {
                return
            }
            $0.entryStatistics.swapAt(index, index + offset)
        }
    }
    private var metricDisplay: AnyView {
        AnyView(
            GroupBox("概览与仪表板 · 最多六项") {
                BatterySettingsStack(
                    spacing: 8,
                    rows: [
                        AnyView(
                            BatteryDisplaySelection(
                                choices: BatteryMetric.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                selected: service.display.metrics.map(\.rawValue), maximum: 6
                            ) { id, selected in
                                guard let metric = BatteryMetric(rawValue: id) else { return }
                                service.updateDisplay {
                                    if selected && $0.metrics.count < 6 { $0.metrics.append(metric) }
                                    if !selected { $0.metrics.removeAll { $0 == metric } }
                                }
                            }),
                        AnyView(
                            BatteryDisplayOrder(choices: service.display.metrics.map { .init(id: $0.rawValue, title: $0.title) }) {
                                id, offset in
                                if let metric = BatteryMetric(rawValue: id) { moveMetric(metric, offset: offset) }
                            }),
                    ]
                ).padding(8)
            })
    }
    private func moveMetric(_ metric: BatteryMetric, offset: Int) {
        service.updateDisplay {
            guard let index = $0.metrics.firstIndex(of: metric), $0.metrics.indices.contains(index + offset) else { return }
            $0.metrics.swapAt(index, index + offset)
        }
    }
    private var other: some View {
        BatterySettingsStack(
            spacing: 14,
            rows: [
                AnyView(
                    AnyView(BatteryDisplayPicker(
                        title: "MagSafe LED", choices: BatteryLED.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                        selection: batteryRawChoiceBinding(preference(\.led)),
                        disabledIDs: Set(BatteryLED.allCases.filter {
                            $0 != .system && (service.reviewTrialActive || !service.report.ledSupported)
                        }.map(\.rawValue))
                    )).dataAnnotationID("si.bm.led")),
                AnyView(
                    Toggle("放电时闪烁LED", isOn: preference(\.blinkWhileDischarging)).disabled(
                        (service.reviewTrialActive || !service.report.ledSupported || service.report.capabilities.minimumDischargeTarget == nil) && !service.preferences.blinkWhileDischarging)),
                AnyView(
                    Text("仅在对应SMC键可读、写入后能回读时提交LED控制；还需用MagSafe设备观察实际灯色。恢复时回到修改前的原始值。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(
                    Text("Intel：仅在BCLM可读时使用该路径，主动放电和航海不可用。不会按处理器名称假定所有功能受支持。")
                        .font(.caption).foregroundStyle(.secondary)),
                AnyView(Button("系统后台辅助程序设置") { service.openSystemAuthorization() }),
                AnyView(Button("恢复默认偏好…") { confirmDefaults = true }),
                AnyView(
                    Text(
                        "诊断\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n电池：\(service.telemetry.hasBattery ? "已识别" : "未识别")\n授权：\(service.authorizationDescription)\n机制：\(service.report.mechanism)\n系统登记目标：\(service.report.registeredTarget.map { "\($0)%" } ?? "未确认")\n系统手动上限读回：\(service.report.nativeSavedLimit.map { "\($0)%" } ?? "未确认")\n辅助程序读数时间：\(service.report.timestamp.formatted())\n电池读数时间：\(service.telemetry.timestamp.formatted())"
                    )
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)),
            ]
        ).dataAnnotationID("si.bm.hardware")
    }
    private func unavailable(_ title: String, _ reason: String) -> some View {
        BatterySettingsStack(
            spacing: 4,
            rows: [
                AnyView(Text(title + " · 暂不可用").font(.callout)),
                AnyView(Text(reason).font(.caption).foregroundStyle(.secondary)),
            ])
    }
    private func preference<T>(_ path: WritableKeyPath<BatteryControlPreferences, T>) -> Binding<T> {
        Binding(get: { service.preferences[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }
    private func rawDisplayBinding<T: RawRepresentable>(_ path: WritableKeyPath<BatteryDisplayPreferences, T>) -> Binding<String>
    where T.RawValue == String {
        Binding(
            get: { service.display[keyPath: path].rawValue },
            set: { value in
                if let parsed = T(rawValue: value) { service.updateDisplay { $0[keyPath: path] = parsed } }
            })
    }
    private func displayBinding<T>(_ path: WritableKeyPath<BatteryDisplayPreferences, T>) -> Binding<T> {
        Binding(get: { service.display[keyPath: path] }, set: { value in service.updateDisplay { $0[keyPath: path] = value } })
    }
    private func change(_ mutation: (inout BatteryControlPreferences) -> Void) {
        do { try service.updatePreferences(mutation) } catch { message = error.localizedDescription }
    }
    private func focusRequested() {
        guard service.focusLowLimit else { return }
        section = .charge
        DispatchQueue.main.async {
            lowLimitFocused = true
            service.focusLowLimit = false
        }
    }
    private func template(
        name: String, action: BatteryScheduledAction, repeatMode: BatteryScheduleRepeat, weekday: Int? = nil, hour: Int = 9
    ) {
        var task = BatteryScheduledTask()
        task.name = name
        task.action = action
        task.repetition = repeatMode
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: task.timeZoneID)!
        task.anchor =
            calendar.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: 0, weekday: weekday), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(3600)
        editingTask = task
    }
}

private struct BatteryTaskEditor: View {
    @State var task: BatteryScheduledTask
    @ObservedObject var service: BatteryManagementService
    let dismiss: () -> Void
    @State private var error: String?
    var body: some View {
        AnyView(BatterySettingsStack(
            spacing: 16,
            rows: [
                AnyView(Text("电池定时任务").font(.title2.bold())),
                AnyView(TextField("任务名称", text: $task.name)),
                AnyView(BatteryDisplayPicker(
                    title: "动作", choices: BatteryScheduledAction.allCases.map {
                        .init(id: $0.rawValue, title: $0.title + (batteryScheduledActionWarning($0, service: service) == nil ? "" : " · 暂不可用"))
                    }, selection: batteryRawChoiceBinding($task.action),
                    disabledIDs: Set(BatteryScheduledAction.allCases.filter { batteryScheduledActionWarning($0, service: service) != nil }.map(\.rawValue))
                )),
                AnyView(
                    Group {
                        if task.action == .discharge || task.action == .limit {
                            Stepper(
                                "目标 \(task.target)%", value: $task.target,
                                in: (task.action == .discharge ? service.minimumDischargeTarget : service.report.minimumSupportedLimit)...(task.action == .discharge
                                    ? (service.reviewTrialActive ? 80 : 99) : (service.reviewTrialActive ? 85 : 100)))
                        }
                    }),
                AnyView(
                    Group {
                        if let warning = service.scheduleCapabilityWarning(task) {
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }),
                AnyView(
                    DatePicker("首次时间", selection: $task.anchor).environment(\.timeZone, TimeZone(identifier: task.timeZoneID) ?? .current)),
                AnyView(TextField("IANA时区", text: $task.timeZoneID)),
                AnyView(BatteryDisplayPicker(
                    title: "重复", choices: BatteryScheduleRepeat.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                    selection: batteryRawChoiceBinding($task.repetition))),
                AnyView(Toggle("启用", isOn: $task.enabled).disabled(!task.enabled && service.scheduleCapabilityWarning(task) != nil)),
                AnyView(Toggle("错过后补做24小时内最近一次", isOn: $task.catchUp)),
                AnyView(
                    Group {
                        if task.action == .calibrate {
                            Text("运行校准时须持续接电且设备支持完整控制和恢复；与现有校准或临时控制冲突时拒绝，不会自动取消已有任务。 ").font(.caption).foregroundStyle(.orange)
                        }
                    }),
                AnyView(Group { if let error { Text(error).font(.caption).foregroundStyle(.red) } }),
                AnyView(
                    BatterySettingsRow(rows: [
                        AnyView(Button("取消", action: dismiss)),
                        AnyView(Spacer()),
                        AnyView(Button("保存") {
                            do {
                                try BatteryScheduleService.shared.save(task)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.keyboardShortcut(.defaultAction).disabled(task.enabled && service.scheduleCapabilityWarning(task) != nil)),
                    ])),
            ]
        )).padding(24).frame(width: 430)
    }
}

@MainActor
private func batteryScheduledActionWarning(_ action: BatteryScheduledAction, service: BatteryManagementService) -> String? {
    // Probe only the action's known capability. A saved task's old target must
    // remain untouched and must not prevent choosing a different valid action.
    var candidate = BatteryScheduledTask()
    candidate.action = action
    candidate.target = action == .discharge ? service.minimumDischargeTarget : 80
    return service.scheduleCapabilityWarning(candidate)
}

// Concrete shared rows keep enum-specific state in the model while avoiding
// repeated SwiftUI list and picker specializations for identical controls.
private struct BatteryDisplayChoice: Identifiable {
    let id: String
    let title: String
}
private struct BatteryDisplayPicker: View {
    let title: String
    let choices: [BatteryDisplayChoice]
    @Binding var selection: String
    var disabledIDs: Set<String> = []
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(choices) { Text($0.title).tag($0.id).disabled(disabledIDs.contains($0.id)) }
        }
    }
}
@MainActor
private func batteryRawChoiceBinding<Value: RawRepresentable>(_ original: Binding<Value>) -> Binding<String> where Value.RawValue == String {
    Binding(get: { original.wrappedValue.rawValue }, set: { raw in
        if let value = Value(rawValue: raw) { original.wrappedValue = value }
    })
}
private struct BatteryDisplaySelection: View {
    let choices: [BatteryDisplayChoice]
    let selected: [String]
    var maximum = Int.max
    let update: (String, Bool) -> Void
    var body: some View {
        ForEach(choices) { item in
            Toggle(item.title, isOn: Binding(get: { selected.contains(item.id) }, set: { update(item.id, $0) }))
                .disabled(!selected.contains(item.id) && selected.count >= maximum)
        }
    }
}
private struct BatteryDisplayOrder: View {
    let choices: [BatteryDisplayChoice]
    let move: (String, Int) -> Void
    var body: some View {
        ForEach(choices) { item in
            BatterySettingsRow(rows: [
                AnyView(Text(item.title)),
                AnyView(Spacer()),
                AnyView(Button("上移") { move(item.id, -1) }.disabled(choices.first?.id == item.id).accessibilityLabel("上移" + item.title)),
                AnyView(Button("下移") { move(item.id, 1) }.disabled(choices.last?.id == item.id).accessibilityLabel("下移" + item.title)),
            ])
        }
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
