import Foundation

/// Serializes capture ownership with a Zilan lease. No UI callback, run-loop
/// operation or actor hop runs while this lock is held.
final class ZilanEventTapInteractionState: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = false
    private var requestID: String?

    var isCapturing: Bool { lock.withLock { captured } }
    var isSuppressed: Bool { lock.withLock { requestID != nil } }

    func beginCapture() -> Bool {
        lock.withLock {
            guard requestID == nil else { return false }
            captured = true
            return true
        }
    }

    func endCapture() { lock.withLock { captured = false } }

    func beginSuppression(requestID: String) -> Bool {
        lock.withLock {
            guard self.requestID == nil, !captured else { return false }
            self.requestID = requestID
            return true
        }
    }

    func endSuppression(requestID: String) {
        lock.withLock {
            guard self.requestID == requestID else { return }
            self.requestID = nil
        }
    }
}

/// An ACK is all-or-nothing across independent UI/input owners. Failed
/// acquisition has no receiver release callback, so unwind synchronously.
@MainActor
enum ZilanSuppressionAcquisition {
    struct Step {
        let acquire: () -> Bool
        let rollback: () -> Void
    }

    static func acquire(_ steps: [Step]) -> Bool {
        var acquired: [Step] = []
        for step in steps {
            guard step.acquire() else {
                acquired.reversed().forEach { $0.rollback() }
                return false
            }
            acquired.append(step)
        }
        return true
    }
}
