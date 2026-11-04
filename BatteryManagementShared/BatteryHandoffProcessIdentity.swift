import Foundation
import Darwin

#if BATTERY_HELPER || DEBUG
/// A replaced application can leave a live process whose executable vnode no
/// longer has a path. Kernel-bound signing and process-birth data remain
/// available. This fallback never accepts an unsigned/local helper or an
/// unreadable identity, and never uses the process's self-reported name.
enum BatteryHandoffProcessIdentity {
    struct ExitedProcess: Equatable {
        var pid: pid_t
        var birthSeconds: Int64
        var birthMicroseconds: Int32
        var uid: uid_t
        var status: Int32
    }
    static func confirmsSameExitedProcess(before: ExitedProcess, after: ExitedProcess) -> Bool {
        before == after && before.pid > 1 && before.birthSeconds > 0
            && (0..<1_000_000).contains(before.birthMicroseconds) && before.status == SZOMB
    }
    enum Lifecycle: Equatable {
        case absent, process(ExitedProcess), unknown
    }
    static func confirmsExit(before: Lifecycle, after: Lifecycle) -> Bool {
        switch (before, after) {
        case (.absent, .absent): return true
        case (.process(let first), .absent):
            return confirmsSameExitedProcess(before: first, after: first)
        case (.process(let first), .process(let last)):
            return confirmsSameExitedProcess(before: first, after: last)
        default: return false
        }
    }
    /// Successful KERN_PROC_PID with zero bytes positively reports absence.
    /// Errors, partial replies and live/PID-reused identities stay unknown.
    static func lifecycle(pid: pid_t) -> Lifecycle {
        guard pid > 1 else { return .unknown }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return .unknown }
        if size == 0 { return .absent }
        guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return .unknown }
        return .process(.init(pid: pid, birthSeconds: Int64(info.kp_proc.p_un.__p_starttime.tv_sec),
            birthMicroseconds: info.kp_proc.p_un.__p_starttime.tv_usec,
            uid: info.kp_eproc.e_ucred.cr_uid, status: Int32(info.kp_proc.p_stat)))
    }
    static func confirmsExitedProcess(pid: pid_t) -> Bool {
        let before = lifecycle(pid: pid)
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) <= 0, errno == ESRCH else { return false }
        return confirmsExit(before: before, after: lifecycle(pid: pid))
    }
    enum PathResolution: Equatable {
        case path(String), exited, unrelatedSigned, unresolved(String)
    }
    /// A process can exit between listallpids, pidpath and the kernel snapshot.
    /// Retry complete observations, never turn ESRCH or an unknown snapshot into
    /// permission to proceed. A reappearing path goes through the worker fence.
    static func resolvePath(attempts: Int = 3, observe: () -> PathResolution,
                            pause: () -> Void = { usleep(5_000) }) -> PathResolution {
        guard (1...3).contains(attempts) else { return .unresolved("invalid-attempts") }
        var diagnostics = [String]()
        for index in 0..<attempts {
            let result = observe()
            if case .unresolved(let detail) = result { diagnostics.append(detail) }
            else { return result }
            if index + 1 < attempts { pause() }
        }
        return .unresolved(diagnostics.joined(separator: ";"))
    }
    static func observePath(pid: pid_t) -> PathResolution {
        var bytes = [CChar](repeating: 0, count: 4096)
        errno = 0
        let rc = proc_pidpath(pid, &bytes, UInt32(bytes.count)), pathError = errno
        if rc > 0 { return .path(String(cString: bytes)) }
        if confirmsExitedProcess(pid: pid) { return .exited }
        if pathError == ENOENT && confirmsUnrelatedMissingPath(pid: pid) { return .unrelatedSigned }
        // Capture raw syscall results, not the misleading assertion "live".
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        errno = 0
        let status = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0), systemError = errno
        let detail = "path=\(rc)/\(pathError),kernel=\(status)/\(systemError)/\(size)"
        if status == 0 && size == MemoryLayout<kinfo_proc>.size {
            return .unresolved(detail + ",pid=\(info.kp_proc.p_pid),state=\(info.kp_proc.p_stat),birth=\(info.kp_proc.p_un.__p_starttime.tv_sec).\(info.kp_proc.p_un.__p_starttime.tv_usec)")
        }
        return .unresolved(detail)
    }
    struct Snapshot: Equatable {
        var pid: pid_t
        var birthSeconds: UInt64
        var birthMicroseconds: UInt64
        var uid: uid_t
        var flags: UInt32
        var identifier: String
        var team: String
        var hash: Data
    }
    static func allowsMissingPath(before: Snapshot, after: Snapshot) -> Bool {
        let id = before.identifier.lowercased()
        return before == after && before.pid > 1 && before.birthSeconds > 0
            && before.birthMicroseconds < 1_000_000
            && before.flags & 1 == 1 && before.flags & 2 == 0 // CS_VALID, not CS_ADHOC
            && before.hash.count == 20 && before.hash.contains(where: { $0 != 0 })
            && before.team.utf8.count == 10
            && before.team.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
            // A kernel code-signing identifier is not a bundle identifier.
            // Signed command-line helpers can legitimately use e.g. extension-host.
            // Trust comes from the stable kernel signature/team/hash above, not dots.
            && !id.isEmpty && id.utf8.count < 512
            && id.utf8.allSatisfy { (33...126).contains($0) }
            && !id.hasPrefix("com.workview.superisland")
            && !id.contains("battery") && !id.contains("aldente")
            && !id.contains("batfi") && !id.contains("ampere")
    }
    static func decodeKernelString(_ bytes: Data) throws -> String {
        guard bytes.count >= 9 else { throw BatteryControlError.recovery("内核签名字段缺少长度。") }
        let size = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size >= 10, size <= bytes.count, size <= 4096 else {
            throw BatteryControlError.recovery("内核签名字段长度无效。")
        }
        let payload = bytes[8..<Int(size)]
        guard payload.last == 0, !payload.dropLast().contains(0),
              let value = String(data: payload.dropLast(), encoding: .utf8), !value.isEmpty else {
            throw BatteryControlError.recovery("内核签名字段内容无效。")
        }
        return value
    }
    static func capture(pid: pid_t) throws -> Snapshot {
        guard pid > 1, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else {
            throw BatteryControlError.recovery("内核进程身份不可读。")
        }
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer, Int) -> Int32
        let csops = unsafeBitCast(symbol, to: CSOps.self)
        func birth() throws -> proc_bsdinfo {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_pid == UInt32(pid), info.pbi_status != SZOMB else {
                throw BatteryControlError.recovery("进程出生身份不可确认。")
            }
            return info
        }
        func string(_ operation: UInt32) throws -> String {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let status = buffer.withUnsafeMutableBytes { csops(pid, operation, $0.baseAddress!, $0.count) }
            guard status == 0 else { throw BatteryControlError.recovery("内核签名标识不可读。") }
            return try decodeKernelString(Data(buffer))
        }
        let first = try birth()
        var flags: UInt32 = 0
        guard csops(pid, 0, &flags, MemoryLayout<UInt32>.size) == 0 else {
            throw BatteryControlError.recovery("内核签名状态不可读。")
        }
        let identifier = try string(11), team = try string(14)
        let hash = try BatteryReadWorkerExecutable.kernelCDHash(pid: pid), last = try birth()
        guard first.pbi_start_tvsec == last.pbi_start_tvsec, first.pbi_start_tvusec == last.pbi_start_tvusec,
              first.pbi_uid == last.pbi_uid else { throw BatteryControlError.recovery("进程身份在读取期间发生变化。") }
        return .init(pid: pid, birthSeconds: first.pbi_start_tvsec, birthMicroseconds: first.pbi_start_tvusec,
                     uid: first.pbi_uid, flags: flags, identifier: identifier, team: team, hash: hash)
    }
    static func confirmsUnrelatedMissingPath(pid: pid_t) -> Bool {
        guard let first = try? capture(pid: pid), let second = try? capture(pid: pid),
              allowsMissingPath(before: first, after: second) else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &path, UInt32(path.count)) <= 0 && errno == ENOENT
    }
}

#endif
