import Foundation
import Security
import CryptoKit
import IOKit.ps
import Darwin

// This executable only reads public certificates, signature metadata and trust
// settings. Installer scripts own the separately reviewed, fixed write commands.
enum InspectionFailure: Error { case invalidCertificate, keychain(OSStatus), trust(OSStatus) }

func exactCodeSigningTrust(_ settings: CFArray) -> Bool {
    guard let entries = settings as? [[String: Any]], entries.count == 1,
          let entry = entries.first,
          Set(entry.keys).isSubset(of: Set([kSecTrustSettingsPolicy as String, kSecTrustSettingsResult as String, "kSecTrustSettingsPolicyName"])),
          let value = entry[kSecTrustSettingsPolicy as String],
          CFGetTypeID(value as CFTypeRef) == SecPolicyGetTypeID() else { return false }
    // SecTrustSettings.h defines an omitted result as trustRoot. The security
    // tool also returns a CodeSigning policy-name metadata field on current macOS.
    if let raw = entry[kSecTrustSettingsResult as String] {
        guard let result = raw as? NSNumber,
              result.uint32Value == SecTrustSettingsResult.trustRoot.rawValue else { return false }
    }
    if let name = entry["kSecTrustSettingsPolicyName"] {
        guard name as? String == "CodeSigning" else { return false }
    }
    let policy = value as! SecPolicy
    guard let actual = SecPolicyCopyProperties(policy) as? [String: Any],
          let oid = actual[kSecPolicyOid as String] as? String,
          let expected = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil),
          let expectedProperties = SecPolicyCopyProperties(expected) as? [String: Any],
          let expectedOID = expectedProperties[kSecPolicyOid as String] as? String else { return false }
    return oid == expectedOID && NSDictionary(dictionary: actual).isEqual(to: expectedProperties)
}

func validCode(_ path: String, identifiers: [String]) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
          let code else { return false }
    let allowed = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
    let text = "certificate leaf = H\"\(SetupPolicy.sha1)\" and (\(allowed))"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
}

func inspect(_ path: String) throws -> [String: Any] {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw InspectionFailure.invalidCertificate }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_size > 0, metadata.st_size <= 16_384 else { throw InspectionFailure.invalidCertificate }
    let data = try handle.read(upToCount: 16_385) ?? Data()
    guard data.count <= 16_384,
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == SetupPolicy.sha256,
          let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw InspectionFailure.invalidCertificate }
    var settings: CFArray?
    let trustStatus = SecTrustSettingsCopyTrustSettings(certificate, .admin, &settings)
    let absent = trustStatus == errSecItemNotFound || trustStatus == errSecNoTrustSettings
    guard absent || trustStatus == errSecSuccess else { throw InspectionFailure.trust(trustStatus) }
    var keychain: SecKeychain?
    let opened = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
    guard opened == errSecSuccess, let keychain else { throw InspectionFailure.keychain(opened) }
    let query: [String: Any] = [kSecClass as String: kSecClassCertificate,
        kSecMatchSearchList as String: [keychain], kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true]
    var items: CFTypeRef?
    let found = SecItemCopyMatching(query as CFDictionary, &items)
    guard found == errSecSuccess || found == errSecItemNotFound else { throw InspectionFailure.keychain(found) }
    let certificates: [SecCertificate]
    if found == errSecItemNotFound { certificates = [] }
    else {
        guard let values = items as? [SecCertificate] else { throw InspectionFailure.keychain(errSecDecode) }
        certificates = values
    }
    let systemPresent = certificates.contains {
        SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined() == SetupPolicy.sha256
    }
    let app = "/Applications/SuperIsland.app"
    let appValid = validCode(app, identifiers: [SetupPolicy.bundleID]) &&
        validCode(app + "/Contents/MacOS/KeepAwakeHelper", identifiers: ["com.workview.SuperIsland.KeepAwakeHelper"]) &&
        validCode(app + "/Contents/MacOS/KeepAwakeEventTool", identifiers: ["com.workview.SuperIsland.KeepAwakeEventTool"])
    var notebook = false
    if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
        notebook = list.contains { source in
            let values = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
            return values?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
    return ["CertificateSHA256": SetupPolicy.sha256, "CertificateSHA1": SetupPolicy.sha1,
        "AdminEntryPresent": !absent, "ExactCodeSigningTrust": settings.map(exactCodeSigningTrust) ?? false,
        "SystemCertificatePresent": systemPresent, "AppSignatureValid": appValid, "Notebook": notebook]
}

#if !KEEP_AWAKE_INSPECTOR_TESTS
do {
    guard CommandLine.arguments.count == 2 else { throw InspectionFailure.invalidCertificate }
    let result = try inspect(CommandLine.arguments[1])
    let plist = try PropertyListSerialization.data(fromPropertyList: result, format: .xml, options: 0)
    FileHandle.standardOutput.write(plist)
} catch {
    // No private paths, trust-store contents or certificate subject names in logs.
    FileHandle.standardError.write(Data("SuperIsland public signing inspection failed. No settings changed.\n".utf8))
    exit(1)
}
#endif
