import Foundation
import Darwin
import MachO

#if (BATTERY_HELPER && BATTERY_REVIEW) || DEBUG
/// Internal, fixed IO protocol. None of these keys, values or arguments are
/// accepted from an XPC client. The parent owns the durable write intent.
enum BatteryPreferences79IO {
    typealias Transaction = BatteryPreferences79Transaction
    typealias Key = Transaction.Key
    typealias Value = Transaction.Value
    static let argument = "--bm1-preferences79-io"
    private static let domain = "com.apple.smartcharging.topoffprotection" as CFString
    private static var retainedNativeClient: BatteryNativeAsyncReadClient?

    struct Write: Codable {
        var desired: Value
        var expected: Value
        var guards: [Key: Value]
        var bootID: String
        var expiresContinuous: TimeInterval
        var controlDeadline: TimeInterval
        var restoring: Bool
    }
    struct Signal: Codable {
        var expected: [Key: Value]
        var guards: [Key: Value]
        var bootID: String
        var expiresContinuous: TimeInterval
        var controlDeadline: TimeInterval
        var restoring: Bool
    }
    struct Reply: Codable {
        var schema = 1
        var value: Value?
        var observation: Transaction.Observation?
        var updateTime: Date?
        var error: String?
    }
    static var continuousNow: TimeInterval {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return .nan }
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    static func sysctlString(_ name: String) throws -> String {
        var bytes = [CChar](repeating: 0, count: 128), count = bytes.count
        guard sysctlbyname(name, &bytes, &count, nil, 0) == 0, count > 1, count <= bytes.count else { throw failure("系统身份读取未知。") }
        return String(cString: bytes)
    }
    static func bootID() throws -> String {
        guard let id = UUID(uuidString: try sysctlString("kern.bootsessionuuid")) else { throw failure("系统启动身份未知。") }
        return id.uuidString
    }
    static func validatePlatform() throws {
        #if arch(arm64)
        guard try sysctlString("hw.model") == "Mac17,2", try sysctlString("kern.osversion") == "26A434",
              dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil else {
            throw failure("79试验仅核验当前Mac与系统映像，未开放此平台。")
        }
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index),
                  String(cString: name) == "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI",
                  let header = _dyld_get_image_header(index) else { continue }
            let base = UnsafeRawPointer(header), h = base.assumingMemoryBound(to: mach_header_64.self).pointee
            guard h.magic == MH_MAGIC_64, h.cputype == CPU_TYPE_ARM64,
                  h.cpusubtype & 0x00ff_ffff == CPU_SUBTYPE_ARM64E,
                  h.ncmds < 4096, h.sizeofcmds < 1_048_576 else { break }
            var offset = MemoryLayout<mach_header_64>.size
            let end = offset + Int(h.sizeofcmds)
            for _ in 0..<h.ncmds {
                guard offset + MemoryLayout<load_command>.size <= end else { break }
                let command = base.advanced(by: offset).assumingMemoryBound(to: load_command.self).pointee
                guard command.cmdsize >= MemoryLayout<load_command>.size, offset + Int(command.cmdsize) <= end else { break }
                if command.cmd == LC_UUID, command.cmdsize == MemoryLayout<uuid_command>.size {
                    let id = base.advanced(by: offset).assumingMemoryBound(to: uuid_command.self).pointee.uuid
                    guard UUID(uuid: id).uuidString == "05E1F9B3-62E9-34DD-B111-6A3DEF44FDAC" else { break }
                    return
                }
                offset += Int(command.cmdsize)
            }
        }
        #endif
        throw failure("PowerUI映像身份不匹配，未写入。")
    }
    private static func read(_ key: Key) throws -> Value {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw failure("试验偏好读取同步未确认。") }
        return try Value.fromFoundation(CFPreferencesCopyValue(key.rawValue as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
    }
    static func handoffValues() throws -> [Key: Value] {
        guard getuid() == 0, geteuid() == 0 else { throw failure("交接快照仅可由root辅助程序读取。") }
        return try Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0, try read($0)) })
    }
    static func observedPreferenceLimit(_ value: Value) -> Int? {
        guard let n = value.numeric, n.isFinite, n.rounded(.towardZero) == n,
              (20...100).contains(n) else { return nil }
        return Int(n)
    }
    static func observedPreferenceEnabled(_ value: Value) -> Int? {
        if value == .bool(true) { return 1 }
        if value == .bool(false) { return 0 }
        guard let n = value.numeric, n == 0 || n == 1 else { return nil }
        return Int(n)
    }
    private static func guardsMatch(_ expected: [Key: Value]) throws {
        let keys: [Key] = [.initialChargeLimitSetDate, .disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC]
        guard Set(expected.keys) == Set(keys) else { throw failure("试验守卫快照不完整。") }
        for key in keys { guard try read(key) == expected[key] else { throw failure("系统临时覆盖或首次日期已变化，未覆盖。") } }
    }
    private static func pureGuards() throws -> [Key: Value] {
        let first = try read(.initialChargeLimitSetDate)
        guard let date = try first.foundationValue() as? NSNumber,
              CFGetTypeID(date) != CFBooleanGetTypeID(), date.doubleValue.isFinite else {
            throw failure("首次限充日期尚未存在或不是有限数值；未调用可能有副作用的查询。")
        }
        var result: [Key: Value] = [.initialChargeLimitSetDate: first]
        for key in [Key.disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC, .mclTempDisabledUntilDate] {
            let value = try read(key)
            guard value == .absent else { throw failure("存在系统临时覆盖（包括已过期值），未调用会清理覆盖的原生查询。") }
            result[key] = value
        }
        return result
    }
    private static func admit(boot: String, expiry: TimeInterval, deadline: TimeInterval, restoring: Bool) throws {
        let now = continuousNow
        guard now.isFinite, expiry.isFinite, deadline.isFinite, try bootID() == boot,
              expiry >= now, expiry - now <= 3, restoring || now < deadline else { throw failure("试验请求已过期或系统已重启，未提交新写入。") }
        let observation = try observe().0
        guard !observation.competingController, !observation.calibrationActive,
              observation.level.isFinite, (0...100).contains(observation.level),
              observation.batteryCurrent.isFinite, observation.adapterPower.isFinite else { throw failure("执行前设备或控制所有权未知。") }
        if !restoring {
            guard observation.level > 79, observation.level <= 85, observation.adapterPresent,
                  observation.adapterPower > 1, observation.nativeEnabled == 1,
                  observation.nativeLimit.map({ [79, 80].contains($0) }) == true else { throw failure("执行前离开固定79试验范围，未继续写入。") }
        }
        // The repeated check narrows, but cannot eliminate, external TOCTOU.
        guard continuousNow <= expiry, restoring || continuousNow < deadline else { throw failure("执行前试验期限已到。") }
    }
    static func observe(admissionOnly: Bool = false) throws -> (Transaction.Observation, Date?) {
        // Private enabled/getMCL getters can clear expired temporary overrides.
        // Pure preferences and physical connection therefore come first. No
        // private getter is called while disconnected; unknown stays nil.
        let before = try pureGuards()
        let savedLimit = try read(.mclLimitValue), savedEnabled = try read(.mclFeatureState)
        let telemetry = BatteryTelemetry.read()
        let smc = try BatterySMC()
        guard telemetry.hasBattery, let level = telemetry.level,
              let ac = telemetry.powerSupplyObservation, let current = telemetry.current,
              let watts = BatteryAdapterInput.watts(read: smc.read), watts.isFinite, watts >= 0 else { throw failure("物理电量、电流或输入功率缺失。") }
        guard let calibration = BatterySystemCalibration.observation else { throw failure("系统校准状态未知。") }
        let competitor = try competingController()
        guard !competitor, !calibration else { throw failure("其他控制器或系统校准活动，未调用原生查询。") }
        var enabled: Int?, limit: Int?
        if !admissionOnly && ac && watts > 1 {
            if retainedNativeClient == nil { retainedNativeClient = try BatteryNativeAsyncReadClient() }
            guard let client = retainedNativeClient, try client.value(.supported) == 1 else { throw failure("原生能力未知。") }
            enabled = try client.value(.enabled); limit = try client.preferences79Limit()
        }
        guard try pureGuards() == before, try read(.mclLimitValue) == savedLimit,
              try read(.mclFeatureState) == savedEnabled,
              BatteryTelemetry.read().powerSupplyObservation == ac else {
            throw failure("查询期间供电或覆盖状态变化，结果保持未知。")
        }
        let data = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["-g", "battlimit"], timeout: 1)
        guard let registrations = BatteryNativeRegistration.parse(String(decoding: data, as: UTF8.self)) else { throw failure("全部系统登记读取未知。") }
        return (.init(nativeLimit: limit, nativeEnabled: enabled, registrations: registrations.sorted(), level: Double(level),
                      adapterPresent: ac, batteryCurrent: current, adapterPower: watts, wallDate: Date(),
                      competingController: competitor, calibrationActive: calibration,
                      rawPreferenceLimit: observedPreferenceLimit(savedLimit),
                      rawPreferenceEnabled: observedPreferenceEnabled(savedEnabled)), telemetry.reportedPower?.batteryUpdateTimeContext)
    }
    private static func competingController() throws -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 65_000 else { throw failure("控制进程清单未知。") }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let read = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard read > 0, read < ids.count else { throw failure("控制进程清单未完整读取。") }
        let names: Set<String> = ["AlDente", "BatFi", "Battery Toolkit", "Ampere"]
        for pid in ids.prefix(Int(read)) where pid > 1 {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
               names.contains(URL(fileURLWithPath: String(cString: path)).lastPathComponent) { return true }
        }
        return false
    }
    static func validateDesired(_ value: Value, for key: Key, restoring: Bool) throws {
        let object = try value.foundationValue()
        switch key {
        case .mclLimitValue:
            guard let n = object as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue == (restoring ? 80 : 79) else { throw failure("试验只可写79或恢复80。") }
        case .isEngaged, .isManuallyChargeLimited:
            if restoring && value == .absent { return }
            fallthrough
        case .mclFeatureState:
            guard let n = object as? NSNumber, n.doubleValue == 1 else { throw failure("试验开关只可恢复/保持已启用值。") }
        case .mclTempDisabledUntilDate:
            guard object == nil else { throw failure("试验只允许保持缺失的临时停充覆盖。") }
        case .checkpoint, .currentState: break
        default: throw failure("守卫和系统运行状态不可由试验写入。")
        }
    }
    static func validateSignal(_ expected: [Key: Value], restoring: Bool) throws {
        guard Set(expected.keys) == Set([Key.mclLimitValue, .mclFeatureState, .isEngaged, .isManuallyChargeLimited]) else {
            throw failure("刷新通知缺少本次固定目标或完整强控制快照。")
        }
        for (key, value) in expected { try validateDesired(value, for: key, restoring: restoring) }
    }
    #if BATTERY_HELPER
    static func run(arguments: [String]) -> Never {
        guard getuid() == 0, geteuid() == 0, arguments.count >= 3, arguments[1] == argument,
              getppid() > 1, let own = try? BatteryReadWorkerExecutable.kernelCDHash(pid: getpid()),
              let parent = try? BatteryReadWorkerExecutable.kernelCDHash(pid: getppid()), own == parent else { Darwin._exit(77) }
        do {
            try validatePlatform()
            let operation = arguments[2]
            if ["observe", "observe-admission"].contains(operation), arguments.count == 3 {
                let (observation, updated) = try observe(admissionOnly: operation == "observe-admission")
                emit(.init(observation: observation, updateTime: updated))
            }
            guard arguments.count == 4 || arguments.count == 5 else { throw failure("固定IO参数无效。") }
            if operation == "signal", arguments.count == 4 {
                let request: Signal = try decode(arguments[3])
                try validateSignal(request.expected, restoring: request.restoring)
                try admit(boot: request.bootID, expiry: request.expiresContinuous, deadline: request.controlDeadline, restoring: request.restoring)
                try guardsMatch(request.guards)
                for (key, value) in request.expected { guard try read(key) == value else { throw failure("通知前强控制值变化。") } }
                typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
                guard continuousNow <= request.expiresContinuous, request.restoring || continuousNow < request.controlDeadline,
                      let post = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post"),
                      unsafeBitCast(post, to: Post.self)("com.apple.smartcharging.defaultschanged") == 0 else { throw failure("系统刷新通知未确认。") }
                emit(.init())
            }
            guard let key = Key(rawValue: arguments[3]) else { throw failure("固定偏好键无效。") }
            if operation == "get", arguments.count == 4 { emit(.init(value: try read(key))) }
            guard operation == "set", arguments.count == 5 else { throw failure("固定IO操作无效。") }
            let request: Write = try decode(arguments[4])
            try validateDesired(request.desired, for: key, restoring: request.restoring)
            try admit(boot: request.bootID, expiry: request.expiresContinuous, deadline: request.controlDeadline, restoring: request.restoring)
            try guardsMatch(request.guards)
            guard try read(key) == request.expected, continuousNow <= request.expiresContinuous,
                  request.restoring || continuousNow < request.controlDeadline else { throw failure("写入前值已变化或请求过期。") }
            CFPreferencesSetValue(key.rawValue as CFString, try request.desired.foundationValue() as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost), try read(key) == request.desired else { throw failure("写入/同步/读回未确认。") }
            emit(.init())
        } catch { emit(.init(error: String(error.localizedDescription.prefix(512)))) }
    }
    private static func emit(_ reply: Reply) -> Never {
        guard let data = try? JSONEncoder().encode(reply), data.count < 32_768 else { Darwin._exit(70) }
        do { try FileHandle.standardOutput.write(contentsOf: data); Darwin._exit(reply.error == nil ? 0 : 70) }
        catch { Darwin._exit(70) }
    }
    #endif
    static func decode<T: Decodable>(_ string: String) throws -> T {
        guard string.utf8.count < 32_768, let data = Data(base64Encoded: string), data.count < 24_576 else { throw failure("固定IO负载超限或无效。") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count < 24_576 else { throw failure("固定IO负载超限。") }
        return data.base64EncodedString()
    }
    static func failure(_ message: String) -> BatteryControlError { .recovery(message) }
}
#endif
