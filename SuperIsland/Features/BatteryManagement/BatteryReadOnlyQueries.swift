import Foundation

/// Query execution has no reference to the controller singleton, scheduler or
/// lease owner. The only helper operation available here is inspect.
@MainActor
struct BatteryReadOnlyQueries {
    private let defaults: UserDefaults
    private let readTelemetry: () -> BatteryTelemetry
    private let inspect: () async throws -> BatteryControlReport

    init(defaults: UserDefaults = .standard,
         readTelemetry: @escaping () -> BatteryTelemetry = BatteryTelemetry.read,
         inspect: (() async throws -> BatteryControlReport)? = nil) {
        self.defaults = defaults
        self.readTelemetry = readTelemetry
        self.inspect = inspect ?? {
            let client = BatteryManagementClient.defaultTransport()
            let (_, report) = try await client.call(.inspect)
            guard report.protocolVersion == BatteryControlReport.currentProtocolVersion else {
                throw BatteryControlError.unavailable("电池辅助程序版本不兼容，未发起充电控制。")
            }
            return report
        }
    }

    func level() throws -> Int {
        let snapshot = readTelemetry()
        guard snapshot.hasBattery, let level = snapshot.level, (0...100).contains(level) else {
            throw BatteryControlError.unavailable("没有可用的内置电池电量。")
        }
        return level
    }

    func temperature() throws -> Double {
        let snapshot = readTelemetry()
        guard snapshot.hasBattery, let temperature = snapshot.temperature,
              temperature.isFinite, (-10...90).contains(temperature) else {
            throw BatteryControlError.unavailable("电池温度读数不可用。")
        }
        return temperature
    }

    func limit() throws -> Int {
        guard let data = defaults.data(forKey: "batteryManagement.preferences") else {
            return BatteryControlPreferences().limit
        }
        guard let preferences = try? JSONDecoder().decode(BatteryControlPreferences.self, from: data),
              (try? preferences.validate()) != nil else {
            throw BatteryControlError.unavailable("保存的电池偏好无法读取，请在电池设置中检查；没有改写偏好。")
        }
        return preferences.limit
    }

    func status() async -> String {
        let snapshot = readTelemetry()
        let charging = !snapshot.hasBattery ? "没有内置电池" : snapshot.chargingObservation.map { $0 ? "正在充电" : "当前未充电" } ?? "充电状态未知"
        let savedLimit = (try? limit()).map { "\($0)%" } ?? "无法读取"
        do {
            let report = try await inspect()
            let registered = report.registeredTarget.map { "\($0)%" } ?? "未确认"
            let native = report.nativeSavedLimit.map { "\($0)%" } ?? "未确认"
            return "\(charging)；长期上限\(savedLimit)；系统登记目标\(registered)；系统手动上限读回\(native)；\(report.message)"
        } catch {
            return "\(charging)；长期上限\(savedLimit)；辅助程序状态不可用：\(error.localizedDescription)"
        }
    }
}

enum BatteryStartupContext {
    /// AppKit documents false for Services and other non-default launches.
    /// Missing metadata also defers control; it never authorizes a write.
    static var currentProcessIsDiagnostic: Bool {
        diagnosticsOnly(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: ProcessInfo.processInfo.arguments,
            packageFlag: Bundle.main.object(forInfoDictionaryKey: "BM1DiagnosticsOnly") as? Bool == true)
    }
    static func diagnosticsOnly(bundleIdentifier: String?, arguments: [String], packageFlag: Bool = false) -> Bool {
        bundleIdentifier == "com.workview.SuperIsland.BM1Debug" && (packageFlag || arguments.contains("--bm1-diagnostics"))
    }
    static func automaticallyEnables(defaultLaunch: Bool?, bundleIdentifier: String? = nil, arguments: [String] = [], packageFlag: Bool = false) -> Bool {
        defaultLaunch == true && !diagnosticsOnly(bundleIdentifier: bundleIdentifier, arguments: arguments, packageFlag: packageFlag)
    }
}
