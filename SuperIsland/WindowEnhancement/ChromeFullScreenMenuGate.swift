import Foundation

/// Retry only pre-dispatch observation. A menu AX error can still mean the
/// command was delivered, so both sent and uncertain attempts end this gate.
@MainActor
enum ChromeFullScreenMenuGate {
    enum Outcome: String {
        case waiting, alreadySatisfied, sent, uncertain, targetChanged, targetGone
        case timedOut, interrupted
    }

    static func request(
        isCurrent: () -> Bool,
        attempt: () -> Outcome,
        maximumDuration: TimeInterval = 4,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: () async -> Bool = {
            do { try await Task.sleep(nanoseconds: 80_000_000); return true }
            catch { return false }
        }
    ) async -> Outcome {
        let deadline = now() + maximumDuration
        while now() < deadline {
            guard isCurrent(), !Task.isCancelled else { return .interrupted }
            let outcome = attempt()
            guard outcome == .waiting else { return outcome }
            guard await pause() else { return .interrupted }
        }
        return .timedOut
    }
}
