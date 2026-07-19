import AppKit
import AVFoundation
import EventKit
import Speech
import SwiftUI
import UserNotifications

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var nowPlayingManager = NowPlayingManager.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var teleprompter = TeleprompterManager.shared
    @State private var teleprompterPermissionRefresh = 0
    @State private var didAutoRequestTeleprompterPermissions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "媒体与 HUD")
            SettingGroup {
                SettingToggleRow(title: "正在播放", isOn: $appState.nowPlayingEnabled)
                if appState.nowPlayingEnabled {
                    SettingRowDivider()
                    SettingToggleRow(
                        title: "浏览器媒体检测",
                        description: "使用 macOS 自动化检测已允许浏览器中的媒体。",
                        isOn: $nowPlayingManager.browserDetectionEnabled
                    )
                    if nowPlayingManager.browserDetectionEnabled {
                        browserMediaRows
                    }
                }
                SettingRowDivider()
                SettingToggleRow(title: "音量 HUD", isOn: $appState.volumeHUDEnabled)
            }

            SettingSectionLabel(title: "首页")
            SettingGroup {
                homeSlotRow(title: "左侧槽位", selection: $appState.homeLeadingPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "中间槽位", selection: $appState.homeCenterPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "右侧槽位", selection: $appState.homeTrailingPanelRaw)
            }

            SettingSectionLabel(title: "系统")
            SettingGroup {
                SettingToggleRow(title: "电池", isOn: $appState.batteryEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "暂存架", isOn: $appState.shelfEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "拖放时自动打开暂存架", isOn: $appState.shelfAutoOpenOnDrop)
                SettingRowDivider()
                shelfRetentionRow
                SettingRowDivider()
                SettingToggleRow(title: "连接", isOn: $appState.connectivityEnabled)
            }

            SettingSectionLabel(title: "信息")
            SettingGroup {
                SettingToggleRow(title: "日历", isOn: calendarEnabledBinding)
                if appState.calendarEnabled {
                    SettingRowDivider()
                    calendarPermissionRow
                    if calendarManager.hasAccess {
                        SettingRowDivider()
                        SettingToggleRow(
                            title: "折叠重复日程",
                            description: "隐藏标题和时间相同的重复节假日或生日。",
                            isOn: $calendarManager.collapseDuplicates
                        )
                        SettingRowDivider()
                        SettingToggleRow(
                            title: "隐藏节假日",
                            isOn: $calendarManager.hideHolidays
                        )
                        SettingRowDivider()
                        SettingToggleRow(
                            title: "隐藏生日",
                            isOn: $calendarManager.hideBirthdays
                        )
                        SettingRowDivider()
                        calendarLookaheadRow
                        calendarSourceRows
                    }
                }
                SettingRowDivider()
                SettingToggleRow(title: "天气", isOn: $appState.weatherEnabled)
                SettingRowDivider()
                HStack {
                    Text("温度单位")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Picker("", selection: $appState.temperatureUnit) {
                        Text("°C").tag(TemperatureUnit.celsius)
                        Text("°F").tag(TemperatureUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                SettingRowDivider()
                SettingToggleRow(title: "通知", isOn: notificationsEnabledBinding)
                if appState.notificationsEnabled {
                    SettingRowDivider()
                    notificationPermissionRow
                    SettingRowDivider()
                    SettingToggleRow(
                        title: "显示预览",
                        description: "可用时显示发送者和消息正文。",
                        isOn: notificationPreviewsBinding
                    )
                    SettingRowDivider()
                    notificationRetentionRow
                    ForEach(NotificationFeedSource.allCases) { source in
                        SettingRowDivider()
                        SettingToggleRow(
                            title: source.title,
                            description: source.description,
                            isOn: notificationSourceBinding(for: source)
                        )
                    }
                }
            }

            SettingSectionLabel(title: "效率")
            SettingGroup {
                SettingToggleRow(title: "提词器", isOn: teleprompterEnabledBinding)
                    .dataAnnotationID("teleprompter-module-toggle")
                if appState.teleprompterEnabled {
                    SettingRowDivider()
                    teleprompterPermissionRow
                    SettingRowDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("模式")
                                .font(.system(size: 13))
                            Text(teleprompter.listeningMode.description)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 12)
                        Picker("", selection: $teleprompter.listeningMode) {
                            ForEach(TeleprompterListeningMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                        .dataAnnotationID("teleprompter-listening-mode-control")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    SettingRowDivider()
                    HStack {
                        Text("稿件")
                            .font(.system(size: 13))
                        Spacer(minLength: 8)
                        Button("编辑稿件…") {
                            TeleprompterScriptEditorWindowController.show()
                        }
                        .font(.system(size: 12))
                        .dataAnnotationID("teleprompter-edit-script-button")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dataAnnotationID("app-localization-settings-ui")
        .onAppear {
            notificationManager.checkPermission()
            calendarManager.refreshAccessStatus()
            refreshTeleprompterPermissionState()
            autoRequestTeleprompterPermissionsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationManager.checkPermission()
            calendarManager.refreshAccessStatus()
            refreshTeleprompterPermissionState()
        }
        .onChange(of: teleprompter.listeningMode) { _, mode in
            refreshTeleprompterPermissionState()
            if mode == .wordTracking {
                autoRequestTeleprompterPermissionsIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                refreshTeleprompterPermissionState()
            }
        }
        .onChange(of: appState.teleprompterEnabled) { _, enabled in
            if enabled {
                autoRequestTeleprompterPermissionsIfNeeded()
            }
        }
    }

    private var teleprompterPermissionRow: some View {
        let _ = teleprompterPermissionRefresh
        let ready = PermissionsManager.shared.checkMicrophone()
            && PermissionsManager.shared.checkSpeechRecognition()

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("语音跟读权限")
                    .font(.system(size: 13))
                Text(teleprompterPermissionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if ready {
                Label("已就绪", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            } else {
                Button(teleprompterPermissionButtonTitle) {
                    requestTeleprompterPermissions()
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .dataAnnotationID("teleprompter-speech-status")
    }

    private var teleprompterPermissionDescription: String {
        let microphoneStatus = PermissionsManager.shared.microphoneAuthorizationStatus()
        let speechStatus = PermissionsManager.shared.speechRecognitionAuthorizationStatus()
        let microphone = microphoneStatus == .authorized
        let speech = speechStatus == .authorized

        if microphoneStatus == .denied || microphoneStatus == .restricted ||
            speechStatus == .denied || speechStatus == .restricted {
            return "访问被拒绝或受限。请打开系统设置以启用语音跟读。"
        }

        switch (microphone, speech) {
        case (true, true):
            return "麦克风和语音识别已可用于语音跟读。"
        case (false, true):
            return "启用语音跟读时会请求麦克风权限。"
        case (true, false):
            return "启用语音跟读时会请求语音识别权限。"
        case (false, false):
            return "启用提词器时会请求麦克风和语音识别权限。"
        }
    }

    private var teleprompterPermissionButtonTitle: String {
        let microphone = PermissionsManager.shared.microphoneAuthorizationStatus()
        let speech = PermissionsManager.shared.speechRecognitionAuthorizationStatus()
        if microphone == .denied || microphone == .restricted ||
            speech == .denied || speech == .restricted {
            return "打开设置"
        }
        return "授权"
    }

    private var calendarPermissionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("日历访问")
                    .font(.system(size: 13))
                Text(calendarPermissionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(calendarPermissionButtonTitle) {
                handleCalendarPermissionAction()
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var notificationPermissionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("权限")
                    .font(.system(size: 13))
                Text(notificationPermissionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(notificationPermissionButtonTitle) {
                handleNotificationPermissionAction()
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var teleprompterEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.teleprompterEnabled },
            set: { enabled in
                appState.teleprompterEnabled = enabled
                if enabled {
                    requestTeleprompterPermissions()
                } else {
                    teleprompter.pause()
                }
            }
        )
    }

    private func requestTeleprompterPermissions() {
        didAutoRequestTeleprompterPermissions = true
        PermissionsManager.shared.requestTeleprompterWordTrackingAccess { _ in
            refreshTeleprompterPermissionState()
        }
        refreshTeleprompterPermissionState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            refreshTeleprompterPermissionState()
        }
    }

    private func autoRequestTeleprompterPermissionsIfNeeded() {
        guard appState.teleprompterEnabled else { return }
        guard !didAutoRequestTeleprompterPermissions else { return }

        let permissions = PermissionsManager.shared
        let microphone = permissions.microphoneAuthorizationStatus()
        let speech = permissions.speechRecognitionAuthorizationStatus()
        guard microphone == .notDetermined || speech == .notDetermined else {
            refreshTeleprompterPermissionState()
            return
        }

        requestTeleprompterPermissions()
    }

    private func refreshTeleprompterPermissionState() {
        teleprompterPermissionRefresh += 1
    }

    private var calendarLookaheadRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("未来范围")
                    .font(.system(size: 13))
                Text("未来列表中显示多少天。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: calendarLookaheadBinding,
                step: 1,
                range: 1...30
            ) { "\(Int($0))d" }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var notificationRetentionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("保留项目")
                    .font(.system(size: 13))
                Text("动态岛中保留多少条信息流项目。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: notificationMaxRetainedBinding,
                step: 1,
                range: 1...50
            ) { "\(Int($0))" }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var calendarSourceRows: some View {
        if calendarManager.calendarSourceGroups.isEmpty {
            SettingRowDivider()
            Text("没有可用日历")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        } else {
            ForEach(calendarManager.calendarSourceGroups) { group in
                SettingRowDivider()
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(group.calendars) { calendar in
                    calendarSourceRow(calendar)
                    if calendar.id != group.calendars.last?.id {
                        SettingRowDivider()
                    }
                }
            }
        }
    }

    private func calendarSourceRow(_ calendar: CalendarDisplayOption) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(cgColor: calendar.color))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.title)
                    .font(.system(size: 13))
                Text(calendarTypeLabel(calendar.type))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: calendarEnabledBinding(for: calendar.id))
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var calendarEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.calendarEnabled },
            set: { newValue in
                appState.calendarEnabled = newValue
                if newValue {
                    calendarManager.refreshAccessStatus()
                    if calendarManager.authorizationStatus == .notDetermined {
                        calendarManager.requestAccess()
                    }
                }
            }
        )
    }

    private var calendarLookaheadBinding: Binding<Double> {
        Binding(
            get: { Double(calendarManager.lookaheadDays) },
            set: { calendarManager.lookaheadDays = Int($0) }
        )
    }

    private func calendarEnabledBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { calendarManager.isCalendarEnabled(calendarID) },
            set: { calendarManager.setCalendar(calendarID, enabled: $0) }
        )
    }

    private var notificationPreviewsBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationPreviewsEnabled },
            set: { newValue in
                appState.notificationPreviewsEnabled = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationMaxRetainedBinding: Binding<Double> {
        Binding(
            get: { appState.notificationMaxRetainedItems },
            set: { newValue in
                appState.notificationMaxRetainedItems = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationsEnabled },
            set: { newValue in
                appState.notificationsEnabled = newValue
                guard newValue else {
                    NotificationManager.shared.clearAll()
                    return
                }

                NotificationManager.shared.checkPermission()
                if NotificationManager.shared.authorizationStatus == .notDetermined {
                    NotificationManager.shared.requestPermission()
                }
            }
        )
    }

    private func notificationSourceBinding(for source: NotificationFeedSource) -> Binding<Bool> {
        Binding(
            get: { appState.isNotificationSourceEnabled(source) },
            set: { newValue in
                appState.setNotificationSource(source, enabled: newValue)
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var calendarPermissionDescription: String {
        switch calendarManager.authorizationStatus {
        case .fullAccess, .authorized:
            return "已允许。选择哪些日历显示在 SuperIsland 中。"
        case .notDetermined:
            return "尚未请求。允许访问后可显示即将到来的日程。"
        case .denied:
            return "已拒绝。请打开系统设置允许日历访问。"
        case .restricted:
            return "受 macOS 设置限制。"
        case .writeOnly:
            return "仅写入权限不足以显示日程。"
        @unknown default:
            return "未知。请检查 macOS 日历隐私设置。"
        }
    }

    private var notificationPermissionDescription: String {
        switch notificationManager.authorizationStatus {
        case .authorized:
            return "已允许。SuperIsland 可以发送自身通知和扩展提醒。"
        case .denied:
            return "已拒绝。请打开系统设置允许 SuperIsland 通知。"
        case .notDetermined:
            return "尚未请求。当你需要 SuperIsland 或扩展发送 macOS 通知时请允许。"
        case .provisional, .ephemeral:
            return "已允许，但通知投递受限。"
        @unknown default:
            return "未知。请检查 macOS 通知设置。"
        }
    }

    private var calendarPermissionButtonTitle: String {
        switch calendarManager.authorizationStatus {
        case .notDetermined:
            return "请求"
        default:
            return "打开设置"
        }
    }

    private var notificationPermissionButtonTitle: String {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            return "请求"
        default:
            return "打开设置"
        }
    }

    private func handleCalendarPermissionAction() {
        switch calendarManager.authorizationStatus {
        case .notDetermined:
            calendarManager.requestAccess()
        default:
            calendarManager.openCalendarSettings()
        }
    }

    private func handleNotificationPermissionAction() {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            notificationManager.requestPermission()
        default:
            notificationManager.openNotificationSettings()
        }
    }

    private func calendarTypeLabel(_ type: EKCalendarType) -> String {
        switch type {
        case .local:
            return "本地"
        case .calDAV:
            return "CalDAV"
        case .exchange:
            return "Exchange"
        case .subscription:
            return "订阅"
        case .birthday:
            return "生日"
        @unknown default:
            return "日历"
        }
    }

    private var shelfRetentionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("暂存架保留")
                    .font(.system(size: 13))
                Text("已固定项目会保留")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: $shelf.retentionDays) {
                ForEach(ShelfRetentionOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func homeSlotRow(title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(HomePanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.iconName)
                        .tag(panel.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var browserMediaRows: some View {
        ForEach(nowPlayingManager.browserTargets) { browser in
            SettingRowDivider()
            browserToggleRow(browser)
        }
        SettingRowDivider()
        browserDetectionTestRow
    }

    private func browserToggleRow(_ browser: NowPlayingBrowserTarget) -> some View {
        SettingToggleRow(
            title: browser.displayName,
            description: "允许 SuperIsland 在此浏览器中查找媒体。",
            isOn: browserBinding(for: browser.id)
        )
    }

    private var browserDetectionTestRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("检测测试")
                    .font(.system(size: 13))
                Text(browserDetectionMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button("测试") {
                    nowPlayingManager.testBrowserDetection()
                }
                .font(.system(size: 12))
                Button("打开设置") {
                    nowPlayingManager.openAutomationSettings()
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func browserBinding(for browserID: String) -> Binding<Bool> {
        Binding(
            get: { nowPlayingManager.isBrowserAllowed(browserID) },
            set: { nowPlayingManager.setBrowser(browserID, allowed: $0) }
        )
    }

    private var browserDetectionMessage: String {
        if !nowPlayingManager.browserDetectionTestMessage.isEmpty {
            return nowPlayingManager.browserDetectionTestMessage
        }
        return "需要自动化权限，并允许浏览器通过 Apple Events 执行 JavaScript。"
    }
}
