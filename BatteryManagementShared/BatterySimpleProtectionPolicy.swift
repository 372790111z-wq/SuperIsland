import Foundation

/// The reduced product admits only an upper limit and an explicit discharge.
/// Legacy wire types remain decodable solely for safe rejection and recovery.
enum BatterySimpleProtectionPolicy {
    static let removedMessage = "精简版已移除此电池操作，请使用电池保护页面。"
    static func preferences(limit: Int) -> BatteryControlPreferences {
        var value = BatteryControlPreferences(); value.limit = limit; return value
    }
    static func validate(_ preferences: BatteryControlPreferences) throws {
        guard (80...100).contains(preferences.limit),
              preferences == self.preferences(limit: preferences.limit) else {
            throw BatteryControlError.invalid("精简版仅支持80–100%充电上限，旧高级规则不会执行。")
        }
    }
    static func validate(_ request: BatteryControlRequest) throws {
        guard request.simpleProtectionVersion == 1,
              request.mode == .automatic || request.mode == .discharge,
              request.calibration == nil,
              !(request.sleeping && request.mode == .discharge) else {
            throw BatteryControlError.unavailable(removedMessage)
        }
        try validate(request.preferences)
        try request.validate()
    }
}
