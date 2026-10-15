import AppKit
import ApplicationServices
import Combine
import CoreGraphics

struct NotificationApplicationIdentity: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
}

struct MacNotificationBanner: Equatable, Sendable {
    let application: NotificationApplicationIdentity
    let title: String
    let body: String
}

enum MacNotificationBannerGeometry {
    static func isCard(_ frame: CGRect) -> Bool {
        (180...650).contains(frame.width) && (35...350).contains(frame.height)
    }

    static func isHistoryViewport(role: String?, frame: CGRect, title: String = "") -> Bool {
        let historyTitles: Set<String> = ["通知中心", "Notification Center", "Notifications", "通知"]
        return role == kAXScrollAreaRole && frame.height > 350 &&
            (frame.width <= 650 || historyTitles.contains(title))
    }

    static func isTopRightCard(_ frame: CGRect, display: CGRect) -> Bool {
        isCard(frame) && frame.minX >= display.maxX - 700 && frame.maxX <= display.maxX + 3 &&
            frame.minY >= display.minY - 3 && frame.maxY <= display.minY + 350
    }
}

enum MacNotificationBannerParser {
    // Only an exact source icon label is provenance. Container summaries and
    // message titles can begin with an app name and must remain message text.
    static func applicationSource(_ label: String, applications: [NotificationApplicationIdentity]) -> NotificationApplicationIdentity? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = applications.filter { $0.name.caseInsensitiveCompare(label) == .orderedSame }
        guard Set(matches.map(\.bundleIdentifier)).count == 1 else { return nil }
        return matches.first
    }

    static func parse(_ texts: [String], sourceLabel: String? = nil, applications: [NotificationApplicationIdentity], allowUnknownSource: Bool = false) -> MacNotificationBanner? {
        var seen = Set<String>()
        let chrome: Set<String> = ["通知中心", "Notification Center", "NotificationCenter", "通知", "Notifications"]
        let values = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !chrome.contains($0) && seen.insert($0).inserted }
        let knownSource = sourceLabel.flatMap { applicationSource($0, applications: applications) }
        // This fallback is enabled only for a visible, bounded system card.
        // An empty bundle identifier must never become an application action.
        guard knownSource != nil || allowUnknownSource else { return nil }
        let application = knownSource ?? NotificationApplicationIdentity(name: "Mac 通知", bundleIdentifier: "")
        // Source metadata never consumes a title. In particular, a title that
        // equals an app name must not promote the private body into the title.
        let fields = values.filter { !isChromeText($0) }
        guard !fields.isEmpty, !fields.contains(where: isOldTimestamp) else { return nil }
        let redacted: Set<String> = ["内容已隐藏", "内容已由系统隐藏", "消息内容已隐藏", "预览已隐藏", "Content hidden", "Preview hidden", "Notification content hidden"]
        if fields.contains(where: { redacted.contains($0) }) {
            return MacNotificationBanner(application: application, title: "新通知", body: "")
        }
        guard fields.count <= 2 else { return nil }
        return MacNotificationBanner(application: application, title: fields.first ?? "新通知", body: fields.dropFirst().joined(separator: " "))
    }

    static func isOldTimestamp(_ text: String) -> Bool {
        text.range(of: #"^(\d+\s*(分钟|小时|天)(前|以前)?|\d+\s*(min|mins|minutes|hour|hours|day|days)\s+ago|昨天|昨日|Yesterday)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isChromeText(_ text: String) -> Bool {
        let ignored: Set<String> = ["现在", "刚刚", "通知", "关闭", "选项", "回复", "显示更多", "Now", "now", "Close", "Options", "Reply", "Show more"]
        return ignored.contains(text) || text.range(of: #"^\d+\s*(秒前|seconds? ago)$"#, options: .regularExpression) != nil
    }
}

/// Keep processed card identities across temporary AX gaps and occlusion.
/// Distinct system cards remain distinct even when their message text matches.
/// Retention is bounded and ends when the source or session is reset.
struct MacNotificationVisibilityTracker {
    private var ids: [String: String] = [:]
    private var primed = false
    private var order: [String] = []

    mutating func update(keys: Set<String>, establishingBaseline: Bool = false) -> [String: String] {
        var arrivals: [String: String] = [:]
        for key in keys where ids[key] == nil {
            let id = "macOS:\(UUID().uuidString)"
            ids[key] = id
            order.append(key)
            if primed && !establishingBaseline { arrivals[key] = id }
        }
        // Never evict currently visible cards; avoid replaying a persistent
        // banner when a newer temporary banner uncovers it.
        while order.count > 512, let index = order.firstIndex(where: { !keys.contains($0) }) {
            ids.removeValue(forKey: order.remove(at: index))
        }
        primed = true
        return arrivals
    }

    mutating func reset() { ids.removeAll(); order.removeAll(); primed = false }
}

@MainActor
final class MacNotificationBridge: ObservableObject {
    static let shared = MacNotificationBridge()
    @Published private(set) var statusText = "未启用 Mac 通知同步"
    @Published private(set) var needsAccessibility = false
    private var enabled = false
    private var locked = false
    private var timer: Timer?
    private var busy = false
    private var generation: UInt64 = 0
    private var tracker = MacNotificationVisibilityTracker()
    private var applications: [NotificationApplicationIdentity] = []
    private let queue = DispatchQueue(label: "superisland.mac-notification-banners", qos: .utility)
    private var lockObservers: [NSObjectProtocol] = []
    private var receive: ((String, MacNotificationBanner) -> Void)?
    private var syncedBannerCount = 0
    private var baselineUntil: TimeInterval = 0

    private struct Snapshot: Sendable {
        let key: String
        let texts: [String]
        let sourceLabel: String?
    }

    private init() {
        let center = DistributedNotificationCenter.default()
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.locked = isLocked
                    self.generation &+= 1
                    self.tracker.reset()
                    self.baselineUntil = ProcessInfo.processInfo.systemUptime + 2
                    if !isLocked && self.enabled { self.statusText = "等待系统可见的新通知；静默通知不在覆盖范围内" }
                    if isLocked { AppState.shared.cancelPendingNotificationPresentation() }
                    self.poll()
                }
            })
        }
    }

    func apply(enabled: Bool, receive: @escaping (String, MacNotificationBanner) -> Void) {
        self.receive = receive
        guard self.enabled != enabled else { poll(); return }
        self.enabled = enabled
        syncedBannerCount = 0
        if enabled { statusText = "等待系统可见的新通知；静默通知不在覆盖范围内" }
        generation &+= 1
        tracker.reset()
        baselineUntil = ProcessInfo.processInfo.systemUptime + 2
        timer?.invalidate()
        timer = nil
        if enabled {
            applications = Self.applicationIdentities()
            timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
        poll()
    }

    func refreshStatus() { poll() }

    func reportOpeningFailure() {
        statusText = "无法打开来源 App，请在系统中手动打开"
    }

    private func poll() {
        needsAccessibility = false
        guard enabled else { statusText = "未启用 Mac 通知同步"; return }
        guard !locked, !Self.sessionIsLocked else {
            statusText = "屏幕已锁定，暂停同步"
            tracker.reset()
            baselineUntil = ProcessInfo.processInfo.systemUptime + 2
            return
        }
        guard AXIsProcessTrusted() else {
            needsAccessibility = true
            statusText = "需要辅助功能权限，暂未接通"
            tracker.reset()
            baselineUntil = ProcessInfo.processInfo.systemUptime + 2
            return
        }
        guard !busy else { return }
        busy = true
        let currentGeneration = generation
        // AX hosts rebuild incrementally after launch, unlock or permission
        // recovery. Baseline their first two seconds, including empty reads,
        // so a pre-existing persistent banner cannot become a new arrival.
        let establishingBaseline = ProcessInfo.processInfo.systemUptime < baselineUntil
        let identities = applications
        queue.async { [weak self] in
            let snapshots = Self.visibleBanners(applications: identities)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.enabled, self.generation == currentGeneration,
                      !self.locked, !Self.sessionIsLocked, AXIsProcessTrusted() else { return }
                guard let snapshots else {
                    self.statusText = "系统通知界面暂不可读取"
                    self.tracker.reset()
                    self.baselineUntil = ProcessInfo.processInfo.systemUptime + 2
                    return
                }
                let parsed = snapshots.compactMap { snapshot -> (Snapshot, MacNotificationBanner)? in
                    guard let banner = MacNotificationBannerParser.parse(snapshot.texts, sourceLabel: snapshot.sourceLabel, applications: self.applications, allowUnknownSource: true) else { return nil }
                    return (snapshot, banner)
                }
                let arrivals = self.tracker.update(keys: Set(parsed.map { $0.0.key }), establishingBaseline: establishingBaseline)
                SystemFeedbackDiagnostics.write("notificationParsing", fields: ["snapshots": snapshots.count, "parsed": parsed.count, "newArrivals": arrivals.count, "synced": self.syncedBannerCount])
                if parsed.count < snapshots.count { self.statusText = "检测到横幅，但暂无法可靠识别来源" }
                for (snapshot, banner) in parsed {
                    guard let id = arrivals[snapshot.key] else { continue }
                    self.receive?(id, banner)
                    self.syncedBannerCount += 1
                    self.statusText = banner.application.bundleIdentifier.isEmpty
                        ? "已同步 \(self.syncedBannerCount) 条系统横幅；来源未暴露时显示 Mac 通知"
                        : "已同步 \(self.syncedBannerCount) 条系统横幅；覆盖范围以来源实测为准"
                }
            }
        }
    }

    nonisolated private static var sessionIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func applicationIdentities() -> [NotificationApplicationIdentity] {
        var urls = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        for path in ["/Applications", "/System/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            if let children = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil) {
                urls += children.filter { $0.pathExtension == "app" }
            }
        }
        var identities: [NotificationApplicationIdentity] = []
        for url in Set(urls) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  !id.lowercased().contains("notificationcenter"), id != "com.apple.controlcenter" else { continue }
            let names = [
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            ].compactMap { $0 }
            for name in Set(names) where !name.isEmpty {
                identities.append(.init(name: name, bundleIdentifier: id))
            }
        }
        // Ambiguous source labels must not open or label the wrong application.
        return identities.filter { candidate in
            Set(identities.filter { $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame }.map(\.bundleIdentifier)).count == 1
        }
    }

    nonisolated private static func visibleBanners(applications: [NotificationApplicationIdentity]) -> [Snapshot]? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            let id = ($0.bundleIdentifier ?? "").lowercased()
            return (id.contains("notificationcenter") || id == "com.apple.controlcenter") && id != Bundle.main.bundleIdentifier?.lowercased()
        }
        guard !apps.isEmpty else {
            SystemFeedbackDiagnostics.write("notificationScanning", fields: ["notificationProcesses": 0, "readable": false])
            return nil
        }
        let onScreenWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var results: [Snapshot] = []
        var readable = false
        var diagnostics: [[String: Any]] = []
        var processes: [[String: Any]] = []
        defer { SystemFeedbackDiagnostics.write("notificationScanning", fields: ["notificationProcesses": apps.count, "readable": readable, "windows": diagnostics, "processes": processes, "snapshots": results.count]) }
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            var windowsValue: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue)
            let windows = windowsValue as? [AXUIElement] ?? []
            processes.append(["bundleIdentifier": app.bundleIdentifier ?? "unknown", "axResult": windowResult.rawValue, "windows": windows.count])
            guard windowResult == .success else { continue }
            readable = true
            for window in windows {
                guard let frame = frame(of: window) else { diagnostics.append(["frameReadable": false]); continue }
                let visible = onScreenWindows.contains(where: { info in
                          guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                                (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                                let visibleFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                          return abs(frame.minX - visibleFrame.minX) < 3 && abs(frame.minY - visibleFrame.minY) < 3 &&
                              abs(frame.width - visibleFrame.width) < 3 && abs(frame.height - visibleFrame.height) < 3
                      })
                var metadata: [String: Any] = ["bundleIdentifier": app.bundleIdentifier ?? "unknown", "width": frame.width, "height": frame.height, "onScreenMatch": visible]
                guard intersectsDisplay(frame), visible else { diagnostics.append(metadata); continue }
                let cards = cardRoots(in: window, applications: applications)
                metadata["cards"] = cards.count
                diagnostics.append(metadata)
                for (card, values, sourceLabel) in cards {
                    guard let banner = MacNotificationBannerParser.parse(values, sourceLabel: sourceLabel, applications: applications, allowUnknownSource: true) else { continue }
                    // Ignore changing system chrome such as the relative age.
                    // The content token stays in memory and is never logged.
                    let token = [banner.application.bundleIdentifier, banner.title, banner.body].hashValue
                    results.append(Snapshot(key: "\(app.processIdentifier):\(CFHash(card)):\(token)", texts: values, sourceLabel: sourceLabel))
                }
            }
        }
        return readable ? results : nil
    }

    /// macOS may host small banners inside one transparent full-screen AX
    /// window. Classify the cards, rather than the host's window dimensions.
    nonisolated private static func cardRoots(in root: AXUIElement, applications: [NotificationApplicationIdentity]) -> [(AXUIElement, [String], String?)] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &displayIDs, &displayCount) == .success else { return [] }
        let displays = displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var cards: [(AXUIElement, [String], String?)] = []
        var nodes: [[String: Any]] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while index < queue.count, index < 250, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[index]; index += 1
            let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
            if identifier.hasPrefix("widget") { continue }
            if (attribute(element, "AXHidden") as? Bool) == true { continue }
            let role = attribute(element, kAXRoleAttribute) as? String
            let elementFrame = frame(of: element)
            if nodes.count < 60 {
                nodes.append(["role": role ?? "unknown", "width": elementFrame?.width ?? -1,
                              "height": elementFrame?.height ?? -1, "identifierHasBanner": identifier.lowercased().contains("banner"),
                              "identifierHasNotification": identifier.lowercased().contains("notification")])
            }
            if let elementFrame {
                let title = role == kAXScrollAreaRole ? (attribute(element, kAXTitleAttribute) as? String ?? "") : ""
                guard !MacNotificationBannerGeometry.isHistoryViewport(role: role, frame: elementFrame, title: title) else { continue }
                if displays.contains(where: { MacNotificationBannerGeometry.isTopRightCard(elementFrame, display: $0) }),
                   role != kAXStaticTextRole, role != kAXImageRole, role != kAXButtonRole {
                    let content = text(of: element, applications: applications)
                    if !nodes.isEmpty { nodes[nodes.count - 1]["textFields"] = content.values.count }
                    if !content.widget, MacNotificationBannerParser.parse(content.values, sourceLabel: content.sourceLabel, applications: applications, allowUnknownSource: true) != nil {
                        cards.append((element, content.values, content.sourceLabel))
                        continue // Do not import the same card through its child groups.
                    }
                }
            }
            guard depth < 10 else { continue }
            let children = (attribute(element, kAXVisibleChildrenAttribute) ?? attribute(element, kAXChildrenAttribute)) as? [AXUIElement] ?? []
            queue.append(contentsOf: children.prefix(250).map { ($0, depth + 1) })
        }
        let rootFrame = frame(of: root) ?? .zero
        SystemFeedbackDiagnostics.write("notificationCardSearch-\(Int(rootFrame.width))x\(Int(rootFrame.height))", fields: ["visited": index, "complete": index >= queue.count, "cards": cards.count, "nodes": nodes])
        return cards
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    nonisolated private static func intersectsDisplay(_ frame: CGRect) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayBounds($0).intersects(frame) }
    }

    nonisolated private static func text(of root: AXUIElement, applications: [NotificationApplicationIdentity]) -> (values: [String], sourceLabel: String?, widget: Bool) {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<CFHashCode>()
        var values: [String] = []
        var sourceLabels = Set<String>()
        var widget = false
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        let rootFrame = frame(of: root)
        while index < pending.count, index < 250, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = pending[index]
            index += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            var id: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &id) == .success,
               let id = id as? String, id.hasPrefix("widget") { widget = true; break }
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            let role = roleValue as? String
            // Keep icon provenance separate from visible title/body text.
            // Container descriptions can concatenate private message text.
            let visibleTextFrame = frame(of: element).map { child in
                child.width > 0 && child.height > 0 && (rootFrame?.intersects(child) ?? false)
            } ?? false
            if visibleTextFrame, role == kAXImageRole,
               let label = attribute(element, kAXDescriptionAttribute) as? String,
               let source = MacNotificationBannerParser.applicationSource(label, applications: applications) {
                sourceLabels.insert(source.name)
            }
            if visibleTextFrame, role == kAXStaticTextRole {
                for name in [kAXTitleAttribute, kAXValueAttribute] {
                    if let string = attribute(element, name) as? String, !string.isEmpty { values.append(string) }
                }
            }
            guard depth < 8 else { continue }
            var children: CFTypeRef?
            let visibleResult = AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &children)
            if visibleResult != .success {
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            }
            if let elements = children as? [AXUIElement] {
                pending.append(contentsOf: elements.prefix(250).filter { child in
                    // Do not scrape off-screen children of a visible banner.
                    guard let rootFrame else { return false }
                    // Structural AX groups may omit a frame. They carry no
                    // message text themselves, but their visible children do.
                    guard let childFrame = frame(of: child) else { return true }
                    return childFrame.width > 0 && childFrame.height > 0 && rootFrame.intersects(childFrame)
                }.map { ($0, depth + 1) })
            }
        }
        // A bounded/incomplete traversal must not turn widgets or partial
        // context into a notification attributed to the wrong application.
        return index < pending.count && !widget ? ([], nil, false) : (values, sourceLabels.count == 1 ? sourceLabels.first : nil, widget)
    }
}
