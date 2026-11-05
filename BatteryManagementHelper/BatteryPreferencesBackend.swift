import Foundation
import Darwin
import MachO

/// Fixed privileged transport for the typed production lease. It accepts no
/// client-supplied domain, key, path or raw value through XPC.
final class BatteryPreferencesBackend {
    typealias Transaction = BatteryPreferencesLease
    typealias Key = Transaction.Key
    typealias Value = Transaction.Value
    typealias Snapshot = Transaction.Snapshot
    static let argument = "--bm1-preferences-lease-io"
    private static let domain = "com.apple.smartcharging.topoffprotection" as CFString
    struct Request: Codable {
        var operation: String
        var key: Key?
        var desired: Value?
        var expected: Snapshot = [:]
        var guards: Snapshot = [:]
        var restoring = false
        var bootID: String
        var expiry: TimeInterval
        var leaseExpiry: TimeInterval
    }
    struct Reply: Codable {
        var snapshot: Snapshot?
        var error: String?
    }
    private let profile: BatteryPreferencesPlatform.Profile
    var requiresExplicitMCLBaseline: Bool { profile.requiresExplicitMCLBaseline }
    init() throws { profile = try Self.validatePlatform() }
    static func systemString(_ name: String) throws -> String {
        var bytes = [CChar](repeating: 0, count: 128), count = bytes.count
        guard sysctlbyname(name, &bytes, &count, nil, 0) == 0, count > 1, count <= bytes.count else { throw failure() }
        return String(cString: bytes)
    }
    static func validatePlatform() throws -> BatteryPreferencesPlatform.Profile {
        #if arch(arm64)
        let model = try systemString("hw.model"), osBuild = try systemString("kern.osversion")
        guard model == "Mac17,2",
              dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil else { throw failure() }
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
                    if let profile = BatteryPreferencesPlatform.profile(model: model, osBuild: osBuild, frameworkUUID: UUID(uuid: id).uuidString) { return profile }
                    break
                }
                offset += Int(command.cmdsize)
            }
        }
        #endif
        throw failure()
    }
    func snapshot() throws -> Snapshot {
        let response = try call(.init(operation: "snapshot", bootID: try Self.systemString("kern.bootsessionuuid"),
            expiry: ProcessInfo.processInfo.systemUptime + 3, leaseExpiry: 0))
        guard let snapshot = response.snapshot, Set(snapshot.keys) == Set(Key.allCases) else { throw Self.failure() }
        return snapshot
    }
    func io(expiry: @escaping () -> TimeInterval) -> Transaction.IO {
        .init(snapshot: snapshot, write: { key, desired, expected, guards, restoring in
            _ = try self.call(.init(operation: "write", key: key, desired: desired, expected: [key: expected], guards: guards,
                restoring: restoring, bootID: try Self.systemString("kern.bootsessionuuid"),
                expiry: ProcessInfo.processInfo.systemUptime + 3, leaseExpiry: expiry()))
        }, signal: { expected, guards, restoring in
            _ = try self.call(.init(operation: "signal", expected: expected, guards: guards, restoring: restoring,
                bootID: try Self.systemString("kern.bootsessionuuid"), expiry: ProcessInfo.processInfo.systemUptime + 3, leaseExpiry: expiry()))
        }, requiresExplicitMCLBaseline: requiresExplicitMCLBaseline)
    }
    private func call(_ request: Request) throws -> Reply {
        try Self.fence()
        guard let source = Bundle.main.executableURL else { throw Self.failure() }
        let worker = try BatteryReadWorkerExecutable.securedCopyOfCurrentHelper(source: source)
        let payload = try JSONEncoder().encode(request)
        guard payload.count < 131_072 else { throw Self.failure() }
        let data = try BatteryNativeReadProcess.run(executable: worker,
            arguments: [Self.argument, payload.base64EncodedString()], timeout: 3, maximumOutput: 65_536)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if let error = reply.error { throw BatteryControlError.recovery(error) }
        return reply
    }
    /// No replacement worker may observe, mutate or restore until every older
    /// helper worker has exited, including orphaned workers after daemon restart.
    private static func fence() throws {
        guard getuid() == 0, geteuid() == 0 else {
            throw BatteryControlError.recovery("电池偏好进程隔离检查：后台root身份未确认。")
        }
        guard BatteryNativeReadProcess.DeferredReaper.shared.reapNow() else {
            throw BatteryControlError.recovery("电池偏好进程隔离检查：旧子进程退出尚未确认。")
        }
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 65_000 else {
            throw BatteryControlError.recovery("电池偏好进程隔离检查：进程清单大小未知。")
        }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let read = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard read > 0, read < ids.count else {
            throw BatteryControlError.recovery("电池偏好进程隔离检查：进程清单读取不完整。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        for pid in ids.prefix(Int(read)) where pid > 1 && pid != getpid() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw BatteryControlError.recovery("电池偏好进程隔离检查超时；未开始新的写入。")
            }
            let result = BatteryHandoffProcessIdentity.resolvePath(observe: {
                BatteryHandoffProcessIdentity.observePath(pid: pid)
            })
            let path: String
            switch result {
            case .exited, .unrelatedSigned: continue
            case .path(let value): path = value
            case .unresolved(let detail):
                throw BatteryControlError.recovery("电池偏好进程隔离检查：PID=\(pid)身份未确认（\(detail)）。")
            }
            guard URL(fileURLWithPath: path).lastPathComponent != "BatteryManagementHelper",
                  !path.contains("/com.workview.SuperIsland.BatteryManagementHelper/read-workers/") else {
                throw BatteryControlError.recovery("电池偏好进程隔离检查：仍有其他电池辅助程序或旧worker（PID=\(pid)）。")
            }
        }
    }
    private static func rawSnapshot() throws -> Snapshot {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw failure() }
        return try Dictionary(uniqueKeysWithValues: Key.allCases.map { key in
            (key, try Value.fromFoundation(CFPreferencesCopyValue(key.rawValue as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)))
        })
    }
    private static func validateClock(_ request: Request) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard request.expiry.isFinite, request.leaseExpiry.isFinite, now <= request.expiry, request.expiry - now <= 3,
              request.restoring || now < request.leaseExpiry,
              try systemString("kern.bootsessionuuid") == request.bootID else { throw failure() }
    }
    private static func mutationAdmission(_ request: Request, snapshot: Snapshot) throws {
        try validateClock(request)
        guard Set(request.guards.keys) == Set(Key.guards),
              request.guards.allSatisfy({ snapshot[$0.key] == $0.value }),
              snapshot[.initialChargeLimitSetDate]?.numeric != nil,
              [Key.disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC, .mclTempDisabledUntilDate].allSatisfy({ snapshot[$0] == .absent }),
              BatterySystemCalibration.observation == false else { throw failure() }
        try validateNoCompetingController()
        try validateClock(request)
    }
    static func validateNoCompetingController() throws {
        // Mirrors the established process identity guard; an unreadable unrelated
        // executable path is not evidence that a battery controller is running.
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 65_000 else { throw failure() }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let read = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard read > 0, read < ids.count else { throw failure() }
        for pid in ids.prefix(Int(read)) where pid > 1 {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
               ["AlDente", "BatFi", "Battery Toolkit", "Ampere"].contains(URL(fileURLWithPath: String(cString: path)).lastPathComponent) {
                throw BatteryControlError.conflict("其他电池控制器运行中，未写入系统偏好。")
            }
        }
    }
    static func run(arguments: [String]) -> Never {
        guard getuid() == 0, geteuid() == 0, arguments.count == 3, arguments[1] == argument,
              getppid() > 1, let own = try? BatteryReadWorkerExecutable.kernelCDHash(pid: getpid()),
              let parent = try? BatteryReadWorkerExecutable.kernelCDHash(pid: getppid()), own == parent else { Darwin._exit(77) }
        do {
            _ = try validatePlatform()
            guard arguments[2].utf8.count < 180_000, let data = Data(base64Encoded: arguments[2]), data.count < 131_072 else { throw failure() }
            let request = try JSONDecoder().decode(Request.self, from: data)
            if request.operation == "snapshot" { emit(.init(snapshot: try rawSnapshot())) }
            let snapshot = try rawSnapshot(); try mutationAdmission(request, snapshot: snapshot)
            if request.operation == "write", let key = request.key, let desired = request.desired {
                guard Key.direct.contains(key), request.expected.count == 1, request.expected[key] == snapshot[key] else { throw failure() }
                try Transaction.validate(desired, key: key)
                if !request.restoring {
                    if key == .mclLimitValue { guard desired.numeric.map({ (1...100).contains($0) }) == true else { throw failure() } }
                    else if [.mclFeatureState, .isEngaged, .isManuallyChargeLimited].contains(key) {
                        guard Transaction.enabled(desired) == true else { throw failure() }
                    } else { guard desired == .absent else { throw failure() } }
                }
                // Read again immediately before mutation. This narrows the external
                // race; CFPreferences does not provide atomic compare-and-swap.
                let before = try rawSnapshot()
                guard request.guards.allSatisfy({ before[$0.key] == $0.value }), before[key] == request.expected[key] else { throw failure() }
                try validateClock(request)
                CFPreferencesSetValue(key.rawValue as CFString, try desired.foundationValue() as CFPropertyList?, domain,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                      try rawSnapshot()[key] == desired else { throw failure() }
            } else if request.operation == "signal" {
                guard Set(request.expected.keys) == Set(Key.direct), Key.direct.filter({ !$0.derived }).allSatisfy({ snapshot[$0] == request.expected[$0] }) else { throw failure() }
                try validateClock(request)
                typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
                guard let post = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post"),
                      unsafeBitCast(post, to: Post.self)("com.apple.smartcharging.defaultschanged") == 0 else { throw failure() }
            } else { throw failure() }
            emit(.init())
        } catch { emit(.init(error: String(error.localizedDescription.prefix(512)))) }
    }
    private static func emit(_ reply: Reply) -> Never {
        guard let data = try? JSONEncoder().encode(reply), data.count < 131_072 else { Darwin._exit(70) }
        do { try FileHandle.standardOutput.write(contentsOf: data); Darwin._exit(reply.error == nil ? 0 : 70) }
        catch { Darwin._exit(70) }
    }
    private static func failure() -> BatteryControlError { .recovery("系统偏好控制的设备身份、类型、时限或读回未确认。") }
}
