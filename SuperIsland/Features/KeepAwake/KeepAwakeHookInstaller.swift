import Foundation
import CoreFoundation

/// Narrow JSON merge. The caller obtains explicit consent before touching a
/// user's agent settings; tests always use a temporary home and executable.
enum KeepAwakeHookInstaller {
    enum Failure: LocalizedError {
        case unavailable, invalidConfiguration, conflict
        var errorDescription: String? {
            switch self {
            case .unavailable: "接入工具未打包，无法写入配置。"
            case .invalidConfiguration: "现有配置格式不受支持，未覆盖原文件。"
            case .conflict: "配置在操作期间发生变化，已保留现场，请检查后重试。"
            }
        }
    }
    static let marker = "--superisland-ka1"
    static func path(source: KeepAwakeSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch source.hookFamily {
        case "qoder": home.appendingPathComponent(".qoder-cn/settings.json")
        case "workbuddy": home.appendingPathComponent(".workbuddy/settings.json")
        case "zcode": home.appendingPathComponent(".zcode/cli/config.json")
        case "gemini": home.appendingPathComponent(".gemini/settings.json")
        case "opencode": home.appendingPathComponent(".config/opencode/plugins/superisland-keep-awake.js")
        case "pi": home.appendingPathComponent(".pi/agent/extensions/superisland-keep-awake.js")
        case "codex": KeepAwakeCodexInstaller.configurationURL(home: home)
        default: home.appendingPathComponent(".claude/settings.json")
        }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func install(source: KeepAwakeSource, credential: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, executable: URL? = nil) throws {
        guard source.hookFamily != nil else { throw Failure.unavailable }
        let tool = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KeepAwakeEventTool")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw Failure.unavailable }
        if source.hookFamily == "codex" {
            try KeepAwakeCodexInstaller.install(source: source, credential: credential, home: home, tool: tool)
            return
        }
        if source.hookFamily == "opencode" || source.hookFamily == "pi" {
            try installPlugin(source: source, credential: credential, home: home, tool: tool)
            return
        }
        if source.hookFamily == "zcode" {
            try modifyZCode(source: source, home: home) { events in
                removeOwned(&events, source: source)
                // ZCode's user-level schema differs from Claude-style JSON.
                // No StopFailure/SessionEnd is invented for this contract.
                for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Stop"] {
                    var entries = events[event] as? [[String: Any]] ?? []
                    if events[event] != nil && !(events[event] is [[String: Any]]) { throw Failure.invalidConfiguration }
                    entries.append(["matcher": "", "hooks": [["type": "process", "command": tool.path,
                        "args": [marker, source.id, credential.path], "enabled": true, "timeoutMs": 5000]]])
                    events[event] = entries
                }
            }
            return
        }
        let command = [shellQuote(tool.path), marker, shellQuote(source.id), shellQuote(credential.path)].joined(separator: " ")
        try modify(source: source, home: home) { hooks in
            removeOwned(&hooks, source: source)
            let events = ["qoder", "workbuddy"].contains(source.hookFamily ?? "")
                ? ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd", "Elicitation", "ElicitationResult"]
                : source.hookFamily == "gemini"
                ? ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "SessionEnd", "Notification"]
                : ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd", "Elicitation", "ElicitationResult"]
            for event in events {
                var entries = hooks[event] as? [[String: Any]] ?? []
                if hooks[event] != nil && !(hooks[event] is [[String: Any]]) { throw Failure.invalidConfiguration }
                let timeout = source.hookFamily == "gemini" ? 5000 : 5
                entries.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": timeout, "name": "superisland-keep-awake-" + event]]])
                hooks[event] = entries
            }
        }
    }
    static func uninstall(source: KeepAwakeSource, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard source.hookFamily != nil else { return }
        if source.hookFamily == "codex" {
            try KeepAwakeCodexInstaller.uninstall(source: source, home: home)
            return
        }
        guard FileManager.default.fileExists(atPath: path(source: source, home: home).path) else { return }
        if source.hookFamily == "opencode" || source.hookFamily == "pi" {
            let url = path(source: source, home: home)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            guard try String(contentsOf: url).hasPrefix("// SuperIsland KA1 owned adapter v1.") else { throw Failure.conflict }
            // Recoverable disconnect; never remove another plugin.
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension(UUID().uuidString + ".disabled"))
        } else if source.hookFamily == "zcode" {
            try modifyZCode(source: source, home: home) { removeOwned(&$0, source: source) }
        } else { try modify(source: source, home: home) { removeOwned(&$0, source: source) } }
    }
    private static func modifyZCode(source: KeepAwakeSource, home: URL, edit: (inout [String: Any]) throws -> Void) throws {
        try modifyConfiguration(source: source, home: home) { root in
            if root["hooks"] != nil && !(root["hooks"] is [String: Any]) { throw Failure.invalidConfiguration }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            if let enabled = hooks["enabled"] {
                guard let flag = enabled as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw Failure.invalidConfiguration }
            }
            if hooks["events"] != nil && !(hooks["events"] is [String: Any]) { throw Failure.invalidConfiguration }
            var events = hooks["events"] as? [String: Any] ?? [:]
            try edit(&events)
            // Preserve an explicit disabled setting: only ZCode's own trust /
            // enable flow may turn it on. New configurations can opt in here.
            if hooks["enabled"] == nil { hooks["enabled"] = true }
            hooks["events"] = events
            root["hooks"] = hooks
        }
    }
    private static func installPlugin(source: KeepAwakeSource, credential: URL, home: URL, tool: URL) throws {
        guard let family = source.hookFamily,
              let resource = Bundle.main.url(forResource: family, withExtension: "js", subdirectory: "KeepAwakeAdapters")
                ?? Bundle.main.url(forResource: family, withExtension: "js") else { throw Failure.unavailable }
        let destination = path(source: source, home: home)
        var contents = try String(contentsOf: resource)
        let encode: (String) throws -> String = { String(data: try JSONEncoder().encode($0), encoding: .utf8)! }
        contents = try contents.replacingOccurrences(of: "__SUPERISLAND_TOOL__", with: encode(tool.path))
            .replacingOccurrences(of: "__SUPERISLAND_CREDENTIAL__", with: encode(credential.path))
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // A file bearing our name is not permission to overwrite edited code.
            if try String(contentsOf: destination) == contents { return }
            throw Failure.conflict
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: destination, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    private static func removeOwned(_ hooks: inout [String: Any], source: KeepAwakeSource) {
        for (event, raw) in hooks {
            guard let entries = raw as? [[String: Any]] else { continue }
            hooks[event] = entries.compactMap { entry -> [String: Any]? in
                guard let actions = entry["hooks"] as? [[String: Any]] else { return entry }
                let remaining = actions.filter { action in
                    if source.hookFamily == "zcode" {
                        guard action["type"] as? String == "process", let args = action["args"] as? [String] else { return true }
                        return !(args.count == 3 && args[0] == marker && args[1] == source.id)
                    }
                    guard let command = action["command"] as? String else { return true }
                    // Exact argument suffix prevents deleting another source's hook.
                    return !command.contains(" " + marker + " " + shellQuote(source.id) + " ")
                }
                if remaining.count == actions.count { return entry }
                guard !remaining.isEmpty else { return nil }
                var copy = entry; copy["hooks"] = remaining; return copy
            }
        }
    }
    private static func modify(source: KeepAwakeSource, home: URL, edit: (inout [String: Any]) throws -> Void) throws {
        try modifyConfiguration(source: source, home: home) { root in
            if root["hooks"] != nil && !(root["hooks"] is [String: Any]) { throw Failure.invalidConfiguration }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            try edit(&hooks); root["hooks"] = hooks
        }
    }
    private static func modifyConfiguration(source: KeepAwakeSource, home: URL, edit: (inout [String: Any]) throws -> Void) throws {
        let url = path(source: source, home: home)
        let fm = FileManager.default
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink { throw Failure.conflict }
        let before = try? Data(contentsOf: url)
        if fm.fileExists(atPath: url.path) && before == nil { throw Failure.invalidConfiguration }
        var root: [String: Any] = [:]
        if let before {
            guard let object = try JSONSerialization.jsonObject(with: before) as? [String: Any] else { throw Failure.invalidConfiguration }
            root = object
        }
        try edit(&root)
        let after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        if let before, let object = try? JSONSerialization.jsonObject(with: before) as? NSDictionary,
           object.isEqual(to: root) { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? Data(contentsOf: url)) == before else { throw Failure.conflict }
        // Keep a recoverable original beside the configuration. Never overwrite
        // an earlier backup, including one made by another install attempt.
        if let before {
            let backup = url.appendingPathExtension("superisland-ka1-" + UUID().uuidString + ".backup")
            try before.write(to: backup, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try after.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
