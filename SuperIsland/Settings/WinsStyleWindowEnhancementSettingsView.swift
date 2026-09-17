import AppKit
import AVFoundation
import SwiftUI

private enum WindowEnhancementPreview: Hashable {
    case overview
    case edgeSnap
    case snapIsland
    case aeroShake
    case dockPreview
    case missionControl
    case dockReverse
    case commandTab
    case action(WindowQuickAction)
    case layout(WindowLayout)

    var title: String {
        switch self {
        case .overview: "功能总览"
        case .edgeSnap: "屏幕边缘分屏"
        case .snapIsland: "悬浮分屏岛"
        case .aeroShake: "摇动窗口"
        case .dockPreview: "Dock 窗口预览"
        case .missionControl: "调度中心 Pro"
        case .dockReverse: "Dock 窗口反转"
        case .commandTab: "Cmd-Tab Plus"
        case .action(let action): action.title
        case .layout(let layout): layout.title
        }
    }

    var videoAssetName: String? {
        switch self {
        case .edgeSnap: "edgeSnap"
        case .snapIsland: "snapIsland_zh"
        case .aeroShake: "aeroShakeView_zh"
        case .dockPreview: "dockPreviewView_zh"
        case .missionControl: "missionControlProStatus"
        case .dockReverse: "flickDock"
        case .commandTab: "commandTabPlus"
        case .action(let action):
            switch action {
            case .closeWindow: "mission-close"
            case .quitApp: "mission-quit"
            case .dockDisplayLock: "dock-lock"
            case .hideAll: "hidden-all"
            case .hideOthers: "hidden-others"
            case .nextDisplay: "next-display"
            case .previousDisplay: "previous-display"
            case .centerWindow: "center"
            }
        case .overview, .layout: nil
        }
    }

    var layoutAssetName: String? {
        guard case .layout(let layout) = self else { return nil }
        return layout.previewAssetName
    }

    var layoutAssetExtension: String? {
        guard case .layout(let layout) = self else { return nil }
        return layout.previewAssetExtension
    }
}

private extension WindowLayout {
    var previewAssetName: String {
        switch self {
        case .leftHalf: "left-half"
        case .rightHalf: "right-half"
        case .maximize: "maximize"
        case .leftThird: "left-third"
        case .centerThird: "center-third"
        case .rightThird: "right-third"
        case .topHalf: "top-half"
        case .bottomHalf: "bottom-half"
        case .leftTwoThirds: "left-two-thirds"
        case .rightTwoThirds: "right-two-thirds"
        case .topLeftQuarter: "top-left-quarter"
        case .topRightQuarter: "top-right-quarter"
        case .bottomLeftQuarter: "bottom-left-quarter"
        case .bottomRightQuarter: "bottom-right-quarter"
        }
    }

    var previewAssetExtension: String {
        switch self {
        case .topLeftQuarter, .topRightQuarter,
             .bottomLeftQuarter, .bottomRightQuarter:
            "svg"
        default:
            "png"
        }
    }
}

struct WindowEnhancementSettingsView: View {
    @StateObject private var preferences = WindowEnhancementPreferences.shared
    @StateObject private var dockDisplayLockStatus = DockDisplayLockStatusStore.shared
    @State private var preview: WindowEnhancementPreview = .overview
    @State private var showAdvanced = false
    @State private var accessibilityState = PermissionsManager.shared.accessibilityAuthorizationState()
    @State private var screenRecordingState = PermissionsManager.shared.screenRecordingAuthorizationState()

    private let coreFeatures: [(String, WindowEnhancementPreview, ReferenceWritableKeyPath<WindowEnhancementPreferences, Bool>)] = [
        ("屏幕边缘分屏", .edgeSnap, \WindowEnhancementPreferences.edgeSnapEnabled),
        ("悬浮分屏岛", .snapIsland, \WindowEnhancementPreferences.snapIslandEnabled),
        ("摇动窗口", .aeroShake, \WindowEnhancementPreferences.aeroShakeEnabled),
        ("Dock 窗口预览", .dockPreview, \WindowEnhancementPreferences.dockPreviewEnabled),
        ("调度中心 Pro", .missionControl, \WindowEnhancementPreferences.missionControlEnabled),
        ("Dock 窗口反转", .dockReverse, \WindowEnhancementPreferences.dockReverseEnabled),
        ("Cmd-Tab Plus", .commandTab, \WindowEnhancementPreferences.cmdTabPlusEnabled)
    ]

    var body: some View {
        if showAdvanced {
            WindowEnhancementAdvancedView(preferences: preferences) { showAdvanced = false }
        } else {
            ScrollView {
                mainSettings
                    .padding(.bottom, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var mainSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingSectionLabel(title: "窗口增强")
            SettingGroup {
                SettingToggleRow(
                    title: "启用窗口增强",
                    description: "开启后由 SuperIsland 在后台响应拖窗、Dock 与快捷键操作",
                    isOn: $preferences.isEnabled
                )
            }

            HStack(alignment: .top, spacing: 16) {
                WindowEnhancementDemoView(preview: preview, accent: accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 278)

                VStack(spacing: 7) {
                    ForEach(Array(coreFeatures.enumerated()), id: \.offset) { _, feature in
                        PreviewFeatureToggleRow(
                            title: feature.0,
                            statusText: nil,
                            isOn: Binding(
                                get: { preferences[keyPath: feature.2] },
                                set: { preferences[keyPath: feature.2] = $0 }
                            ),
                            onPreview: { preview = feature.1 },
                            onExit: { resetPreview(ifCurrent: feature.1) }
                        )
                    }
                }
                .frame(width: 310)
            }

            SettingSectionLabel(title: "调度中心 Pro")
            SettingGroup {
                actionRow(.closeWindow)
                SettingRowDivider()
                actionRow(.quitApp)
            }

            SettingSectionLabel(title: "快捷功能")
            SettingGroup {
                finderFileTrashRow
                SettingRowDivider()
                dockDisplayLockRow
                SettingRowDivider()
                actionRow(.hideAll)
                SettingRowDivider()
                actionRow(.hideOthers)
                SettingRowDivider()
                actionRow(.nextDisplay)
                SettingRowDivider()
                actionRow(.previousDisplay)
                SettingRowDivider()
                actionRow(.centerWindow)
            }

            SettingSectionLabel(title: "窗口布局")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                ForEach(WindowLayout.shortcutLayouts) { layout in
                    layoutCard(layout)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            SettingSectionLabel(title: "权限与降级")
            SettingGroup {
                permissionRow(
                    title: "辅助功能",
                    description: "布局、移动、缩放和关闭窗口所必需",
                    state: accessibilityState,
                    requestAction: requestAccessibility,
                    openSettingsAction: PermissionsManager.shared.openAccessibilitySettings
                )
                SettingRowDivider()
                permissionRow(
                    title: "屏幕录制（可选）",
                    description: "用于本地窗口缩略图；拒绝后自动使用标题模式",
                    state: screenRecordingState,
                    requestAction: requestScreenRecording,
                    openSettingsAction: PermissionsManager.shared.openScreenRecordingSettings
                )
                SettingRowDivider()
                permissionTargetRow
            }

            if let feedback = preferences.lastFeedback {
                Text(feedback)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("高级…") { showAdvanced = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .toggleStyle(.switch)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            WindowEnhancementController.shared.refreshSystemIntegrations()
        }
        .dataAnnotationID("window-enhancement-settings")
    }

    private func actionRow(_ action: WindowQuickAction) -> some View {
        PreviewActionRow(
            action: action,
            isOn: Binding(
                get: { preferences.isActionEnabled(action) },
                set: { preferences.setActionEnabled($0, action: action) }
            ),
            preferences: preferences,
            onPreview: { preview = .action(action) },
            onExit: { resetPreview(ifCurrent: .action(action)) }
        )
    }

    private var finderFileTrashRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(FinderFileShortcut.title)
                    .font(.system(size: 13))
                Text("Finder／桌面选中文件移到废纸篓，可恢复")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ShortcutRecorderButton(targetID: FinderFileShortcut.id, preferences: preferences)
            Toggle(FinderFileShortcut.title, isOn: $preferences.fileTrashEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .help("仅在 Finder 或桌面选中文件时移到废纸篓；正在重命名时不执行。快捷键与开关独立。")
        .dataAnnotationID("window-enhancement-file-trash")
    }

    private var dockDisplayLockRow: some View {
        DockDisplayLockActionRow(
            isOn: Binding(
                get: { preferences.isActionEnabled(.dockDisplayLock) },
                set: { preferences.setActionEnabled($0, action: .dockDisplayLock) }
            ),
            windowEnhancementEnabled: preferences.isEnabled,
            preferences: preferences,
            status: dockDisplayLockStatus.status,
            onLock: {
                WindowEnhancementController.shared.perform(action: .dockDisplayLock)
            },
            onPreview: { preview = .action(.dockDisplayLock) },
            onExit: { resetPreview(ifCurrent: .action(.dockDisplayLock)) }
        )
    }

    private func layoutCard(_ layout: WindowLayout) -> some View {
        PreviewLayoutCard(
            layout: layout,
            preferences: preferences,
            onPreview: { preview = .layout(layout) },
            onExit: { resetPreview(ifCurrent: .layout(layout)) }
        )
    }

    private func permissionRow(
        title: String,
        description: String,
        state: PermissionAuthorizationState,
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(description).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Label(permissionStateTitle(state), systemImage: permissionStateIcon(state))
                    .font(.system(size: 11))
                    .foregroundColor(permissionStateColor(state))

                switch state {
                case .notRequested:
                    Button("请求权限", action: requestAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .denied, .revoked:
                    Button("打开系统设置", action: openSettingsAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .grantedRequiresRestart:
                    Button("完全退出 App") { NSApp.terminate(nil) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .granted:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var permissionTargetRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("当前授权目标")
                    .font(.system(size: 12, weight: .medium))
                Text(authorizationTargetName)
                    .font(.system(size: 11, weight: .medium))
                Text(Bundle.main.bundleURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("重新检测") {
                    refreshPermissions()
                    WindowEnhancementController.shared.refreshSystemIntegrations()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu("打开权限设置") {
                    Button("辅助功能") { PermissionsManager.shared.openAccessibilitySettings() }
                    Button("屏幕与系统音频录制") { PermissionsManager.shared.openScreenRecordingSettings() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var authorizationTargetName: String {
        let fallback = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fallback
    }

    private func permissionStateTitle(_ state: PermissionAuthorizationState) -> String {
        switch state {
        case .notRequested: "未请求"
        case .denied: "已拒绝"
        case .grantedRequiresRestart: "已授权 · 待重启"
        case .granted: "已生效"
        case .revoked: "授权已撤销"
        }
    }

    private func permissionStateIcon(_ state: PermissionAuthorizationState) -> String {
        switch state {
        case .notRequested: "questionmark.circle"
        case .denied: "xmark.circle.fill"
        case .grantedRequiresRestart: "arrow.clockwise.circle.fill"
        case .granted: "checkmark.circle.fill"
        case .revoked: "exclamationmark.triangle.fill"
        }
    }

    private func permissionStateColor(_ state: PermissionAuthorizationState) -> Color {
        switch state {
        case .notRequested: .secondary
        case .denied: .red
        case .grantedRequiresRestart: .orange
        case .granted: .green
        case .revoked: .orange
        }
    }

    private var accentColor: Color {
        switch preferences.accentName {
        case "purple": .purple
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "gray": .gray
        default: .blue
        }
    }

    private func resetPreview(ifCurrent candidate: WindowEnhancementPreview) {
        if preview == candidate {
            preview = .overview
        }
    }

    private func refreshPermissions() {
        let permissions = PermissionsManager.shared
        accessibilityState = permissions.accessibilityAuthorizationState()
        screenRecordingState = permissions.screenRecordingAuthorizationState()
    }

    private func requestAccessibility() {
        PermissionsManager.shared.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            refreshPermissions()
            WindowEnhancementController.shared.refreshSystemIntegrations()
        }
    }

    private func requestScreenRecording() {
        let permissions = PermissionsManager.shared
        let wasGranted = permissions.checkScreenRecording()
        let granted = permissions.requestScreenRecordingAccess()

        if granted {
            if !wasGranted && !permissions.screenRecordingGrantedAtProcessLaunch {
                preferences.publishFeedback("屏幕录制权限已授权，需完全退出并重新打开 SuperIsland 后生效")
            }
        } else {
            preferences.publishFeedback("请在“系统设置 > 隐私与安全性 > 屏幕与系统音频录制”中允许 SuperIsland；授权后需重新启动 App")
            permissions.openScreenRecordingSettings()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { refreshPermissions() }
    }
}

private struct PreviewFeatureToggleRow: View {
    let title: String
    let statusText: String?
    @Binding var isOn: Bool
    let onPreview: () -> Void
    let onExit: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            if let statusText {
                Text(statusText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(
            Color.white.opacity((hovered || focused) ? 0.085 : 0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onHover { inside in
            hovered = inside
            (inside || focused) ? onPreview() : onExit()
        }
        .onChange(of: focused) { _, isFocused in
            (isFocused || hovered) ? onPreview() : onExit()
        }
        .help(
            title == "调度中心 Pro"
                ? "在 Mission Control 或 App Exposé 中识别鼠标指向的精确窗口，并提供关闭窗口；退出 App 仍会二次确认。"
                : title
        )
    }
}

private struct PreviewActionRow: View {
    let action: WindowQuickAction
    @Binding var isOn: Bool
    @ObservedObject var preferences: WindowEnhancementPreferences
    let onPreview: () -> Void
    let onExit: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if action == .hideAll {
                    Text("第一次收起全部，第二次恢复刚才收起的窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            ShortcutRecorderButton(targetID: action.shortcutID, preferences: preferences)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .frame(height: action == .hideAll ? 58 : 50)
        .background(Color.white.opacity((hovered || focused) ? 0.025 : 0))
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onHover { inside in
            hovered = inside
            (inside || focused) ? onPreview() : onExit()
        }
        .onChange(of: focused) { _, isFocused in
            (isFocused || hovered) ? onPreview() : onExit()
        }
    }
}

private struct DockDisplayLockActionRow: View {
    @Binding var isOn: Bool
    let windowEnhancementEnabled: Bool
    @ObservedObject var preferences: WindowEnhancementPreferences
    let status: DockDisplayLockStatus
    let onLock: () -> Void
    let onPreview: () -> Void
    let onExit: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dock 固定到显示器")
                    .font(.system(size: 13))
                Text(status.summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if !status.detail.isEmpty {
                    Text(status.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Button("固定到鼠标所在显示器", action: onLock)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!windowEnhancementEnabled || !isOn || status.phase == .moving)
                .help(lockButtonHelp)
            ShortcutRecorderButton(
                targetID: WindowQuickAction.dockDisplayLock.shortcutID,
                preferences: preferences
            )
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("仅启用或关闭 Dock 固定能力；开启后仍需选择目标显示器")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 66)
        .background(Color.white.opacity((hovered || focused) ? 0.025 : 0))
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onHover { inside in
            hovered = inside
            (inside || focused) ? onPreview() : onExit()
        }
        .onChange(of: focused) { _, isFocused in
            (isFocused || hovered) ? onPreview() : onExit()
        }
    }

    private var statusColor: Color {
        switch status.phase {
        case .locked: .green
        case .moving: .blue
        case .paused: .orange
        case .failed: .red
        case .disabled, .idle: .secondary
        }
    }

    private var lockButtonHelp: String {
        if !windowEnhancementEnabled {
            return "请先开启窗口增强"
        }
        if !isOn {
            return "请先开启 Dock 固定能力"
        }
        return "把 Dock 移到当前鼠标所在显示器；位置回读验证成功后才会显示为已固定"
    }
}

private struct PreviewLayoutCard: View {
    let layout: WindowLayout
    @ObservedObject var preferences: WindowEnhancementPreferences
    let onPreview: () -> Void
    let onExit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black.opacity(0.32)
                if let image = WindowEnhancementAssetLoader.image(
                    named: layout.previewAssetName,
                    extension: layout.previewAssetExtension,
                    folder: "settings-layouts"
                ) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    WindowLayoutGlyph(layout: layout, accent: .blue)
                        .padding(18)
                }
            }
            .aspectRatio(5 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity((hovered || focused) ? 0.22 : 0.10), lineWidth: 1)
            )
            .scaleEffect((hovered || focused) && !reduceMotion ? 1.015 : 1)

            ShortcutRecorderButton(targetID: layout.shortcutID, preferences: preferences)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered || focused)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onHover { inside in
            hovered = inside
            (inside || focused) ? onPreview() : onExit()
        }
        .onChange(of: focused) { _, isFocused in
            (isFocused || hovered) ? onPreview() : onExit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layout.title)布局")
    }
}

private struct WindowEnhancementDemoView: View {
    let preview: WindowEnhancementPreview
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            previewContent
                .id(preview)
                .transition(.opacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: preview)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(preview.title)演示")
    }

    @ViewBuilder
    private var previewContent: some View {
        if preview == .overview {
            assetImage(named: "macbook-hero", extension: "png", folder: "settings-previews")
                .padding(12)
        } else if let videoName = preview.videoAssetName,
                  let url = WindowEnhancementAssetLoader.url(
                    named: videoName,
                    extension: "mp4",
                    folder: "settings-previews"
                  ) {
            LoopingPreviewVideo(url: url, shouldPlay: !reduceMotion)
                .padding(1)
        } else if let imageName = preview.layoutAssetName,
                  let fileExtension = preview.layoutAssetExtension {
            assetImage(named: imageName, extension: fileExtension, folder: "settings-layouts")
                .padding(12)
        } else {
            fallbackPreview
        }
    }

    @ViewBuilder
    private func assetImage(named name: String, extension fileExtension: String, folder: String) -> some View {
        if let image = WindowEnhancementAssetLoader.image(
            named: name,
            extension: fileExtension,
            folder: folder
        ) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            fallbackPreview
        }
    }

    private var fallbackPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(accent)
            Text(preview.title)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(18)
    }
}

private enum WindowEnhancementAssetLoader {
    static func url(named name: String, extension fileExtension: String, folder: String) -> URL? {
        let subdirectories: [String?] = [
            folder,
            "WindowEnhancementAssets/\(folder)",
            "prototype/assets/\(folder)",
            nil
        ]

        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }

        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        for subdirectory in subdirectories.compactMap({ $0 }) {
            let candidate = resourceURL
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent("\(name).\(fileExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func image(named name: String, extension fileExtension: String, folder: String) -> NSImage? {
        guard let url = url(named: name, extension: fileExtension, folder: folder) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct LoopingPreviewVideo: NSViewRepresentable {
    let url: URL
    let shouldPlay: Bool

    func makeNSView(context: Context) -> LoopingPreviewPlayerView {
        let view = LoopingPreviewPlayerView()
        view.configure(url: url, shouldPlay: shouldPlay)
        return view
    }

    func updateNSView(_ nsView: LoopingPreviewPlayerView, context: Context) {
        nsView.configure(url: url, shouldPlay: shouldPlay)
    }

    static func dismantleNSView(_ nsView: LoopingPreviewPlayerView, coordinator: ()) {
        nsView.stop()
    }
}

private final class LoopingPreviewPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var representedURL: URL?
    private var playbackRequested = false
    private var clipViewObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipView()
        updatePlaybackState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeClipView()
        updatePlaybackState()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        updatePlaybackState()
    }

    func configure(url: URL, shouldPlay: Bool) {
        playbackRequested = shouldPlay
        if representedURL != url {
            tearDownPlayer()
            representedURL = url

            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.actionAtItemEnd = .none
            queuePlayer.automaticallyWaitsToMinimizeStalling = true

            let item = AVPlayerItem(url: url)
            player = queuePlayer
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            playerLayer.player = queuePlayer
            queuePlayer.seek(
                to: CMTime(seconds: 0.08, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        updatePlaybackState()
    }

    func stop() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
            self.clipViewObserver = nil
        }
        playbackRequested = false
        tearDownPlayer()
    }

    private func observeClipView() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
            self.clipViewObserver = nil
        }

        var ancestor = superview
        while let view = ancestor {
            if let clipView = view as? NSClipView {
                clipView.postsBoundsChangedNotifications = true
                clipViewObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    self?.updatePlaybackState()
                }
                break
            }
            ancestor = view.superview
        }
    }

    private func updatePlaybackState() {
        let isVisible = window != nil
            && !isHiddenOrHasHiddenAncestor
            && visibleRect.width > 4
            && visibleRect.height > 4

        if playbackRequested && isVisible {
            player?.play()
        } else {
            player?.pause()
        }
    }

    private func tearDownPlayer() {
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        playerLayer.player = nil
        looper = nil
        player = nil
        representedURL = nil
    }

    deinit {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
        }
    }
}
