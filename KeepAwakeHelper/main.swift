import Foundation
import Darwin
import IOKit.ps

/// A fixed executable and fixed arguments only; this daemon cannot execute a
/// caller-supplied command or write to a caller-supplied path.
func pmset(_ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    if done.wait(timeout: .now() + 3) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        throw KeepAwakeLease.Failure.writeFailed
    }
    guard process.terminationStatus == 0 else { throw KeepAwakeLease.Failure.writeFailed }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func protectionReason(acOnly: Bool, minimumBattery: Int, respectLowPower: Bool) -> String? {
    if [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) { return "系统热压力过高" }
    if respectLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return "系统处于低电量模式" }
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return "电源状态未知" }
    for source in list {
        guard let values = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        guard let current = values[kIOPSCurrentCapacityKey] as? Int,
              let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0,
              let power = values[kIOPSPowerSourceStateKey] as? String else { return "电源状态未知" }
        if Double(current) / Double(maximum) * 100 < Double(minimumBattery) { return "电量低于保护阈值" }
        if acOnly && power != kIOPSACPowerValue { return "已断开电源" }
        return nil
    }
    return "没有确认内置电池能力，不能启用合盖运行"
}

final class Daemon: NSObject, NSXPCListenerDelegate, KeepAwakeHelperProtocol {
    let queue = DispatchQueue(label: "com.workview.SuperIsland.KeepAwakeHelper.lease")
    var lease: KeepAwakeLease?
    var failure: String?
    var timer: DispatchSourceTimer?
    var expiryTimer: DispatchSourceTimer?
    let directory = URL(fileURLWithPath: "/Library/Application Support/com.workview.SuperIsland.KeepAwakeHelper", isDirectory: true)
    func prepare() {
        do {
            guard getuid() == 0 else { throw CocoaError(.fileWriteNoPermission) }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try fm.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let url = directory.appendingPathComponent("lease.json")
            let stored: KeepAwakeLease.Journal?
            if fm.fileExists(atPath: url.path) {
                guard (try fm.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadNoPermission) }
                stored = try JSONDecoder().decode(KeepAwakeLease.Journal.self, from: Data(contentsOf: url))
            } else { stored = nil }
            let lease = KeepAwakeLease(journal: stored, readPower: {
                let lines = try pmset(["-g"]).split(separator: "\n")
                guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SleepDisabled") }),
                      let value = Int(line.split(whereSeparator: { $0.isWhitespace }).last ?? ""), [0, 1].contains(value) else { throw KeepAwakeLease.Failure.conflict }
                return value
            }, writePower: { value in
                guard [0, 1].contains(value) else { throw KeepAwakeLease.Failure.conflict }
                _ = try pmset(["-a", "disablesleep", String(value)])
            }, save: { journal in
                if let journal {
                    try JSONEncoder().encode(journal).write(to: url, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    // Flush durable intent before the power command can execute.
                    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
                    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                    defer { close(fd) }
                    guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
                } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            })
            self.lease = lease
            try lease.recover()
        } catch { failure = error.localizedDescription }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                if let journal = self.lease?.journal,
                   let reason = protectionReason(acOnly: journal.acOnly, minimumBattery: journal.minimumBattery, respectLowPower: journal.respectLowPower) {
                    try self.lease?.recover(); self.failure = reason
                } else if try self.lease?.expire(now: KeepAwakeClock.now()) == true {
                    // A verified restoration must not leave an earlier conflict
                    // permanently poisoning subsequent status/renew requests.
                    self.failure = nil
                }
            }
            catch { self.failure = error.localizedDescription }
        }
        self.timer = timer; timer.resume()
        let expiry = DispatchSource.makeTimerSource(queue: queue)
        expiry.schedule(deadline: .distantFuture)
        expiry.setEventHandler { [weak self] in
            guard let self else { return }
            do { if try self.lease?.expire(now: KeepAwakeClock.now()) == true { self.failure = nil } }
            catch { self.failure = error.localizedDescription }
        }
        expiryTimer = expiry; expiry.resume()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Listener checks the signing requirement before delivering this call.
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
        connection.exportedObject = self
        connection.resume(); return true
    }
    func status(reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in reply(failure == nil && lease != nil, failure ?? (lease?.journal == nil ? "辅助程序就绪；没有活动租约" : "合盖租约已应用")) }
    }
    private func recordFailure(_ error: Error) {
        if (error as? KeepAwakeLease.Failure)?.isRequestRejection != true {
            failure = error.localizedDescription
        }
    }
    func renew(owner: String, acOnly: Bool, minimumBattery: Int, respectLowPower: Bool, reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in
            guard failure == nil, let lease else { reply(false, failure ?? "辅助程序未就绪"); return }
            guard UUID(uuidString: owner) != nil else { reply(false, KeepAwakeLease.Failure.invalidOwner.localizedDescription); return }
            guard (5...50).contains(minimumBattery) else { reply(false, "无效的保护阈值"); return }
            if let reason = protectionReason(acOnly: acOnly, minimumBattery: minimumBattery, respectLowPower: respectLowPower) {
                do { try lease.release(owner: owner) } catch { recordFailure(error); reply(false, error.localizedDescription); return }
                failure = reason; reply(false, reason); return
            }
            do { try lease.renew(owner: owner, now: KeepAwakeClock.now(), acOnly: acOnly, minimumBattery: minimumBattery, respectLowPower: respectLowPower)
                if let expires = lease.journal?.expires {
                    expiryTimer?.schedule(deadline: .now() + max(0, expires - KeepAwakeClock.now()))
                }
                reply(true, "合盖租约已应用；实际合盖需设备验收") }
            catch { recordFailure(error); reply(false, error.localizedDescription) }
        }
    }
    func release(owner: String, reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in
            guard let lease else { reply(false, failure ?? "无法读取恢复记录"); return }
            do { try lease.release(owner: owner); failure = nil; reply(true, "已核对并释放合盖租约") }
            catch { recordFailure(error); reply(false, error.localizedDescription) }
        }
    }
}
let daemon = Daemon()
daemon.prepare()
// Fail closed for untrusted/ad-hoc builds; no listener accepts clients.
guard let requirement = KeepAwakeHelperIdentity.requirement(identifiers: ["com.workview.SuperIsland", "com.workview.SuperIsland.WE1Debug", "com.workview.SuperIsland.BM1Debug"]) else { exit(78) }
let listener = NSXPCListener(machServiceName: KeepAwakeHelperIdentity.label)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = daemon
listener.resume()
RunLoop.current.run()
