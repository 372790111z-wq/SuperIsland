import Foundation
import Darwin
import CryptoKit
import CoreFoundation
import Security

/// Same-user, bounded admission proofs, containing only SHA256 session IDs.
/// This does not read the transcript or infer completion from a missing file.
struct KeepAwakeCodexSessionProof {
    let credential: URL
    var url: URL { credential.appendingPathExtension("sessions.json") }
    private struct Store: Codable { var version = 1; var sessions = Set<String>() }
    private func valid(_ identity: String) -> Bool {
        identity.utf8.count == 64 && identity.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        var info = stat()
        let parent = credential.deletingLastPathComponent().path
        guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func read() throws -> Store {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return Store() }
            throw CocoaError(.fileReadNoPermission)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 524288 else { throw CocoaError(.fileReadNoPermission) }
        let data = try handle.read(upToCount: 524289) ?? Data()
        let store = try JSONDecoder().decode(Store.self, from: data)
        guard store.version == 1, store.sessions.count <= 4096, store.sessions.allSatisfy(valid) else { throw CocoaError(.fileReadCorruptFile) }
        return store
    }
    func contains(_ identity: String) throws -> Bool {
        guard valid(identity) else { return false }
        return try locked { try read().sessions.contains(identity) }
    }
    func remember(_ identity: String) throws {
        guard valid(identity) else { throw CocoaError(.fileReadCorruptFile) }
        try locked {
            var store = try read()
            guard store.sessions.contains(identity) || store.sessions.count < 4096 else { throw CocoaError(.fileWriteOutOfSpace) }
            store.sessions.insert(identity)
            try JSONEncoder().encode(store).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func forget(_ identity: String) throws {
        guard valid(identity) else { return }
        try locked {
            var store = try read()
            guard store.sessions.remove(identity) != nil else { return }
            try JSONEncoder().encode(store).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// WorkBuddy can emit FinalStop for an internal compaction run. Admit only a
/// task's own actor and keep compacted turns unverified until a stronger vendor
/// settlement signal exists. The private store contains hashes, never hook text.
struct KeepAwakeWorkBuddyTurnProof {
    let credential: URL
    struct Turn: Codable {
        var actor: String?
        var role: String?
        var compacted = false
    }
    private struct Store: Codable { var version = 1; var turns: [String: Turn] = [:]; var overflowed = false }
    var url: URL { credential.appendingPathExtension("workbuddy-turns.json") }

    func observe(_ input: [String: Any], finished: Bool = false,
                 delivery: ((Bool) throws -> Bool)? = nil) throws -> Bool {
        guard let turn = KeepAwakeHookContract.workBuddyTurn(input) else {
            _ = try delivery?(false)
            return false
        }
        let parent = credential.deletingLastPathComponent().path
        var info = stat()
        guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { flock(fd, LOCK_UN) }
        var store = Store()
        let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if file >= 0 {
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 1_048_576 else { throw CocoaError(.fileReadNoPermission) }
            store = try JSONDecoder().decode(Store.self, from: handle.read(upToCount: 1_048_577) ?? Data())
            guard store.version == 1, store.turns.count <= 4096,
                  store.turns.allSatisfy({ Self.validHash($0.key) && ($0.value.actor.map(Self.validHash) ?? true)
                    && ($0.value.role.map(Self.validHash) ?? true) }) else { throw CocoaError(.fileReadCorruptFile) }
        } else if errno != ENOENT { throw CocoaError(.fileReadNoPermission) }
        let before = store.turns
        let wasOverflowed = store.overflowed
        let event = input["hook_event_name"] as? String
        let actor = KeepAwakeHookContract.workBuddyActor(input)
        let role = KeepAwakeHookContract.workBuddyRole(input)
        let actorIsWellFormed = KeepAwakeHookContract.workBuddyActorIsWellFormed(input)
        if ["UserPromptSubmit", "PreCompact", "PostCompact"].contains(event ?? ""),
           store.turns[turn] == nil, store.turns.count >= 4096 { store.overflowed = true }
        if event == "UserPromptSubmit", store.turns[turn] == nil,
           KeepAwakeHookContract.metadata(source: "workbuddy-desktop", input: input).startsTask,
           actorIsWellFormed, store.turns.count < 4096, !store.overflowed {
            store.turns[turn] = Turn(actor: actor, role: role)
        }
        if ["PreCompact", "PostCompact"].contains(event ?? ""), store.turns[turn] == nil, store.turns.count < 4096 {
            // A compact boundary can arrive before a delayed prompt hook.
            store.turns[turn] = Turn(actor: nil, role: nil, compacted: true)
        }
        if var admission = store.turns[turn] {
            if event == "PreCompact" || event == "PostCompact" { admission.compacted = true }
            // On first use the prompt hook may run before the actor's role is
            // assigned. Only its own tool hook, before any compaction, can bind it.
            if event == "PreToolUse", !admission.compacted, admission.role == nil,
               actorIsWellFormed, actor == admission.actor, let role { admission.role = role }
            store.turns[turn] = admission
        }
        let verified = store.turns[turn].map {
            !store.overflowed && !$0.compacted && actorIsWellFormed && $0.actor == actor && $0.role != nil && $0.role == role
        } ?? false
        if finished { store.turns.removeValue(forKey: turn) }
        func save() throws {
            let temporary = url.appendingPathExtension(UUID().uuidString + ".tmp")
            let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            defer { try? handle.close(); unlink(temporary.path) }
            try handle.write(contentsOf: JSONEncoder().encode(store))
            try handle.synchronize()
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        // Final verification and authenticated terminal enqueue share this
        // lock with compaction admission; no stale verification escapes it.
        if before != store.turns || wasOverflowed != store.overflowed { try save() }
        if try delivery?(verified) == true, event == "FinalStop", verified {
            store.turns.removeValue(forKey: turn); try save()
        }
        return verified
    }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension KeepAwakeWorkBuddyTurnProof.Turn: Equatable {}

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
    static let codexSessionStarted = "scope.codex.session.start"
    static let codexSessionEnded = "scope.codex.session.end"
    /// Signed control records use reserved IDs, never vendor turn IDs. Only an
    /// explicit root lifecycle callback can open/close a session's own tasks.
    static func codexSessionControl(source: String, input: [String: Any]) -> String? {
        guard codexSources.contains(source), codexHookSession(input) != nil,
              input["agent_id"] == nil || input["agent_id"] is NSNull else { return nil }
        if input["hook_event_name"] as? String == "SessionStart",
           codexRootSessionProof(input) != nil, input["source"] as? String != "compact" {
            return codexSessionStarted
        }
        if input["hook_event_name"] as? String == "SessionEnd", input["reason"] as? String == "other" {
            return codexSessionEnded
        }
        return nil
    }
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
    /// Internal, non-persisted Codex workers also emit generic tool/prompt hooks,
    /// but do not run root SessionStart/SessionEnd or a root notify callback.
    /// An explicit null transcript alone is therefore not task identity. A
    /// legitimate --ephemeral root is admitted by its public SessionStart proof;
    /// explicitly identified user subagents and older wire formats remain valid.
    /// Hook session_id is shared by the root and descendants. agent_id, when
    /// supplied, is the concrete child thread that notify later identifies.
    /// Keep the owner in the source/session/turn key; never join turns globally.
    static func codexHookSession(_ input: [String: Any]) -> String? {
        guard let root = codexIdentity(input["session_id"]) else { return nil }
        if let agent = input["agent_id"], !(agent is NSNull) {
            return codexIdentity(agent).map(anonymousIdentity)
        }
        return anonymousIdentity(root)
    }
    static func codexTaskInputIsIdentified(_ input: [String: Any], verifiedSession: Bool) -> Bool {
        guard codexHookSession(input) != nil else { return false }
        if verifiedSession { return true }
        if codexIdentity(input["agent_id"]) != nil { return true }
        guard let transcript = input["transcript_path"] else { return true } // Older contract.
        guard let path = transcript as? String else { return false }
        return path.hasPrefix("/") && path.utf8.count <= 4096 &&
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func codexRootSessionProof(_ input: [String: Any]) -> String? {
        guard input["hook_event_name"] as? String == "SessionStart",
              input["agent_id"] == nil || input["agent_id"] is NSNull,
              let source = input["source"] as? String,
              ["startup", "resume", "clear", "compact", "fork"].contains(source),
              let session = codexIdentity(input["session_id"]) else { return nil }
        return anonymousIdentity(session)
    }
    /// Only documented same-turn identity is accepted. The raw vendor value
    /// never leaves this process. Version, cwd, transcript and tool IDs cannot
    /// be substituted for task identity.
    static func metadata(source: String, input: [String: Any]) -> Metadata {
        if let control = codexSessionControl(source: source, input: input) {
            return Metadata(taskID: control, startsTask: false)
        }
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
        // ZCode retains its native camelCase trace identity alongside the
        // snake_case hook aliases. Tool IDs and transcript paths are not turns.
        if source == "zcode-desktop", let turn = codexIdentity(input["turnId"]) {
            taskID = anonymousIdentity(turn)
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
    /// Interrupt is an irrevocable main-turn end, including any compaction
    /// currently owned by that turn. Stop and notify cannot provide this proof:
    /// Stop may continue, and notify may precede post-turn compaction.
    static func interruptedCodexCompaction(source: String, input: [String: Any]) -> Metadata? {
        guard codexSources.contains(source), input["hook_event_name"] as? String == "Interrupt",
              input["agent_id"] == nil || input["agent_id"] is NSNull,
              codexHookSession(input) != nil, let turn = codexIdentity(input["turn_id"]) else { return nil }
        return Metadata(taskID: codexCompactionPrefix + anonymousIdentity(turn + "\nka1.codex.compaction.v1"),
                        startsTask: false)
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
    static func workBuddyTurn(_ input: [String: Any]) -> String? {
        guard let session = codexIdentity(input["session_id"]), let generation = codexIdentity(input["generation_id"]) else { return nil }
        return anonymousIdentity(session + "\n" + generation)
    }
    static func workBuddyActor(_ input: [String: Any]) -> String? {
        codexIdentity(input["agent_id"]).map(anonymousIdentity)
    }
    static func workBuddyActorIsWellFormed(_ input: [String: Any]) -> Bool {
        // New desktop roots may have no durable storeId yet. Absence must
        // remain consistent across their hooks; malformed values are not absence.
        input["agent_id"] == nil || codexIdentity(input["agent_id"]) != nil
    }
    static func workBuddyRole(_ input: [String: Any]) -> String? {
        codexIdentity(input["agent_type"]).map(anonymousIdentity)
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
    static func state(_ input: [String: Any], source: String? = nil, verifiedWorkBuddyTurn: Bool = false) -> String? {
        guard let session = input["session_id"] as? String, !session.isEmpty, session.utf8.count <= 1024,
              let event = input["hook_event_name"] as? String else { return nil }
        switch event {
        case "FinalStop":
            guard source == "workbuddy-desktop" else { return nil }
            guard verifiedWorkBuddyTurn, workBuddyTurn(input) != nil,
                  let recovery = input["is_truncation_recovery"] as? NSNumber,
                  CFGetTypeID(recovery) == CFBooleanGetTypeID(), !recovery.boolValue else { return "idle" }
            switch input["final_stop_reason"] as? String {
            case "completed": return "completed"
            case "interrupted", "cancelled": return "cancelled"
            case "failed": return "failed"
            default: return "idle"
            }
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
    static func eventState(source: String, input: [String: Any], verifiedWorkBuddyTurn: Bool = false) -> String? {
        guard let session = input["session_id"] as? String, !session.isEmpty, session.utf8.count <= 1024,
              let event = input["hook_event_name"] as? String else { return nil }
        if sources.contains(source) {
            // Compaction is private admission metadata, not a new task or an
            // outcome. It must not create another hold record without a start.
            if source == "workbuddy-desktop", ["PreCompact", "PostCompact"].contains(event) { return nil }
            return state(input, source: source, verifiedWorkBuddyTurn: verifiedWorkBuddyTurn)
        }
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
            if let control = codexSessionControl(source: source, input: input) {
                return control == codexSessionEnded ? "ended" : "idle"
            }
            switch event {
            case "UserPromptSubmit", "PostToolUse", "PreCompact": return "running"
            case "PostCompact": return metadata(source: source, input: input).taskID != nil ? "completed" : "idle"
            case "PreToolUse": return input["tool_name"] as? String == "request_user_input" ? "waiting" : "running"
            case "PermissionRequest": return "waiting"
            // Stop is pre-final: another hook may ask the agent to continue.
            // Only the main-turn Interrupt contract cannot be blocked/restarted.
            case "Interrupt": return metadata(source: source, input: input).taskID != nil ? "cancelled" : "idle"
            case "Stop": return "idle"
            case "SessionEnd": return nil // Missing/unknown end semantics are not proof.
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
    enum DesktopProcessRole { case other, shell, workBuddyServer, independentCLI }
    struct DesktopAncestor {
        let bundleID: String?
        let appRoot: String?
        let hasTerminal: Bool
        let role: DesktopProcessRole
    }
    /// A desktop WorkBuddy session uses its bundled CLI's serve protocol in a
    /// PTY. A TTY therefore cannot distinguish that worker from an interactive
    /// CLI. Inspect only the entry point and protocol prefix, never task argv.
    static func desktopProcessRole(executable: String, appRoot: String?, arguments: [String]) -> DesktopProcessRole {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if ["sh", "bash", "zsh", "dash"].contains(name) { return .shell }
        if arguments.count >= 2 {
            let entry = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath().path
            if let appRoot, ["app.asar", "app.asar.unpacked"].contains(where: {
                entry == appRoot + "/Contents/Resources/" + $0 + "/cli/bin/codebuddy"
            }) {
                return arguments.count >= 3 && arguments[2] == "--serve" ? .workBuddyServer : .independentCLI
            }
            if ["codebuddy", "codebuddy-lite-wb.mjs"].contains(URL(fileURLWithPath: entry).lastPathComponent) { return .independentCLI }
        }
        return ["codebuddy", "wb"].contains(name) ? .independentCLI : .other
    }
    static func acceptsDesktopParent(source: String, ancestors: [DesktopAncestor]) -> Bool {
        guard sources.contains(source) else { return false }
        var managedRoot: String?
        for ancestor in ancestors {
            if let managedRoot {
                // The managed server must belong directly to the same App's
                // non-terminal host. A CLI or nested server cannot borrow a
                // more distant desktop ancestor to change its attribution.
                return !ancestor.hasTerminal && ancestor.appRoot == managedRoot &&
                    ancestor.role == .other && accepts(source: source, bundleID: ancestor.bundleID ?? "")
            }
            if source == "workbuddy-desktop" {
                if ancestor.role == .independentCLI { return false }
                if ancestor.role == .workBuddyServer {
                    guard accepts(source: source, bundleID: ancestor.bundleID ?? ""), let root = ancestor.appRoot else { return false }
                    managedRoot = root; continue
                }
                if ancestor.hasTerminal && ancestor.role == .shell { continue }
            }
            guard !ancestor.hasTerminal else { return false }
            if accepts(source: source, bundleID: ancestor.bundleID ?? "") { return true }
        }
        return false
    }
    /// Attribution only, never a running signal. Opening a same-brand App or
    /// launching an independent CLI inside a desktop tool cannot start a task.
    static func hasDesktopParent(source: String, startingAt initialPID: pid_t = getppid()) -> Bool {
        var pid = initialPID
        var ancestors: [DesktopAncestor] = []
        for _ in 0..<16 {
            guard pid > 1 else { break }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid() else { return false }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let executable = String(cString: path)
            var appRoot: String?, bundleID: String?
            if let range = executable.range(of: ".app/Contents/") {
                let root = URL(fileURLWithPath: String(executable[..<range.lowerBound]) + ".app")
                    .standardizedFileURL.resolvingSymlinksInPath().path
                let url = URL(fileURLWithPath: root).appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: url),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let id = plist["CFBundleIdentifier"] as? String { appRoot = root; bundleID = id }
            }
            let role = source == "workbuddy-desktop" ? desktopProcessRole(executable: executable, appRoot: appRoot,
                arguments: processArguments(pid, maximumArguments: 3)) : .other
            ancestors.append(.init(bundleID: bundleID, appRoot: appRoot, hasTerminal: info.e_tdev != UInt32.max, role: role))
            // Stop at the first matching host, retaining a following host for
            // serve workers. Avoid sampling unrelated ancestors or their argv.
            if accepts(source: source, bundleID: bundleID ?? ""), role != .workBuddyServer { break }
            pid = pid_t(info.pbi_ppid)
        }
        return acceptsDesktopParent(source: source, ancestors: ancestors)
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
    private static func processArguments(_ pid: pid_t, maximumArguments: Int = 64) -> [String] {
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
        for _ in 0..<min(Int(count), maximumArguments) {
            guard index < size else { return [] }
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size, let argument = String(bytes: bytes[start..<index], encoding: .utf8) else { return [] }
            arguments.append(argument); index += 1
        }
        return arguments
    }
}
