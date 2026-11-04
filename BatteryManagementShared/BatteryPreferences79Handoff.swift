import Foundation
import Darwin

#if (BATTERY_HELPER && BATTERY_REVIEW) || DEBUG
/// Ends only an independent review while leaving the external 85 untouched.
/// This never changes the application's saved policy or restores its old 80.
/// No preference setter, native getter or signal belongs to this path.
struct BatteryPreferences79Handoff {
    typealias T = BatteryPreferences79Transaction
    static let reviewDisposition = "review-ended-preserving-external-85"
    struct Snapshot: Codable, Equatable {
        var values: [T.Key: T.Value]
        var registrations: [Int]
        var level: Int
        var onAC: Bool
        var current: Double
        var updateTime: Date
        var readAt: Date
    }
    struct Receipt: Codable {
        var schema = 1
        var disposition = BatteryPreferences79Handoff.reviewDisposition
        // Optional for old audit-file decoding; absence is not permission to
        // treat a historical receipt as a transfer of application policy.
        var policyTransferred: Bool? = false
        var record: T.Record
        var first: Snapshot
        var last: Snapshot
    }
    let record: T.Record
    private let startedWall: Date
    private let started: TimeInterval
    private var lastContinuous: TimeInterval
    private var lastWall: Date
    private(set) var first: Snapshot?
    private(set) var last: Snapshot?
    private var stableStarted: TimeInterval?
    private var distinctUpdates = 0
    private var latestUpdate: Date?
    private var failed = false

    init(record: T.Record, owner: UUID, wall: Date, now: TimeInterval) throws {
        try T.validate(record)
        guard record.owner == owner, wall.timeIntervalSince1970.isFinite, now.isFinite, now >= 0 else {
            throw T.Failure.invalid
        }
        self.record = record; startedWall = wall; started = now
        lastContinuous = now; lastWall = wall
    }
    mutating func observe(_ sample: Snapshot, now: TimeInterval) throws -> Bool {
        do {
            guard !failed, now.isFinite, now >= lastContinuous, now - started < 180,
                  sample.readAt.timeIntervalSince1970.isFinite, sample.readAt >= lastWall,
                  abs(sample.readAt.timeIntervalSince(startedWall) - (now - started)) <= 5 else { throw T.Failure.invalid }
            try validate(sample)
            if let last { guard sample.values == last.values else { throw T.Failure.conflict(T.Key.allCases) } }
            if now - lastContinuous > 8 { first = nil; stableStarted = nil; distinctUpdates = 0 }
            lastContinuous = now; lastWall = sample.readAt; last = sample
            guard sample.updateTime.timeIntervalSince1970.isFinite,
                  latestUpdate.map({ sample.updateTime >= $0 }) != false else { throw T.Failure.invalid }
            let age = sample.readAt.timeIntervalSince(sample.updateTime)
            guard sample.updateTime >= startedWall, (-2...90).contains(age) else {
                first = nil; stableStarted = nil; distinctUpdates = 0; return false
            }
            if first == nil { first = sample; stableStarted = now; distinctUpdates = 1 }
            else if latestUpdate.map({ sample.updateTime > $0 }) == true { distinctUpdates = 2 }
            latestUpdate = sample.updateTime
            return stableStarted.map { now - $0 >= 15 && distinctUpdates >= 2 } == true
        } catch { failed = true; throw error }
    }
    func receipt() throws -> Receipt {
        guard !failed, let first, let last, let stableStarted, distinctUpdates >= 2,
              lastContinuous - stableStarted >= 15 else { throw T.Failure.unconfirmed }
        return .init(record: record, first: first, last: last)
    }
    private func validate(_ sample: Snapshot) throws {
        guard Set(sample.values.keys) == Set(T.Key.allCases) else { throw BatteryPreferences79IO.failure("偏好快照字段不完整。") }
        guard sample.onAC, (79...85).contains(sample.level), sample.current.isFinite, sample.current >= -0.05 else {
            throw BatteryPreferences79IO.failure("供电/电量/电流未满足交接条件：AC=\(sample.onAC)，SOC=\(sample.level)，A=\(sample.current)。")
        }
        guard !sample.registrations.isEmpty, sample.registrations.allSatisfy({ $0 == 85 }),
              sample.values[.mclLimitValue]?.numeric == 85 else {
            throw BatteryPreferences79IO.failure("保存上限和全部系统登记未共同确认85。")
        }
        guard sample.values[.mclFeatureState]?.numeric == 1 || sample.values[.mclFeatureState] == .bool(true),
              sample.values[.modeOfOperation]?.numeric == 7 else {
            throw BatteryPreferences79IO.failure("MCLFeatureState或modeOfOperation未确认手动限充。")
        }
        for value in sample.values.values { try value.validate() }
        for key in T.Key.guards { guard sample.values[key] == record.guards[key] else { throw T.Failure.conflict([key]) } }
        guard sample.values[.mclTempDisabledUntilDate] == .absent else { throw BatteryPreferences79IO.failure("临时禁用日期仍存在，未交接。") }
        for key in [T.Key.isEngaged, .isManuallyChargeLimited] {
            guard let value = sample.values[key], value == .absent || value == .bool(true) || value.numeric == 1 else {
                throw BatteryPreferences79IO.failure("控制标记\(key.rawValue)未确认，未交接。")
            }
        }
    }
}

enum BatteryPreferences79HandoffRead {
    /// Every other helper/secured worker blocks handoff, including a worker
    /// from an older code hash. Unreadable live process identity is unknown.
    static func processAllowsHandoff(path: String, pid: pid_t, ownPID: pid_t) -> Bool {
        guard pid > 1, ownPID > 1, path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        guard pid != ownPID else { return true }
        return URL(fileURLWithPath: path).lastPathComponent != "BatteryManagementHelper"
            && !path.contains("/com.workview.SuperIsland.BatteryManagementHelper/read-workers/")
    }
    static func fence() throws {
        guard getuid() == 0, geteuid() == 0, BatteryNativeReadProcess.DeferredReaper.shared.reapNow() else {
            throw BatteryPreferences79IO.failure("旧子进程退出尚未确认，保留恢复责任。")
        }
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 65_000 else { throw BatteryPreferences79IO.failure("进程清单大小未知。") }
        var ids = [pid_t](repeating: 0, count: Int(count) + 64)
        let read = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard read > 0, read < ids.count else { throw BatteryPreferences79IO.failure("进程清单读取不完整。") }
        for pid in ids.prefix(Int(read)) where pid > 1 && pid != getpid() {
            var bytes = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &bytes, UInt32(bytes.count)) <= 0 {
                let pathError = errno
                // A process confirmed gone cannot carry out a late write.
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                if pathError == ESRCH && BatteryHandoffProcessIdentity.confirmsExitedProcess(pid: pid) { continue }
                if pathError == ENOENT && BatteryHandoffProcessIdentity.confirmsUnrelatedMissingPath(pid: pid) { continue }
                throw BatteryPreferences79IO.failure("存活进程\(pid)的路径或内核签名身份无法确认，未交接。")
            }
            guard processAllowsHandoff(path: String(cString: bytes), pid: pid, ownPID: getpid()) else {
                throw BatteryPreferences79IO.failure("仍有其他电池辅助程序或旧worker，未交接。")
            }
        }
        // Finishing this independent trial must not awaken an unrelated
        // ordinary recovery that could overwrite the accepted external value.
        for name in ["lease.json", "cutoff.json", "calibration.json"] {
            let path = "/Library/Application Support/" + BatteryManagementIdentity.storageIdentifier + "/" + name
            var info = stat()
            guard lstat(path, &info) == -1 && errno == ENOENT else {
                throw BatteryPreferences79IO.failure("仍有普通控制恢复记录，未交接。")
            }
        }
    }
    static func capture() throws -> BatteryPreferences79Handoff.Snapshot {
        try fence()
        // observe-admission omits all potentially mutating private getters.
        let observed = try BatteryPreferences79IO.observe(admissionOnly: true)
        guard let update = observed.1 else { throw BatteryPreferences79IO.failure("电池更新时刻缺失，未交接。") }
        let values = try BatteryPreferences79IO.handoffValues()
        let after = try BatteryPreferences79IO.handoffValues()
        guard values == after else { throw BatteryPreferences79Transaction.Failure.conflict(BatteryPreferences79Transaction.Key.allCases) }
        try fence()
        return .init(values: values, registrations: observed.0.registrations,
                     level: Int(observed.0.level), onAC: observed.0.adapterPresent,
                     current: observed.0.batteryCurrent, updateTime: update, readAt: observed.0.wallDate)
    }
    static func confirm(_ receipt: BatteryPreferences79Handoff.Receipt) throws {
        let snapshot = try capture()
        guard snapshot.values == receipt.last.values, snapshot.registrations == receipt.last.registrations,
              snapshot.onAC, snapshot.current.isFinite, snapshot.current >= -0.05, (79...85).contains(snapshot.level),
              snapshot.updateTime >= receipt.last.updateTime,
              (0...8).contains(snapshot.readAt.timeIntervalSince(receipt.last.readAt)),
              (-2...90).contains(snapshot.readAt.timeIntervalSince(snapshot.updateTime)) else {
            throw BatteryPreferences79IO.failure("归档期间设备或偏好已变化，恢复记录保留。")
        }
    }
}
#endif
