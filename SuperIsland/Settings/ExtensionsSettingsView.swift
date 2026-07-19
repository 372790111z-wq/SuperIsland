import SwiftUI
import AppKit

private let linearMentionsExtensionID = "superisland.linear-mentions"
private let lastFmScrobblerExtensionID = "superisland.lastfm-scrobbler"

private enum ExtensionListFilter: String, CaseIterable, Identifiable {
    case all
    case active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .active: return "活动"
        }
    }
}

struct ExtensionsSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var logger = ExtensionLogger.shared
    @State private var selectedExtensionID: String?
    @State private var listFilter: ExtensionListFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterBar

            HStack(spacing: 10) {
                leftPane
                    .frame(width: 300)

                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dataAnnotationID("app-localization-extension-ui")
        .onAppear {
            manager.discoverExtensions()
            preserveSelection()
        }
        .onChange(of: manager.installed.map(\.id)) { _, _ in
            preserveSelection()
        }
        .onChange(of: activeExtensionIDs) { _, _ in
            preserveSelection()
        }
        .onChange(of: listFilter) { _, _ in
            preserveSelection()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Text("筛选")
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: $listFilter) {
                ForEach(ExtensionListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer(minLength: 0)

            Text("显示 \(filteredManifests.count) 个")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                manager.discoverExtensions()
                preserveSelection()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("扩展")
                .font(.headline.weight(.semibold))

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredManifests, id: \.id) { manifest in
                        let isSelected = selectedExtensionID == manifest.id
                        Button {
                            selectedExtensionID = manifest.id
                        } label: {
                            extensionListRow(for: manifest, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .panelBackground()
    }

    @ViewBuilder
    private var rightPane: some View {
        if let manifest = selectedManifest {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    extensionHeaderCard(for: manifest)

                    if manifest.id == "superisland.whatsapp-web" {
                        SettingsCard(title: "WhatsApp Web 登录") {
                            WhatsAppWebBridgeSettingsView()
                        }
                    }

                    if manifest.id == linearMentionsExtensionID {
                        SettingsCard(title: "Linear 登录") {
                            LinearOAuthSettingsView()
                        }
                    }

                    if manifest.id == lastFmScrobblerExtensionID {
                        SettingsCard(title: "Last.fm 登录") {
                            LastFmOAuthSettingsView()
                        }
                    }

                    SettingsCard(title: "详情") {
                        if let author = manifest.author?.name {
                            metadataRow(label: "作者", value: author)
                        }
                        if manifest.id != linearMentionsExtensionID {
                            metadataRow(label: "刷新", value: "\(String(format: "%.1f", manifest.refreshInterval))s")
                        }
                        metadataRow(label: "触发", value: manifest.activationTriggers.joined(separator: ", "))

                        if !manifest.permissions.isEmpty {
                            metadataRow(label: "权限", value: manifest.permissions.joined(separator: ", "))
                        }
                    }

                    if let schema = manager.settingsSchemas[manifest.id] {
                        SettingsCard(title: "设置") {
                            ExtensionSettingsRenderer(extensionID: manifest.id, schema: schema)
                        }
                    }

                    let logEntries = logger.entries(for: manifest.id)
                    if !logEntries.isEmpty {
                        SettingsCard(title: "最近日志") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(logEntries.suffix(8)) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(width: 72, alignment: .leading)

                                        Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(entry.level == .error ? .red : .secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("选择一个扩展")
                    .font(.headline)
                Text("从左侧面板选择扩展。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelBackground()
        }
    }

    private func extensionHeaderCard(for manifest: ExtensionManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 10) {
                    extensionIcon(for: manifest, size: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(manifest.name)
                            .font(.title3.weight(.semibold))
                        Text("\(manifest.id) • v\(manifest.version)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(manager.runtimes[manifest.id] == nil ? "未活动" : "活动中")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(manager.runtimes[manifest.id] == nil ? Color.secondary.opacity(0.15) : Color.green.opacity(0.15))
                    )
                    .foregroundColor(manager.runtimes[manifest.id] == nil ? .secondary : .green)
            }

            Text(manifest.description)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(manager.runtimes[manifest.id] == nil ? "启用" : "重新加载") {
                    if manager.runtimes[manifest.id] == nil {
                        manager.activate(extensionID: manifest.id)
                    } else {
                        manager.reload(extensionID: manifest.id)
                    }
                }
                .buttonStyle(.borderedProminent)

                if manager.runtimes[manifest.id] != nil {
                    Button("停用") {
                        manager.disableByUser(extensionID: manifest.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .panelBackground()
    }

    private func extensionListRow(for manifest: ExtensionManifest, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            extensionIcon(for: manifest, size: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(manifest.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    sourceBadge(for: manifest)
                }

                Text(manifest.id)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            }

            Spacer(minLength: 6)

            Circle()
                .fill(manager.runtimes[manifest.id] == nil ? Color.secondary.opacity(isSelected ? 0.75 : 0.45) : Color.green)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                    ? selectedRowFillColor
                    : Color(nsColor: .controlBackgroundColor).opacity(0.20)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? selectedRowStrokeColor : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: isSelected ? selectedRowShadowColor : .clear, radius: 6, x: 0, y: 2)
        .foregroundColor(isSelected ? .white : .primary)
    }

    @ViewBuilder
    private func sourceBadge(for manifest: ExtensionManifest) -> some View {
        let source = extensionSource(for: manifest)
        Text(source.label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(source.color.opacity(0.15))
            )
            .foregroundColor(source.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func extensionIcon(for manifest: ExtensionManifest, size: CGFloat) -> some View {
        if let image = extensionIconImage(for: manifest) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(5, size * 0.22), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: max(5, size * 0.22), style: .continuous)
                        .stroke(Color.secondary.opacity(0.24), lineWidth: 0.6)
                )
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: max(5, size * 0.22), style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )
        }
    }

    private func extensionIconImage(for manifest: ExtensionManifest) -> NSImage? {
        guard let iconURL = manifest.iconURL else { return nil }

        if let image = NSImage(contentsOf: iconURL) {
            return image
        }

        if let data = try? Data(contentsOf: iconURL), let image = NSImage(data: data) {
            return image
        }

        return nil
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var selectedManifest: ExtensionManifest? {
        guard let selectedExtensionID else { return nil }
        return filteredManifests.first(where: { $0.id == selectedExtensionID })
            ?? manager.installed.first(where: { $0.id == selectedExtensionID })
    }

    private var filteredManifests: [ExtensionManifest] {
        switch listFilter {
        case .all:
            return manager.installed
        case .active:
            return manager.installed.filter { manager.runtimes[$0.id] != nil }
        }
    }

    private var activeExtensionIDs: [String] {
        manager.runtimes.keys.sorted()
    }

    private func extensionSource(for manifest: ExtensionManifest) -> (label: String, color: Color) {
        if isInstalledExtension(manifest) {
            return ("Installed", Color.accentColor)
        }
        return ("Bundled", .secondary)
    }

    private func isInstalledExtension(_ manifest: ExtensionManifest) -> Bool {
        let installedPath = manager.installedExtensionsDirectory.standardizedFileURL.path
        let bundlePath = manifest.bundleURL.standardizedFileURL.path
        return bundlePath == installedPath || bundlePath.hasPrefix(installedPath + "/")
    }

    private func preserveSelection() {
        guard !filteredManifests.isEmpty else {
            selectedExtensionID = nil
            return
        }

        if let selectedExtensionID,
           filteredManifests.contains(where: { $0.id == selectedExtensionID }) {
            return
        }

        selectedExtensionID = filteredManifests.first?.id
    }

    private var selectedRowFillColor: Color {
        colorScheme == .light
            ? Color(nsColor: .selectedContentBackgroundColor)
            : .accentColor
    }

    private var selectedRowStrokeColor: Color {
        colorScheme == .light
            ? Color(nsColor: .selectedControlColor).opacity(0.42)
            : Color.white.opacity(0.15)
    }

    private var selectedRowShadowColor: Color {
        colorScheme == .light
            ? Color(nsColor: .selectedControlColor).opacity(0.20)
            : Color.accentColor.opacity(0.25)
    }
}

private struct LinearOAuthSettingsView: View {
    private static let authorizeURLString = "https://api.supercmd.sh/auth/linear/authorize?app=superisland"
    private static let oauthStoreKey = "extensions.\(linearMentionsExtensionID).store.oauth"

    @ObservedObject private var manager = ExtensionManager.shared
    @State private var session: LinearOAuthSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            Text(statusMessage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button(primaryButtonTitle) {
                    openAuthorizeURL()
                }
                .buttonStyle(.borderedProminent)

                if session != nil {
                    Button("断开连接") {
                        disconnect()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            if let session {
                VStack(alignment: .leading, spacing: 4) {
                    if !session.scope.isEmpty {
                        Text("范围：\(session.scope)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if let expiresAt = session.expiresAt {
                        Text(expirationLabel(expiresAt: expiresAt, isExpired: session.isExpired))
                            .font(.system(size: 11))
                            .foregroundColor(session.isExpired ? .red : .secondary)
                    }
                }
            }
        }
        .onAppear {
            reloadSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadSession()
        }
    }

    private var statusTitle: String {
        if let session {
            return session.isExpired ? "已过期" : "已登录"
        }
        return "未登录"
    }

    private var statusColor: Color {
        if let session {
            return session.isExpired ? .orange : .green
        }
        return .secondary
    }

    private var statusMessage: String {
        if let session {
            if session.isExpired {
                return "Linear 会话已过期。请重新授权以恢复提及同步。"
            }
            return "Linear 已授权。新的提及会显示在 SuperIsland 中。"
        }
        return "授权 Linear 后可开始接收提及通知并进行行内回复。"
    }

    private var primaryButtonTitle: String {
        if let session {
            return session.isExpired ? "重新登录" : "重新连接"
        }
        return "登录 Linear"
    }

    private func reloadSession() {
        session = LinearOAuthSession.load()
    }

    private func openAuthorizeURL() {
        guard let url = URL(string: Self.authorizeURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.oauthStoreKey)
        UserDefaults.standard.synchronize()

        if manager.runtimes[linearMentionsExtensionID] == nil {
            manager.activate(extensionID: linearMentionsExtensionID)
        }
        manager.scheduleImmediateRefresh(extensionID: linearMentionsExtensionID)
        reloadSession()
    }

    private func expirationLabel(expiresAt: Date, isExpired: Bool) -> String {
        let formatted = expiresAt.formatted(date: .abbreviated, time: .shortened)
        return isExpired ? "已于 \(formatted) 过期" : "将于 \(formatted) 过期"
    }
}

private struct LinearOAuthSession {
    private static let oauthStoreKey = "extensions.\(linearMentionsExtensionID).store.oauth"

    let accessToken: String
    let tokenType: String
    let scope: String
    let receivedAt: Date?
    let expiresAt: Date?
    let isExpired: Bool

    static func load(defaults: UserDefaults = .standard) -> LinearOAuthSession? {
        guard let dictionary = defaults.dictionary(forKey: oauthStoreKey) else {
            return nil
        }

        let accessToken = normalizedText(dictionary["accessToken"] ?? dictionary["access_token"])
        guard !accessToken.isEmpty else {
            return nil
        }

        let tokenType = normalizedText(dictionary["tokenType"] ?? dictionary["token_type"])
        let scope = normalizedText(dictionary["scope"])
        let receivedAtSeconds = numericValue(dictionary["receivedAt"])
        let expiresInSeconds = numericValue(dictionary["expiresIn"] ?? dictionary["expires_in"])

        let receivedAt = receivedAtSeconds.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
        let expiresAt: Date? = {
            guard let receivedAt, let expiresInSeconds, expiresInSeconds > 0 else { return nil }
            return receivedAt.addingTimeInterval(TimeInterval(expiresInSeconds))
        }()
        let isExpired = expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false

        return LinearOAuthSession(
            accessToken: accessToken,
            tokenType: tokenType.isEmpty ? "Bearer" : tokenType,
            scope: scope,
            receivedAt: receivedAt,
            expiresAt: expiresAt,
            isExpired: isExpired
        )
    }

    private static func normalizedText(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    private static func numericValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let number = Int(string) {
            return number
        }
        return nil
    }
}

private struct LastFmOAuthSettingsView: View {
    private static let authorizeURLString = "https://api.supercmd.sh/auth/lastfm/authorize?app=superisland"
    private static let oauthStoreKey = "extensions.\(lastFmScrobblerExtensionID).store.oauth"

    @ObservedObject private var manager = ExtensionManager.shared
    @State private var session: LastFmOAuthSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            Text(statusMessage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button(primaryButtonTitle) {
                    openAuthorizeURL()
                }
                .buttonStyle(.borderedProminent)

                if session != nil {
                    Button("断开连接") {
                        disconnect()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            if let session {
                VStack(alignment: .leading, spacing: 4) {
                    if !session.username.isEmpty {
                        Text("账户：\(session.username)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if !session.scope.isEmpty {
                        Text("范围：\(session.scope)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if let expiresAt = session.expiresAt {
                        Text(expirationLabel(expiresAt: expiresAt, isExpired: session.isExpired))
                            .font(.system(size: 11))
                            .foregroundColor(session.isExpired ? .red : .secondary)
                    }
                }
            }
        }
        .onAppear {
            reloadSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadSession()
        }
    }

    private var statusTitle: String {
        if let session {
            return session.isExpired ? "已过期" : "已登录"
        }
        return "未登录"
    }

    private var statusColor: Color {
        if let session {
            return session.isExpired ? .orange : .green
        }
        return .secondary
    }

    private var statusMessage: String {
        if let session {
            if session.isExpired {
                return "Last.fm 会话已过期。请重新授权以恢复记录。"
            }
            if !session.username.isEmpty {
                return "Last.fm 已以 \(session.username) 连接。新的播放会自动记录。"
            }
            return "Last.fm 已连接。新的播放会自动记录。"
        }
        return "授权 Last.fm 后可开始记录你的收听历史。"
    }

    private var primaryButtonTitle: String {
        if let session {
            return session.isExpired ? "重新登录" : "重新连接"
        }
        return "登录 Last.fm"
    }

    private func reloadSession() {
        session = LastFmOAuthSession.load()
    }

    private func openAuthorizeURL() {
        guard let url = URL(string: Self.authorizeURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.oauthStoreKey)
        UserDefaults.standard.synchronize()

        if manager.runtimes[lastFmScrobblerExtensionID] == nil {
            manager.activate(extensionID: lastFmScrobblerExtensionID)
        }
        manager.scheduleImmediateRefresh(extensionID: lastFmScrobblerExtensionID)
        reloadSession()
    }

    private func expirationLabel(expiresAt: Date, isExpired: Bool) -> String {
        let formatted = expiresAt.formatted(date: .abbreviated, time: .shortened)
        return isExpired ? "已于 \(formatted) 过期" : "将于 \(formatted) 过期"
    }
}

private struct LastFmOAuthSession {
    private static let oauthStoreKey = "extensions.\(lastFmScrobblerExtensionID).store.oauth"

    let accessToken: String
    let tokenType: String
    let scope: String
    let username: String
    let receivedAt: Date?
    let expiresAt: Date?
    let isExpired: Bool

    static func load(defaults: UserDefaults = .standard) -> LastFmOAuthSession? {
        guard let dictionary = defaults.dictionary(forKey: oauthStoreKey) else {
            return nil
        }

        let accessToken = normalizedText(dictionary["accessToken"] ?? dictionary["access_token"])
        guard !accessToken.isEmpty else {
            return nil
        }

        let tokenType = normalizedText(dictionary["tokenType"] ?? dictionary["token_type"])
        let scope = normalizedText(dictionary["scope"])
        let username = normalizedText(dictionary["username"] ?? dictionary["name"])
        let receivedAtSeconds = numericValue(dictionary["receivedAt"])
        let expiresInSeconds = numericValue(dictionary["expiresIn"] ?? dictionary["expires_in"])

        let receivedAt = receivedAtSeconds.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
        let expiresAt: Date? = {
            guard let receivedAt, let expiresInSeconds, expiresInSeconds > 0 else { return nil }
            return receivedAt.addingTimeInterval(TimeInterval(expiresInSeconds))
        }()
        let isExpired = expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false

        return LastFmOAuthSession(
            accessToken: accessToken,
            tokenType: tokenType.isEmpty ? "Bearer" : tokenType,
            scope: scope,
            username: username,
            receivedAt: receivedAt,
            expiresAt: expiresAt,
            isExpired: isExpired
        )
    }

    private static func normalizedText(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    private static func numericValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let number = Int(string) {
            return number
        }
        return nil
    }
}

private struct WhatsAppWebBridgeSettingsView: View {
    @ObservedObject private var bridge = WhatsAppWebBridge.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 9, height: 9)
                Text(stateTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            Text(bridge.statusText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                if bridge.connectionState == .loggedIn {
                    Button("退出登录") {
                        bridge.logout()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button("开始登录") {
                        bridge.start()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("刷新二维码") {
                        bridge.refreshQRCode()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if bridge.connectionState == .loggedIn {
                Text("已连接。新消息会从此次登录同步。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if let image = qrImage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("用手机 WhatsApp 扫描此二维码")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white)
                        )
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备安全登录会话...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if let error = bridge.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .onAppear {
            bridge.start()
        }
    }

    private var stateTitle: String {
        switch bridge.connectionState {
        case .idle:
            return "空闲"
        case .loading:
            return "加载中"
        case .qrReady:
            return "二维码已就绪"
        case .loggedIn:
            return "已连接"
        case .error:
            return "错误"
        }
    }

    private var stateColor: Color {
        switch bridge.connectionState {
        case .idle:
            return .secondary
        case .loading:
            return .orange
        case .qrReady:
            return .blue
        case .loggedIn:
            return .green
        case .error:
            return .red
        }
    }

    private var qrImage: NSImage? {
        guard let dataURL = bridge.qrCodeDataURL else { return nil }
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let encoded = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }
}

private extension View {
    func panelBackground() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
    }
}
