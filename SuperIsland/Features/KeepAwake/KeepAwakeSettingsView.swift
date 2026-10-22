import SwiftUI

struct KeepAwakeSettingsView: View {
    @ObservedObject private var service = KeepAwakeService.shared
    @State private var tab = 0
    @State private var duration = 60
    @State private var query = ""
    @State private var proposedSource: KeepAwakeSource?
    @State private var showConnection = false
    @State private var showLidAuthorization = false
    @State private var message = ""
    @State private var showMessage = false
    private var sources: [KeepAwakeSource] {
        KeepAwakeSource.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保持唤醒").font(.title2.weight(.semibold))
            Text("按本地任务或手动计时保持 Mac 工作，屏幕与合盖支持分别管理。")
                .font(.callout).foregroundStyle(.secondary)
            status
            Picker("管理分区", selection: $tab) {
                Text("运行策略").tag(0); Text("任务来源 · \(KeepAwakeSource.all.count)").tag(1); Text("保护与恢复").tag(2)
            }.pickerStyle(.segmented)
            switch tab {
            case 0: strategy
            case 1: sourceList
            default: protection
            }
        }
        .accessibilityElement(children: .contain)
        .dataAnnotationID("si.ka.settings")
        .confirmationDialog("接入任务来源", isPresented: $showConnection, titleVisibility: .visible) {
            Button(proposedSource?.readsLocalStatus == true ? "启用只读接入" : "备份并接入") {
                guard let source = proposedSource else { return }
                do { try service.connect(source) } catch { alert(error.localizedDescription) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let source = proposedSource {
                if source.id == "codex-desktop" {
                    Text("仅连接 Codex 已经运行的官方本机共享服务，每 5 秒检查线程与轮次状态。可补捕该服务中正在运行的任务；不会启动新服务、恢复或发送任务，不保存标题、消息或工具正文。没有公开本机接口的桌面会话和云端任务不能由此接入。断线后已开始任务继续保持，需明确结束或手动停止。")
                } else if source.id == "codex-cli" {
                    Text("将备份并合并 Codex 的 config.toml 与 hooks.json，接入运行/等待事件和官方完成通知；已有其他 notify 时会停止并提示冲突。请在 Codex 中审阅并信任新增 hooks，接入不会重放已过去的开始事件，也不会开启保持唤醒总开关。仅使用匿名轮次和状态，不保存正文；缺少结束信号时继续保持。")
                } else if source.readsLocalStatus {
                    Text("每 5 秒只读检查已运行的 Kimi Code 1.0.1 本机任务状态。仅查询运行与等待数量，不读取提示词或回复，不修改 Kimi 配置。断开后停止读取；接入不会开启保持唤醒总开关。当前仍需真实任务验收。")
                } else {
                    Text("将备份并合并 \(KeepAwakeHookInstaller.path(source: source).path) 中本功能的 hook。保留其他配置；请在新会话验证。仅发送来源、匿名会话及状态。收到运行事件后持续保持，等待确认或信号中断不会自动释放；无法核实结束时需手动停止。当前为适配候选，尚未完成真实长任务验收。")
                }
            }
        }
        .confirmationDialog("授权合盖运行", isPresented: $showLidAuthorization, titleVisibility: .visible) {
            Button("继续系统授权") { service.lid.authorize() }
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
                SettingToggleRow(title: "启用保持唤醒", description: "自动模式等待有效任务，手动模式需要点击开始。", isOn: Binding(get: { service.engine.enabled }, set: service.setEnabled))
                    .dataAnnotationID("si.ka.master")
                SettingRowDivider()
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
                    .disabled(service.recoveryInProgress)
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
                                do { try service.disconnect(source) } catch { alert(error.localizedDescription) }
                            }
                        } else if source.canConnect {
                            Button("接入…") { proposedSource = source; showConnection = true }
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
            }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.protection")
            controls
            if service.isNotebook {
                SettingGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.lidExplanation).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("检查并释放租约") { service.lid.retryRelease() }.disabled(service.lid.busy || !service.lid.registered)
                            Button("撤销合盖授权") { Task { await service.lid.revoke() } }.disabled(service.lid.busy || !service.lid.registered)
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
