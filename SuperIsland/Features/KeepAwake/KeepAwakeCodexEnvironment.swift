import AppKit
import CoreServices
import Darwin
import Foundation
import Security

/// Discovers a local Codex installation without launching or changing it.
/// A profile identifies an installation and home; it does not claim that the
/// desktop exposes a listener, or that a listener belongs to a particular UI.
enum KeepAwakeCodexEnvironment {
    struct Profile: Codable, Equatable {
        let executableURL: URL
        let codexHome: URL
        let socketURL: URL
    }

    /// Only populated after validating the parent desktop and child executable.
    /// Process identifiers and the rest of the process environment are not kept.
    struct DesktopChild {
        let executableURL: URL
        let home: URL?
        let codexHome: URL?
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, ambiguous, invalidEnvironment, invalidEndpoint
        var errorDescription: String? {
            switch self {
            case .unavailable: "没有找到可用的官方 Codex 安装或本机任务接口。"
            case .ambiguous: "发现多个不同的 Codex 数据目录；请先明确要接入的桌面环境。"
            case .invalidEnvironment: "无法确认 Codex 的实际数据目录，未接入。"
            case .invalidEndpoint: "Codex 本机接口的归属或权限无法确认，未连接。"
            }
        }
    }

    private struct Cache {
        let created: TimeInterval
        let environment: [String: String]
        let result: Result<Profile, Failure>
    }
    private static let cacheLock = NSLock()
    private static var cache: Cache?

    /// Discovery is briefly cached because SwiftUI may ask availability several
    /// times per render. Explicit connection operations can request a refresh.
    /// Endpoint permissions are checked again even when the profile is cached.
    static func discover(requireEndpoint: Bool = false, refresh: Bool = false) throws -> Profile {
        let environment = ProcessInfo.processInfo.environment
        let relevant = environment.filter { ["CODEX_HOME", "PATH"].contains($0.key) }
        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        let cached = cache.flatMap { !refresh && $0.environment == relevant && now - $0.created < 2 ? $0.result : nil }
        cacheLock.unlock()
        let result: Result<Profile, Failure>
        if let cached { result = cached }
        else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == "com.openai.codex" && !$0.isTerminated &&
                    $0.bundleURL.map(isOfficialDesktopApplication) == true
            }
            var applications = running.compactMap(\.bundleURL)
            if let registered = LSCopyApplicationURLsForBundleIdentifier("com.openai.codex" as CFString, nil)?.takeRetainedValue() as? [URL] {
                applications += registered.filter(isOfficialDesktopApplication)
            }
            // These are fallbacks only. Renamed or relocated applications above
            // are discovered by bundle identity, rather than their display name.
            applications += [URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                             URL(fileURLWithPath: "/Applications/Codex.app"),
                             home.appendingPathComponent("Applications/ChatGPT.app"),
                             home.appendingPathComponent("Applications/Codex.app")]
                .filter(isOfficialDesktopApplication)
            do {
                let children = try desktopChildren(parentPIDs: Set(running.map(\.processIdentifier)))
                let profile = try resolve(userHome: home, environment: environment,
                                          applications: applications, desktopChildren: children,
                                          isOfficialExecutable: isOfficialExecutable,
                                          validateEndpoint: validateEndpoint)
                try validateHomeOwnership(profile.codexHome)
                result = .success(profile)
            } catch let failure as Failure { result = .failure(failure) }
            catch { result = .failure(.unavailable) }
            cacheLock.lock()
            cache = Cache(created: ProcessInfo.processInfo.systemUptime, environment: relevant, result: result)
            cacheLock.unlock()
        }
        let profile = try result.get()
        if requireEndpoint { try validateEndpoint(profile.socketURL) }
        return profile
    }

    /// Pure resolution seam. Applications and desktop children are supplied by
    /// the caller; executable validation and endpoint checks are injectable.
    static func resolve(userHome: URL, environment: [String: String], applications: [URL],
                        desktopChildren: [DesktopChild], requireEndpoint: Bool = false,
                        isOfficialExecutable: (URL) -> Bool,
                        validateEndpoint: (URL) throws -> Void) throws -> Profile {
        guard validFileURL(userHome) else { throw Failure.invalidEnvironment }
        let children = desktopChildren.filter { isOfficialExecutable(canonical($0.executableURL)) }
        let desktopHomes = try Set(children.map { child -> URL in
            if let codexHome = child.codexHome {
                guard validFileURL(codexHome) else { throw Failure.invalidEnvironment }
                return canonical(codexHome)
            }
            guard let home = child.home, validFileURL(home) else { throw Failure.invalidEnvironment }
            return canonical(home.appendingPathComponent(".codex", isDirectory: true))
        })
        guard desktopHomes.count <= 1 else { throw Failure.ambiguous }
        let codexHome = try desktopHomes.first ?? defaultCodexHome(userHome: userHome, environment: environment)
        let candidates = children.map(\.executableURL) + executableCandidates(userHome: userHome,
            environment: environment, applications: applications)
        guard let executable = unique(candidates.map(canonical)).first(where: isOfficialExecutable) else {
            throw Failure.unavailable
        }
        let profile = Profile(executableURL: executable, codexHome: codexHome,
                              socketURL: controlSocket(codexHome: codexHome))
        if requireEndpoint { try validateEndpoint(profile.socketURL) }
        return profile
    }

    static func defaultCodexHome(userHome: URL, environment: [String: String]) throws -> URL {
        guard validFileURL(userHome) else { throw Failure.invalidEnvironment }
        if let value = environment["CODEX_HOME"] {
            guard let url = absoluteDirectory(value) else { throw Failure.invalidEnvironment }
            return canonical(url)
        }
        return canonical(userHome.appendingPathComponent(".codex", isDirectory: true))
    }

    static func controlSocket(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("app-server-control/app-server-control.sock")
    }

    static func executableCandidates(userHome: URL, environment: [String: String], applications: [URL]) -> [URL] {
        let relativeExecutables = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                                   "Contents/Resources/codex", "Contents/MacOS/codex"]
        let bundled = unique(applications).flatMap { app in relativeExecutables.map { app.appendingPathComponent($0) } }
        let path = (environment["PATH"] ?? "").split(separator: ":")
            .compactMap { absoluteDirectory(String($0))?.appendingPathComponent("codex") }
        // A GUI process often has a nonempty PATH containing only system bins.
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex", "/bin/codex"].map {
            URL(fileURLWithPath: $0)
        } + [userHome.appendingPathComponent(".local/bin/codex"), userHome.appendingPathComponent(".npm-global/bin/codex")]
        return unique(bundled + path + fixed)
    }

    static func isOfficialExecutable(_ url: URL) -> Bool {
        validFileURL(url) && url.lastPathComponent == "codex" &&
            FileManager.default.isExecutableFile(atPath: url.path) && validSignature(url, identifier: "codex")
    }

    static func validateEndpoint(_ socket: URL) throws {
        guard validFileURL(socket) else { throw Failure.invalidEndpoint }
        var file = stat(), directory = stat()
        guard lstat(socket.path, &file) == 0 else { throw Failure.unavailable }
        guard (file.st_mode & S_IFMT) == S_IFSOCK, file.st_uid == getuid(),
              lstat(socket.deletingLastPathComponent().path, &directory) == 0,
              (directory.st_mode & S_IFMT) == S_IFDIR, directory.st_uid == getuid(),
              directory.st_mode & 0o077 == 0 else { throw Failure.invalidEndpoint }
    }

    /// Hooks may create a not-yet-existing home, but only underneath a directory
    /// belonging to this user. Never redirect configuration to another account.
    static func validateHomeOwnership(_ home: URL) throws {
        guard validFileURL(home) else { throw Failure.invalidEnvironment }
        var ancestor = canonical(home), info = stat()
        while lstat(ancestor.path, &info) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else { throw Failure.invalidEnvironment }
            ancestor.deleteLastPathComponent()
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw Failure.invalidEnvironment }
    }

    /// KERN_PROCARGS2 includes argv before env. Skip argv as bytes and decode
    /// only HOME/CODEX_HOME; prompts, tokens, and other keys never become strings.
    static func allowedProcessEnvironment(_ data: Data) -> [String: String]? {
        let bytes = [UInt8](data)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let count = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        guard count < 65_536 else { return nil }
        var offset = 4
        func next() -> ArraySlice<UInt8>? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return bytes[offset..<end]
        }
        guard next() != nil else { return nil } // Executable path, not argv[0].
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<count { guard next() != nil else { return nil } }
        let homeKey = Array("HOME=".utf8), codexKey = Array("CODEX_HOME=".utf8)
        var result: [String: String] = [:]
        while offset < bytes.count {
            guard let part = next() else { return nil }
            if part.isEmpty { break }
            for (key, prefix) in [("HOME", homeKey), ("CODEX_HOME", codexKey)] where part.starts(with: prefix) {
                guard result[key] == nil, part.count <= 4_096,
                      let value = String(bytes: part.dropFirst(prefix.count), encoding: .utf8),
                      absoluteDirectory(value) != nil else { return nil }
                result[key] = value
            }
        }
        return result
    }

    private static func desktopChildren(parentPIDs: Set<pid_t>) throws -> [DesktopChild] {
        guard !parentPIDs.isEmpty else { return [] }
        let required = proc_listallpids(nil, 0)
        guard required > 0 && required < 65_536 else { throw Failure.invalidEnvironment }
        var pids = [pid_t](repeating: 0, count: Int(required) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 && Int(count) <= pids.count else { throw Failure.invalidEnvironment }
        var result: [DesktopChild] = []
        for pid in pids.prefix(Int(count)) where pid > 1 {
            guard let before = processInfo(pid), before.pbi_uid == getuid(),
                  parentPIDs.contains(pid_t(before.pbi_ppid)), let executable = processPath(pid),
                  isOfficialExecutable(executable) else { continue }
            let values = processEnvironment(pid)
            guard let after = processInfo(pid), before.pbi_start_tvsec == after.pbi_start_tvsec,
                  before.pbi_start_tvusec == after.pbi_start_tvusec, before.pbi_ppid == after.pbi_ppid,
                  after.pbi_uid == getuid() else { continue }
            result.append(.init(executableURL: executable, home: values?["HOME"].flatMap(absoluteDirectory),
                                codexHome: values?["CODEX_HOME"].flatMap(absoluteDirectory)))
        }
        return result
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
    private static func processPath(_ pid: pid_t) -> URL? {
        var bytes = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return absoluteDirectory(String(cString: bytes))
    }
    private static func processEnvironment(_ pid: pid_t) -> [String: String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count > 0 && count <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctl(&mib, 3, &bytes, &count, nil, 0) == 0 else { return nil }
        return allowedProcessEnvironment(Data(bytes.prefix(count)))
    }
    private static func isOfficialDesktopApplication(_ url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier == "com.openai.codex" && validSignature(url, identifier: "com.openai.codex")
    }
    private static func validSignature(_ url: URL, identifier: String) -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    private static func absoluteDirectory(_ value: String) -> URL? {
        guard value.hasPrefix("/"), value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
    private static func validFileURL(_ url: URL) -> Bool { url.isFileURL && absoluteDirectory(url.path) != nil }
    private static func canonical(_ url: URL) -> URL {
        // URL's directory hint adds a trailing slash even for nonexistent paths.
        // Identity is the normalized filesystem path, independent of that hint.
        URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
    }
    private static func unique(_ values: [URL]) -> [URL] {
        var seen = Set<URL>(); return values.filter { seen.insert($0).inserted }
    }
}
