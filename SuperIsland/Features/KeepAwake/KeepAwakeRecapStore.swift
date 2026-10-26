import Foundation
import Darwin

/// Only two bounded summaries, never a transcript or an append-only activity log.
actor KeepAwakeRecapStore {
    let root: URL
    static let byteLimit = 2_097_152
    private var prepared = false
    private var savedRevision: UInt64 = 0
    init(root: URL) { self.root = root }
    private func directory(create: Bool) throws -> Int32 {
        if create && !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw CocoaError(.fileReadNoPermission) }
        if create && mkdirat(parent, "Recap", 0o700) != 0 && errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let fd = openat(parent, "Recap", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw CocoaError(.fileReadNoPermission) }
        return fd
    }
    func load() throws -> KeepAwakeRecap {
        guard !Task.isCancelled else { throw CancellationError() }
        let dir = try directory(create: true); defer { close(dir) }; prepared = true
        let fd = openat(dir, "summary.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return KeepAwakeRecap() }; throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size <= Self.byteLimit else { throw CocoaError(.fileReadNoPermission) }
        let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit else { throw CocoaError(.fileReadTooLarge) }
        let ledger = try JSONDecoder().decode(KeepAwakeRecap.self, from: data)
        guard ledger.validate() else { throw CocoaError(.fileReadCorruptFile) }
        return ledger
    }
    @discardableResult func save(_ ledger: KeepAwakeRecap, revision: UInt64) throws -> Bool {
        guard prepared, revision > savedRevision else { return false }
        guard ledger.validate() else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONEncoder().encode(ledger)
        guard data.count <= Self.byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        // A late save cannot recreate a removed root during test/application shutdown.
        let dir = try directory(create: false); defer { close(dir) }
        let name = ".summary-" + UUID().uuidString
        let fd = openat(dir, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd); unlinkat(dir, name, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(dir, name, dir, "summary.json") == 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = fsync(dir); savedRevision = revision; return true
    }
}
