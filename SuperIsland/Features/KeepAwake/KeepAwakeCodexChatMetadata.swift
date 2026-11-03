import Foundation
import SQLite3
import Darwin

/// Opt-in projection of the six approved hierarchy columns, never messages.
enum KeepAwakeCodexChatMetadata {
    enum Issue: String, Sendable { case unavailable, unsafeFile, schema, budget, sizeLimit, invalidMetadata, changedFile }
    struct Node: Equatable, Sendable {
        var session: String
        var parent: String?
        var root: String
        var title: String?
        var availability: String? = nil
    }
    struct Snapshot: Equatable, Sendable {
        var nodes: [String: Node] = [:]
        /// Memory-only title map. Never pass to a recorder or a diagnostic log.
        var titles: [String: String] = [:]
        var issue: Issue? = nil
        var unresolvedCount = 0
        var rejectedTitleCount = 0
        var quality: String { issue == nil && unresolvedCount == 0 ? "complete" : nodes.isEmpty ? "unavailable" : "partial" }
    }
    static func databaseURL(home: URL) -> URL? {
        guard home.isFileURL, home.path.hasPrefix("/"), home.standardizedFileURL == home else { return nil }
        return home.appendingPathComponent("state_5.sqlite")
    }
    static func read(database: URL, sessions: Set<String>, maximumDuration: Double = 0.25,
                     maximumInstructions: Int = 400_000) -> Snapshot {
        guard !sessions.isEmpty, sessions.count <= 1024,
              sessions.allSatisfy(KeepAwakeTurnMetadataReader.validHash), maximumDuration.isFinite, maximumDuration > 0,
              maximumInstructions > 0 else { return .init(issue: .invalidMetadata, unresolvedCount: sessions.count) }
        let fd = open(database.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .init(issue: .unavailable, unresolvedCount: sessions.count) }; defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, owned(initial), safeSidecars(database) else { return .init(issue: .unsafeFile, unresolvedCount: sessions.count) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return .init(issue: .unavailable, unresolvedCount: sessions.count) }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1, sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { return .init(issue: .unsafeFile, unresolvedCount: sessions.count) }
        sqlite3_busy_timeout(db, 20)
        // SQLite applies LENGTH to records too, not just projected columns.
        // Bound the record independently from the 512-byte title we expose.
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 16_777_216); sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 4096)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128)
        let context = Context(sessions, duration: maximumDuration, instructions: maximumInstructions)
        let raw = Unmanaged.passUnretained(context).toOpaque(); defer { withExtendedLifetime(context) {} }
        guard sqlite3_create_function_v2(db, "si_admitted_chat", 1, SQLITE_UTF8, raw, { result, count, args in
            guard let result, count == 1, let args, let opaque = sqlite3_user_data(result) else { return }
            let context = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
            guard context.live else { sqlite3_result_error(result, "metadata budget exhausted", -1); return }
            guard let value = args[0], sqlite3_value_type(value) == SQLITE_TEXT,
                  sqlite3_value_bytes(value) <= 1024, let bytes = sqlite3_value_text(value),
                  let id = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(value))), encoding: .utf8), KeepAwakeCodexChatMetadata.validID(id) else { sqlite3_result_int(result, 0); return }
            sqlite3_result_int(result, context.sessions.contains(KeepAwakeCodexChatMetadata.hash(id)) ? 1 : 0)
        }, nil, nil, nil) == SQLITE_OK else { return .init(issue: .schema, unresolvedCount: sessions.count) }
        sqlite3_set_authorizer(db, { _, action, a, b, database, origin in
            switch action {
            case SQLITE_SELECT: return SQLITE_OK
            case SQLITE_READ:
                guard origin == nil, let a, let b, let database, String(cString: database) == "main" else { return SQLITE_DENY }
                let columns = ["threads": Set(["id", "title", "attached_thread_parent_id"]),
                               "thread_spawn_edges": Set(["parent_thread_id", "child_thread_id", "status"])]
                return columns[String(cString: a)]?.contains(String(cString: b)) == true ? SQLITE_OK : SQLITE_DENY
            case SQLITE_FUNCTION: return b.map { String(cString: $0) == "si_admitted_chat" } == true ? SQLITE_OK : SQLITE_DENY
            default: return SQLITE_DENY
            }
        }, nil)
        sqlite3_progress_handler(db, Int32(context.step), { pointer in
            guard let pointer else { return 1 }
            let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue(); context.instructions -= context.step
            return context.live ? 0 : 1
        }, raw)
        // Scan only IDs (covering primary-key index), then isolate each target's
        // metadata query. One oversized or malformed target cannot erase others.
        guard let targets = rows(db, sql: "SELECT id FROM threads WHERE si_admitted_chat(id)=1 LIMIT 1025", values: [], columns: 1, context: context),
              targets.count <= sessions.count, Set(targets.compactMap { $0[0] }).count == targets.count else {
            return .init(issue: context.issue ?? (context.live ? .invalidMetadata : .budget), unresolvedCount: sessions.count)
        }
        struct RawNode { var id: String; var title: String?; var parent: String?; var availability: String? }
        var cache: [String: RawNode] = [:], failed = Set<String>()
        func load(_ id: String) -> RawNode? {
            if let hit = cache[id] { return hit }; if failed.contains(id) { return nil }
            guard context.live, cache.count < 2048,
                  let records = rows(db, sql: "SELECT id,title,attached_thread_parent_id FROM threads WHERE id=? LIMIT 2", values: [id], context: context, titleColumn: 1),
                  records.count == 1, let item = records.first, item[0] == id, validID(id), item[2].map(validID) != false,
                  let edges = rows(db, sql: "SELECT parent_thread_id,child_thread_id,status FROM thread_spawn_edges WHERE child_thread_id=? LIMIT 3", values: [id], context: context), edges.count <= 1 else { failed.insert(id); return nil }
            var parent = item[2], availability: String?
            if let edge = edges.first {
                guard let edgeParent = edge[0], validID(edgeParent), edge[1] == id,
                      let status = edge[2], ["open", "closed"].contains(status), parent == nil || parent == edgeParent else { failed.insert(id); return nil }
                availability = status; parent = edgeParent
            }
            guard parent != id else { failed.insert(id); return nil }
            let node = RawNode(id: id, title: KeepAwakeChatGrouping.safeTitle(item[1]), parent: parent, availability: availability)
            cache[id] = node; return node
        }
        var result = Snapshot()
        for target in targets {
            guard let id = target[0], sessions.contains(hash(id)), let first = load(id) else { continue }
            var visited = Set<String>(), cursor: RawNode? = first, root: RawNode?
            for _ in 0..<16 {
                guard let node = cursor, visited.insert(node.id).inserted else { break }
                if let parent = node.parent { cursor = load(parent) }
                else { root = node; break }
            }
            guard let root else { continue }
            result.nodes[hash(id)] = .init(session: hash(id), parent: first.parent.map(hash), root: hash(root.id), title: first.title, availability: first.availability)
            if let title = root.title { result.titles[hash(root.id)] = title }
        }
        var current = stat()
        guard lstat(database.path, &current) == 0, owned(current), current.st_dev == initial.st_dev,
              current.st_ino == initial.st_ino, safeSidecars(database) else { return .init(issue: .changedFile, unresolvedCount: sessions.count) }
        result.unresolvedCount = sessions.count - result.nodes.count
        result.issue = context.live ? context.issue : .budget
        result.rejectedTitleCount = context.rejectedTitles
        if result.unresolvedCount > 0 && result.issue == nil { result.issue = .invalidMetadata }
        return result
    }
    private final class Context {
        let sessions: Set<String>; let deadline: Double; var instructions: Int; let step: Int
        var issue: Issue?; var rejectedTitles = 0
        var live: Bool { instructions > 0 && ProcessInfo.processInfo.systemUptime < deadline }
        init(_ sessions: Set<String>, duration: Double, instructions: Int) {
            self.sessions = sessions; deadline = ProcessInfo.processInfo.systemUptime + min(0.25, duration)
            self.instructions = min(400_000, instructions); step = min(100, instructions)
        }
        func fail(_ code: Int32) { issue = !live || code == SQLITE_INTERRUPT ? .budget : code == SQLITE_TOOBIG ? .sizeLimit : .schema }
    }
    private static func rows(_ db: OpaquePointer, sql: String, values: [String], columns: Int32 = 3,
                             context: Context, titleColumn: Int32? = nil) -> [[String?]]? {
        guard context.live else { context.issue = .budget; return nil }; var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { context.fail(sqlite3_errcode(db)); return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1, sqlite3_column_count(statement) == columns else { context.issue = .schema; return nil }
        for (i, value) in values.enumerated() {
            guard value.withCString({ sqlite3_bind_text(statement, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { context.issue = .schema; return nil }
        }
        var output: [[String?]] = []
        while context.live {
            let rc = sqlite3_step(statement); if rc == SQLITE_DONE { return output }
            guard rc == SQLITE_ROW, output.count < 1025 else { context.fail(rc); return nil }
            var row: [String?] = []
            for column in 0..<columns {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { row.append(nil); continue }
                let bytes = sqlite3_column_bytes(statement, column)
                // Do not copy overlong titles into Swift, even transiently.
                if column == titleColumn && (sqlite3_column_type(statement, column) != SQLITE_TEXT || bytes > 512) {
                    context.rejectedTitles += 1; row.append(nil); continue
                }
                guard sqlite3_column_type(statement, column) == SQLITE_TEXT, bytes <= 1024,
                      let text = sqlite3_column_text(statement, column),
                      let value = String(bytes: UnsafeBufferPointer(start: text, count: Int(bytes)), encoding: .utf8) else { context.issue = .invalidMetadata; return nil }
                row.append(value)
            }
            output.append(row)
        }
        context.issue = .budget; return nil
    }
    private static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 1024 && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    private static func hash(_ id: String) -> String { KeepAwakeHookContract.anonymousIdentity(id) }
    private static func owned(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() }
    private static func safeSidecars(_ url: URL) -> Bool {
        for suffix in ["-wal", "-shm", "-journal"] {
            var info = stat(); if lstat(url.path + suffix, &info) != 0 { if errno == ENOENT { continue }; return false }
            if !owned(info) { return false }
        }
        return true
    }
}
