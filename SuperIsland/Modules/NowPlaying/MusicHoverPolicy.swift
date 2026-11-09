import Foundation

enum MusicHoverPolicy {
    static func showsPreview(enabled: Bool, playing: Bool, title: String) -> Bool {
        enabled && playing && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
