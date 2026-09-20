import SwiftUI

struct AdvancedSettingsView: View {
    @State private var showResetAlert = false
    @State private var screenOptions: [ScreenDetector.ScreenOption] = ScreenDetector.availableScreenOptions()
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var updater = AutoUpdater.shared
    @ObservedObject private var scheduler = ModuleRefreshScheduler.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Display ────────────────────────────────────────────────────
            SettingSectionLabel(title: "显示")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("动态岛显示在").font(.system(size: 13))
                        Text("选择指定显示器，或让 SuperIsland 自动选择")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $appState.displayIdentifier) {
                        ForEach(screenOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .onAppear { refreshScreenOptions() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )) { _ in refreshScreenOptions() }

            SettingSectionLabel(title: "能耗诊断")
            SettingGroup {
                if scheduler.diagnostics.isEmpty {
                    Text("没有计划中的刷新任务")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(scheduler.diagnostics.enumerated()), id: \.element.id) { index, job in
                        diagnosticRow(job)
                        if index < scheduler.diagnostics.count - 1 {
                            SettingRowDivider()
                        }
                    }
                }
            }

            SettingSectionLabel(title: "调试")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重置所有设置").font(.system(size: 13))
                        Text("恢复默认设置，并清除已设快捷键")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("重置") {
                        showResetAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .alert("重置所有设置？", isPresented: $showResetAlert) {
                        Button("取消", role: .cancel) {}
                        Button("重置", role: .destructive) { resetAllSettings() }
                    } message: {
                        Text("将恢复默认设置、清除快捷键，并退出 Linear 和 Last.fm。其他应用的数据不受影响。")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            SettingSectionLabel(title: "关于")
            SettingGroup {
                HStack {
                    Text("版本").font(.system(size: 13))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)

                SettingRowDivider()

                HStack {
                    Text("构建").font(.system(size: 13))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)

                SettingRowDivider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更新").font(.system(size: 13))
                        updateStatusText
                    }
                    Spacer()
                    updateButton
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var updateStatusText: some View {
        if case .failed(let message) = updater.state {
            Text(message).font(.system(size: 11)).foregroundColor(.red)
        } else if case .downloading(let progress) = updater.state {
            Text("正在下载 \(Int(progress * 100))%")
                .font(.system(size: 11)).foregroundColor(.secondary)
        } else if case .installing = updater.state {
            Text("正在安装...").font(.system(size: 11)).foregroundColor(.secondary)
        } else {
            switch updateChecker.checkState {
            case .idle:
                EmptyView()
            case .checking:
                Text("正在检查...").font(.system(size: 11)).foregroundColor(.secondary)
            case .noCompatibleRelease:
                Text("暂无适用更新").font(.system(size: 11)).foregroundColor(.secondary)
            case .upToDate:
                Text("已是最新版本").font(.system(size: 11)).foregroundColor(.green)
            case .updateAvailable(let version, _, _):
                Text("可更新到版本 \(version)").font(.system(size: 11)).foregroundColor(.orange)
            case .failed(let message):
                Text(message).font(.system(size: 11)).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if updater.isBusy {
            ProgressView().controlSize(.small)
        } else {
            switch updateChecker.checkState {
            case .checking:
                ProgressView().controlSize(.small)
            case .updateAvailable(_, let releaseURL, let downloadURL):
                Button("更新") {
                    if let downloadURL {
                        AutoUpdater.shared.start(downloadURL: downloadURL, releaseURL: releaseURL)
                    } else {
                        NSWorkspace.shared.open(releaseURL)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            default:
                Button("检查更新") {
                    updater.clearFailure()
                    updateChecker.checkNow()
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func resetAllSettings() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        ApplicationSettingsReset.reset(
            defaults: .standard,
            domain: domain,
            windowPreferences: .shared
        )
    }

    private func diagnosticRow(_ job: EnergyDiagnosticsSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.system(size: 13))
                Text("\(job.moduleName) · \(job.policy)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let lastError = job.lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(job.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(job.status == "Scheduled" ? .green : .secondary)
                if let duration = job.lastRunDuration {
                    Text("\(String(format: "%.0f", duration * 1000)) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let nextFireDate = job.nextFireDate {
                    Text("下次 \(nextFireDate, style: .relative)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func refreshScreenOptions() {
        screenOptions = ScreenDetector.availableScreenOptions()
        // If the stored display identifier no longer matches a connected
        // screen (e.g. the user unplugged it), fall back to Automatic.
        let currentID = appState.displayIdentifier
        if !currentID.isEmpty, !screenOptions.contains(where: { $0.id == currentID }) {
            appState.displayIdentifier = ""
        }
    }
}
