import Foundation

#if (BATTERY_HELPER && BATTERY_REVIEW) || DEBUG
/// A fixed review-only preference transaction. All I/O is injected and must be
/// serialized by its owner. CFPreferences offers no atomic compare-and-swap:
/// comparison, inspection and restoration still have an external TOCTOU window.
final class BatteryPreferences79Transaction {
    static let controlDuration: TimeInterval = 180
    static let observationDuration: TimeInterval = 150
    typealias Key = BatteryPreferenceTypes.Key
    typealias Value = BatteryPreferenceTypes.Value
    struct Observation: Codable, Equatable {
        var nativeLimit: Int?
        var nativeEnabled: Int?
        var registrations: [Int]
        var level: Double
        var adapterPresent: Bool
        var batteryCurrent: Double
        var adapterPower: Double
        var wallDate: Date
        var competingController = false
        var calibrationActive = false
        // Root CurrentUser/AnyHost preferences, separately attributed from
        // native getter results. Nil remains unknown in legacy observations.
        var rawPreferenceLimit: Int?
        var rawPreferenceEnabled: Int?
    }
    enum Ack: String, Codable {
        case untouched, writeIntent, applied, restoreIntent, restored, derivedRecomputed, conflict
    }
    struct Entry: Codable, Equatable {
        var key: Key
        var original: Value
        var expected: Value
        var prior: Value?
        var ack = Ack.untouched
    }
    enum Phase: String, Codable {
        case admissionPending, admissionIntent, prepared, applying, applySignalIntent, active, restoring, restoreSignalIntent, awaitingConfirmation, blocked
    }
    struct Record: Codable, Equatable {
        var schema = 2
        var owner: UUID
        var bootID: String
        var startedContinuous: TimeInterval
        var deadlineContinuous: TimeInterval
        var initialObservation: Observation
        var admittedObservation: Observation?
        var entries: [Entry]
        var guards: [Key: Value]
        var modeOfOperation: Value
        var phase = Phase.prepared
        var mutationOutcomeUnknown = false
        var observationPending = false
    }
    enum Failure: LocalizedError, Equatable {
        case invalid, busy, missing, restoreOnly, alreadyApplied, expired, foreignBoot, unconfirmed
        /// Trusted in-process proof that this entire mutation closure submitted
        /// no child. Never reconstruct this case from an XPC/worker response.
        case notSubmitted
        case conflict([Key])
        case invalidOriginal(Key)
        var errorDescription: String? {
            switch self {
            case .invalid: return "79%验证条件、数值类型或恢复记录不符合固定规则；未提交本步。"
            case .invalidOriginal(let key): return "原始电池偏好不符合固定79%验证规则：" + key.rawValue + "；未提交本步偏好写入。"
            case .busy: return "已有验证记录或恢复责任，未启动新的79%事务。"
            case .missing: return "缺少持久化验证记录，未执行偏好写入。"
            case .restoreOnly: return "重新加载的验证记录只允许恢复原设置，不能继续设置79%。"
            case .alreadyApplied: return "本次79%事务已尝试执行；不会重复写入或延长时限。"
            case .expired: return "79%验证时限已到或连续时钟异常；停止新写入并保留恢复责任。"
            case .foreignBoot: return "系统启动标识已变化；本次记录只允许恢复原设置。"
            case .unconfirmed: return "原设置恢复尚未得到独立确认，保留验证记录。"
            case .notSubmitted: return "本步尚未提交变更子进程，已停止后续79%写入并保留恢复责任。"
            case .conflict(let keys): return "检测到外部或系统修改，未覆盖这些偏好：" + keys.map(\.rawValue).joined(separator: "、") + "；保留恢复记录。"
            }
        }
    }

    private(set) var record: Record?
    /// A failed uncertainty-marker save leaves the last durable pending intent
    /// in record. This property also exposes the in-process sticky responsibility.
    var mutationOutcomeUnknown: Bool { uncertain || record?.mutationOutcomeUnknown == true }
    private let read: (Key) throws -> Value
    private let write: (Key, Value) throws -> Void
    private let save: (Record?) throws -> Void
    private let signal: () throws -> Void
    private let inspect: () throws -> Observation
    private let continuousNow: () -> TimeInterval
    private let recoveryOnly: Bool
    private var applyStarted = false
    private var uncertain = false
    private var observing = false

    init(record: Record? = nil, read: @escaping (Key) throws -> Value,
         write: @escaping (Key, Value) throws -> Void, save: @escaping (Record?) throws -> Void,
         signal: @escaping () throws -> Void, inspect: @escaping () throws -> Observation,
         continuousNow: @escaping () -> TimeInterval) throws {
        self.record = record; self.read = read; self.write = write; self.save = save
        self.signal = signal; self.inspect = inspect; self.continuousNow = continuousNow; recoveryOnly = record != nil
        if let record {
            try Self.validate(record)
            if record.entries.contains(where: { $0.ack == .writeIntent || $0.ack == .restoreIntent })
                || record.phase == .applySignalIntent || record.phase == .restoreSignalIntent
                || record.phase == .admissionIntent || record.observationPending {
                uncertain = true
                try persist(record)
            }
        }
    }

    @discardableResult
    /// Fake/compatibility entry only. Production must journal pure admission
    /// before invoking any PowerUI getter; use prepareAdmission instead.
    func prepare(owner: UUID, bootID: String, now: TimeInterval, observation: Observation) throws -> Record {
        try prepareRecord(owner: owner, bootID: bootID, now: now, observation: observation, admission: false)
    }
    @discardableResult
    func prepareAdmission(owner: UUID, bootID: String, now: TimeInterval, observation: Observation) throws -> Record {
        try prepareRecord(owner: owner, bootID: bootID, now: now, observation: observation, admission: true)
    }
    private func prepareRecord(owner: UUID, bootID: String, now: TimeInterval, observation: Observation, admission: Bool) throws -> Record {
        guard record == nil, !recoveryOnly, !applyStarted else { throw Failure.busy }
        try Self.validateClock(bootID, now)
        if admission { try Self.validateAdmission(observation) }
        else { try Self.validate(observation, preparing: true, restoring: false) }
        var values: [Key: Value] = [:]
        for key in Key.allCases { let value = try read(key); try value.validate(); values[key] = value }
        try Self.validateOriginals(values)
        let entries = Key.direct.map { key in Entry(key: key, original: values[key]!, expected: Self.desired(key, original: values[key]!)) }
        var next = Record(owner: owner, bootID: bootID, startedContinuous: now, deadlineContinuous: now + Self.controlDuration,
                          initialObservation: observation,
                          entries: entries, guards: Dictionary(uniqueKeysWithValues: Key.guards.map { ($0, values[$0]!) }),
                          modeOfOperation: values[.modeOfOperation]!)
        if admission { next.phase = .admissionPending }
        try Self.validate(next); try persist(next)
        return record!
    }

    func confirmAdmission(bootID: String, now: TimeInterval) throws {
        guard !recoveryOnly else { throw Failure.restoreOnly }
        let initial = try required()
        guard initial.phase == .admissionPending, !observing, !applyStarted else { throw Failure.busy }
        try Self.validateClock(bootID, now)
        guard bootID == initial.bootID else { throw Failure.foreignBoot }
        guard now >= initial.startedContinuous, now < initial.deadlineContinuous else { throw Failure.expired }
        try checkDeadline()
        try checkPreferences(restoring: false)
        var next = initial; next.phase = .admissionIntent; try persist(next)
        do { try checkDeadline() } catch { try rollbackUnsubmitted(initial, error: error) }
        observing = true; defer { observing = false }
        do {
            let observed = try inspect()
            try Self.validate(observed, preparing: true, restoring: false)
            guard observed.adapterPower > 1 else { throw Failure.invalid }
            for entry in initial.entries {
                guard try read(entry.key) == entry.original else { throw Failure.conflict([entry.key]) }
            }
            try checkPreferences(restoring: false); try checkDeadline()
            next = try required(); next.admittedObservation = observed; next.phase = .prepared
            try persist(next)
        } catch { markUncertain(); throw error }
    }

    func apply(bootID: String, now: TimeInterval) throws {
        guard !recoveryOnly else { throw Failure.restoreOnly }
        guard !applyStarted else { throw Failure.alreadyApplied }
        applyStarted = true
        let initial = try required()
        guard initial.phase == .prepared else { throw Failure.alreadyApplied }
        try Self.validateClock(bootID, now)
        guard bootID == initial.bootID else { throw Failure.foreignBoot }
        guard now >= initial.startedContinuous, now < initial.deadlineContinuous else { throw Failure.expired }
        for key in Key.direct {
            try inspectBeforeMutation(restoring: false)
            let entry = try entry(key)
            guard try read(key) == entry.original else { throw Failure.conflict([key]) }
            let beforeIntent = try required()
            var next = beforeIntent
            let index = try index(key)
            next.phase = .applying; next.entries[index].prior = entry.original; next.entries[index].ack = .writeIntent
            try persist(next)
            do { try checkDeadline() } catch { try rollbackUnsubmitted(beforeIntent, error: error) }
            do { try write(key, entry.expected) }
            catch { try mutationFailed(error, beforeIntent: beforeIntent) }
            next = try required(); next.entries[index].ack = .applied
            try acknowledge(next)
        }
        try inspectBeforeMutation(restoring: false)
        let beforeSignal = try required()
        var next = try required(); next.phase = .applySignalIntent; try persist(next)
        do { try checkDeadline() } catch { try rollbackUnsubmitted(beforeSignal, error: error) }
        do { try signal() } catch { try mutationFailed(error, beforeIntent: beforeSignal) }
        next = try required(); next.phase = .active; try acknowledge(next)
    }

    /// Compare-and-restore is deliberately not called CAS: another process can
    /// change CFPreferences after either the comparison or the fresh inspection.
    func restore(bootID: String, now: TimeInterval) throws {
        try Self.validateClock(bootID, now)
        var next = try required()
        if next.phase == .awaitingConfirmation { return }
        next.phase = .restoring; try persist(next)
        var conflicts: [Key] = []
        for key in Key.restoration {
            try inspectBeforeMutation(restoring: true)
            let current = try read(key), old = try entry(key), index = try index(key)
            try current.validate()
            next = try required()
            if current == old.original {
                next.entries[index].ack = .restored
                try persist(next); continue
            }
            let hadIntent = [Ack.writeIntent, .applied, .restoreIntent].contains(old.ack)
            if key.derived, current != old.expected || !hadIntent {
                next.entries[index].prior = current; next.entries[index].ack = .derivedRecomputed
                try persist(next); continue
            }
            guard hadIntent, current == old.expected else {
                next.entries[index].prior = current; next.entries[index].ack = .conflict
                try persist(next); conflicts.append(key); continue
            }
            let beforeIntent = next
            next.entries[index].prior = current; next.entries[index].ack = .restoreIntent
            try persist(next)
            do { try write(key, old.original) }
            catch { try mutationFailed(error, beforeIntent: beforeIntent) }
            next = try required(); next.entries[index].ack = .restored
            try acknowledge(next)
        }
        try inspectBeforeMutation(restoring: true)
        next = try required()
        for index in next.entries.indices where !next.entries[index].key.derived {
            let key = next.entries[index].key, value = try read(key)
            try value.validate()
            if value != next.entries[index].original {
                next.entries[index].prior = value; next.entries[index].ack = .conflict
                if !conflicts.contains(key) { conflicts.append(key) }
            }
        }
        if !conflicts.isEmpty {
            next.phase = .blocked; try persist(next)
            throw Failure.conflict(conflicts)
        }
        let beforeSignal = try required()
        next = beforeSignal; next.phase = .restoreSignalIntent; try persist(next)
        do { try signal() } catch { try mutationFailed(error, beforeIntent: beforeSignal) }
        next = try required(); next.phase = .awaitingConfirmation; try acknowledge(next)
    }

    /// Validation is supplied by the independent physical/native/registration
    /// checker. It cannot clear an unacknowledged or timed-out mutation.
    @discardableResult
    func finishRestoration(validated: Bool) throws -> Bool {
        guard validated else { return false }
        let current = try required()
        guard current.phase == .awaitingConfirmation else { throw Failure.unconfirmed }
        guard !mutationOutcomeUnknown else { return false }
        let observed = try inspectBeforeMutation(restoring: true)
        guard observed.nativeLimit == 80, observed.nativeEnabled == 1,
              Set(observed.registrations) == Set([80]), observed.adapterPresent,
              observed.adapterPower > 1, observed.batteryCurrent >= -0.05 else { throw Failure.unconfirmed }
        let changed = try current.entries.filter { entry in
            guard !entry.key.derived else { return false }
            return try read(entry.key) != entry.original
        }.map(\.key)
        guard changed.isEmpty else { throw Failure.conflict(changed) }
        try save(nil); record = nil
        return true
    }

    @discardableResult
    private func inspectBeforeMutation(restoring: Bool) throws -> Observation {
        try observeInternal(restoring: restoring, mutation: true)
    }
    /// Read-only policy permits a known target-reached/unplugged sample so the
    /// caller can restore. It never widens apply's control-write admission.
    func observe(restoring: Bool) throws -> Observation {
        guard !recoveryOnly || restoring else { throw Failure.restoreOnly }
        return try observeInternal(restoring: restoring, mutation: false)
    }
    private func observeInternal(restoring: Bool, mutation: Bool) throws -> Observation {
        guard !observing else { throw Failure.busy }
        try checkPreferences(restoring: restoring)
        if !restoring { try checkDeadline() }
        let beforeIntent = try required()
        var next = beforeIntent; next.observationPending = true; try persist(next)
        if !restoring {
            do { try checkDeadline() } catch { try rollbackUnsubmitted(beforeIntent, error: error) }
        }
        observing = true; defer { observing = false }
        do {
            let observed = try inspect()
            try Self.validate(observed, preparing: false, restoring: restoring || !mutation)
            try checkPreferences(restoring: restoring)
            if !restoring { try checkDeadline() }
            next = try required(); next.observationPending = false; try persist(next)
            return observed
        } catch { markUncertain(); throw error }
    }
    private func checkPreferences(restoring: Bool) throws {
        let current = try required()
        for key in Key.guards {
            guard try read(key) == current.guards[key] else { throw Failure.conflict([key]) }
        }
        if !restoring {
            for entry in current.entries where !entry.key.derived {
                let expected = entry.ack == .untouched ? entry.original : entry.expected
                guard entry.ack == .untouched || entry.ack == .applied,
                      try read(entry.key) == expected else { throw Failure.conflict([entry.key]) }
            }
        }
    }
    private func checkDeadline() throws {
        let current = try required(), now = continuousNow()
        guard now.isFinite, now >= current.startedContinuous, now < current.deadlineContinuous else { throw Failure.expired }
    }
    private func persist(_ next: Record) throws {
        var next = next
        next.mutationOutcomeUnknown = next.mutationOutcomeUnknown || mutationOutcomeUnknown
        try save(next); record = next
    }
    private func markUncertain() {
        uncertain = true
        if let record { try? persist(record) }
    }
    private func acknowledge(_ next: Record) throws {
        do { try persist(next) } catch { markUncertain(); throw error }
    }
    private func mutationFailed(_ error: Error, beforeIntent: Record) throws -> Never {
        if let failure = error as? Failure, failure == .notSubmitted {
            try rollbackUnsubmitted(beforeIntent, error: error)
        }
        markUncertain(); throw error
    }
    private func rollbackUnsubmitted(_ beforeIntent: Record, error: Error) throws -> Never {
        do { try persist(beforeIntent) }
        catch { markUncertain(); throw error }
        throw error
    }
    private func required() throws -> Record { guard let record else { throw Failure.missing }; return record }
    private func index(_ key: Key) throws -> Int {
        guard let index = try required().entries.firstIndex(where: { $0.key == key }) else { throw Failure.invalid }
        return index
    }
    private func entry(_ key: Key) throws -> Entry { try required().entries[index(key)] }

    private static func desired(_ key: Key, original: Value) -> Value {
        switch key {
        case .checkpoint, .currentState, .mclTempDisabledUntilDate: return .absent
        case .mclLimitValue: return .integer(79)
        default:
            if case .bool = original { return .bool(true) }
            if case .real = original { return .real(1) }
            return .integer(1)
        }
    }
    private static func validateClock(_ bootID: String, _ now: TimeInterval) throws {
        guard !bootID.isEmpty, bootID.utf8.count <= 128,
              !bootID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              now.isFinite, now >= 0 else { throw Failure.invalid }
    }
    private static func validate(_ observation: Observation, preparing: Bool, restoring: Bool) throws {
        let nativeKnown: Bool
        if restoring, observation.nativeLimit == nil, observation.nativeEnabled == nil { nativeKnown = true }
        else if let limit = observation.nativeLimit, let enabled = observation.nativeEnabled {
            nativeKnown = (restoring ? [0, 1] : [1]).contains(enabled)
                && ((restoring && enabled == 0 && limit == 100) || (preparing ? [80] : [79, 80]).contains(limit))
        } else { nativeKnown = false }
        guard (restoring || observation.adapterPresent), !observation.competingController, !observation.calibrationActive,
              observation.level.isFinite, (restoring ? 0.0...100.0 : 80.0...85.0).contains(observation.level),
              observation.batteryCurrent.isFinite, observation.adapterPower.isFinite, observation.adapterPower >= 0,
              observation.wallDate.timeIntervalSinceReferenceDate.isFinite, nativeKnown,
              (restoring || !observation.registrations.isEmpty),
              observation.registrations.allSatisfy({ (preparing ? [80] : [79, 80]).contains($0) }) else { throw Failure.invalid }
    }
    private static func validateAdmission(_ observation: Observation) throws {
        try validate(observation, preparing: false, restoring: true)
        guard observation.nativeLimit == nil, observation.nativeEnabled == nil,
              observation.adapterPresent, observation.adapterPower > 1,
              (80.0...85.0).contains(observation.level),
              Set(observation.registrations) == Set([80]) else { throw Failure.invalid }
    }
    private static func validateOriginals(_ values: [Key: Value]) throws {
        guard values[.mclLimitValue]?.numeric == 80 else { throw Failure.invalidOriginal(.mclLimitValue) }
        guard values[.initialChargeLimitSetDate]?.numeric != nil else { throw Failure.invalidOriginal(.initialChargeLimitSetDate) }
        for key in [Key.disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC] {
            guard values[key] == .absent else { throw Failure.invalidOriginal(key) }
        }
        for key in [Key.mclFeatureState, .isEngaged, .isManuallyChargeLimited] {
            guard let value = values[key] else { throw Failure.invalidOriginal(key) }
            // Native macOS80 can omit the two legacy flags. Preserve explicit
            // absence in the journal and restore it, never normalize it to0/1.
            // MCLFeatureState still has to prove an enabled original contract.
            if (key == .isEngaged || key == .isManuallyChargeLimited) && value == .absent { continue }
            guard value == .bool(true) || value.numeric == 1 else { throw Failure.invalidOriginal(key) }
        }
        guard values[.mclTempDisabledUntilDate] == .absent else { throw Failure.invalidOriginal(.mclTempDisabledUntilDate) }
    }
    static func validate(_ record: Record) throws {
        try validateClock(record.bootID, record.startedContinuous)
        let admission = record.initialObservation.nativeLimit == nil && record.initialObservation.nativeEnabled == nil
        if admission { try validateAdmission(record.initialObservation) }
        else { try validate(record.initialObservation, preparing: true, restoring: false) }
        if let observed = record.admittedObservation {
            try validate(observed, preparing: true, restoring: false)
            guard observed.adapterPower > 1 else { throw Failure.invalid }
        }
        if record.phase == .admissionPending || record.phase == .admissionIntent {
            guard admission, record.admittedObservation == nil,
                  record.entries.allSatisfy({ $0.ack == .untouched && $0.prior == nil }) else { throw Failure.invalid }
        }
        if admission, [.prepared, .applying, .applySignalIntent, .active].contains(record.phase) {
            guard record.admittedObservation != nil else { throw Failure.invalid }
        }
        // Old journals keep their exact original deadline and remain recovery
        // only when loaded. Never reinterpret a schema-1 record as a new trial.
        let duration: TimeInterval
        switch record.schema {
        case 1: duration = 60
        case 2: duration = controlDuration
        default: throw Failure.invalid
        }
        guard record.deadlineContinuous.isFinite,
              record.deadlineContinuous > record.startedContinuous,
              record.deadlineContinuous == record.startedContinuous + duration,
              record.entries.map(\.key) == Key.direct, Set(record.guards.keys) == Set(Key.guards) else { throw Failure.invalid }
        var values = record.guards
        for entry in record.entries {
            try entry.original.validate(); try entry.expected.validate(); try entry.prior?.validate()
            guard entry.expected == desired(entry.key, original: entry.original) else { throw Failure.invalid }
            if entry.ack == .writeIntent || entry.ack == .applied {
                guard entry.prior == entry.original else { throw Failure.invalid }
            }
            if entry.ack == .restoreIntent {
                guard entry.prior == entry.expected else { throw Failure.invalid }
            }
            values[entry.key] = entry.original
        }
        if record.phase == .prepared { guard record.entries.allSatisfy({ $0.ack == .untouched && $0.prior == nil }) else { throw Failure.invalid } }
        if record.phase == .active { guard record.entries.allSatisfy({ $0.ack == .applied }) else { throw Failure.invalid } }
        if record.phase == .awaitingConfirmation {
            guard record.entries.allSatisfy({ $0.ack == .restored || $0.ack == .derivedRecomputed }) else { throw Failure.invalid }
        }
        try record.modeOfOperation.validate()
        try validateOriginals(values)
    }
}
#endif
