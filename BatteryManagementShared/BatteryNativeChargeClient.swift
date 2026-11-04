import Foundation
import ObjectiveC
import Darwin

#if BATTERY_HELPER || DEBUG
enum BatteryNativeReadQuery: String, CaseIterable {
    case supported, enabled, limit, transport, supportedAsync, enabledAsync, limitAsync, fixedSMC
    var baseQuery: Self {
        switch self {
        case .supportedAsync: return .supported
        case .enabledAsync: return .enabled
        case .limitAsync: return .limit
        default: return self
        }
    }
    var asynchronousQuery: Self {
        switch self {
        case .supported: return .supportedAsync
        case .enabled: return .enabledAsync
        case .limit: return .limitAsync
        default: return self
        }
    }
    func accepts(_ value: Int) -> Bool {
        if self == .transport || self == .fixedSMC { return value == 1 }
        return baseQuery == .limit ? (80...100).contains(value) : (0...1).contains(value)
    }
}

/// Fresh, bounded readbacks, separate from the daemon's potentially stale
/// private-framework connection. No setters exist in this worker protocol.
struct BatteryNativeReadTransport {
    let executable: URL
    init(executable: URL? = Bundle.main.executableURL) throws {
        guard let executable, executable.isFileURL,
              executable.lastPathComponent == "BatteryManagementHelper",
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BatteryControlError.unavailable("原生只读辅助程序路径无效。")
        }
        let resolved = executable.resolvingSymlinksInPath()
        if getuid() == 0 || geteuid() == 0 {
            // App bundles are user writable. Never execute that mutable path
            // as root, even when the code running now came from the same URL.
            self.executable = try BatteryReadWorkerExecutable.securedCopyOfCurrentHelper(source: resolved)
        } else { self.executable = resolved }
    }
    func value(_ query: BatteryNativeReadQuery) throws -> Int {
        guard [.supported, .enabled, .limit].contains(query.baseQuery) else {
            throw BatteryControlError.invalid("控制读回仅接受三项原生限充查询。")
        }
        do {
            let data = try BatteryNativeReadProcess.run(executable: executable,
                arguments: ["--bm1-native-read", query.asynchronousQuery.rawValue])
            return try Self.decode(data, query: query)
        } catch {
            throw BatteryControlError.unavailable("只读查询\(query.rawValue)：\(error.localizedDescription)")
        }
    }
    #if BATTERY_REVIEW || DEBUG
    func diagnose(_ query: BatteryNativeReadQuery) -> BatteryNativeReadDiagnostic {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let data = try BatteryNativeReadProcess.run(executable: executable,
                arguments: ["--bm1-native-read", query.rawValue])
            let value = try Self.decode(data, query: query)
            let reply = data.split(separator: 0x0a).last.flatMap {
                try? JSONDecoder().decode(BatteryNativeReadReply.self, from: Data($0))
            }
            return .init(query: query.rawValue, value: value, workerPID: reply?.pid,
                         elapsed: ProcessInfo.processInfo.systemUptime - started,
                         phase: BatteryNativeReadProcess.lastPhase(data))
        } catch {
            return .init(query: query.rawValue, elapsed: ProcessInfo.processInfo.systemUptime - started,
                         error: error.localizedDescription)
        }
    }
    func fixedSMCReadDiagnostics() throws -> String {
        let data = try BatteryNativeReadProcess.run(executable: executable,
            arguments: ["--bm1-native-read", BatteryNativeReadQuery.fixedSMC.rawValue])
        _ = try Self.decode(data, query: .fixedSMC)
        guard let line = data.split(separator: 0x0a).last,
              let reply = try? JSONDecoder().decode(BatteryNativeReadReply.self, from: Data(line)),
              let text = reply.diagnostics else {
            throw BatteryControlError.unavailable("固定SMC只读矩阵未返回。")
        }
        try BatteryFixedSMCReadDiagnostics.validate(text, workerPID: reply.pid)
        return text
    }
    #endif
    static func decode(_ data: Data, query: BatteryNativeReadQuery) throws -> Int {
        let lines = data.split(separator: 0x0a)
        guard data.count <= 4096, !lines.isEmpty, lines.count <= 4 else {
            throw BatteryControlError.unavailable("系统限充只读结果无效；未用未知值继续控制。")
        }
        var final: Int?
        for (index, line) in lines.enumerated() {
            guard let reply = try? JSONDecoder().decode(BatteryNativeReadReply.self, from: Data(line)),
                  reply.schema == 1, reply.error == nil else {
                throw BatteryControlError.unavailable("系统限充只读结果无效；未用未知值继续控制。")
            }
            if let value = reply.value, reply.phase == nil || reply.phase == "reply",
               index == lines.count - 1, query.accepts(value) { final = value }
            else if reply.value == nil, let phase = reply.phase,
                    ["initializing", "querying", "query-returned"].contains(phase), index < lines.count - 1 { continue }
            else { throw BatteryControlError.unavailable("系统限充只读阶段或结果无效。") }
        }
        guard let value = final else { throw BatteryControlError.unavailable("系统限充只读结果缺失。") }
        return value
    }
}

#if BATTERY_HELPER
enum BatteryNativeReadWorker {
    static func run(arguments: [String]) -> Int32 {
        // Runs before daemon construction: no journal, lease, listener or
        // recursive worker. Native queries create no SMC; fixedSMC only reads
        // its declared diagnostic matrix. A normal user cannot invoke this.
        guard getuid() == 0, geteuid() == 0, let executable = Bundle.main.executableURL,
              executable.lastPathComponent == "BatteryManagementHelper" else { return 77 }
        let parentPID = getppid()
        guard parentPID > 1,
              let ownHash = try? BatteryReadWorkerExecutable.kernelCDHash(pid: getpid()),
              let parentHash = try? BatteryReadWorkerExecutable.kernelCDHash(pid: parentPID),
              ownHash == parentHash else { return 77 }
        guard arguments.count == 3, arguments[1] == "--bm1-native-read",
              let query = BatteryNativeReadQuery(rawValue: arguments[2]) else { return 64 }
        func report(_ phase: String) {
            guard let data = try? JSONEncoder().encode(BatteryNativeReadReply(phase: phase)) else { return }
            FileHandle.standardOutput.write(data + Data([0x0a]))
        }
        if query == .transport {
            guard let data = try? JSONEncoder().encode(BatteryNativeReadReply(value: 1, phase: "reply", pid: getpid())) else { return 70 }
            FileHandle.standardOutput.write(data)
            return 0 // No private framework/client was created.
        }
        #if BATTERY_REVIEW || DEBUG
        if query == .fixedSMC {
            do {
                report("initializing")
                let smc = try BatterySMC()
                withExtendedLifetime(smc) {
                    do {
                        report("querying")
                        let text = try smc.fixedReadDiagnosticJSON()
                        report("query-returned")
                        emitAndExit(.init(value: 1, phase: "reply", pid: getpid(), diagnostics: text))
                    } catch { emitAndExit(.init(error: error.localizedDescription, pid: getpid())) }
                }
            } catch { emitAndExit(.init(error: error.localizedDescription, pid: getpid())) }
        }
        #endif
        if query != query.baseQuery {
            // Only this read-only child uses immediate process exit. Its
            // successful result must not wait on private-client ARC teardown.
            // Setters, journals and hardware control never run in this branch.
            do {
                report("initializing")
                let client = try BatteryNativeAsyncReadClient()
                withExtendedLifetime(client) {
                    do {
                        report("querying")
                        let value = try client.value(query.baseQuery)
                        report("query-returned")
                        emitAndExit(.init(value: value, phase: "reply", pid: getpid()))
                    } catch {
                        emitAndExit(.init(error: error.localizedDescription, pid: getpid()))
                    }
                }
            } catch { emitAndExit(.init(error: error.localizedDescription, pid: getpid())) }
        }
        #if BATTERY_REVIEW || DEBUG
        let reply: BatteryNativeReadReply
        do {
            report("initializing")
            let client = try BatteryNativeChargeClient()
            report("querying")
            let value: Int
            switch query {
            case .supported: value = 1 // init has already confirmed support.
            case .enabled: value = try client.enabled()
            case .limit: value = try client.limit()
            case .transport, .fixedSMC: return 64 // Handled before client construction.
            case .supportedAsync, .enabledAsync, .limitAsync: return 64 // Async path is handled separately.
            }
            // Mark getter completion before releasing the private client. A
            // later stall is cleanup/exit, not necessarily a getter stall.
            withExtendedLifetime(client) { report("query-returned") }
            reply = .init(value: value, phase: "reply", pid: getpid())
        } catch { reply = .init(error: "系统限充只读接口不可用。") }
        guard let data = try? JSONEncoder().encode(reply), data.count <= 4096 else { return 70 }
        FileHandle.standardOutput.write(data)
        return reply.error == nil ? 0 : 70
        #else
        return 64 // Legacy synchronous probes are never a production read path.
        #endif
    }
    private static func emitAndExit(_ reply: BatteryNativeReadReply) -> Never {
        guard let data = try? JSONEncoder().encode(reply), data.count <= 4096 else { Darwin._exit(70) }
        FileHandle.standardOutput.write(data) // Direct fd write, no stdio buffer.
        Darwin._exit(reply.error == nil ? 0 : 70)
    }
}
#endif
#endif

/// A narrow, ABI-checked bridge to the device's manual-charge-limit service.
/// Queries are safe in the application; mutations exist only in the helper.
#if BATTERY_HELPER || DEBUG
final class BatteryNativeChargeClient {
    private let object: AnyObject
    private let dispatch: UnsafeMutableRawPointer
    private typealias ErrorPointer = UnsafeMutablePointer<Unmanaged<NSError>?>

    init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let dispatch = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            throw BatteryControlError.unavailable("系统限充客户端不可用。")
        }
        let shapes = [
            "initWithClientName:": "@24@0:8@16", "isMCLSupported": "B16@0:8",
            "isMCLCurrentlyEnabled:": "Q24@0:8^@16", "getMCLLimitWithError:": "C24@0:8^@16",
            "enableMCL:": "B24@0:8^@16",
            "disableMCL:": "B24@0:8^@16", "setMCLLimit:error:": "B28@0:8C16^@20"
        ]
        guard shapes.allSatisfy({ name, shape in
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)), let actual = method_getTypeEncoding(method) else { return false }
            return String(cString: actual) == shape
        }) else { throw BatteryControlError.unavailable("系统限充接口版本不兼容，未发起控制。") }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let allocated = unsafeBitCast(dispatch, to: Alloc.self)(cls, NSSelectorFromString("alloc"))
        guard let initialized = unsafeBitCast(dispatch, to: Init.self)(allocated.takeUnretainedValue(), NSSelectorFromString("initWithClientName:"), "SuperIsland.Battery") else {
            // Objective-C init consumes alloc's ownership even when it returns nil.
            throw BatteryControlError.unavailable("系统限充客户端无法初始化。")
        }
        self.object = initialized.takeRetainedValue(); self.dispatch = dispatch
        typealias Supported = @convention(c) (AnyObject, Selector) -> Bool
        guard unsafeBitCast(dispatch, to: Supported.self)(object, NSSelectorFromString("isMCLSupported")) else {
            throw BatteryControlError.unavailable("当前设备不支持原生限充。")
        }
    }

    func enabled() throws -> Int {
        let value = try wideQuery("isMCLCurrentlyEnabled:")
        guard value <= 1 else { throw BatteryControlError.unavailable("系统限充开关状态未知。") }
        return Int(value)
    }
    // Manual MCL preference, not currentChargeLimit: (the separate optimized
    // charging threshold). Enforced behavior still needs powerd + telemetry.
    func limit() throws -> Int {
        typealias Query = @convention(c) (AnyObject, Selector, ErrorPointer) -> UInt8
        var error: Unmanaged<NSError>?
        let value = Int(unsafeBitCast(dispatch, to: Query.self)(object, NSSelectorFromString("getMCLLimitWithError:"), &error))
        guard error == nil, (80...100).contains(value) else {
            throw BatteryControlError.unavailable("无法确认系统原生限充目标，未开始覆盖。")
        }
        return value
    }
    private func wideQuery(_ name: String) throws -> UInt64 {
        typealias Query = @convention(c) (AnyObject, Selector, ErrorPointer) -> UInt64
        var error: Unmanaged<NSError>?
        let value = unsafeBitCast(dispatch, to: Query.self)(object, NSSelectorFromString(name), &error)
        guard error == nil else { throw BatteryControlError.unavailable("系统限充状态查询失败。") }
        return value
    }

#if BATTERY_HELPER
    func setEnabled(_ value: Int) throws {
        guard value == 0 || value == 1 else { throw BatteryControlError.invalid("无效系统限充开关。") }
        typealias Mutation = @convention(c) (AnyObject, Selector, ErrorPointer) -> Bool
        var error: Unmanaged<NSError>?
        let ok = unsafeBitCast(dispatch, to: Mutation.self)(object, NSSelectorFromString(value == 1 ? "enableMCL:" : "disableMCL:"), &error)
        guard ok, error == nil else { throw BatteryControlError.recovery("系统拒绝修改限充开关。") }
    }
    func setLimit(_ value: Int) throws {
        guard (80...100).contains(value) else { throw BatteryControlError.invalid("原生限充仅支持80–100%。") }
        typealias Mutation = @convention(c) (AnyObject, Selector, UInt8, ErrorPointer) -> Bool
        var error: Unmanaged<NSError>?
        let ok = unsafeBitCast(dispatch, to: Mutation.self)(object, NSSelectorFromString("setMCLLimit:error:"), UInt8(value), &error)
        guard ok, error == nil else { throw BatteryControlError.recovery("系统拒绝修改限充目标。") }
    }
#endif
}

#endif
