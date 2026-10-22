import XCTest
@testable import SuperIsland

final class KeepAwakeCodexRPCTests: XCTestCase {
    private func metadata(_ id: String, status: String = "active", source: Any = "appServer",
                          parent: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "status": ["type": status, "activeFlags": []], "source": source,
                                    "preview": "PRIVATE-PROMPT-MUST-NOT-BE-RETAINED"]
        if let parent { value["parentThreadId"] = parent }
        return ["thread": value]
    }
    private func turn(_ id: String, status: String = "inProgress") -> [String: Any] {
        ["id": id, "status": status, "items": [], "itemsView": "notLoaded"]
    }

    func testReaderUsesOnlyReadOnlyMetadataMethodsAndDiscardsPreview() throws {
        var calls: [String] = []
        let reader = KeepAwakeCodexRPC.Reader { method, params in
            calls.append(method)
            switch method {
            case "thread/loaded/list": return ["data": ["a"]]
            case "thread/read":
                XCTAssertEqual(params["includeTurns"] as? Bool, false)
                return self.metadata("a")
            case "thread/turns/list":
                XCTAssertEqual(params["itemsView"] as? String, "notLoaded")
                return ["data": [self.turn("t")]]
            default: XCTFail("Forbidden operation: \(method)"); return [:]
            }
        }
        let result = try reader.read()
        XCTAssertEqual(calls, ["thread/loaded/list", "thread/read", "thread/turns/list", "thread/read"])
        XCTAssertEqual(result.threads.first?.turns, [.init(id: "t", status: "inProgress")])
        XCTAssertEqual(result.threads.first?.turnsComplete, true)
        XCTAssertFalse(String(reflecting: result).contains("PRIVATE-PROMPT"))
    }

    func testReaderPaginatesThreadAndTurnMetadata() throws {
        var loadedCursors: [String?] = [], turnCursors: [String?] = []
        let reader = KeepAwakeCodexRPC.Reader { method, params in
            switch method {
            case "thread/loaded/list":
                let cursor = params["cursor"] as? String; loadedCursors.append(cursor)
                return cursor == nil ? ["data": ["a"], "nextCursor": "threads-next"] : ["data": ["b"]]
            case "thread/read": return self.metadata(params["threadId"] as! String)
            case "thread/turns/list":
                let cursor = params["cursor"] as? String; turnCursors.append(cursor)
                return cursor == nil ? ["data": [self.turn("t1")], "nextCursor": "turns-next"] :
                    ["data": [self.turn("t0", status: "completed")]]
            default: throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }
        let result = try reader.read()
        XCTAssertEqual(loadedCursors, [nil, "threads-next"])
        XCTAssertEqual(turnCursors, [nil, "turns-next", nil, "turns-next"])
        XCTAssertEqual(result.threads.map(\.id), ["a", "b"])
        XCTAssertTrue(result.threads.allSatisfy { $0.turnsComplete && $0.turns.count == 2 })
    }

    func testCLIAndUnattributedSourcesAreNotMisreportedAsDesktop() throws {
        let ids = ["cli", "exec", "vscode", "unknown", "desktop", "child"]
        let reader = KeepAwakeCodexRPC.Reader { method, params in
            switch method {
            case "thread/loaded/list": return ["data": ids]
            case "thread/read":
                let id = params["threadId"] as! String
                if id == "child" { return self.metadata(id, source: ["subAgent": ["thread_spawn": [:]]], parent: "desktop") }
                return self.metadata(id, source: id == "desktop" ? "appServer" : id)
            case "thread/turns/list": return ["data": [self.turn("t")]]
            default: throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }
        XCTAssertEqual(try reader.read().threads.map(\.id), ["desktop", "child"])
    }

    func testChangedThreadStatusAfterPagingCannotClaimCompleteSnapshot() throws {
        var reads = 0
        let reader = KeepAwakeCodexRPC.Reader { method, _ in
            switch method {
            case "thread/loaded/list": return ["data": ["a"]]
            case "thread/read": reads += 1; return self.metadata("a", status: reads == 1 ? "active" : "idle")
            case "thread/turns/list": return ["data": [self.turn("t", status: "completed")]]
            default: throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }
        let result = try reader.read()
        XCTAssertEqual(result.threads.first?.status, "idle")
        XCTAssertEqual(result.threads.first?.turnsComplete, false)
    }

    func testUnexpectedItemsOrSummaryViewFailsInsteadOfReadingContent() {
        for value in [
            ["id": "t", "status": "completed", "items": [["text": "PRIVATE"]], "itemsView": "full"] as [String: Any],
            ["id": "t", "status": "completed", "items": [], "itemsView": "summary"] as [String: Any]
        ] {
            let reader = KeepAwakeCodexRPC.Reader { method, _ in
                switch method {
                case "thread/loaded/list": return ["data": ["a"]]
                case "thread/read": return self.metadata("a")
                default: return ["data": [value]]
                }
            }
            XCTAssertThrowsError(try reader.read())
        }
    }

    func testRepeatedPaginationCursorIsRejected() {
        let reader = KeepAwakeCodexRPC.Reader { _, params in
            ["data": [(params["cursor"] as? String ?? "first")], "nextCursor": "same"]
        }
        XCTAssertThrowsError(try reader.read())
    }

    func testTurnCapacityIsMarkedIncompleteInsteadOfFinal() throws {
        var reader = KeepAwakeCodexRPC.Reader { method, _ in
            switch method {
            case "thread/loaded/list": return ["data": ["a"]]
            case "thread/read": return self.metadata("a", status: "idle")
            default: return ["data": [self.turn("t", status: "completed")], "nextCursor": "more"]
            }
        }
        reader.maximumTurns = 1
        XCTAssertFalse(try reader.read().threads[0].turnsComplete)
    }

    func testMissingSocketAndOrdinaryFileAreNeverUsedAsEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-socket")
        XCTAssertThrowsError(try KeepAwakeCodexRPC.validateEndpoint(file))
        try Data().write(to: file)
        XCTAssertThrowsError(try KeepAwakeCodexRPC.validateEndpoint(file))
    }
}
