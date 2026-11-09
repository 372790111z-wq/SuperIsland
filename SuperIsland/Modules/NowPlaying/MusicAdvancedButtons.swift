import SwiftUI

/// Both music presentations share the same coordinator and confirmed snapshot.
struct MusicAdvancedButtons: View {
    @ObservedObject private var controls = NowPlayingManager.shared.advancedControls
    @State private var owner = UUID()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: controls.toggleFavorite) {
                Image(systemName: controls.snapshot.favorite == true ? "heart.fill" : "heart")
                    .foregroundStyle(controls.snapshot.favorite == true ? .pink : .white)
                    .overlay(alignment: .topTrailing) {
                        if controls.snapshot.favorite == nil { Text("?").font(.system(size: 8, weight: .bold)).offset(x: 4, y: -4) }
                    }
                    .frame(width: 26, height: 26)
            }
            .disabled(controls.isBusy || !controls.snapshot.canFavorite)
            .accessibilityLabel(controls.snapshot.favorite == true ? "取消收藏" : "收藏歌曲")
            .accessibilityValue(controls.snapshot.favorite.map { $0 ? "已收藏" : "未收藏" } ?? "状态未知")
            .accessibilityIdentifier("data-annotation-id=now-playing-favorite")
            .help(controls.snapshot.favorite == nil ? "收藏状态未知，请重新读取" : (controls.snapshot.favorite == true ? "取消收藏" : "收藏歌曲"))

            Button(action: controls.cycleMode) {
                Image(systemName: controls.snapshot.mode?.symbol ?? "questionmark.circle")
                    .frame(width: 26, height: 26)
            }
            .disabled(controls.isBusy || !controls.snapshot.canSetMode)
            .accessibilityLabel(controls.snapshot.mode?.rawValue ?? "播放模式未知")
            .accessibilityIdentifier("data-annotation-id=now-playing-playback-mode")
            .help(controls.snapshot.mode.map { "\($0.rawValue)，点击切换为\($0.next.rawValue)" } ?? "模式未知，请重新读取")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .onAppear { controls.setVisible(true, owner: owner) }
        .onDisappear { controls.setVisible(false, owner: owner) }
    }
}

struct MusicControlStatusView: View {
    @ObservedObject private var controls = NowPlayingManager.shared.advancedControls
    var body: some View {
        HStack(spacing: 4) {
            if controls.isBusy {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                Text("正在确认状态…")
            } else if let message = controls.snapshot.message {
                Text(message).lineLimit(1).help(message)
                Spacer(minLength: 0)
                Button("重读", action: controls.refresh).buttonStyle(.plain).help("重新读取播放器状态，不会重复执行操作")
            } else {
                Text(controls.snapshot.mode?.rawValue ?? "状态未知")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.7))
        .frame(height: 14)
        .accessibilityIdentifier("data-annotation-id=now-playing-control-status")
    }
}
