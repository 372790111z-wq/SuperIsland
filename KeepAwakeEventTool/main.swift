import Foundation
import CryptoKit
import Darwin

// Source hook stdin may contain sensitive text. Only allowlisted lifecycle
// metadata affects mapping; never log or persist the original input. The
// explicit notify-forward mode passes it only to the pre-existing delegate.
struct Credential: Decodable { let source: String; let generation: String; let key: String; let inbox: String }
struct Event: Codable {
    let source: String; let session: String; let sequence: UInt64; let state: String
    let taskID: String?; let startsTask: Bool?
}
struct Envelope: Codable { let generation: String; let event: Event; let issuedAt: Double; let mac: String }
func privateFile(_ path: String, maximumBytes: Int) throws -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == getuid(), info.st_size <= maximumBytes, info.st_mode & 0o077 == 0 else { close(fd); return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    return data.count <= maximumBytes ? data : nil
}
func run(arguments args: [String] = CommandLine.arguments,
         codexSource: () -> String? = KeepAwakeHookContract.codexParentSource) throws {
    let isHook = args.count == 4 && args[1] == "--superisland-ka1"
    let isCodexNotify = args.count == 5 && args[1] == "--superisland-ka1-codex-notify" && args[2] == "codex-cli"
    let isAutoHook = args.count == 3 && args[1] == "--superisland-ka1-codex-hook-auto"
    let isAutoNotify = args.count == 4 && args[1] == "--superisland-ka1-codex-notify-auto"
    guard isHook || isCodexNotify || isAutoHook || isAutoNotify else { return }
    let source: String, credentialPath: String
    if isAutoHook || isAutoNotify {
        guard let observedSource = codexSource(),
              let data = try privateFile(args[2], maximumBytes: 1_048_576),
              let router = try? JSONDecoder().decode(KeepAwakeHookContract.CodexRouter.self, from: data),
              let path = router.credentialPath(source: observedSource) else { return }
        source = observedSource; credentialPath = path
    } else {
        guard (["claude-code", "gemini-cli", "opencode", "pi"] + KeepAwakeHookContract.codexSources + KeepAwakeHookContract.sources).contains(args[2]) else { return }
        source = args[2]; credentialPath = args[3]
    }
    guard let data = try privateFile(credentialPath, maximumBytes: 4096),
          let credential = try? JSONDecoder().decode(Credential.self, from: data),
          credential.source == source, let key = Data(base64Encoded: credential.key) else { return }
    // notify's JSON is the final argv element, never stdin. Hook stdin may
    // contain sensitive text; both formats are bounded and never persisted.
    var input = isCodexNotify ? Data(args[4].utf8) : isAutoNotify ? Data(args[3].utf8) : Data()
    if isHook || isAutoHook {
        while input.count <= 2_097_152 {
            let chunk = try FileHandle.standardInput.read(upToCount: min(65536, 2_097_153 - input.count)) ?? Data()
            if chunk.isEmpty { break }
            input.append(chunk)
        }
    }
    guard input.count <= 2_097_152,
          let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
    if KeepAwakeHookContract.sources.contains(credential.source) {
        guard KeepAwakeHookContract.hasDesktopParent(source: credential.source) else { return }
    }
    if KeepAwakeHookContract.codexSources.contains(credential.source) && !isAutoHook && !isAutoNotify {
        guard KeepAwakeHookContract.hasCodexParent(source: credential.source) else { return }
    }
    if KeepAwakeHookContract.codexSources.contains(source), isHook || isAutoHook {
        guard KeepAwakeHookContract.codexHookSession(payload) != nil else { return }
        let proof = KeepAwakeCodexSessionProof(credential: URL(fileURLWithPath: credentialPath))
        if let identity = KeepAwakeHookContract.codexRootSessionProof(payload) {
            try proof.remember(identity)
            return // Opening a session is not a running task.
        }
        if !KeepAwakeHookContract.codexTaskInputIsIdentified(payload, verifiedSession: false) {
            let session = (payload["session_id"] as? String).map(KeepAwakeHookContract.anonymousIdentity)
            guard try session.map({ try proof.contains($0) }) ?? false else { return }
        }
    }
    let state: String, metadata: KeepAwakeHookContract.Metadata, session: String
    if isCodexNotify || isAutoNotify {
        guard let notification = KeepAwakeHookContract.codexNotification(payload) else { return }
        state = notification.state; metadata = notification.metadata; session = notification.session
    } else {
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 1024,
              let hookState = KeepAwakeHookContract.eventState(source: credential.source, input: payload) else { return }
        state = hookState; metadata = KeepAwakeHookContract.metadata(source: credential.source, input: payload)
        if KeepAwakeHookContract.codexSources.contains(source) {
            guard let owner = KeepAwakeHookContract.codexHookSession(payload) else { return }
            session = owner
        } else {
            session = KeepAwakeHookContract.anonymousIdentity(sessionID)
        }
    }
    let event = Event(source: credential.source, session: session, sequence: mach_continuous_time(), state: state,
                      taskID: metadata.taskID, startsTask: metadata.startsTask)
    let issuedAt = Date().timeIntervalSince1970
    let bytes = KeepAwakeHookContract.authenticatedBytes(generation: credential.generation, source: event.source,
        session: event.session, sequence: event.sequence, state: state, issuedAt: issuedAt,
        taskID: event.taskID, startsTask: event.startsTask)
    let mac = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key))).base64EncodedString()
    let envelope = Envelope(generation: credential.generation, event: event, issuedAt: issuedAt, mac: mac)
    let directory = URL(fileURLWithPath: credential.inbox, isDirectory: true)
    let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attrs[.type] as? FileAttributeType == .typeDirectory,
          (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          (attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o700 else { return }
    // A crashed/stopped consumer must not allow a long-lived source to fill disk.
    guard try FileManager.default.contentsOfDirectory(atPath: directory.path).count < 512 else { return }
    let output = directory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONEncoder().encode(envelope).write(to: output, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
}
func currentExecutablePath() -> String {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    if proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 { return String(cString: path) }
    return CommandLine.arguments[0]
}
/// Observation never owns the original callback. Every observation return or
/// thrown error reaches execvp, independently of the receipt and credentials.
func forwardCodexNotify(arguments args: [String], toolPath: String,
                        observe: ([String]) throws -> Void) -> Never {
    guard args.count >= 6, args[1] == KeepAwakeHookContract.codexNotifyForwardMode, args[3] == "--",
          KeepAwakeHookContract.validCodexNotifyDelegate(Array(args[4..<(args.count - 1)]), toolPath: toolPath) else { _exit(127) }
    do { try observe([args[0], "--superisland-ka1-codex-notify-auto", args[2], args[args.count - 1]]) } catch { }
    // Reuse the original C argv suffix, including the untouched final JSON.
    // execvp preserves this PID, its parent, environment, cwd and standard FDs.
    let original = CommandLine.unsafeArgv.advanced(by: 4)
    guard let executable = original.pointee else { _exit(127) }
    execvp(executable, original)
    _exit(127)
}
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == KeepAwakeHookContract.codexNotifyForwardMode {
    forwardCodexNotify(arguments: CommandLine.arguments, toolPath: currentExecutablePath(), observe: { try run(arguments: $0) })
}
// Gemini and Codex receive a JSON no-op even when the event is ignored or
// credentials have been revoked. Never approve tools or change their policy.
if CommandLine.arguments.count > 1 && (CommandLine.arguments[1] == "--superisland-ka1-codex-hook-auto"
    || (CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--superisland-ka1"
    && ["gemini-cli", "codex-cli", "codex-desktop"].contains(CommandLine.arguments[2]))) {
    FileHandle.standardOutput.write(Data("{}".utf8))
}
// A monitoring hook must never block or fail the user's actual AI task.
do { try run() } catch { }
