import Foundation
import XCTest
@testable import SuperIsland

final class WindowInteractionDiagnosticTests: XCTestCase {
    func testGlobalRateDoesNotBurstAcrossAClockWindowBoundary() {
        var limiter = WindowInteractionDiagnosticLimiter()
        for index in 0..<12 {
            XCTAssertTrue(limiter.admit(component: "cmdTab", event: "a\(index)", now: 1_999_999_999))
            limiter.completedWrite()
        }
        XCTAssertFalse(limiter.admit(component: "cmdTab", event: "next", now: 2_000_000_000))
        XCTAssertTrue(limiter.admit(component: "cmdTab", event: "next", now: 2_999_999_999))
    }

    func testAdmissionBoundsEventRateGlobalRateAndPendingWork() {
        var limiter = WindowInteractionDiagnosticLimiter()
        XCTAssertTrue(limiter.admit(component: "cmdTab", event: "pointer", now: 1_000_000_000))
        limiter.completedWrite()
        XCTAssertFalse(limiter.admit(component: "cmdTab", event: "pointer", now: 1_499_999_999))
        XCTAssertTrue(limiter.admit(component: "cmdTab", event: "pointer", now: 1_500_000_000))
        limiter.completedWrite()
        for index in 0..<10 {
            XCTAssertTrue(limiter.admit(component: "mc", event: "probe\(index)", now: 1_500_000_000))
            limiter.completedWrite()
        }
        XCTAssertFalse(limiter.admit(component: "mc", event: "overflow", now: 1_999_999_999))
        XCTAssertTrue(limiter.admit(component: "mc", event: "overflow", now: 2_000_000_000))
        for index in 0..<15 {
            XCTAssertTrue(limiter.admit(component: "mc", event: "pending\(index)", now: UInt64(index + 3) * 1_000_000_000))
        }
        XCTAssertEqual(limiter.pendingWrites, 16)
        XCTAssertFalse(limiter.admit(component: "mc", event: "blocked", now: 100_000_000_000))
        limiter.completedWrite()
        XCTAssertTrue(limiter.admit(component: "mc", event: "blocked", now: 100_000_000_000))
    }

    func testDiagnosticCodesRejectTextPathsURLsAndUnboundedInput() {
        for value in ["Window title", "/Users/person/document", "https://example.com", "聊天正文", String(repeating: "a", count: 65), ""] {
            XCTAssertFalse(WindowInteractionDiagnosticValue.code(value).isAllowed)
        }
        XCTAssertTrue(WindowInteractionDiagnosticValue.code("scene-mc-root-stabilizing").isAllowed)
        XCTAssertTrue(WindowInteractionDiagnosticValue.integer(123).isAllowed)
        XCTAssertTrue(WindowInteractionDiagnosticValue.flag(false).isAllowed)
    }

    func testProductionAndInvalidMetadataNeverCreateDiagnosticFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.jsonl")
        let production = WindowInteractionDiagnosticRecorder(bundleIdentifier: "com.workview.SuperIsland", fileURL: file)
        production.record(component: "cmdTab", event: "pointer", metadata: ["inside": .flag(true)])
        await flush(production)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let debug = WindowInteractionDiagnosticRecorder(bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier, fileURL: file)
        debug.record(component: "cmdTab", event: "pointer", metadata: ["reason": .code("private window title")])
        await flush(debug)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDebugReadbackAndRotationRetainOnlyBoundedMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.jsonl")
        let recorder = WindowInteractionDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, maximumFileBytes: 700
        )
        for index in 0..<8 {
            recorder.record(component: "cmdTab", event: "sample\(index)", metadata: ["pid": .integer(42), "closable": .flag(true)])
        }
        await flush(recorder)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["state.jsonl", "state.previous.jsonl"])
        for url in files {
            let data = try Data(contentsOf: url)
            XCTAssertLessThanOrEqual(data.count, 700)
            for line in try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\n") {
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                XCTAssertEqual(row["component"] as? String, "cmdTab")
                let metadata = try XCTUnwrap(row["metadata"] as? [String: Any])
                XCTAssertEqual(Set(metadata.keys), ["pid", "closable"])
                XCTAssertEqual(metadata["pid"] as? Int, 42)
            }
        }
    }

    private func flush(_ recorder: WindowInteractionDiagnosticRecorder) async {
        await withCheckedContinuation { continuation in
            recorder.flush { continuation.resume() }
        }
    }
}

final class WindowLifecycleDiagnosticTests: XCTestCase {
    func testRepeatedTransitionsKeepEverySequenceWithoutTimeThrottling() {
        var buffer = WindowLifecycleDiagnosticBuffer<String>()
        for _ in 0..<100 {
            XCTAssertTrue(buffer.append { _ in "registered" })
        }
        XCTAssertEqual(buffer.bufferedCount, 100)
        for expected in 1...100 {
            guard case let .event(sequence, value)? = buffer.popFirst() else {
                return XCTFail("A valid transition was dropped")
            }
            XCTAssertEqual(sequence, Int64(expected))
            XCTAssertEqual(value, "registered")
        }
        XCTAssertFalse(buffer.hasPending)
    }

    func testOverflowRetainsOrderedFinalGapWithoutAnotherEvent() {
        var buffer = WindowLifecycleDiagnosticBuffer<Int>(capacity: 2)
        var constructed = 0
        for _ in 0..<4 {
            buffer.append { sequence in constructed += 1; return Int(sequence) }
        }
        XCTAssertEqual(constructed, 2, "Overflow must not retain or construct event payloads")
        XCTAssertEqual(buffer.popFirst()?.sequenceRange, .init(firstSequence: 1, lastSequence: 1, count: 1))
        XCTAssertFalse(buffer.append { _ in XCTFail("Gap cannot be overtaken"); return 5 })
        XCTAssertEqual(buffer.popFirst()?.sequenceRange, .init(firstSequence: 2, lastSequence: 2, count: 1))
        guard case let .gap(gap)? = buffer.popFirst() else { return XCTFail("Final overflow was lost") }
        XCTAssertEqual(gap, .init(firstSequence: 3, lastSequence: 5, count: 3))
        XCTAssertFalse(buffer.hasPending)
        XCTAssertTrue(buffer.append { Int($0) })
        XCTAssertEqual(buffer.popFirst()?.sequenceRange, .init(firstSequence: 6, lastSequence: 6, count: 1))
    }

    func testBufferCannotBeConfiguredAboveTheProductionBound() {
        var buffer = WindowLifecycleDiagnosticBuffer<Int>(capacity: 10_000)
        for _ in 0..<256 { buffer.append { Int($0) } }
        XCTAssertEqual(buffer.bufferedCount, 128)
        XCTAssertEqual(buffer.lastAssignedSequence, 256)
        for expected in 1...128 {
            XCTAssertEqual(buffer.popFirst()?.sequenceRange.firstSequence, Int64(expected))
        }
        guard case let .gap(gap)? = buffer.popFirst() else { return XCTFail("Expected one compact gap") }
        XCTAssertEqual(gap, .init(firstSequence: 129, lastSequence: 256, count: 128))
        XCTAssertFalse(buffer.hasPending)
    }

    func testProductionAndPrivatePayloadsNeverWriteOrConsumeValidSequences() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("window-lifecycle.jsonl")
        let production = WindowLifecycleDiagnosticRecorder(bundleIdentifier: "com.workview.SuperIsland", fileURL: file)
        production.record(event: "registered", metadata: ["pid": .integer(42)])
        await flush(production)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let debug = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier, fileURL: file
        )
        debug.record(event: "private window title")
        debug.record(event: "registered", metadata: ["/Users/private": .flag(true)])
        debug.record(event: "registered", metadata: ["reason": .code("https://private.example")])
        debug.record(event: "registered", metadata: Dictionary(uniqueKeysWithValues: (0..<17).map {
            ("key\($0)", WindowInteractionDiagnosticValue.integer(Int64($0)))
        }))
        await flush(debug)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        debug.record(event: "registered", metadata: ["pid": .integer(42)])
        await flush(debug)
        let rows = try readRows(file)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["eventSequence"] as? Int, 1)
    }

    func testProductionWriterAutomaticallyDrainsFinalBurstAndGap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("window-lifecycle.jsonl")
        let queue = DispatchQueue(label: "test.lifecycle.final-burst")
        queue.suspend()
        let recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, bufferCapacity: 3, writerQueue: queue
        )
        for _ in 0..<20 { recorder.record(event: "registered", metadata: ["pid": .integer(42)]) }
        queue.resume()
        // Wait for the already scheduled writer, without asking the recorder
        // to flush or generating another event that could conceal the bug.
        await barrier(queue)
        let rows = try readRows(file)
        XCTAssertEqual(rows.compactMap { $0["eventSequence"] as? Int }, [1, 2, 3, 20])
        XCTAssertEqual(rows.prefix(3).compactMap { $0["event"] as? String }, Array(repeating: "registered", count: 3))
        let gap = try XCTUnwrap(rows.last)
        XCTAssertEqual(gap["event"] as? String, "diagnosticGap")
        let metadata = try XCTUnwrap(gap["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["reason"] as? String, "queueOverflow")
        XCTAssertEqual(metadata["firstSequence"] as? Int, 4)
        XCTAssertEqual(metadata["lastSequence"] as? Int, 20)
        XCTAssertEqual(metadata["droppedCount"] as? Int, 17)
        let sessions = Set(rows.compactMap { $0["sessionID"] as? String })
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(sessions.first)))
        for row in rows {
            XCTAssertEqual(row["processIdentifier"] as? Int32, ProcessInfo.processInfo.processIdentifier)
            XCTAssertNotNil(row["buildNumber"] as? String)
            XCTAssertNotNil(row["elapsedMS"] as? UInt64)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(row["timestamp"] as? String)))
        }
        recorder.record(event: "retired")
        await flush(recorder)
        XCTAssertEqual(try readRows(file).last?["eventSequence"] as? Int, 21)
    }

    func testWriteFailureIsReportedWithoutLaterInputAndFlushPersistsRecoveryGap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("window-lifecycle.jsonl")
        // An existing directory at the log path must be preserved, not replaced.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let failures = FailureReports()
        let queue = DispatchQueue(label: "test.lifecycle.write-failure")
        queue.suspend()
        let recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, bufferCapacity: 2, writerQueue: queue,
            reportFailure: { failures.append($0) }
        )
        for _ in 0..<5 { recorder.record(event: "registered") }
        queue.resume()
        await barrier(queue)
        XCTAssertEqual(failures.snapshot(), [.init(firstSequence: 1, lastSequence: 5, count: 5)])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        try FileManager.default.removeItem(at: file)
        // Recovery must not require a new user event, nor replay old payloads.
        await flush(recorder)
        let rows = try readRows(file)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["eventSequence"] as? Int, 5)
        let gap = try XCTUnwrap(rows[0]["metadata"] as? [String: Any])
        XCTAssertEqual(gap["reason"] as? String, "writeFailed")
        XCTAssertEqual(gap["firstSequence"] as? Int, 1)
        XCTAssertEqual(gap["lastSequence"] as? Int, 5)
        XCTAssertEqual(gap["droppedCount"] as? Int, 5)
        recorder.record(event: "retired", metadata: ["windowID": .integer(371)])
        await flush(recorder)
        XCTAssertEqual(try readRows(file).compactMap { $0["eventSequence"] as? Int }, [5, 6])
    }

    func testRotationRetainsOnlyTwoBoundedPrivateFilesInSequenceOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("window-lifecycle.jsonl")
        let recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, maximumFileBytes: 900
        )
        for _ in 0..<24 { recorder.record(event: "registered", metadata: ["pid": .integer(42)]) }
        await flush(recorder)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["window-lifecycle.jsonl", "window-lifecycle.previous.jsonl"])
        let previous = file.deletingPathExtension().appendingPathExtension("previous.jsonl")
        var sequences: [Int] = []
        for url in [previous, file] {
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 900)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let rows = try readRows(url)
            sequences.append(contentsOf: rows.compactMap { $0["eventSequence"] as? Int })
            for row in rows {
                XCTAssertEqual(row["event"] as? String, "registered")
                XCTAssertEqual(Set((try XCTUnwrap(row["metadata"] as? [String: Any])).keys), ["pid"])
            }
        }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(sequences.last, 24)
    }

    func testOversizedRecordReportsFailureInsteadOfExceedingFileBound() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("window-lifecycle.jsonl")
        let queue = DispatchQueue(label: "test.lifecycle.oversized")
        let failures = FailureReports()
        let recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, maximumFileBytes: 1, writerQueue: queue,
            reportFailure: { failures.append($0) }
        )
        recorder.record(event: "registered")
        await barrier(queue)
        XCTAssertEqual(failures.snapshot(), [.init(firstSequence: 1, lastSequence: 1, count: 1)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testConcurrentTransitionsAndRepeatedFlushesKeepCompleteOrderedAccounting() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("window-lifecycle.jsonl")
        let recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier,
            fileURL: file, bufferCapacity: 8
        )
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for index in 0..<64 {
                        recorder.record(event: "registered", metadata: ["worker": .integer(Int64(worker))])
                        if index % 8 == 0 {
                            await withCheckedContinuation { continuation in
                                recorder.flush { continuation.resume() }
                            }
                        }
                    }
                }
            }
        }
        await flush(recorder)
        var expectedSequence = 1
        for row in try readRows(file) {
            let sequence = try XCTUnwrap(row["eventSequence"] as? Int)
            if row["event"] as? String == "diagnosticGap" {
                let gap = try XCTUnwrap(row["metadata"] as? [String: Any])
                XCTAssertEqual(gap["reason"] as? String, "queueOverflow")
                XCTAssertEqual(gap["firstSequence"] as? Int, expectedSequence)
                XCTAssertEqual(gap["lastSequence"] as? Int, sequence)
                XCTAssertEqual(gap["droppedCount"] as? Int, sequence - expectedSequence + 1)
            } else {
                XCTAssertEqual(sequence, expectedSequence)
                XCTAssertEqual(row["event"] as? String, "registered")
            }
            expectedSequence = sequence + 1
        }
        XCTAssertEqual(expectedSequence, 257, "All four producers must be represented by events or explicit gaps")
    }

    private final class FailureReports: @unchecked Sendable {
        private let lock = NSLock()
        private var gaps: [WindowLifecycleDiagnosticGap] = []
        func append(_ gap: WindowLifecycleDiagnosticGap) { lock.withLock { gaps.append(gap) } }
        func snapshot() -> [WindowLifecycleDiagnosticGap] { lock.withLock { gaps } }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func readRows(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func barrier(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func flush(_ recorder: WindowLifecycleDiagnosticRecorder) async {
        await withCheckedContinuation { continuation in recorder.flush { continuation.resume() } }
    }
}
