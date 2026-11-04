import Foundation

@objc protocol BatteryManagementProtocol {
    func inspect(reply: @escaping (Data) -> Void)
    /// Fixed read-only probes. The daemon rejects this while any control or
    /// recovery session exists; callers cannot choose a selector or command.
    func diagnoseNativeReads(reply: @escaping (Data) -> Void)
    /// Fixed, sealed Review experiment. Production helpers reject this endpoint.
    /// A client cannot supply a target, raw key, path, domain or payload.
    func preferences79(action: String, owner: String, reply: @escaping (Data) -> Void)
    func renew(request: Data, reply: @escaping (Bool, Data) -> Void)
    func prepareExitHold(owner: String, reply: @escaping (Bool, Data) -> Void)
    func release(owner: String, reply: @escaping (Bool, Data) -> Void)
}

#if BATTERY_REVIEW || DEBUG
struct BatteryNativeReadDiagnostic: Codable, Equatable {
    var query: String
    var completedAt = Date()
    var value: Int?
    var workerPID: Int32?
    var elapsed: TimeInterval
    var phase: String?
    var error: String?
}
#endif

enum BatteryManagementIdentity {
    static let label = "com.workview.SuperIsland.BatteryManagementHelper"
    static let plist = label + ".plist"
    static func diagnosticHelper(arguments: [String], packageFlag: Bool? = false) -> Bool {
        packageFlag != false || arguments.contains("--bm1-helper-diagnostics")
    }
    /// Read the actual enclosing application as well as launchd arguments:
    /// a cached registration may predate the new diagnostic argument.
    static func packageDiagnosticsOnly(executableURL: URL?) -> Bool? {
        guard let executableURL, executableURL.lastPathComponent == "BatteryManagementHelper" else { return nil }
        let infoURL = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL), data.count < 65_536,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              ["com.workview.SuperIsland", "com.workview.SuperIsland.BM1Debug"].contains(identifier) else { return nil }
        return identifier == "com.workview.SuperIsland.BM1Debug" && info["BM1DiagnosticsOnly"] as? Bool == true
    }
    static func packagePauseRefreshTrial(executableURL: URL?) -> Bool {
        #if BATTERY_REVIEW
        guard let executableURL, executableURL.lastPathComponent == "BatteryManagementHelper" else { return false }
        let url = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url), data.count < 65_536,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == "com.workview.SuperIsland.BM1Debug"
            && info["BM1PauseRefreshTrial"] as? Bool == true
            && info["BM1DiagnosticsOnly"] as? Bool != true
            && info["BM1NativeCutoffTrial"] as? Bool != true
            && info["BM1Preferences79Review"] as? Bool != true
        #else
        return false
        #endif
    }
    static func packageNativeCutoffTrial(executableURL: URL?) -> Bool {
        guard let executableURL, executableURL.lastPathComponent == "BatteryManagementHelper" else { return false }
        let infoURL = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL), data.count < 65_536,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == "com.workview.SuperIsland.BM1Debug"
            && info["BM1NativeCutoffTrial"] as? Bool == true
            && info["BM1NativeCutoffTrialDurationSeconds"] as? Int == Int(BatteryNativeCutoffTrial.maximumDuration)
            && info["BM1DiagnosticsOnly"] as? Bool != true
    }

}

/// Fixed device-acceptance scope, available only in an explicitly sealed Review
/// package. No client can choose its range, neutral target or watchdog deadline.
enum BatteryNativeCutoffTrial {
    static let neutralLimit = 85
    static let maximumDuration: TimeInterval = 600
    static func validateStart(telemetry: BatteryTelemetry) throws {
        guard telemetry.adapterConnectionCandidate == true else {
            throw BatteryControlError.unavailable("有界放电试验尚未确认物理连接，未开始断供。")
        }
    }
    static func validate(_ request: BatteryControlRequest, level: Int?) throws {
        guard let level, (79...85).contains(level),
              request.mode != .topUp, request.calibration == nil, !request.sleeping,
              request.mode != .discharge || request.dischargeTarget == 80 else {
            throw BatteryControlError.unavailable("固定复测仅限79–85%、目标80的有界放电；其他模式未开放。")
        }
        try validatePreferences(request.preferences)
    }
    static func validatePreferences(_ p: BatteryControlPreferences) throws {
        guard (80...85).contains(p.limit), !p.allowLowLimit, !p.automaticDischarge, !p.sailing, !p.heatProtection,
              p.sleep == .unchanged, p.lowPower == .never, p.highPowerScope == .never,
              p.led == .system, !p.blinkWhileDischarging else {
            throw BatteryControlError.unavailable("本验证包仅开放80–85%限充、目标80%的手动放电及暂停恢复；其他充电规则暂未开放。")
        }
    }
}
