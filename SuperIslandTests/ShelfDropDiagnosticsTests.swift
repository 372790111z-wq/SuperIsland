import Darwin
import XCTest
@testable import SuperIsland

final class ShelfDropDiagnosticsTests: XCTestCase {
    func testRequiresExactOptInAndWE1Bundle() {
        let bundle = ShelfDropDiagnostics.debugBundleIdentifier
        XCTAssertTrue(ShelfDropDiagnostics.isEnabled(environment: ["WE1_SHELF_DIAGNOSTICS": "1"], bundleIdentifier: bundle))
        for value in ["", "0", "true", "yes"] {
            XCTAssertFalse(ShelfDropDiagnostics.isEnabled(environment: ["WE1_SHELF_DIAGNOSTICS": value], bundleIdentifier: bundle))
        }
        XCTAssertFalse(ShelfDropDiagnostics.isEnabled(environment: [:], bundleIdentifier: bundle))
        XCTAssertFalse(ShelfDropDiagnostics.isEnabled(environment: ["WE1_SHELF_DIAGNOSTICS": "1"], bundleIdentifier: "com.workview.SuperIsland"))
        XCTAssertFalse(ShelfDropDiagnostics.isEnabled(environment: ["WE1_SHELF_DIAGNOSTICS": "1"], bundleIdentifier: nil))
    }

    func testDisabledAndInvalidCodesNeverCreateFiles() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        let disabled = ShelfDropDiagnostics(enabled: false, fileURL: file)
        XCTAssertFalse(disabled.record("perform.begin"))
        disabled.flush()
        let recorder = ShelfDropDiagnostics(enabled: true, fileURL: file)
        for invalid in ["", "private file.txt", "/Users/person/file", "https://example.com", "文件名", "line\nbreak", String(repeating: "a", count: 65)] {
            XCTAssertFalse(recorder.record(invalid))
            XCTAssertFalse(recorder.record("valid", destination: invalid))
            XCTAssertFalse(recorder.record("valid", code: invalid))
            XCTAssertFalse(recorder.record("valid", values: [invalid: 1]))
        }
        XCTAssertFalse(recorder.record("valid", values: Dictionary(uniqueKeysWithValues: (0..<17).map { ("v\($0)", Int64($0)) })))
        recorder.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReadbackContainsOnlyMetadataAndPrivateFilePermissions() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        let recorder = ShelfDropDiagnostics(enabled: true, fileURL: file)
        XCTAssertTrue(recorder.record("load.complete", destination: "tray", values: ["errorCode": -1100, "providers": 2], code: "provider_failed"))
        recorder.flush()
        let rows = try records(file)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(row.keys), ["uptimeNanoseconds", "pid", "event", "destination", "code", "values"])
        XCTAssertEqual(row["event"] as? String, "load.complete")
        XCTAssertEqual(row["destination"] as? String, "tray")
        XCTAssertEqual(row["code"] as? String, "provider_failed")
        XCTAssertEqual(row["pid"] as? Int32, getpid())
        XCTAssertGreaterThan((row["uptimeNanoseconds"] as? NSNumber)?.uint64Value ?? 0, 0)
        XCTAssertEqual(row["values"] as? [String: Int64], ["errorCode": -1100, "providers": 2])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPendingAndTotalLimitsStayBoundedWithoutErasingTrace() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        let queue = DispatchQueue(label: "ShelfDropDiagnosticsTests.blocked")
        let recorder = ShelfDropDiagnostics(enabled: true, fileURL: file, maximumPending: 2, maximumRecords: 3, queue: queue)
        queue.suspend()
        XCTAssertTrue(recorder.record("first"))
        XCTAssertTrue(recorder.record("second"))
        XCTAssertFalse(recorder.record("pending_overflow"))
        queue.resume()
        recorder.flush()
        XCTAssertTrue(recorder.record("third"))
        XCTAssertFalse(recorder.record("total_overflow"))
        recorder.flush()
        XCTAssertEqual(try records(file).compactMap { $0["event"] as? String }, ["first", "second", "third"])
        let prior = try Data(contentsOf: file)
        let restarted = ShelfDropDiagnostics(enabled: true, fileURL: file, maximumRecords: 3)
        restarted.record("after_restart")
        restarted.flush()
        XCTAssertEqual(try Data(contentsOf: file), prior)
    }

    func testByteLimitStopsAppendingWithoutTruncatingExistingTrace() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        let recorder = ShelfDropDiagnostics(enabled: true, fileURL: file, maximumFileBytes: 240)
        recorder.record("first")
        recorder.flush()
        let prior = try Data(contentsOf: file)
        XCTAssertFalse(prior.isEmpty)
        for _ in 0..<10 { recorder.record("next", code: String(repeating: "a", count: 64)) }
        recorder.flush()
        XCTAssertEqual(try Data(contentsOf: file), prior)
        XCTAssertLessThanOrEqual(prior.count, 240)
    }

    func testSymlinkFileAndParentAreNeverFollowed() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("untouched.txt")
        let original = Data("test-owned sentinel".utf8)
        try original.write(to: target)
        let linkedFile = root.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: target)
        let fileRecorder = ShelfDropDiagnostics(enabled: true, fileURL: linkedFile)
        fileRecorder.record("ignored")
        fileRecorder.flush()
        XCTAssertEqual(try Data(contentsOf: target), original)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        let parentRecorder = ShelfDropDiagnostics(enabled: true, fileURL: linkedDirectory.appendingPathComponent("trace.jsonl"))
        parentRecorder.record("ignored")
        parentRecorder.flush()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: realDirectory.path).isEmpty)
    }

    func testConcurrentAdmissionWritesCompleteLinesAndOnlyUpdatedIsThrottled() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        let recorder = ShelfDropDiagnostics(enabled: true, fileURL: file)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            XCTAssertTrue(recorder.record("load.complete", values: ["index": Int64(index)]))
        }
        recorder.flush()
        XCTAssertEqual(try records(file).count, 32)
        XCTAssertTrue(recorder.record("updated"))
        XCTAssertFalse(recorder.record("updated"))
        XCTAssertTrue(recorder.record("perform.begin"))
        XCTAssertTrue(recorder.record("perform.begin"))
        recorder.flush()
        XCTAssertEqual(try records(file).count, 35)
    }

    private func temporaryURL() throws -> URL {
        // Foundation can preserve /var here; the recorder deliberately rejects
        // symlinks, so tests need the actual POSIX path under /private/var.
        let base = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(base) }
        return URL(fileURLWithPath: String(cString: base), isDirectory: true)
            .appendingPathComponent("ShelfDropDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func records(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
