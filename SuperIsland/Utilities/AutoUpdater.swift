import AppKit
import Foundation

@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var progressObservation: NSKeyValueObservation?
    private init() {}

    var isBusy: Bool {
        switch state {
        case .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }

    func clearFailure() {
        if case .failed = state { state = .idle }
    }

    func start(downloadURL: URL, releaseURL: URL) {
        guard !isBusy else { return }
        let policy = UpdateReleasePolicy.current
        guard downloadURL.scheme == "https", !policy.isWE1 || policy.allowedWE1Download(downloadURL) else {
            state = .failed("安装包不适用于当前版本")
            return
        }
        // Mark busy before scheduling, so a double click cannot start two installs.
        state = .downloading(progress: 0)
        Task { await perform(downloadURL: downloadURL, releaseURL: releaseURL, policy: policy) }
    }

    private func perform(downloadURL: URL, releaseURL: URL, policy: UpdateReleasePolicy) async {
        let installedURL = Bundle.main.bundleURL
        var dmgURL: URL?
        var mountURL: URL?
        var stagedURL: URL?
        do {
            let downloaded = try await downloadDMG(from: downloadURL)
            dmgURL = downloaded
            state = .installing
            let mount = try await mountDMG(at: downloaded)
            mountURL = mount
            let candidates = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == policy.bundleIdentifier }
            guard candidates.count == 1, let source = candidates.first,
                  source.resolvingSymlinksInPath().path.hasPrefix(mount.resolvingSymlinksInPath().path + "/") else {
                throw UpdateError.appNotFoundInDMG
            }
            try UpdatePackageValidator.validate(appURL: source, installedURL: installedURL, policy: policy, downloadURL: downloadURL)

            // Copy and verify while the current app is still alive. Replacement
            // uses renames on the same volume and preserves a rollback copy.
            let stage = installedURL.deletingLastPathComponent().appendingPathComponent(".SuperIsland-update-\(UUID().uuidString).app")
            stagedURL = stage
            _ = try await run("/usr/bin/ditto", [source.path, stage.path])
            try UpdatePackageValidator.validate(appURL: stage, installedURL: installedURL, policy: policy, downloadURL: downloadURL)
            try launchReplacementScript(stagedURL: stage, installedURL: installedURL, mountURL: mount, dmgURL: downloaded, fallbackURL: releaseURL)
            NSApp.terminate(nil)
        } catch {
            if let mountURL { _ = try? await run("/usr/bin/hdiutil", ["detach", mountURL.path, "-quiet"]) }
            if let dmgURL { try? FileManager.default.removeItem(at: dmgURL) }
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            state = .failed((error as? LocalizedError)?.errorDescription ?? "更新失败，原版本已保留，请重试")
        }
    }

    private func downloadDMG(from url: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
                Task { @MainActor [weak self] in self?.progressObservation = nil }
                if let error { continuation.resume(throwing: error); return }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let temporaryURL else {
                    continuation.resume(throwing: UpdateError.downloadFailed)
                    return
                }
                do {
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress: progress.fractionCompleted)
                }
            }
            task.resume()
        }
    }

    private func mountDMG(at url: URL) async throws -> URL {
        let output = try await run("/usr/bin/hdiutil", ["attach", url.path, "-nobrowse", "-noautoopen", "-readonly", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 { continuation.resume(returning: data) }
                else { continuation.resume(throwing: UpdateError.operationFailed) }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private func launchReplacementScript(stagedURL: URL, installedURL: URL, mountURL: URL, dmgURL: URL, fallbackURL: URL) throws {
        // All external values are positional arguments, never shell source.
        let script = """
        #!/bin/bash
        app_pid="$1"
        stage="$2"
        destination="$3"
        mount_point="$4"
        download="$5"
        fallback="$6"
        backup="$7"
        cleanup() {
            /usr/bin/hdiutil detach "$mount_point" -quiet 2>/dev/null
            /bin/rm -f -- "$download" "$0"
        }
        trap cleanup EXIT
        count=0
        while kill -0 "$app_pid" 2>/dev/null; do
            count=$((count + 1))
            if [ "$count" -ge 400 ]; then exit 1; fi
            sleep 0.3
        done
        if /bin/mv -- "$destination" "$backup"; then
            if /bin/mv -- "$stage" "$destination"; then
                /usr/bin/open "$destination"
                exit 0
            fi
            /bin/mv -- "$backup" "$destination"
        fi
        /usr/bin/open "$destination"
        /usr/bin/open "$fallback"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("si-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let backup = installedURL.deletingLastPathComponent().appendingPathComponent(".SuperIsland-before-update-\(UUID().uuidString).app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), stagedURL.path, installedURL.path, mountURL.path, dmgURL.path, fallbackURL.absoluteString, backup.path]
        do { try process.run() }
        catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
        }
    }

    enum UpdateError: LocalizedError {
        case appNotFoundInDMG, mountFailed, downloadFailed, operationFailed
        var errorDescription: String? {
            switch self {
            case .appNotFoundInDMG: return "安装包中未找到适用应用，原版本已保留"
            case .mountFailed: return "无法打开安装包，原版本已保留"
            case .downloadFailed: return "下载失败，请稍后重试"
            case .operationFailed: return "无法准备更新，原版本已保留"
            }
        }
    }
}
