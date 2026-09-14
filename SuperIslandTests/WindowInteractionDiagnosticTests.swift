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
