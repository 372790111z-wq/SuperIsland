import Foundation

#if BATTERY_HELPER || DEBUG
/// Typed subtransaction of the ordinary lease. It has no independent owner,
/// timer or file. Every mutation is preceded by the parent's durable checkpoint.
enum BatteryPreferencesLease {
    typealias Key = BatteryPreferenceTypes.Key
    typealias Value = BatteryPreferenceTypes.Value
    typealias Snapshot = [Key: Value]
    enum Phase: String, Codable { case prepared, applying, signalIntent, active, restoring, restoreSignalIntent, awaitingConfirmation }
    struct Record: Codable, Equatable {
        var original: Snapshot
        var expected: Snapshot
        var prior: Snapshot = [:]
        var guards: Snapshot
        var phase: Phase = .prepared
        var target: Int
    }
    struct IO {
        var snapshot: () throws -> Snapshot
        var write: (Key, Value, Value, Snapshot, Bool) throws -> Void
        var signal: (Snapshot, Snapshot, Bool) throws -> Void
        var requiresExplicitMCLBaseline = false
    }
    static func plannedTarget(_ decision: BatteryControlDecision, currentLevel: Int, calibrating: Bool) throws -> Int {
        guard (0...100).contains(currentLevel) else { throw failure() }
        let target = decision.protectiveHold ? (decision.nativeHoldTarget ?? currentLevel)
            : decision.forceDischarge ? decision.target : decision.nativeTarget(currentLevel: currentLevel)
        guard (20...100).contains(target) || (calibrating && target == 10)
            || (decision.protectiveHold && (1...100).contains(target)) else { throw failure() }
        return target
    }
    static func validate(_ record: Record) throws {
        guard (1...100).contains(record.target), Set(record.original.keys) == Set(Key.direct),
              Set(record.expected.keys) == Set(Key.direct), Set(record.guards.keys) == Set(Key.guards),
              Set(record.prior.keys).isSubset(of: Set(Key.direct)),
              record.guards[.initialChargeLimitSetDate]?.numeric != nil else { throw failure() }
        for key in Key.guards where key != .initialChargeLimitSetDate {
            guard record.guards[key] == .absent else { throw failure() }
        }
        for values in [record.original, record.expected, record.prior, record.guards] {
            for (key, value) in values { try validate(value, key: key) }
        }
    }
    static func validate(_ value: Value, key: Key) throws {
        try value.validate()
        switch key {
        case .mclLimitValue:
            guard value == .absent || value.numeric.map({ $0.rounded() == $0 && (1...100).contains($0) }) == true else { throw failure() }
        case .mclFeatureState, .isEngaged, .isManuallyChargeLimited:
            guard value == .absent || value == .bool(true) || value == .bool(false) || value.numeric == 0 || value.numeric == 1 else { throw failure() }
        case .mclTempDisabledUntilDate:
            guard value == .absent else { throw failure() }
        default: break
        }
    }
    /// On newer PowerUI, removing these keys retains cached values. Without
    /// explicit originals neither normalization nor absence proves restoration.
    /// Keep this separate from schema validation so old journals stay readable.
    static func validateReloadBaseline(_ original: Snapshot, requiresExplicitMCLBaseline: Bool) throws {
        guard requiresExplicitMCLBaseline else { return }
        guard let state = original[.mclFeatureState], state != .absent,
              let limit = original[.mclLimitValue], limit != .absent else {
            throw BatteryControlError.recovery("当前macOS需要明确的原始充电开关和上限；缺失值不能作为可恢复的基线，原设置和恢复记录已保留。")
        }
        try validate(state, key: .mclFeatureState)
        try validate(limit, key: .mclLimitValue)
    }
    static func begin(snapshot: Snapshot, target: Int, requiresExplicitMCLBaseline: Bool = false) throws -> Record {
        try validateReloadBaseline(snapshot, requiresExplicitMCLBaseline: requiresExplicitMCLBaseline)
        guard Set(snapshot.keys) == Set(Key.allCases) else { throw failure() }
        let originals = Dictionary(uniqueKeysWithValues: Key.direct.map { ($0, snapshot[$0]!) })
        let guards = Dictionary(uniqueKeysWithValues: Key.guards.map { ($0, snapshot[$0]!) })
        let record = Record(original: originals, expected: originals, guards: guards, target: target)
        try validate(record)
        // An enabled limit must be interpretable; disabled/absent baselines are
        // preserved exactly and restored without normalizing absence to zero.
        if enabled(snapshot[.mclFeatureState]) == true, snapshot[.mclLimitValue]?.numeric == nil { throw failure() }
        return record
    }
    static func enabled(_ value: Value?) -> Bool? {
        guard let value else { return nil }
        if value == .absent || value == .bool(false) || value.numeric == 0 { return false }
        if value == .bool(true) || value.numeric == 1 { return true }
        return nil
    }
    static func desired(_ key: Key, target: Int, original: Value) -> Value {
        switch key {
        case .mclLimitValue: return .integer(Int64(target))
        case .mclFeatureState, .isEngaged, .isManuallyChargeLimited:
            if case .bool = original { return .bool(true) }
            if case .real = original { return .real(1) }
            return .integer(1)
        default: return .absent
        }
    }
    static func checkGuards(_ snapshot: Snapshot, _ record: Record) throws {
        guard record.guards.allSatisfy({ snapshot[$0.key] == $0.value }) else {
            throw BatteryControlError.conflict("系统临时充电覆盖发生变化，保留恢复责任。")
        }
    }
    /// Repeated targets retain the first baseline. A failed/pending operation
    /// is restore-only; renewing the lease cannot legitimize a partial apply.
    static func apply(_ initial: Record, target: Int, io: IO,
                      save: (Record) throws -> Void, admit: () throws -> Void) throws -> Record {
        try validate(initial)
        try validateReloadBaseline(initial.original, requiresExplicitMCLBaseline: io.requiresExplicitMCLBaseline)
        guard (1...100).contains(target), [.prepared, .active].contains(initial.phase), initial.prior.isEmpty else { throw failure() }
        var next = initial
        var snapshot = try io.snapshot(); try checkGuards(snapshot, next)
        let admitted = snapshot
        var externallyChanged = false
        for key in Key.direct where !key.derived {
            guard let actual = snapshot[key] else { throw failure() }
            try validate(actual, key: key)
            if actual != next.expected[key] {
                guard next.phase == .active else { throw BatteryControlError.conflict("首次写入前电池偏好已变化。") }
                externallyChanged = true
            }
        }
        if enabled(snapshot[.mclFeatureState]) == true && snapshot[.mclLimitValue]?.numeric == nil { throw failure() }
        // While explicitly enabled, the user's application policy has priority
        // over a legal system slider change. Preserve the FIRST baseline; only
        // this active apply path may reassert. Recovery remains compare-only.
        if next.phase == .active && next.target == target && !externallyChanged { return next }
        next.target = target
        for key in Key.direct {
            try admit()
            snapshot = try io.snapshot(); try checkGuards(snapshot, next)
            guard let current = snapshot[key] else { throw failure() }
            if !key.derived, current != next.expected[key] && current != admitted[key] {
                throw BatteryControlError.conflict("写入期间电池偏好再次变化，未追逐外部控制。")
            }
            let value = desired(key, target: target, original: next.original[key]!)
            next.phase = .applying
            next.expected[key] = value; next.prior[key] = current
            try save(next); try admit()
            if current != value { try io.write(key, value, current, next.guards, false) }
            guard try io.snapshot()[key] == value else { throw failure() }
            next.prior.removeValue(forKey: key); try save(next)
        }
        try admit(); next.phase = .signalIntent; try save(next); try admit()
        try io.signal(next.expected, next.guards, false)
        next.phase = .active; try save(next)
        return next
    }
    static func restore(_ initial: Record, io: IO, save: (Record) throws -> Void) throws -> Record {
        try validate(initial)
        try validateReloadBaseline(initial.original, requiresExplicitMCLBaseline: io.requiresExplicitMCLBaseline)
        if initial.phase == .awaitingConfirmation { return initial }
        var next = initial; next.phase = .restoring; try save(next)
        for key in Key.restoration {
            let snapshot = try io.snapshot(); try checkGuards(snapshot, next)
            guard let actual = snapshot[key], let original = next.original[key] else { throw failure() }
            if key.derived && actual != next.expected[key] && actual != next.prior[key] {
                // System timelines are independently recomputed. Never rewind
                // a newer derived value to an old checkpoint.
                next.expected[key] = actual; next.prior.removeValue(forKey: key); try save(next); continue
            }
            guard actual == original || actual == next.expected[key] || actual == next.prior[key] else {
                throw BatteryControlError.conflict("电池偏好恢复遇到外部修改，原始快照已保留。")
            }
            next.prior[key] = actual; next.expected[key] = original; try save(next)
            if actual != original { try io.write(key, original, actual, next.guards, true) }
            guard try io.snapshot()[key] == original else { throw failure() }
            next.prior.removeValue(forKey: key); try save(next)
        }
        next.phase = .restoreSignalIntent; try save(next)
        try io.signal(next.expected, next.guards, true)
        next.phase = .awaitingConfirmation; try save(next)
        return next
    }
    /// Active target acceptance is deliberately separate from original-state
    /// restoration; neither can stand in for the other.
    static func activeMatches(_ record: Record, snapshot: Snapshot, target: Int,
                              registrations: Set<Int>?) throws -> Bool {
        try validate(record); try checkGuards(snapshot, record)
        return record.phase == .active && record.prior.isEmpty && record.target == target
            && Key.direct.filter { !$0.derived }.allSatisfy { snapshot[$0] == record.expected[$0] }
            && registrations == [target]
    }
    static func restored(_ record: Record, snapshot: Snapshot, registrations: Set<Int>?, requiresExplicitMCLBaseline: Bool = false) throws -> Bool {
        try validate(record)
        try validateReloadBaseline(record.original, requiresExplicitMCLBaseline: requiresExplicitMCLBaseline)
        try checkGuards(snapshot, record)
        guard record.phase == .awaitingConfirmation, record.prior.isEmpty,
              Key.direct.filter({ !$0.derived }).allSatisfy({ snapshot[$0] == record.original[$0] }),
              let registrations else { return false }
        if enabled(record.original[.mclFeatureState]) == false { return registrations.isEmpty || registrations == [100] }
        guard let limit = record.original[.mclLimitValue]?.numeric else { return false }
        return registrations == [Int(limit)]
    }
    private static func failure() -> BatteryControlError { .recovery("带类型电池偏好事务未确认，保留恢复责任。") }
}
#endif
