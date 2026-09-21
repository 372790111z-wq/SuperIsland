import Foundation
import CryptoKit
import CoreFoundation

/// Fixed public error vocabulary. Raw server errors never cross into extension JS.
enum CodexUsageError: String, Error {
    case timeout, network, auth
    case rateLimited = "rate-limited"
    case invalidResponse = "invalid-response"
    case noCredentials = "no-credentials"
}

final class CodexUsageCancellation {
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void = {}) { self.action = action }

    func cancel() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

struct CodexUsageCredential {
    let token: String
    /// One-way hashes kept only in process memory, never in diagnostic output.
    let identity: String
    let fingerprint: String
    let accountID: String?

    init(token: String, accountID: String? = nil) {
        self.token = token
        self.accountID = accountID?.isEmpty == false ? accountID : nil
        identity = Self.digest(self.accountID.map { "account:\($0)" } ?? "token:\(token)")
        fingerprint = Self.digest(token)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum CodexUsageFetchResult {
    case response(status: Int, data: Data, retryAfter: String?)
    case failure(CodexUsageError)
}

struct CodexUsageSample {
    let primary: [String: Any]?
    let secondary: [String: Any]?
    let planType: String?
    let hasCredits: Bool
    let creditsUnlimited: Bool
    let updatedAt: Date
    let source: String
}

/// A nonblocking, single-flight cache. All mutable state is locked; dependencies
/// run outside the lock and are injectable without using any real account.
final class CodexUsageService {
    struct Dependencies {
        var now: () -> Date
        var credential: () -> CodexUsageCredential?
        var localSummary: (CodexUsageCredential, Date) -> CodexUsageSample?
        var fetch: (CodexUsageCredential, @escaping (CodexUsageFetchResult) -> Void) -> CodexUsageCancellation
        var scheduleTimeout: (TimeInterval, @escaping () -> Void) -> CodexUsageCancellation
        var work: (@escaping () -> Void) -> Void
        var onChange: () -> Void
        var log: (String) -> Void
    }

    static let normalTTL: TimeInterval = 300
    static let staleTTL: TimeInterval = 900
    static let requestTimeout: TimeInterval = 10
    private let dependencies: Dependencies
    private let lock = NSLock()
    private var checking = false
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var task: CodexUsageCancellation?
    private var timeoutTask: CodexUsageCancellation?
    private var identity: String?
    private var credentialFingerprint: String?
    private var sample: CodexUsageSample?
    private var status = "loading"
    private var error: CodexUsageError?
    private var nextAttempt: Date?
    private var failureCount = 0

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func snapshot() -> [String: Any] {
        let now = dependencies.now()
        lock.lock()
        expireSample(at: now)
        let result = payload()
        let shouldCheck = !checking
        if shouldCheck { checking = true }
        lock.unlock()
        if shouldCheck { dependencies.work { [weak self] in self?.check() } }
        return result
    }

    /// Revalidate credentials even during the success TTL so a detected sign-out
    /// or account switch cannot reuse the previous account's cached result.
    private func check() {
        let current = dependencies.credential()
        let now = dependencies.now()
        lock.lock()
        guard let current else {
            let changed = status != "unavailable" || error != .noCredentials || sample != nil
            clearIdentity()
            status = "unavailable"
            error = .noCredentials
            nextAttempt = now.addingTimeInterval(Self.normalTTL)
            checking = false
            lock.unlock()
            if changed { publish("Codex usage unavailable: no-credentials") }
            return
        }
        let identityChanged = identity != current.identity
        if identityChanged {
            clearIdentity()
            identity = current.identity
            status = "loading"
        }
        let tokenChanged = credentialFingerprint != current.fingerprint
        credentialFingerprint = current.fingerprint
        expireSample(at: now)
        if !tokenChanged, let nextAttempt, now < nextAttempt {
            checking = false
            lock.unlock()
            return
        }
        generation &+= 1
        let requestGeneration = generation
        activeGeneration = requestGeneration
        lock.unlock()
        if identityChanged { publish("Codex usage loading") }

        if let local = dependencies.localSummary(current, now) {
            complete(.success(local), generation: requestGeneration, credential: current)
            return
        }

        let timeout = dependencies.scheduleTimeout(Self.requestTimeout) { [weak self] in
            self?.complete(.failure(.timeout, nil), generation: requestGeneration, credential: current)
        }
        install(timeout, asTimeout: true, generation: requestGeneration)
        let request = dependencies.fetch(current) { [weak self] result in
            guard let self else { return }
            let outcome: Outcome
            switch result {
            case .failure(let error):
                outcome = .failure(error, nil)
            case .response(let code, let data, let retryAfter):
                if code == 401 || code == 403 {
                    outcome = .failure(.auth, nil)
                } else if code == 429 {
                    outcome = .failure(.rateLimited, Self.retryDelay(retryAfter, now: self.dependencies.now()))
                } else if !(200..<300).contains(code) {
                    outcome = .failure(.network, nil)
                } else if let parsed = CodexUsageParser.api(data, at: self.dependencies.now()) {
                    outcome = .success(parsed)
                } else {
                    outcome = .failure(.invalidResponse, nil)
                }
            }
            self.complete(outcome, generation: requestGeneration, credential: current)
        }
        install(request, asTimeout: false, generation: requestGeneration)
    }

    private enum Outcome {
        case success(CodexUsageSample)
        case failure(CodexUsageError, TimeInterval?)
    }

    private func install(_ cancellation: CodexUsageCancellation, asTimeout: Bool, generation: UInt64) {
        lock.lock()
        let stillActive = activeGeneration == generation
        if stillActive {
            if asTimeout { timeoutTask = cancellation } else { task = cancellation }
        }
        lock.unlock()
        // Covers synchronous test transports and an early timeout/completion.
        if !stillActive { cancellation.cancel() }
    }

    private func complete(_ outcome: Outcome, generation: UInt64, credential: CodexUsageCredential) {
        lock.lock()
        guard activeGeneration == generation else { lock.unlock(); return }
        activeGeneration = nil
        let request = task
        let timer = timeoutTask
        task = nil
        timeoutTask = nil
        lock.unlock()
        request?.cancel()
        timer?.cancel()

        dependencies.work { [weak self] in
            guard let self else { return }
            let latest = self.dependencies.credential()
            let now = self.dependencies.now()
            self.lock.lock()
            // A request started before sign-out/account/token change must not
            // publish its result into the new credential context.
            guard let latest, latest.identity == credential.identity,
                  latest.fingerprint == credential.fingerprint else {
                if latest?.identity != self.identity { self.clearIdentity() }
                self.identity = latest?.identity
                self.credentialFingerprint = latest?.fingerprint
                self.status = latest == nil ? "unavailable" : (self.sample == nil ? "loading" : "stale")
                self.error = latest == nil ? .noCredentials : nil
                self.nextAttempt = nil
                self.checking = false
                self.lock.unlock()
                self.publish("Codex usage credentials changed")
                return
            }
            let message: String
            switch outcome {
            case .success(let sample):
                self.sample = sample
                self.status = "ready"
                self.error = nil
                self.failureCount = 0
                self.nextAttempt = sample.updatedAt.addingTimeInterval(Self.normalTTL)
                message = "Codex usage ready"
            case .failure(let error, let retryAfter):
                self.failureCount += 1
                self.error = error
                if error == .auth || error == .noCredentials { self.sample = nil }
                self.expireSample(at: now)
                self.status = self.sample == nil ? "unavailable" : "stale"
                let base = error == .auth || error == .noCredentials
                    ? Self.normalTTL : min(60, 15 * pow(2, Double(min(2, self.failureCount - 1))))
                self.nextAttempt = now.addingTimeInterval(max(base, min(300, retryAfter ?? 0)))
                message = "Codex usage \(self.status): \(error.rawValue)"
            }
            self.checking = false
            self.lock.unlock()
            self.publish(message)
        }
    }

    /// Caller holds lock. This never treats stale data as a new observation.
    private func expireSample(at now: Date) {
        guard let sample else { return }
        if now.timeIntervalSince(sample.updatedAt) > Self.staleTTL {
            self.sample = nil
            status = "unavailable"
        } else if now.timeIntervalSince(sample.updatedAt) >= Self.normalTTL {
            status = "stale"
        }
    }

    private func clearIdentity() {
        identity = nil
        credentialFingerprint = nil
        sample = nil
        error = nil
        nextAttempt = nil
        failureCount = 0
    }

    private func payload() -> [String: Any] {
        var payload: [String: Any] = [
            "available": sample != nil,
            "status": status,
            "errorCode": error?.rawValue as Any? ?? NSNull(),
            "primary": sample?.primary as Any? ?? NSNull(),
            "secondary": sample?.secondary as Any? ?? NSNull(),
            "planType": sample?.planType as Any? ?? NSNull(),
            "hasCredits": sample?.hasCredits ?? false,
            // Unlimited credits do not mean the usage windows are unlimited.
            "unlimited": false,
            "creditsUnlimited": sample?.creditsUnlimited ?? false,
            "source": sample?.source ?? (status == "loading" ? "loading" : "unavailable"),
            "updatedAt": sample?.updatedAt.timeIntervalSince1970 as Any? ?? NSNull()
        ]
        if let nextAttempt { payload["nextRetryAt"] = nextAttempt.timeIntervalSince1970 }
        return payload
    }

    private func publish(_ message: String) {
        dependencies.log(message)
        dependencies.onChange()
    }

    static func retryDelay(_ header: String?, now: Date) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return min(300, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { min(300, max(0, $0.timeIntervalSince(now))) }
    }
}

/// Strict decoding prevents absent/bool/NaN fields becoming an invented 100%.
enum CodexUsageParser {
    static func api(_ data: Data, at now: Date) -> CodexUsageSample? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rate = root["rate_limit"] as? [String: Any],
              let windows = windows(primary: rate["primary_window"], secondary: rate["secondary_window"], api: true)
        else { return nil }
        let credits = root["credits"] as? [String: Any]
        return CodexUsageSample(primary: windows.0, secondary: windows.1, planType: root["plan_type"] as? String,
                                hasCredits: credits?["has_credits"] as? Bool ?? false,
                                creditsUnlimited: credits?["unlimited"] as? Bool ?? false, updatedAt: now, source: "oauth-api")
    }

    static func local(_ data: Data, credential: CodexUsageCredential, at now: Date) -> CodexUsageSample? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accountID = credential.accountID,
              (root["accountId"] as? String ?? root["account_id"] as? String) == accountID,
              let timestamp = number(root["updatedAt"]), timestamp > 0,
              now.timeIntervalSince1970 - timestamp >= 0,
              now.timeIntervalSince1970 - timestamp < CodexUsageService.normalTTL,
              let windows = windows(primary: root["primary"], secondary: root["secondary"], api: false)
        else { return nil }
        return CodexUsageSample(primary: windows.0, secondary: windows.1, planType: root["planType"] as? String,
                                hasCredits: root["hasCredits"] as? Bool ?? false,
                                creditsUnlimited: root["creditsUnlimited"] as? Bool ?? false,
                                updatedAt: Date(timeIntervalSince1970: timestamp), source: "local-summary")
    }

    private static func windows(primary: Any?, secondary: Any?, api: Bool) -> ([String: Any]?, [String: Any]?)? {
        var mapped: [[String: Any]?] = []
        for value in [primary, secondary] {
            if value == nil || value is NSNull { mapped.append(nil); continue }
            guard let window = value as? [String: Any], let parsed = windowPayload(window, api: api) else { return nil }
            mapped.append(parsed)
        }
        guard mapped.contains(where: { $0 != nil }) else { return nil }
        return (mapped[0], mapped[1])
    }

    private static func windowPayload(_ window: [String: Any], api: Bool) -> [String: Any]? {
        let used = number(window[api ? "used_percent" : "usedPercent"])
        let remaining = api ? used.map { 100 - $0 } : number(window["remainingPercent"]) ?? used.map { 100 - $0 }
        guard let remaining, (0...100).contains(remaining),
              used.map({ (0...100).contains($0) && abs(100 - $0 - remaining) < 0.001 }) ?? true,
              let duration = number(window[api ? "limit_window_seconds" : "windowMinutes"]), duration > 0,
              duration <= (api ? 366 * 86400 : 366 * 1440) else { return nil }
        let minutes = api ? duration / 60 : duration
        guard minutes >= 1, minutes.rounded(.down) == minutes else { return nil }
        var result: [String: Any] = ["usedPercent": 100 - remaining, "remainingPercent": remaining,
                                   "windowMinutes": minutes, "windowLabel": minutes >= 60 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m"]
        if let reset = window[api ? "reset_at" : "resetsAt"], !(reset is NSNull) {
            guard let timestamp = number(reset), timestamp > 0 else { return nil }
            result["resetsAt"] = timestamp
        } else { result["resetsAt"] = NSNull() }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }
}

extension CodexUsageService.Dependencies {
    static func live(onChange: @escaping () -> Void, log: @escaping (String) -> Void) -> Self {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.timeoutIntervalForRequest = CodexUsageService.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = CodexUsageService.requestTimeout
        sessionConfiguration.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfiguration)
        return .init(
            now: Date.init,
            credential: {
                guard let data = boundedRead(directory.appendingPathComponent("auth.json")),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tokens = object["tokens"] as? [String: Any],
                      let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
                return CodexUsageCredential(token: token, accountID: tokens["account_id"] as? String)
            },
            localSummary: { credential, now in
                for relative in ["usage-summary.json", "usage/summary.json"] {
                    if let data = boundedRead(directory.appendingPathComponent(relative)),
                       let parsed = CodexUsageParser.local(data, credential: credential, at: now) { return parsed }
                }
                return nil
            },
            fetch: { credential, completion in
                var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
                request.timeoutInterval = CodexUsageService.requestTimeout
                request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("SuperIsland/1.0", forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error as? URLError {
                        completion(.failure(error.code == .timedOut ? .timeout : .network))
                    } else if error != nil {
                        completion(.failure(.network))
                    } else if let response = response as? HTTPURLResponse, (data?.count ?? 0) <= 1_048_576 {
                        completion(.response(status: response.statusCode, data: data ?? Data(),
                                             retryAfter: response.value(forHTTPHeaderField: "Retry-After")))
                    } else { completion(.failure(.invalidResponse)) }
                }
                task.resume()
                return CodexUsageCancellation { task.cancel() }
            },
            scheduleTimeout: { delay, completion in
                let item = DispatchWorkItem(block: completion)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
                return CodexUsageCancellation { item.cancel() }
            },
            work: { operation in DispatchQueue.global(qos: .utility).async(execute: operation) },
            onChange: onChange,
            log: log
        )
    }

    private static func boundedRead(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576 else { return nil }
        return try? Data(contentsOf: url)
    }
}
