import XCTest
@testable import SuperIsland

@MainActor
final class NowPlayingSourceOpenerTests: XCTestCase {
    private typealias Opener = NowPlayingSourceOpener
    private let chrome = "com.google.Chrome"

    private func snapshot(url: String = "https://music.example/old", playing: Bool = true) -> Opener.Snapshot {
        .init(bundleIdentifier: chrome, title: "Song", artist: "Artist", browserURL: url, isPlaying: playing)
    }

    private func tab(id: String = "10", url: String = "https://music.example/live", title: String = "Song",
                     artist: String = "Artist", playing: Bool = true, hasMedia: Bool = true) -> Opener.BrowserTab {
        .init(windowID: "1", tabID: id, url: url, title: title, artist: artist,
              hasMedia: hasMedia, isPlaying: playing)
    }

    private func encoded(_ tabs: [Opener.BrowserTab]) throws -> String {
        try tabs.map { value in
            let payload: [String: Any] = ["url": value.url, "title": value.title, "artist": value.artist,
                                          "hasMedia": value.hasMedia, "isPlaying": value.isPlaying]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return value.windowID + "\t" + value.tabID + "\t" + String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }

    func testStaleURLCannotOverrideLiveTitle() {
        let old = tab(id: "11", url: "https://music.example/old", title: "Different song")
        let current = tab()
        XCTAssertEqual(Opener.selectTab(for: snapshot(), among: [old, current]), current)
        XCTAssertNil(Opener.selectTab(for: snapshot(), among: [old]))
    }

    func testMatchingURLDoesNotChooseArbitraryDuplicateTabs() {
        let first = tab(id: "10"), second = tab(id: "11")
        XCTAssertNil(Opener.selectTab(for: snapshot(url: first.url), among: [first, second]))
        let paused = tab(id: "12", playing: false)
        XCTAssertEqual(Opener.selectTab(for: snapshot(url: first.url), among: [paused, first]), first)
    }

    func testArtistAndActualMediaPreventFalseMatches() {
        XCTAssertNil(Opener.selectTab(for: snapshot(), among: [tab(artist: "Another artist")]))
        XCTAssertNil(Opener.selectTab(for: snapshot(), among: [tab(hasMedia: false)]))
        XCTAssertNil(Opener.selectTab(for: snapshot(), among: [tab(playing: false)]))
        XCTAssertNil(Opener.selectTab(for: snapshot(), among: [tab(url: "chrome://settings")]))
    }

    func testYouTubeTitleAndPausedMediaRemainOpenable() {
        let paused = tab(title: "Song - Artist - YouTube Music", artist: "", playing: false)
        XCTAssertEqual(Opener.selectTab(for: snapshot(playing: false), among: [paused]), paused)
    }

    func testNativeSourceOnlyActivatesExistingUniqueProcess() async {
        var activated: [pid_t] = []
        var scripts = 0
        let service = Opener(dependencies: .init(runningPID: { _ in 123 }, hasAutomationPermission: { _ in false },
            executeScript: { _ in scripts += 1; return nil }, activateApplication: { activated.append($0); return true }))
        let source = Opener.Snapshot(bundleIdentifier: "com.tencent.QQMusicMac", title: "Song", artist: "Artist",
                                    browserURL: "", isPlaying: false)
        let outcome = await service.open(source, browserDetectionAllowed: true, isCurrent: { true })
        XCTAssertEqual(outcome, .openedApp)
        XCTAssertEqual(activated, [123])
        XCTAssertEqual(scripts, 0)
    }

    func testExitedSourceDoesNotStartApplication() async {
        let service = Opener(dependencies: .init(runningPID: { _ in nil }, hasAutomationPermission: { _ in
            XCTFail("Permission must not be queried"); return false
        }, executeScript: { _ in XCTFail("No script for exited source"); return nil }, activateApplication: { _ in
            XCTFail("No activation for exited source"); return true
        }))
        let result = await service.open(snapshot(), browserDetectionAllowed: true, isCurrent: { true })
        XCTAssertEqual(result, .unavailable)
    }

    func testBrowserPrivacySwitchOrDeniedPermissionOnlyActivatesBrowser() async {
        for allowDetection in [false, true] {
            var scripts = 0, activations = 0
            let service = Opener(dependencies: .init(runningPID: { _ in 123 }, hasAutomationPermission: { _ in false },
                executeScript: { _ in scripts += 1; return nil }, activateApplication: { _ in activations += 1; return true }))
            let result = await service.open(snapshot(), browserDetectionAllowed: allowDetection, isCurrent: { true })
            XCTAssertEqual(result, .openedApp)
            XCTAssertEqual(scripts, 0)
            XCTAssertEqual(activations, 1)
        }
    }

    func testSourceChangeAfterReadPreventsTabSelectionAndActivation() async throws {
        let rows = try encoded([tab()])
        var current = true, scripts = 0
        let service = Opener(dependencies: .init(runningPID: { _ in 123 }, hasAutomationPermission: { _ in true },
            executeScript: { _ in scripts += 1; current = false; return rows }, activateApplication: { _ in
                XCTFail("Old source must not steal focus"); return true
            }))
        let result = await service.open(snapshot(), browserDetectionAllowed: true, isCurrent: { current })
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(scripts, 1)
    }

    func testSourceProcessChangeCannotTargetReplacementProcess() async throws {
        let rows = try encoded([tab()])
        var pid: pid_t = 123
        let service = Opener(dependencies: .init(runningPID: { _ in pid }, hasAutomationPermission: { _ in true },
            executeScript: { _ in pid = 124; return rows }, activateApplication: { _ in
                XCTFail("Replacement process must not be activated"); return true
            }))
        let result = await service.open(snapshot(), browserDetectionAllowed: true, isCurrent: { true })
        XCTAssertEqual(result, .unavailable)
    }

    func testMatchedExistingTabRevalidatedBeforeApplicationActivation() async throws {
        let rows = try encoded([tab()])
        var scripts: [String] = [], activations = 0
        let service = Opener(dependencies: .init(runningPID: { _ in 123 }, hasAutomationPermission: { _ in true },
            executeScript: { script in scripts.append(script); return scripts.count == 1 ? rows : "FOCUSED" },
            activateApplication: { _ in activations += 1; return true }))
        let result = await service.open(snapshot(), browserDetectionAllowed: true, isCurrent: { true })
        XCTAssertEqual(result, .openedTab)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[1].contains("(id of t as text) is \"10\""))
        XCTAssertTrue(scripts[1].contains("return \"CHANGED\""))
        XCTAssertEqual(activations, 1)
    }

    func testTabChangedOrReadFailedFallsBackWithoutOpeningNewPage() async throws {
        for firstResult in [nil, "INCOMPLETE", try encoded([tab()])] {
            var scripts = 0, activations = 0
            let service = Opener(dependencies: .init(runningPID: { _ in 123 }, hasAutomationPermission: { _ in true },
                executeScript: { _ in scripts += 1; return scripts == 1 ? firstResult : "CHANGED" },
                activateApplication: { _ in activations += 1; return true }))
            let result = await service.open(snapshot(), browserDetectionAllowed: true, isCurrent: { true })
            XCTAssertEqual(result, .openedApp)
            XCTAssertEqual(activations, 1)
        }
    }

    func testSourceChangeDuringFocusDoesNotActivateOldApplication() async throws {
        let rows = try encoded([tab()])
        var current = true, calls = 0
        let service = Opener(dependencies: .init(runningPID: { _ in 123 }, hasAutomationPermission: { _ in true },
            executeScript: { _ in calls += 1; if calls == 1 { return rows }; current = false; return "FOCUSED" },
            activateApplication: { _ in XCTFail("Changed source must not be activated"); return true }))
        let result = await service.open(snapshot(), browserDetectionAllowed: true, isCurrent: { current })
        XCTAssertEqual(result, .cancelled)
    }

    func testScriptsCannotNavigateCreateTabsOrControlPlayback() throws {
        let dangerous = tab(title: "A \"quote\"\\ newline\n", artist: "'quoted'")
        let scripts = [try XCTUnwrap(Opener.readScript(bundleIdentifier: chrome)),
                       try XCTUnwrap(Opener.focusScript(bundleIdentifier: chrome, tab: dangerous))]
        for script in scripts {
            XCTAssertFalse(script.contains("make new"))
            XCTAssertFalse(script.contains("open location"))
            XCTAssertFalse(script.contains("set URL"))
            XCTAssertFalse(script.contains(".play("))
            XCTAssertFalse(script.contains(".pause("))
            XCTAssertFalse(script.contains("innerText"))
            XCTAssertFalse(script.contains("textContent"))
            XCTAssertTrue(script.contains("with timeout of 1 seconds"))
        }
        XCTAssertNil(Opener.readScript(bundleIdentifier: "com.google.Chrome\"\ndo shell script"))
        XCTAssertNil(Opener.focusScript(bundleIdentifier: "com.apple.Safari", tab: tab()))
        let invalid = Opener.BrowserTab(windowID: "1\"", tabID: "2", url: "https://example.com", title: "Song",
                                       artist: "Artist", hasMedia: true, isPlaying: true)
        XCTAssertNil(Opener.focusScript(bundleIdentifier: chrome, tab: invalid))
    }

    func testDecodeRejectsPartialMalformedOrUnboundedTabInventory() throws {
        let expected = tab(title: "Song\twith\nnewlines")
        XCTAssertEqual(Opener.decodeTabs(try encoded([expected])), [expected])
        XCTAssertNil(Opener.decodeTabs("1\t2\tbad json"))
        XCTAssertNil(Opener.decodeTabs("INCOMPLETE"))
        XCTAssertNil(Opener.decodeTabs(try encoded(Array(repeating: tab(), count: 33))))
    }
}
