import Foundation
import Darwin
import Security

/// A read-only client of an already running, same-user Codex shared service.
/// Never starts a daemon, resumes a thread, submits a prompt, or reads items.
enum KeepAwakeCodexRPC {
    enum Failure: LocalizedError {
        case unavailable, invalidEndpoint, timeout, invalidResponse, capacity, incompatible
        var errorDescription: String? {
            switch self {
            case .unavailable: "当前 Codex 没有可连接的官方本机任务接口；不能读取现有任务。"
            case .invalidEndpoint: "Codex 本机接口的归属或权限无法确认，未连接。"
            case .timeout: "Codex 状态读取超时；已开始任务继续保持。"
            case .invalidResponse: "Codex 状态响应不完整；不能确认任务结束。"
            case .capacity: "Codex 任务状态超过本次读取上限；不能确认全部结束。"
            case .incompatible: "当前 Codex 不支持所需的只读任务状态接口。"
            }
        }
    }

    static var codexHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    static func controlSocket(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base = home == FileManager.default.homeDirectoryForCurrentUser ? codexHome : home.appendingPathComponent(".codex")
        return base.appendingPathComponent("app-server-control/app-server-control.sock")
    }
    static func executableURL() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let candidates = path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") } + [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        ]
        return candidates.first { isOfficialExecutable($0.resolvingSymlinksInPath()) }?.resolvingSymlinksInPath()
    }
    static func isOfficialExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    static func endpointAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        (try? validateEndpoint(controlSocket(home: home))) != nil
    }
    static func validateEndpoint(_ socket: URL) throws {
        var file = stat(), directory = stat()
        guard lstat(socket.path, &file) == 0 else { throw Failure.unavailable }
        guard (file.st_mode & S_IFMT) == S_IFSOCK, file.st_uid == getuid(),
              lstat(socket.deletingLastPathComponent().path, &directory) == 0,
              (directory.st_mode & S_IFMT) == S_IFDIR, directory.st_uid == getuid(),
              directory.st_mode & 0o077 == 0 else { throw Failure.invalidEndpoint }
    }

    static func sample() throws -> KeepAwakeCodexMonitor.Snapshot {
        try validateEndpoint(controlSocket())
        guard let executable = executableURL() else { throw Failure.unavailable }
        let session = try Session(executable: executable)
        defer { session.close() }
        _ = try session.request("initialize", params: [
            "clientInfo": ["name": "superisland_keep_awake", "title": "SuperIsland", "version": "1"]
        ])
        try session.notification("initialized", params: [:])
        return try Reader(request: session.request).read()
    }

    /// Injectable at the JSON-RPC boundary for pagination, privacy, and race tests.
    struct Reader {
        var request: (String, [String: Any]) throws -> [String: Any]
        var maximumThreads = 256
        var maximumTurns = 1024

        func read() throws -> KeepAwakeCodexMonitor.Snapshot {
            var ids: [String] = [], cursor: String?, cursors = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 64]
                if let cursor { params["cursor"] = cursor }
                let result = try request("thread/loaded/list", params)
                guard let page = result["data"] as? [String], page.allSatisfy(Self.validID) else { throw Failure.invalidResponse }
                ids.append(contentsOf: page)
                guard ids.count <= maximumThreads, Set(ids).count == ids.count else { throw Failure.capacity }
                cursor = try Self.nextCursor(result)
                if let cursor, !cursors.insert(cursor).inserted { throw Failure.invalidResponse }
            } while cursor != nil

            var metadata: [String: [String: Any]] = [:]
            for id in ids {
                let response = try request("thread/read", ["threadId": id, "includeTurns": false])
                guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == id,
                      let status = thread["status"] as? [String: Any], status["type"] is String else { throw Failure.invalidResponse }
                // `preview`, name, cwd, and every other content field are discarded.
                metadata[id] = ["id": id, "status": status,
                                "source": thread["source"] ?? NSNull(),
                                "parentThreadId": thread["parentThreadId"] ?? NSNull()]
            }
            func belongsToDesktop(_ id: String, visiting: Set<String> = []) -> Bool {
                guard !visiting.contains(id), let value = metadata[id] else { return false }
                if let source = value["source"] as? String { return source == "appServer" }
                guard let source = value["source"] as? [String: Any], source["subAgent"] != nil,
                      let parent = value["parentThreadId"] as? String else { return false }
                return belongsToDesktop(parent, visiting: visiting.union([id]))
            }

            var threads: [KeepAwakeCodexMonitor.Thread] = []
            for id in ids where belongsToDesktop(id) {
                guard let status = metadata[id]?["status"] as? [String: Any], let type = status["type"] as? String else { throw Failure.invalidResponse }
                var turns: [KeepAwakeCodexMonitor.Turn] = [], complete = true
                var turnCursor: String?, seenCursors = Set<String>(), seenTurns = Set<String>()
                repeat {
                    var params: [String: Any] = ["threadId": id, "itemsView": "notLoaded", "limit": 64, "sortDirection": "desc"]
                    if let turnCursor { params["cursor"] = turnCursor }
                    let result = try request("thread/turns/list", params)
                    guard let page = result["data"] as? [[String: Any]] else { throw Failure.invalidResponse }
                    for value in page {
                        guard let turnID = value["id"] as? String, Self.validID(turnID),
                              let state = value["status"] as? String, seenTurns.insert(turnID).inserted,
                              let items = value["items"] as? [Any], items.isEmpty,
                              value["itemsView"] as? String == "notLoaded" else { throw Failure.invalidResponse }
                        turns.append(.init(id: turnID, status: state))
                    }
                    turnCursor = try Self.nextCursor(result)
                    if let turnCursor, !seenCursors.insert(turnCursor).inserted { throw Failure.invalidResponse }
                    if turns.count >= maximumTurns && turnCursor != nil { complete = false; break }
                    guard turns.count <= maximumTurns else { throw Failure.capacity }
                } while turnCursor != nil
                // Recheck status after paging. A new turn during the read must
                // never be paired with the old idle snapshot to release a hold.
                let fresh = try request("thread/read", ["threadId": id, "includeTurns": false])
                guard let value = fresh["thread"] as? [String: Any], value["id"] as? String == id,
                      let finalStatus = value["status"] as? [String: Any],
                      let finalType = finalStatus["type"] as? String else { throw Failure.invalidResponse }
                if type != finalType { complete = false }
                threads.append(.init(id: id, status: finalType,
                                     activeFlags: finalStatus["activeFlags"] as? [String] ?? [],
                                     turns: turns, turnsComplete: complete))
            }
            return .init(threads: threads)
        }
        private static func validID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 1024 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        private static func nextCursor(_ result: [String: Any]) throws -> String? {
            guard let raw = result["nextCursor"], !(raw is NSNull) else { return nil }
            guard let value = raw as? String, validID(value) else { throw Failure.invalidResponse }
            return value
        }
    }

    private final class Session {
        let process = Process()
        let input = Pipe(), output = Pipe()
        let deadline = Date().addingTimeInterval(15)
        var sequence = 0
        var buffer = Data()
        init(executable: URL) throws {
            process.executableURL = executable
            process.arguments = ["app-server", "proxy"]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.unavailable }
            try process.run()
        }
        func close() {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() } // Our own disposable proxy, never the daemon.
        }
        func notification(_ method: String, params: [String: Any]) throws {
            try write(["method": method, "params": params])
        }
        func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
            sequence += 1
            let id = sequence
            try write(["id": id, "method": method, "params": params])
            while Date() < deadline {
                let value = try readLine()
                guard value["id"] as? Int == id else { continue } // Unsubscribed content is never persisted.
                if value["error"] != nil { throw Failure.incompatible }
                guard let result = value["result"] as? [String: Any] else { throw Failure.invalidResponse }
                return result
            }
            throw Failure.timeout
        }
        private func write(_ value: [String: Any]) throws {
            guard Date() < deadline, process.isRunning else { throw Failure.unavailable }
            var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        private func readLine() throws -> [String: Any] {
            while Date() < deadline {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                    guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw Failure.invalidResponse }
                    return value
                }
                var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&item, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; throw Failure.invalidResponse }
                if ready == 0 { continue }
                if item.revents & Int16(POLLIN) == 0 { throw Failure.unavailable }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(item.fd, &chunk, chunk.count)
                guard count > 0 else { throw Failure.unavailable }
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= 8_388_608 else { throw Failure.capacity }
            }
            throw Failure.timeout
        }
    }
}
