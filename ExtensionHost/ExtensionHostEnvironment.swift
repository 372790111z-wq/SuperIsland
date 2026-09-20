import Foundation

/// Identity-dependent extension state. Helpers take explicit inputs so tests never
/// need to touch the current user's extensions, credentials, or CLI configuration.
enum ExtensionHostEnvironment {
    static let we1BundleIdentifier = "com.workview.SuperIsland.WE1Debug"
    static var isWE1: Bool { Bundle.main.bundleIdentifier == we1BundleIdentifier }

    static func applicationSupportDirectoryName(bundleIdentifier: String?) -> String {
        bundleIdentifier == we1BundleIdentifier ? "SuperIsland-WE1-Debug" : "SuperIsland"
    }

    static func discoveryDirectories(
        isWE1: Bool,
        installed: URL,
        development: URL,
        local: URL,
        repository: URL?,
        bundled: URL?
    ) -> [URL] {
        let candidates = isWE1
            ? [installed, bundled].compactMap { $0 }
            : [installed, development, local, repository, bundled].compactMap { $0 }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

enum ExtensionActivationPolicy {
    static let disabledKey = "extensions.userDisabled"
    static let seenKey = "extensions.seenIDs"
    static let we1OptInKey = "extensions.we1ManualOptInSeeded"

    /// The old WE1 build never ran extensions. Restoring them must not silently
    /// start credential readers or install CLI integrations on the first launch.
    static func register(
        installedIDs: Set<String>,
        defaultDisabledIDs: Set<String>,
        defaults: UserDefaults,
        isWE1: Bool
    ) {
        var disabled = Set(defaults.stringArray(forKey: disabledKey) ?? [])
        let storedSeen = defaults.stringArray(forKey: seenKey)
        let seen = Set(storedSeen ?? [])
        if isWE1 && !defaults.bool(forKey: we1OptInKey) {
            disabled.formUnion(installedIDs)
            defaults.set(true, forKey: we1OptInKey)
            // Settings UI and JavaScript agree: CLI configuration is only
            // changed after the user explicitly enables an individual hook.
            for key in ["hooksClaudeCode", "hooksCodex"] {
                defaults.set(false, forKey: "extensions.superisland.agents-status.settings.\(key)")
            }
        } else if storedSeen == nil {
            disabled.formUnion(defaultDisabledIDs)
        } else {
            disabled.formUnion(installedIDs.subtracting(seen))
        }
        defaults.set(disabled.sorted(), forKey: disabledKey)
        defaults.set(seen.union(installedIDs).sorted(), forKey: seenKey)
    }
}
