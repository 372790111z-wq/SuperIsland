import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

struct WindowShortcut: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    var formattedDisplay: String {
        Self.displayString(keyCode: keyCode, modifiers: modifiers, fallback: display)
    }

    private static func displayString(keyCode: UInt32, modifiers: UInt32, fallback: String) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        let keyLabel: String
        switch Int(keyCode) {
        case kVK_LeftArrow: keyLabel = "←"
        case kVK_RightArrow: keyLabel = "→"
        case kVK_UpArrow: keyLabel = "↑"
        case kVK_DownArrow: keyLabel = "↓"
        case kVK_Return: keyLabel = "↩"
        case kVK_Tab: keyLabel = "⇥"
        case kVK_Space: keyLabel = "Space"
        case kVK_Delete: keyLabel = "⌫"
        case kVK_ForwardDelete: keyLabel = "⌦"
        case kVK_Escape: keyLabel = "Esc"
        case kVK_Home: keyLabel = "↖"
        case kVK_End: keyLabel = "↘"
        case kVK_PageUp: keyLabel = "⇞"
        case kVK_PageDown: keyLabel = "⇟"
        case kVK_Help: keyLabel = "Help"
        case kVK_F1: keyLabel = "F1"
        case kVK_F2: keyLabel = "F2"
        case kVK_F3: keyLabel = "F3"
        case kVK_F4: keyLabel = "F4"
        case kVK_F5: keyLabel = "F5"
        case kVK_F6: keyLabel = "F6"
        case kVK_F7: keyLabel = "F7"
        case kVK_F8: keyLabel = "F8"
        case kVK_F9: keyLabel = "F9"
        case kVK_F10: keyLabel = "F10"
        case kVK_F11: keyLabel = "F11"
        case kVK_F12: keyLabel = "F12"
        case kVK_F13: keyLabel = "F13"
        case kVK_F14: keyLabel = "F14"
        case kVK_F15: keyLabel = "F15"
        case kVK_F16: keyLabel = "F16"
        case kVK_F17: keyLabel = "F17"
        case kVK_F18: keyLabel = "F18"
        case kVK_F19: keyLabel = "F19"
        case kVK_F20: keyLabel = "F20"
        case kVK_ANSI_KeypadEnter: keyLabel = "⌤"
        default:
            let candidate = fallback
                .replacingOccurrences(of: "⌃", with: "")
                .replacingOccurrences(of: "⌥", with: "")
                .replacingOccurrences(of: "⇧", with: "")
                .replacingOccurrences(of: "⌘", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let containsPrivateUseScalar = candidate.unicodeScalars.contains {
                (0xE000...0xF8FF).contains(Int($0.value))
            }
            keyLabel = candidate.isEmpty || containsPrivateUseScalar
                ? "Key \(keyCode)"
                : candidate
        }
        parts.append(keyLabel)
        return parts.joined()
    }
}

enum WindowLayout: String, CaseIterable, Identifiable, Hashable {
    case leftHalf
    case rightHalf
    case maximize
    case leftThird
    case centerThird
    case rightThird
    case topHalf
    case bottomHalf
    case leftTwoThirds
    case rightTwoThirds
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    var id: String { rawValue }
    var shortcutID: String { "layout.\(rawValue)" }

    /// WINS 设置页提供快捷键的 10 个单窗口位置。
    /// 四分之一位置只用于顶部组合分屏岛，不拆成四张独立快捷键卡。
    static let shortcutLayouts: [WindowLayout] = [
        .leftHalf, .rightHalf, .maximize,
        .leftThird, .centerThird, .rightThird,
        .topHalf, .bottomHalf,
        .leftTwoThirds, .rightTwoThirds
    ]

    var title: String {
        switch self {
        case .leftHalf: "左半屏"
        case .rightHalf: "右半屏"
        case .maximize: "最大化"
        case .leftThird: "左侧三分之一"
        case .centerThird: "居中三分之一"
        case .rightThird: "右侧三分之一"
        case .topHalf: "上半屏"
        case .bottomHalf: "下半屏"
        case .leftTwoThirds: "左侧三分之二"
        case .rightTwoThirds: "右侧三分之二"
        case .topLeftQuarter: "左上四分之一"
        case .topRightQuarter: "右上四分之一"
        case .bottomLeftQuarter: "左下四分之一"
        case .bottomRightQuarter: "右下四分之一"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .maximize: "rectangle.inset.filled"
        case .leftThird: "rectangle.split.3x1.fill"
        case .centerThird: "rectangle.split.3x1"
        case .rightThird: "rectangle.split.3x1.fill"
        case .topHalf: "rectangle.tophalf.inset.filled"
        case .bottomHalf: "rectangle.bottomhalf.inset.filled"
        case .leftTwoThirds: "rectangle.split.3x1.fill"
        case .rightTwoThirds: "rectangle.split.3x1.fill"
        case .topLeftQuarter: "rectangle.tophalf.inset.filled"
        case .topRightQuarter: "rectangle.tophalf.inset.filled"
        case .bottomLeftQuarter: "rectangle.bottomhalf.inset.filled"
        case .bottomRightQuarter: "rectangle.bottomhalf.inset.filled"
        }
    }
}

enum WindowQuickAction: String, CaseIterable, Identifiable, Hashable {
    case closeWindow
    case quitApp
    case dockDisplayLock
    case hideAll
    case hideOthers
    case nextDisplay
    case previousDisplay
    case centerWindow

    var id: String { rawValue }
    var shortcutID: String { "action.\(rawValue)" }

    static let legacyDockDisplayLockRawValue = "lockScreen"
    static let legacyDockDisplayLockShortcutID = "action.lockScreen"

    var title: String {
        switch self {
        case .closeWindow: "关闭窗口"
        case .quitApp: "退出程序"
        case .dockDisplayLock: "Dock 固定到显示器"
        case .hideAll: "隐藏/显示所有窗口"
        case .hideOthers: "隐藏其他窗口"
        case .nextDisplay: "移动到下个显示器"
        case .previousDisplay: "移动到上个显示器"
        case .centerWindow: "窗口居中"
        }
    }
}

/// Finder file operations remain separate from window actions and their IDs.
enum FinderFileShortcut {
    static let id = "file.moveToTrash"
    static let title = "快捷删除文件"
}

struct WindowEnhancementFeedbackEvent: Equatable, Identifiable {
    let id: UInt64
    let message: String
}

@MainActor
final class WindowEnhancementPreferences: ObservableObject {
    static let shared = WindowEnhancementPreferences()
    static let islandReadyMessage = "窗口中心 · 已就绪"

    private struct PendingShortcutChange {
        let previous: WindowShortcut?
        let attempted: WindowShortcut
    }

    private enum Key {
        static let enabled = "windowEnhancement.enabled"
        static let edgeSnap = "windowEnhancement.edgeSnap"
        static let snapIsland = "windowEnhancement.snapIsland"
        static let aeroShake = "windowEnhancement.aeroShake"
        static let dockPreview = "windowEnhancement.dockPreview"
        static let missionControl = "windowEnhancement.missionControl"
        static let dockReverse = "windowEnhancement.dockReverse"
        static let cmdTabPlus = "windowEnhancement.cmdTabPlus"
        static let fileTrash = "windowEnhancement.fileTrash"
        static let reserveStageManagerSpace = "windowEnhancement.reserveStageManagerSpace"
        static let windowSpacing = "windowEnhancement.windowSpacing"
        static let accent = "windowEnhancement.accent"
        static let excludedBundleIDs = "windowEnhancement.excludedBundleIDs"
        static let shortcuts = "windowEnhancement.shortcuts"
        static let disabledActions = "windowEnhancement.disabledActions"
    }

    private let defaults: UserDefaults
    private var pendingShortcutChanges: [String: PendingShortcutChange] = [:]
    private var nextShortcutPreflightID: UInt32 = 1
    private var nextFeedbackEventID: UInt64 = 0

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    @Published var edgeSnapEnabled: Bool { didSet { defaults.set(edgeSnapEnabled, forKey: Key.edgeSnap) } }
    @Published var snapIslandEnabled: Bool { didSet { defaults.set(snapIslandEnabled, forKey: Key.snapIsland) } }
    @Published var aeroShakeEnabled: Bool { didSet { defaults.set(aeroShakeEnabled, forKey: Key.aeroShake) } }
    @Published var dockPreviewEnabled: Bool { didSet { defaults.set(dockPreviewEnabled, forKey: Key.dockPreview) } }
    @Published var missionControlEnabled: Bool { didSet { defaults.set(missionControlEnabled, forKey: Key.missionControl) } }
    @Published var dockReverseEnabled: Bool { didSet { defaults.set(dockReverseEnabled, forKey: Key.dockReverse) } }
    @Published var cmdTabPlusEnabled: Bool { didSet { defaults.set(cmdTabPlusEnabled, forKey: Key.cmdTabPlus) } }
    @Published var fileTrashEnabled: Bool { didSet { defaults.set(fileTrashEnabled, forKey: Key.fileTrash) } }
    @Published var reserveStageManagerSpace: Bool { didSet { defaults.set(reserveStageManagerSpace, forKey: Key.reserveStageManagerSpace) } }
    @Published var windowSpacingEnabled: Bool { didSet { defaults.set(windowSpacingEnabled, forKey: Key.windowSpacing) } }
    @Published var accentName: String { didSet { defaults.set(accentName, forKey: Key.accent) } }
    @Published var excludedBundleIDs: [String] { didSet { persistExcludedApps() } }
    @Published private(set) var shortcuts: [String: WindowShortcut]
    @Published private(set) var disabledActionIDs: Set<String>
    @Published private(set) var lastFeedback: String?
    /// Runtime-only island/HUD event. The monotonically increasing id makes
    /// repeated identical messages observable without entering the persisted
    /// configuration stream.
    @Published private(set) var feedbackEvent: WindowEnhancementFeedbackEvent?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: true,
            Key.edgeSnap: false,
            Key.snapIsland: false,
            Key.aeroShake: false,
            Key.dockPreview: false,
            Key.missionControl: false,
            Key.dockReverse: false,
            Key.cmdTabPlus: false,
            Key.fileTrash: false,
            // Do not shrink every layout by default. Users who actively use
            // Stage Manager can opt in from Advanced settings.
            Key.reserveStageManagerSpace: false,
            Key.windowSpacing: false,
            Key.accent: "blue"
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        edgeSnapEnabled = defaults.bool(forKey: Key.edgeSnap)
        snapIslandEnabled = defaults.bool(forKey: Key.snapIsland)
        aeroShakeEnabled = defaults.bool(forKey: Key.aeroShake)
        dockPreviewEnabled = defaults.bool(forKey: Key.dockPreview)
        missionControlEnabled = defaults.bool(forKey: Key.missionControl)
        dockReverseEnabled = defaults.bool(forKey: Key.dockReverse)
        cmdTabPlusEnabled = defaults.bool(forKey: Key.cmdTabPlus)
        fileTrashEnabled = defaults.bool(forKey: Key.fileTrash)
        reserveStageManagerSpace = defaults.bool(forKey: Key.reserveStageManagerSpace)
        windowSpacingEnabled = defaults.bool(forKey: Key.windowSpacing)
        accentName = defaults.string(forKey: Key.accent) ?? "blue"
        excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []
        var migratedDisabledActionIDs = Set(defaults.stringArray(forKey: Key.disabledActions) ?? [])
        let hadLegacyDisabledDockLock = migratedDisabledActionIDs.remove(
            WindowQuickAction.legacyDockDisplayLockRawValue
        ) != nil
        if hadLegacyDisabledDockLock {
            migratedDisabledActionIDs.insert(WindowQuickAction.dockDisplayLock.rawValue)
            defaults.set(Array(migratedDisabledActionIDs).sorted(), forKey: Key.disabledActions)
        }
        disabledActionIDs = migratedDisabledActionIDs
        if let data = defaults.data(forKey: Key.shortcuts),
           let decoded = try? JSONDecoder().decode([String: WindowShortcut].self, from: data) {
            var migratedShortcuts = decoded
            let legacyShortcut = migratedShortcuts.removeValue(
                forKey: WindowQuickAction.legacyDockDisplayLockShortcutID
            )
            if migratedShortcuts[WindowQuickAction.dockDisplayLock.shortcutID] == nil,
               let legacyShortcut {
                migratedShortcuts[WindowQuickAction.dockDisplayLock.shortcutID] = legacyShortcut
            }
            shortcuts = migratedShortcuts
            if legacyShortcut != nil,
               let migratedData = try? JSONEncoder().encode(migratedShortcuts) {
                defaults.set(migratedData, forKey: Key.shortcuts)
            }
        } else {
            shortcuts = [:]
        }
    }

    /// Emits only for persisted window-enhancement configuration. Runtime
    /// feedback intentionally stays out of this stream so showing a HUD does
    /// not tear down and rebuild every hot key and interaction monitor.
    var configurationChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            changePublisher($isEnabled),
            changePublisher($edgeSnapEnabled),
            changePublisher($snapIslandEnabled),
            changePublisher($aeroShakeEnabled),
            changePublisher($dockPreviewEnabled),
            changePublisher($missionControlEnabled),
            changePublisher($dockReverseEnabled),
            changePublisher($cmdTabPlusEnabled),
            changePublisher($fileTrashEnabled),
            changePublisher($reserveStageManagerSpace),
            changePublisher($windowSpacingEnabled),
            changePublisher($accentName),
            changePublisher($excludedBundleIDs),
            changePublisher($shortcuts),
            changePublisher($disabledActionIDs)
        ])
        .eraseToAnyPublisher()
    }

    func shortcut(for id: String) -> WindowShortcut? {
        shortcuts[id]
    }

    func isActionEnabled(_ action: WindowQuickAction) -> Bool {
        !disabledActionIDs.contains(action.rawValue)
    }

    func setActionEnabled(_ enabled: Bool, action: WindowQuickAction) {
        if enabled {
            disabledActionIDs.remove(action.rawValue)
        } else {
            disabledActionIDs.insert(action.rawValue)
        }
        defaults.set(Array(disabledActionIDs).sorted(), forKey: Key.disabledActions)
    }

    @discardableResult
    func setShortcut(_ shortcut: WindowShortcut?, for id: String) -> Bool {
        let current = shortcuts[id]
        if current == shortcut {
            publishFeedback(shortcut == nil
                ? "当前没有设置快捷键"
                : "快捷键保持为 \(shortcut?.formattedDisplay ?? "")")
            return true
        }
        if let shortcut,
           let conflict = shortcuts.first(where: { $0.key != id && $0.value.keyCode == shortcut.keyCode && $0.value.modifiers == shortcut.modifiers }) {
            publishFeedback("快捷键与 \(displayName(for: conflict.key)) 冲突")
            return false
        }
        if let shortcut,
           let reserved = pendingShortcutChanges.first(where: {
               guard $0.key != id, let previous = $0.value.previous else { return false }
               return sameChord(previous, shortcut)
           }) {
            publishFeedback("\(displayName(for: reserved.key)) 的原快捷键正在更新，请稍后重试")
            return false
        }

        if let shortcut, !canTemporarilyRegister(shortcut) {
            publishFeedback("快捷键已被系统或其他 App 占用，已保留原设置")
            return false
        }

        if let shortcut {
            let previous: WindowShortcut?
            if let pending = pendingShortcutChanges[id] {
                previous = pending.previous
            } else {
                previous = current
            }
            pendingShortcutChanges[id] = PendingShortcutChange(
                previous: previous,
                attempted: shortcut
            )
        } else {
            pendingShortcutChanges.removeValue(forKey: id)
        }
        shortcuts[id] = shortcut
        persistShortcuts()
        if let shortcut, let warning = shortcutSafetyWarning(for: id) {
            publishFeedback("已设置快捷键 \(shortcut.formattedDisplay)。注意：\(warning)")
        } else {
            publishFeedback(shortcut == nil ? "已清除快捷键" : "已设置快捷键 \(shortcut?.formattedDisplay ?? "")")
        }
        return true
    }

    /// Returns a non-blocking warning for a globally registered shortcut that
    /// is commonly owned by the frontmost app or by macOS. Settings can render
    /// this next to the recorder without changing the existing conflict and
    /// registration rollback behavior.
    func shortcutSafetyWarning(for id: String) -> String? {
        // The file shortcut is active only while Finder is frontmost. It does
        // not replace this chord inside every other application.
        guard id != FinderFileShortcut.id else { return nil }
        guard let shortcut = shortcuts[id] else { return nil }
        return shortcutSafetyWarning(for: shortcut)
    }

    func shortcutSafetyWarning(for shortcut: WindowShortcut) -> String? {
        guard shortcut.modifiers == UInt32(cmdKey) else { return nil }
        switch Int(shortcut.keyCode) {
        case kVK_ANSI_D:
            return "⌘D 常用于收藏、复制或其他 App 内操作，全局注册会优先截获它"
        case kVK_ANSI_W:
            return "⌘W 是标准关闭窗口快捷键，全局注册会改变所有 App 的原生行为"
        case kVK_LeftArrow, kVK_RightArrow:
            return "⌘←／⌘→ 常用于页面、历史和文本导航，全局注册会优先截获它"
        case kVK_ANSI_Q:
            return "⌘Q 是标准退出 App 快捷键，全局注册会改变所有 App 的原生行为"
        case kVK_ANSI_H, kVK_ANSI_M:
            return "这个组合是常用的 macOS 窗口快捷键，全局注册会改变所有 App 的原生行为"
        case kVK_Tab, kVK_Space:
            return "这个组合通常由 macOS 管理，全局注册可能与系统切换或搜索冲突"
        default:
            return nil
        }
    }

    /// Finalizes a preflighted shortcut once Carbon has registered it in the
    /// live registry. This keeps the pending rollback window intentionally
    /// short and avoids retaining stale transactions across unrelated changes.
    func finishShortcutRegistration(_ shortcut: WindowShortcut, for id: String) {
        guard pendingShortcutChanges[id]?.attempted == shortcut else { return }
        pendingShortcutChanges.removeValue(forKey: id)
    }

    /// Restores the value that was persisted before a preflighted shortcut if
    /// the real registry still loses the race to the system or another process.
    @discardableResult
    func rollbackShortcutRegistration(_ shortcut: WindowShortcut, for id: String) -> Bool {
        guard let pending = pendingShortcutChanges[id],
              pending.attempted == shortcut,
              shortcuts[id] == shortcut else { return false }
        pendingShortcutChanges.removeValue(forKey: id)
        if let previous = pending.previous,
           shortcuts.contains(where: { $0.key != id && sameChord($0.value, previous) }) {
            return false
        }
        shortcuts[id] = pending.previous
        persistShortcuts()
        return true
    }

    func addExcludedApp(bundleID: String) {
        guard !bundleID.isEmpty, !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
    }

    func removeExcludedApp(bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
    }

    func isExcluded(_ application: NSRunningApplication?) -> Bool {
        guard let bundleID = application?.bundleIdentifier else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    func publishFeedback(_ message: String) {
        lastFeedback = message
        nextFeedbackEventID &+= 1
        if nextFeedbackEventID == 0 { nextFeedbackEventID = 1 }
        feedbackEvent = WindowEnhancementFeedbackEvent(
            id: nextFeedbackEventID,
            message: message
        )
    }

    private func persistShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: Key.shortcuts)
        }
    }

    private func persistExcludedApps() {
        defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs)
    }

    private func changePublisher<Value>(
        _ publisher: Published<Value>.Publisher
    ) -> AnyPublisher<Void, Never> {
        publisher
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    private func sameChord(_ lhs: WindowShortcut, _ rhs: WindowShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    private func canTemporarilyRegister(_ shortcut: WindowShortcut) -> Bool {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: 0x53495750, // SIWP — SuperIsland Window preflight
            id: nextShortcutPreflightID
        )
        nextShortcutPreflightID &+= 1
        if nextShortcutPreflightID == 0 { nextShortcutPreflightID = 1 }

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            if let reference { UnregisterEventHotKey(reference) }
            return false
        }
        UnregisterEventHotKey(reference)
        return true
    }

    private func displayName(for id: String) -> String {
        if id == FinderFileShortcut.id { return FinderFileShortcut.title }
        if let layout = WindowLayout.allCases.first(where: { $0.shortcutID == id }) { return layout.title }
        if let action = WindowQuickAction.allCases.first(where: { $0.shortcutID == id }) { return action.title }
        return id
    }
}

extension WindowShortcut {
    static func from(event: NSEvent) -> WindowShortcut? {
        let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !relevant.isEmpty else { return nil }

        var carbonModifiers: UInt32 = 0
        if relevant.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if relevant.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if relevant.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if relevant.contains(.command) { carbonModifiers |= UInt32(cmdKey) }

        let fallback = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let display = displayString(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            fallback: fallback
        )
        return WindowShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            display: display
        )
    }
}
