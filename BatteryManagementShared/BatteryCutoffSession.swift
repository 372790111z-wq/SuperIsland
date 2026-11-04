import Foundation

/// Intent and recovery evidence only. Register originals remain in the lease.
/// No client can supply this record or a claim of physical connection over XPC.
final class BatteryCutoffSession {
    enum Phase: String, Codable { case discharging, restoring, attention }
    #if BATTERY_HELPER || DEBUG
    struct PausePulse: Codable, Equatable {
        var operationID: UUID
        var target: Int
        var submittedAt: Date
    }
    struct Record: Codable, Equatable {
        var schema = 1
        var owner: UUID
        var phase: Phase
        var observedPowerOff = false
        var releasingLease = false
        var requiresSupplyRecovery = true
        // Older records observed OS connection flags. Never reinterpret those
        // as independent adapter-input evidence after an upgrade.
        var inputEvidenceVersion: Int? = 1
        var pausePulse: PausePulse?
    }
    private(set) var record: Record?
    private let save: (Record?) throws -> Void
    private var started: TimeInterval?
    private var unknownSince: TimeInterval?
    private var restoringSince: TimeInterval?
    private var stableSince: TimeInterval?
    private var lastTime: TimeInterval?
    let timeout: TimeInterval
    let stableDuration: TimeInterval
    var recovering: Bool { record.map { $0.phase != .discharging } ?? false }
    var needsAttention: Bool { record?.phase == .attention }
    var message: String {
        needsAttention ? "供电或原控制状态仍未恢复；请检查电源，恢复责任已保留。"
            : record?.requiresSupplyRecovery == true
                ? "正在等待实际供电及控制读回恢复；尚未确认完成。"
                : "正在等待系统原控制状态回读稳定；尚未确认完成。"
    }

    init(record: Record? = nil, timeout: TimeInterval = 90, stableDuration: TimeInterval = 10,
         save: @escaping (Record?) throws -> Void) throws {
        guard record.map({ $0.schema == 1 && ($0.inputEvidenceVersion == nil || $0.inputEvidenceVersion == 1) && ($0.phase != .discharging || (!$0.releasingLease && $0.requiresSupplyRecovery))
                  && ($0.requiresSupplyRecovery || $0.releasingLease)
                  && ($0.pausePulse.map { (79...85).contains($0.target) && $0.submittedAt.timeIntervalSince1970.isFinite } ?? true)
                  && ($0.pausePulse == nil || ($0.phase != .discharging && $0.requiresSupplyRecovery)) }) ?? true,
              timeout.isFinite, timeout > 0, stableDuration.isFinite,
              stableDuration > 0, stableDuration < timeout else {
            throw BatteryControlError.recovery("断供恢复记录或观察参数无效。")
        }
        var trusted = record
        if trusted?.inputEvidenceVersion == nil {
            trusted?.observedPowerOff = false
            trusted?.inputEvidenceVersion = 1
        }
        self.record = trusted; self.timeout = timeout; self.stableDuration = stableDuration; self.save = save
    }

    /// Pulse recovery proves useful input and released controls, not an
    /// observed off/on edge. Its separate marker never relaxes discharge rules.
    func armPausePulse(owner: UUID, pulse: PausePulse, now: TimeInterval) throws {
        guard record == nil, now.isFinite, now >= 0, (79...85).contains(pulse.target),
              pulse.submittedAt.timeIntervalSince1970.isFinite else {
            throw BatteryControlError.recovery("短暂切换恢复状态无效。")
        }
        try checkpoint(.init(owner: owner, phase: .restoring, pausePulse: pulse))
        restoringSince = now; lastTime = now
    }

    /// Only helper-observed durable ownership and a matching live register can
    /// supply policy's trusted context. An absent AC flag is never proof.
    func ownsCutoff(owner: UUID, journal: BatteryOverrideLease.Journal?, key: String?, actual: Int?) throws -> Bool {
        guard let record, record.phase == .discharging else { return false }
        guard let key, ["CHIE", "CH0I", "CH0J"].contains(key),
              record.owner == owner, journal?.owner == owner,
              let entry = journal?.entries[key], entry.original == 0 else {
            throw BatteryControlError.conflict("断供会话或原值所有权未得到确认。")
        }
        let enabled = key == "CHIE" ? 8 : 1
        guard (entry.expected == enabled || entry.prior == enabled), actual == enabled else {
            throw BatteryControlError.conflict("断供寄存器已改变，未继续放电。")
        }
        return true
    }
    /// Continuing recovery accepts the identical heartbeat or cancellation of
    /// its current calibration, never an unrelated mode/preference change.
    func acceptsRecoveryRequest(_ next: BatteryControlRequest, previous: BatteryControlRequest?) -> Bool {
        guard recovering, let record, record.owner == next.owner, !record.releasingLease,
              let previous else { return false }
        if next == previous { return true }
        guard case .cancel(let id) = next.calibration, case .start(let previousID) = previous.calibration, id == previousID else { return false }
        var comparable = next; comparable.calibration = previous.calibration
        return comparable == previous
    }

    /// Must succeed before the lease is allowed to write adapter cutoff.
    func arm(owner: UUID, powered: Bool, now: TimeInterval) throws {
        guard now.isFinite, now >= 0 else { throw BatteryControlError.invalid("断供时钟无效。") }
        if let record {
            guard record.owner == owner, record.phase == .discharging else {
                throw BatteryControlError.conflict("已有断供或恢复责任，不能开启新控制。")
            }
            return
        }
        guard powered else { throw BatteryControlError.unavailable("尚未确认适配器正在供电，未启动断供。") }
        try checkpoint(.init(owner: owner, phase: .discharging))
        started = now; lastTime = now
    }

    /// owned must be established from the same owner's durable lease AND a
    /// matching live cutoff register, not from absence of AC alone.
    func observeDischarge(owner: UUID, owned: Bool, powered: Bool?,
                          physicalConnection: Bool?, now: TimeInterval) throws {
        guard var next = record, next.owner == owner, next.phase == .discharging, owned else {
            throw BatteryControlError.conflict("自有断供状态未得到所有权及寄存器确认。")
        }
        try clock(now)
        if powered == false && !next.observedPowerOff { next.observedPowerOff = true; try checkpoint(next) }
        if physicalConnection == false { throw BatteryControlError.recovery("已确认适配器断开；正在恢复断供设置。") }
        if !next.observedPowerOff, now - (started ?? now) >= timeout {
            throw BatteryControlError.recovery("断供后未观察到实际供电变化；已停止并尝试恢复。")
        }
        if physicalConnection == nil || powered == nil {
            if unknownSince == nil { unknownSince = now }
            if now - unknownSince! >= timeout {
                throw BatteryControlError.recovery("断供期间物理连接持续未知；已停止并尝试恢复。")
            }
        } else { unknownSince = nil }
    }

    /// Restart has no in-memory start time and must restore, never resume a
    /// review cutoff. Invalid/backwards clocks cannot extend the trial deadline.
    func enforceDischargeDeadline(now: TimeInterval, maximum: TimeInterval) throws {
        guard record?.phase == .discharging else { return }
        guard let started, now.isFinite, maximum.isFinite, maximum > 0,
              now >= started, now - started < maximum else {
            throw BatteryControlError.recovery("有界放电观察期限已到，正在恢复原控制。")
        }
    }

    /// Call before writing cutoff0 or restoring the lease. Stronger release
    /// intent is sticky; heartbeats/cancel cannot postpone the deadline.
    func beginRecovery(owner: UUID, releasingLease: Bool, now: TimeInterval,
                       mayHaveApplied: Bool = true, requiresSupplyRecovery: Bool = true) throws {
        try clock(now)
        if let record, record.owner != owner { throw BatteryControlError.conflict("不能恢复其他实例的断供会话。") }
        if let current = record, current.phase != .discharging {
            if releasingLease && !current.releasingLease {
                var next = current; next.releasingLease = true
                try checkpoint(next); stableSince = nil
            }
            if restoringSince == nil { restoringSince = now }
            return
        }
        // Only the still-held lease can prove that this process never reached
        // a cutoff write intent. Never use a missing post-crash journal as proof.
        if requiresSupplyRecovery && !mayHaveApplied && record?.observedPowerOff != true { try checkpoint(nil); return }
        var next = record ?? .init(owner: owner, phase: .restoring)
        next.phase = .restoring; next.releasingLease = releasingLease
        next.requiresSupplyRecovery = record?.requiresSupplyRecovery ?? requiresSupplyRecovery
        try checkpoint(next); restoringSince = now; stableSince = nil
    }

    /// Requires a real off→on observation plus matching control reads. A
    /// register restored to0, an old AC=true or a selected target is insufficient.
    @discardableResult
    func observeRecovery(powered: Bool?, controlsMatch: Bool, now: TimeInterval) throws -> Bool {
        guard var next = record else { return true }
        guard next.phase != .discharging else { return false }
        try clock(now)
        if restoringSince == nil { restoringSince = now }
        if powered == false && !next.observedPowerOff { next.observedPowerOff = true; try checkpoint(next) }
        let supplyConfirmed = !next.requiresSupplyRecovery || (powered == true && (next.observedPowerOff || next.pausePulse != nil))
        if supplyConfirmed && controlsMatch {
            if stableSince == nil { stableSince = now }
            if now - stableSince! >= stableDuration { try checkpoint(nil); return true }
        } else { stableSince = nil }
        if now - restoringSince! >= timeout && next.phase != .attention {
            next.phase = .attention; try checkpoint(next)
        }
        return false
    }

    private func clock(_ now: TimeInterval) throws {
        guard now.isFinite, now >= 0 else { throw BatteryControlError.invalid("断供观察时钟无效。") }
        if record?.pausePulse != nil, let lastTime, now - lastTime > 5 { stableSince = nil }
        if let lastTime, now < lastTime {
            if record?.pausePulse != nil { throw BatteryControlError.recovery("短暂切换恢复时钟倒退，未确认恢复。") }
            stableSince = nil; unknownSince = nil; started = now; restoringSince = now
        }
        lastTime = now
    }
    private func checkpoint(_ next: Record?) throws { try save(next); record = next }
    #endif
}

/// Planning an inactive target must not acquire somebody else's cutoff. Raw
/// restore compatibility is separate from permission to start an override.
#if BATTERY_HELPER || DEBUG
enum BatteryCutoffTargets {
    static func validateRestoration(_ journal: BatteryOverrideLease.Journal) throws {
        guard ["CHIE", "CH0I", "CH0J"].allSatisfy({ journal.entries[$0].map { $0.original == 0 } ?? true }) else {
            throw BatteryControlError.recovery("历史日志的断供原值未证明属于本实例，已保留日志，不自动写回断供。")
        }
    }
    static func make(key: String?, forceDischarge: Bool, ownedKeys: Set<String>,
                     read: (String) throws -> Int) throws -> [String: Int] {
        guard let key else { return [:] }
        guard ["CHIE", "CH0I", "CH0J"].contains(key) else {
            throw BatteryControlError.invalid("未知断供键，未开始覆盖。")
        }
        if !ownedKeys.contains(key) {
            guard try read(key) == 0 else {
                throw BatteryControlError.conflict("适配器断供已被外部控制，未接管或覆盖。")
            }
            if !forceDischarge { return [:] }
        }
        return [key: forceDischarge ? (key == "CHIE" ? 8 : 1) : 0]
    }
}

/// Orders the cross-backend handoff without duplicating hardware originals.
/// This is helper-owned orchestration, never an XPC-supplied key list or bypass.
enum BatteryCutoffHandoff {
    /// Keep existing controls; only prepare the native backend here. Do not
    /// write cutoff until both the saved manual target and live registrations
    /// agree. A crash before arm is a normal native-preference restoration.
    static func prepareNative(lease: BatteryOverrideLease, owner: UUID, neutralTarget: Int = 100,
                              registrationsMatch: (BatteryOverrideLease.Journal) throws -> Bool) throws -> Bool {
        guard [85, 100].contains(neutralTarget) else { throw BatteryControlError.invalid("未支持的断供中和目标。") }
        guard let journal = lease.journal, journal.owner == owner else {
            throw BatteryControlError.conflict("断供准备缺少本实例租约。")
        }
        var targets = journal.entries.mapValues(\.expected)
        targets["nativeAPIEnabled"] = 1; targets["nativeAPILimit"] = neutralTarget
        try lease.apply(targets, owner: owner)
        guard let prepared = lease.journal else { throw BatteryControlError.recovery("断供准备日志缺失。") }
        return try registrationsMatch(prepared)
    }

    /// Release ONLY the owned cutoff first, leaving native MCL untouched until
    /// independent useful input and control readbacks are stable. Retained lease
    /// entries survive restart and failures. Restoring a lower original MCL is a
    /// later, separate registration check; it can legitimately drain the battery.
    static func recover(lease: BatteryOverrideLease, session: BatteryCutoffSession,
                        owner: UUID? = nil, now: TimeInterval, powered: () -> Bool?,
                        controlsMatch: (BatteryOverrideLease.Journal) throws -> Bool) throws -> Bool {
        guard session.recovering, let record = session.record, record.requiresSupplyRecovery,
              let journal = lease.journal, journal.owner == record.owner,
              owner == nil || owner == journal.owner else {
            throw BatteryControlError.recovery("断供交接缺少同一所有者的恢复记录。")
        }
        try BatteryCutoffTargets.validateRestoration(journal)
        // Preserve an off observation before clearing the cutoff, even when a
        // cancellation arrived before the ordinary discharge watchdog tick.
        if !record.observedPowerOff {
            _ = try session.observeRecovery(powered: powered(), controlsMatch: false, now: now)
        }
        try lease.restore(keys: ["CHIE", "CH0I", "CH0J"], owner: record.owner)
        guard let restored = lease.journal else { throw BatteryControlError.recovery("断供恢复日志缺失。") }
        return try session.observeRecovery(powered: powered(),
            controlsMatch: controlsMatch(restored), now: now)
    }
}

#endif
