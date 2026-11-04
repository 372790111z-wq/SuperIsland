import Foundation
import Darwin

#if BATTERY_HELPER || DEBUG
/// This receipt consumes the ONE authorized trial, not hardware ownership.
/// Originals/recovery remain in the ordinary lease and cutoff journals.
final class BatteryPauseRefreshTicket {
    private let directory: URL
    private let owner: uid_t
    init(directory: URL, owner: uid_t = 0) { self.directory = directory; self.owner = owner }
    func consume(operationID: UUID) throws {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == owner,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_mode & 0o077 == 0 else { throw failure() }
        let path = directory.appendingPathComponent("pause-refresh-v1.consumed").path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() } // Existing/empty/corrupt is never absence.
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw failure() }
        let bytes = Data((operationID.uuidString + "\n").utf8)
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
        guard fsync(fd) == 0 else { throw failure() }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw failure() }
        defer { close(dir) }
        guard fsync(dir) == 0 else { throw failure() }
    }
    private func failure() -> BatteryControlError {
        .recovery("本次短暂供电切换许可已消耗或未持久确认；禁止自动重试。")
    }
}

enum BatteryPauseRefresh {
    /// mach_continuous_time includes system sleep; a wake never extends a pulse.
    static func continuousTime() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
    static func validate(_ request: BatteryControlRequest, telemetry: BatteryTelemetry,
                         target: Int, saved: Int?, registered: Set<Int>?, input: Bool?,
                         calibrationActive: Bool, now: Date) throws {
        let p = request.preferences
        guard request.mode == .paused, request.calibration == nil, !request.sleeping,
              !calibrationActive, let level = telemetry.level, (79...85).contains(level), target == level,
              (79...85).contains(p.limit), !p.automaticDischarge, !p.sailing, !p.heatProtection,
              p.sleep == .unchanged, p.lowPower == .never, p.highPowerScope == .never,
              p.led == .system, !p.blinkWhileDischarging,
              telemetry.chargingObservation == true, telemetry.current.map({ $0.isFinite && $0 > 0 }) == true,
              telemetry.powerSupplyObservation == true, input == true,
              let update = telemetry.reportedPower?.batteryUpdateTimeContext,
              now.timeIntervalSince(update) >= 0, now.timeIntervalSince(update) <= 90,
              saved == target, let registered, !registered.isEmpty, registered != [target],
              registered.allSatisfy({ (79...85).contains($0) }) else {
            throw BatteryControlError.unavailable("暂停短暂切换的79–85范围、独立供电、充电或目标条件未满足。")
        }
    }

    /// Used by the daemon BEFORE policy/apply. Pending work owns this tick:
    /// either observe its fixed target or cancel; never fall through to writes.
    static func handlePending(_ pending: Verification?, request: BatteryControlRequest,
                              telemetry: BatteryTelemetry, observe: (Int) throws -> Void,
                              cancel: () throws -> Void) throws -> Bool {
        guard let pending else { return false }
        if request.mode == .paused, request.operationID == pending.operationID {
            guard let level = telemetry.level, (79...85).contains(level) else {
                throw BatteryControlError.recovery("暂停验证电量越界或未知，未写入新的目标。")
            }
            try observe(pending.target)
        } else { try cancel() }
        return true
    }

    struct Verification {
        let operationID: UUID
        let target: Int
        let started: TimeInterval
        let submittedAt: Date
        let baselineUpdate: Date
        private var stableSince: TimeInterval?
        private var lastTime: TimeInterval?
        init(operationID: UUID, target: Int, started: TimeInterval, submittedAt: Date, baselineUpdate: Date) {
            self.operationID = operationID; self.target = target; self.started = started
            self.submittedAt = submittedAt; self.baselineUpdate = baselineUpdate
        }
        mutating func observe(_ telemetry: BatteryTelemetry, activeMatches: Bool, input: Bool?,
                              now: TimeInterval, date: Date) throws -> Bool {
            guard now.isFinite, now >= started, now - started <= 90,
                  lastTime.map({ now >= $0 }) ?? true,
                  abs(date.timeIntervalSince(submittedAt) - (now - started)) <= 2 else {
                throw BatteryControlError.recovery("暂停确认超时或时钟变化；未判定暂停成功。")
            }
            if let lastTime, now - lastTime > 5 { stableSince = nil }
            lastTime = now
            guard let level = telemetry.level, (79...85).contains(level) else {
                throw BatteryControlError.recovery("暂停验证电量越界或未知，正在恢复。")
            }
            guard let update = telemetry.reportedPower?.batteryUpdateTimeContext,
                  update > baselineUpdate, update > submittedAt,
                  date.timeIntervalSince(update) >= 0, date.timeIntervalSince(update) <= 90,
                  telemetry.powerSupplyObservation == true, input == true, activeMatches,
                  telemetry.chargingObservation == false,
                  telemetry.current.map({ $0.isFinite && $0 <= 0 }) == true else {
                stableSince = nil; return false
            }
            if stableSince == nil { stableSince = now }
            return now - stableSince! >= 10
        }
    }
}
#endif
