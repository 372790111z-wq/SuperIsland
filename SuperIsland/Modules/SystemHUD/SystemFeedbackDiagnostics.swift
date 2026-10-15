import Foundation

/// Opt-in local validation metadata. Never records notification text or keys
/// other than the two supported system adjustment categories.
enum SystemFeedbackDiagnostics {
    private static let lock = NSLock()
    static func write(_ section: String, fields: [String: Any]) {
        guard Bundle.main.bundleIdentifier == "com.workview.SuperIsland.WE1Debug",
              UserDefaults.standard.bool(forKey: "debug.sf1.diagnostics") else { return }
        lock.lock(); defer { lock.unlock() }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SuperIsland/SF1Validation")
        let file = directory.appendingPathComponent("diagnostics.json")
        var document = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        document[section] = fields
        document["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
