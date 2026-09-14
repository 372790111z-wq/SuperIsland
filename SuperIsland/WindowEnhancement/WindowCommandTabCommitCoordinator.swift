import Foundation

/// Owns one explicit window commit while Dock retires the native switcher.
/// A superseded task cannot activate a window or clear a newer commit.
struct WindowCommandTabCommitCoordinator {
    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let sequenceID: Int
    }

    enum Visibility: String, Sendable {
        case visible, absent, unknown
    }

    enum Decision: Equatable {
        case wait, activate, abort, stale
    }

    enum Dismissal: Equatable {
        case alreadyAbsent, posted, rejected
    }

    private var generation: UInt64 = 0
    private(set) var pending: Ticket?
    private(set) var commandWasReleased = false
    var isPending: Bool { pending != nil }

    mutating func begin(sequenceID: Int) -> Ticket {
        generation &+= 1
        let ticket = Ticket(generation: generation, sequenceID: sequenceID)
        pending = ticket
        commandWasReleased = false
        return ticket
    }

    func isCurrent(_ ticket: Ticket, sequenceID: Int) -> Bool {
        pending == ticket && ticket.sequenceID == sequenceID
    }

    func observe(visibility: Visibility, for ticket: Ticket, sequenceID: Int) -> Decision {
        guard isCurrent(ticket, sequenceID: sequenceID) else { return .stale }
        switch visibility {
        case .visible: return .wait
        case .absent: return .activate
        case .unknown: return .abort
        }
    }

    /// Physical release still reaches Dock, but must not enqueue a second
    /// commit or tear down a click already waiting for native dismissal.
    @discardableResult
    mutating func markCommandReleased() -> Bool {
        guard isPending else { return false }
        commandWasReleased = true
        return true
    }

    @discardableResult
    mutating func finish(_ ticket: Ticket) -> Bool {
        guard pending == ticket else { return false }
        pending = nil
        commandWasReleased = false
        return true
    }

    @discardableResult
    mutating func invalidate() -> Bool {
        let wasPending = isPending
        generation &+= 1
        pending = nil
        commandWasReleased = false
        return wasPending
    }
}

enum WindowCommandTabSessionReconciliation {
    enum Action: Equatable {
        case endSession, restorePointerSession, awaitFreshSelection
    }

    static func action(
        visibility: WindowCommandTabCommitCoordinator.Visibility,
        commandHeld: Bool
    ) -> Action {
        switch visibility {
        case .absent: return .endSession
        case .visible: return .restorePointerSession
        case .unknown: return commandHeld ? .awaitFreshSelection : .endSession
        }
    }
}

/// Production polling and callback order, injectable without synthesizing
/// keyboard input or activating a real application in regression tests.
@MainActor
enum WindowCommandTabCommitWorkflow {
    enum AbortReason: String, Equatable {
        case stateChanged, visibilityUnknown, dismissTimeout
    }

    static func run(
        delays: [UInt64] = [20_000_000, 40_000_000, 80_000_000, 120_000_000, 160_000_000],
        isCurrent: () -> Bool,
        isValid: () -> Bool,
        readVisibility: () -> WindowCommandTabCommitCoordinator.Visibility,
        decision: (WindowCommandTabCommitCoordinator.Visibility) -> WindowCommandTabCommitCoordinator.Decision,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        onConfirmed: () -> Void,
        onAbort: (AbortReason) -> Void
    ) async {
        for delay in delays {
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, isCurrent() else { return }
            guard isValid() else { onAbort(.stateChanged); return }
            let visibility = readVisibility()
            // A slow AX call must not authorize a stale activation. Recheck
            // current physical input and identity after that call returns.
            guard !Task.isCancelled, isCurrent() else { return }
            guard isValid() else { onAbort(.stateChanged); return }
            switch decision(visibility) {
            case .wait: continue
            case .stale: return
            case .activate: onConfirmed(); return
            case .abort: onAbort(.visibilityUnknown); return
            }
        }
        guard !Task.isCancelled, isCurrent() else { return }
        onAbort(.dismissTimeout)
    }
}
