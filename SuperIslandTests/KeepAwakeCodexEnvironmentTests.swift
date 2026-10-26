import Darwin
import XCTest
@testable import SuperIsland

final class KeepAwakeCodexEnvironmentTests: XCTestCase {
    private typealias Environment = KeepAwakeCodexEnvironment
    private let userHome = URL(fileURLWithPath: "/Users/another-user", isDirectory: true)
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/codex")

    private func resolve(environment: [String: String] = [:], applications: [URL] = [],
                         children: [Environment.DesktopChild] = [], requireEndpoint: Bool = false,
                         official: ((URL) -> Bool)? = nil,
                         endpoint: (URL) throws -> Void = { _ in XCTFail("Discovery must not require a socket") }) throws -> Environment.Profile {
        try Environment.resolve(userHome: userHome, environment: environment, applications: applications,
                                desktopChildren: children, requireEndpoint: requireEndpoint,
                                isOfficialExecutable: official ?? { $0 == self.executable }, validateEndpoint: endpoint)
    }

    func testDefaultHomeUsesSuppliedUserRatherThanThisMachinesUsername() throws {
        let profile = try resolve(environment: ["HOME": "/Users/unrelated-user"])
        XCTAssertEqual(profile.codexHome.path, "/Users/another-user/.codex")
        XCTAssertEqual(profile.socketURL.path, "/Users/another-user/.codex/app-server-control/app-server-control.sock")
    }

    func testAbsoluteCustomHomeWithSpacesAndUnicodeIsPreserved() throws {
        let profile = try resolve(environment: ["CODEX_HOME": "/Volumes/Work Disk/用户/Codex Home"])
        XCTAssertEqual(profile.codexHome.path, "/Volumes/Work Disk/用户/Codex Home")
        XCTAssertTrue(profile.socketURL.path.hasPrefix(profile.codexHome.path + "/"))
    }

    func testInvalidCustomHomeIsRejectedWithoutFallingBack() {
        for value in ["", "relative/home", "~/my-codex", "/Users/user\nother"] {
            XCTAssertThrowsError(try resolve(environment: ["CODEX_HOME": value])) {
                XCTAssertEqual($0 as? Environment.Failure, .invalidEnvironment)
            }
        }
    }

    func testRenamedApplicationInUserApplicationsSuppliesRelativeExecutable() throws {
        let app = userHome.appendingPathComponent("Applications/My Renamed Assistant.app")
        let bundled = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let profile = try resolve(applications: [app], official: { $0 == bundled })
        XCTAssertEqual(profile.executableURL, bundled)
    }

    func testNonemptyGUIPathStillIncludesHomebrewAndUserLocalBin() throws {
        XCTAssertEqual(try resolve(environment: ["PATH": "/usr/bin:/bin"]).executableURL, executable)
        let local = userHome.appendingPathComponent(".local/bin/codex")
        XCTAssertEqual(try resolve(environment: ["PATH": "/usr/bin"], official: { $0 == local }).executableURL, local)
        let intel = URL(fileURLWithPath: "/usr/local/bin/codex")
        XCTAssertEqual(try resolve(environment: ["PATH": "/usr/bin"], official: { $0 == intel }).executableURL, intel)
    }

    func testUntrustedExecutableCannotCreateAProfile() {
        XCTAssertThrowsError(try resolve(environment: ["PATH": "/tmp/fake-cli"], official: { _ in false })) {
            XCTAssertEqual($0 as? Environment.Failure, .unavailable)
        }
    }

    func testDesktopChildActualHomeOverridesUnrelatedInheritedEnvironment() throws {
        let appCLI = URL(fileURLWithPath: "/Users/another-user/Applications/Codex Renamed.app/Contents/Resources/codex")
        let child = Environment.DesktopChild(executableURL: appCLI, home: URL(fileURLWithPath: "/Users/desktop-user"),
                                            codexHome: URL(fileURLWithPath: "/Volumes/Tasks/Live Profile"))
        let profile = try resolve(environment: ["CODEX_HOME": "/Users/wrong-profile"], children: [child], official: { $0 == appCLI })
        XCTAssertEqual(profile.executableURL, appCLI)
        XCTAssertEqual(profile.codexHome.path, "/Volumes/Tasks/Live Profile")
    }

    func testDesktopHomeFallsBackToThatChildsHomeNotTheCallersHome() throws {
        let child = Environment.DesktopChild(executableURL: executable, home: URL(fileURLWithPath: "/Users/desktop-user"), codexHome: nil)
        XCTAssertEqual(try resolve(children: [child]).codexHome.path, "/Users/desktop-user/.codex")
    }

    func testConflictingDesktopHomesAreRejectedEvenIfOnlyOneSocketIsAvailable() {
        let children = ["/Users/one/.codex", "/Users/two/.codex"].map {
            Environment.DesktopChild(executableURL: executable, home: nil, codexHome: URL(fileURLWithPath: $0))
        }
        var endpointsChecked = 0
        XCTAssertThrowsError(try resolve(children: children, requireEndpoint: true, endpoint: { _ in endpointsChecked += 1 })) {
            XCTAssertEqual($0 as? Environment.Failure, .ambiguous)
        }
        XCTAssertEqual(endpointsChecked, 0)
    }

    func testEquivalentDesktopHomesDoNotCreateAConflict() throws {
        var children = ["/Users/another-user/profiles/../.codex", "/Users/another-user/.codex"].map {
            Environment.DesktopChild(executableURL: executable, home: nil, codexHome: URL(fileURLWithPath: $0))
        }
        children.append(.init(executableURL: executable, home: nil,
                              codexHome: URL(fileURLWithPath: "/Users/another-user/.codex", isDirectory: true)))
        XCTAssertEqual(try resolve(children: children).codexHome.path, "/Users/another-user/.codex")
    }

    func testUnreadableSignedChildHomeDoesNotSilentlyUseDefaultHome() {
        let child = Environment.DesktopChild(executableURL: executable, home: nil, codexHome: nil)
        XCTAssertThrowsError(try resolve(children: [child])) {
            XCTAssertEqual($0 as? Environment.Failure, .invalidEnvironment)
        }
    }

    func testUnsignedChildEnvironmentIsNotTrusted() throws {
        let child = Environment.DesktopChild(executableURL: URL(fileURLWithPath: "/tmp/fake/codex"), home: nil,
                                            codexHome: URL(fileURLWithPath: "/Users/untrusted"))
        XCTAssertEqual(try resolve(children: [child]).codexHome.path, "/Users/another-user/.codex")
    }

    func testHookDiscoveryDoesNotNeedSocketButRPCDiscoveryDoes() throws {
        let profile = try resolve()
        var checked: [URL] = []
        XCTAssertThrowsError(try resolve(requireEndpoint: true, endpoint: { url in
            checked.append(url); throw Environment.Failure.unavailable
        })) { XCTAssertEqual($0 as? Environment.Failure, .unavailable) }
        XCTAssertEqual(checked, [profile.socketURL])
        XCTAssertEqual(try resolve(requireEndpoint: true, endpoint: { XCTAssertEqual($0, profile.socketURL) }), profile)
    }

    func testProfileCodableContainsOnlyPortableBindingFields() throws {
        let profile = try resolve(environment: ["CODEX_HOME": "/Volumes/Work/Codex Home"])
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(Environment.Profile.self, from: data), profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["executableURL", "codexHome", "socketURL"])
    }

    func testRelativePathEntriesAndDuplicateApplicationsAreNotCandidates() {
        let app = userHome.appendingPathComponent("Applications/Custom.app")
        let paths = Environment.executableCandidates(userHome: userHome,
            environment: ["PATH": ".:relative/bin::/custom/tools:/custom/tools"], applications: [app, app]).map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count)
        XCTAssertTrue(paths.contains("/custom/tools/codex"))
        XCTAssertFalse(paths.contains { $0.contains("relative/bin") })
    }

    func testProcessEnvironmentParserDecodesOnlyAllowedPathsAndSkipsPrivateArguments() throws {
        let data = processArguments(["codex", "PRIVATE TASK BODY"],
            environment: ["AUTH_TOKEN=PRIVATE TOKEN", "HOME=/Users/desktop-user", "CODEX_HOME=/Volumes/Work Disk/Codex"])
        XCTAssertEqual(Environment.allowedProcessEnvironment(data),
                       ["HOME": "/Users/desktop-user", "CODEX_HOME": "/Volumes/Work Disk/Codex"])
    }

    func testMalformedTruncatedOrDuplicateProcessEnvironmentIsRejected() {
        XCTAssertNil(Environment.allowedProcessEnvironment(Data([1, 2])))
        XCTAssertNil(Environment.allowedProcessEnvironment(processArguments(["codex"], environment: ["HOME=relative"])))
        XCTAssertNil(Environment.allowedProcessEnvironment(processArguments(["codex"], environment: ["HOME=/one", "HOME=/two"])))
        let truncated = processArguments(["codex"], environment: ["HOME=/one", "CODEX_HOME=/two"]).dropLast(2)
        XCTAssertNil(Environment.allowedProcessEnvironment(Data(truncated)))
    }

    func testEndpointRequiresPrivateParentAndRejectsSocketSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KA1-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw XCTSkip("Fixture UNIX socket unavailable") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.path.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw XCTSkip("Fixture socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        try Environment.validateEndpoint(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try Environment.validateEndpoint(path)) { XCTAssertEqual($0 as? Environment.Failure, .invalidEndpoint) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try Environment.validateEndpoint(link)) { XCTAssertEqual($0 as? Environment.Failure, .invalidEndpoint) }
    }

    func testHomeOwnershipAllowsOwnNewSubdirectoryAndRejectsOrdinaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try Environment.validateHomeOwnership(root.appendingPathComponent("new/profile"))
        let file = root.appendingPathComponent("file"); try Data().write(to: file)
        XCTAssertThrowsError(try Environment.validateHomeOwnership(file)) {
            XCTAssertEqual($0 as? Environment.Failure, .invalidEnvironment)
        }
    }

    private func processArguments(_ arguments: [String], environment: [String]) -> Data {
        var count = Int32(arguments.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: Array("/Applications/Official/codex".utf8) + [0, 0])
        for value in arguments + environment { data.append(contentsOf: Array(value.utf8) + [0]) }
        data.append(0)
        return data
    }
}
