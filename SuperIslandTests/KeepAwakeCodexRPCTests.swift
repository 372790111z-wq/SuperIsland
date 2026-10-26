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

    func testServerCoverageDoesNotFilterByHistoricalSourceOrRequireLoadedParent() throws {
        let ids = ["cli", "exec", "vscode", "unknown", "desktop", "child", "orphan"]
        let reader = KeepAwakeCodexRPC.Reader { method, params in
            switch method {
            case "thread/loaded/list": return ["data": ids]
            case "thread/read":
                let id = params["threadId"] as! String
                if id == "child" { return self.metadata(id, source: ["subAgent": ["thread_spawn": [:]]], parent: "desktop") }
                if id == "orphan" { return self.metadata(id, source: ["subAgent": ["thread_spawn": [:]]], parent: "unloaded-parent") }
                return self.metadata(id, source: id == "desktop" ? "appServer" : id)
            case "thread/turns/list": return ["data": [self.turn("t")]]
            default: throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }
        XCTAssertEqual(try reader.read().threads.map(\.id), ids)
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
            ["id": "t", "status": "completed", "items": [], "itemsView": "summary"] as [String: Any],
            ["id": "t", "status": "completed", "items": []] as [String: Any]
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

    func testProxyArgumentsUseBoundSocketAndHomeWithoutShellEscaping() {
        let profile = fixtureProfile()
        XCTAssertEqual(KeepAwakeCodexRPC.proxyArguments(profile: profile),
                       ["app-server", "proxy", "--sock", profile.socketURL.path])
        let environment = KeepAwakeCodexRPC.proxyEnvironment(profile: profile,
            inherited: ["CODEX_HOME": "/Users/wrong", "HOME": "/Users/original", "PATH": "/usr/bin"])
        XCTAssertEqual(environment["CODEX_HOME"], profile.codexHome.path)
        XCTAssertEqual(environment["HOME"], "/Users/original")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testHandshakeValidatesBoundHomeBeforeMetadataAndNotLoadedRequests() throws {
        let profile = fixtureProfile()
        var calls: [String] = []
        let result = try KeepAwakeCodexRPC.read(profile: profile, request: { method, params in
            calls.append(method)
            switch method {
            case "initialize":
                XCTAssertNil(params["capabilities"])
                return ["codexHome": profile.codexHome.path]
            case "thread/loaded/list": return ["data": ["active"]]
            case "thread/read":
                XCTAssertEqual(params["includeTurns"] as? Bool, false)
                return self.metadata("active", source: "cli")
            case "thread/turns/list":
                XCTAssertEqual(params["itemsView"] as? String, "notLoaded")
                return ["data": [self.turn("turn")]]
            default: XCTFail("Forbidden operation \(method)"); throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }, notification: { method, _ in calls.append(method) })
        XCTAssertEqual(calls, ["initialize", "initialized", "thread/loaded/list", "thread/read", "thread/turns/list", "thread/read"])
        XCTAssertEqual(result.threads.first?.id, "active")
    }

    func testDifferentHandshakeHomeIsRejectedWithoutReadingThreads() {
        var calls: [String] = []
        XCTAssertThrowsError(try KeepAwakeCodexRPC.read(profile: fixtureProfile(), request: { method, _ in
            calls.append(method); return ["codexHome": "/Users/another-profile/.codex"]
        }, notification: { _, _ in XCTFail("Mismatched profile must not initialize") })) {
            guard case KeepAwakeCodexRPC.Failure.profileMismatch = $0 else { return XCTFail("Expected profile mismatch") }
        }
        XCTAssertEqual(calls, ["initialize"])
    }

    func testMissingOrRelativeHandshakeHomeCannotUseDefaultProfile() {
        for value: Any in [NSNull(), "relative/profile", "/Users/invalid\nprofile"] {
            XCTAssertThrowsError(try KeepAwakeCodexRPC.read(profile: fixtureProfile(), request: { method, _ in
                XCTAssertEqual(method, "initialize"); return ["codexHome": value]
            }, notification: { _, _ in XCTFail("Invalid handshake must stop") })) {
                guard case KeepAwakeCodexRPC.Failure.incompatible = $0 else { return XCTFail("Expected incompatible interface") }
            }
        }
    }

    func testUnsupportedTurnMetadataNeverFallsBackToFullHistoryOrResume() {
        let profile = fixtureProfile()
        var calls: [String] = []
        XCTAssertThrowsError(try KeepAwakeCodexRPC.read(profile: profile, request: { method, _ in
            calls.append(method)
            switch method {
            case "initialize": return ["codexHome": profile.codexHome.path]
            case "thread/loaded/list": return ["data": ["active"]]
            case "thread/read": return self.metadata("active")
            case "thread/turns/list": throw KeepAwakeCodexRPC.Failure.incompatible
            default: XCTFail("Forbidden fallback \(method)"); throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }, notification: { _, _ in }))
        XCTAssertEqual(calls, ["initialize", "thread/loaded/list", "thread/read", "thread/turns/list"])
    }

    func testEmptyServerDoesNotInventAThreadForCapabilityChecks() throws {
        let profile = fixtureProfile()
        var calls: [String] = []
        let result = try KeepAwakeCodexRPC.read(profile: profile, request: { method, _ in
            calls.append(method)
            switch method {
            case "initialize": return ["codexHome": profile.codexHome.path]
            case "thread/loaded/list": return ["data": []]
            default: XCTFail("Must not probe invented threads"); throw KeepAwakeCodexRPC.Failure.invalidResponse
            }
        }, notification: { _, _ in })
        XCTAssertTrue(result.threads.isEmpty)
        XCTAssertEqual(calls, ["initialize", "thread/loaded/list"])
    }

    private func fixtureProfile() -> KeepAwakeCodexEnvironment.Profile {
        let home = URL(fileURLWithPath: "/Volumes/Work Disk/用户/Codex Profile", isDirectory: true)
        return .init(executableURL: URL(fileURLWithPath: "/Applications/Renamed Assistant.app/Contents/Resources/codex"),
                     codexHome: home, socketURL: KeepAwakeCodexEnvironment.controlSocket(codexHome: home))
    }
}
