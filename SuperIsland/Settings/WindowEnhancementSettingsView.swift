import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

struct WindowEnhancementAdvancedView: View {
    @ObservedObject var preferences: WindowEnhancementPreferences
    let onDone: () -> Void

    private let accents: [(String, Color)] = [
        ("gray", .gray), ("blue", .blue), ("purple", .purple),
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("高级选项")
                        .font(.system(size: 18, weight: .semibold))

                    SettingGroup {
                        SettingToggleRow(title: "预留台前调度空间", isOn: $preferences.reserveStageManagerSpace)
                        SettingRowDivider()
                        SettingToggleRow(title: "分屏窗口间距", isOn: $preferences.windowSpacingEnabled)
                        SettingRowDivider()
                        HStack(spacing: 12) {
                            Text("强调色").font(.system(size: 13))
                            Spacer(minLength: 12)
                            ForEach(accents, id: \.0) { name, color in
                                Button {
                                    preferences.accentName = name
                                } label: {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 20, height: 20)
                                        .overlay {
                                            if preferences.accentName == name {
                                                Circle()
                                                    .stroke(Color.white.opacity(0.95), lineWidth: 2)
                                                    .padding(3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(name) 强调色")
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                    }

                    SettingGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("排除 App")
                                .font(.system(size: 14, weight: .medium))
                            Text("SuperIsland 会排除以下 App，不响应快捷键和分屏功能")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                        SettingRowDivider()

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(preferences.excludedBundleIDs, id: \.self) { bundleID in
                                excludedAppRow(bundleID)
                            }
                            Button(action: chooseApplication) {
                                VStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.055))
                                        .frame(width: 58, height: 54)
                                        .overlay {
                                            Image(systemName: "plus")
                                                .font(.system(size: 23, weight: .semibold))
                                                .foregroundColor(.secondary)
                                        }
                                    Text("添加")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("添加排除 App")
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    }

                    SettingGroup {
                        Text("关于")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                        SettingRowDivider()
                        HStack {
                            Text(versionLabel)
                                .font(.system(size: 13))
                            Spacer()
                            if isWE1DebugBundle {
                                Text("测试构建不检查更新")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            } else {
                                Button("检查新版本") { UpdateChecker.shared.checkNow() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                    }
                }
                .padding(.bottom, 18)
            }

            Divider()
            HStack {
                Spacer()
                Button("完成", action: onDone)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 4)
            .frame(height: 50)
        }
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .topLeading)
        .toggleStyle(.switch)
        .dataAnnotationID("window-enhancement-advanced-settings")
    }

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard Bundle.main.bundleIdentifier == "com.workview.SuperIsland.WE1Debug",
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            return "版本 \(version)"
        }
        return "版本 \(version) · 测试构建 \(build)"
    }

    private var isWE1DebugBundle: Bool {
        Bundle.main.bundleIdentifier == "com.workview.SuperIsland.WE1Debug"
    }

    private func excludedAppRow(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url?.deletingPathExtension().lastPathComponent ?? "应用不可用"
        return HStack(spacing: 9) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12))
                Text(bundleID).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                preferences.removeExcludedApp(bundleID: bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(name)")
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要排除的 App"
        panel.prompt = "排除"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        preferences.addExcludedApp(bundleID: bundleID)
    }
}

struct ShortcutRecorderButton: View {
    private enum FeedbackTone {
        case success
        case warning
        case error

        var color: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }
    }

    let targetID: String
    @ObservedObject var preferences: WindowEnhancementPreferences
    @ObservedObject private var recorder = ShortcutRecorderController.shared
    @State private var feedbackText: String?
    @State private var feedbackTone: FeedbackTone = .success
    @State private var attemptID = UUID()

    private var isRecording: Bool {
        recorder.recordingTargetID == targetID
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ZStack(alignment: .trailing) {
                Button {
                    attemptID = UUID()
                    feedbackText = nil
                    recorder.start(targetID: targetID) { event in
                        if event.keyCode == UInt16(kVK_Escape) {
                            attemptID = UUID()
                            recorder.stop()
                            setFeedback("已取消录入", tone: .success)
                            return
                        }
                        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                        if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)),
                           modifiers.isEmpty {
                            attemptID = UUID()
                            _ = preferences.setShortcut(nil, for: targetID)
                            recorder.stop()
                            setFeedback("已清除快捷键", tone: .success)
                            return
                        }
                        guard let shortcut = WindowShortcut.from(event: event) else {
                            setFeedback("请同时按下 ⌘、⌥、⌃ 或 ⇧", tone: .error)
                            NSSound.beep()
                            return
                        }

                        let previous = preferences.shortcut(for: targetID)
                        guard preferences.setShortcut(shortcut, for: targetID) else {
                            setFeedback(
                                preferences.lastFeedback ?? "快捷键不可用，已保留原设置",
                                tone: .error
                            )
                            NSSound.beep()
                            return
                        }

                        recorder.stop()
                        verifyRegistration(of: shortcut, previous: previous)
                    }
                } label: {
                    Text(
                        isRecording
                            ? "请按快捷键…"
                            : (preferences.shortcut(for: targetID)?.formattedDisplay ?? "设置快捷键")
                    )
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary.opacity(0.82))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if preferences.shortcut(for: targetID) != nil {
                    Button {
                        attemptID = UUID()
                        _ = preferences.setShortcut(nil, for: targetID)
                        recorder.stop()
                        setFeedback("已清除快捷键", tone: .success)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除快捷键")
                }
            }
            .frame(width: 132, height: 28)
            .background(
                Color.white.opacity(isRecording ? 0.10 : 0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isRecording ? Color.accentColor.opacity(0.65) : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )

            if let feedbackText {
                Text(feedbackText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(feedbackTone.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 132, alignment: .trailing)
                    .help(feedbackText)
                    .accessibilityLabel(feedbackText)
            }
        }
        .frame(width: 132, alignment: .trailing)
        .frame(minHeight: 28, alignment: .trailing)
        .onDisappear {
            attemptID = UUID()
            recorder.stop(ifTarget: targetID)
        }
    }

    private func verifyRegistration(of shortcut: WindowShortcut, previous: WindowShortcut?) {
        let currentAttemptID = UUID()
        attemptID = currentAttemptID
        setFeedback("正在注册…", tone: .success)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard attemptID == currentAttemptID else { return }
            if preferences.shortcut(for: targetID) == shortcut {
                if let warning = highRiskWarning(for: shortcut) {
                    setFeedback(warning, tone: .warning)
                } else {
                    setFeedback("已设置 \(shortcut.formattedDisplay)", tone: .success)
                }
                return
            }

            let preserved = preferences.shortcut(for: targetID) == previous
            setFeedback(
                preserved
                    ? (preferences.lastFeedback ?? "注册失败，已保留原设置")
                    : "注册失败，请重新设置",
                tone: .error
            )
        }
    }

    private func highRiskWarning(for shortcut: WindowShortcut) -> String? {
        guard targetID != FinderFileShortcut.id else { return nil }
        guard shortcut.modifiers == UInt32(cmdKey) else { return nil }
        let highRiskKeys: Set<Int> = [
            kVK_ANSI_D,
            kVK_ANSI_H,
            kVK_ANSI_M,
            kVK_ANSI_Q,
            kVK_ANSI_W,
            kVK_LeftArrow,
            kVK_RightArrow
        ]
        guard highRiskKeys.contains(Int(shortcut.keyCode)) else { return nil }
        return "会覆盖普通 App 的 \(shortcut.formattedDisplay)"
    }

    private func setFeedback(_ text: String, tone: FeedbackTone) {
        feedbackText = text
        feedbackTone = tone
    }
}

@MainActor
private final class ShortcutRecorderController: ObservableObject {
    static let shared = ShortcutRecorderController()

    @Published private(set) var recordingTargetID: String?
    private var localMonitor: Any?

    func start(targetID: String, onEvent: @escaping (NSEvent) -> Void) {
        stop()
        recordingTargetID = targetID
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recordingTargetID == targetID else { return event }
            onEvent(event)
            return nil
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        recordingTargetID = nil
    }

    func stop(ifTarget targetID: String) {
        guard recordingTargetID == targetID else { return }
        stop()
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
