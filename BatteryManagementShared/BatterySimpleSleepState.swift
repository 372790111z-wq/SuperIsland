import Foundation

/// Only the daemon's kernel power notifications may extend a sleeping lease.
/// Client-provided `sleeping` is never authority to disable the watchdog.
struct BatterySimpleSleepState {
    private(set) var sleeping = false
    private struct Operation: Hashable { let owner: UUID; let id: UUID }
    private var interrupted = Set<Operation>()

    mutating func willSleep(_ request: BatteryControlRequest?) {
        sleeping = true
        if let request, request.mode == .discharge {
            interrupted.insert(Operation(owner: request.owner, id: request.operationID))
        }
    }
    mutating func didWake() { sleeping = false }
    mutating func normalize(_ request: BatteryControlRequest) -> BatteryControlRequest {
        var next = request
        let operation = Operation(owner: request.owner, id: request.operationID)
        // A discharge queued before the sleep edge may arrive after it.
        // Remember that cancellation too, so its post-wake heartbeat cannot run.
        if sleeping && request.mode == .discharge { interrupted.insert(operation) }
        if sleeping || interrupted.contains(operation) {
            next.mode = .automatic
            next.dischargeTarget = nil
        }
        next.sleeping = sleeping
        return next
    }
}
