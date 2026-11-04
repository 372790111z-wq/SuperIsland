import XCTest
import Darwin
#if canImport(SuperIsland)
@testable import SuperIsland
#endif

final class BatteryReadWorkerExecutableTests: XCTestCase {
    private func metadata(mode: mode_t, uid: uid_t = 0, links: nlink_t = 1, size: off_t = 1024) -> stat {
        var value = stat(); value.st_mode = mode; value.st_uid = uid; value.st_nlink = links; value.st_size = size
        return value
    }
    private func header(magic: UInt32 = 0xfeedfacf, cpu: UInt32? = nil, type: UInt32 = 2) -> Data {
        #if arch(arm64)
        let compiled: UInt32 = 0x0100000c
        #else
        let compiled: UInt32 = 0x01000007
        #endif
        var data = Data(repeating: 0, count: 32)
        for (offset, word) in [(0, magic), (4, cpu ?? compiled), (12, type)] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        return data
    }
    func testRootDirectoryModesWithNoOtherWriteAreAccepted() {
        for mode: mode_t in [0o700, 0o750, 0o755] {
            XCTAssertNoThrow(try BatteryReadWorkerExecutable.validateDirectoryMetadata(metadata(mode: mode_t(S_IFDIR) | mode)))
        }
    }
    func testUntrustedWritableAndNondirectoryParentsAreRejected() {
        for info in [metadata(mode: mode_t(S_IFDIR) | 0o775), metadata(mode: mode_t(S_IFDIR) | 0o757),
                     metadata(mode: mode_t(S_IFDIR) | 0o755, uid: 501), metadata(mode: mode_t(S_IFLNK) | 0o755)] {
            XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateDirectoryMetadata(info))
        }
    }
    func testProtectedFileRequiresExactRootModeSingleLinkAndBoundedSize() {
        XCTAssertNoThrow(try BatteryReadWorkerExecutable.validateProtectedFileMetadata(metadata(mode: mode_t(S_IFREG) | 0o500)))
        for info in [metadata(mode: mode_t(S_IFREG) | 0o500, uid: 501), metadata(mode: mode_t(S_IFREG) | 0o700),
                     metadata(mode: mode_t(S_IFREG) | 0o550), metadata(mode: mode_t(S_IFREG) | 0o4500),
                     metadata(mode: mode_t(S_IFREG) | 0o500, links: 2), metadata(mode: mode_t(S_IFREG) | 0o500, links: 0),
                     metadata(mode: mode_t(S_IFREG) | 0o500, size: 31),
                     metadata(mode: mode_t(S_IFREG) | 0o500, size: BatteryReadWorkerExecutable.maximumBytes + 1),
                     metadata(mode: mode_t(S_IFIFO) | 0o500)] {
            XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateProtectedFileMetadata(info))
        }
    }
    func testThinExecutableHeaderMustMatchCompilationArchitecture() {
        XCTAssertNoThrow(try BatteryReadWorkerExecutable.validateThinMachOHeader(header()))
        #if arch(arm64)
        let other: UInt32 = 0x01000007
        #else
        let other: UInt32 = 0x0100000c
        #endif
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateThinMachOHeader(header(cpu: other)))
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateThinMachOHeader(header(type: 6)))
    }
    func testFatTruncatedAndNonNativeEndianHeadersAreRejected() {
        for magic: UInt32 in [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca, 0xfeedface, 0xcefaedfe, 0xcffaedfe] {
            XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateThinMachOHeader(header(magic: magic)))
        }
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateThinMachOHeader(Data(repeating: 0, count: 31)))
    }
    func testDenyOnlyAndReadOnlyACLPermissionsDoNotGrantMutation() {
        XCTAssertFalse(BatteryReadWorkerExecutable.aclGrantsMutation(tag: ACL_EXTENDED_DENY, mask: .max))
        let mask = [ACL_READ_DATA, ACL_EXECUTE, ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_SYNCHRONIZE]
            .reduce(acl_permset_mask_t(0)) { $0 | acl_permset_mask_t($1.rawValue) }
        XCTAssertFalse(BatteryReadWorkerExecutable.aclGrantsMutation(tag: ACL_EXTENDED_ALLOW, mask: mask))
    }
    func testAllMutatingAndUnknownAllowRightsFailClosed() {
        for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                           ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
            XCTAssertTrue(BatteryReadWorkerExecutable.aclGrantsMutation(tag: ACL_EXTENDED_ALLOW, mask: acl_permset_mask_t(permission.rawValue)))
        }
        XCTAssertTrue(BatteryReadWorkerExecutable.aclGrantsMutation(tag: ACL_EXTENDED_ALLOW, mask: 1 << 63))
    }
    func testAbsentACLOnAnOpenOrdinaryFileIsNotAnUnknownFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BM1ACL-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = open(directory.appendingPathComponent("file").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }; defer { _ = close(fd) }
        let acl = try XCTUnwrap(acl_init(0)); defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
        XCTAssertNoThrow(try BatteryReadWorkerExecutable.rejectMutatingACL(fd))
    }
    func testAnActualAllowWriteACLOnOwnFixtureIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BM1ACLGrant-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = open(directory.appendingPathComponent("file").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }; defer { _ = close(fd) }
        var acl: acl_t? = acl_init(1)
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        let actualEntry = try XCTUnwrap(entry), actualACL = try XCTUnwrap(acl)
        XCTAssertEqual(acl_set_tag_type(actualEntry, ACL_EXTENDED_ALLOW), 0)
        var qualifier = UUID().uuid
        XCTAssertEqual(withUnsafePointer(to: &qualifier) { acl_set_qualifier(actualEntry, $0) }, 0)
        var permissions: acl_permset_t?
        XCTAssertEqual(acl_get_permset(actualEntry, &permissions), 0)
        let actualPermissions = try XCTUnwrap(permissions)
        XCTAssertEqual(acl_add_perm(actualPermissions, ACL_WRITE_DATA), 0)
        XCTAssertEqual(acl_set_permset(actualEntry, actualPermissions), 0)
        XCTAssertEqual(acl_valid(actualACL), 0)
        XCTAssertEqual(acl_set_fd_np(fd, actualACL, ACL_TYPE_EXTENDED), 0)
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.rejectMutatingACL(fd))
    }
    func testUnreadableACLDescriptorRemainsAnError() {
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.rejectMutatingACL(-1))
    }
    func testInvalidHashLengthAndPIDAreRejectedBeforeAnyFilesystemWork() {
        for length in [0, 19, 21, 32] {
            XCTAssertThrowsError(try BatteryReadWorkerExecutable.validateStaticSignature(
                at: URL(fileURLWithPath: "/does-not-exist-bm1"), expectedHash: Data(repeating: 1, count: length)))
        }
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.kernelCDHash(pid: -1))
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.kernelCDHash(pid: 0))
    }
    func testNonRootCannotEnterTheProtectedCopyPath() throws {
        guard getuid() != 0 || geteuid() != 0 else { throw XCTSkip("This fixture checks the non-root guard only.") }
        XCTAssertThrowsError(try BatteryReadWorkerExecutable.securedCopyOfCurrentHelper(
            source: URL(fileURLWithPath: "/private/var/root/not-a-source"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("真实root"))
        }
    }
}
