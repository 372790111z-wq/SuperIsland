import Foundation
import Darwin
import CryptoKit
import CoreFoundation

/// Public hook metadata contract. Extra vendor fields and version strings do
/// not affect compatibility. Unsupported events cannot invent running state.
enum KeepAwakeHookContract {
    static let sources = ["qoder-desktop", "workbuddy-desktop", "zcode-desktop"]
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
        return Metadata(taskID: taskID, startsTask: startsTask)
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
        if ["codex-cli", "codex-desktop"].contains(source) {
            switch event {
            case "UserPromptSubmit", "PostToolUse", "PreCompact", "PostCompact": return "running"
            case "PreToolUse": return input["tool_name"] as? String == "request_user_input" ? "waiting" : "running"
            case "PermissionRequest": return "waiting"
            // Parser candidates remain unavailable for installation until
            // client attribution and the complete lifecycle are verified.
            case "Stop", "Interrupt", "SessionEnd": return "idle"
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
}
