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
    // launchd owns a service by label, not by the displayed application name.
    // Never reuse the retired Review record for the installed local application.
    static let signingIdentifier = "com.workview.SuperIsland.BatteryManagementHelper"
    static let storageIdentifier = signingIdentifier
    static let legacyLabel = signingIdentifier
    static let unifiedLabel = "com.workview.SuperIsland.WE1Debug.BatteryControl"
    static func serviceLabel(bundleIdentifier: String?, executableURL: URL?) -> String {
        var host = bundleIdentifier
        if let executableURL, executableURL.lastPathComponent == "BatteryManagementHelper" {
            let url = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Info.plist")
            host = nil
            if let data = try? Data(contentsOf: url), data.count < 65_536,
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                host = info["CFBundleIdentifier"] as? String
            }
        }
        return host == "com.workview.SuperIsland.WE1Debug" ? unifiedLabel : legacyLabel
    }
    static let label = serviceLabel(bundleIdentifier: Bundle.main.bundleIdentifier, executableURL: Bundle.main.executableURL)
    static let plist = label + ".plist"
    static let legacyPlist = legacyLabel + ".plist"
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
              ["com.workview.SuperIsland", "com.workview.SuperIsland.WE1Debug", "com.workview.SuperIsland.BM1Debug"].contains(identifier) else { return nil }
        return identifier == "com.workview.SuperIsland.BM1Debug" && info["BM1DiagnosticsOnly"] as? Bool == true
    }
    // A narrow compile gate is separate from the broad legacy Review build.
    static var pauseRefreshBuilds: (review: Bool, unified: Bool) {
        #if BATTERY_REVIEW
        let review = true
        #else
        let review = false
        #endif
        #if BATTERY_PAUSE_REFRESH
        let unified = true
        #else
        let unified = false
        #endif
        return (review, unified)
    }
    static func pauseRefreshClient(info: [String: Any], reviewBuild: Bool, unifiedBuild: Bool) -> String? {
        guard info["BM1DiagnosticsOnly"] as? Bool != true,
              info["BM1NativeCutoffTrial"] as? Bool != true,
              info["BM1Preferences79Review"] as? Bool != true else { return nil }
        let identifier = info["CFBundleIdentifier"] as? String
        if reviewBuild, identifier == "com.workview.SuperIsland.BM1Debug",
           info["BM1PauseRefreshTrial"] as? Bool == true, info["WE1PauseRefreshTrial"] as? Bool != true {
            return identifier
        }
        if unifiedBuild, identifier == "com.workview.SuperIsland.WE1Debug",
           info["WE1PauseRefreshTrial"] as? Bool == true, info["BM1PauseRefreshTrial"] as? Bool != true {
            return identifier
        }
        return nil
    }
    static func packagePauseRefreshClient(executableURL: URL?) -> String? {
        guard pauseRefreshBuilds.review || pauseRefreshBuilds.unified,
              let executableURL, executableURL.lastPathComponent == "BatteryManagementHelper" else { return nil }
        let url = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url), data.count < 65_536,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return pauseRefreshClient(info: info, reviewBuild: pauseRefreshBuilds.review, unifiedBuild: pauseRefreshBuilds.unified)
    }
    static func packagePauseRefreshTrial(executableURL: URL?) -> Bool {
        packagePauseRefreshClient(executableURL: executableURL) != nil
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
