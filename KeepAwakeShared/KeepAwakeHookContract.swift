import Foundation
import Darwin
import CryptoKit
import CoreFoundation
import Security

/// Public hook metadata contract. Extra vendor fields and version strings do
/// not affect compatibility. Unsupported events cannot invent running state.
enum KeepAwakeHookContract {
    static let sources = ["qoder-desktop", "workbuddy-desktop", "zcode-desktop"]
    static let codexSources = ["codex-cli", "codex-desktop"]
    static let codexNotifyForwardMode = "--superisland-ka1-codex-notify-forward"
    /// A delegate is the user's existing argv, never shell text we construct.
    /// Reject owned invocations even inside an existing shell argument, and
    /// resolve aliases so a renamed/symlinked tool cannot delegate to itself.
    static func validCodexNotifyDelegate(_ command: [String], toolPath: String) -> Bool {
        guard !command.isEmpty, command.count <= 1024, let executable = command.first,
              !executable.isEmpty, executable.utf8.count <= 4096,
              command.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576,
              command.allSatisfy({ !$0.utf8.contains(0) && !$0.contains("--superisland-ka1") }) else { return false }
        let tool = URL(fileURLWithPath: toolPath).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate: String?
        if executable.contains("/") {
            candidate = URL(fileURLWithPath: executable).standardizedFileURL.resolvingSymlinksInPath().path
        } else {
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false)
            candidate = paths.lazy.map { directory -> String in
                URL(fileURLWithPath: directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory), isDirectory: true)
                    .appendingPathComponent(executable).standardizedFileURL.resolvingSymlinksInPath().path
            }.first {
                var info = stat()
                return access($0, X_OK) == 0 && stat($0, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            }
        }
        guard let candidate else { return true } // execvp preserves the original missing-program failure.
        guard candidate != tool else { return false }
        var delegateInfo = stat(), toolInfo = stat()
        if stat(candidate, &delegateInfo) == 0, stat(tool, &toolInfo) == 0,
           delegateInfo.st_dev == toolInfo.st_dev, delegateInfo.st_ino == toolInfo.st_ino { return false }
        return true
    }
    private static let codexCompactionPrefix = "aux.codex.compaction."
    /// The private installer receipt doubles as the router. It contains only
    /// source-to-credential paths, never task content or authentication keys.
    struct CodexRouter: Decodable {
        let version: Int
        let sources: [String: String]
        func credentialPath(source: String) -> String? {
            guard version == 2, !sources.isEmpty, sources.count <= codexSources.count,
                  sources.allSatisfy({ codexSources.contains($0.key) && Self.validPath($0.value) }),
                  codexSources.contains(source) else { return nil }
            return sources[source]
        }
        private static func validPath(_ value: String) -> Bool {
            value.hasPrefix("/") && value.utf8.count <= 4096 && !value.utf8.contains(0)
        }
    }
    struct Metadata: Equatable {
        var taskID: String?
        var startsTask: Bool
    }
    /// Only documented same-turn identity is accepted. The raw vendor value
    /// never leaves this process. Version, cwd, transcript and tool IDs cannot
    /// be substituted for task identity.
    static func metadata(source: String, input: [String: Any]) -> Metadata {
        let event = input["hook_event_name"] as? String
        var startsTask = event == "UserPromptSubmit" || (source == "gemini-cli" && event == "BeforeAgent")
        if source == "workbuddy-desktop", isTrue(input["is_internal_continuation"]) { startsTask = false }
        if ["opencode", "pi"].contains(source) {
            startsTask = event == "running" && isTrue(input["task_start"])
        }
        var taskID: String?
        if source == "workbuddy-desktop", let generation = input["generation_id"] as? String,
           !generation.isEmpty, generation.utf8.count <= 1024 {
            taskID = SHA256.hash(data: Data(generation.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        if source == "pi", let ownedID = input["ka1_task_id"] as? String,
           ownedID.utf8.count <= 1024, UUID(uuidString: ownedID) != nil {
            taskID = SHA256.hash(data: Data(ownedID.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        if codexSources.contains(source), let turn = codexIdentity(input["turn_id"]) {
            let isCompaction = event == "PreCompact" || event == "PostCompact"
            // notify precedes optional post-turn compaction. Track that stage
            // independently so a completed answer cannot end active maintenance.
            taskID = (isCompaction ? codexCompactionPrefix : "")
                + anonymousIdentity(turn + (isCompaction ? "\nka1.codex.compaction.v1" : ""))
            if event == "PreCompact" { startsTask = true }
        }
        return Metadata(taskID: taskID, startsTask: startsTask)
    }
    struct CodexNotification: Equatable {
        let session: String
        let metadata: Metadata
        let state = "completed"
    }
    /// `notify` appends one JSON argument. It is a different wire contract
    /// from stdin hooks, and can only end the exact thread/turn it identifies.
    /// Message text, paths and optional client labels are deliberately unused.
    static func codexNotification(_ input: [String: Any]) -> CodexNotification? {
        guard input["type"] as? String == "agent-turn-complete",
              let thread = codexIdentity(input["thread-id"]),
              let turn = codexIdentity(input["turn-id"]) else { return nil }
        return CodexNotification(session: anonymousIdentity(thread),
            metadata: Metadata(taskID: anonymousIdentity(turn), startsTask: false))
    }
    private static func codexIdentity(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 1024,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    static func anonymousIdentity(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Auxiliary stages still hold power until completion, but must not emit a
    /// user-task completion notification. The complete label is authenticated
    /// by the existing taskID field; no envelope schema change is needed.
    static func isAuxiliaryTask(source: String, taskID: String?) -> Bool {
        guard codexSources.contains(source), let taskID, taskID.hasPrefix(codexCompactionPrefix) else { return false }
        let digest = taskID.dropFirst(codexCompactionPrefix.count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func isTrue(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    /// The legacy nil/nil form is byte-for-byte unchanged. Once either field
    /// is present, both values (including explicit absence) are authenticated.
    static func authenticatedBytes(generation: String, source: String, session: String, sequence: UInt64,
                                   state: String, issuedAt: Double, taskID: String?, startsTask: Bool?) -> Data {
        var fields = [generation, source, session, String(sequence), state, String(issuedAt)]
        if taskID != nil || startsTask != nil {
            fields.append("ka1.event-metadata.v1")
            fields.append(taskID.map { "taskID:" + Data($0.utf8).base64EncodedString() } ?? "taskID:-")
            fields.append(startsTask.map { "startsTask:" + ($0 ? "true" : "false") } ?? "startsTask:-")
        }
        return Data(fields.joined(separator: "\n").utf8)
    }
    static func state(_ input: [String: Any], source: String? = nil) -> String? {
        guard let session = input["session_id"] as? String, !session.isEmpty, session.utf8.count <= 1024,
              let event = input["hook_event_name"] as? String else { return nil }
        switch event {
        case "UserPromptSubmit", "PostToolUse", "PreCompact", "PostCompact", "ElicitationResult": return "running"
        // A failed or interrupted tool can be followed by model recovery. It
        // does not cancel the parent task, even when is_interrupt is true.
        case "PostToolUseFailure": return "running"
        case "PreToolUse":
            guard let tool = input["tool_name"] as? String, !tool.isEmpty else { return nil }
            return ["AskUserQuestion", "ask_user_question", "AskUser"].contains(tool) ? "waiting" : "running"
        case "PermissionRequest", "PermissionDenied", "Elicitation": return "waiting"
        case "Notification":
            switch input["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog", "idle_prompt", "agent_needs_input": return "waiting"
            case "agent_completed": return "idle"
            default: return nil
            }
        // Stop runs before the vendor aggregates all hook decisions. Neither
        // value of stop_hook_active proves that another hook will not continue.
        case "Stop", "Interrupt": return "idle"
        case "StopFailure": return terminalFailure(input, source: source)
        case "SessionEnd": return terminalSessionEnd(input, source: source)
        default: return nil // SessionStart is not work; child completion is not parent completion.
        }
    }
    /// Shared mapping for the standalone event tool. Returning idle means an
    /// unverified boundary, not permission to release an already-started task.
    static func eventState(source: String, input: [String: Any]) -> String? {
        guard let session = input["session_id"] as? String, !session.isEmpty, session.utf8.count <= 1024,
              let event = input["hook_event_name"] as? String else { return nil }
        if sources.contains(source) { return state(input, source: source) }
        if ["opencode", "pi"].contains(source) {
            switch event {
            case "running", "waiting", "idle": return event
            // Only Pi's adapter emits this after agent_settled, whose public
            // contract excludes automatic continuations. OpenCode idle/error
            // alone has not been verified as a final task outcome.
            case "completed", "cancelled":
                return source == "pi" && metadata(source: source, input: input).taskID != nil ? event : "idle"
            case "failed": return "idle"
            default: return nil
            }
        }
        if codexSources.contains(source) {
            switch event {
            case "UserPromptSubmit", "PostToolUse", "PreCompact": return "running"
            case "PostCompact": return metadata(source: source, input: input).taskID != nil ? "completed" : "idle"
            case "PreToolUse": return input["tool_name"] as? String == "request_user_input" ? "waiting" : "running"
            case "PermissionRequest": return "waiting"
            // Stop is pre-final: another hook may ask the agent to continue.
            // Only the main-turn Interrupt contract cannot be blocked/restarted.
            case "Interrupt": return metadata(source: source, input: input).taskID != nil ? "cancelled" : "idle"
            case "Stop", "SessionEnd": return "idle"
            default: return nil
            }
        }
        if source == "claude-code" {
            switch event {
            case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "ElicitationResult", "PreCompact", "PostCompact": return "running"
            case "PreToolUse": return input["tool_name"] as? String == "AskUserQuestion" ? "waiting" : "running"
            case "Elicitation", "PermissionRequest": return "waiting"
            case "Notification":
                guard let type = input["notification_type"] as? String,
                      ["permission_prompt", "elicitation_dialog"].contains(type) else { return nil }
                return "waiting"
            case "Stop", "Interrupt": return "idle"
            case "StopFailure": return terminalFailure(input, source: source)
            case "SessionEnd": return terminalSessionEnd(input, source: source)
            default: return nil
            }
        }
        if source == "gemini-cli" {
            switch event {
            case "BeforeAgent", "BeforeTool", "AfterTool": return "running"
            // AfterAgent can reject the response and trigger an automatic retry.
            case "AfterAgent": return "idle"
            case "SessionEnd": return terminalSessionEnd(input, source: source)
            case "Notification": return input["notification_type"] as? String == "ToolPermission" ? "waiting" : nil
            default: return nil
            }
        }
        return nil
    }
    private static func terminalFailure(_ input: [String: Any], source: String?) -> String {
        // Require the documented whole-turn API failure discriminator. An
        // absent/unknown error type can also be a hook or tool failure.
        guard ["qoder-desktop", "workbuddy-desktop", "claude-code"].contains(source ?? ""),
              hasTerminalIdentity(source: source, input: input),
              let error = input["error_type"] as? String,
              ["rate_limit", "authentication_failed", "billing_error", "invalid_request", "server_error", "max_output_tokens"].contains(error) else { return "idle" }
        return "failed"
    }
    private static func terminalSessionEnd(_ input: [String: Any], source: String?) -> String {
        guard ["qoder-desktop", "workbuddy-desktop", "claude-code", "gemini-cli"].contains(source ?? ""),
              hasTerminalIdentity(source: source, input: input),
              let reason = input["reason"] as? String else { return "idle" }
        // resume can merely switch away from a session that still owns work;
        // other/new reasons must not turn uncertainty into cancellation.
        if ["clear", "logout", "prompt_input_exit"].contains(reason) { return "cancelled" }
        if source == "gemini-cli" && reason == "exit" { return "cancelled" }
        return "idle"
    }
    private static func hasTerminalIdentity(source: String?, input: [String: Any]) -> Bool {
        guard let source else { return false }
        // Without a reliable turn identity, a delayed end from the prior turn
        // could release a newer task that shares its session ID.
        return metadata(source: source, input: input).taskID != nil
    }
    static func accepts(source: String, bundleID: String) -> Bool {
        switch source {
        case "qoder-desktop": return bundleID == "com.qodercn.app"
        case "workbuddy-desktop": return bundleID == "com.tencent.workbuddy.mac"
        case "zcode-desktop": return bundleID == "dev.zcode.app"
        default: return false
        }
    }
    /// Attribution only, never a running signal. Terminal-launched hooks do
    /// not become desktop events simply because the same brand is open.
    static func hasDesktopParent(source: String) -> Bool {
        var pid = getppid()
        for _ in 0..<16 {
            guard pid > 1 else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid(), info.e_tdev == UInt32.max else { return false }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let executable = String(cString: path)
            if let range = executable.range(of: ".app/Contents/") {
                let root = String(executable[..<range.lowerBound]) + ".app"
                let url = URL(fileURLWithPath: root).appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: url),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let id = plist["CFBundleIdentifier"] as? String,
                   accepts(source: source, bundleID: id) { return true }
            }
            pid = pid_t(info.pbi_ppid)
        }
        return false
    }

    enum CodexProcessRole: Equatable { case cli, appServer, other }
    struct CodexAncestor: Equatable {
        let isCodex: Bool
        let isVerified: Bool
        let role: CodexProcessRole
        let isDesktopHost: Bool
    }
    /// The CLI can be bundled inside a desktop .app and can run without a TTY.
    /// Its role comes from its own command, not the enclosing path or an open
    /// same-brand app. The nearest Codex process owns this hook invocation.
    static func acceptsCodexParent(source: String, ancestors: [CodexAncestor]) -> Bool {
        guard codexSources.contains(source), let index = ancestors.firstIndex(where: \.isCodex) else { return false }
        let codex = ancestors[index]
        guard codex.isVerified else { return false }
        switch codex.role {
        case .cli: return source == "codex-cli"
        case .appServer:
            guard source == "codex-desktop" else { return false }
            for ancestor in ancestors.dropFirst(index + 1) {
                // A secondary app-server launched by a CLI/tool is not the
                // desktop's own backend merely because the UI is farther up.
                if ancestor.isCodex { return false }
                if ancestor.isDesktopHost { return true }
            }
            return false
        case .other: return false
        }
    }
    /// Inspect only the command prefix. Option values and prompt arguments
    /// never affect attribution and must not be logged or stored.
    static func codexProcessRole(arguments: [String]) -> CodexProcessRole {
        guard !arguments.isEmpty else { return .other }
        let valueOptions: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "--enable", "--disable", "-i", "--image", "--local-provider"]
        let switches: Set<String> = ["--oss", "--search", "--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--no-alt-screen", "--strict-config", "--approve-for-me", "--worktree", "--no-daemon"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else { return .other }
                index += 2; continue
            }
            if switches.contains(argument) { index += 1; continue }
            if let option = argument.split(separator: "=", maxSplits: 1).first,
               argument.contains("="), valueOptions.contains(String(option)) { index += 1; continue }
            if argument == "app-server" { return .appServer }
            if ["exec", "e", "resume", "fork", "review"].contains(argument) { return .cli }
            if argument == "--" { return .cli }
            if argument.hasPrefix("-") { return .other }
            // An ordinary positional argument is the interactive CLI prompt.
            if ["agents", "mcp", "mcp-server", "plugin", "debug", "login", "logout", "completion", "apply", "a", "cloud", "sandbox", "features", "remote-control", "app", "update", "doctor", "queue", "archive", "delete", "unarchive", "migrate-rollouts", "exec-server", "help"].contains(argument) { return .other }
            return .cli
        }
        return .cli
    }
    static func hasCodexParent(source: String) -> Bool {
        codexParentSource() == source
    }
    static func codexParentSource() -> String? {
        var pid = getppid()
        var ancestors: [CodexAncestor] = []
        for _ in 0..<24 {
            guard pid > 1 else { break }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid() else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            let executable = URL(fileURLWithPath: String(cString: path)).lastPathComponent
            let isCodex = executable == "codex"
            let verified = isCodex && verifiedOpenAIProcess(pid, identifier: "codex")
            let isHost = ["ChatGPT", "Codex"].contains(executable) && verifiedOpenAIProcess(pid, identifier: "com.openai.codex")
            ancestors.append(CodexAncestor(isCodex: isCodex, isVerified: verified,
                role: verified ? codexProcessRole(arguments: processArguments(pid)) : .other, isDesktopHost: isHost))
            // Once a verified CLI is found, unrelated ancestors cannot turn it
            // into a desktop task; no need to inspect them further.
            if isCodex && (!verified || ancestors.last?.role != .appServer) { break }
            pid = pid_t(info.pbi_ppid)
        }
        return codexSources.first { acceptsCodexParent(source: $0, ancestors: ancestors) }
    }
    private static func verifiedOpenAIProcess(_ pid: pid_t, identifier: String) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    private static func processArguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= 262_144 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 64 else { return [] }
        var index = MemoryLayout<Int32>.size
        while index < size && bytes[index] != 0 { index += 1 } // kernel executable path
        while index < size && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<Int(count) {
            guard index < size else { return [] }
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size, let argument = String(bytes: bytes[start..<index], encoding: .utf8) else { return [] }
            arguments.append(argument); index += 1
        }
        return arguments
    }
}
