import SwiftUI

struct SystemHUDCompactView: View {
    var kind: SystemFeedbackKind = .volume
    var centerGapWidth: CGFloat? = nil
    @ObservedObject private var volumeManager = VolumeManager.shared
    @ObservedObject private var brightnessManager = ScreenBrightnessManager.shared

    private var value: Float {
        kind == .brightness ? (brightnessManager.brightness ?? 0) : (volumeManager.isMuted ? 0 : volumeManager.volume)
    }

    private var icon: String {
        kind == .brightness ? "sun.max.fill" : volumeManager.volumeIconName
    }

    var body: some View {
        Group {
            if let centerGapWidth {
                HStack(spacing: 0) {
                    feedbackIcon
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: centerGapWidth)
                    VStack(spacing: 3) {
                        feedbackPercentage
                        progressBar.frame(width: 32, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Constants.compactMinimalHorizontalPadding)
            } else {
                inlineFeedback
            }
        }
        .dataAnnotationID(kind == .brightness ? "system-feedback-brightness-hud" : "system-feedback-volume-hud")
    }

    private var inlineFeedback: some View {
        HStack(spacing: 8) {
            feedbackIcon

            // Slim progress bar
            progressBar
            .frame(maxWidth: 80, maxHeight: 4)
            feedbackPercentage
        }
    }

    private var feedbackIcon: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
    }

    private var feedbackPercentage: some View {
        Text("\(Int((min(1, max(0, value)) * 100).rounded()))%")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))
            .fixedSize()
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.2))
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(1, max(0, value)))))
                    .animation(Constants.progressBar, value: value)
            }
        }
    }
}
