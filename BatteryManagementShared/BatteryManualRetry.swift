import Foundation

#if BATTERY_HELPER || DEBUG
/// Fault acknowledgment is a helper-owned capability, never a client boolean.
/// The accepted record remains on disk: a crash before/after acquisition cannot
/// erase the fault or let an old acknowledgment authorize a restarted daemon.
final class BatteryManualRetry {
    struct Record: Codable, Equatable {
        var schema = 1
        var id = UUID()
        var failedOwner: UUID?
        var failedOperation: UUID?
        var rejectedOperations: [UUID] = []
        var reason: String
        var resolved = false
        var acceptedOwner: UUID?
        var acceptedOperation: UUID?
    }
    private(set) var record: Record?
    private(set) var durable = false
    private var acceptedInThisProcess = false
    private var unreadable = false
    private let save: (Data) throws -> Void
    var required: Bool { !durable || (record != nil && !acceptedInThisProcess) }
    var faultID: UUID? { durable && required ? record?.id : nil }

    init(load: () throws -> Data?, save: @escaping (Data) throws -> Void) {
        self.save = save
        do {
            if let data = try load() {
                let value = try JSONDecoder().decode(Record.self, from: data)
                guard value.schema == 1, !value.reason.isEmpty,
                      (value.acceptedOwner == nil) == (value.acceptedOperation == nil) else {
                    throw BatteryControlError.recovery("故障确认记录无效。")
                }
                record = value
                if let previous = value.acceptedOperation, !value.rejectedOperations.contains(previous) {
                    record?.rejectedOperations.append(previous)
                }
                acceptedInThisProcess = value.resolved
                // Rotate every restart, including a pending fault. No token
                // obtained from a previous daemon instance is reusable.
                record?.id = UUID(); record?.acceptedOwner = nil; record?.acceptedOperation = nil
                try persist()
            } else { durable = true }
        } catch {
            // Unknown is not absence. Keep the corrupt file untouched; normal
            // admission stays closed, but the caller must still restore power.
            durable = false; unreadable = record == nil
        }
    }
    /// Every watchdog iteration, not just incoming requests, observes the gate.
    /// Restoring supply never acknowledges a fault or authorizes active policy.
    func handleRecovery(_ restore: () throws -> Void) rethrows -> Bool {
        guard required else { return false }
        try restore()
        return true
    }
    func retryPersistence() {
        guard !durable, !unreadable, record != nil else { return }
        do { try persist() } catch { durable = false }
    }
    func fail(owner: UUID?, operation: UUID?, reason: String) {
        guard !unreadable else { return }
        if !acceptedInThisProcess, record != nil { retryPersistence(); return }
        var rejected = record?.rejectedOperations ?? []
        if let operation, !rejected.contains(operation) { rejected.append(operation) }
        acceptedInThisProcess = false
        record = Record(failedOwner: owner, failedOperation: operation, rejectedOperations: rejected,
                        reason: String(reason.prefix(1024)))
        durable = false
        do { try persist() } catch { durable = false }
    }
    func validate(_ request: BatteryControlRequest, recovered: Bool) throws {
        guard durable else { throw BatteryControlError.recovery("故障确认记录未可靠保存；恢复继续，新控制已禁止。") }
        guard (record?.rejectedOperations.count ?? 0) < 1024 else {
            throw BatteryControlError.recovery("故障历史已达安全上限，需维护后再控制。")
        }
        guard record?.rejectedOperations.contains(request.operationID) != true else {
            throw BatteryControlError.recovery("已失败的操作不能重放。")
        }
        if !required {
            if let token = request.acknowledgedFaultID {
                guard let record, token == record.id, request.owner == record.acceptedOwner,
                      request.operationID == record.acceptedOperation else {
                    throw BatteryControlError.recovery("已消费的确认不能用于其他请求。")
                }
            }
            return
        }
        guard recovered, let record, request.acknowledgedFaultID == record.id,
              request.operationID != record.failedOperation else {
            throw BatteryControlError.recovery("故障已锁定；恢复完成后请明确重新启用，旧请求不会自动重试。")
        }
    }
    /// Called only after all read-only admission checks and before any control
    /// mutation. A failed save cannot clear the in-memory gate.
    func accept(_ request: BatteryControlRequest, recovered: Bool) throws {
        try validate(request, recovered: recovered)
        guard required else { return }
        record?.resolved = false
        record?.acceptedOwner = request.owner; record?.acceptedOperation = request.operationID
        durable = false
        try persist()
        acceptedInThisProcess = true
    }
    /// Only a previously acknowledged fault can become resolved, and only
    /// after verified release. Keep tombstones; never delete the fault file.
    func releasedSuccessfully() throws {
        guard !required, record != nil else { return }
        record?.resolved = true
        durable = false
        try persist()
    }
    private func persist() throws {
        guard let record else { return }
        try save(JSONEncoder().encode(record))
        durable = true
    }
}
#endif
