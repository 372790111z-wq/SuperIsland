import AppKit
import Combine
import SwiftUI

enum FeatureMenuBarIcon: String, CaseIterable {
    case screenshotLine, keepAwake, battery
    var key: String { "menuBar.\(rawValue).visible" }
    var defaultVisible: Bool { self != .battery }
    var annotationID: String {
        switch self {
        case .screenshotLine: return "si.sc.menu-bar-visible"
        case .keepAwake: return "si.ka.menu-bar-visible"
        case .battery: return "si.bm.menu-bar-visible"
        }
    }
    func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultVisible
    }
}

struct FeatureMenuBarVisibility: Equatable {
    let screenshotLine: Bool
    let keepAwake: Bool
    let battery: Bool
    init(defaults: UserDefaults = .standard) {
        screenshotLine = FeatureMenuBarIcon.screenshotLine.isVisible(in: defaults)
        keepAwake = FeatureMenuBarIcon.keepAwake.isVisible(in: defaults)
        battery = FeatureMenuBarIcon.battery.isVisible(in: defaults)
    }
}

/// Observes only presentation preferences. No runtime/module settings are written.
@MainActor
final class FeatureMenuBarVisibilityObserver {
    private let defaults: UserDefaults
    private let apply: (FeatureMenuBarVisibility) -> Void
    private var current: FeatureMenuBarVisibility?
    private var observer: AnyCancellable?
    init(defaults: UserDefaults = .standard, apply: @escaping (FeatureMenuBarVisibility) -> Void) {
        self.defaults = defaults; self.apply = apply
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }
    func refresh() {
        let next = FeatureMenuBarVisibility(defaults: defaults)
        guard next != current else { return }
        current = next; apply(next)
    }
}

struct FeatureMenuBarToggle: View {
    let feature: FeatureMenuBarIcon
    @AppStorage private var visible: Bool
    init(_ feature: FeatureMenuBarIcon, defaults: UserDefaults? = nil) {
        self.feature = feature
        _visible = AppStorage(wrappedValue: feature.defaultVisible, feature.key, store: defaults)
    }
    var body: some View {
        SettingToggleRow(title: "显示菜单栏图标", description: "只控制图标显示，不改变功能是否启用。", isOn: $visible)
            .toggleStyle(.switch).dataAnnotationID(feature.annotationID)
    }
}

/// A read-only battery entry. Visibility never enables protection or asks for privileges.
@MainActor
final class BatteryStatusMenuController: NSObject, NSMenuDelegate {
    struct Snapshot {
        var presence: BatteryPresence
        var level: Int?
        var charging: Bool
        var text: String { level.map { "电池 \($0)%" } ?? "电池电量暂不可用" }
        var symbol: String {
            guard let level else { return "questionmark.circle" }
            if charging { return "battery.100percent.bolt" }
            switch level { case 0..<13: return "battery.0percent"; case 13..<38: return "battery.25percent"
            case 38..<63: return "battery.50percent"; case 63..<88: return "battery.75percent"; default: return "battery.100percent" }
        }
    }
    private let read: () -> Snapshot
    private let openSettings: () -> Void
    private var observer: AnyCancellable?
    private var requestedVisible = false
    private(set) var statusItem: NSStatusItem?
    init(read: @escaping () -> Snapshot, openSettings: @escaping () -> Void) {
        self.read = read; self.openSettings = openSettings
        super.init()
    }
    convenience init(openSettings: @escaping () -> Void) {
        let battery = BatteryManager.shared
        self.init(read: { Snapshot(presence: battery.presence, level: battery.displayLevel, charging: battery.isCharging) }, openSettings: openSettings)
        observer = battery.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
    }
    func setVisible(_ visible: Bool) { requestedVisible = visible; refresh() }
    func refresh() {
        let snapshot = read()
        guard requestedVisible, snapshot.presence != .absent else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.setAccessibilityIdentifier("data-annotation-id=si.bm.status-item")
            let menu = NSMenu(); menu.delegate = self
            let info = NSMenuItem(title: snapshot.text, action: nil, keyEquivalent: ""); info.isEnabled = false
            menu.addItem(info); menu.addItem(.separator())
            let settings = NSMenuItem(title: "打开电池保护设置…", action: #selector(showSettings), keyEquivalent: "")
            settings.target = self; menu.addItem(settings); item.menu = menu
            statusItem = item
        }
        let image = NSImage(systemSymbolName: snapshot.symbol, accessibilityDescription: "SuperIsland 电池")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = snapshot.text
        statusItem?.menu?.items.first?.title = snapshot.text
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc private func showSettings() { openSettings() }
}
