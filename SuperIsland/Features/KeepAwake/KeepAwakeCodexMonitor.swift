import Foundation
import CryptoKit
import SQLite3
import Darwin

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

/// ZCode's final per-turn usage fact is written after Stop hooks have either
/// continued the model loop or accepted its ending. Read only that fact for a
/// turn already admitted by an authenticated hook; absence is never an ending.
enum KeepAwakeZCodeTurnMetadataReader {
    struct Identity: Hashable, Sendable {
        var sessionHash: String
        var taskHash: String
    }
    struct Terminal: Equatable, Sendable {
        var identity: Identity
        var state: String
        var startedAt: TimeInterval
        var completedAt: TimeInterval
    }
    struct Budget {
        var maximumVMInstructions = 200_000
        var maximumDuration: TimeInterval = 0.25
    }
    static var defaultDatabaseURL: URL {
        defaultDatabaseURL(home: FileManager.default.homeDirectoryForCurrentUser)
    }
    static func defaultDatabaseURL(home: URL) -> URL {
        home.appendingPathComponent(".zcode/cli/db/db.sqlite")
    }

    /// A custom/invalid path must not silently cause a read of a different,
    /// stale default database. Only the already-authorized configuration field
    /// is inspected; its other keys are neither returned nor retained.
    static func defaultPathIsConfigured(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = home.appendingPathComponent(".zcode/cli/config.json")
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isOwnedRegular(info), info.st_size <= 1_048_576 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        guard let rawStorage = root["storage"] else { return true }
        guard let storage = rawStorage as? [String: Any] else { return false }
        guard let rawPath = storage["sessionDbPath"] else { return true }
        guard var path = rawPath as? String, !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
        guard path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == defaultDatabaseURL(home: home).standardizedFileURL.path
    }

    /// Synchronous and bounded; the service calls this off the main thread.
    /// A failed or interrupted read returns no proof, preserving unknown holds.
    static func read(database: URL = defaultDatabaseURL, identities: Set<Identity>,
                     now: TimeInterval = Date().timeIntervalSince1970,
                     budget: Budget = Budget()) -> [Terminal] {
        guard !identities.isEmpty, identities.count <= 1024,
              identities.allSatisfy({ validHash($0.sessionHash) && validHash($0.taskHash) }),
              now.isFinite, now > 0, budget.maximumVMInstructions > 0,
              budget.maximumDuration.isFinite, budget.maximumDuration > 0 else { return [] }
        // Keep an independently opened, no-follow descriptor for the complete
        // read. Detect path replacement before accepting a result, too.
        let descriptor = open(database.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, isOwnedRegular(initial),
              safeSidecars(database) else { return [] }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return []
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_db_readonly(connection, "main") == 1 else { return [] }
        sqlite3_busy_timeout(connection, 50)
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 8192)
        sqlite3_limit(connection, SQLITE_LIMIT_SQL_LENGTH, 4096)
        // The native table contains more usage columns than our projection.
        // This limit also applies while SQLite parses its existing schema.
        sqlite3_limit(connection, SQLITE_LIMIT_COLUMN, 128)
        let context = ReadContext(identities: identities, budget: budget)
        defer { withExtendedLifetime(context) {} }
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        guard sqlite3_create_function_v2(connection, "superisland_known_turn", 2, SQLITE_UTF8,
            opaque, { result, count, values in
                guard let result, count == 2, let values, let raw = sqlite3_user_data(result) else { return }
                let context = Unmanaged<ReadContext>.fromOpaque(raw).takeUnretainedValue()
                guard context.withinDeadline else { sqlite3_result_error(result, "read budget exhausted", -1); return }
                guard let session = KeepAwakeZCodeTurnMetadataReader.identifier(values[0]),
                      let task = KeepAwakeZCodeTurnMetadataReader.identifier(values[1]) else { sqlite3_result_int(result, 0); return }
                let identity = Identity(sessionHash: KeepAwakeZCodeTurnMetadataReader.digest(session),
                                        taskHash: KeepAwakeZCodeTurnMetadataReader.digest(task))
                sqlite3_result_int(result, context.identities.contains(identity) ? 1 : 0)
            }, nil, nil, nil) == SQLITE_OK else { return [] }
        sqlite3_set_authorizer(connection, { _, action, first, second, database, origin in
            switch action {
            case SQLITE_SELECT: return SQLITE_OK
            case SQLITE_READ:
                guard origin == nil, let first, let second, let database,
                      String(cString: database) == "main", String(cString: first) == "turn_usage",
                      ["session_id", "turn_id", "status", "started_at", "completed_at"].contains(String(cString: second)) else { return SQLITE_DENY }
                return SQLITE_OK
            case SQLITE_FUNCTION:
                return second.map { String(cString: $0) == "superisland_known_turn" } == true ? SQLITE_OK : SQLITE_DENY
            default: return SQLITE_DENY
            }
        }, nil)
        sqlite3_progress_handler(connection, 100, { raw in
            guard let raw else { return 1 }
            let context = Unmanaged<ReadContext>.fromOpaque(raw).takeUnretainedValue()
            context.remainingInstructions -= 100
            return context.remainingInstructions > 0 && context.withinDeadline ? 0 : 1
        }, opaque)
        // The predicate inspects IDs only. SQLite does not project other row
        // metadata until both IDs match an admitted task's anonymous identity.
        let sql = "SELECT session_id,turn_id,status,started_at,completed_at FROM main.turn_usage WHERE superisland_known_turn(session_id,turn_id)=1 LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1, sqlite3_column_count(statement) == 5,
              sqlite3_bind_int(statement, 1, Int32(identities.count + 1)) == SQLITE_OK else { return [] }
        var terminals: [Terminal] = []
        var seen: Set<Identity> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, context.withinDeadline,
                  let session = columnText(statement, 0, limit: 1024), validIdentifier(session),
                  let task = columnText(statement, 1, limit: 1024), validIdentifier(task) else { return [] }
            let identity = Identity(sessionHash: digest(session), taskHash: digest(task))
            guard identities.contains(identity), seen.insert(identity).inserted, seen.count <= identities.count else { return [] }
            guard let nativeState = columnText(statement, 2, limit: 32),
                  let state = ["completed": "completed", "error": "failed", "cancelled": "cancelled"][nativeState],
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER else { continue }
            let startedAt = Double(sqlite3_column_int64(statement, 3)) / 1000
            let completedAt = Double(sqlite3_column_int64(statement, 4)) / 1000
            guard startedAt >= 0, completedAt >= startedAt, completedAt <= now + 5 else { continue }
            terminals.append(.init(identity: identity, state: state, startedAt: startedAt, completedAt: completedAt))
        }
        var current = stat()
        guard lstat(database.path, &current) == 0, isOwnedRegular(current),
              current.st_dev == initial.st_dev, current.st_ino == initial.st_ino,
              safeSidecars(database) else { return [] }
        return terminals.sorted { ($0.identity.sessionHash, $0.identity.taskHash) < ($1.identity.sessionHash, $1.identity.taskHash) }
    }
    private final class ReadContext {
        let identities: Set<Identity>
        let deadline: TimeInterval
        var remainingInstructions: Int
        var withinDeadline: Bool { ProcessInfo.processInfo.systemUptime <= deadline }
        init(identities: Set<Identity>, budget: Budget) {
            self.identities = identities
            deadline = ProcessInfo.processInfo.systemUptime + min(0.25, budget.maximumDuration)
            remainingInstructions = min(200_000, budget.maximumVMInstructions)
        }
    }
    private static func isOwnedRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }
    private static func safeSidecars(_ database: URL) -> Bool {
        for suffix in ["-wal", "-shm", "-journal"] {
            var info = stat()
            if lstat(database.path + suffix, &info) != 0 {
                if errno == ENOENT { continue }
                return false
            }
            guard isOwnedRegular(info) else { return false }
        }
        return true
    }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 &&
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func identifier(_ value: OpaquePointer?) -> String? {
        guard let value, sqlite3_value_type(value) == SQLITE_TEXT,
              sqlite3_value_bytes(value) <= 1024, let text = sqlite3_value_text(value),
              let string = String(bytes: UnsafeBufferPointer(start: text, count: Int(sqlite3_value_bytes(value))), encoding: .utf8),
              validIdentifier(string) else { return nil }
        return string
    }
    private static func columnText(_ statement: OpaquePointer, _ index: Int32, limit: Int) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, index) <= limit,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8)
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
