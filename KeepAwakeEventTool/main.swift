import Foundation
import CryptoKit
import Darwin

// Source hook stdin may contain sensitive text. Only allowlisted lifecycle
// metadata affects mapping; never log, persist or forward the original input.
struct Credential: Decodable { let source: String; let generation: String; let key: String; let inbox: String }
struct Event: Codable {
    let source: String; let session: String; let sequence: UInt64; let state: String
    let taskID: String?; let startsTask: Bool?
}
struct Envelope: Codable { let generation: String; let event: Event; let issuedAt: Double; let mac: String }
func run() throws {
    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "--superisland-ka1", (["claude-code", "gemini-cli", "opencode", "pi", "codex-cli", "codex-desktop"] + KeepAwakeHookContract.sources).contains(args[2]) else { return }
    let fd = open(args[3], O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == getuid(), info.st_size <= 4096, info.st_mode & 0o077 == 0 else { close(fd); return }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let credential = try JSONDecoder().decode(Credential.self, from: handle.read(upToCount: 4097) ?? Data())
    try handle.close()
    guard credential.source == args[2], let key = Data(base64Encoded: credential.key) else { return }
    // Bounds memory even when a hook sends a very large prompt or transcript.
    var input = Data()
    while input.count <= 2_097_152 {
        let chunk = try FileHandle.standardInput.read(upToCount: min(65536, 2_097_153 - input.count)) ?? Data()
        if chunk.isEmpty { break }
        input.append(chunk)
    }
    guard input.count <= 2_097_152,
          let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let sessionID = payload["session_id"] as? String, !sessionID.isEmpty,
          payload["hook_event_name"] is String else { return }
    if KeepAwakeHookContract.sources.contains(credential.source) {
        guard KeepAwakeHookContract.hasDesktopParent(source: credential.source) else { return }
    }
    guard let state = KeepAwakeHookContract.eventState(source: credential.source, input: payload) else { return }
    let metadata = KeepAwakeHookContract.metadata(source: credential.source, input: payload)
    let session = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
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
// Gemini and Codex receive a JSON no-op even when the event is ignored or
// credentials have been revoked. Never approve tools or change their policy.
if CommandLine.arguments.count > 2 && ["gemini-cli", "codex-cli", "codex-desktop"].contains(CommandLine.arguments[2]) {
    FileHandle.standardOutput.write(Data("{}".utf8))
}
// A monitoring hook must never block or fail the user's actual AI task.
do { try run() } catch { }
