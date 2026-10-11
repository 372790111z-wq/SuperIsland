import SwiftUI

struct SystemHUDCompactView: View {
    @ObservedObject private var volumeManager = VolumeManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeManager.volumeIconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            // Slim progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.2))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: max(0, geometry.size.width * CGFloat(volumeManager.volume)))
                        .animation(Constants.progressBar, value: volumeManager.volume)
                }
            }
            .frame(maxWidth: 80, maxHeight: 4)

            Text("\(Int(volumeManager.volume * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}
