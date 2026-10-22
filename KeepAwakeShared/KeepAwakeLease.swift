import Foundation

/// Serialized by the daemon. The durable intent is written BEFORE changing
/// power state, so a daemon restart can recover even after a partial operation.
final class KeepAwakeLease {
    struct Journal: Codable, Equatable {
        let owner: String
        let baseline: Int
        let applied: Int
        var expires: Double
        var acOnly = true
        var minimumBattery = 20
        var respectLowPower = true
    }
    enum Failure: LocalizedError {
        case occupied, conflict, invalidOwner, writeFailed
        /// A rejected caller did not change power state or recovery ownership.
        /// It must not lock the daemon out of renewing the existing owner.
        var isRequestRejection: Bool {
            switch self {
            case .occupied, .invalidOwner: true
            case .conflict, .writeFailed: false
            }
        }
        var errorDescription: String? {
            switch self {
            case .occupied: "另一保持会话或电源工具正在控制合盖设置。"
            case .conflict: "系统电源设置与恢复记录不一致，需人工核对。"
            case .invalidOwner: "无效的租约拥有者。"
            case .writeFailed: "系统没有确认电源设置变更，恢复记录已保留。"
            }
        }
    }
    var journal: Journal?
    let readPower: () throws -> Int
    let writePower: (Int) throws -> Void
    let save: (Journal?) throws -> Void
    init(journal: Journal?, readPower: @escaping () throws -> Int, writePower: @escaping (Int) throws -> Void, save: @escaping (Journal?) throws -> Void) {
        self.journal = journal; self.readPower = readPower; self.writePower = writePower; self.save = save
    }
    func renew(owner: String, now: Double, acOnly: Bool = true, minimumBattery: Int = 20, respectLowPower: Bool = true) throws {
        guard (5...50).contains(minimumBattery) else { throw Failure.invalidOwner }
        guard UUID(uuidString: owner) != nil else { throw Failure.invalidOwner }
        if let previous = journal, previous.expires <= now { try recover() }
        if var current = journal {
            guard current.owner == owner else { throw Failure.occupied }
            guard try readPower() == current.applied else { throw Failure.conflict }
            current.expires = now + 180
            current.acOnly = acOnly; current.minimumBattery = minimumBattery; current.respectLowPower = respectLowPower
            try save(current); journal = current
            return
        }
        let baseline = try readPower()
        // Do not take ownership of a pre-existing global sleep override.
        guard baseline == 0 else { throw Failure.occupied }
        let next = Journal(owner: owner, baseline: baseline, applied: 1, expires: now + 180, acOnly: acOnly, minimumBattery: minimumBattery, respectLowPower: respectLowPower)
        try save(next); journal = next
        try writePower(1)
        guard try readPower() == 1 else { throw Failure.writeFailed }
    }
    func release(owner: String) throws {
        guard UUID(uuidString: owner) != nil else { throw Failure.invalidOwner }
        if let current = journal, current.owner != owner { throw Failure.occupied }
        try recover()
    }
    func expire(now: Double) throws {
        if let current = journal, current.expires <= now { try recover() }
    }
    /// Called on EVERY daemon startup, never resumes an old lease.
    func recover() throws {
        guard let current = journal else { return }
        let value = try readPower()
        if value == current.baseline {
            try save(nil); journal = nil; return
        }
        guard value == current.applied else { throw Failure.conflict }
        try writePower(current.baseline)
        guard try readPower() == current.baseline else { throw Failure.writeFailed }
        try save(nil); journal = nil
    }
}
