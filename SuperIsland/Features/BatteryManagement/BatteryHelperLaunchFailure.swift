import Foundation

/// A narrow repair signal for a job that never initialized. This is not a
/// general launchctl parser or permission to restart a slow/running helper.
enum BatteryHelperLaunchFailure {
    enum State: Equatable { case signingFailure(UUID), invalidated(UUID) }
    static func confirmed(_ text: String, parent: String, build: String) -> Bool {
        if case .invalidated = state(text, parent: parent, build: build) { return true }
        return false
    }
    static func state(_ text: String, parent: String, build: String) -> State? {
        guard ["com.workview.SuperIsland", "com.workview.SuperIsland.WE1Debug", "com.workview.SuperIsland.BM1Debug"].contains(parent),
              !build.isEmpty, build != "unknown", !build.contains(where: \.isNewline),
              text.utf8.count <= 16_384 else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "system/\(BatteryManagementIdentity.label) = {",
              lines.last(where: { !$0.isEmpty }) == "}" else { return nil }
        let fields = lines.filter { $0.hasPrefix("\t") && !$0.hasPrefix("\t\t") }
        func value(_ key: String) -> String? {
            let prefix = "\t" + key + " = "
            let matches = fields.filter { $0.hasPrefix(prefix) }
            guard matches.count == 1 else { return nil }
            return String(matches[0].dropFirst(prefix.count))
        }
        guard value("type") == "Submitted", value("managed_by") == "com.apple.xpc.ServiceManagement",
              value("parent bundle identifier") == parent, value("parent bundle version") == build,
              value("program identifier") == "Contents/MacOS/BatteryManagementHelper (mode: 2)",
              value("active count") == "0", value("state") == "spawn scheduled",
              value("job state") == "spawn failed", let runs = value("runs"), Int(runs).map({ $0 > 0 }) == true,
              !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid") }),
              !fields.contains(where: { $0.hasPrefix("\tinitialized") || $0.hasPrefix("\texecs") }),
              let record = value("BTM uuid").flatMap(UUID.init(uuidString:)) else { return nil }
        let properties = value("properties")?.components(separatedBy: " | ") ?? []
        guard properties.contains("needs LWCR update"), properties.contains("has LWCR") else { return nil }
        let reasons = fields.filter { $0.hasPrefix("\tlast exit reason = ") || $0.hasPrefix("\tlast exit code = ") }
        guard reasons.count == 1 else { return nil }
        if value("last exit reason") == "OS_REASON_CODESIGNING" { return .signingFailure(record) }
        if value("last exit code") == "78: EX_CONFIG" { return .invalidated(record) }
        return nil
    }

    /// A code-signing launch failure precedes BTM invalidation on the observed
    /// system. Repairing immediately rebinds the still-current OLD record and
    /// consumes the one repair attempt before the replacement record exists.
    /// Only the same job's subsequent EX_CONFIG is a repair signal; an unknown,
    /// running or replaced job ends observation without unregistering anything.
    static func awaitInvalidation(parent: String, build: String, attempts: Int = 16,
                                  read: () throws -> String,
                                  pause: () async throws -> Void) async -> Bool {
        guard (1...16).contains(attempts) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var signingRecord: UUID?
        for index in 0..<attempts {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  let text = try? read(), !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  let observed = state(text, parent: parent, build: build) else { return false }
            switch observed {
            case .invalidated(let record): return signingRecord == nil || signingRecord == record
            case .signingFailure(let record):
                guard signingRecord == nil || signingRecord == record else { return false }
                signingRecord = record
            }
            guard index + 1 < attempts else { return false }
            do { try await pause() } catch { return false }
        }
        return false
    }

    static func probe(bundle: URL, parent: String, build: String) async -> Bool {
        let observation = Task.detached(priority: .utility) {
            do {
                // Validate our existing bytes; never re-sign or change trust.
                _ = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--verify", "--deep", "--strict", bundle.path], maximumOutput: 16_384)
                return await awaitInvalidation(parent: parent, build: build, read: {
                    let data = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                        arguments: ["print", "system/" + BatteryManagementIdentity.label], maximumOutput: 16_384)
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw BatteryControlError.unavailable("后台启动状态编码无效。")
                    }
                    return text
                }, pause: { try await Task.sleep(for: .seconds(1)) })
            } catch { return false } // Missing, denied, timed out, or incomplete is unknown.
        }
        return await withTaskCancellationHandler(operation: { await observation.value },
                                                onCancel: { observation.cancel() })
    }
}
