import Foundation
import AppKit
import Darwin

@MainActor
final class AgentsStatusBridge {
    static let shared = AgentsStatusBridge()
    nonisolated static let managedExtensionID = "superisland.agents-status"
    nonisolated static let port = 7823

    private let fileManager = FileManager.default

    private var serverProcess: Process?
    private var shouldKeepRunning = false
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempts = 0
    private var cachedPythonURL: URL?
    private var didCleanupLegacyLaunchd = false
    private var didWarnPythonMissing = false
    private var didWarnPortConflict = false
    private var adoptedExternalServer = false
    private var adoptedServerPID: pid_t?
    private let ownerToken = UUID().uuidString
    private var extensionDirectory: URL?

    private init() {}

    // MARK: - Public lifecycle

    func start(extensionDirectory: URL? = nil) {
        self.extensionDirectory = extensionDirectory
        shouldKeepRunning = true
        if !ExtensionHostEnvironment.isWE1 { cleanupLegacyLaunchdOnce() }
        startServerIfNeeded()
    }

    /// Block briefly until the Python server has bound port 7823. Called from
    /// the main thread right before `runtime.activate()` fires — the extension's
    /// JS `onActivate` talks to the bridge via synchronous fetch, so the socket
    /// has to be live or the very first /control/resume + /hooks/install burst
    /// will fail and the extension will mark itself "setup required".
    @discardableResult
    func waitForListening(timeout: TimeInterval = 2.0) -> Bool {
        if ExtensionHostEnvironment.isWE1 && serverProcess == nil { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isServerListening() {
                if !ExtensionHostEnvironment.isWE1 { return true }
                if let process = serverProcess, process.isRunning,
                   let pid = probeOwnedHealth(), pid == process.processIdentifier { return true }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func isServerListening() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(Self.port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Quick synchronous probe of the server's `/health` endpoint. Returns the
    /// server's PID when the response matches the bridge. WE1 additionally
    /// requires this launch's token; a matching service name is not ownership.
    private func probeOwnedHealth(timeout: TimeInterval = 0.5) -> pid_t? {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var resolvedPID: pid_t?
        var matched = false
        let requiredOwnerToken = ExtensionHostEnvironment.isWE1 ? ownerToken : nil
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["ok"] as? Bool) == true,
                  (json["port"] as? Int) == Self.port,
                  requiredOwnerToken == nil || (json["ownerToken"] as? String) == requiredOwnerToken
            else { return }
            matched = true
            if let pid = json["pid"] as? Int, pid > 0 {
                resolvedPID = pid_t(pid)
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.1)
        if !matched { task.cancel() }
        return resolvedPID
    }

    func stop() {
        shouldKeepRunning = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        restartAttempts = 0

        if let process = serverProcess {
            serverProcess = nil
            adoptedServerPID = nil
            adoptedExternalServer = false
            guard process.isRunning else { return }
            process.terminate()
            // Reload starts another instance immediately. Release this owned
            // process's port before returning, rather than mistaking it for a
            // foreign service during the next activation.
            let pid = process.processIdentifier
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
            return
        }

        // An external server can belong to another running host. Its PID is
        // useful for diagnostics, never authority to terminate that process.
        adoptedServerPID = nil
        adoptedExternalServer = false
    }

    // MARK: - Path resolution

    private func serverScriptURL() -> URL? {
        if let extensionDirectory {
            let script = extensionDirectory.appendingPathComponent("server/server.py")
            return fileManager.fileExists(atPath: script.path) ? script : nil
        }
        if let bundleResources = Bundle.main.resourceURL {
            let bundled = bundleResources.appendingPathComponent(
                "BundledExtensions/agents-status/server/server.py", isDirectory: false)
            if fileManager.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        if ExtensionHostEnvironment.isWE1 { return nil }
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let repoScript = repoRoot.appendingPathComponent(
            "Extensions/agents-status/server/server.py", isDirectory: false)
        if fileManager.fileExists(atPath: repoScript.path) {
            return repoScript
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let installed = appSupport?
            .appendingPathComponent("SuperIsland/Extensions/agents-status/server/server.py",
                                    isDirectory: false),
           fileManager.fileExists(atPath: installed.path) {
            return installed
        }
        return nil
    }

    private func hookScriptPath(_ filename: String) -> String {
        if let extensionDirectory {
            return extensionDirectory.appendingPathComponent("hooks/\(filename)").path
        }
        if let bundleResources = Bundle.main.resourceURL {
            let bundled = bundleResources.appendingPathComponent(
                "BundledExtensions/agents-status/hooks/\(filename)", isDirectory: false)
            if fileManager.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }
        if ExtensionHostEnvironment.isWE1 { return "" }
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let repoPath = repoRoot.appendingPathComponent(
            "Extensions/agents-status/hooks/\(filename)", isDirectory: false).path
        if fileManager.fileExists(atPath: repoPath) {
            return repoPath
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let installed = appSupport?
            .appendingPathComponent("SuperIsland/Extensions/agents-status/hooks/\(filename)",
                                    isDirectory: false).path {
            return installed
        }
        return repoPath
    }

    private func resolvePython3URL() -> URL? {
        if let cachedPythonURL, fileManager.isExecutableFile(atPath: cachedPythonURL.path) {
            return cachedPythonURL
        }
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                let url = URL(fileURLWithPath: path)
                cachedPythonURL = url
                return url
            }
        }
        return nil
    }

    // MARK: - Process management

    private func startServerIfNeeded() {
        guard shouldKeepRunning, serverProcess == nil else { return }

        if isServerListening() {
            if ExtensionHostEnvironment.isWE1 {
                ExtensionLogger.shared.log(Self.managedExtensionID, .error,
                    "Agent 状态端口 \(Self.port) 正被其他进程使用；请先退出另一套 Agent 状态服务，再点重新加载。")
                showPortConflictAlertOnce()
                return
            }
            if let pid = probeOwnedHealth() {
                adoptedServerPID = pid
                if !adoptedExternalServer {
                    adoptedExternalServer = true
                    ExtensionLogger.shared.log(Self.managedExtensionID, .info,
                        "Port \(Self.port) already serving /health; adopting existing agents-status instance (pid \(pid))")
                }
                restartAttempts = 0
                return
            }
            ExtensionLogger.shared.log(Self.managedExtensionID, .error,
                "Port \(Self.port) is held by another process that does not look like agents-status; aborting start")
            showPortConflictAlertOnce()
            return
        }
        adoptedExternalServer = false

        guard let pythonURL = resolvePython3URL() else {
            ExtensionLogger.shared.log(Self.managedExtensionID, .error,
                "python3 not found on PATH; agents-status service cannot start")
            showPythonMissingAlertOnce()
            return
        }

        guard let scriptURL = serverScriptURL() else {
            ExtensionLogger.shared.log(Self.managedExtensionID, .error,
                "server.py not found in bundle or repo")
            return
        }

        let ccHookPath = hookScriptPath("cc-event-hook.sh")
        let codexHookPath = hookScriptPath("codex-notify-hook.sh")
        // Bundle resources lose +x through rsync in some setups; re-assert it.
        if !ExtensionHostEnvironment.isWE1 {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ccHookPath)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHookPath)
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        env["AGENTS_STATUS_PORT"] = String(Self.port)
        env["AGENTS_STATUS_OWNER_TOKEN"] = ownerToken
        env["AGENTS_STATUS_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["AGENTS_STATUS_CC_HOOK_SCRIPT"] = ccHookPath
        env["AGENTS_STATUS_CODEX_HOOK_SCRIPT"] = codexHookPath
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                ExtensionLogger.shared.log(Self.managedExtensionID, .info, "server: \(text)")
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                ExtensionLogger.shared.log(Self.managedExtensionID, .warning, "server: \(text)")
            }
        }

        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                self?.handleTermination(terminated)
            }
        }

        do {
            try process.run()
            serverProcess = process
            restartAttempts = 0
            ExtensionLogger.shared.log(Self.managedExtensionID, .info,
                "Started agents-status server (pid \(process.processIdentifier))")
        } catch {
            serverProcess = nil
            ExtensionLogger.shared.log(Self.managedExtensionID, .error,
                "Failed to start agents-status server: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func handleTermination(_ process: Process) {
        guard serverProcess === process else { return }
        serverProcess = nil

        let reason = process.terminationReason == .exit ? "exit" : "uncaught signal"
        ExtensionLogger.shared.log(Self.managedExtensionID, .info,
            "agents-status server terminated (\(reason), code \(process.terminationStatus))")

        if shouldKeepRunning {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        restartAttempts = min(restartAttempts + 1, 6)
        let delay = min(30.0, pow(1.5, Double(restartAttempts)))
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.startServerIfNeeded()
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Legacy launchd cleanup

    private func cleanupLegacyLaunchdOnce() {
        guard !didCleanupLegacyLaunchd else { return }
        didCleanupLegacyLaunchd = true

        let home = fileManager.homeDirectoryForCurrentUser
        let labels = ["com.superisland.agents-status", "com.superisland.cc-status"]
        let uid = getuid()
        for label in labels {
            let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
            guard fileManager.fileExists(atPath: plistURL.path) else { continue }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["bootout", "gui/\(uid)", plistURL.path]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                // bootout may legitimately fail if the plist was never loaded — just proceed.
            }
            try? fileManager.removeItem(at: plistURL)
            ExtensionLogger.shared.log(Self.managedExtensionID, .info,
                "Removed legacy launchd job \(label)")
        }
    }

    // MARK: - Alerts

    private func showPortConflictAlertOnce() {
        guard !didWarnPortConflict else { return }
        didWarnPortConflict = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Agent 状态服务启动失败"
            alert.informativeText = "端口 \(Self.port) 正被其他进程使用。请先退出另一套 Agent 状态服务，再点重新加载。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Got it")
            _ = alert.runModal()
        }
    }

    private func showPythonMissingAlertOnce() {
        guard !didWarnPythonMissing else { return }
        didWarnPythonMissing = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Python 3 required for Agents Status"
            alert.informativeText = "Agents Status tracks your Claude Code and Codex CLI sessions through a small background service that needs Python 3. On macOS, install the Command Line Tools by running `xcode-select --install` in Terminal, then restart Super Island."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Got it")
            _ = alert.runModal()
        }
    }
}
