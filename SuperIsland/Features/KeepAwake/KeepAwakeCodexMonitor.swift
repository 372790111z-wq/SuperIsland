import Foundation
import CryptoKit

/// A metadata-only adapter. It neither opens Codex transports nor reads its
/// files, messages, tool items or authentication state.
enum KeepAwakeCodexMonitor {
    struct Snapshot: Equatable {
        var threads: [Thread]
    }

    struct Thread: Equatable {
        var id: String
        var status: String
        var activeFlags: [String]
        var turns: [Turn]
        /// False for a failed, truncated or partially fetched turn listing.
        var turnsComplete: Bool

        init(id: String, status: String, activeFlags: [String] = [], turns: [Turn] = [], turnsComplete: Bool = false) {
            self.id = id
            self.status = status
            self.activeFlags = activeFlags
            self.turns = turns
            self.turnsComplete = turnsComplete
        }
    }

    struct Turn: Equatable {
        var id: String
        var status: String
    }

    struct Ledger {
        private struct TrackedThread {
            var isOpen = false
            var unidentifiedActive = false
            var roundTurns: Set<String> = []
            var outcomes: [String: KeepAwakeEngine.TaskState] = [:]
            // Keep tombstones for the connection lifetime, including terminal
            // turns observed before monitoring began. A late old turn cannot
            // become a new task merely because its snapshot arrives later.
            var terminalTurns: Set<String> = []
        }

        private var tracked: [String: TrackedThread] = [:]
        private var lastInputSequence: UInt64?
        private var nextOutputSequence: UInt64?
        private var exhaustedSequence = false

        /// `sequence` orders whole snapshots; outputs additionally get unique
        /// monotonic sequence numbers when one snapshot produces many events.
        mutating func consume(snapshot: Snapshot, now: TimeInterval, sequence: UInt64) -> [KeepAwakeEngine.Event] {
            guard now.isFinite, !exhaustedSequence,
                  lastInputSequence.map({ sequence > $0 }) ?? true else { return [] }
            lastInputSequence = sequence
            nextOutputSequence = max(sequence, nextOutputSequence ?? sequence)
            var events: [KeepAwakeEngine.Event] = []
            var present: Set<String> = []
            let groups = Dictionary(grouping: snapshot.threads.filter { Self.validID($0.id) }, by: { Self.anonymize($0.id) })

            for session in groups.keys.sorted() {
                guard let group = groups[session], let thread = group.first else { continue }
                present.insert(session)
                var record = tracked[session] ?? TrackedThread()
                // Conflicting duplicate thread rows cannot prove an ending.
                guard group.allSatisfy({ $0 == thread }) else {
                    if group.contains(where: { $0.status == "active" }), !record.isOpen {
                        record.isOpen = true
                        record.unidentifiedActive = true
                        emit(.running, session: session, startsTask: true, into: &events)
                    }
                    if record.isOpen {
                        record.unidentifiedActive = true
                        emit(.idle, session: session, into: &events)
                    }
                    tracked[session] = record
                    continue
                }

                let turnGroups = Dictionary(grouping: thread.turns.filter { Self.validID($0.id) }, by: { Self.anonymize($0.id) })
                let knownStatuses: Set<String> = ["inProgress", "completed", "failed", "interrupted"]
                let invalidTurns = turnGroups.count != Set(thread.turns.map(\.id)).count ||
                    turnGroups.values.contains(where: { Set($0.map(\.status)).count != 1 }) ||
                    thread.turns.contains(where: { !knownStatuses.contains($0.status) })
                let complete = thread.turnsComplete && !invalidTurns
                var currentTurns: [String: String] = [:]
                for (id, values) in turnGroups where Set(values.map(\.status)).count == 1 {
                    currentTurns[id] = values[0].status
                }
                let progress = Set(currentTurns.compactMap { id, status in
                    status == "inProgress" && !record.terminalTurns.contains(id) ? id : nil
                })
                let onlyReplayedProgress = currentTurns.values.contains("inProgress") && progress.isEmpty
                let wasOpen = record.isOpen

                if thread.status == "active", !record.isOpen, !onlyReplayedProgress {
                    record.isOpen = true
                    record.roundTurns.removeAll()
                    record.outcomes.removeAll()
                    record.unidentifiedActive = progress.isEmpty
                    emit(.running, session: session, startsTask: true, into: &events)
                }

                if record.isOpen {
                    // Only an active snapshot establishes a current task round.
                    // A first idle/history snapshot never invents running work.
                    if thread.status == "active" {
                        record.roundTurns.formUnion(progress)
                        if progress.isEmpty {
                            record.unidentifiedActive = true
                        } else if complete {
                            // A real, fully enumerated in-progress turn can
                            // resolve an earlier guard with unknown turn ID.
                            record.unidentifiedActive = false
                        }
                    }
                    for (id, status) in currentTurns {
                        if record.roundTurns.contains(id), record.outcomes[id] == nil,
                           let terminal = Self.terminal(status) {
                            record.outcomes[id] = terminal
                        }
                    }

                    let allKnownEnded = !record.roundTurns.isEmpty && record.roundTurns.allSatisfy { record.outcomes[$0] != nil }
                    if thread.status == "idle", complete, !record.unidentifiedActive, allKnownEnded {
                        let terminal: KeepAwakeEngine.TaskState = record.outcomes.values.contains(.failed) ? .failed :
                            record.outcomes.values.contains(.cancelled) ? .cancelled : .completed
                        emit(terminal, session: session, into: &events)
                        record.isOpen = false
                    } else {
                        let state: KeepAwakeEngine.TaskState
                        if thread.status == "active", !record.unidentifiedActive,
                           thread.activeFlags.contains(where: { $0 == "waitingOnApproval" || $0 == "waitingOnUserInput" }) {
                            state = .waiting
                        } else if thread.status == "active", !record.unidentifiedActive,
                                  thread.activeFlags.isEmpty, !progress.isEmpty {
                            state = .running
                        } else {
                            state = .idle // Unknown still preserves the open Engine guard.
                        }
                        // The start event already represents a known running
                        // state; waiting/unknown needs its own final update.
                        if wasOpen || state != .running {
                            emit(state, session: session, into: &events)
                        }
                    }
                }
                for (id, status) in currentTurns where Self.terminal(status) != nil {
                    record.terminalTurns.insert(id)
                }
                tracked[session] = record
            }

            // A disconnect, missing page or disappearing thread is not a
            // terminal event. Keep a visible unknown heartbeat for its guard.
            for session in tracked.keys.sorted() where !present.contains(session) && tracked[session]?.isOpen == true {
                emit(.idle, session: session, into: &events)
            }
            return events
        }

        private mutating func emit(_ state: KeepAwakeEngine.TaskState, session: String,
                                   startsTask: Bool = false, into events: inout [KeepAwakeEngine.Event]) {
            guard !exhaustedSequence, let sequence = nextOutputSequence else { return }
            events.append(.init(source: "codex-desktop", session: session, sequence: sequence, state: state,
                                taskID: Self.anonymize("guard:" + session), startsTask: startsTask))
            if sequence == UInt64.max { exhaustedSequence = true }
            else { nextOutputSequence = sequence + 1 }
        }

        private static func terminal(_ status: String) -> KeepAwakeEngine.TaskState? {
            switch status {
            case "completed": .completed
            case "failed": .failed
            case "interrupted": .cancelled
            default: nil
            }
        }

        private static func validID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 1024 &&
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }

        private static func anonymize(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
