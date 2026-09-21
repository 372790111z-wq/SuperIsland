import Foundation

/// Release metadata is only an offer. AutoUpdater also verifies the downloaded
/// app's identity, architecture and signing requirement before replacement.
struct UpdateReleasePolicy {
    static let we1BundleID = "com.workview.SuperIsland.WE1Debug"
    static let we1Repository = "372790111z-wq/SuperIsland"

    let bundleIdentifier: String
    let currentVersion: String
    let currentBuild: String
    let architecture: String

    var isWE1: Bool { bundleIdentifier == Self.we1BundleID }
    var apiURL: URL {
        if isWE1 {
            return URL(string: "https://api.github.com/repos/\(Self.we1Repository)/releases?per_page=100")!
        }
        return URL(string: "https://api.github.com/repos/shobhit99/superisland/releases/latest")!
    }

    static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Self(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            currentBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            architecture: architecture
        )
    }

    struct Offer: Equatable {
        let version: String
        let build: String?
        let releaseURL: URL
        let downloadURL: URL?
    }

    enum Result: Equatable {
        case upToDate
        case noCompatibleRelease
        case available(Offer)
    }

    func selectRelease(from data: Data) throws -> Result {
        let object = try JSONSerialization.jsonObject(with: data)
        if isWE1 {
            guard let releases = object as? [[String: Any]], Self.validBuild(currentBuild) else {
                throw PolicyError.invalidMetadata
            }
            let offers = releases.compactMap(we1Offer).sorted { ($0.build ?? "") > ($1.build ?? "") }
            guard let latest = offers.first, let build = latest.build else { return .noCompatibleRelease }
            return build > currentBuild ? .available(latest) : .upToDate
        }
        guard let release = object as? [String: Any],
              let tag = release["tag_name"] as? String,
              let urlString = release["html_url"] as? String,
              let releaseURL = URL(string: urlString), releaseURL.scheme == "https" else {
            throw PolicyError.invalidMetadata
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewerVersion(version, than: currentVersion) else { return .upToDate }
        let assets = release["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let downloadURL = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        return .available(Offer(version: version, build: nil, releaseURL: releaseURL, downloadURL: downloadURL))
    }

    /// WE1 releases use tag `we1-YYYYMMDDHHMMSS` and an architecture-specific
    /// `SuperIsland-WE1-YYYYMMDDHHMMSS-arm64.dmg` (or x86_64/universal) asset.
    /// Existing upstream releases without this identity never qualify.
    private func we1Offer(_ release: [String: Any]) -> Offer? {
        guard release["draft"] as? Bool != true,
              let tag = release["tag_name"] as? String, tag.hasPrefix("we1-"),
              Self.validBuild(String(tag.dropFirst(4))),
              let releaseString = release["html_url"] as? String,
              let releaseURL = URL(string: releaseString),
              Self.isRepositoryURL(releaseURL, pathPrefix: "/releases/tag/"),
              releaseURL.lastPathComponent == tag else { return nil }
        let build = String(tag.dropFirst(4))
        let assets = release["assets"] as? [[String: Any]] ?? []
        let names = ["SuperIsland-WE1-\(build)-\(architecture).dmg", "SuperIsland-WE1-\(build)-universal.dmg"]
        for name in names {
            guard let asset = assets.first(where: { $0["name"] as? String == name }),
                  let downloadString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadString),
                  allowedWE1Download(downloadURL, requireNewer: false),
                  downloadURL.deletingLastPathComponent().lastPathComponent == tag,
                  downloadURL.lastPathComponent == name else { continue }
            return Offer(version: "SuperIsland \(build)", build: build, releaseURL: releaseURL, downloadURL: downloadURL)
        }
        return nil
    }

    func allowedWE1Download(_ url: URL, requireNewer: Bool = true) -> Bool {
        guard Self.isRepositoryURL(url, pathPrefix: "/releases/download/") else { return false }
        let tag = url.deletingLastPathComponent().lastPathComponent
        guard tag.hasPrefix("we1-") else { return false }
        let build = String(tag.dropFirst(4))
        guard Self.validBuild(build), !requireNewer || build > currentBuild else { return false }
        return [architecture, "universal"].contains {
            url.lastPathComponent == "SuperIsland-WE1-\(build)-\($0).dmg"
        }
    }

    private static func isRepositoryURL(_ url: URL, pathPrefix: String) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil
            && url.path.hasPrefix("/\(we1Repository)\(pathPrefix)")
    }

    static func validBuild(_ value: String) -> Bool {
        value.utf8.count == 14 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(a.count, b.count) {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    enum PolicyError: Error { case invalidMetadata }
}
