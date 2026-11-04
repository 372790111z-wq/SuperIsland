import Foundation

#if BATTERY_HELPER || DEBUG

/// Durable compare-and-restore transaction, independent of IOKit and XPC.
/// Save intent BEFORE each write, so a crash between write and acknowledgement
/// leaves enough information to undo only changes still owned by this helper.
final class BatteryOverrideLease {
    struct Entry: Codable, Equatable {
        var original: Int
        var expected: Int
        // Until readback AND its checkpoint are durable, hardware can still
        // contain the previous acknowledged value or the new intended one.
        var prior: Int?
    }
    struct Journal: Codable, Equatable {
        var owner: UUID
        var entries: [String: Entry]
        var schemaVersion: Int? = 3
        var preferences: BatteryPreferencesLease.Record?
        var detachedExitHold: Bool?
    }
    private(set) var journal: Journal?
    private(set) var expires: TimeInterval = 0
    private let read: (String) throws -> Int
    private let write: (String, Int) throws -> Void
    private let save: (Journal?) throws -> Void
    var preferencesIO: BatteryPreferencesLease.IO?
    var confirmPreferences: ((BatteryPreferencesLease.Record) throws -> Bool)?

    init(journal: Journal? = nil, read: @escaping (String) throws -> Int,
         write: @escaping (String, Int) throws -> Void, save: @escaping (Journal?) throws -> Void) {
        self.journal = journal; self.read = read; self.write = write; self.save = save
    }
    func renew(owner: UUID, now: TimeInterval) throws {
        if let journal, journal.owner != owner { throw BatteryControlError.conflict("已有其他SuperIsland实例持有控制。") }
        if journal == nil {
            let created = Journal(owner: owner, entries: [:]); try save(created); journal = created
        }
        expires = now + 45
    }
    func apply(_ targets: [String: Int], owner: UUID) throws {
        guard var next = journal, next.owner == owner else { throw BatteryControlError.conflict("没有本次控制租约。") }
        // A removed preference restores only the register it previously owned.
        for key in next.entries.keys.sorted() where targets[key] == nil {
            let entry = next.entries[key]!
            if ([2, 3, 4].contains(next.schemaVersion ?? 0)) && entry.original == entry.expected && entry.prior == nil {
                next.entries.removeValue(forKey: key); try save(next); journal = next; continue
            }
            let actual = try read(key)
            guard actual == entry.expected || actual == entry.prior || actual == entry.original else {
                throw BatteryControlError.conflict("\(key)已被外部修改，不能恢复。")
            }
            if actual == entry.expected || actual == entry.prior { try write(key, entry.original) }
            guard try read(key) == entry.original else { throw BatteryControlError.recovery("\(key)恢复读回失败。") }
            next.entries.removeValue(forKey: key); try save(next); journal = next
        }
        for key in targets.keys.sorted() {
            let desired = targets[key]!, actual = try read(key)
            if next.entries[key]?.prior != nil { throw BatteryControlError.recovery("\(key)上次写入尚未确认，需先恢复。") }
            if let previous = next.entries[key], actual != previous.expected {
                throw BatteryControlError.conflict("\(key)已被其他控制方修改；停止写入并保留恢复记录。")
            }
            if let previous = next.entries[key], previous.expected == desired { continue }
            let original = next.entries[key]?.original ?? actual
            next.entries[key] = Entry(original: original, expected: desired, prior: actual == desired ? nil : actual)
            try save(next); journal = next
            if actual == desired { continue }
            try write(key, desired)
            guard try read(key) == desired else { throw BatteryControlError.recovery("\(key)读回不一致。") }
            next.entries[key]?.prior = nil
            try save(next); journal = next
        }
    }
    /// The durable original and write intent already authorize restoration.
    /// Never require a NEW disk checkpoint before releasing an owned CHIE8.
    /// This is also the first startup/exit action after loading a valid lease.
    func releaseCHIEImmediately(owner: UUID? = nil) throws {
        guard var next = journal, let entry = next.entries["CHIE"] else { return }
        guard owner == nil || next.owner == owner, entry.original == 0 else {
            throw BatteryControlError.recovery("断供原值或所有者未确认，不能自动写回。")
        }
        let actual = try read("CHIE")
        guard actual == 0 || (actual == 8 && (entry.expected == 8 || entry.prior == 8)) else {
            throw BatteryControlError.conflict("断供值已被外部改变，保留恢复责任。")
        }
        if actual == 8 { try write("CHIE", 0) }
        guard try read("CHIE") == 0 else { throw BatteryControlError.recovery("断供释放尚未读回0。") }
        if entry.expected == 0 && entry.prior == nil { return }
        next.entries["CHIE"] = .init(original: 0, expected: 0)
        try save(next); journal = next
    }

    /// Sealed review orchestrator only. No disk operations or sensor queries
    /// between the two writes. The clock includes the write8 call itself.
    /// A stalled OS call cannot be made hard realtime; >1s is a failed trial.
    func pulseCHIE(owner: UUID, admit: () throws -> Void,
                   now: () -> TimeInterval, wait: (TimeInterval) -> Void,
                   writePulse: ((Int) throws -> Void)? = nil) throws -> TimeInterval {
        let writePulse = writePulse ?? { try self.write("CHIE", $0) }
        guard var next = journal, next.owner == owner, next.entries["CHIE"] == nil,
              try read("CHIE") == 0 else {
            throw BatteryControlError.conflict("短暂切换要求未被占用的CHIE0及当前租约。")
        }
        next.entries["CHIE"] = .init(original: 0, expected: 8, prior: 0)
        try save(next); journal = next
        var problem: Error?
        let start = now()
        var pulseElapsed: TimeInterval = 0
        do {
            try admit()
            guard start.isFinite, start >= 0 else {
                throw BatteryControlError.recovery("短暂切换租约或时钟无效。")
            }
            // Admission is allowed to read. Start the pulse clock AFTER it.
            let began = now()
            guard began.isFinite, began >= start else {
                throw BatteryControlError.recovery("短暂切换开始前租约或时钟改变。")
            }
            var writeError: Error?
            do { try writePulse(8) } catch { writeError = error }
            if writeError == nil {
                let elapsed = now() - began
                if elapsed.isFinite, elapsed >= 0, elapsed < 0.5 { wait(0.5 - elapsed) }
            }
            // Release even when write8 reached hardware but lost its reply.
            // No read/save may delay this known original-value write.
            try writePulse(0)
            let elapsed = now() - began
            pulseElapsed = elapsed
            if let writeError { throw writeError }
            guard elapsed.isFinite, elapsed >= 0.5, elapsed <= 1 else {
                throw BatteryControlError.recovery("供电切换实际耗时超出候选边界，未判定通过。")
            }
        } catch { problem = error }
        // Reconcile/readback/checkpoint only AFTER the immediate release.
        // This retry is also required if the release reply itself was lost.
        do { try releaseCHIEImmediately(owner: owner) }
        catch { throw BatteryControlError.recovery("短暂切换释放未确认：\(error.localizedDescription)") }
        if let problem { throw problem }
        return pulseElapsed
    }

    func applyPreferences(target: Int, owner: UUID, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        guard let current = journal, current.owner == owner, current.detachedExitHold != true, let io = preferencesIO,
              current.entries.keys.allSatisfy({ !$0.hasPrefix("native") }) else {
            throw BatteryControlError.recovery("偏好控制缺少同一所有者租约或仍有旧后端恢复责任。")
        }
        func admit() throws {
            guard self.journal?.owner == owner, now().isFinite, now() < self.expires else {
                throw BatteryControlError.recovery("偏好控制租约已过期，未提交新写入。")
            }
        }
        try admit()
        let record: BatteryPreferencesLease.Record
        if let existing = current.preferences { record = existing }
        else {
            record = try BatteryPreferencesLease.begin(snapshot: io.snapshot(), target: target)
            try checkpointPreferences(record)
        }
        _ = try BatteryPreferencesLease.apply(record, target: target, io: io, save: checkpointPreferences, admit: admit)
    }
    func detachExitHold(owner: UUID, confirmed: Bool) throws {
        guard var next = journal, next.owner == owner, next.schemaVersion == 4,
              next.entries.isEmpty, next.preferences?.phase == .active,
              next.preferences?.prior.isEmpty == true, confirmed else {
            throw BatteryControlError.recovery("退出暂停尚未确认，未移交持续目标。")
        }
        next.detachedExitHold = true
        try save(next); journal = next
    }
    private func checkpointPreferences(_ record: BatteryPreferencesLease.Record) throws {
        guard var next = journal else { throw BatteryControlError.recovery("偏好恢复缺少租约。") }
        next.schemaVersion = 4; next.preferences = record
        if record.phase != .active { next.detachedExitHold = nil }
        try save(next); journal = next
    }
    /// Restore only selected controls, retaining every original and ownership
    /// checkpoint. Cutoff recovery uses this before touching the native limit.
    func restore(keys: Set<String>, owner: UUID? = nil) throws {
        try restoreEntries(keys: keys, owner: owner, retain: true)
    }
    @discardableResult
    func release(owner: UUID? = nil, verifyRestoration: ((Journal) throws -> Bool)? = nil) throws -> Bool {
        guard let current = journal else { return true }
        if let owner, owner != current.owner { throw BatteryControlError.conflict("不能释放其他实例的控制。") }
        if let preferences = current.preferences {
            guard let io = preferencesIO else { throw BatteryControlError.recovery("当前设备无法恢复已保存的带类型偏好，恢复记录已保留。") }
            _ = try BatteryPreferencesLease.restore(preferences, io: io, save: checkpointPreferences)
        }
        try restoreEntries(keys: Set(current.entries.keys), owner: owner, retain: verifyRestoration != nil)
        if let preferences = journal?.preferences {
            guard let confirmPreferences, try confirmPreferences(preferences) else { return false }
        }
        guard let remaining = journal else { return true }
        // Originals and ownership stay durable while physical supply or native
        // registration is still pending. Retries never rewrite restored values.
        if let verifyRestoration, try !verifyRestoration(remaining) { return false }
        try save(nil); journal = nil; expires = 0
        return true
    }
    private func restoreEntries(keys: Set<String>, owner: UUID?, retain: Bool) throws {
        guard var remaining = journal else { return }
        if let owner, owner != remaining.owner { throw BatteryControlError.conflict("不能释放其他实例的控制。") }
        var failures: [String] = []
        for key in keys.sorted().reversed() {
            guard let entry = remaining.entries[key] else { continue }
            var stage = "读取当前值"
            do {
                if ([2, 3, 4].contains(remaining.schemaVersion ?? 0)) && entry.original == entry.expected && entry.prior == nil {
                    if !retain {
                        var next = remaining
                        next.entries.removeValue(forKey: key)
                        stage = "保存恢复记录"
                        try save(next); remaining = next; journal = next
                    } else if try read(key) != entry.original {
                        throw BatteryControlError.conflict("恢复后的值已被外部修改")
                    }
                    continue
                }
                let actual = try read(key)
                if actual == entry.original {
                    // The previous restore may have reached hardware before
                    // its acknowledgement became durable. Do not rewrite it.
                } else if actual == entry.expected || actual == entry.prior {
                    if retain {
                        var next = remaining
                        next.entries[key] = Entry(original: entry.original, expected: entry.original, prior: actual)
                        stage = "保存恢复意图"
                        try save(next); remaining = next; journal = next
                    }
                    stage = "写回原值"
                    try write(key, entry.original)
                    stage = "读取恢复结果"
                    guard try read(key) == entry.original else { throw BatteryControlError.recovery("读回失败") }
                } else {
                    throw BatteryControlError.conflict("外部值已变化")
                }
                var next = remaining
                if !retain { next.entries.removeValue(forKey: key) }
                else { next.entries[key] = Entry(original: entry.original, expected: entry.original, prior: nil) }
                stage = "保存恢复结果"
                try save(next); remaining = next; journal = next
            } catch {
                // An unreadable value is unknown, never evidence of another
                // controller. Keep the last durable entry on checkpoint failure.
                if case BatteryControlError.conflict = error {
                    failures.append("\(key)：已确认外部值变化，未覆盖")
                } else {
                    failures.append("\(key)：\(stage)失败（\(error.localizedDescription)），尚未确认恢复")
                }
            }
        }
        guard failures.isEmpty else { throw BatteryControlError.recovery("待恢复：\(failures.sorted().joined(separator: "；"))。恢复记录已保留。") }
    }
    func expire(now: TimeInterval) throws {
        if journal != nil, journal?.detachedExitHold != true, now >= expires { try release() }
    }
}

#endif
