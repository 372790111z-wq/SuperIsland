import Foundation

/// New settings never reinterpret archived advanced preferences as live rules.
struct BatterySimplePreferences: Codable, Equatable {
    static let key = "batteryProtection.v1.configuration"
    var enabled = false
    var limit = 80
    var needsLimitChoice = false
    var leaseMayExist = false
    var recoveryPending = false
    var migrationPending = true

    static func load(_ defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data),
           (80...100).contains(value.limit) {
            var restored = value
            restored.recoveryPending = value.recoveryPending || value.leaseMayExist
            return restored
        }
        // Archive once. Never overwrite the backup on retry/restart.
        let backup = "batteryProtection.v1.legacyBackup"
        if defaults.object(forKey: backup) == nil {
            var saved: [String: Data] = [:]
            for key in ["batteryManagement.preferences", "batteryManagement.display"] {
                if let data = defaults.data(forKey: key) { saved[key] = data }
            }
            defaults.set(saved, forKey: backup)
        }
        var value = Self()
        if let raw = defaults.data(forKey: "batteryManagement.preferences") {
            if let legacy = try? JSONDecoder().decode(BatteryControlPreferences.self, from: raw), (80...100).contains(legacy.limit) {
                value.limit = legacy.limit
            } else { value.needsLimitChoice = true }
        }
        // Old releases did not persist an explicit enable choice. Unknown is
        // not permission to acquire a fresh lease during migration.
        if defaults.object(forKey: key) != nil { value.needsLimitChoice = true }
        value.save(defaults)
        return value
    }
    func save(_ defaults: UserDefaults) { defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}
