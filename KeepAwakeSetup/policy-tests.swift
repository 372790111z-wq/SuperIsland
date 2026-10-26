let code = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil)!
let ssl = SecPolicyCreateSSL(true, nil)
let rule: [String: Any] = [kSecTrustSettingsPolicy as String: code,
    kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue)]
assert(exactCodeSigningTrust([rule] as CFArray))
assert(!exactCodeSigningTrust([] as CFArray))
assert(!exactCodeSigningTrust([rule, rule] as CFArray))
var altered = rule; altered[kSecTrustSettingsPolicy as String] = ssl
assert(!exactCodeSigningTrust([altered] as CFArray))
altered = rule; altered[kSecTrustSettingsResult as String] = NSNumber(value: SecTrustSettingsResult.deny.rawValue)
assert(!exactCodeSigningTrust([altered] as CFArray))
altered = rule; altered["unexpected"] = "retain"
assert(!exactCodeSigningTrust([altered] as CFArray))
altered = rule; altered.removeValue(forKey: kSecTrustSettingsResult as String)
assert(exactCodeSigningTrust([altered] as CFArray))
altered["kSecTrustSettingsPolicyName"] = "CodeSigning"
assert(exactCodeSigningTrust([altered] as CFArray))
altered["kSecTrustSettingsPolicyName"] = "SSL"
assert(!exactCodeSigningTrust([altered] as CFArray))
altered = rule; altered[kSecTrustSettingsResult as String] = "unexpected result type"
assert(!exactCodeSigningTrust([altered] as CFArray))
altered = [kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue)]
assert(!exactCodeSigningTrust([altered] as CFArray))
print("11 code-signing trust policy cases passed")
