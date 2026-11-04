import XCTest
@testable import SuperIsland

final class BatteryFixedSMCReadDiagnosticsTests: XCTestCase {
    private func matrix() -> [String: Any] {
        let rows: [[String: Any]] = BatteryFixedSMCReadDiagnostics.keys.flatMap { key, size in
            [["key": key, "command": 9, "error": "metadata denied"],
             ["key": key, "command": 5, "bytes": Array(repeating: 0, count: size)]]
        }
        return ["sourceUID": 0, "pid": 123, "readAt": Date().timeIntervalSince1970,
                "hardwareWrites": false, "records": rows]
    }
    private func text(_ matrix: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: matrix), as: UTF8.self)
    }
    func testMetadataFailureAndDirectReadRemainIndependentObservations() throws {
        let data = try text(matrix())
        XCTAssertNoThrow(try BatteryFixedSMCReadDiagnostics.validate(data, workerPID: 123))
        let reply = try JSONSerialization.data(withJSONObject: ["schema": 1, "value": 1, "phase": "reply", "pid": 123, "diagnostics": data])
        var output = Data()
        for phase in ["initializing", "querying", "query-returned"] {
            output.append(try JSONSerialization.data(withJSONObject: ["schema": 1, "phase": phase]))
            output.append(10)
        }
        output.append(reply)
        XCTAssertLessThan(output.count, 4096)
        XCTAssertEqual(try BatteryNativeReadTransport.decode(output, query: .fixedSMC), 1)
        let errorReply = try JSONSerialization.data(withJSONObject: ["schema": 1, "error": "SMC unavailable", "pid": 123])
        XCTAssertThrowsError(try BatteryNativeReadTransport.decode(errorReply, query: .fixedSMC))
    }
    func testWrongUIDPIDAndBooleanClaimCannotProveRootContext() throws {
        let values: [Any] = [501, false]
        for value in values {
            var m = matrix(); m["sourceUID"] = value
            XCTAssertThrowsError(try BatteryFixedSMCReadDiagnostics.validate(text(m), workerPID: 123))
        }
        XCTAssertThrowsError(try BatteryFixedSMCReadDiagnostics.validate(text(matrix()), workerPID: 124))
    }
    func testMissingDuplicateUnknownAndMalformedBytesAreRejected() throws {
        let original = matrix()["records"] as! [[String: Any]]
        var missing = original; missing.removeLast()
        var duplicate = original; duplicate[7] = duplicate[0]
        var unknown = original; unknown[7]["key"] = "ZZZZ"
        var malformed = original; malformed[7]["bytes"] = [false]
        for rows in [missing, duplicate, unknown, malformed] {
            var m = matrix(); m["records"] = rows
            XCTAssertThrowsError(try BatteryFixedSMCReadDiagnostics.validate(text(m), workerPID: 123))
        }
    }
    func testCompleteFailedMatrixIsEvidenceWithoutAssumedCapability() throws {
        var m = matrix()
        m["records"] = BatteryFixedSMCReadDiagnostics.keys.flatMap { key, _ in
            [9, 5].map { ["key": key, "command": $0, "error": "read denied"] as [String: Any] }
        }
        XCTAssertNoThrow(try BatteryFixedSMCReadDiagnostics.validate(text(m), workerPID: 123))
        XCTAssertFalse(BatteryControlReport().dischargeSupported)
    }
    func testOversizedDiagnosticAndTransportOutputAreRejected() throws {
        XCTAssertThrowsError(try BatteryFixedSMCReadDiagnostics.validate(String(repeating: "x", count: 3001), workerPID: 123))
        XCTAssertThrowsError(try BatteryNativeReadTransport.decode(Data(repeating: 32, count: 4097), query: .fixedSMC))
    }
}
