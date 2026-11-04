import Foundation
import Security
import CryptoKit

@objc protocol KeepAwakeHelperProtocol {
    func status(reply: @escaping (Bool, String) -> Void)
    func renew(owner: String, acOnly: Bool, minimumBattery: Int, respectLowPower: Bool, reply: @escaping (Bool, String) -> Void)
    func release(owner: String, reply: @escaping (Bool, String) -> Void)
}

enum KeepAwakeHelperIdentity {
    static let label = "com.workview.SuperIsland.KeepAwakeHelper"
    static let plist = label + ".plist"
    /// Pin the signing leaf, including a locally managed signing certificate.
    /// Ad-hoc/unsigned binaries have no certificate and are not authorized.
    static func requirement(identifiers: [String], diagnostic: ((String) -> Void)? = nil) -> String? {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else { diagnostic?("SecCodeCopySelf status=\(selfStatus)"); return nil }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else { diagnostic?("SecCodeCopyStaticCode status=\(staticStatus)"); return nil }
        var information: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard signingStatus == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { diagnostic?("SecCodeCopySigningInformation status=\(signingStatus); signing leaf unavailable"); return nil }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let identifiers = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "certificate leaf = H\"\(fingerprint)\" and (\(identifiers))"
    }
}
