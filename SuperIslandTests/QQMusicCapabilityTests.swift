import XCTest
import ApplicationServices
@testable import SuperIsland

/// Synthetic AX tree; exercises the real adapter, never a user's player.
private final class QQCapabilityFixture {
    let context = MusicControlContext(bundleID: QQMusicControlAdapter.bundleID, processID: 1000,
        launchDate: Date(timeIntervalSince1970: 1), trackID: "fixture", title: "Song", artist: "Lead")
    var attributes: [Int: [String: Any]] = [:]
    var trusted = true, processMatches = true, updateOnPress = true
    var sends = 0, trackReads = 0
    var beforeTrackRead: ((Int) -> Void)?
    var afterPress: (() -> Void)?
    var beforeActions: ((Int) -> Void)?
    var pressResult: AXError = .success
    var missingPress = Set<Int>()
    var timeoutNode: Int?
    func element(_ id: Int) -> AXUIElement { AXUIElementCreateApplication(pid_t(id)) }
    func id(_ element: AXUIElement) -> Int { var pid: pid_t = 0; AXUIElementGetPid(element, &pid); return Int(pid) }
    func set(_ id: Int, _ key: String, _ value: Any) { attributes[id, default: [:]][key] = value }
    func children(_ id: Int, _ ids: [Int]) { set(id, kAXChildrenAttribute, ids.map(element)) }
    init(modes: [MusicPlaybackMode] = MusicPlaybackMode.allCases) {
        set(1000, kAXWindowsAttribute, [element(1)])
        set(1000, kAXMenuBarAttribute, element(10))
        set(1, kAXIdentifierAttribute, "QQMianWindow"); children(1, [2])
        set(2, kAXDescriptionAttribute, "播放控制栏"); children(2, [3, 4, 5])
        set(3, kAXDescriptionAttribute, "歌曲名：Song - 歌手名：Lead/Guest")
        set(4, kAXDescriptionAttribute, "添加到我喜欢")
        set(5, kAXDescriptionAttribute, "播放模式（顺序播放）")
        children(10, [11]); set(11, kAXTitleAttribute, "播放控制"); children(11, [12])
        set(12, kAXRoleAttribute, kAXMenuRole); children(12, [13, 14])
        set(13, kAXTitleAttribute, "喜欢歌曲")
        set(14, kAXTitleAttribute, "播放模式"); children(14, [15]); set(15, kAXRoleAttribute, kAXMenuRole)
        children(15, modes.compactMap { mode in MusicPlaybackMode.allCases.firstIndex(of: mode).map { 20 + $0 } })
        for (index, mode) in MusicPlaybackMode.allCases.enumerated() { set(20 + index, kAXTitleAttribute, mode.rawValue) }
        for id in [13, 20, 21, 22] { set(id, kAXRoleAttribute, kAXMenuItemRole); set(id, kAXEnabledAttribute, true) }
    }
    var access: QQMusicAccessibility {
        .init(isTrusted: { self.trusted }, processMatches: { _ in self.processMatches },
            value: { element, key in
                let id = self.id(element)
                if self.timeoutNode == id { return (.cannotComplete, nil) }
                if id == 3 && key == kAXDescriptionAttribute {
                    self.trackReads += 1; self.beforeTrackRead?(self.trackReads)
                }
                return (.success, self.attributes[id]?[key] as AnyObject?)
            }, actions: { element in
                self.beforeActions?(self.id(element))
                return (.success, self.missingPress.contains(self.id(element)) ? [] : [kAXPressAction])
            }, press: { element in
                self.sends += 1
                let id = self.id(element)
                if self.updateOnPress {
                    if id == 13 {
                        let liked = self.attributes[4]?[kAXDescriptionAttribute] as? String == "从我喜欢删除"
                        self.set(4, kAXDescriptionAttribute, liked ? "添加到我喜欢" : "从我喜欢删除")
                        self.set(13, kAXTitleAttribute, liked ? "喜欢歌曲" : "取消喜欢")
                    } else if let mode = self.attributes[id]?[kAXTitleAttribute] as? String {
                        self.set(5, kAXDescriptionAttribute, "播放模式（\(mode)）")
                    }
                }
                self.afterPress?()
                return self.pressResult
            })
    }
    func read() async -> MusicAdvancedSnapshot { await QQMusicControlAdapter(accessibility: access).read(context, fence: MusicControlFence()) }
    func apply(_ action: MusicAdvancedAction, fence: MusicControlFence = MusicControlFence()) async -> MusicAdvancedSnapshot {
        await QQMusicControlAdapter(accessibility: access).apply(action, context: context, fence: fence)
    }
}

final class QQMusicCapabilityTests: XCTestCase {
    func testCompatibleControlsWorkWithoutVersionMetadata() async {
        // No bundle URL or version metadata exists in this fixture.
        for modes in [[MusicPlaybackMode.sequential, .repeatOne], MusicPlaybackMode.allCases] {
            let f = QQCapabilityFixture(modes: modes)
            let state = await f.read()
            XCTAssertEqual(state.availableModes, modes); XCTAssertTrue(state.canFavorite); XCTAssertTrue(state.canSetMode)
            XCTAssertNil(state.message); XCTAssertEqual(f.sends, 0)
        }
    }
    func testNamedModeCycleAndFavoriteRoundTripReadBackActualState() async {
        let f = QQCapabilityFixture()
        for mode in [MusicPlaybackMode.repeatOne, .shuffle, .sequential] {
            let state = await f.apply(.mode(mode)); XCTAssertEqual(state.mode, mode); XCTAssertNil(state.message)
        }
        let liked = await f.apply(.favorite(true)); XCTAssertEqual(liked.favorite, true)
        let restored = await f.apply(.favorite(false)); XCTAssertEqual(restored.favorite, false)
        XCTAssertEqual(f.sends, 5)
    }
    func testMissingModeDoesNotDisableFavoriteAndCannotBeSent() async {
        let f = QQCapabilityFixture(modes: [.sequential, .repeatOne])
        let state = await f.read(); XCTAssertTrue(state.canFavorite); XCTAssertTrue(state.canSetMode)
        _ = await f.apply(.mode(.shuffle)); XCTAssertEqual(f.sends, 0)
        f.set(13, kAXEnabledAttribute, false)
        let unavailableFavorite = await f.read()
        XCTAssertFalse(unavailableFavorite.canFavorite); XCTAssertTrue(unavailableFavorite.canSetMode)
    }
    func testDuplicateWrongRoleDisabledOrNonPressableTargetsNeverWrite() async {
        for variant in 0..<4 {
            let f = QQCapabilityFixture()
            switch variant {
            case 0: f.children(12, [13, 13, 14])
            case 1: f.set(13, kAXRoleAttribute, kAXButtonRole)
            case 2: f.set(13, kAXEnabledAttribute, false)
            default: f.missingPress.insert(13)
            }
            let state = await f.read(); XCTAssertFalse(state.canFavorite); XCTAssertTrue(state.canSetMode)
            _ = await f.apply(.favorite(true)); XCTAssertEqual(f.sends, 0)
        }
    }
    func testPermissionsProcessIdentityAndCancellationBlockWrites() async {
        for variant in 0..<3 {
            let f = QQCapabilityFixture(), fence = MusicControlFence()
            if variant == 0 { f.trusted = false }
            if variant == 1 { f.processMatches = false }
            if variant == 2 { fence.cancel() }
            let state = await f.apply(.favorite(true), fence: fence)
            XCTAssertFalse(state.canFavorite); XCTAssertNotNil(state.message); XCTAssertEqual(f.sends, 0)
        }
    }
    func testMissingOrAmbiguousPlaybackTreeAndWrongTrackNeverWrite() async {
        for variant in 0..<5 {
            let f = QQCapabilityFixture()
            switch variant {
            case 0: f.set(1000, kAXWindowsAttribute, [AXUIElement]())
            case 1: f.set(1000, kAXWindowsAttribute, [f.element(1), f.element(1)])
            case 2: f.children(1, [2, 2])
            case 3: f.set(3, kAXDescriptionAttribute, "歌曲名：Other - 歌手名：Lead")
            default: f.timeoutNode = 2
            }
            let state = await f.apply(.favorite(true))
            XCTAssertFalse(state.canFavorite); XCTAssertNotNil(state.message); XCTAssertEqual(f.sends, 0)
        }
    }
    func testCollaboratorChangeBeforeSendInvalidatesFullTrackIdentity() async {
        let f = QQCapabilityFixture()
        f.beforeTrackRead = { [unowned f] count in
            if count == 3 { f.set(3, kAXDescriptionAttribute, "歌曲名：Song - 歌手名：Lead/Another") }
        }
        let state = await f.apply(.favorite(true))
        XCTAssertNil(state.favorite); XCTAssertEqual(f.sends, 0)
    }
    func testPressTimeoutWithConfirmedEffectIsNeverRepeated() async {
        let f = QQCapabilityFixture(); f.pressResult = .cannotComplete
        let state = await f.apply(.favorite(true))
        XCTAssertEqual(state.favorite, true); XCTAssertEqual(f.sends, 1)
    }
    func testUnconfirmedPressNeverInventsSuccessOrRetries() async {
        let f = QQCapabilityFixture(); f.pressResult = .cannotComplete; f.updateOnPress = false
        let state = await f.apply(.favorite(true))
        XCTAssertNil(state.favorite); XCTAssertNotNil(state.message); XCTAssertEqual(f.sends, 1)
    }
    func testInvalidationDuringFinalActionProbeMustBlockSend() async {
        for restart in [false, true] {
            let f = QQCapabilityFixture(), fence = MusicControlFence()
            var favoriteProbes = 0
            f.beforeActions = { [unowned f] id in
                guard id == 13 else { return }
                favoriteProbes += 1
                if favoriteProbes == 2 {
                    if restart { f.processMatches = false } else { fence.cancel() }
                }
            }
            _ = await f.apply(.favorite(true), fence: fence)
            XCTAssertEqual(f.sends, 0)
        }
    }
    func testAmbiguousModeAndUnknownCurrentStateKeepFavoriteIndependent() async {
        let f = QQCapabilityFixture()
        f.children(15, [20, 21, 22, 22])
        let state = await f.read()
        XCTAssertEqual(state.availableModes, [.sequential, .repeatOne]); XCTAssertTrue(state.canFavorite)
        _ = await f.apply(.mode(.shuffle)); XCTAssertEqual(f.sends, 0)
        f.set(5, kAXDescriptionAttribute, "播放模式（未知新模式）")
        let unknown = await f.read()
        XCTAssertNil(unknown.mode); XCTAssertFalse(unknown.canSetMode); XCTAssertTrue(unknown.canFavorite)
    }
    func testProcessRestartAfterSendDiscardsConfirmationWithoutRetry() async {
        let f = QQCapabilityFixture()
        f.afterPress = { [unowned f] in f.processMatches = false }
        let state = await f.apply(.favorite(true))
        XCTAssertNil(state.favorite); XCTAssertEqual(f.sends, 1)
    }
}
