import Foundation
import Darwin

// Shared bounded transport. The caller owns fixed arguments, permissions and
// action-specific confirmation; this transport never interprets success as a
// completed hardware or session action. The legacy type name is retained.
#if BATTERY_HELPER || DEBUG
struct BatteryNativeReadReply: Codable {
    var schema = 1
    var value: Int?
    var error: String?
    var phase: String?
    var pid: Int32?
    #if BATTERY_REVIEW || DEBUG
    var diagnostics: String?
    #endif
}
#endif

/// The parent owns one directly spawned read-only child. No Foundation Process
/// callback, DispatchSource callback or run-loop progress is needed to observe
/// its real waitpid exit and the separate stdout EOF.
enum BatteryNativeReadProcess {
    struct ChildState {
        enum Observation: Equatable { case running, interrupted, reaped, lost(Int32) }
        let pid: pid_t
        private(set) var status: Int32 = 0
        private(set) var reaped = false
        private(set) var relationshipLost = false
        private(set) var waitError: Int32?
        var maySignal: Bool { !reaped && !relationshipLost }
        mutating func observe(wait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = Darwin.waitpid) -> Observation {
            if reaped { return .reaped }
            if relationshipLost { return .lost(waitError ?? ECHILD) }
            var value: Int32 = 0
            let result = wait(pid, &value, WNOHANG)
            if result == pid {
                // Traced children can report a stop even without WUNTRACED.
                // A stop/continue notification does not release PID ownership.
                if value & 0x7f == 0x7f { return .running }
                status = value; reaped = true; return .reaped
            }
            if result == 0 { return .running }
            let code = result == -1 ? errno : ECHILD
            if result == -1, code == EINTR { return .interrupted }
            relationshipLost = true; waitError = code
            return .lost(code)
        }
    }
    /// Keeps wait ownership after the synchronous cleanup budget expires.
    /// It never signals a PID and never decides whether a read succeeded.
    final class DeferredReaper: @unchecked Sendable {
        static let shared = DeferredReaper()
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "SuperIsland.battery.native-read-reaper", qos: .utility)
        private let wait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
        private let automaticallySchedule: Bool
        private var children: [pid_t: ChildState] = [:]
        private var timer: DispatchSourceTimer?
        init(wait: @escaping (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = Darwin.waitpid,
             automaticallySchedule: Bool = true) {
            self.wait = wait; self.automaticallySchedule = automaticallySchedule
        }
        var pendingCount: Int {
            lock.lock(); defer { lock.unlock() }; return children.count
        }
        func adopt(_ child: ChildState) {
            guard child.pid > 0, child.maySignal else { return }
            lock.lock(); defer { lock.unlock() }
            children[child.pid] = child
            guard automaticallySchedule, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in _ = self?.reapNow() }
            self.timer = timer; timer.resume()
        }
        @discardableResult func reapNow() -> Bool {
            lock.lock(); defer { lock.unlock() }
            for (pid, var child) in children {
                _ = child.observe(wait: wait)
                if child.reaped || child.relationshipLost { children.removeValue(forKey: pid) }
                else { children[pid] = child }
            }
            if children.isEmpty { timer?.cancel(); timer = nil }
            return children.isEmpty
        }
        deinit { timer?.cancel() }
    }
    static func lastPhase(_ data: Data) -> String? {
        #if BATTERY_HELPER || DEBUG
        data.split(separator: 0x0a).compactMap { line -> String? in
            guard let reply = try? JSONDecoder().decode(BatteryNativeReadReply.self, from: Data(line)),
                  reply.schema == 1, let phase = reply.phase,
                  ["initializing", "querying", "query-returned", "reply"].contains(phase) else { return nil }
            return phase
        }.last
        #else
        // App workers have their own action receipts, with no native-read phases.
        // The POSIX exit/EOF/deadline checks below remain the same for all callers.
        return nil
        #endif
    }
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 1.25,
                    maximumOutput: Int = 4096) throws -> Data {
        try run(executable: executable, arguments: arguments, timeout: timeout,
                maximumOutput: maximumOutput, reaper: .shared)
    }
    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    maximumOutput: Int, reaper: DeferredReaper,
                    wait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = Darwin.waitpid) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 3, (1...65_536).contains(maximumOutput),
              executable.isFileURL, !executable.path.utf8.contains(0), !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw BatteryControlError.invalid("原生只读子进程参数无效。")
        }
        guard reaper.reapNow() else {
            throw BatteryControlError.unavailable("先前只读子进程回收尚未确认，未启动新的只读进程。")
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw BatteryControlError.unavailable("无法准备原生只读管道（errno=\(errno)）。") }
        defer { for descriptor in descriptors where descriptor >= 0 { _ = close(descriptor) } }
        // Keep the pipe clear of 0/1/2 even if the caller closed its stdio.
        // All original pipe descriptors are close-on-exec in the parent.
        for index in descriptors.indices {
            if descriptors[index] < 3 {
                let moved = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                guard moved >= 0 else { throw BatteryControlError.unavailable("无法隔离只读管道（errno=\(errno)）。") }
                _ = close(descriptors[index]); descriptors[index] = moved
            }
            let flags = fcntl(descriptors[index], F_GETFD)
            guard flags >= 0, fcntl(descriptors[index], F_SETFD, flags | FD_CLOEXEC) == 0 else {
                throw BatteryControlError.unavailable("无法设置只读管道关闭标记（errno=\(errno)）。")
            }
        }
        let readDescriptor = descriptors[0], writeDescriptor = descriptors[1]
        let readFlags = fcntl(readDescriptor, F_GETFL)
        guard readFlags >= 0, fcntl(readDescriptor, F_SETFL, readFlags | O_NONBLOCK) == 0 else {
            throw BatteryControlError.unavailable("无法准备原生非阻塞读取（errno=\(errno)）。")
        }
        var actions: posix_spawn_file_actions_t?
        let actionResult = posix_spawn_file_actions_init(&actions)
        guard actionResult == 0 else { throw BatteryControlError.unavailable("无法准备只读进程文件动作（errno=\(actionResult)）。") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let actionResults = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO),
            posix_spawn_file_actions_addclose(&actions, readDescriptor),
            posix_spawn_file_actions_addclose(&actions, writeDescriptor)
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            throw BatteryControlError.unavailable("只读进程文件动作配置失败。")
        }
        var attributes: posix_spawnattr_t?
        let attributeResult = posix_spawnattr_init(&attributes)
        guard attributeResult == 0 else { throw BatteryControlError.unavailable("无法准备只读进程属性（errno=\(attributeResult)）。") }
        defer { posix_spawnattr_destroy(&attributes) }
        // Do not leak unrelated non-CLOEXEC descriptors from the daemon into
        // the worker. Its three standard descriptors are explicit actions.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw BatteryControlError.unavailable("无法隔离只读进程文件描述符。")
        }
        var strings = ([executable.path] + arguments).map { strdup($0) }
        defer { for case let pointer? in strings { free(pointer) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw BatteryControlError.unavailable("无法准备只读进程参数。") }
        strings.append(nil)
        var pid: pid_t = 0
        let started = ProcessInfo.processInfo.systemUptime
        // posix_spawn is synchronous. The deadline bounds post-spawn I/O and
        // waiting, not the operating system's launch operation itself.
        let spawnResult = strings.withUnsafeMutableBufferPointer { argv in
            posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, environ)
        }
        let launched = ProcessInfo.processInfo.systemUptime
        // EOF must describe the child's writers, never our own retained end.
        _ = close(writeDescriptor); descriptors[1] = -1
        guard spawnResult == 0, pid > 0 else {
            throw BatteryControlError.unavailable("系统限充只读进程启动失败（errno=\(spawnResult)）。")
        }
        var child = ChildState(pid: pid), output = Data(), readEOF = false, overflow = false
        let deadline = launched + timeout
        var readFailure: Int32?
        func diagnostic() -> String {
            "phase=\(lastPhase(output) ?? "未收到阶段报告"), processFinished=\(child.reaped), pipeFinished=\(readEOF), bytes=\(output.count), overflow=\(overflow), waitRelationshipLost=\(child.relationshipLost)"
        }
        func boundary() -> String {
            "pid=\(pid), launch=\(String(format: "%.3f", launched - started))s, elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s"
        }
        func stopOwnedChild() -> String {
            // A reaped PID can be reused. ECHILD/other lost-wait states cannot
            // authorize signalling either, even if the numeric PID is alive.
            let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.3
            var killResult: Int32?, killError: Int32?
            var signalled = false
            repeat {
                switch child.observe(wait: wait) {
                case .reaped, .lost: break
                case .interrupted: break
                case .running:
                    if !signalled, child.maySignal {
                        killResult = kill(pid, SIGKILL)
                        if killResult == -1 { killError = errno }
                        signalled = true
                    }
                }
                if child.reaped || child.relationshipLost { break }
                if ProcessInfo.processInfo.systemUptime < reapDeadline { _ = poll(nil, 0, 1) }
            } while ProcessInfo.processInfo.systemUptime < reapDeadline
            let deferred = child.maySignal
            if deferred { reaper.adopt(child) }
            let signal = killResult.map(String.init) ?? "not-requested"
            return "killResult=\(signal), killErrno=\(killError.map(String.init) ?? "none"), completionObserved=\(child.reaped), reapDeferred=\(deferred), waitErrno=\(child.waitError.map(String.init) ?? "none")"
        }
        while true {
            if !readEOF {
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(readDescriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        if output.count + count > maximumOutput { overflow = true; break }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 { readEOF = true; break }
                    else if errno == EINTR {
                        if ProcessInfo.processInfo.systemUptime >= deadline { break }
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else { readFailure = errno; break }
                    if ProcessInfo.processInfo.systemUptime >= deadline { break }
                }
            }
            _ = child.observe(wait: wait)
            // A full pipe is a bounded output error, even if the child has
            // concurrently exited or the deadline just expired.
            if overflow {
                let evidence = diagnostic(), cleanup = stopOwnedChild()
                throw BatteryControlError.unavailable("系统限充只读响应过长（\(boundary()), \(evidence), \(cleanup)）。")
            }
            if child.relationshipLost {
                throw BatteryControlError.unavailable("系统限充只读子进程退出状态未知（\(boundary()), \(diagnostic()), waitErrno=\(child.waitError ?? ECHILD)）；未向失去回收关系的PID发送信号。")
            }
            if let readFailure {
                let evidence = diagnostic(), cleanup = stopOwnedChild()
                throw BatteryControlError.unavailable("系统限充只读管道失败（errno=\(readFailure), \(boundary()), \(evidence), \(cleanup)）。")
            }
            if child.reaped && readEOF { break }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                let evidence = diagnostic(), cleanup = stopOwnedChild()
                throw BatteryControlError.unavailable("系统限充读取超时；仅对尚未回收的自身子进程请求终止（\(boundary()), \(evidence), \(cleanup)）。")
            }
            let milliseconds = Int32(max(1, min(20, ceil(remaining * 1000))))
            let ready: Int32
            if readEOF { ready = poll(nil, 0, milliseconds) }
            else {
                var descriptor = pollfd(fd: readDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                ready = poll(&descriptor, 1, milliseconds)
                if ready > 0, descriptor.revents & Int16(POLLNVAL) != 0 { readFailure = EBADF }
            }
            if ready == -1, errno != EINTR { readFailure = errno }
        }
        let exitCode = (child.status >> 8) & 0xff, signal = child.status & 0x7f
        guard signal == 0, exitCode == 0 else {
            // Only a typed schema-1 error is useful diagnostic context. A
            // nonzero exit remains failure even when stdout contains a value.
            #if BATTERY_HELPER || DEBUG
            let workerError = output.split(separator: 0x0a).reversed().compactMap { line -> String? in
                guard let reply = try? JSONDecoder().decode(BatteryNativeReadReply.self, from: Data(line)),
                      reply.schema == 1, let error = reply.error else { return nil }
                let forbidden = CharacterSet.controlCharacters.union(.newlines)
                let clean = String(String.UnicodeScalarView(error.unicodeScalars.filter { !forbidden.contains($0) }))
                return clean.isEmpty ? nil : String(clean.prefix(180))
            }.first
            let context = workerError.map { ", workerError=" + $0 } ?? ""
            #else
            let context = ""
            #endif
            throw BatteryControlError.unavailable("系统限充只读子进程失败（status=\(child.status), exitCode=\(exitCode), signal=\(signal), \(diagnostic())\(context)）。")
        }
        return output
    }
}

