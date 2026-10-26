import Foundation
import CryptoKit
import Darwin
import CoreFoundation

/// File-based IPC: no listening web port, raw hook payloads or task transcripts.
/// Both directory and per-source capability are restricted to the current user.
/// This is not a security boundary against another process of the same user.
struct KeepAwakeMailbox {
    struct Credential: Codable {
        var source: String
        var generation: String
        var key: String
        var inbox: String
    }
    struct Envelope: Codable {
        var generation: String
        var event: KeepAwakeEngine.Event
        var issuedAt: Double
        var mac: String
        var authenticatedBytes: Data {
            KeepAwakeHookContract.authenticatedBytes(generation: generation, source: event.source,
                session: event.session, sequence: event.sequence, state: event.state.rawValue, issuedAt: issuedAt,
                taskID: event.taskID, startsTask: event.startsTask)
        }
    }
    let root: URL
    private(set) var credentials: [String: Credential] = [:]
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var credentialsDirectory: URL { root.appendingPathComponent("credentials", isDirectory: true) }

    mutating func connect(source: String) throws {
        guard KeepAwakeSource.all.contains(where: { $0.id == source }) else { throw CocoaError(.validationMissingMandatoryProperty) }
        for directory in [root, inbox, credentialsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileReadNoPermission) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let credential = Credential(source: source, generation: UUID().uuidString, key: key, inbox: inbox.path)
        let destination = credentialsDirectory.appendingPathComponent(source + ".json")
        // Atomic replacement removes a prior leaf symlink rather than following it.
        try JSONEncoder().encode(credential).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        credentials[source] = credential
    }
    mutating func disconnect(source: String) throws {
        credentials.removeValue(forKey: source)
        let path = credentialsDirectory.appendingPathComponent(source + ".json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    func read(now: Double = Date().timeIntervalSince1970) -> [KeepAwakeEngine.Event] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return [] }
        var accepted: [KeepAwakeEngine.Event] = []
        for file in files.filter({ $0.pathExtension == "json" }).prefix(128) {
            // Never read a symlink or oversized file, including a leaf replaced
            // between directory enumeration and open.
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), info.st_size <= 4096 else { close(fd); continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = try? handle.read(upToCount: 4097)
            try? handle.close()
            // Only files in our private, dedicated inbox are consumed.
            try? FileManager.default.removeItem(at: file)
            guard let data, Self.validMetadata(in: data), let value = try? JSONDecoder().decode(Envelope.self, from: data),
                  let credential = credentials[value.event.source],
                  value.generation == credential.generation,
                  value.issuedAt.isFinite, abs(now - value.issuedAt) <= 30,
                  let key = Data(base64Encoded: credential.key), let mac = Data(base64Encoded: value.mac),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: value.authenticatedBytes, using: SymmetricKey(data: key)) else { continue }
            accepted.append(value.event)
        }
        return accepted.sorted { $0.sequence < $1.sequence }
    }
    private static func validMetadata(in data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = root["event"] as? [String: Any] else { return false }
        // Missing fields mean the legacy wire contract. Explicit null is
        // rejected so adding an unsigned null cannot masquerade as absence.
        if let raw = event["taskID"] {
            guard let task = raw as? String, !task.isEmpty, task.utf8.count <= 128,
                  !task.contains("\n"), !task.contains(":") else { return false }
        }
        if let raw = event["startsTask"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        }
        return true
    }
}
