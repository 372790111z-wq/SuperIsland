import AuthenticationServices
import Foundation
import XCTest
@testable import SuperIsland

final class ExtensionOAuthCallbackTests: XCTestCase {
    func testLinearCallbackPreservesExistingExtensionPayloadWithoutSecretURL() throws {
        let callback = try ExtensionOAuthCallback.parse(
            url(provider: "linear", extra: ["expires_in": "3600", "scope": "read write"]),
            expectedProvider: .linear,
            receivedAt: Date(timeIntervalSince1970: 1234)
        )
        XCTAssertEqual(callback.payload["accessToken"] as? String, "test-token")
        XCTAssertEqual(callback.payload["access_token"] as? String, "test-token")
        XCTAssertEqual(callback.payload["tokenType"] as? String, "Bearer")
        XCTAssertEqual(callback.payload["expiresIn"] as? Int, 3600)
        XCTAssertEqual(callback.payload["receivedAt"] as? Int, 1234)
        XCTAssertEqual(callback.payload["scope"] as? String, "read write")
        XCTAssertNil(callback.payload["callbackURL"])
    }

    func testLastFmCallbackPreservesSigningFieldsAndNameFallback() throws {
        let callback = try ExtensionOAuthCallback.parse(
            url(provider: "lastfm", extra: ["api_key": "test-key", "api_secret": "test-secret", "name": "example"]),
            expectedProvider: .lastfm
        )
        XCTAssertEqual(callback.payload["username"] as? String, "example")
        XCTAssertEqual(callback.payload["apiKey"] as? String, "test-key")
        XCTAssertEqual(callback.payload["api_secret"] as? String, "test-secret")
        XCTAssertEqual(callback.payload["expiresIn"] as? Int, 0)
    }

    func testCallbackCannotSwitchProviderSelectedForTheSession() throws {
        try withDefaults { defaults in
            defaults.set(["accessToken": "previous"], forKey: ExtensionOAuthProvider.linear.storeKey)
            XCTAssertThrowsError(try ExtensionOAuthCallback.storeCompletion(
                url: url(provider: "lastfm"), error: nil, expectedProvider: .linear, defaults: defaults
            )) { XCTAssertEqual($0 as? ExtensionOAuthError, .providerMismatch) }
            XCTAssertEqual(defaults.dictionary(forKey: ExtensionOAuthProvider.linear.storeKey)?["accessToken"] as? String, "previous")
            XCTAssertNil(defaults.dictionary(forKey: ExtensionOAuthProvider.lastfm.storeKey))
        }
    }

    func testOnlyExpectedCallbackEndpointCanStoreCredentials() throws {
        let invalidURLs = [
            "https://auth/callback?provider=linear&access_token=test-token",
            "superisland://other/callback?provider=linear&access_token=test-token",
            "superisland://auth/other?provider=linear&access_token=test-token",
            "superisland://user@auth/callback?provider=linear&access_token=test-token",
            "superisland://auth:80/callback?provider=linear&access_token=test-token",
            "superisland://auth/callback?provider=linear&access_token=test-token#other"
        ]
        try withDefaults { defaults in
            for raw in invalidURLs {
                XCTAssertThrowsError(try ExtensionOAuthCallback.storeCompletion(
                    url: URL(string: raw), error: nil, expectedProvider: .linear, defaults: defaults
                )) { XCTAssertEqual($0 as? ExtensionOAuthError, .invalidCallback) }
            }
            XCTAssertNil(defaults.dictionary(forKey: ExtensionOAuthProvider.linear.storeKey))
        }
    }

    func testDuplicateCallbackKeysCannotOverwriteAnEarlierValue() {
        let duplicate = URL(string: "superisland://auth/callback?provider=linear&access_token=first&ACCESS_TOKEN=second")!
        XCTAssertThrowsError(try ExtensionOAuthCallback.parse(duplicate, expectedProvider: .linear)) {
            XCTAssertEqual($0 as? ExtensionOAuthError, .invalidCallback)
        }
    }

    func testInvalidExpirationCannotBecomeANonExpiringSession() {
        for expiration in ["-1", "not-a-number", "999999999999999999999999"] {
            XCTAssertThrowsError(try ExtensionOAuthCallback.parse(
                url(provider: "linear", extra: ["expires_in": expiration]), expectedProvider: .linear
            )) { XCTAssertEqual($0 as? ExtensionOAuthError, .invalidExpiration) }
        }
    }

    func testEmptyTokenAndDeniedAuthorizationAreRejected() {
        XCTAssertThrowsError(try ExtensionOAuthCallback.parse(
            url(provider: "linear", extra: ["access_token": " \n "]), expectedProvider: .linear
        )) { XCTAssertEqual($0 as? ExtensionOAuthError, .missingToken) }
        XCTAssertThrowsError(try ExtensionOAuthCallback.parse(
            url(provider: "linear", extra: ["error": "access_denied"]), expectedProvider: .linear
        )) { XCTAssertEqual($0 as? ExtensionOAuthError, .authorizationDenied) }
    }

    func testCanceledLoginLeavesExistingCredentialsUnchangedEvenWithCallbackURL() throws {
        try withDefaults { defaults in
            defaults.set(["accessToken": "previous"], forKey: ExtensionOAuthProvider.linear.storeKey)
            let cancellation = NSError(domain: ASWebAuthenticationSessionErrorDomain,
                                       code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
            let callback = try ExtensionOAuthCallback.storeCompletion(
                url: url(provider: "linear"), error: cancellation, expectedProvider: .linear, defaults: defaults
            )
            XCTAssertNil(callback)
            XCTAssertEqual(defaults.dictionary(forKey: ExtensionOAuthProvider.linear.storeKey)?["accessToken"] as? String, "previous")
        }
    }

    func testOtherErrorsAndMissingResultDoNotCreateSession() throws {
        try withDefaults { defaults in
            XCTAssertThrowsError(try ExtensionOAuthCallback.storeCompletion(
                url: url(provider: "linear"), error: NSError(domain: "other", code: 1), expectedProvider: .linear, defaults: defaults
            )) { XCTAssertEqual($0 as? ExtensionOAuthError, .authenticationFailed) }
            XCTAssertThrowsError(try ExtensionOAuthCallback.storeCompletion(
                url: nil, error: nil, expectedProvider: .linear, defaults: defaults
            )) { XCTAssertEqual($0 as? ExtensionOAuthError, .invalidCallback) }
            XCTAssertNil(defaults.dictionary(forKey: ExtensionOAuthProvider.linear.storeKey))
        }
    }

    func testSuccessfulLoginWritesOnlySelectedProviderInSuppliedDomain() throws {
        try withDefaults { local in
            try withDefaults { otherDomain in
                otherDomain.set(["accessToken": "production-example"], forKey: ExtensionOAuthProvider.linear.storeKey)
                local.set(["accessToken": "lastfm-existing"], forKey: ExtensionOAuthProvider.lastfm.storeKey)
                let callback = try ExtensionOAuthCallback.storeCompletion(
                    url: url(provider: "linear"), error: nil, expectedProvider: .linear, defaults: local
                )
                XCTAssertEqual(callback?.provider, .linear)
                XCTAssertEqual(local.dictionary(forKey: ExtensionOAuthProvider.linear.storeKey)?["accessToken"] as? String, "test-token")
                XCTAssertEqual(local.dictionary(forKey: ExtensionOAuthProvider.lastfm.storeKey)?["accessToken"] as? String, "lastfm-existing")
                XCTAssertEqual(otherDomain.dictionary(forKey: ExtensionOAuthProvider.linear.storeKey)?["accessToken"] as? String, "production-example")
            }
        }
    }

    private func url(provider: String, extra: [String: String] = [:]) -> URL {
        var components = URLComponents(string: "superisland://auth/callback")!
        var values = ["provider": provider, "access_token": "test-token"]
        values.merge(extra) { _, new in new }
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ExtensionOAuthCallbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
