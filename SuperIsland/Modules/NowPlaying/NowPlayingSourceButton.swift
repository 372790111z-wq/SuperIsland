import SwiftUI

/// A source shortcut, separate from all playback and seek controls.
struct NowPlayingSourceButton<Content: View>: View {
    @ObservedObject private var manager = NowPlayingManager.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Button(action: manager.openPlaybackSource) {
            content
                .contentShape(Rectangle())
                .overlay {
                    if manager.isOpeningPlaybackSource {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .padding(6)
                            .background(.black.opacity(0.55), in: Circle())
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!manager.canOpenPlaybackSource || manager.isOpeningPlaybackSource)
        .help(manager.playbackSourceHelp)
        .accessibilityLabel("打开播放来源")
        .accessibilityValue(manager.playbackSourceHelp)
        .accessibilityIdentifier("data-annotation-id=now-playing-open-source")
        .hoverPointer()
    }
}
