import Foundation
import Darwin
import Security

/// Uses Codex's own TOML editor in an isolated home. The real Codex home is
/// touched only by the byte-checked transaction below, never by app-server.
enum KeepAwakeCodexInstaller {
    enum Failure: LocalizedError {
        case unavailable, invalidConfiguration, conflict, transactionPending, editorFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: "找不到支持配置编辑的 Codex CLI；未安装任何依赖。"
            case .invalidConfiguration: "Codex 配置格式或文件类型不受支持，原配置未覆盖。"
            case .conflict: "Codex 配置或 notify 已由其他内容占用，已保留原配置。"
            case .transactionPending: "Codex 配置存在待恢复变更，尚未确认完整还原；已保留备份，请核对后重试。"
            case .editorFailed: "Codex 官方配置编辑未确认成功，原配置未覆盖。"
            }
        }
    }
    enum NotifyMutation {
        case install(owned: [String], replacingOwned: [String]?, allowNotifyForwarding: Bool = false)
        case remove(owned: [String], restore: [String]?)
    }
    struct EditedConfig {
        var data: Data
        var previousNotify: [String]?
        var effectiveNotify: [String]? = nil
    }
    typealias ConfigEditor = (Data, NotifyMutation) throws -> EditedConfig
    private struct Receipt: Codable {
        var version: Int
        var notify: [String]
        var previousNotify: [String]?
        var hookCommand: String
        var sources: [String: String]?
        var lifecycleVersion: Int? = 2
        var sourceCredentials: [String: String] {
            version == 1 ? ["codex-cli": notify[3]] : sources ?? [:]
        }
    }
    private struct Change: Codable {
        var name: String
        var before: Data?
        var after: Data?
    }
    private struct Transaction: Codable {
        var id: String
        var changes: [Change]
    }
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact", "Stop", "Interrupt"]
    private static let stateName = ".superisland-keep-awake"
    private static let receiptName = "receipt.json"
    private static let maximumFileSize = 1_048_576
    private static func codexRoot(home: URL, codexHome: URL? = nil) -> URL {
        codexHome ?? (home == FileManager.default.homeDirectoryForCurrentUser ? KeepAwakeCodexRPC.codexHome : home.appendingPathComponent(".codex", isDirectory: true))
    }
    static func configurationURL(home: URL = FileManager.default.homeDirectoryForCurrentUser, codexHome: URL? = nil) -> URL {
        codexRoot(home: home, codexHome: codexHome).appendingPathComponent("config.toml")
    }

    /// Upgrade only declarations already owned by this installation. No TOML,
    /// notification chain, trust setting, or third-party handler is rewritten.
    /// An absent receipt is not permission to create an unsolicited connection.
    static func refreshOwnedLifecycleHooks(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          codexHome: URL? = nil) throws {
        let root = codexRoot(home: home, codexHome: codexHome)
        let receiptURL = destination(receiptName, root: root)
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
        let lock = try acquireLock(root: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        try recover(root: root)
        let beforeReceipt = try read(receiptURL)
        guard var receipt = try decodeReceipt(beforeReceipt, location: receiptURL) else { return }
        guard receipt.version == 2 else { return } // Legacy receipt migration remains an explicit install action.
        guard let before = try read(root.appendingPathComponent("hooks.json")),
              let object = try JSONSerialization.jsonObject(with: before) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any],
              let groups = hooks["UserPromptSubmit"] as? [[String: Any]],
              groups.contains(where: { group in
                  (group["hooks"] as? [[String: Any]])?.contains {
                      $0["type"] as? String == "command" && $0["command"] as? String == receipt.hookCommand
                  } == true
              }) else { throw Failure.conflict }
        // A disabled whole file or disabled owned start must stay disabled.
        guard object["enabled"] as? Bool != false,
              groups.contains(where: { group in
                  group["enabled"] as? Bool != false && (group["hooks"] as? [[String: Any]])?.contains {
                      $0["type"] as? String == "command" && $0["command"] as? String == receipt.hookCommand && $0["enabled"] as? Bool != false
                  } == true
              }) else { return }
        func hasOwned(_ event: String) -> Bool {
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    $0["type"] as? String == "command" && $0["command"] as? String == receipt.hookCommand
                } == true
            }
        }
        var additions = hasOwned("SessionStart") ? [] : ["SessionStart"]
        let upgradeEnd = (receipt.lifecycleVersion ?? 0) < 2
        if upgradeEnd, !hasOwned("SessionEnd") { additions.append("SessionEnd") }
        guard !additions.isEmpty || upgradeEnd else { return }
        let after = additions.isEmpty ? before : try editHooks(before, removing: nil, adding: receipt.hookCommand, addingEvents: additions)
        var changes = [Change(name: "hooks.json", before: before, after: after)]
        if upgradeEnd {
            receipt.lifecycleVersion = 2
            changes.append(.init(name: receiptName, before: beforeReceipt, after: try encodeReceipt(receipt)))
        }
        try commit(root: root, changes: changes)
    }

    static func install(source: KeepAwakeSource, credential: URL, home: URL, tool: URL,
                        codexHome: URL? = nil, cli: URL? = nil,
                        allowNotifyForwarding: Bool = false,
                        relayVerifier: @escaping (String) -> Bool = isOfficialNotifyRelay,
                        editor: ConfigEditor? = nil) throws {
        guard KeepAwakeHookContract.codexSources.contains(source.id), source.hookFamily == "codex",
              credential.isFileURL, credential.path.utf8.count <= 4096,
              FileManager.default.isExecutableFile(atPath: tool.path) else { throw Failure.unavailable }
        let root = codexRoot(home: home, codexHome: codexHome)
        try prepareRoot(root)
        let lock = try acquireLock(root: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        try recover(root: root)
        let beforeConfig = try read(root.appendingPathComponent("config.toml"))
        let beforeHooks = try read(root.appendingPathComponent("hooks.json"))
        let receiptURL = destination(receiptName, root: root)
        let beforeReceipt = try read(receiptURL)
        let receipt = try decodeReceipt(beforeReceipt, location: receiptURL)
        if let existing = receipt?.sourceCredentials[source.id], existing != credential.path,
           receipt?.notify.first != tool.path { throw Failure.conflict }
        let baseNotify = [tool.path, "--superisland-ka1-codex-notify-auto", receiptURL.path]
        let command = [KeepAwakeHookInstaller.shellQuote(tool.path), "--superisland-ka1-codex-hook-auto",
                       KeepAwakeHookInstaller.shellQuote(receiptURL.path)].joined(separator: " ")
        let configEditor = editor ?? { data, mutation in
            try editWithCLI(data, mutation, cli: cli, relayVerifier: relayVerifier)
        }
        let mutation = NotifyMutation.install(owned: baseNotify, replacingOwned: receipt?.notify,
                                               allowNotifyForwarding: allowNotifyForwarding)
        let edited = try configEditor(beforeConfig ?? Data(), mutation)
        // The editor confirms the actual wrapper it wrote; legacy fixture
        // editors may omit this field, so derive the same ownership decision.
        let effective = try notifyValue(current: edited.previousNotify, mutation: mutation, relayVerifier: relayVerifier)
        let notify: [String]
        if let receipt {
            notify = try forwardedNotify(receipt.notify).map { try forwardingNotify(owned: baseNotify, original: $0) } ?? baseNotify
        } else {
            guard let installed = effective else { throw Failure.editorFailed }
            notify = installed
        }
        guard edited.effectiveNotify == nil || edited.effectiveNotify == effective else { throw Failure.editorFailed }
        let hooks = try editHooks(beforeHooks, removing: receipt?.hookCommand,
                                  adding: command)
        // nil is meaningful: an earlier install may have created notify itself.
        let baseline = receipt.map(\.previousNotify) ?? (edited.previousNotify == notify ? nil : edited.previousNotify)
        var sources = receipt?.sourceCredentials ?? [:]
        sources[source.id] = credential.path
        let saved = Receipt(version: 2, notify: notify, previousNotify: baseline, hookCommand: command, sources: sources)
        try commit(root: root, changes: [
            .init(name: "config.toml", before: beforeConfig, after: edited.data),
            .init(name: "hooks.json", before: beforeHooks, after: hooks),
            .init(name: receiptName, before: beforeReceipt, after: try encodeReceipt(saved))
        ])
    }

    static func uninstall(source: KeepAwakeSource, home: URL, credential: URL? = nil, codexHome: URL? = nil,
                          cli: URL? = nil, relayVerifier: @escaping (String) -> Bool = isOfficialNotifyRelay,
                          editor: ConfigEditor? = nil) throws {
        guard KeepAwakeHookContract.codexSources.contains(source.id), source.hookFamily == "codex" else { throw Failure.unavailable }
        let root = codexRoot(home: home, codexHome: codexHome)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try prepareRoot(root)
        let lock = try acquireLock(root: root)
        defer { flock(lock, LOCK_UN); close(lock) }
        try recover(root: root)
        let receiptURL = destination(receiptName, root: root)
        let beforeReceipt = try read(receiptURL)
        guard var receipt = try decodeReceipt(beforeReceipt, location: receiptURL),
              receipt.sourceCredentials[source.id] != nil else { return }
        if let credential, receipt.sourceCredentials[source.id] != credential.path { throw Failure.conflict }
        var sources = receipt.sourceCredentials
        sources.removeValue(forKey: source.id)
        if !sources.isEmpty {
            // Shared commands and their trust definition stay unchanged while
            // either client remains connected. Only revoke this routing entry.
            receipt.sources = sources
            try commit(root: root, changes: [
                .init(name: receiptName, before: beforeReceipt, after: try encodeReceipt(receipt))
            ])
            return
        }
        let beforeConfig = try read(root.appendingPathComponent("config.toml"))
        let beforeHooks = try read(root.appendingPathComponent("hooks.json"))
        let configEditor = editor ?? { data, mutation in
            try editWithCLI(data, mutation, cli: cli, relayVerifier: relayVerifier)
        }
        let edited = try configEditor(beforeConfig ?? Data(), .remove(owned: receipt.notify, restore: receipt.previousNotify))
        let hooks = try editHooks(beforeHooks, removing: receipt.hookCommand, adding: nil)
        try commit(root: root, changes: [
            .init(name: "config.toml", before: beforeConfig, after: edited.data),
            .init(name: "hooks.json", before: beforeHooks, after: hooks),
            .init(name: receiptName, before: beforeReceipt, after: nil)
        ])
    }

    /// Pure ownership decision shared by the official editor and test doubles.
    static func notifyValue(current: [String]?, mutation: NotifyMutation,
                            relayVerifier: (String) -> Bool = isOfficialNotifyRelay) throws -> [String]? {
        switch mutation {
        case let .install(owned, replacingOwned, allowNotifyForwarding):
            if let replacingOwned {
                // A later user edit must not be wrapped under a stale receipt:
                // its previousNotify would otherwise restore the wrong command.
                let replacement = try forwardedNotify(replacingOwned).map { try forwardingNotify(owned: owned, original: $0) } ?? owned
                if current == owned { return owned }
                guard let current else { throw Failure.conflict }
                let changed = try editNotifyChain(current, owned: replacingOwned, replacement: replacement, relayVerifier: relayVerifier)
                guard changed.found else { throw Failure.conflict }
                return changed.value
            }
            if current == nil || current?.isEmpty == true || current == owned { return owned }
            guard allowNotifyForwarding, let current else { throw Failure.conflict }
            return try forwardingNotify(owned: owned, original: current)
        case let .remove(owned, restore):
            guard let current else { return nil }
            return try editNotifyChain(current, owned: owned, replacement: restore, relayVerifier: relayVerifier).value
        }
    }

    /// The native notification client can retain our exact command inside its
    /// documented --previous-notify JSON argv. A different top-level program
    /// is not evidence that the callback was removed. Only this signed relay
    /// protocol may be traversed, and only the exact owned leaf may be edited.
    private static func editNotifyChain(_ current: [String], owned: [String], replacement: [String]?,
                                       relayVerifier: (String) -> Bool, depth: Int = 0) throws -> (value: [String]?, found: Bool) {
        guard !owned.isEmpty, current.count <= 1028, current.reduce(0, { $0 + $1.utf8.count }) <= maximumFileSize,
              current.allSatisfy({ !$0.utf8.contains(0) }) else { throw Failure.conflict }
        if current == owned { return (replacement, true) }
        if forwardedNotify(owned) != nil, current.count >= 4, current.prefix(4) == owned.prefix(4) {
            throw Failure.conflict // Preserve a user's edited delegate and its dependencies.
        }
        let referencesOwnedMode = current.contains { $0.contains("--superisland-ka1") || $0.contains(owned[0]) }
        guard current.count == 4, current[1] == "turn-ended", current[2] == "--previous-notify",
              current[0].hasPrefix("/"), relayVerifier(current[0]) else {
            if referencesOwnedMode { throw Failure.conflict }
            return (current, false)
        }
        guard depth < 4, let data = current[3].data(using: .utf8),
              let child = try? JSONDecoder().decode([String].self, from: data), !child.isEmpty else {
            throw Failure.conflict
        }
        let edited = try editNotifyChain(child, owned: owned, replacement: replacement,
                                        relayVerifier: relayVerifier, depth: depth + 1)
        guard edited.found else { return (current, false) }
        if edited.value == child { return (current, true) } // Keep original JSON whitespace/escaping.
        guard let next = edited.value, !next.isEmpty else { return (Array(current.prefix(2)), true) }
        let encoded = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        return (Array(current.prefix(3)) + [encoded], true)
    }

    static func isOfficialNotifyRelay(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { return false }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"com.openai.sky.CUAService.cli\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func forwardedNotify(_ value: [String]) -> [String]? {
        guard value.count >= 5, value[1] == "--superisland-ka1-codex-notify-forward", value[3] == "--" else { return nil }
        return Array(value.dropFirst(4))
    }
    private static func forwardingNotify(owned: [String], original: [String]) throws -> [String] {
        guard owned.count == 3, owned[1] == "--superisland-ka1-codex-notify-auto",
              owned[0].hasPrefix("/"), owned[2].hasPrefix("/"),
              KeepAwakeHookContract.validCodexNotifyDelegate(original, toolPath: owned[0]) else { throw Failure.conflict }
        return [owned[0], "--superisland-ka1-codex-notify-forward", owned[2], "--"] + original
    }

    static func officialEdit(_ original: Data, _ mutation: NotifyMutation) throws -> EditedConfig {
        guard let cli = KeepAwakeCodexRPC.executableURL() else { throw Failure.unavailable }
        return try officialEdit(original, mutation, executable: cli)
    }
    private static func editWithCLI(_ original: Data, _ mutation: NotifyMutation, cli: URL?,
                                    relayVerifier: @escaping (String) -> Bool) throws -> EditedConfig {
        if let cli {
            guard KeepAwakeCodexRPC.isOfficialExecutable(cli) else { throw Failure.unavailable }
            return try officialEdit(original, mutation, executable: cli, relayVerifier: relayVerifier)
        }
        guard let executable = KeepAwakeCodexRPC.executableURL() else { throw Failure.unavailable }
        return try officialEdit(original, mutation, executable: executable, relayVerifier: relayVerifier)
    }
    static func officialEdit(_ original: Data, _ mutation: NotifyMutation, executable: URL,
                             relayVerifier: (String) -> Bool = isOfficialNotifyRelay) throws -> EditedConfig {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("SuperIsland-Codex-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let config = temporary.appendingPathComponent("config.toml")
        try replace(original, at: config)
        let rpc = try ConfigRPC(executable: executable, home: temporary)
        defer { rpc.close() }
        _ = try rpc.call("initialize", params: ["clientInfo": ["name": "superisland_config_editor", "version": "1"]])
        try rpc.notify("initialized")
        let snapshot = try rpc.call("config/read", params: ["includeLayers": true])
        guard let layers = snapshot["layers"] as? [[String: Any]],
              let layer = layers.first(where: { ($0["name"] as? [String: Any])?["type"] as? String == "user"
                  && (($0["name"] as? [String: Any])?["profile"] == nil || ($0["name"] as? [String: Any])?["profile"] is NSNull) }),
              let values = layer["config"] as? [String: Any], let version = layer["version"] as? String else { throw Failure.editorFailed }
        guard values["notify"] == nil || values["notify"] is [String] else { throw Failure.invalidConfiguration }
        let current = values["notify"] as? [String]
        if case .install = mutation {
            // A selected profile or managed layer may own effective notify.
            // Do not claim an installation that that layer would override.
            let effective = (snapshot["config"] as? [String: Any])?["notify"] as? [String]
            guard effective == current else { throw Failure.conflict }
        }
        let next = try notifyValue(current: current, mutation: mutation, relayVerifier: relayVerifier)
        if current == next { return EditedConfig(data: original, previousNotify: current, effectiveNotify: next) }
        let response = try rpc.call("config/batchWrite", params: [
            "filePath": config.path, "expectedVersion": version, "reloadUserConfig": false,
            "edits": [["keyPath": "notify", "value": next.map { $0 as Any } ?? NSNull(), "mergeStrategy": "replace"]]
        ])
        guard response["status"] as? String == "ok", let writtenPath = response["filePath"] as? String,
              URL(fileURLWithPath: writtenPath).resolvingSymlinksInPath() == config.resolvingSymlinksInPath(),
              let edited = try read(config) else { throw Failure.editorFailed }
        if case .install = mutation {
            let confirmed = try rpc.call("config/read", params: ["includeLayers": false])
            guard (confirmed["config"] as? [String: Any])?["notify"] as? [String] == next else { throw Failure.editorFailed }
        }
        return EditedConfig(data: edited, previousNotify: current, effectiveNotify: next)
    }

    private static func decodeReceipt(_ data: Data?, location: URL) throws -> Receipt? {
        guard let data else { return nil }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { throw Failure.conflict }
        if receipt.version == 1 {
            guard receipt.notify.count == 4, receipt.notify[1] == "--superisland-ka1-codex-notify",
                  receipt.notify[2] == "codex-cli", receipt.notify[0].hasPrefix("/"), receipt.notify[3].hasPrefix("/"),
                  receipt.hookCommand == [KeepAwakeHookInstaller.shellQuote(receipt.notify[0]), "--superisland-ka1", "codex-cli",
                                          KeepAwakeHookInstaller.shellQuote(receipt.notify[3])].joined(separator: " ") else { throw Failure.conflict }
        } else {
            let original = forwardedNotify(receipt.notify)
            let auto = receipt.notify.count == 3 && receipt.notify[1] == "--superisland-ka1-codex-notify-auto"
            let forward = original != nil && original == receipt.previousNotify &&
                KeepAwakeHookContract.validCodexNotifyDelegate(original!, toolPath: receipt.notify[0])
            guard receipt.version == 2, receipt.notify.count >= 3, auto || forward,
                  receipt.notify[0].hasPrefix("/"),
                  receipt.notify[2] == location.path,
                  let router = try? JSONDecoder().decode(KeepAwakeHookContract.CodexRouter.self, from: data),
                  receipt.sourceCredentials.keys.allSatisfy({ router.credentialPath(source: $0) != nil }),
                  !receipt.sourceCredentials.isEmpty,
                  receipt.hookCommand == [KeepAwakeHookInstaller.shellQuote(receipt.notify[0]), "--superisland-ka1-codex-hook-auto",
                                          KeepAwakeHookInstaller.shellQuote(location.path)].joined(separator: " ") else { throw Failure.conflict }
        }
        return receipt
    }
    private static func encodeReceipt(_ receipt: Receipt) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(receipt)
    }
    private static func editHooks(_ data: Data?, removing: String?, adding: String?, addingEvents: [String] = events) throws -> Data? {
        guard data != nil || adding != nil else { return nil }
        var root: [String: Any]
        if let data {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidConfiguration }
            root = value
        } else { root = [:] }
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else { throw Failure.invalidConfiguration }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Set(events + Array(hooks.keys)) {
            guard let raw = hooks[event] else { continue }
            guard let groups = raw as? [[String: Any]] else { throw Failure.invalidConfiguration }
            if let removing {
                hooks[event] = try groups.compactMap { group -> [String: Any]? in
                    guard let handlers = group["hooks"] as? [[String: Any]] else { throw Failure.invalidConfiguration }
                    guard handlers.contains(where: { $0["type"] as? String == "command" && $0["command"] as? String == removing }) else { return group }
                    let kept = handlers.compactMap { handler -> [String: Any]? in
                        guard handler["type"] as? String == "command", handler["command"] as? String == removing else { return handler }
                        guard let adding else { return nil }
                        // Migration changes the owned command in place, keeping
                        // group/handler disables and third-party fields intact.
                        var copy = handler; copy["command"] = adding
                        if ["Interrupt", "SessionEnd"].contains(event) { copy["timeout"] = 3 }
                        return copy
                    }
                    guard !kept.isEmpty else { return nil }
                    var copy = group; copy["hooks"] = kept; return copy
                }
            }
        }
        if let adding {
            for event in addingEvents {
                var groups = hooks[event] as? [[String: Any]] ?? []
                let exists = groups.contains { group in
                    (group["hooks"] as? [[String: Any]])?.contains { $0["type"] as? String == "command" && $0["command"] as? String == adding } == true
                }
                // Preserve a user's disabled/edited copy instead of enabling it.
                if !exists { groups.append(["matcher": "", "hooks": [["type": "command", "command": adding, "timeout": ["Interrupt", "SessionEnd"].contains(event) ? 3 : 5]]]) }
                hooks[event] = groups
            }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func prepareRoot(_ root: URL) throws {
        let fm = FileManager.default
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0) else { throw Failure.invalidConfiguration }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.conflict }
    }
    private static func destination(_ name: String, root: URL) -> URL {
        name == receiptName ? root.appendingPathComponent(stateName).appendingPathComponent(name) : root.appendingPathComponent(name)
    }
    private static func read(_ url: URL, limit: Int = maximumFileSize) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.conflict
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= limit else { close(fd); throw Failure.invalidConfiguration }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.invalidConfiguration }
        return data
    }
    private static func replace(_ data: Data?, at url: URL) throws {
        let fm = FileManager.default
        guard let data else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".superisland-write-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.editorFailed }
        defer { try? fm.removeItem(at: temporary) }
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.editorFailed }
        let flushed = fsync(fd); close(fd)
        guard flushed == 0 else { throw Failure.editorFailed }
        guard rename(temporary.path, url.path) == 0 else { throw Failure.editorFailed }
    }
    private static func stateDirectory(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent(stateName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.conflict }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private static func acquireLock(root: URL) throws -> Int32 {
        let path = try stateDirectory(root).appendingPathComponent("install.lock")
        let fd = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.conflict }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.conflict }
        return fd
    }
    private static func commit(root: URL, changes: [Change]) throws {
        let changes = changes.filter { $0.before != $0.after }
        guard !changes.isEmpty else { return }
        let state = try stateDirectory(root)
        let id = UUID().uuidString
        let backup = state.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for change in changes {
            guard try read(destination(change.name, root: root)) == change.before else { throw Failure.conflict }
            if let before = change.before { try replace(before, at: backup.appendingPathComponent(change.name + ".before")) }
        }
        let transaction = Transaction(id: id, changes: changes)
        let journal = state.appendingPathComponent("pending.json")
        guard try read(journal) == nil else { throw Failure.transactionPending }
        try replace(try JSONEncoder().encode(transaction), at: journal)
        do {
            for change in changes {
                let url = destination(change.name, root: root)
                guard try read(url) == change.before else { throw Failure.conflict }
                try replace(change.after, at: url)
                guard try read(url) == change.after else { throw Failure.conflict }
            }
            try FileManager.default.moveItem(at: journal, to: backup.appendingPathComponent("committed.json"))
        } catch {
            let originalError = error
            do { try recover(root: root) }
            catch { throw Failure.transactionPending }
            throw originalError
        }
    }
    private static func recover(root: URL) throws {
        let state = root.appendingPathComponent(stateName, isDirectory: true)
        let journal = state.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: state.path) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: state.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.transactionPending }
        guard let data = try read(journal, limit: maximumFileSize * 10) else { return }
        guard let transaction = try? JSONDecoder().decode(Transaction.self, from: data), UUID(uuidString: transaction.id) != nil,
              transaction.changes.count <= 3,
              Set(transaction.changes.map(\.name)).count == transaction.changes.count,
              transaction.changes.allSatisfy({ ["config.toml", "hooks.json", receiptName].contains($0.name) }) else { throw Failure.transactionPending }
        // Validate the whole rollback first. A user's new edit must not cause
        // us to partially undo other files while leaving this transaction split.
        for change in transaction.changes {
            let current = try read(destination(change.name, root: root))
            guard current == change.before || current == change.after else { throw Failure.transactionPending }
        }
        for change in transaction.changes.reversed() {
            let url = destination(change.name, root: root)
            let current = try read(url)
            if current == change.before { continue }
            guard current == change.after else { throw Failure.transactionPending }
            try replace(change.before, at: url)
        }
        let backup = state.appendingPathComponent(transaction.id)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        guard backupAttributes[.type] as? FileAttributeType == .typeDirectory,
              (backupAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.transactionPending }
        try FileManager.default.moveItem(at: journal, to: backup.appendingPathComponent("rolled-back.json"))
    }

    private final class ConfigRPC {
        private let process = Process()
        private let input = Pipe(), output = Pipe()
        private var buffer = Data()
        private var nextID = 0
        init(executable: URL, home: URL) throws {
            process.executableURL = executable
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.currentDirectoryURL = home
            let allowed = ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"]
            var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            environment["CODEX_HOME"] = home.path
            process.environment = environment
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.editorFailed }
            try process.run()
        }
        func close() {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func notify(_ method: String) throws { try send(["method": method]) }
        private func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
            guard ["initialize", "config/read", "config/batchWrite"].contains(method) else { throw Failure.editorFailed }
            nextID += 1; let id = nextID
            try send(["id": id, "method": method, "params": params])
            let deadline = KeepAwakeClock.now() + 10
            while KeepAwakeClock.now() < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                    guard let response = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          response["id"] as? Int == id else { continue }
                    guard response["error"] == nil, let result = response["result"] as? [String: Any] else { throw Failure.editorFailed }
                    return result
                }
                guard process.isRunning else { throw Failure.editorFailed }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) >= 0 else { throw Failure.editorFailed }
                if descriptor.revents & Int16(POLLIN) != 0 {
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    guard count > 0, buffer.count + count <= maximumFileSize * 4 else { throw Failure.editorFailed }
                    buffer.append(contentsOf: bytes.prefix(count))
                } else if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 { throw Failure.editorFailed }
            }
            throw Failure.editorFailed
        }
    }
}
