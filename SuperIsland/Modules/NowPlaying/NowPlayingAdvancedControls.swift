import AppKit
import Combine

struct MusicControlContext: Equatable, Sendable {
    let bundleID: String
    let processID: pid_t
    let launchDate: Date?
    let trackID: String
    let title: String
    let artist: String
}

enum MusicPlaybackMode: String, CaseIterable, Sendable {
    case sequential = "顺序播放", repeatOne = "单曲循环", shuffle = "随机播放"
    var next: Self {
        switch self { case .sequential: return .repeatOne; case .repeatOne: return .shuffle; case .shuffle: return .sequential }
    }
    var symbol: String {
        switch self { case .sequential: return "repeat"; case .repeatOne: return "repeat.1"; case .shuffle: return "shuffle" }
    }
}

struct MusicAdvancedSnapshot: Equatable, Sendable {
    var favorite: Bool?
    var mode: MusicPlaybackMode?
    var canFavorite = false
    var canSetMode = false
    var message: String?
    static let unknown = Self(message: "正在读取播放器状态")
}

enum MusicAdvancedAction: Equatable, Sendable {
    case favorite(Bool), mode(MusicPlaybackMode)
    func matches(_ state: MusicAdvancedSnapshot) -> Bool {
        switch self { case .favorite(let target): return state.favorite == target; case .mode(let target): return state.mode == target }
    }
}

/// AX queue checks this cancellation fence immediately before sending any action.
final class MusicControlFence: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func cancel() { lock.lock(); valid = false; lock.unlock() }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
}

protocol MusicAdvancedAdapter {
    func read(_ context: MusicControlContext, fence: MusicControlFence) async -> MusicAdvancedSnapshot
    func apply(_ action: MusicAdvancedAction, context: MusicControlContext, fence: MusicControlFence) async -> MusicAdvancedSnapshot
}

@MainActor
final class NowPlayingAdvancedControls: ObservableObject {
    @Published private(set) var context: MusicControlContext?
    @Published private(set) var snapshot = MusicAdvancedSnapshot(message: "无法确认播放来源，请打开播放器后重新读取")
    @Published private(set) var isBusy = false
    private let adapter: any MusicAdvancedAdapter
    private var fence = MusicControlFence()
    private var task: Task<Void, Never>?
    private var viewers = Set<UUID>()
    var isSupported: Bool { context?.bundleID == QQMusicControlAdapter.bundleID }

    init(adapter: any MusicAdvancedAdapter = QQMusicControlAdapter()) { self.adapter = adapter }

    func updateContext(_ next: MusicControlContext?) {
        guard next != context else { return }
        invalidate()
        context = next
        snapshot = next == nil
            ? .init(message: "无法确认播放来源，请打开播放器后重新读取") : .unknown
        if !viewers.isEmpty { refresh() }
    }

    func setVisible(_ visible: Bool, owner: UUID) {
        if visible { viewers.insert(owner); if !isBusy { refresh() } }
        else { viewers.remove(owner); if viewers.isEmpty { invalidate(); snapshot = .unknown } }
    }

    func shutdown() { viewers.removeAll(); invalidate(); context = nil; snapshot = .unknown }

    private func invalidate() {
        fence.cancel()
        task?.cancel()
        fence = MusicControlFence()
        isBusy = false
    }

    /// Explicit read retry; an ambiguous toggle is never automatically resent.
    func refresh() {
        guard !isBusy, isSupported, let context else { return }
        isBusy = true
        let requestFence = fence
        task = Task { [weak self, adapter] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, requestFence.isValid else { return }
            let state = await adapter.read(context, fence: requestFence)
            guard let self, requestFence.isValid, self.context == context else { return }
            self.snapshot = state
            self.isBusy = false
        }
    }

    func toggleFavorite() {
        guard snapshot.canFavorite, let favorite = snapshot.favorite else { return }
        perform(.favorite(!favorite))
    }

    func cycleMode() {
        guard snapshot.canSetMode, let mode = snapshot.mode else { return }
        perform(.mode(mode.next))
    }

    private func perform(_ action: MusicAdvancedAction) {
        guard !isBusy, isSupported, let context else { return }
        isBusy = true
        let requestFence = fence
        task = Task { [weak self, adapter] in
            let result = await adapter.apply(action, context: context, fence: requestFence)
            guard let self, requestFence.isValid, self.context == context else { return }
            self.snapshot = result
            self.isBusy = false
        }
    }
}
