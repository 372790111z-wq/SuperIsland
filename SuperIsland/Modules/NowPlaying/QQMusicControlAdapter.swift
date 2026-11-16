import AppKit
import ApplicationServices
import Darwin

/// The production AX boundary also lets tests exercise the real read/send/readback
/// flow without relying on the machine's permissions or changing a user's player.
struct QQMusicAccessibility {
    var isTrusted: () -> Bool
    var processMatches: (MusicControlContext) -> Bool
    var value: (AXUIElement, String) -> (AXError, CFTypeRef?)
    var actions: (AXUIElement) -> (AXError, [String])
    var press: (AXUIElement) -> AXError
    var verifyNowPlaying: (MusicControlContext) -> Bool = { _ in false }

    static let live = Self(
        isTrusted: { AXIsProcessTrusted() },
        processMatches: { context in
            guard let running = NSRunningApplication(processIdentifier: context.processID) else { return false }
            return !running.isTerminated && running.bundleIdentifier == context.bundleID
                && running.launchDate == context.launchDate
        },
        value: { element, key in
            AXUIElementSetMessagingTimeout(element, 0.15)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &result)
            return (error, result)
        },
        actions: { element in
            var result: CFArray?
            let error = AXUIElementCopyActionNames(element, &result)
            return (error, result as? [String] ?? [])
        },
        press: { AXUIElementPerformAction($0, kAXPressAction as CFString) },
        verifyNowPlaying: { QQMusicNowPlayingVerification.verify($0) }
    )
}

/// Fresh read-only source/track proof for a closed playback window. Uses the
/// existing bundled media adapter, never cached labels or application activation.
enum QQMusicNowPlayingVerification {
    static func matches(_ data: [String: Any], context: MusicControlContext) -> Bool {
        guard let pid = data["processIdentifier"] as? Int, pid == context.processID,
              (data["parentApplicationBundleIdentifier"] as? String ?? data["bundleIdentifier"] as? String) == context.bundleID,
              context.bundleID == QQMusicControlAdapter.bundleID,
              !context.title.isEmpty, !context.artist.isEmpty else { return false }
        return data["title"] as? String == context.title && data["artist"] as? String == context.artist
    }

    static func verify(_ context: MusicControlContext, script: URL? = nil, framework: URL? = nil) -> Bool {
        guard let script = script ?? Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter.pl"),
              let framework = framework ?? Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: framework.path) else { return false }
        let process = Process(), pipe = Pipe(), output = Output()
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "get"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return false }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drained.signal() }
            do {
                while let part = try pipe.fileHandleForReading.read(upToCount: 65536), !part.isEmpty {
                    if !output.append(part) { if process.isRunning { process.terminate() }; break }
                }
            } catch { output.invalidate() }
        }
        if exited.wait(timeout: .now() + 0.8) != .success {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.1) != .success, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return false
        }
        guard process.terminationStatus == 0, drained.wait(timeout: .now() + 0.1) == .success,
              let data = output.value, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return matches(json, context: context)
    }
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data(), valid = true
        func append(_ part: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard data.count + part.count <= 8 * 1024 * 1024 else { valid = false; return false }
            data.append(part); return true
        }
        func invalidate() { lock.lock(); valid = false; lock.unlock() }
        var value: Data? { lock.lock(); defer { lock.unlock() }; return valid ? data : nil }
    }
}

/// Reads QQ's playback bar, or its menu with fresh system media proof. No coordinates,
/// account API, library traversal, activation, or automatic repeat of an action.
final class QQMusicControlAdapter: MusicAdvancedAdapter {
    static let bundleID = "com.tencent.QQMusicMac"
    private let accessibility: QQMusicAccessibility
    init(accessibility: QQMusicAccessibility = .live) { self.accessibility = accessibility }
    private let queue = DispatchQueue(label: "superisland.qqmusic.controls", qos: .userInitiated)

    func read(_ context: MusicControlContext, fence: MusicControlFence) async -> MusicAdvancedSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [accessibility] in
                do { continuation.resume(returning: try Session(context, fence: fence, accessibility: accessibility).read()) }
                catch { continuation.resume(returning: Self.unavailable(error)) }
            }
        }
    }

    func apply(_ action: MusicAdvancedAction, context: MusicControlContext, fence: MusicControlFence) async -> MusicAdvancedSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [accessibility] in
                do {
                    let session = try Session(context, fence: fence, accessibility: accessibility)
                    let before = try session.read()
                    if action.matches(before) { continuation.resume(returning: before); return }
                    let target: AXUIElement
                    switch action {
                    case .favorite:
                        guard before.canFavorite, before.favorite != nil else { throw Failure.unavailable }
                        target = try session.favoriteMenuItem(isFavorite: before.favorite!)
                    case .mode(let mode):
                        guard before.availableModes.contains(mode), before.mode != nil else { throw Failure.unavailable }
                        target = try session.modeMenuItem(mode)
                    }
                    // Revalidate both process identity and exact playback-bar metadata immediately
                    // before the single send. A cross-process atomic guarantee is not possible.
                    try session.verifyTrack()
                    try session.check()
                    guard try session.isPressable(target) else { throw Failure.unavailable }
                    // AX action discovery can yield while the source exits or the
                    // owner cancels. Recheck after that last cross-process call.
                    try session.verifyTrack()
                    try session.check()
                    let sent = accessibility.press(target)
                    // Even AX timeout can mean the action was sent: ONLY read afterwards.
                    for _ in 0..<8 {
                        Thread.sleep(forTimeInterval: 0.15)
                        try session.check()
                        let after = try session.read()
                        let writeReady: Bool
                        switch action { case .favorite: writeReady = after.canFavorite; case .mode(let target): writeReady = after.availableModes.contains(target) }
                        // QQ updates the playback label before its menu. Wait for both so a
                        // successful favorite can immediately be undone without a stale menu.
                        if action.matches(after), writeReady { continuation.resume(returning: after); return }
                    }
                    let reason = sent == .success ? "操作结果尚未确认，请重新读取或打开 QQ 音乐检查" : "无法确认操作结果，请先重新读取状态"
                    continuation.resume(returning: .init(message: reason))
                } catch { continuation.resume(returning: Self.unavailable(error)) }
            }
        }
    }

    private enum Failure: Error { case permission, process, track, windowUnavailable, ambiguousWindow, controlsUnavailable, unavailable, timeout, cancelled }
    private static func unavailable(_ error: Error) -> MusicAdvancedSnapshot {
        let message: String
        switch error as? Failure {
        case .permission: message = "需要辅助功能权限，请在系统设置中检查"
        case .process: message = "QQ 音乐已退出或重新启动，请重新读取"
        case .track: message = "暂时无法核对当前歌曲，请稍后重新读取"
        case .windowUnavailable: message = "收藏和模式暂不可读：QQ 主窗口未就绪"
        case .ambiguousWindow: message = "收藏和模式暂不可读：无法唯一确认 QQ 主窗口"
        case .controlsUnavailable: message = "收藏和模式暂不可读：未找到 QQ 播放控制栏"
        case .timeout: message = "读取超时；操作结果未知，请重新读取"
        default: message = "QQ 收藏或模式状态暂不可读，基础播放控制仍可用"
        }
        return .init(message: message)
    }

    /// Pure parsers also used by regression tests. Unknown labels never imply a default.
    static func favoriteState(description: String) -> Bool? {
        if description == "添加到我喜欢" { return false }
        if description == "从我喜欢删除" { return true }
        return nil
    }
    static func playbackMode(description: String) -> MusicPlaybackMode? {
        MusicPlaybackMode.allCases.first { description == "播放模式（\($0.rawValue)）" }
    }
    static func trackMatches(description: String, title: String, artist: String) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let prefix = "歌曲名：\(title) - 歌手名："
        guard description.hasPrefix(prefix) else { return false }
        let qqArtist = String(description.dropFirst(prefix.count))
        if qqArtist == artist { return true }
        // QQ can publish only the lead artist to system media metadata,
        // while its playback bar joins the full credits with '/'. Do not accept
        // arbitrary substrings, later collaborators, or unobserved separators.
        let credits = qqArtist.components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return credits.count > 1 && credits.allSatisfy { !$0.isEmpty }
            && credits.first == artist
    }

    private final class Session {
        let context: MusicControlContext
        let fence: MusicControlFence
        let app: AXUIElement
        let accessibility: QQMusicAccessibility
        private var verifiedPlaybackDescription: String?
        private var usingMenuState = false
        let deadline = ProcessInfo.processInfo.systemUptime + 3.5
        init(_ context: MusicControlContext, fence: MusicControlFence, accessibility: QQMusicAccessibility) throws {
            self.context = context; self.fence = fence; self.accessibility = accessibility
            guard accessibility.isTrusted() else { throw Failure.permission }
            app = AXUIElementCreateApplication(context.processID)
            try check()
        }
        func check() throws {
            guard fence.isValid else { throw Failure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timeout }
            guard context.bundleID == QQMusicControlAdapter.bundleID,
                  accessibility.processMatches(context) else { throw Failure.process }
            // Compatibility is established by bounded, unique semantic controls
            // and confirmed state below, never by a marketing version string.
        }
        func value(_ element: AXUIElement, _ key: String) throws -> CFTypeRef? {
            try check()
            let (error, result) = accessibility.value(element, key)
            if error == .cannotComplete { throw Failure.timeout }
            return error == .success ? result : nil
        }
        func text(_ e: AXUIElement, _ key: String) throws -> String { try value(e, key) as? String ?? "" }
        func children(_ e: AXUIElement) throws -> [AXUIElement] {
            let result = try value(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard result.count <= 64 else { throw Failure.unavailable }
            return result
        }
        func unique(_ elements: [AXUIElement], _ predicate: (AXUIElement) throws -> Bool) throws -> AXUIElement {
            let matches = try elements.filter(predicate)
            guard matches.count == 1 else { throw Failure.unavailable }
            return matches[0]
        }
        func playbackChildren() throws -> [AXUIElement] {
            var windows = try value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            guard windows.count <= 8 else { throw Failure.ambiguousWindow }
            // QQ may publish its main/focused window before AXWindows after reopening.
            let hasMain = try windows.contains { try text($0, kAXIdentifierAttribute) == "QQMianWindow" }
            if !hasMain {
                for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                    if let raw = try? value(app, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                        let window = unsafeBitCast(raw, to: AXUIElement.self)
                        if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
                    }
                }
            }
            let matches = try windows.filter { try text($0, kAXIdentifierAttribute) == "QQMianWindow" }
            guard !matches.isEmpty else { throw Failure.windowUnavailable }
            guard matches.count == 1 else { throw Failure.ambiguousWindow }
            let bars = try children(matches[0]).filter { try text($0, kAXDescriptionAttribute) == "播放控制栏" }
            guard !bars.isEmpty else { throw Failure.controlsUnavailable }
            guard bars.count == 1 else { throw Failure.ambiguousWindow }
            return try children(bars[0])
        }
        func verifyTrack(in nodes: [AXUIElement]? = nil) throws {
            if usingMenuState {
                try check()
                guard accessibility.verifyNowPlaying(context) else { throw Failure.track }
                try check()
                return
            }
            let candidates = try nodes ?? playbackChildren()
            let matching = try candidates.map { try text($0, kAXDescriptionAttribute) }.filter {
                QQMusicControlAdapter.trackMatches(description: $0, title: context.title, artist: context.artist)
            }
            guard matching.count == 1 else { throw Failure.track }
            // Pin the full QQ identity across the read → send → readback session,
            // even when the system exposes only the first artist.
            if let verifiedPlaybackDescription, verifiedPlaybackDescription != matching[0] {
                throw Failure.track
            }
            verifiedPlaybackDescription = matching[0]
        }
        func playbackMenu() throws -> AXUIElement {
            guard let raw = try value(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw Failure.unavailable }
            let menuBar = unsafeBitCast(raw, to: AXUIElement.self)
            let item = try unique(children(menuBar)) { try text($0, kAXTitleAttribute) == "播放控制" }
            return try unique(children(item)) { try text($0, kAXRoleAttribute) == kAXMenuRole }
        }
        func favoriteMenuItem(isFavorite: Bool) throws -> AXUIElement {
            try unique(children(playbackMenu())) { try text($0, kAXTitleAttribute) == (isFavorite ? "取消喜欢" : "喜欢歌曲") }
        }
        func modeMenuItems() throws -> [AXUIElement] {
            let item = try unique(children(playbackMenu())) { try text($0, kAXTitleAttribute) == "播放模式" }
            let menu = try unique(children(item)) { try text($0, kAXRoleAttribute) == kAXMenuRole }
            return try children(menu)
        }
        func modeMenuItem(_ mode: MusicPlaybackMode) throws -> AXUIElement {
            try unique(modeMenuItems()) { try text($0, kAXTitleAttribute) == mode.rawValue }
        }
        func isPressable(_ e: AXUIElement) throws -> Bool {
            guard try text(e, kAXRoleAttribute) == kAXMenuItemRole,
                  try value(e, kAXEnabledAttribute) as? Bool == true else { return false }
            try check()
            let (error, actions) = accessibility.actions(e)
            return error == .success && actions.contains(kAXPressAction)
        }
        private func readMenuState() throws -> MusicAdvancedSnapshot {
            try verifyTrack()
            let menu = try children(playbackMenu())
            let favorites = try menu.filter { ["喜欢歌曲", "取消喜欢"].contains(try text($0, kAXTitleAttribute)) }
            var state = MusicAdvancedSnapshot()
            if favorites.count == 1 {
                state.favorite = try text(favorites[0], kAXTitleAttribute) == "取消喜欢"
                state.canFavorite = try isPressable(favorites[0])
            }
            if let items = try? modeMenuItems() {
                var checked: [MusicPlaybackMode] = []
                var unknownMark = false
                // Inspect every mark, including unknown future options. Multiple or
                // unrecognized checked entries must never become a guessed mode.
                for item in items {
                    let title = try text(item, kAXTitleAttribute)
                    let mark = try text(item, "AXMenuItemMarkChar")
                    guard !mark.isEmpty else { continue }
                    if mark == "✓", let mode = MusicPlaybackMode(rawValue: title),
                       try text(item, kAXRoleAttribute) == kAXMenuItemRole {
                        checked.append(mode)
                    } else { unknownMark = true }
                }
                for mode in MusicPlaybackMode.allCases {
                    let matches = try items.filter { try text($0, kAXTitleAttribute) == mode.rawValue }
                    guard matches.count == 1 else {
                        if checked.contains(mode) { unknownMark = true }
                        continue
                    }
                    if try isPressable(matches[0]) { state.availableModes.append(mode) }
                }
                if checked.count == 1 && !unknownMark { state.mode = checked[0] }
            }
            state.canSetMode = state.nextMode != nil
            var issues: [String] = []
            if !state.canFavorite { issues.append("收藏暂不可用") }
            if state.mode == nil || !state.canSetMode { issues.append("播放模式暂不可用") }
            state.message = issues.isEmpty ? nil : issues.joined(separator: "；")
            try verifyTrack()
            return state
        }

        func read() throws -> MusicAdvancedSnapshot {
            if usingMenuState { return try readMenuState() }
            let nodes: [AXUIElement]
            do {
                nodes = try playbackChildren()
                try verifyTrack(in: nodes)
            } catch let failure as Failure {
                switch failure {
                case .track where verifiedPlaybackDescription != nil:
                    throw failure
                case .windowUnavailable, .controlsUnavailable, .track:
                    usingMenuState = true
                    return try readMenuState()
                default: throw failure
                }
            }
            let descriptions = try nodes.map { try text($0, kAXDescriptionAttribute) }
            let favorites = descriptions.compactMap { QQMusicControlAdapter.favoriteState(description: $0) }
            let modes = descriptions.compactMap { QQMusicControlAdapter.playbackMode(description: $0) }
            var state = MusicAdvancedSnapshot(favorite: favorites.count == 1 ? favorites[0] : nil,
                                              mode: modes.count == 1 ? modes[0] : nil)
            state.canFavorite = state.favorite != nil && ((try? isPressable(favoriteMenuItem(isFavorite: state.favorite ?? false))) == true)
            if let items = try? modeMenuItems() {
                // Missing options are a legitimate QQ scene capability, not a read error.
                state.availableModes = MusicPlaybackMode.allCases.filter { mode in
                    guard let item = try? unique(items, { try text($0, kAXTitleAttribute) == mode.rawValue }) else { return false }
                    return (try? isPressable(item)) == true
                }
            }
            state.canSetMode = state.nextMode != nil
            var issues: [String] = []
            if !state.canFavorite { issues.append("收藏暂不可用") }
            if state.mode == nil || state.availableModes.isEmpty || !state.availableModes.contains(state.mode!) {
                issues.append("播放模式暂不可用")
            }
            state.message = issues.isEmpty ? nil : issues.joined(separator: "；")
            return state
        }
    }
}
