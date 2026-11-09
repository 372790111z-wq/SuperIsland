import XCTest
import SwiftUI
@testable import SuperIsland

final class MusicHoverPolicyTests: XCTestCase {
    func testOnlyEnabledPlayingNonEmptyMusicShowsPreview() {
        XCTAssertTrue(MusicHoverPolicy.showsPreview(enabled: true, playing: true, title: "Song"))
        XCTAssertFalse(MusicHoverPolicy.showsPreview(enabled: false, playing: true, title: "Song"))
        XCTAssertFalse(MusicHoverPolicy.showsPreview(enabled: true, playing: false, title: "Song"))
        XCTAssertFalse(MusicHoverPolicy.showsPreview(enabled: true, playing: true, title: " \n"))
    }
    func testQQRejectsUnrelatedFavoriteLabelsAndUnknownModes() {
        XCTAssertEqual(QQMusicControlAdapter.favoriteState(description: "添加到我喜欢"), false)
        XCTAssertEqual(QQMusicControlAdapter.favoriteState(description: "从我喜欢删除"), true)
        XCTAssertNil(QQMusicControlAdapter.favoriteState(description: "收藏"))
        XCTAssertNil(QQMusicControlAdapter.favoriteState(description: "加载中"))
        XCTAssertNil(QQMusicControlAdapter.playbackMode(description: "列表循环"))
        for mode in MusicPlaybackMode.allCases {
            XCTAssertEqual(QQMusicControlAdapter.playbackMode(description: "播放模式（\(mode.rawValue)）"), mode)
        }
        XCTAssertEqual(MusicPlaybackMode.sequential.next, .repeatOne)
        XCTAssertEqual(MusicPlaybackMode.repeatOne.next, .shuffle)
        XCTAssertEqual(MusicPlaybackMode.shuffle.next, .sequential)
    }
    func testTwoModeSceneCyclesWithoutRequiringShuffle() {
        var state = MusicAdvancedSnapshot(mode: .sequential, availableModes: [.repeatOne, .sequential])
        XCTAssertEqual(state.nextMode, .repeatOne)
        state.mode = .repeatOne
        XCTAssertEqual(state.nextMode, .sequential)
    }
    func testThreeModeSceneKeepsProductOrderRegardlessOfMenuOrder() {
        var state = MusicAdvancedSnapshot(mode: .sequential, availableModes: [.shuffle, .repeatOne, .sequential])
        XCTAssertEqual(state.nextMode, .repeatOne)
        state.mode = .repeatOne; XCTAssertEqual(state.nextMode, .shuffle)
        state.mode = .shuffle; XCTAssertEqual(state.nextMode, .sequential)
    }
    func testUnknownMissingOrOnlyCurrentModeDoesNotGuessATarget() {
        XCTAssertNil(MusicAdvancedSnapshot(mode: nil, availableModes: MusicPlaybackMode.allCases).nextMode)
        XCTAssertNil(MusicAdvancedSnapshot(mode: .shuffle, availableModes: [.sequential, .repeatOne]).nextMode)
        XCTAssertNil(MusicAdvancedSnapshot(mode: .sequential, availableModes: []).nextMode)
        XCTAssertNil(MusicAdvancedSnapshot(mode: .sequential, availableModes: [.sequential, .sequential]).nextMode)
    }
    func testTrackIdentityRequiresExactTitleAndArtist() {
        let description = "歌曲名：Song - 歌手名：Artist"
        XCTAssertTrue(QQMusicControlAdapter.trackMatches(description: description, title: "Song", artist: "Artist"))
        XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: description, title: "Song", artist: "Other"))
        XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: description, title: "Song", artist: ""))
        XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: "推荐：" + description, title: "Song", artist: "Artist"))
    }
    func testQQMultiArtistCreditsAllowSystemLeadArtist() {
        let description = "歌曲名：Song (original ver) - 歌手名：Lead/Guest"
        XCTAssertTrue(QQMusicControlAdapter.trackMatches(description: description, title: "Song (original ver)", artist: "Lead"))
        XCTAssertTrue(QQMusicControlAdapter.trackMatches(description: description, title: "Song (original ver)", artist: "Lead/Guest"))
        XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: description, title: "Song", artist: "Lead"))
        XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: description, title: "Song (original ver)", artist: "Guest"))
        XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: description, title: "Song (original ver)", artist: "Lea"))
    }
    func testQQArtistCompatibilityRejectsMalformedAndUnknownSeparators() {
        for credits in ["Lead/", "/Lead", "Lead//Guest", "Lead & Guest", "Lead, Guest", "LeadX/Guest"] {
            XCTAssertFalse(QQMusicControlAdapter.trackMatches(description: "歌曲名：Song - 歌手名：\(credits)", title: "Song", artist: "Lead"), credits)
        }
        XCTAssertTrue(QQMusicControlAdapter.trackMatches(description: "歌曲名：Song - 歌手名：Lead / Guest", title: "Song", artist: "Lead"))
    }
}

private actor ControlledMusicAdapter: MusicAdvancedAdapter {
    var reads = 0
    var actions: [MusicAdvancedAction] = []
    var pending: CheckedContinuation<MusicAdvancedSnapshot, Never>?
    var actionFence: MusicControlFence?
    var ready = MusicAdvancedSnapshot(favorite: false, mode: .sequential, availableModes: MusicPlaybackMode.allCases, canFavorite: true, canSetMode: true)
    func setSnapshot(_ snapshot: MusicAdvancedSnapshot) { ready = snapshot }
    func read(_ context: MusicControlContext, fence: MusicControlFence) async -> MusicAdvancedSnapshot { reads += 1; return ready }
    func apply(_ action: MusicAdvancedAction, context: MusicControlContext, fence: MusicControlFence) async -> MusicAdvancedSnapshot {
        actions.append(action); actionFence = fence
        return await withCheckedContinuation { pending = $0 }
    }
    func finish(_ result: MusicAdvancedSnapshot) { pending?.resume(returning: result); pending = nil }
    var count: Int { actions.count }
    var lastAction: MusicAdvancedAction? { actions.last }
    var requestIsValid: Bool { actionFence?.isValid ?? false }
}

@MainActor
final class MusicAdvancedControlsTests: XCTestCase {
    private func context(_ track: String = "one", bundle: String = QQMusicControlAdapter.bundleID) -> MusicControlContext {
        .init(bundleID: bundle, processID: 123, launchDate: Date(timeIntervalSince1970: 10), trackID: track, title: track, artist: "artist")
    }
    private func ready(_ service: NowPlayingAdvancedControls) async {
        for _ in 0..<100 { if !service.isBusy { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Read did not finish")
    }
    private func waitForAction(_ adapter: ControlledMusicAdapter) async {
        for _ in 0..<100 { if await adapter.count > 0 { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Action did not start")
    }
    func testSingleFlightAndNoOptimisticFavoriteOnAmbiguousResult() async {
        let adapter = ControlledMusicAdapter()
        let controls = NowPlayingAdvancedControls(adapter: adapter)
        controls.updateContext(context()); controls.refresh(); await ready(controls)
        controls.toggleFavorite(); controls.toggleFavorite(); controls.cycleMode()
        await waitForAction(adapter)
        let count = await adapter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(controls.snapshot.favorite, false)
        await adapter.finish(.init(message: "无法确认")); await ready(controls)
        XCTAssertNil(controls.snapshot.favorite)
        XCTAssertFalse(controls.snapshot.canFavorite)
        controls.toggleFavorite()
        let after = await adapter.count
        XCTAssertEqual(after, 1)
        controls.refresh(); await ready(controls)
        XCTAssertEqual(controls.snapshot.favorite, false)
    }
    func testTrackChangeCancelsFenceAndDiscardsLateSuccess() async {
        let adapter = ControlledMusicAdapter()
        let service = NowPlayingAdvancedControls(adapter: adapter)
        service.updateContext(context()); service.refresh(); await ready(service)
        service.toggleFavorite(); await waitForAction(adapter)
        service.updateContext(context("two"))
        let valid = await adapter.requestIsValid
        XCTAssertFalse(valid)
        await adapter.finish(.init(favorite: true, mode: .shuffle, canFavorite: true, canSetMode: true))
        await Task.yield()
        XCTAssertNil(service.snapshot.favorite)
        XCTAssertNil(service.snapshot.mode)
    }
    func testUnsupportedSourceHidesAndDoesNotReadAdapter() async {
        let adapter = ControlledMusicAdapter()
        let service = NowPlayingAdvancedControls(adapter: adapter)
        service.updateContext(context(bundle: "com.spotify.client")); service.refresh()
        XCTAssertFalse(service.isSupported)
        let reads = await adapter.reads
        XCTAssertEqual(reads, 0)
    }
    func testVisibleRefreshReplacesSceneOptionsWithoutChangingTrack() async {
        let adapter = ControlledMusicAdapter()
        let service = NowPlayingAdvancedControls(adapter: adapter), owner = UUID()
        service.updateContext(context())
        service.refreshIfVisible()
        let hiddenReads = await adapter.reads
        XCTAssertEqual(hiddenReads, 0)
        await adapter.setSnapshot(.init(favorite: false, mode: .repeatOne, availableModes: [.sequential, .repeatOne], canFavorite: true, canSetMode: true))
        service.setVisible(true, owner: owner); await ready(service)
        XCTAssertEqual(service.snapshot.nextMode, .sequential)
        service.cycleMode(); await waitForAction(adapter)
        let target = await adapter.lastAction
        XCTAssertEqual(target, .mode(.sequential))
        await adapter.finish(.init(favorite: false, mode: .sequential, availableModes: [.sequential, .repeatOne], canFavorite: true, canSetMode: true))
        await ready(service)
        await adapter.setSnapshot(.init(favorite: false, mode: .repeatOne, availableModes: MusicPlaybackMode.allCases, canFavorite: true, canSetMode: true))
        service.refreshIfVisible(); await ready(service)
        XCTAssertEqual(service.snapshot.nextMode, .shuffle)
        XCTAssertEqual(service.snapshot.favorite, false)
        service.setVisible(false, owner: owner)
        let reads = await adapter.reads
        service.refreshIfVisible()
        let hiddenAgain = await adapter.reads
        XCTAssertEqual(reads, hiddenAgain)
    }
    func testVisibleReadRecoversAfterWindowReturnsWithoutRepeatingAction() async {
        let adapter = ControlledMusicAdapter()
        let controls = NowPlayingAdvancedControls(adapter: adapter), owner = UUID()
        await adapter.setSnapshot(.init(message: "QQ 主窗口未就绪"))
        controls.updateContext(context()); controls.setVisible(true, owner: owner); await ready(controls)
        XCTAssertNil(controls.snapshot.favorite)
        await adapter.setSnapshot(.init(favorite: true, mode: .sequential, availableModes: [.sequential, .repeatOne], canFavorite: true, canSetMode: true))
        controls.refreshIfVisible(); await ready(controls)
        XCTAssertEqual(controls.snapshot.favorite, true)
        XCTAssertNil(controls.snapshot.message)
        let writes = await adapter.count
        XCTAssertEqual(writes, 0)
        controls.setVisible(false, owner: owner)
    }
    func testNamedModeTargetAndLastViewerInvalidation() async {
        let adapter = ControlledMusicAdapter()
        let controls = NowPlayingAdvancedControls(adapter: adapter), first = UUID(), second = UUID()
        controls.updateContext(context()); controls.setVisible(true, owner: first); controls.setVisible(true, owner: second)
        await ready(controls); controls.cycleMode(); await waitForAction(adapter)
        let action = await adapter.lastAction
        XCTAssertEqual(action, .mode(.repeatOne))
        controls.setVisible(false, owner: first)
        let stillValid = await adapter.requestIsValid
        XCTAssertTrue(stillValid)
        controls.setVisible(false, owner: second)
        let valid = await adapter.requestIsValid
        XCTAssertFalse(valid)
        await adapter.finish(.init(mode: .repeatOne, canSetMode: true)); await Task.yield()
        XCTAssertNil(controls.snapshot.mode)
    }
}

@MainActor
final class MusicHoverTransitionTests: XCTestCase {
    func testActualHoverTransitionsAndPauseStayHalfExpanded() async {
        var playing = true
        let state = AppState(synchronizesRuntimeEnergyState: false, musicHoverSnapshot: { (playing, "Hover test") })
        let oldDelay = state.hoverExpandDelay, oldDismissDelay = state.expandedAutoDismissDelay
        let oldEnabled = state.nowPlayingEnabled
        defer {
            state.handleHoverChange(false); state.cancelAutoDismiss(); state.cancelFullExpandedDismiss()
            state.hoverExpandDelay = oldDelay; state.expandedAutoDismissDelay = oldDismissDelay
            state.nowPlayingEnabled = oldEnabled
        }
        state.nowPlayingEnabled = true
        state.hoverExpandDelay = 0.01; state.expandedAutoDismissDelay = 30
        state.activeModule = .builtIn(.nowPlaying)
        XCTAssertEqual(state.currentState, .compact)
        state.handleHoverChange(true)
        print("MP1 hover entry delay=\(state.hoverExpandDelay) pressed=\(NSEvent.pressedMouseButtons) hover=\(state.isHovering) suppressed=\(state.isWindowDragHoverSuppressed)")
        for _ in 0..<100 { if state.currentState != .compact { break }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.currentState, .expanded)
        playing = false
        state.handleHoverChange(false); state.handleHoverChange(true)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(state.currentState, .expanded, "Pausing or re-entering the preview must not promote it")
        state.open()
        XCTAssertEqual(state.currentState, .fullExpanded)
        state.handleHoverChange(false); state.dismiss()
        playing = false
        state.handleHoverChange(true)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(state.currentState, .fullExpanded, "Paused re-entry keeps the existing full expansion path")
    }
}

@MainActor
final class MusicNativeRenderingTests: XCTestCase {
    func testPreviewAndAdvancedControlsRenderInNativeHostingView() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.activeModule = .builtIn(.nowPlaying)
        state.expand(); state.cancelAutoDismiss()
        let manager = NowPlayingManager.shared
        // Allow the actual source snapshot to arrive; this check does not control playback.
        try? await Task.sleep(for: .milliseconds(900))
        let height: CGFloat = manager.hasAdvancedMusicControls ? 134 : 100
        let root = NowPlayingExpandedView().environmentObject(state)
            .padding(.horizontal, 30).padding(.vertical, 10)
            .frame(width: 408, height: height).background(Color.black)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 408, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        defer { window.close(); state.cancelAutoDismiss() }
        try? await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/mp1-native-preview.png"))
        XCTAssertEqual(host.bounds.width, 408, accuracy: 0.5)
        XCTAssertEqual(host.bounds.height, height, accuracy: 0.5)
        print("MP1 native preview: advanced=\(manager.hasAdvancedMusicControls), size=408x\(height)")
        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        // The unsigned test host has no AX permission. Its disabled favorite must
        // consume the click instead of promoting the preview or sending a write.
        if manager.hasAdvancedMusicControls, !manager.advancedControls.snapshot.canFavorite,
           !manager.advancedControls.isBusy {
            try click(NSPoint(x: 43, y: height - 85))
            XCTAssertEqual(state.currentState, .expanded)
        }
        try click(NSPoint(x: 245, y: height - 28))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.currentState, .fullExpanded, "The title opens the existing full presentation")
    }
}
