import AppKit
import Foundation

/// Read-only adapter for the installed Kimi Code Desktop 1.0.1 local server.
/// The ID-only projection excludes prompts, titles, paths and reply content.
/// CLI uses a separate source and is never inferred from the desktop process.
enum KeepAwakeKimiMonitor {
    static let sourceID = "kimi-code-desktop"
    struct Snapshot {
        let state: KeepAwakeEngine.TaskState?
        let message: String
    }
    enum Failure: Error { case unavailable, invalidResponse, limitExceeded }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static let statuses = ["running", "approval", "question"]
    static func requestURL(port: Int, status: String) -> URL? {
        guard (1...65535).contains(port), statuses.contains(status) else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = port
        parts.path = "/api/v2/sessions"
        parts.queryItems = [.init(name: "fields", value: "id,archived"),
                            .init(name: "activity.status", value: status),
                            .init(name: "page_size", value: "1")]
        return parts.url
    }
    static func count(from data: Data) throws -> Int {
        guard data.count <= 8192,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(), code.doubleValue == 0,
              let page = root["data"] as? [String: Any],
              let total = page["total"] as? NSNumber, CFGetTypeID(total) != CFBooleanGetTypeID(),
              total.doubleValue.isFinite, total.doubleValue.rounded() == total.doubleValue,
              (0...1_000_000).contains(total.intValue),
              let items = page["items"] as? [[String: Any]], items.count <= 1,
              let more = page["has_more"] as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID(),
              items.count == min(total.intValue, 1), more.boolValue == (total.intValue > 1) else { throw Failure.invalidResponse }
        // Fail closed if a changed server ignores the privacy projection.
        for item in items {
            guard Set(item.keys) == Set(["id", "archived"]),
                  let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  let archived = item["archived"] as? NSNumber, CFGetTypeID(archived) == CFBooleanGetTypeID() else { throw Failure.invalidResponse }
        }
        return total.intValue
    }
    static func state(running: Int, approval: Int, question: Int) -> KeepAwakeEngine.TaskState {
        if running > 0 { return .running }
        if approval > 0 || question > 0 { return .waiting }
        // A snapshot cannot prove successful completion, so never notify it.
        return .idle
    }
    static func ports(from output: String) -> [Int] {
        Array(Set(output.split(separator: "\n").compactMap { line -> Int? in
            let prefix = "n127.0.0.1:"
            guard line.hasPrefix(prefix), let port = Int(line.dropFirst(prefix.count)),
                  (1...65535).contains(port) else { return nil }
            return port
        })).sorted().prefix(16).map { $0 }
    }
    static func installedVersion(at appURL: URL) -> String? {
        // Bundle caches its Info.plist. Re-read the file so an in-place app
        // update cannot retain a previously accepted version in this process.
        guard let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
    static func listeningPorts(pid: pid_t) async -> [Int] {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continuation.resume(returning: []); return }
            // Keep run/wait on one OS thread. Awaiting between them can move a
            // Swift task to another thread and strand Foundation's exit wait.
            // A full pipe also hits this deadline; killed output is discarded.
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.read(upToCount: 65537)) ?? Data()
            try? pipe.fileHandleForReading.close()
            guard process.terminationStatus == 0, data.count <= 65536 else { continuation.resume(returning: []); return }
            continuation.resume(returning: ports(from: String(decoding: data, as: UTF8.self)))
          }
        }
    }
    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == url, response.expectedContentLength <= 8192 else { throw Failure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8192 else { throw Failure.limitExceeded }
            data.append(byte)
        }
        return data
    }
    @MainActor static func sample() async -> Snapshot {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kimi.code.desktop")
        guard apps.count == 1, let app = apps.first, !app.isTerminated else {
            return .init(state: nil, message: "Kimi 未运行或实例不唯一；等待本机来源")
        }
        guard let url = app.bundleURL, installedVersion(at: url) == "1.0.1" else {
            return .init(state: nil, message: "Kimi 当前版本尚未核验；未读取任务接口")
        }
        let pid = app.processIdentifier, launchDate = app.launchDate
        let ports = await listeningPorts(pid: pid)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for port in ports {
            if Task.isCancelled { break }
            do {
                var counts = [Int]()
                for status in statuses {
                    counts.append(try count(from: await fetch(requestURL(port: port, status: status)!, session: session)))
                }
                guard !Task.isCancelled, !app.isTerminated,
                      NSRunningApplication(processIdentifier: pid)?.launchDate == launchDate else { throw Failure.unavailable }
                let result = state(running: counts[0], approval: counts[1], question: counts[2])
                return .init(state: result, message: "本机只读接口已响应 · " + (result == .running ? "运行中" : result == .waiting ? "等待确认" : "空闲"))
            } catch { continue }
        }
        return .init(state: nil, message: "本机接口未响应或格式不兼容；状态未知")
    }
}
