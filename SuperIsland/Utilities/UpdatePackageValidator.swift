import Foundation
import Security

struct UpdatePackageValidator {
    enum ValidationError: LocalizedError {
        case wrongApplication, wrongBuild, wrongArchitecture, invalidSignature
        var errorDescription: String? {
            switch self {
            case .wrongApplication: return "安装包不适用于当前应用，原版本已保留"
            case .wrongBuild: return "安装包版本不符，原版本已保留"
            case .wrongArchitecture: return "安装包不适用于这台 Mac，原版本已保留"
            case .invalidSignature: return "安装包签名无法验证，原版本已保留"
            }
        }
    }

    static func validate(appURL: URL, installedURL: URL, policy: UpdateReleasePolicy, downloadURL: URL) throws {
        guard let app = Bundle(url: appURL) else { throw ValidationError.wrongApplication }
        let expectedBuild = policy.isWE1
            ? String(downloadURL.deletingLastPathComponent().lastPathComponent.dropFirst(4)) : nil
        try validateMetadata(
            bundleIdentifier: app.bundleIdentifier,
            build: app.infoDictionary?["CFBundleVersion"] as? String,
            executableArchitectures: app.executableArchitectures?.map { $0.intValue } ?? [],
            policy: policy,
            expectedBuild: expectedBuild
        )
        var installedCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: 0)
        guard SecStaticCodeCreateWithPath(installedURL as CFURL, flags, &installedCode) == errSecSuccess,
              let installedCode,
              SecCodeCopyDesignatedRequirement(installedCode, flags, &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(appURL as CFURL, flags, &candidateCode) == errSecSuccess,
              let candidateCode else { throw ValidationError.invalidSignature }
        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidateCode, validationFlags, requirement) == errSecSuccess else {
            throw ValidationError.invalidSignature
        }
    }

    static func validateMetadata(
        bundleIdentifier: String?, build: String?, executableArchitectures: [Int],
        policy: UpdateReleasePolicy, expectedBuild: String?
    ) throws {
        guard !policy.bundleIdentifier.isEmpty, bundleIdentifier == policy.bundleIdentifier else {
            throw ValidationError.wrongApplication
        }
        let cpuType = policy.architecture == "arm64" ? 0x0100000c : 0x01000007
        guard executableArchitectures.contains(cpuType) else { throw ValidationError.wrongArchitecture }
        if policy.isWE1 {
            guard let build, let expectedBuild, UpdateReleasePolicy.validBuild(build),
                  build == expectedBuild, build > policy.currentBuild else { throw ValidationError.wrongBuild }
        }
    }
}
