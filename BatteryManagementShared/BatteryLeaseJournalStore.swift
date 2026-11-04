import Foundation
import Darwin

#if BATTERY_HELPER || DEBUG
/// The ordinary lease has one canonical record and a cleanup backup. A failed
/// unlink/directory-fsync must never turn outstanding recovery into absence.
final class BatteryLeaseJournalStore {
    private let directory: URL
    private let name: String
    private let owner: uid_t
    private let sync: (Int32) -> Int32
    init(directory: URL, owner: uid_t = 0, name: String = "lease", sync: @escaping (Int32) -> Int32 = fsync) {
        precondition(name == "lease" || name == "manual-retry")
        self.directory = directory; self.owner = owner; self.name = name; self.sync = sync
    }
    func load() throws -> Data? {
        for name in ["\(name).json", "\(name)-cleanup-backup.json"] {
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { if errno == ENOENT { continue }; throw failure() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_nlink == 1, info.st_size >= 0, info.st_size < 1_048_576 else { throw failure() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let data = try handle.readToEnd(), data.count == info.st_size else { throw failure() }
            return data
        }
        return nil
    }
    func save(_ data: Data?) throws {
        let original = try load()
        if let data { try publish(data, name: "\(name).json"); return }
        guard let original else { return }
        try publish(original, name: "\(name)-cleanup-backup.json")
        guard unlink(directory.appendingPathComponent("\(name).json").path) == 0 || errno == ENOENT else { throw failure() }
        try syncDirectory()
        guard unlink(directory.appendingPathComponent("\(name)-cleanup-backup.json").path) == 0 || errno == ENOENT else { throw failure() }
        try syncDirectory()
    }
    private func publish(_ data: Data, name: String) throws {
        guard data.count < 1_048_576 else { throw failure() }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard sync(fd) == 0 else { throw failure() }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard sync(fd) == 0 else { throw failure() }
    }
    private func failure() -> BatteryControlError { .recovery("控制恢复日志未确认持久保存或清理，保留恢复责任。") }
}
#endif
