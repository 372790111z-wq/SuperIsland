import AppKit
import AuthenticationServices
import Combine
import Foundation

enum ExtensionOAuthProvider: String, CaseIterable {
    case linear
    case lastfm

    var extensionID: String {
        switch self {
        case .linear: return "superisland.linear-mentions"
        case .lastfm: return "superisland.lastfm-scrobbler"
        }
    }

    var storeKey: String { "extensions.\(extensionID).store.oauth" }

    var authorizeURL: URL {
        // The original service performs the provider exchange and returns the
        // existing superisland://auth/callback payload.
        URL(string: "https://api.supercmd.sh/auth/\(rawValue)/authorize?app=superisland")!
    }
}

enum ExtensionOAuthError: Error, Equatable {
    case invalidCallback
    case providerMismatch
    case missingToken
    case invalidExpiration
    case authorizationDenied
    case authenticationFailed

    var message: String {
        switch self {
        case .providerMismatch: return "登录来源不匹配，请重试。"
        case .authorizationDenied: return "未完成授权，请重试。"
        case .authenticationFailed: return "登录未完成，请检查网络后重试。"
        case .invalidCallback, .missingToken, .invalidExpiration:
            return "登录结果无效，请重试。"
        }
    }
}

struct ExtensionOAuthCallback {
    let provider: ExtensionOAuthProvider
    let payload: [String: Any]

    static func parse(
        _ url: URL,
        expectedProvider: ExtensionOAuthProvider,
        receivedAt: Date = Date()
    ) throws -> ExtensionOAuthCallback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "superisland",
              components.host?.lowercased() == "auth",
              components.path == "/callback",
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else {
            throw ExtensionOAuthError.invalidCallback
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard values[name] == nil else { throw ExtensionOAuthError.invalidCallback }
            values[name] = item.value ?? ""
        }

        guard values["provider"]?.lowercased() == expectedProvider.rawValue else {
            throw ExtensionOAuthError.providerMismatch
        }
        if let error = values["error"], !error.isEmpty {
            throw ExtensionOAuthError.authorizationDenied
        }
        let accessToken = (values["access_token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { throw ExtensionOAuthError.missingToken }

        var expiresIn = 0
        if let rawExpiration = values["expires_in"], !rawExpiration.isEmpty {
            guard let expiration = Int(rawExpiration), expiration >= 0 else {
                throw ExtensionOAuthError.invalidExpiration
            }
            expiresIn = expiration
        }
        let rawTokenType = (values["token_type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenType = rawTokenType.isEmpty ? "Bearer" : rawTokenType
        var payload: [String: Any] = [
            "provider": expectedProvider.rawValue,
            "accessToken": accessToken,
            "access_token": accessToken,
            "tokenType": tokenType,
            "token_type": tokenType,
            "expiresIn": expiresIn,
            "expires_in": expiresIn,
            "scope": values["scope"] ?? "",
            "receivedAt": Int(receivedAt.timeIntervalSince1970)
        ]
        let username = [values["username"], values["name"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let username { payload["username"] = username }

        if expectedProvider == .lastfm {
            for (queryKey, storeKey) in [("api_key", "apiKey"), ("api_secret", "apiSecret")] {
                if let value = values[queryKey], !value.isEmpty {
                    payload[queryKey] = value
                    payload[storeKey] = value
                }
            }
        }
        // Neither extension uses the callback URL. Keep the expected credential
        // fields, without storing a second copy of all credentials in that URL.
        return ExtensionOAuthCallback(provider: expectedProvider, payload: payload)
    }

    /// Returns nil for cancellation. Any failure leaves the existing session intact.
    static func storeCompletion(
        url: URL?,
        error: Error?,
        expectedProvider: ExtensionOAuthProvider,
        defaults: UserDefaults,
        receivedAt: Date = Date()
    ) throws -> ExtensionOAuthCallback? {
        if let error {
            let nativeError = error as NSError
            if nativeError.domain == ASWebAuthenticationSessionErrorDomain,
               nativeError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return nil
            }
            throw ExtensionOAuthError.authenticationFailed
        }
        guard let url else { throw ExtensionOAuthError.invalidCallback }
        let callback = try parse(url, expectedProvider: expectedProvider, receivedAt: receivedAt)
        defaults.set(callback.payload, forKey: callback.provider.storeKey)
        return callback
    }
}

/// Owns the native authentication session independently of the selected settings
/// row. WE1 receives only its initiated callback, without registering the original
/// application's system-wide URL scheme.
@MainActor
final class ExtensionOAuthCoordinator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = ExtensionOAuthCoordinator()
    static var usesScopedAuthentication: Bool {
        Bundle.main.bundleIdentifier == "com.workview.SuperIsland.WE1Debug"
    }

    @Published private(set) var activeProvider: ExtensionOAuthProvider?
    @Published private(set) var messages: [ExtensionOAuthProvider: String] = [:]
    @Published private(set) var completedAuthorizationCount = 0

    private var authenticationSession: ASWebAuthenticationSession?
    private var attemptID: UUID?
    private var anchor: NSWindow?

    func authorize(_ provider: ExtensionOAuthProvider) {
        guard activeProvider == nil else { return }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            messages[provider] = "请打开设置窗口后重试。"
            return
        }

        let id = UUID()
        attemptID = id
        activeProvider = provider
        messages[provider] = "正在登录…"
        anchor = window
        let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
            Task { @MainActor [weak self] in
                self?.complete(id: id, provider: provider, url: url, error: error)
            }
        }
        let session: ASWebAuthenticationSession
        if #available(macOS 14.4, *) {
            session = ASWebAuthenticationSession(url: provider.authorizeURL, callback: .customScheme("superisland"), completionHandler: completion)
        } else {
            session = ASWebAuthenticationSession(url: provider.authorizeURL, callbackURLScheme: "superisland", completionHandler: completion)
        }
        session.presentationContextProvider = self
        authenticationSession = session
        if !session.start() {
            clearAttempt()
            messages[provider] = "无法打开登录窗口，请重试。"
        }
    }

    func cancel(_ provider: ExtensionOAuthProvider) {
        guard activeProvider == provider else { return }
        let session = authenticationSession
        clearAttempt()
        session?.cancel()
        messages[provider] = "已取消"
    }

    func clearMessage(_ provider: ExtensionOAuthProvider) {
        messages[provider] = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // start() is called only after obtaining and retaining a visible window.
        anchor ?? ASPresentationAnchor()
    }

    private func complete(id: UUID, provider: ExtensionOAuthProvider, url: URL?, error: Error?) {
        // A canceled session can finish after a subsequent attempt has started.
        guard attemptID == id, activeProvider == provider else { return }
        clearAttempt()
        do {
            guard let callback = try ExtensionOAuthCallback.storeCompletion(
                url: url, error: error, expectedProvider: provider, defaults: .standard
            ) else {
                messages[provider] = "已取消"
                return
            }
            let manager = ExtensionManager.shared
            if manager.runtimes[callback.provider.extensionID] == nil {
                manager.activate(extensionID: callback.provider.extensionID)
            }
            manager.scheduleImmediateRefresh(extensionID: callback.provider.extensionID)
            completedAuthorizationCount += 1
            messages[provider] = "已连接"
        } catch let error as ExtensionOAuthError {
            messages[provider] = error.message
        } catch {
            messages[provider] = ExtensionOAuthError.authenticationFailed.message
        }
    }

    private func clearAttempt() {
        attemptID = nil
        activeProvider = nil
        authenticationSession = nil
        anchor = nil
    }
}
