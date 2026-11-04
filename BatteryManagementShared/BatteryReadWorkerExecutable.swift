import Foundation
import Security
import Darwin

#if BATTERY_HELPER || DEBUG
/// Only the running helper's kernel-bound code may become a root read worker.
/// The user-writable application is an untrusted byte source, never an exec path.
enum BatteryReadWorkerExecutable {
    static let maximumBytes: off_t = 32 * 1024 * 1024
    private static let name = "BatteryManagementHelper"
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func failure(_ message: String) -> Failure { .init(message: message) }

    /// Apple XNU bsd/sys/codesign.h: CS_OPS_CDHASH=5. kern/cs_blobs.h:
    /// CS_CDHASH_LEN=20; kern_proc.c requires exactly this buffer size.
    static func kernelCDHash(pid: pid_t) throws -> Data {
        guard pid > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else {
            throw failure("无法读取内核运行代码身份：csops不可用或PID无效。")
        }
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer, Int) -> Int32
        var bytes = [UInt8](repeating: 0, count: 20)
        let status = bytes.withUnsafeMutableBytes { unsafeBitCast(symbol, to: CSOps.self)(pid, 5, $0.baseAddress!, $0.count) }
        guard status == 0 else { throw failure("内核运行代码身份读取失败（errno=\(errno)）。") }
        guard bytes.contains(where: { $0 != 0 }) else { throw failure("内核运行代码身份为空，未准备只读执行文件。") }
        return Data(bytes)
    }

    static func securedCopyOfCurrentHelper(source: URL) throws -> URL {
        guard getuid() == 0, geteuid() == 0 else { throw failure("只读执行文件保护仅可由真实root辅助程序准备。") }
        guard let current = Bundle.main.executableURL, source.isFileURL,
              current.lastPathComponent == name, source.lastPathComponent == name,
              source.standardizedFileURL == current.standardizedFileURL else {
            throw failure("只允许保护当前正在运行的电池辅助程序。")
        }
        let hash = try kernelCDHash(pid: getpid())
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let directory = try openProtectedDirectory(hash: hex)
        defer { _ = close(directory) }
        let url = URL(fileURLWithPath: "/private/var/root/Library/Caches", isDirectory: true)
            .appendingPathComponent(BatteryManagementIdentity.label, isDirectory: true)
            .appendingPathComponent("read-workers", isDirectory: true).appendingPathComponent(hex, isDirectory: true)
            .appendingPathComponent(name)
        let existing = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 {
            defer { _ = close(existing) }
            try validateCacheFile(existing, directory: directory, entry: name, url: url, hash: hash)
            return url
        }
        guard errno == ENOENT else { throw failure("无法安全打开只读执行缓存（errno=\(errno)）。") }
        let input = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw failure("无法安全打开当前helper字节源（errno=\(errno)）。") }
        defer { _ = close(input) }
        let original = try metadata(input)
        try validateSourceMetadata(original)
        let temporary = ".worker-" + UUID().uuidString
        let output = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure("无法创建独立只读执行缓存（errno=\(errno)）。") }
        var published = false
        defer {
            _ = close(output)
            if !published { _ = unlinkat(directory, temporary, 0) }
        }
        guard fchown(output, 0, 0) == 0 else { throw failure("无法固定执行缓存所有权。") }
        guard let emptyACL = acl_init(0) else { throw failure("无法准备独立缓存ACL。") }
        defer { _ = acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(output, emptyACL, ACL_TYPE_EXTENDED) == 0 else { throw failure("无法清除缓存继承ACL。") }
        var total: off_t = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure("读取helper字节失败（errno=\(errno)）。") }
            if count == 0 { break }
            total += off_t(count)
            guard total <= maximumBytes, total <= original.st_size else { throw failure("helper源在复制中增长或超过大小限制。") }
            var written = 0
            while written < count {
                let amount = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written) }
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw failure("执行缓存写入未完成（errno=\(errno)）。") }
                written += amount
            }
        }
        guard total == original.st_size, sameSnapshot(original, try metadata(input)) else {
            throw failure("helper源在复制期间改变；未发布执行缓存。")
        }
        guard fchmod(output, 0o500) == 0 else { throw failure("无法锁定执行缓存模式。") }
        try synchronize(output)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(temporary)
        try validateCacheFile(output, directory: directory, entry: temporary, url: temporaryURL, hash: hash)
        if renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 {
            published = true
        } else if errno != EEXIST {
            throw failure("无法原子发布只读执行缓存（errno=\(errno)）。")
        }
        // A competing publisher is accepted only after the same full checks.
        let final = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard final >= 0 else { throw failure("发布后的执行缓存不可安全打开。") }
        defer { _ = close(final) }
        try validateCacheFile(final, directory: directory, entry: name, url: url, hash: hash)
        return url
    }

    private static func openProtectedDirectory(hash: String) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("无法打开固定系统根目录。") }
        do {
            try validateDirectory(descriptor)
            let components = ["private", "var", "root", "Library", "Caches", BatteryManagementIdentity.label, "read-workers", hash]
            for (index, component) in components.enumerated() {
                guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.utf8.contains(0) else {
                    throw failure("执行缓存目录分量无效。")
                }
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                // The system anchor /private/var/root must already exist.
                // Only descendants Library/Caches/... may be created here.
                if next < 0, errno == ENOENT, index >= 3 {
                    let made = mkdirat(descriptor, component, 0o700)
                    guard made == 0 || errno == EEXIST else { throw failure("无法创建root私有执行缓存目录。") }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure("固定root缓存父链缺失或不安全（分量\(index)，errno=\(errno)）。") }
                do { try validateDirectory(next) } catch { _ = close(next); throw error }
                _ = close(descriptor); descriptor = next
            }
            return descriptor
        } catch { _ = close(descriptor); throw error }
    }
    private static func validateDirectory(_ fd: Int32) throws {
        let info = try metadata(fd)
        try validateDirectoryMetadata(info)
        try rejectMutatingACL(fd)
    }
    static func validateDirectoryMetadata(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == 0,
              info.st_mode & 0o022 == 0 else { throw failure("执行缓存目录不是不可被其他用户写入的root目录。") }
    }
    static func validateProtectedFileMetadata(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == 0,
              info.st_mode & 0o7777 == 0o500, info.st_nlink == 1,
              info.st_size >= 32, info.st_size <= maximumBytes else {
            throw failure("执行缓存必须为root0500、单链接、大小受限的普通文件。")
        }
    }
    private static func validateSourceMetadata(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 32,
              info.st_size <= maximumBytes else { throw failure("helper字节源不是大小受限的普通文件。") }
    }
    private static func metadata(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("无法确认文件描述符元数据（errno=\(errno)）。") }
        return info
    }
    private static func sameSnapshot(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func validateCacheFile(_ fd: Int32, directory: Int32, entry: String, url: URL, hash: Data) throws {
        let before = try metadata(fd)
        try validateProtectedFileMetadata(before)
        try rejectMutatingACL(fd)
        var header = [UInt8](repeating: 0, count: 32)
        var readCount: Int
        repeat { readCount = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) } } while readCount < 0 && errno == EINTR
        guard readCount == 32 else { throw failure("无法读取执行缓存Mach-O头。") }
        try validateThinMachOHeader(Data(header))
        try validateStaticSignature(at: url, expectedHash: hash)
        var leaf = stat(), absolute = stat()
        guard sameSnapshot(before, try metadata(fd)),
              fstatat(directory, entry, &leaf, AT_SYMLINK_NOFOLLOW) == 0, sameSnapshot(before, leaf),
              lstat(url.path, &absolute) == 0, sameSnapshot(before, absolute) else {
            throw failure("签名核验期间执行缓存路径或内容改变。")
        }
    }
    static func validateThinMachOHeader(_ data: Data) throws {
        guard data.count >= 32 else { throw failure("执行缓存Mach-O头不完整。") }
        func word(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #elseif arch(x86_64)
        let cpu: UInt32 = 0x01000007
        #else
        throw failure("当前编译架构没有受支持的只读执行缓存格式。")
        #endif
        guard word(0) == 0xfeedfacf, word(4) == cpu, word(12) == 2 else {
            throw failure("只允许与编译架构一致的thin Mach-O执行文件。")
        }
    }
    static func validateStaticSignature(at url: URL, expectedHash: Data) throws {
        guard expectedHash.count == 20 else { throw failure("执行缓存期望cdhash长度无效。") }
        var code: SecStaticCode?, requirement: SecRequirement?
        let opened = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard opened == errSecSuccess, let code else { throw failure("执行缓存签名对象不可读（status=\(opened)）。") }
        let hex = expectedHash.map { String(format: "%02x", $0) }.joined()
        let made = SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement)
        guard made == errSecSuccess, let requirement else { throw failure("无法构造精确cdhash要求（status=\(made)）。") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let valid = SecStaticCodeCheckValidity(code, flags, requirement)
        guard valid == errSecSuccess else { throw failure("执行缓存与运行中内核代码身份不匹配（status=\(valid)）。") }
        var information: CFDictionary?
        let copied = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard copied == errSecSuccess,
              let actual = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              actual == expectedHash else { throw failure("执行缓存首选cdhash未精确匹配内核身份。") }
    }
    /// Deliberately stricter than resolving ACL principals: even a root-only
    /// allow-write ACE is rejected. Deny-only/nonmutating ACEs remain valid.
    static func rejectMutatingACL(_ fd: Int32) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            let code = errno
            // Darwin acl_get_fd_np delegates to filesec_get_property; an absent
            // ACL property reports ENOENT even for a valid, open descriptor.
            if code == ENOENT { _ = try metadata(fd); return }
            throw failure("无法确认执行缓存ACL（errno=\(code)）。")
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw failure("执行缓存ACL结构无效。") }
        var entry: acl_entry_t?, selector = Int32(truncatingIfNeeded: ACL_FIRST_ENTRY.rawValue)
        for _ in 0...128 {
            errno = 0
            let result = acl_get_entry(acl, selector, &entry)
            if result == -1, errno == EINVAL { return } // Darwin's end-of-ACL convention.
            guard result == 0, let entry else { throw failure("无法枚举执行缓存ACL。") }
            var tag = ACL_UNDEFINED_TAG
            var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &mask) == 0 else {
                throw failure("无法读取执行缓存ACL权限。")
            }
            guard tag == ACL_EXTENDED_ALLOW || tag == ACL_EXTENDED_DENY else { throw failure("执行缓存ACL存在未知授权类型。") }
            guard !aclGrantsMutation(tag: tag, mask: mask) else { throw failure("执行缓存ACL存在允许修改或替换的授权。") }
            selector = Int32(truncatingIfNeeded: ACL_NEXT_ENTRY.rawValue)
        }
        throw failure("执行缓存ACL条目超限。")
    }
    static func aclGrantsMutation(tag: acl_tag_t, mask: acl_permset_mask_t) -> Bool {
        let readOnly = [ACL_READ_DATA, ACL_EXECUTE, ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_SYNCHRONIZE]
            .reduce(acl_permset_mask_t(0)) { $0 | acl_permset_mask_t($1.rawValue) }
        return tag == ACL_EXTENDED_ALLOW && mask & ~readOnly != 0
    }
    private static func synchronize(_ fd: Int32) throws {
        var result: Int32
        repeat { result = fsync(fd) } while result < 0 && errno == EINTR
        guard result == 0 else { throw failure("执行缓存未确认落盘（errno=\(errno)）。") }
    }
}
#endif
