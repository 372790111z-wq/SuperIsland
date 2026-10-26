import SwiftUI

struct KeepAwakeSettingsView: View {
    @ObservedObject private var service: KeepAwakeService
    init(service: KeepAwakeService = .shared, initialTab: Int = 0) {
        self.service = service
        _tab = State(initialValue: initialTab)
    }
    @State private var tab = 0
    @State private var duration = 60
    @State private var query = ""
    @State private var proposedSource: KeepAwakeSource?
    @State private var proposedCodexConnection: KeepAwakeCodexConnection?
    @State private var showConnection = false
    @State private var showLidAuthorization = false
    @State private var message = ""
    @State private var showMessage = false
    private var sources: [KeepAwakeSource] {
        KeepAwakeSource.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var proposedReadOnly: Bool {
        proposedCodexConnection?.mode == .rpc || proposedSource?.readsLocalStatus == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保持唤醒").font(.title2.weight(.semibold))
            Text("按本地任务或手动计时保持 Mac 工作，屏幕与合盖支持分别管理。")
                .font(.callout).foregroundStyle(.secondary)
            SettingGroup {
                SettingToggleRow(title: "启用保持唤醒", description: "关闭后立即停止本功能保持并恢复系统设置，不会取消外部任务。",
                                 isOn: Binding(get: { service.engine.enabled }, set: service.setEnabled))
                    .toggleStyle(.switch).disabled(!service.canEnable)
                    .dataAnnotationID("si.ka.master")
            }
            status
            if service.isNotebook { KeepAwakeRecapSettings(recap: service.recap, enabled: service.engine.enabled) }
            if service.releasePending {
                Button(service.lid.busy ? "正在恢复系统设置…" : "重试恢复系统设置") { service.retryRelease() }
                    .disabled(service.lid.busy).dataAnnotationID("si.ka.release-retry")
            }
            Picker("管理分区", selection: $tab) {
                Text("运行策略").tag(0); Text("任务来源 · \(KeepAwakeSource.all.count)").tag(1); Text("保护与恢复").tag(2)
            }.pickerStyle(.segmented)
            switch tab {
            case 0: strategy.disabled(!service.engine.enabled)
            case 1: sourceList
            default: protection
            }
        }
        .accessibilityElement(children: .contain)
        .dataAnnotationID("si.ka.settings")
        .confirmationDialog("接入任务来源", isPresented: $showConnection, titleVisibility: .visible) {
            Button(proposedReadOnly ? "启用只读接入" : "备份并接入") {
                guard service.engine.enabled, let source = proposedSource else { return }
                do { try service.connect(source, codexConnection: proposedCodexConnection) } catch { alert(error.localizedDescription) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let source = proposedSource {
                if source.id == "codex-desktop" {
                    if proposedReadOnly {
                        Text("检测到 Codex 官方本机共享服务，将只读检查该服务内已加载的任务状态。可补捕运行中的任务；不会新建服务或发送任务，不保存正文。这个通道覆盖该服务的本机任务，不能确认具体桌面客户端或云端编排。断线后已开始任务继续保持，需明确结束或手动停止。")
                    } else {
                        Text("将自动查找 Codex，并备份、合并对应环境的 config.toml 与 hooks.json。若已有完成通知，将保留原通知程序和参数，由本功能记录匿名状态后原样转发；监测失败仍继续原通知。配置未被另行修改时，最后一个来源断开会恢复原入口；检测到变更时保留并提示核对。桌面端的 Local / Worktree 本机新任务通过官方 hooks 和完成通知接入；请在 Codex 审阅信任。CLI 和桌面端共用一份配置，独立识别来源，断开一项保留另一项。Cloud / Work Cloud 不在本地通道覆盖内，接入前已运行的任务不能补放开始事件。总开关保持关闭，收到有效任务事件后才确认接通；不保存任务正文。")
                    }
                } else if source.id == "codex-cli" {
                    Text("将自动查找 Codex，备份并合并对应环境的 config.toml 与 hooks.json。若已有完成通知，将保留原通知程序和参数，由本功能记录匿名状态后原样转发；监测失败仍继续原通知。配置未被另行修改时，最后一个来源断开会恢复原入口；检测到变更时保留并提示核对。CLI 与桌面端共用一份配置并独立识别来源。请在 Codex 审阅信任新增 hooks；接入不会重放过去的开始事件或开启总开关。仅使用匿名轮次和状态，不保存正文，缺少结束信号时继续保持。")
                } else if source.readsLocalStatus {
                    Text("每 5 秒只读检查已运行的 Kimi Code 1.0.1 本机任务状态。仅查询运行与等待数量，不读取提示词或回复，不修改 Kimi 配置。断开后停止读取；接入不会开启保持唤醒总开关。当前仍需真实任务验收。")
                } else {
                    Text("将备份并合并 \(KeepAwakeHookInstaller.path(source: source).path) 中本功能的 hook。保留其他配置；请在新会话验证。仅发送来源、匿名会话及状态。收到运行事件后持续保持，等待确认或信号中断不会自动释放；无法核实结束时需手动停止。当前为适配候选，尚未完成真实长任务验收。")
                }
            }
        }
        .confirmationDialog("授权合盖运行", isPresented: $showLidAuthorization, titleVisibility: .visible) {
            Button("继续系统授权") { if service.engine.enabled { service.lid.authorize() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将注册 SuperIsland 自己的系统辅助程序。启用后会在保持期间暂时改变系统合盖休眠设置，辅助程序每 30 秒续期，任务可持续运行；只有主程序异常停止续期时，才在最多 3 分钟后恢复系统设置。与其他电源工具冲突时停止并提示。首次启用后仍需测试本机合盖任务是否连续运行。")
        }
        .alert("保持唤醒", isPresented: $showMessage) { Button("好", role: .cancel) {} } message: { Text(message) }
    }
    private var status: some View {
        SettingGroup {
            VStack(alignment: .leading, spacing: 10) {
                Label(service.decision.title, systemImage: service.actualHold ? "cup.and.saucer.fill" : "moon.zzz")
                    .font(.headline).foregroundStyle(service.actualHold ? Color.green : Color.primary)
                Text(service.decision.detail).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(service.environment.hardware == .desktop ? "桌面 Mac · 交流电源" : service.environment.battery.map { "电量 \($0)%" } ?? "电源能力检查中")
                    Spacer()
                    Text(service.lidStatus)
                }.font(.caption).foregroundStyle(.secondary)
                if let error = service.runtimeError { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.status")
    }
    private var strategy: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup {
                HStack {
                    Text("运行模式")
                    Spacer()
                    Picker("运行模式", selection: Binding(get: { service.engine.mode }, set: service.selectMode)) {
                        Text("自动").tag(KeepAwakeEngine.Mode.automatic)
                        Text("手动").tag(KeepAwakeEngine.Mode.manual)
                    }.labelsHidden().frame(width: 180)
                }.padding(16).dataAnnotationID("si.ka.mode")
                if service.engine.mode == .manual {
                    SettingRowDivider()
                    HStack {
                        Text("保持时长")
                        Spacer()
                        Picker("保持时长", selection: $duration) {
                            Text("30 分钟").tag(30); Text("1 小时").tag(60)
                            Text("2 小时").tag(120); Text("直到手动停止").tag(0)
                        }.labelsHidden().frame(width: 180)
                        Button("开始") { service.manual(minutes: duration) }.buttonStyle(.borderedProminent)
                    }.padding(16).dataAnnotationID("si.ka.manual")
                }
            }
            SettingSectionLabel(title: "设备行为")
            SettingGroup {
                if service.isNotebook {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("合盖后继续运行"); Spacer()
                            if service.lid.enabled {
                                Button("关闭合盖运行") { service.lid.disable() }
                            } else { Button(service.lid.registered ? "启用合盖运行…" : "设置合盖支持…") { showLidAuthorization = true } }
                        }
                        Text(service.lidExplanation).font(.caption).foregroundStyle(.secondary)
                    }.padding(16).dataAnnotationID("si.ka.lid")
                    SettingRowDivider()
                }
                HStack {
                    Text("屏幕策略"); Spacer()
                    Picker("屏幕策略", selection: preference(\.screen)) {
                        ForEach(KeepAwakeEngine.ScreenPolicy.allCases, id: \.self) { policy in Text(policy.title).tag(policy) }
                    }.labelsHidden().frame(width: 200)
                }.padding(16).dataAnnotationID("si.ka.screen")
                if service.isNotebook && KeepAwakePower.hasExternalDisplay {
                    Text("检测到外接显示器：当前版本保留外屏，不执行会关闭全部屏幕的熄屏动作。")
                        .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 16)
                }
            }
            controls
            Text("普通保持只防止空闲休眠；合盖、用户主动睡眠和系统保护需分别处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var controls: some View {
        HStack {
            Button(service.engine.pauseDeadline.map { $0 > KeepAwakeClock.now() } == true ? "结束暂停" : "暂停 30 分钟") { service.pause() }
                .disabled(!service.engine.enabled).dataAnnotationID("si.ka.pause")
            Button("停止并恢复") { service.stop() }.dataAnnotationID("si.ka.stop")
            if service.engine.protection != nil {
                Button(service.recoveryInProgress ? "正在检查恢复…" : "恢复检查并继续") { service.resume() }
                    .disabled(!service.engine.enabled || service.recoveryInProgress)
            }
        }
    }
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保留原 17 项，新增本机 5 款工具的 CLI / 桌面端核验，共 \(KeepAwakeSource.all.count) 项。待验证不代表已接通，也不代表该形态已提供。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("搜索任务来源", text: $query).textFieldStyle(.roundedBorder)
            ForEach(sources) { source in
                SettingGroup {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.name).font(.headline)
                            Text(service.sourceStatus(source)).font(.caption).foregroundStyle(.secondary)
                            Text(source.integration).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if service.cleanupPendingSources.contains(source.id) {
                            Button("重试清理") {
                                do { try service.disconnect(source) } catch { alert(error.localizedDescription) }
                            }
                        } else if service.connections.contains(source.id) {
                            Button("断开") {
                                guard service.engine.enabled else { return }
                                do { try service.disconnect(source) } catch { alert(error.localizedDescription) }
                            }.disabled(!service.engine.enabled)
                        } else if source.canConnect {
                            Button("接入…") {
                                guard service.engine.enabled else { return }
                                do {
                                    proposedCodexConnection = try service.prepareCodexConnection(source)
                                    proposedSource = source; showConnection = true
                                } catch { alert(error.localizedDescription) }
                            }.disabled(!service.engine.enabled)
                        } else {
                            Text(source.isDeferred ? "暂缓接入" : source.id == "codex-desktop" ? "接口未提供" : "待验证")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16)
                }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.source." + source.id)
            }
            if sources.isEmpty { Text("没有匹配的来源").foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.sources")
    }
    private var protection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup {
                if service.isNotebook {
                    HStack {
                        Text("电池低于阈值时停止"); Spacer()
                        Stepper("\(service.preferences.minimumBattery)%", value: preference(\.minimumBattery), in: 5...50)
                            .frame(width: 130)
                    }.padding(16)
                    SettingRowDivider()
                    SettingToggleRow(title: "仅接通电源时运行", isOn: preference(\.acOnly))
                    SettingRowDivider()
                    SettingToggleRow(title: "遵循低电量模式", isOn: preference(\.respectLowPower))
                    SettingRowDivider()
                }
                HStack { Text("过热保护"); Spacer(); Text("始终开启").foregroundStyle(.secondary) }.padding(16)
                SettingRowDivider()
                SettingToggleRow(title: "任务完成提醒", description: "仅包含来源和状态，不含任务正文。", isOn: preference(\.notifyCompletion))
                    .dataAnnotationID("si.ka.notify")
                HStack {
                    Text(service.notificationStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("申请通知权限") { service.requestNotificationPermission() }
                }.padding(16)
            }.disabled(!service.engine.enabled)
                .accessibilityElement(children: .contain).dataAnnotationID("si.ka.protection")
            controls
            if service.isNotebook {
                SettingGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.lidExplanation).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("检查并释放租约") { service.lid.retryRelease() }.disabled(!service.engine.enabled || service.lid.busy || !service.lid.registered)
                            Button("撤销合盖授权") { Task { await service.lid.revoke() } }.disabled(!service.engine.enabled || service.lid.busy || !service.lid.registered)
                        }
                    }.padding(16)
                }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.helper")
            }
            SettingSectionLabel(title: "本次运行记录 · 仅状态，不保存任务正文")
            SettingGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(service.activity.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .contain).accessibilityLabel("本次运行记录").dataAnnotationID("si.ka.recovery")
        }
    }
    private func preference<Value>(_ path: WritableKeyPath<KeepAwakeEngine.Preferences, Value>) -> Binding<Value> {
        Binding(get: { service.preferences[keyPath: path] }, set: { value in service.updatePreferences { $0[keyPath: path] = value } })
    }
    private func alert(_ text: String) { message = text; showMessage = true }
}

private struct KeepAwakeRecapSettings: View {
    @ObservedObject var recap: KeepAwakeRecapController
    let enabled: Bool
    var body: some View {
        SettingGroup {
            SettingToggleRow(title: "开盖后自动显示回顾", description: "解锁后展示本次任务、保持与休眠结果；关闭后仍可从杯子菜单查看最近一次。",
                isOn: Binding(get: { recap.autoShow }, set: { _ = recap.setAutoShow($0) }))
                .toggleStyle(.switch).disabled(!enabled).dataAnnotationID("si.ka.recap.settings-auto")
            if let error = recap.preferenceError ?? recap.storageError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 10) }
        }
    }
}
