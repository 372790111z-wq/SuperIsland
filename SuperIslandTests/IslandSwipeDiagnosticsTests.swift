import AppKit
import Darwin
import XCTest
@testable import SuperIsland

final class IslandSwipeDiagnosticsTests: XCTestCase {
    typealias Log = IslandSwipeDiagnostics

    func testRequiresExactEnvironmentOptInAndWE1Bundle() {
        let bundle = ShelfDropDiagnostics.debugBundleIdentifier
        XCTAssertTrue(Log.isEnabled(environment: ["WE1_SWIPE_DIAGNOSTICS": "1"], bundleIdentifier: bundle))
        for value in ["", "0", "true", "yes"] {
            XCTAssertFalse(Log.isEnabled(environment: ["WE1_SWIPE_DIAGNOSTICS": value], bundleIdentifier: bundle))
        }
        XCTAssertFalse(Log.isEnabled(environment: [:], bundleIdentifier: bundle))
        XCTAssertFalse(Log.isEnabled(environment: ["WE1_SHELF_DIAGNOSTICS": "1"], bundleIdentifier: bundle))
        XCTAssertFalse(Log.isEnabled(environment: ["WE1_SWIPE_DIAGNOSTICS": "1"], bundleIdentifier: nil))
        XCTAssertFalse(Log.isEnabled(environment: ["WE1_SWIPE_DIAGNOSTICS": "1"], bundleIdentifier: "com.workview.SuperIsland"))
    }

    func testDisabledRecorderAndGestureDoNotCreateOutput() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("island-swipe.jsonl")
        let recorder = Log(enabled: false, fileURL: file)
        XCTAssertFalse(recorder.record(Log.Record(event: .switchBefore, module: .weather, reason: .none, values: [:])))
        var rows: [Log.Record] = []
        var trace = IslandSwipeGestureDiagnostics(enabled: false) { rows.append($0) }
        receive(&trace, phase: .began)
        trace.decision(.triggered)
        trace.finish(.ended)
        recorder.flush()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testModuleVocabularyRedactsEveryExtensionIdentifier() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("island-swipe.jsonl")
        let recorder = Log(enabled: true, fileURL: file)
        let privateID = "private-extension-https-example-script-title"
        XCTAssertEqual(Log.Module.code(for: .extension_(privateID)), .extensionModule)
        XCTAssertEqual(Log.Module.code(for: .extension_("another-account-extension")), .extensionModule)
        XCTAssertEqual(Log.Module.code(for: .builtIn(.teleprompter)), .teleprompter)
        XCTAssertEqual(Log.Module.code(for: nil), .none)
        XCTAssertTrue(recorder.record(Log.Record(
            event: .pageAppeared, module: Log.Module.code(for: .extension_(privateID)),
            reason: .none, values: [.state: 2]
        )))
        recorder.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(privateID))
        XCTAssertFalse(text.contains("https"))
        let row = try XCTUnwrap(try records(file).first)
        XCTAssertEqual(Set(row.keys), ["uptimeNanoseconds", "pid", "event", "destination", "code", "values"])
        XCTAssertEqual(row["destination"] as? String, "extensionModule")
        XCTAssertEqual(row["values"] as? [String: Int64], ["state": 2])
    }

    func testHundredsOfEventsEmitOnlyFirstDecisionAndOneSummary() throws {
        var rows: [Log.Record] = []
        var trace = IslandSwipeGestureDiagnostics(enabled: true) { rows.append($0) }
        receive(&trace, phase: .began)
        for index in 1...500 {
            receive(&trace, time: 1 + Double(index) / 10_000, x: 1, y: 0.25)
            trace.decision(.belowThreshold)
            trace.decision(.nestedScrollView)
        }
        receive(&trace, phase: .ended, time: 1.1)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter { $0.event == .gestureReceived }.count, 1)
        XCTAssertEqual(rows.filter { $0.reason == .belowThreshold }.count, 1)
        XCTAssertEqual(rows.filter { $0.reason == .nestedScrollView }.count, 1)
        let summary = try XCTUnwrap(rows.last)
        XCTAssertEqual(summary.event, .gestureSummary)
        XCTAssertEqual(summary.reason, .ended)
        XCTAssertEqual(summary.values[.events], 502)
        XCTAssertEqual(summary.values[.deltaX100], 50_000)
        XCTAssertEqual(summary.values[.deltaY100], 12_500)
        XCTAssertEqual(Set(rows.compactMap { $0.values[.gestureID] }).count, 1)
    }

    func testTimeoutAndNewBeganSummarizeOldGestureBeforeStartingAnother() {
        var rows: [Log.Record] = []
        var trace = IslandSwipeGestureDiagnostics(enabled: true) { rows.append($0) }
        receive(&trace, phase: .began, module: .weather)
        trace.decision(.suppressed)
        receive(&trace, time: 1.5, module: .teleprompter)
        receive(&trace, phase: .began, time: 1.6, module: .shelf)
        trace.finish(.detached)
        let summaries = rows.filter { $0.event == .gestureSummary }
        XCTAssertEqual(summaries.map(\.reason), [.timeout, .restarted, .detached])
        XCTAssertEqual(summaries.map(\.module), [.weather, .teleprompter, .shelf])
    }

    func testMomentumAfterEndDoesNotManufactureMoreGestures() {
        var rows: [Log.Record] = []
        var trace = IslandSwipeGestureDiagnostics(enabled: true) { rows.append($0) }
        receive(&trace, phase: .began)
        trace.decision(.triggered)
        receive(&trace, phase: .ended, time: 1.1)
        let count = rows.count
        for index in 0..<200 {
            receive(&trace, phase: [], momentum: .changed, time: 1.2 + Double(index) / 1_000)
        }
        XCTAssertEqual(rows.count, count)
    }

    func testNotPreciseAndSuppressionAreRecordedOnceWithoutChangingInput() {
        var rows: [Log.Record] = []
        var trace = IslandSwipeGestureDiagnostics(enabled: true) { rows.append($0) }
        receive(&trace, phase: .began, precise: false)
        for index in 1...20 {
            receive(&trace, time: 1 + Double(index) / 1_000, precise: false)
            trace.decision(.suppressed)
        }
        receive(&trace, phase: .cancelled, time: 1.1)
        XCTAssertEqual(rows.filter { $0.reason == .notPrecise }.count, 1)
        XCTAssertEqual(rows.filter { $0.reason == .suppressed }.count, 1)
        XCTAssertEqual(rows.last?.reason, .cancelled)
        XCTAssertEqual(rows.last?.values[.preciseEvents], 1)
    }

    func testNumericConversionDoesNotTrapOnInvalidOrExtremeInput() {
        XCTAssertEqual(Log.integer(.nan), 0)
        XCTAssertEqual(Log.integer(.infinity), 0)
        XCTAssertEqual(Log.integer(Double.greatestFiniteMagnitude), .max)
        XCTAssertEqual(Log.integer(-Double.greatestFiniteMagnitude), .min)
        XCTAssertEqual(Log.integer(42.9), 42)
    }

    func testIndependentWriterRetainsOnlyBoundedMetadata() throws {
        let root = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("island-swipe.jsonl")
        let recorder = Log(enabled: true, fileURL: file)
        for index in 0..<2_100 {
            _ = recorder.record(Log.Record(event: .switchBefore, module: .weather,
                                           reason: .none, values: [.switchID: Int64(index)]))
            if index % 32 == 31 { recorder.flush() }
        }
        recorder.flush()
        let rows = try records(file)
        XCTAssertEqual(rows.count, 2_048)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 512 * 1_024)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shelf-drop.jsonl").path))
    }

    private func receive(
        _ trace: inout IslandSwipeGestureDiagnostics,
        phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = [],
        time: TimeInterval = 1, precise: Bool = true, x: Double = 0, y: Double = 0,
        module: Log.Module = .weather
    ) {
        trace.receive(timestamp: time, phase: phase, momentum: momentum, precise: precise,
                      deltaX: x, deltaY: y, module: module, state: 2, generation: 3)
    }

    private func temporaryURL() throws -> URL {
        // Match the writer's no-symlink policy; Foundation can retain /var.
        let base = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(base) }
        return URL(fileURLWithPath: String(cString: base), isDirectory: true)
            .appendingPathComponent("IslandSwipeDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func records(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
