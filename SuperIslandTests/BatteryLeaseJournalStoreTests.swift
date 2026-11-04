import XCTest
import Darwin
@testable import SuperIsland

final class BatteryLeaseJournalStoreTests: XCTestCase {
    func testCleanupDirectorySyncFailurePreservesReadableRecoveryBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BM1-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("original recovery record".utf8)
        let store = BatteryLeaseJournalStore(directory: directory, owner: getuid())
        try store.save(original)
        var syncs = 0
        let failing = BatteryLeaseJournalStore(directory: directory, owner: getuid(), sync: { fd in
            syncs += 1
            return syncs == 3 ? -1 : fsync(fd)
        })
        XCTAssertThrowsError(try failing.save(nil))
        XCTAssertEqual(try store.load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lease.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lease-cleanup-backup.json").path))
        try store.save(nil)
        XCTAssertNil(try store.load())
    }
    func testRefusesSymlinkInsteadOfTreatingItAsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BM1-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("lease.json"), withDestinationURL: directory.appendingPathComponent("missing"))
        let store = BatteryLeaseJournalStore(directory: directory, owner: getuid())
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data("new".utf8)))
    }
}
