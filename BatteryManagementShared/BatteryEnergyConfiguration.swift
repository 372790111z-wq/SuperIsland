import Foundation

#if BATTERY_HELPER || DEBUG

/// Only explicit per-source values qualify; missing fields and duplicate or
/// contradictory flags never authorize a power-mode write.
struct BatteryEnergyConfiguration {
    struct Source {
        var lowPower: Int?
        var highPower: Int?
        var mode: Int? {
            guard let lowPower, let highPower, (0...1).contains(lowPower), (0...1).contains(highPower),
                  lowPower + highPower <= 1 else { return nil }
            return highPower == 1 ? 2 : lowPower
        }
    }
    var battery = Source()
    var adapter = Source()
    var highPowerSupported: Bool { battery.mode != nil && adapter.mode != nil }
    static func advertisesHighPower(_ capabilities: String) -> Bool {
        capabilities.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "highpowermode"
        }
    }

    static func parse(_ text: String) -> BatteryEnergyConfiguration? {
        var values: [String: [String: Int]] = [:]
        var source: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                source = ["Battery Power:", "AC Power:"].contains(trimmed) ? trimmed : nil
                if let source {
                    guard values[source] == nil else { return nil }
                    values[source] = [:]
                }
                continue
            }
            let words = trimmed.split(whereSeparator: \.isWhitespace)
            guard let source, let key = words.first.map(String.init), ["lowpowermode", "highpowermode"].contains(key) else { continue }
            guard words.count == 2, let value = Int(words[1]), (0...1).contains(value), values[source]?[key] == nil else { return nil }
            values[source]?[key] = value
        }
        guard let battery = values["Battery Power:"], let adapter = values["AC Power:"] else { return nil }
        return .init(battery: .init(lowPower: battery["lowpowermode"], highPower: battery["highpowermode"]),
                     adapter: .init(lowPower: adapter["lowpowermode"], highPower: adapter["highpowermode"]))
    }
}

enum BatteryEnergyTargets {
    static func make(preferences: BatteryControlPreferences, highPowerSupported: Bool) throws -> [String: Int] {
        try preferences.validate()
        let high = preferences.highPowerScope, low = preferences.lowPower
        guard high != .never || low != .never else { return [:] }
        guard high == .never || highPowerSupported else {
            throw BatteryControlError.unavailable("没有可确认的高功率模式与恢复能力，未修改能源设置。")
        }
        if highPowerSupported {
            return ["powerModeBattery": high.applies(onAC: false) ? 2 : low.applies(onAC: false) ? 1 : 0,
                    "powerModeAC": high.applies(onAC: true) ? 2 : low.applies(onAC: true) ? 1 : 0]
        }
        return ["lowPowerBattery": low.applies(onAC: false) ? 1 : 0,
                "lowPowerAC": low.applies(onAC: true) ? 1 : 0]
    }
}

#endif
