import Foundation
import Darwin
import Security

/// A pending review transaction is a write barrier even for a production helper
/// which cannot execute this experimental backend. Only ENOENT means absent.
enum BatteryPreferences79Identity {
    static let directory = "/private/var/root/Library/Application Support/com.workview.SuperIsland.BatteryManagementHelper/preferences79"
    static var pending: Bool {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { _ = close(fd) }
        for component in directory.split(separator: "/").map(String.init) {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { return errno != ENOENT }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0, noACL(next) else {
                _ = close(next); return true
            }
            _ = close(fd); fd = next
        }
        for name in ["journal.json", "cleanup-backup.json"] {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT { return true }
        }
        return false
    }
    static func noACL(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { return false }
            var info = stat()
            return fstat(fd, &info) == 0
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }
    #if BATTERY_REVIEW || DEBUG
    static func sealed(executable: URL? = Bundle.main.executableURL) -> Bool {
        guard let executable, executable.lastPathComponent == "BatteryManagementHelper",
              let required = KeepAwakeHelperIdentity.requirement(identifiers: ["com.workview.SuperIsland.BM1Debug"]) else { return false }
        // Info.plist is in a user-writable bundle. Opt-in is accepted only as
        // part of a valid sealed bundle with this helper's signing identity.
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signed = information as? [String: Any], let info = signed[kSecCodeInfoPList as String] as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.workview.SuperIsland.BM1Debug",
              info["BM1Preferences79Review"] as? Bool == true, info["BM1DiagnosticsOnly"] as? Bool != true,
              info["BM1NativeCutoffTrial"] as? Bool != true,
              SecRequirementCreateWithString(required as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { return false }
        // Bind the sealed package's helper bytes to the helper actually running,
        // rather than validating a replacement bundle with another code hash.
        var helper: SecStaticCode?, helperInformation: CFDictionary?
        guard let runningHash = try? BatteryReadWorkerExecutable.kernelCDHash(pid: getpid()),
              SecStaticCodeCreateWithPath(executable as CFURL, [], &helper) == errSecSuccess, let helper,
              SecCodeCopySigningInformation(helper, SecCSFlags(rawValue: kSecCSSigningInformation), &helperInformation) == errSecSuccess,
              (helperInformation as? [String: Any])?[kSecCodeInfoUnique as String] as? Data == runningHash,
              SecStaticCodeCheckValidity(helper, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { return false }
        return true
    }
    #endif
}

#if (BATTERY_HELPER && BATTERY_REVIEW) || DEBUG
/// One root-only lock covers a whole transaction. Atomic replacement plus
/// fsync acknowledges the journal before a separate fixed IO worker may write.
/// The file contains battery preferences only; clients cannot choose its path.
final class BatteryPreferences79JournalStore {
    private var directory: Int32 = -1
    #if DEBUG
    private var testDirectorySync: (() throws -> Void)?
    #endif
    private var lock: Int32 = -1
    private let owner: uid_t
    private let mutating: Bool
    private let maximumBytes = 65_536

    convenience init(mutating: Bool) throws {
        guard getuid() == 0, geteuid() == 0 else { throw Self.failure("试验恢复记录只能由系统辅助程序访问。") }
        try self.init(components: ["private", "var", "root", "Library", "Application Support", BatteryManagementIdentity.label, "preferences79"],
                      owner: 0, mutating: mutating, createFrom: 3)
    }

    #if DEBUG
    /// Tests use a caller-owned temporary directory; this initializer is absent
    /// in both shipping helpers. It is never exposed by the worker or XPC.
    convenience init(testDirectory: URL, mutating: Bool, directorySync: (() throws -> Void)? = nil) throws {
        // Foundation preserves macOS's /var display alias even after
        // resolvingSymlinksInPath. Use realpath before nofollow traversal.
        guard let tempBytes = realpath(NSTemporaryDirectory(), nil) else { throw Self.failure("临时目录无法解析。") }
        defer { free(tempBytes) }
        guard let pathBytes = realpath(testDirectory.path, nil) else { throw Self.failure("测试目录无法解析。") }
        defer { free(pathBytes) }
        let temp = String(cString: tempBytes), path = String(cString: pathBytes)
        guard path.hasPrefix(temp + "/"), path != temp else { throw Self.failure("测试目录必须是独立临时子目录。") }
        try self.init(components: path.split(separator: "/").map(String.init), owner: getuid(), mutating: mutating,
                      createFrom: Int.max, testAnchor: path)
        testDirectorySync = directorySync
    }
    #endif

    private init(components: [String], owner: uid_t, mutating: Bool, createFrom: Int, testAnchor: String? = nil) throws {
        self.owner = owner; self.mutating = mutating
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure("无法打开系统目录锚点。") }
        var walked = ""
        do {
            for (index, component) in components.enumerated() {
                guard !["", ".", ".."].contains(component), !component.contains("/"), !component.utf8.contains(0) else {
                    throw Self.failure("恢复目录分量无效。")
                }
                walked += "/" + component
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, mutating, index >= createFrom {
                    guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { throw Self.failure("无法创建恢复目录。") }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0, errno == ENOENT, !mutating { _ = close(current); return }
                guard next >= 0 else { throw Self.failure("恢复目录分量\(index)不可安全打开（errno \(errno)）。") }
                do {
                    var info = stat()
                    guard fstat(next, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Self.failure("恢复目录类型未知。") }
                    // In test mode only the explicitly supplied final directory
                    // is ours; macOS's temporary ancestors are not task-owned.
                    if testAnchor == nil || walked == testAnchor {
                        guard info.st_uid == owner, info.st_mode & 0o022 == 0 else { throw Self.failure("恢复目录所有权或权限不可信。") }
                        try Self.noACL(next)
                    }
                } catch { _ = close(next); throw error }
                _ = close(current); current = next
            }
            directory = current
            if mutating {
                lock = openat(directory, "transaction.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw Self.failure("无法打开恢复互斥锁。") }
                try protectedFile(lock)
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure("另一个试验操作仍持有恢复记录。") }
            }
        } catch {
            if lock >= 0 { _ = close(lock); lock = -1 }
            _ = close(current); directory = -1
            throw error
        }
    }
    deinit { if lock >= 0 { _ = flock(lock, LOCK_UN); _ = close(lock) }; if directory >= 0 { _ = close(directory) } }

    func load() throws -> Data? {
        // A prepared cleanup backup survives a failed journal unlink/fsync.
        // A corrupt/unsafe leaf never silently falls back to an older copy.
        let journal = try loadFile("journal.json")
        let backup = try loadFile("cleanup-backup.json")
        return journal ?? backup
    }
    private func loadFile(_ name: String) throws -> Data? {
        guard directory >= 0 else { return nil }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.failure("恢复记录不可安全读取。") }
        defer { _ = close(fd) }
        try protectedFile(fd)
        var before = stat(); guard fstat(fd, &before) == 0, before.st_size > 0, before.st_size < maximumBytes else { throw Self.failure("恢复记录大小无效。") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.failure("恢复记录读取失败。") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count < maximumBytes else { throw Self.failure("恢复记录超过上限。") }
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_dev == path.st_dev, after.st_ino == path.st_ino, data.count == before.st_size else {
            throw Self.failure("恢复记录在读取期间改变。")
        }
        return data
    }

    func save(_ data: Data?) throws {
        guard mutating, directory >= 0, lock >= 0 else { throw Self.failure("未持有恢复记录的写锁。") }
        let current = try load() // Neither unsafe leaf may be silently replaced.
        if let data {
            try publish(data, as: "journal.json")
        } else {
            guard let current else { return }
            // Confirm a complete backup durable before deleting the main leaf.
            // If its unlink or directory fsync fails, another daemon can still
            // load this backup and retains the ordinary-control write barrier.
            try publish(current, as: "cleanup-backup.json")
            guard unlinkat(directory, "journal.json", 0) == 0 || errno == ENOENT else { throw Self.failure("恢复记录清理未确认。") }
            try syncDirectory()
            // At this point main-journal deletion is durable and restoration
            // was confirmed before save(nil). A backup reappearing after the
            // final sync fails is conservative cleanup residue, never proof of
            // a hidden outstanding 79 submission.
            guard unlinkat(directory, "cleanup-backup.json", 0) == 0 || errno == ENOENT else { throw Self.failure("恢复备份清理未确认。") }
            try syncDirectory()
        }
    }
    /// Keep the complete old responsibility and explicit new-target proof
    /// durable before removing either pending leaf. This is not restoration.
    func finishHandoff85(expected: Data, receipt: BatteryPreferences79Handoff.Receipt,
                         confirm: (BatteryPreferences79Handoff.Receipt) throws -> Void = BatteryPreferences79HandoffRead.confirm) throws {
        guard mutating, lock >= 0, receipt.policyTransferred == false,
              receipt.disposition == BatteryPreferences79Handoff.reviewDisposition, try load() == expected,
              try JSONDecoder().decode(BatteryPreferences79Transaction.Record.self, from: expected) == receipt.record else {
            throw Self.failure("交接前恢复记录已变化，未清理。")
        }
        let data = try JSONEncoder().encode(receipt)
        let name = "handoff85-" + UUID().uuidString + ".json"
        try publish(data, as: name)
        guard try loadFile(name) == data, try load() == expected else { throw Self.failure("交接归档未确认，恢复记录保留。") }
        try confirm(receipt)
        try save(nil)
    }
    private func publish(_ data: Data, as destination: String) throws {
        guard !data.isEmpty, data.count < maximumBytes else { throw Self.failure("恢复记录编码大小无效。") }
        let name = ".journal-" + UUID().uuidString
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("无法创建恢复检查点。") }
        var published = false
        defer { _ = close(fd); if !published { _ = unlinkat(directory, name, 0) } }
        try protectedFile(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.failure("恢复检查点写入未完成。") }
                offset += count
            }
        }
        try Self.sync(fd)
        guard renameat(directory, name, directory, destination) == 0 else { throw Self.failure("恢复检查点发布失败。") }
        published = true
        try syncDirectory()
    }
    private func syncDirectory() throws {
        #if DEBUG
        try testDirectorySync?()
        #endif
        try Self.sync(directory)
    }
    private func protectedFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == owner, info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw Self.failure("恢复文件所有权、类型或权限不可信。") }
        try Self.noACL(fd)
    }
    private static func noACL(_ fd: Int32) throws {
        guard BatteryPreferences79Identity.noACL(fd) else { throw failure("恢复路径存在附加ACL或ACL未知，未使用。") }
    }
    private static func sync(_ fd: Int32) throws {
        var result: Int32
        repeat { result = fsync(fd) } while result < 0 && errno == EINTR
        guard result == 0 else { throw failure("恢复检查点未确认落盘。") }
    }
    private static func failure(_ text: String) -> BatteryControlError { .recovery(text) }
}
#endif
