import Foundation
import XCTest
@testable import SuperIsland

final class WindowTerminationDiagnosticTests: XCTestCase {
    func testRepeatedEventsRemainCompleteAndOrderedWithoutPointerThrottling() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("termination.jsonl")
        let diagnostics = WindowTerminationDiagnostics(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file
        )

        // No sleep between identical events: applying the pointer recorder's
        // 500 ms throttle, 12-per-second rate or 16-pending limit loses these.
        for index in 1...96 {
            diagnostics.record(.recoveryProgress, metadata: ["attempt": .integer(Int64(index))])
        }
        await flush(diagnostics)

        let rows = try readRows(file)
        XCTAssertEqual(rows.count, 96)
        XCTAssertEqual(rows.compactMap { $0["eventSequence"] as? Int }, Array(1...96))
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, Array(repeating: "recoveryProgress", count: 96))
        XCTAssertEqual(try rows.map { try metadata($0)["attempt"] as? Int }, Array(1...96))
        XCTAssertEqual(Set(rows.compactMap { $0["sessionID"] as? String }).count, 1)
    }

    func testProductionAndUnknownBundleNeverWriteTerminationEvidence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, bundleIdentifier) in ["com.workview.SuperIsland", nil].enumerated() {
            let file = directory.appendingPathComponent("termination-\(index).jsonl")
            let diagnostics = WindowTerminationDiagnostics(bundleIdentifier: bundleIdentifier, fileURL: file)
            diagnostics.record(.requestEntered, metadata: ["attempt": .integer(1)])
            await flush(diagnostics)
            XCTAssertTrue(diagnostics.flushBeforeExit(timeout: 0))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPrivateOrUnboundedMetadataIsRejectedBeforeCreatingFilesOrAssigningSequence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("termination.jsonl")
        let diagnostics = WindowTerminationDiagnostics(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file
        )

        diagnostics.record(.requestEntered, metadata: ["/Users/private/document": .flag(true)])
        for value in ["private window title", "/Users/private", "https://private.example", "聊天正文", String(repeating: "a", count: 65)] {
            diagnostics.record(.requestEntered, metadata: ["reason": .code(value)])
        }
        diagnostics.record(.requestEntered, metadata: Dictionary(uniqueKeysWithValues: (0..<17).map {
            ("field\($0)", WindowInteractionDiagnosticValue.integer(Int64($0)))
        }))
        await flush(diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        diagnostics.record(.requestEntered, metadata: ["attempt": .integer(7), "pending": .flag(false)])
        await flush(diagnostics)
        let rows = try readRows(file)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["eventSequence"] as? Int, 1)
        XCTAssertEqual(Set(try metadata(row).keys), ["attempt", "pending"])
    }

    func testRapidRequestDeferredAndFinishRecordsPreserveEachAttempt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("termination.jsonl")
        let diagnostics = WindowTerminationDiagnostics(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file
        )
        let events: [WindowTerminationDiagnostics.Event] = [
            .requestEntered, .requestDeferred, .deferredTaskStarted,
            .preparationStarted, .recoveryAttempt, .preparationFinished, .deferredTaskFinished
        ]

        for attempt in [41, 42] {
            for event in events {
                diagnostics.record(event, metadata: ["attempt": .integer(Int64(attempt))])
            }
        }
        await flush(diagnostics)

        let rows = try readRows(file)
        XCTAssertEqual(rows.compactMap { $0["eventSequence"] as? Int }, Array(1...14))
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, (events + events).map(\.rawValue))
        XCTAssertEqual(
            try rows.map { try metadata($0)["attempt"] as? Int },
            Array(repeating: 41, count: events.count) + Array(repeating: 42, count: events.count)
        )
    }

    func testRotationRetainsOnlyTwoPrivateBoundedFilesAndNewestSequence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("termination.jsonl")
        let diagnostics = WindowTerminationDiagnostics(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, maximumFileBytes: 900
        )
        for attempt in 1...24 {
            diagnostics.record(.requestEntered, metadata: ["attempt": .integer(Int64(attempt))])
        }
        await flush(diagnostics)

        let sequences = try readRotatedSequences(file, maximumFileBytes: 900)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(sequences.last, 24)
    }

    func testConfiguredMaximumCannotExpandTerminationStreamBeyond262KiB() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("termination.jsonl")
        let diagnostics = WindowTerminationDiagnostics(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, maximumFileBytes: UInt64.max
        )
        let values = Dictionary(uniqueKeysWithValues: (0..<16).map {
            ("field\($0)", WindowInteractionDiagnosticValue.code(String(repeating: "a", count: 64)))
        })
        // Drain each sub-128 burst so this tests disk rotation, not the
        // lifecycle writer's separate in-memory overflow accounting.
        for _ in 0..<8 {
            for _ in 0..<64 { diagnostics.record(.recoveryProgress, metadata: values) }
            await flush(diagnostics)
        }

        let sequences = try readRotatedSequences(file, maximumFileBytes: 262_144)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(sequences.last, 512)
    }

    func testExitFlushTimesOutWithoutDeadlockAndWriterCanRecover() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("termination.jsonl")
        let queue = DispatchQueue(label: "test.termination.suspended-writer")
        queue.suspend()
        var isSuspended = true
        defer { if isSuspended { queue.resume() } }
        let diagnostics = WindowTerminationDiagnostics(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, writerQueue: queue
        )
        diagnostics.record(.requestEntered, metadata: ["attempt": .integer(9)])
        let result = FlushResult()
        let returned = expectation(description: "Exit flush returns while writer remains suspended")

        // Isolate the potentially blocking call so a regression fails via the
        // expectation and the deferred resume still releases its writer.
        DispatchQueue.global(qos: .userInitiated).async {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let flushed = diagnostics.flushBeforeExit(timeout: 0.01)
            result.set(flushed: flushed, elapsed: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        let observed = try XCTUnwrap(result.snapshot())
        XCTAssertFalse(observed.flushed)
        XCTAssertLessThan(observed.elapsed, 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        queue.resume()
        isSuspended = false
        await flush(diagnostics)
        XCTAssertTrue(diagnostics.flushBeforeExit())
        let rows = try readRows(file)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["eventSequence"] as? Int, 1)
        XCTAssertEqual(rows.first?["event"] as? String, "requestEntered")
        XCTAssertEqual(try metadata(XCTUnwrap(rows.first))["attempt"] as? Int, 9)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("termination-tests-\(UUID().uuidString)")
    }

    private func flush(_ diagnostics: WindowTerminationDiagnostics) async {
        await withCheckedContinuation { continuation in
            diagnostics.flush { continuation.resume() }
        }
    }

    private func readRows(_ file: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func metadata(_ row: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(row["metadata"] as? [String: Any])
    }

    private func readRotatedSequences(_ file: URL, maximumFileBytes: Int) throws -> [Int] {
        let files = try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["termination.jsonl", "termination.previous.jsonl"])
        let previous = file.deletingPathExtension().appendingPathExtension("previous.jsonl")
        var sequences: [Int] = []
        for url in [previous, file] {
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, maximumFileBytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            sequences.append(contentsOf: try readRows(url).compactMap { $0["eventSequence"] as? Int })
        }
        return sequences
    }

    private final class FlushResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (flushed: Bool, elapsed: TimeInterval)?

        func set(flushed: Bool, elapsed: TimeInterval) {
            lock.withLock { value = (flushed, elapsed) }
        }

        func snapshot() -> (flushed: Bool, elapsed: TimeInterval)? {
            lock.withLock { value }
        }
    }
}
