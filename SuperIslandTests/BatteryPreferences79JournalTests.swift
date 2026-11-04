import XCTest
import Darwin
@testable import SuperIsland

final class BatteryPreferences79JournalTests: XCTestCase {
    private func directory() throws -> URL {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Preferences79Store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    func testAtomicRoundTripAndExplicitRemoval() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        XCTAssertNil(try store.load())
        let first = Data("{\"phase\":\"before-write\"}".utf8), second = Data("{\"phase\":\"after-ack\"}".utf8)
        try store.save(first); XCTAssertEqual(try store.load(), first)
        try store.save(second); XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["journal.json", "transaction.lock"])
        try store.save(nil); XCTAssertNil(try store.load())
    }
    func testSecondWriterIsExcludedWhileReadOnlyInspectionWorks() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        try store.save(Data("owned".utf8))
        XCTAssertThrowsError(try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true))
        let reader = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: false)
        XCTAssertEqual(try reader.load(), Data("owned".utf8))
        XCTAssertThrowsError(try reader.save(nil))
    }
    func testSymlinkLeafIsNeverReadReplacedOrFollowed() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let victim = dir.appendingPathComponent("victim")
        try Data("preserve".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("journal.json"), withDestinationURL: victim)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data("replacement".utf8)))
        XCTAssertThrowsError(try store.save(nil))
        XCTAssertEqual(try Data(contentsOf: victim), Data("preserve".utf8))
    }
    func testHardLinkAndReadableByOthersAreRejected() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        try store.save(Data("original".utf8))
        let leaf = dir.appendingPathComponent("journal.json"), alias = dir.appendingPathComponent("alias")
        XCTAssertEqual(link(leaf.path, alias.path), 0)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(chmod(leaf.path, 0o644), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data("replacement".utf8)))
    }
    func testOversizeSaveKeepsPreviousCheckpoint() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let previous = Data("previous".utf8); try store.save(previous)
        XCTAssertThrowsError(try store.save(Data(repeating: 1, count: 65_536)))
        XCTAssertEqual(try store.load(), previous)
    }
    func testCleanupSyncFailureKeepsDurableBackupForAnotherProcess() throws {
        enum Injected: Error { case directorySync }
        let dir = try directory()
        var calls = 0, failAt = Int.max
        let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true, directorySync: {
            calls += 1
            if calls == failAt { throw Injected.directorySync }
        })
        let previous = Data("complete-restoration-record".utf8)
        try store.save(previous)
        failAt = calls + 2 // Backup sync succeeds; journal-unlink sync fails.
        XCTAssertThrowsError(try store.save(nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cleanup-backup.json").path))
        let independentReader = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: false)
        XCTAssertEqual(try independentReader.load(), previous)
        failAt = Int.max
        try store.save(nil)
        XCTAssertNil(try independentReader.load())
    }
    func testBackupPublicationFailureDoesNotDeleteOriginalJournal() throws {
        enum Injected: Error { case directorySync }
        let dir = try directory()
        var fail = false
        let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true, directorySync: {
            if fail { throw Injected.directorySync }
        })
        let previous = Data("retained-original".utf8); try store.save(previous)
        fail = true
        XCTAssertThrowsError(try store.save(nil))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("journal.json")), previous)
        XCTAssertEqual(try store.load(), previous)
    }
    func testUnsafeBackupCannotBeHiddenByValidJournal() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let previous = Data("retained-original".utf8); try store.save(previous)
        let backup = dir.appendingPathComponent("cleanup-backup.json")
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: dir.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data("replacement".utf8)))
        XCTAssertThrowsError(try store.save(nil))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("journal.json")), previous)
    }
    func testCurrentJournalWinsOverOlderCleanupBackupAndBothAreRemoved() throws {
        let dir = try directory(), store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let current = Data("current-record".utf8); try store.save(current)
        let backup = dir.appendingPathComponent("cleanup-backup.json")
        try Data("old-record".utf8).write(to: backup)
        XCTAssertEqual(chmod(backup.path, 0o600), 0)
        XCTAssertEqual(try store.load(), current)
        try store.save(nil)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
    func testUnsafeDirectoryAndRootConstructorFailBeforeWriting() throws {
        let dir = try directory(); XCTAssertEqual(chmod(dir.path, 0o777), 0)
        XCTAssertThrowsError(try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true))
        if getuid() != 0 { XCTAssertThrowsError(try BatteryPreferences79JournalStore(mutating: true)) }
    }
    func testExtendedACLIsRejectedEvenWhenPOSIXOwnerAndModeAreSafe() throws {
        let dir = try directory()
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", dir.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { _ = close(fd) } }
        XCTAssertFalse(BatteryPreferences79Identity.noACL(fd))
        XCTAssertFalse(BatteryPreferences79Identity.noACL(-1))
        XCTAssertThrowsError(try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true))
    }
    func testIORequestRoundTripDoesNotRelaxNormalNativeContract() throws {
        typealias T = BatteryPreferences79Transaction
        let request = BatteryPreferences79IO.Write(desired: .integer(79), expected: .integer(80),
            guards: [.initialChargeLimitSetDate: .real(100), .disabledUntil: .absent,
                     .mclOverridenUntilDate: .absent, .mclSavedTargetSoC: .absent],
            bootID: UUID().uuidString, expiresContinuous: 2, controlDeadline: 60, restoring: false)
        let encoded = try BatteryPreferences79IO.encode(request)
        let decoded: BatteryPreferences79IO.Write = try BatteryPreferences79IO.decode(encoded)
        XCTAssertEqual(decoded.desired, T.Value.integer(79))
        XCTAssertFalse(BatteryNativeReadQuery.limit.accepts(79))
        XCTAssertTrue(BatteryNativeReadQuery.limit.accepts(80))
        XCTAssertThrowsError(try BatteryPreferences79IO.decode(String(repeating: "a", count: 32_768)) as BatteryPreferences79IO.Write)
    }
}
