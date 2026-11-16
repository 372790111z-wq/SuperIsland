import Foundation

/// Present from launch, including when the feed starts disabled. Every settings
/// entry point (menu, settings, reset) must activate the same source lifecycle.
@MainActor
final class NotificationPreferencesObserver {
    private struct Snapshot: Equatable {
        var enabled: Bool
        var sources: String
        init(_ defaults: UserDefaults) {
            enabled = defaults.object(forKey: "module.notifications.enabled") as? Bool ?? true
            sources = defaults.string(forKey: "module.notifications.enabledSources") ?? NotificationFeedSource.defaultEnabledRawValue
        }
    }
    private let defaults: UserDefaults
    private let changed: () -> Void
    private var snapshot: Snapshot
    private var observer: NSObjectProtocol?
    init(defaults: UserDefaults = .standard, changed: @escaping () -> Void) {
        self.defaults = defaults; self.changed = changed; snapshot = Snapshot(defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if snapshot.enabled { changed() }
    }
    func refresh() {
        let value = Snapshot(defaults)
        guard value != snapshot else { return }
        snapshot = value; changed()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
