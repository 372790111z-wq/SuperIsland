import Foundation

extension Notification.Name {
    static let superIslandSettingsWillReset = Notification.Name("superIslandSettingsWillReset")
    static let superIslandSettingsDidReset = Notification.Name("superIslandSettingsDidReset")
}

@MainActor
enum ApplicationSettingsReset {
    /// Callers pass the active bundle's exact domain. Extension runtimes stop
    /// synchronously before removal so onDeactivate cannot rewrite old state.
    static func reset(
        defaults: UserDefaults,
        domain: String,
        windowPreferences: WindowEnhancementPreferences,
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(name: .superIslandSettingsWillReset, object: nil)
        defaults.removePersistentDomain(forName: domain)
        windowPreferences.reloadFromDefaults()
        notificationCenter.post(name: .superIslandSettingsDidReset, object: nil)
    }
}
