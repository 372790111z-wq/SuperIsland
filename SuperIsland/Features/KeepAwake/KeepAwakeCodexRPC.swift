import Foundation
import Darwin

/// A read-only client of an already running, same-user Codex shared service.
/// Never starts a daemon, resumes a thread, submits a prompt, or reads items.
enum KeepAwakeCodexRPC {
    enum Failure: LocalizedError {
        case unavailable, invalidEndpoint, timeout, invalidResponse, capacity, incompatible, ambiguousEnvironment, profileMismatch
        var errorDescription: String? {
            switch self {
            case .unavailable: "当前 Codex 没有可连接的官方本机任务接口；不能读取现有任务。"
            case .invalidEndpoint: "Codex 本机接口的归属或权限无法确认，未连接。"
            case .timeout: "Codex 状态读取超时；已开始任务继续保持。"
            case .invalidResponse: "Codex 状态响应不完整；不能确认任务结束。"
            case .capacity: "Codex 任务状态超过本次读取上限；不能确认全部结束。"
            case .incompatible: "当前 Codex 不支持所需的只读任务状态接口。"
            case .ambiguousEnvironment: "发现多个不同的 Codex 数据目录；未选择任务接口。"
            case .profileMismatch: "Codex 接口返回的数据目录与所选环境不一致，未接入。"
            }
        }
    }

    static var codexHome: URL {
        // Compatibility for CLI hook callers. Desktop connections bind a full
        // profile and never infer their endpoint from this convenience value.
        (try? KeepAwakeCodexEnvironment.defaultCodexHome(userHome: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment)) ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    static func controlSocket(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base = home == FileManager.default.homeDirectoryForCurrentUser ? codexHome : home.appendingPathComponent(".codex")
        return KeepAwakeCodexEnvironment.controlSocket(codexHome: base)
    }
    static func executableURL() -> URL? {
        try? KeepAwakeCodexEnvironment.discover().executableURL
    }
    static func isOfficialExecutable(_ url: URL) -> Bool {
        KeepAwakeCodexEnvironment.isOfficialExecutable(url)
    }
    static func endpointAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        if home != FileManager.default.homeDirectoryForCurrentUser {
            return (try? validateEndpoint(controlSocket(home: home))) != nil
        }
        return (try? KeepAwakeCodexEnvironment.discover(requireEndpoint: true)) != nil
    }
    static func validateEndpoint(_ socket: URL) throws {
        do { try KeepAwakeCodexEnvironment.validateEndpoint(socket) }
        catch KeepAwakeCodexEnvironment.Failure.unavailable { throw Failure.unavailable }
        catch { throw Failure.invalidEndpoint }
    }

    static func sample() throws -> KeepAwakeCodexMonitor.Snapshot {
        let profile: KeepAwakeCodexEnvironment.Profile
        do { profile = try KeepAwakeCodexEnvironment.discover(requireEndpoint: true, refresh: true) }
        catch KeepAwakeCodexEnvironment.Failure.ambiguous { throw Failure.ambiguousEnvironment }
        catch KeepAwakeCodexEnvironment.Failure.invalidEndpoint { throw Failure.invalidEndpoint }
        catch { throw Failure.unavailable }
        return try sample(profile: profile)
    }

    static func sample(profile: KeepAwakeCodexEnvironment.Profile) throws -> KeepAwakeCodexMonitor.Snapshot {
        try validateEndpoint(profile.socketURL)
        guard isOfficialExecutable(profile.executableURL) else { throw Failure.unavailable }
        let session = try Session(profile: profile)
        defer { session.close() }
        return try read(profile: profile, request: session.request, notification: session.notification)
    }

    /// A fixture seam for the handshake and read-only protocol, without spawning
    /// a proxy or querying real threads. Home identity is checked before reads.
    static func read(profile: KeepAwakeCodexEnvironment.Profile,
                     request: @escaping (String, [String: Any]) throws -> [String: Any],
                     notification: (String, [String: Any]) throws -> Void) throws -> KeepAwakeCodexMonitor.Snapshot {
        let initialized = try request("initialize", [
            "clientInfo": ["name": "superisland_keep_awake", "title": "SuperIsland", "version": "1"]
        ])
        guard let home = initialized["codexHome"] as? String, home.hasPrefix("/"), home.utf8.count <= 4_096,
              !home.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.incompatible }
        guard URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path ==
                profile.codexHome.standardizedFileURL.resolvingSymlinksInPath().path else { throw Failure.profileMismatch }
        try notification("initialized", [:])
        return try Reader(request: request).read()
    }

    static func proxyArguments(profile: KeepAwakeCodexEnvironment.Profile) -> [String] {
        ["app-server", "proxy", "--sock", profile.socketURL.path]
    }
    static func proxyEnvironment(profile: KeepAwakeCodexEnvironment.Profile, inherited: [String: String]) -> [String: String] {
        var values = inherited; values["CODEX_HOME"] = profile.codexHome.path; return values
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
                metadata[id] = ["id": id, "status": status]
            }

            var threads: [KeepAwakeCodexMonitor.Thread] = []
            // Source/originator describe creation, not the current executor.
            // Cover this server's loaded tasks, including resumed CLI threads
            // and children whose parent was unloaded; do not claim UI identity.
            for id in ids {
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
        init(profile: KeepAwakeCodexEnvironment.Profile) throws {
            process.executableURL = profile.executableURL
            process.arguments = proxyArguments(profile: profile)
            process.environment = proxyEnvironment(profile: profile, inherited: ProcessInfo.processInfo.environment)
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
