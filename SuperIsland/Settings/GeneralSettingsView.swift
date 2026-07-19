import AppKit
import SwiftUI

private struct MascotGridPicker: View {
    @ObservedObject private var manager = MascotManager.shared
    @State private var downloadingSlug: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(manager.availableMascots) { entry in
                mascotCell(entry)
            }
        }
    }

    private func mascotCell(_ entry: MascotCatalogEntry) -> some View {
        let isSelected = manager.selectedSlug == entry.slug
        let isDownloaded = manager.isMascotDownloaded(entry.slug)
        let isDownloading = downloadingSlug == entry.slug

        return Button {
            guard !isDownloading else { return }
            if isDownloaded {
                manager.selectMascot(entry.slug)
            } else {
                downloadingSlug = entry.slug
                Task {
                    let didDownload = await manager.downloadMascot(entry.slug)
                    downloadingSlug = nil
                    if didDownload {
                        manager.selectMascot(entry.slug)
                    }
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                        .frame(height: 80)

                    AsyncImage(url: URL(string: entry.thumbnailURL)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 60, height: 60)

                    if !isDownloaded {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                if isDownloading {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(4)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.accentColor)
                                        .padding(4)
                                }
                            }
                        }
                        .frame(height: 80)
                    }
                }

                Text(entry.name)
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                .frame(height: 80)
                .offset(y: -10)
        )
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var mascotManager = MascotManager.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var permissionStates: [PermissionType: Bool] = [:]
    private let permissionRefreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Startup
            SettingSectionLabel(title: "启动")
            SettingGroup {
                HStack {
                    Text("登录时启动").font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newValue in
                            newValue ? LaunchAtLogin.enable() : LaunchAtLogin.disable()
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)

                SettingRowDivider()
                SettingToggleRow(title: "显示菜单栏图标", isOn: $appState.showMenuBarIcon)
                SettingRowDivider()
                SettingToggleRow(title: "在屏幕录制中显示", isOn: $appState.showInScreenRecordings)
            }

            // Display
            SettingSectionLabel(title: "显示")
            SettingGroup {
                SettingToggleRow(title: "在所有空间显示", isOn: $appState.showOnAllSpaces)
                if appState.presentationHasNotch {
                    SettingRowDivider()
                    SettingToggleRow(title: "隐藏侧边槽位", isOn: $appState.hideSideSlots)
                }
                SettingRowDivider()
                SettingToggleRow(title: "全屏时隐藏", isOn: $appState.hideOnFullscreen)
                SettingRowDivider()
                HStack {
                    Text("动画速度").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $appState.animationSpeed) {
                        Text("正常").tag(1.0)
                        Text("降低").tag(1.5)
                        Text("最小").tag(2.0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }

            // Power
            SettingSectionLabel(title: "电源")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("电源模式").font(.system(size: 13))
                        Text(appState.energyMode.description)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: energyModeBinding) {
                        ForEach(EnergyMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 132)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                SettingRowDivider()
                SettingToggleRow(
                    title: "减少动画",
                    description: "Use simpler motion for island transitions and visual effects.",
                    isOn: $appState.reduceAnimations
                )

                SettingRowDivider()
                SettingToggleRow(
                    title: "暂停后台扩展刷新",
                    description: "Keep inactive extensions quiet until they are visible or selected.",
                    isOn: $appState.disableBackgroundExtensionRefresh
                )

                SettingRowDivider()
                SettingToggleRow(
                    title: "低电量建议",
                    description: "Offer Low Power mode when the Mac switches to battery or refresh work stays busy.",
                    isOn: lowPowerSuggestionBinding
                )
            }
            .onChange(of: appState.reduceAnimations) { _, _ in appState.refreshEnergyState() }
            .onChange(of: appState.disableBackgroundExtensionRefresh) { _, _ in appState.refreshEnergyState() }

            // Behavior
            SettingSectionLabel(title: "行为")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("展开后收起延迟").font(.system(size: 13))
                        Text("展开内容保持可见的时间")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.expandedAutoDismissDelay,
                        step: 0.5,
                        range: 0.1...10.0
                    ) { "\(String(format: "%.1f", $0))s" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                SettingRowDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("悬停展开延迟").font(.system(size: 13))
                        Text("悬停在刘海区域多久后预览展开")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.hoverExpandDelay,
                        step: 0.05,
                        range: 0.0...1.5
                    ) { "\(String(format: "%.2f", $0))s" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            // Interaction
            SettingSectionLabel(title: "交互")
            SettingGroup {
                SettingToggleRow(title: "动态岛表面滑动", isOn: $appState.islandSurfaceSwipeEnabled)
                SettingRowDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("刘海触觉反馈强度").font(.system(size: 13))
                        Text("进入刘海区域时的反馈强度")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $appState.notchHapticIntensity) {
                        ForEach(NotchHapticIntensity.allCases) { intensity in
                            Text(intensity.title).tag(intensity.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                SettingRowDivider()
                SettingToggleRow(
                    title: "允许 Command+Q 退出",
                    description: "Turn this off to prevent accidental quits while interacting with the notch.",
                    isOn: $appState.allowQuitHotkey
                )
            }

            // Permissions
            SettingSectionLabel(title: "权限")
            SettingGroup {
                permissionRow(.accessibility,
                    title: "辅助功能", icon: "figure.stand",
                    description: "Gesture detection and system events")
                SettingRowDivider()
                permissionRow(.calendar,
                    title: "日历", icon: "calendar",
                    description: "Show upcoming events in the island")
                SettingRowDivider()
                permissionRow(.location,
                    title: "定位", icon: "location.fill",
                    description: "Weather information for your location")
                SettingRowDivider()
                permissionRow(.bluetooth,
                    title: "蓝牙", icon: "wave.3.right.circle.fill",
                    description: "Connected device notifications")
            }

            // Mascot
            SettingSectionLabel(title: "吉祥物")
            SettingGroup {
                MascotGridPicker()
                    .padding(14)

                if let loadError = mascotManager.loadError {
                    SettingRowDivider()
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                SettingRowDivider()
                SettingToggleRow(title: "在番茄钟中显示吉祥物", isOn: $mascotManager.showInPomodoro)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { refreshPermissionStates() }
        .onReceive(permissionRefreshTimer) { _ in refreshPermissionStates() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ permission: PermissionType,
        title: String, icon: String, description: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(permissionGranted(permission) ? .green : .secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(description).font(.system(size: 11)).foregroundColor(.secondary)
            }

            Spacer()

            if permissionGranted(permission) {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            } else {
                Button("授权") { requestPermission(permission) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func permissionGranted(_ permission: PermissionType) -> Bool {
        permissionStates[permission] ?? false
    }

    private var energyModeBinding: Binding<EnergyMode> {
        Binding(
            get: { appState.energyMode },
            set: { appState.energyMode = $0 }
        )
    }

    private var lowPowerSuggestionBinding: Binding<Bool> {
        Binding(
            get: { !appState.lowPowerSuggestionDoNotAskAgain },
            set: { appState.lowPowerSuggestionDoNotAskAgain = !$0 }
        )
    }

    private func refreshPermissionStates() {
        permissionStates[.accessibility] = PermissionsManager.shared.checkAccessibility()
        permissionStates[.calendar] = PermissionsManager.shared.checkCalendar()
        permissionStates[.location] = PermissionsManager.shared.checkLocation()
        permissionStates[.bluetooth] = PermissionsManager.shared.checkBluetooth()
    }

    private func requestPermission(_ permission: PermissionType) {
        PermissionsManager.shared.request(permission)
        refreshPermissionStates()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshPermissionStates()
            try? await Task.sleep(nanoseconds: 900_000_000)
            refreshPermissionStates()
        }
    }
}
