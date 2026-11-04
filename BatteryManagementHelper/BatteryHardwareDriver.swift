import Foundation
import IOKit
import ObjectiveC
import Darwin

/// All privileged operations are fixed here. No caller can supply a command,
/// path, preference domain, register name or raw byte buffer through XPC.
final class BatteryHardwareDriver {
    typealias Mechanism = BatteryControlCapabilities.Backend
    let smc: BatterySMC?
    let mechanism: Mechanism?
    let preferencesBackend: BatteryPreferencesBackend?
    var nativeTargetKey: String { preferencesBackend == nil ? "nativeAPILimit" : "preferencesTarget" }
    var reportedMechanism: Mechanism? { mechanism == .native && preferencesBackend != nil ? .nativePreferences : mechanism }
    let dischargeKey: String?
    private let pauseRefreshTrial = BatteryManagementIdentity.packagePauseRefreshTrial(executableURL: Bundle.main.executableURL)
    // Keep the discovered cutoff key for legacy/modern operation and recovery
    // of historical ownership. Native manual-limit discharge never arms it.
    let nativeCutoffReviewTrial = BatteryManagementIdentity.packageNativeCutoffTrial(executableURL: Bundle.main.executableURL)
    // Historical cutoff recovery may still refer to its previous neutral limit;
    // new native target planning does not use this property.
    var nativeDischargeNeutralTarget: Int { nativeCutoffReviewTrial ? BatteryNativeCutoffTrial.neutralLimit : 100 }
    var dischargeSupported: Bool {
        guard let mechanism, mechanism != .intel else { return false }
        return mechanism == .native || dischargeKey != nil
    }
    var minimumDischargeTarget: Int? {
        guard dischargeSupported else { return nil }
        return mechanism == .native && preferencesBackend == nil ? BatteryNativeDischargePlanner.minimumTarget : 20
    }
    var dischargeMechanism: BatteryDischargeMechanism? {
        guard dischargeSupported else { return nil }
        return mechanism == .native ? .nativeLimit : .adapterCutoff
    }
    var calibrationSupported: Bool { !nativeCutoffReviewTrial && mechanism != nil && mechanism != .intel && (mechanism != .native || preferencesBackend != nil) && dischargeSupported }
    var capabilities: BatteryControlCapabilities {
        .init(backend: reportedMechanism, dischargeSupported: dischargeSupported, minimumDischargeTarget: minimumDischargeTarget,
            led: ledSupported, highPower: highPowerSupported, calibration: calibrationSupported, reviewTrial: nativeCutoffReviewTrial)
    }
    let ledSupported: Bool
    let highPowerSupported: Bool
    // Writer construction/calls stay before arming cutoff or after CHIE0.
    // Periodic ownership/readback checks never enter this private connection.
    private var nativeWriter: BatteryNativeChargeClient? { try? BatteryNativeChargeClient() }
    private let nativeReadback: BatteryNativeReadTransport?
    let nativeReadInitializationFailure: String?
    private let domain = "com.apple.smartcharging.topoffprotection" as CFString
    private var lastLimitRead = -Double.infinity
    private var cachedRegistrations: Set<Int>?
    private var cachedRegistrationText: String?

    #if BATTERY_REVIEW || DEBUG
    func nativeReadDiagnostics() -> [BatteryNativeReadDiagnostic] {
        guard let nativeReadback else {
            return [.init(query: "transport", elapsed: 0, error: "原生只读辅助程序不可用。")]
        }
        return [BatteryNativeReadQuery.transport, .supported, .enabled, .limit,
                .supportedAsync, .enabledAsync, .limitAsync].map { nativeReadback.diagnose($0) }
    }
    #endif

    init() {
        let probe = try? BatterySMC()
        smc = probe
        var reader: BatteryNativeReadTransport?
        var nativeFailure: String?
        var nativeSupported = false
        do {
            reader = try BatteryNativeReadTransport()
            nativeSupported = try reader?.value(.supported) == 1
        } catch { nativeFailure = error.localizedDescription }
        nativeReadback = reader
        nativeReadInitializationFailure = nativeFailure
        func supports(_ key: String, _ size: Int) -> Bool { (try? probe?.read(key).bytes.count) == size }
#if arch(arm64)
        if supports("CHTE", 4) { mechanism = .modern }
        else if supports("CH0B", 1), supports("CH0C", 1) { mechanism = .legacy }
        else if nativeSupported { mechanism = .native }
        else { mechanism = nil }
        dischargeKey = supports("CHIE", 1) ? "CHIE" : supports("CH0J", 1) ? "CH0J" : supports("CH0I", 1) ? "CH0I" : nil
#else
        mechanism = supports("BCLM", 1) ? .intel : nil
        dischargeKey = nil
#endif
        preferencesBackend = mechanism == .native && !nativeCutoffReviewTrial ? try? BatteryPreferencesBackend() : nil
        ledSupported = !nativeCutoffReviewTrial && supports("ACLC", 1)
        highPowerSupported = !nativeCutoffReviewTrial && (try? Self.pmset(["-g", "custom"]))
            .flatMap(BatteryEnergyConfiguration.parse)?.highPowerSupported == true
            && (try? Self.pmset(["-g", "cap"]))
                .map(BatteryEnergyConfiguration.advertisesHighPower) == true
    }

    private static let nativeClientClass: AnyClass? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") else { return nil }
        let expected = ["initWithClientName:": "@24@0:8@16", "isMCLCurrentlyEnabled:": "Q24@0:8^@16", "enableMCL:": "B24@0:8^@16", "disableMCL:": "B24@0:8^@16"]
        guard expected.allSatisfy({ name, encoding in
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)), let actual = method_getTypeEncoding(method) else { return false }
            return String(cString: actual) == encoding
        }) else { return nil }
        return cls
    }()

    func read(_ key: String) throws -> Int {
        if key == "powerModeBattery" || key == "powerModeAC" {
            let config = BatteryEnergyConfiguration.parse(try Self.pmset(["-g", "custom"]))
            let mode = key == "powerModeBattery" ? config?.battery.mode : config?.adapter.mode
            guard let mode else { throw BatteryControlError.unavailable("能源模式字段缺失或相互矛盾，无法确认读回。") }
            return mode
        }
        if key == "nativeAPIEnabled" || key == "nativeAPILimit" {
            guard let nativeReadback else { throw BatteryControlError.unavailable("系统限充只读客户端不可用。") }
            return try nativeReadback.value(key == "nativeAPIEnabled" ? .enabled : .limit)
        }
        if key == "nativeEnabled" || key == "nativeLimit" {
            CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            let name = key == "nativeEnabled" ? "MCLFeatureState" : "mclLimitValue"
            return (CFPreferencesCopyValue(name as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.intValue ?? -1
        }
        if key == "lowPowerBattery" || key == "lowPowerAC" {
            let text = try Self.pmset(["-g", "custom"])
            let marker = key == "lowPowerBattery" ? "Battery Power:" : "AC Power:"
            var selected = false
            for line in text.components(separatedBy: .newlines) {
                if line.contains("Power:") { selected = line.contains(marker) }
                if selected, line.trimmingCharacters(in: .whitespaces).hasPrefix("lowpowermode"),
                   let n = Int(line.split(whereSeparator: \.isWhitespace).last ?? "") { return n }
            }
            throw BatteryControlError.unavailable("该电源配置不支持低功耗模式。")
        }
        let allowed = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "ACLC", "BCLM"]
        guard allowed.contains(key), let smc else { throw BatteryControlError.invalid("不允许的控制寄存器。") }
        let bytes = try smc.read(key).bytes
        if key == "CHTE", bytes.count == 4 { return Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24 }
        guard bytes.count == 1 else { throw BatteryControlError.unavailable("控制寄存器格式不支持。") }
        return Int(bytes[0])
    }

    func writePauseRefreshCHIE(_ value: Int) throws {
        #if BATTERY_REVIEW
        guard pauseRefreshTrial, preferencesBackend != nil, dischargeKey == "CHIE", let smc else {
            throw BatteryControlError.unavailable("本包未开放单次暂停切换。")
        }
        try smc.writePauseRefreshCHIE(value)
        #else
        throw BatteryControlError.unavailable("生产包没有暂停切换试验入口。")
        #endif
    }

    func write(_ key: String, _ value: Int) throws {
        if key == "powerModeBattery" || key == "powerModeAC" {
            guard highPowerSupported, (0...2).contains(value) else { throw BatteryControlError.invalid("高功率模式不可用或能源模式无效。") }
            _ = try Self.pmset([key == "powerModeBattery" ? "-b" : "-c", "powermode", String(value)])
            return
        }
        if key == "nativeAPIEnabled" || key == "nativeAPILimit" {
            guard let nativeWriter else { throw BatteryControlError.unavailable("系统限充客户端不可用。") }
            if key == "nativeAPIEnabled" { try nativeWriter.setEnabled(value) }
            else { try nativeWriter.setLimit(value) }
            lastLimitRead = -Double.infinity
            return
        }
        // Old preference keys remain only to recover pre-v3 durable journals.
        // New decisions never use this legacy mutation path.
        if key == "nativeEnabled" || key == "nativeLimit" {
            guard Self.nativeClientClass != nil,
                  key == "nativeEnabled" ? [-1, 0, 1].contains(value) : value == -1 || (20...100).contains(value) else {
                throw BatteryControlError.invalid("无效系统充电参数。")
            }
            if key == "nativeEnabled", value != 1 { try disableNativeLimit() }
            let name = key == "nativeEnabled" ? "MCLFeatureState" : "mclLimitValue"
            CFPreferencesSetValue(name as CFString, value == -1 ? nil : NSNumber(value: value), domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                throw BatteryControlError.recovery("系统充电偏好写入失败。")
            }
            typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post"),
                  unsafeBitCast(symbol, to: Post.self)("com.apple.smartcharging.defaultschanged") == 0 else {
                throw BatteryControlError.recovery("无法通知系统刷新充电上限。")
            }
            return
        }
        if key == "lowPowerBattery" || key == "lowPowerAC" {
            guard [0, 1].contains(value) else { throw BatteryControlError.invalid("无效能源模式。") }
            _ = try Self.pmset([key == "lowPowerBattery" ? "-b" : "-c", "lowpowermode", String(value)])
            return
        }
        let ranges: [String: ClosedRange<Int>] = ["CHTE": 0...1, "CH0B": 0...2, "CH0C": 0...2, "CHIE": 0...8, "CH0I": 0...1, "CH0J": 0...1, "ACLC": 0...4, "BCLM": 20...100]
        guard let range = ranges[key], range.contains(value), let smc else { throw BatteryControlError.invalid("无效控制参数。") }
        let bytes = key == "CHTE" ? [UInt8(value), 0, 0, 0] : [UInt8(value)]
        try smc.write(key, bytes: bytes)
    }

    func canRestore(_ key: String, value: Int) -> Bool {
        switch key {
        case "nativeAPIEnabled": return [0, 1].contains(value)
        case "nativeAPILimit": return (80...100).contains(value)
        case "nativeEnabled": return [-1, 0, 1].contains(value)
        case "nativeLimit": return value == -1 || (20...100).contains(value)
        case "CHTE", "CH0I", "CH0J", "lowPowerBattery", "lowPowerAC": return [0, 1].contains(value)
        case "CH0B", "CH0C": return [0, 2].contains(value)
        case "CHIE": return [0, 8].contains(value)
        case "ACLC": return (0...4).contains(value)
        case "BCLM": return (20...100).contains(value)
        case "powerModeBattery", "powerModeAC": return highPowerSupported && (0...2).contains(value)
        default: return false
        }
    }

    func targets(for decision: BatteryControlDecision, request: BatteryControlRequest, telemetry: BatteryTelemetry, ownedKeys: Set<String>, calibrating: Bool = false) throws -> [String: Int] {
        guard let mechanism else { throw BatteryControlError.unavailable("没有经过识别的充电控制机制。") }
        if nativeCutoffReviewTrial {
            try BatteryNativeCutoffTrial.validate(request, level: telemetry.level)
            guard mechanism == .native else {
                throw BatteryControlError.unavailable("固定复测不支持此设备控制路径。")
            }
            if !ownedKeys.contains("nativeAPILimit"), !(80...85).contains(try read("nativeAPILimit")) {
                throw BatteryControlError.unavailable("固定复测要求原系统上限处于80–85%。")
            }
            if !ownedKeys.contains("nativeAPIEnabled"), try read("nativeAPIEnabled") != 1 {
                throw BatteryControlError.unavailable("固定复测要求原系统限充已启用。")
            }
        }
        try capabilities.validate(request, currentLevel: telemetry.level)
        var result: [String: Int] = [:]
        switch mechanism {
        case .native:
            if preferencesBackend != nil {
                guard let level = telemetry.level, (0...100).contains(level) else { throw BatteryControlError.unavailable("电量未知，未提交偏好目标。") }
                let target = try BatteryPreferencesLease.plannedTarget(decision, currentLevel: level, calibrating: calibrating)
                result["preferencesTarget"] = target
            } else {
                result = try BatteryNativeDischargePlanner.targets(decision: decision, request: request, currentLevel: telemetry.level)
            }
        case .nativePreferences:
            throw BatteryControlError.invalid("偏好通道必须由核验的平台适配器选择。")
        case .modern: result["CHTE"] = decision.inhibit ? 1 : 0
        case .legacy: result["CH0B"] = decision.inhibit ? 2 : 0; result["CH0C"] = decision.inhibit ? 2 : 0
        case .intel:
            guard request.mode != .discharge, !request.preferences.sailing else {
                throw BatteryControlError.unavailable("Intel BCLM不支持主动放电或航海模式。")
            }
            result["BCLM"] = decision.inhibit ? max(20, telemetry.level ?? decision.target) : decision.target
        }
        if decision.forceDischarge && !dischargeSupported { throw BatteryControlError.unavailable("当前控制路径尚无经验证的主动放电恢复通道，未启动放电。") }
        result.merge(try BatteryCutoffTargets.make(key: dischargeKey,
            forceDischarge: decision.forceDischarge && mechanism != .native, ownedKeys: ownedKeys, read: read)) { _, cutoff in cutoff }
        if !nativeCutoffReviewTrial { // No LED or energy mutations in this fixed trial.
            result.merge(try BatteryEnergyTargets.make(preferences: request.preferences, highPowerSupported: highPowerSupported)) { _, energy in energy }
            if ledSupported, let value = request.preferences.led.controlValue(reachedLimit: (telemetry.level ?? 0) >= request.preferences.limit) {
                result["ACLC"] = value
            }
            if ledSupported, request.preferences.blinkWhileDischarging, decision.forceDischarge {
                result["ACLC"] = Int(ProcessInfo.processInfo.systemUptime / 5) % 2 == 0 ? 1 : 4
            }
        }
        for key in result.keys where key != "preferencesTarget" && !ownedKeys.contains(key) {
            guard canRestore(key, value: try read(key)) else {
                throw BatteryControlError.unavailable("\(key)的原始状态没有受支持的恢复路径；未开始写入。")
            }
        }
        return result
    }

    func adapterInputObservation() -> Bool? {
        guard let smc else { return nil }
        return BatteryAdapterInput.supplying(watts: BatteryAdapterInput.watts(read: smc.read))
    }

    func registeredLimit() -> Int? {
        let values = registeredLimits()
        return values?.count == 1 ? values?.first : nil
    }
    func registeredLimits(fresh: Bool = false) -> Set<Int>? {
        if fresh || ProcessInfo.processInfo.systemUptime - lastLimitRead > 15 {
            lastLimitRead = ProcessInfo.processInfo.systemUptime
            cachedRegistrationText = try? Self.pmset(["-g", "battlimit"])
            cachedRegistrations = cachedRegistrationText.flatMap(BatteryNativeRegistration.parse)
        }
        return cachedRegistrations
    }
    /// Shares the existing registration poll/cache; this adds no per-tick
    /// pmset process and keeps unknown output separate from a mismatch.
    func nativeDrainRegistered(target: Int) -> Bool? {
        guard mechanism == .native else { return nil }
        _ = registeredLimits()
        guard let text = cachedRegistrationText else { return nil }
        return BatteryNativeRegistration.manualDrainMatches(text, target: target)
    }
    func savedNativeLimit() -> Int? {
        if let preferencesBackend {
            guard let value = try? preferencesBackend.snapshot()[.mclLimitValue].flatMap({ $0.numeric }),
                  value.rounded() == value, (1...100).contains(value) else { return nil }
            return Int(value)
        }
        return try? nativeReadback?.value(.limit)
    }
    static func parseRegisteredLimit(_ text: String) -> Int? {
        let values = BatteryNativeRegistration.parse(text)
        return values?.count == 1 ? values?.first : nil
    }

    // Adapted from Ampere's MIT-licensed PowerUI bridge. See bundled notices.
    // This is private API: inspect method presence and fail closed on change.
    private func disableNativeLimit() throws {
        guard let nativeReadback, let nativeWriter else {
            throw BatteryControlError.recovery("系统充电恢复接口不可用。")
        }
        let state = try nativeReadback.value(.enabled)
        if state == 0 {
            try nativeWriter.setEnabled(1)
        }
        try nativeWriter.setEnabled(0)
    }

    static func pmset(_ arguments: [String]) throws -> String {
        if arguments.first == "-g" {
            guard arguments.count == 2, ["custom", "cap", "battlimit"].contains(arguments[1]) else {
                throw BatteryControlError.invalid("不允许的电源查询。")
            }
            let data = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/pmset"),
                arguments: arguments, timeout: 3)
            return String(decoding: data, as: UTF8.self)
        }
        let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            throw BatteryControlError.unavailable("系统电源命令超时。")
        }
        guard process.terminationStatus == 0 else { throw BatteryControlError.unavailable("系统拒绝电源命令。") }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
