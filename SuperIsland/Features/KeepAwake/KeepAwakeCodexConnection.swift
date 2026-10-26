import Foundation

/// Bind configuration ownership to the environment chosen at explicit connect
/// time. Discovery changes must never redirect a later cleanup to another home.
struct KeepAwakeCodexConnection: Codable, Equatable {
    enum Mode: String, Codable { case hooks, rpc }
    var profile: KeepAwakeCodexEnvironment.Profile
    var mode: Mode

    static let defaultsKey = "keepAwake.codex.connections.v1"
    static func load(_ data: Data?) -> [String: Self] {
        guard let data, let values = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return values.filter { source, connection in
            ["codex-cli", "codex-desktop"].contains(source) &&
            [connection.profile.executableURL, connection.profile.codexHome, connection.profile.socketURL].allSatisfy {
                $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            } && (source == "codex-desktop" || connection.mode == .hooks)
        }
    }
}
