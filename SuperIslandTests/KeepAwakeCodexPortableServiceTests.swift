import XCTest
@testable import SuperIsland

final class KeepAwakeCodexPortableServiceTests: XCTestCase {
    private func profile(_ root: URL, name: String) -> KeepAwakeCodexEnvironment.Profile {
        .init(executableURL: root.appendingPathComponent(name + "/Renamed App.app/codex"),
              codexHome: root.appendingPathComponent(name + "/Codex Data"),
              socketURL: root.appendingPathComponent(name + "/Codex Data/control.sock"))
    }
    @MainActor private func source(_ id: String = "codex-desktop") -> KeepAwakeSource {
        KeepAwakeSource.all.first { $0.id == id }!
    }
    @MainActor private func fixture() throws -> (String, UserDefaults, URL) {
        let name = "KA1Portable-" + UUID().uuidString
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)), FileManager.default.temporaryDirectory.appendingPathComponent(name))
    }
    @MainActor func testDesktopHooksDoNotRequireAnExposedSocketAndCleanupStaysAtBoundHome() throws {
        let (name, defaults, root) = try fixture()
        let original = profile(root, name: "User A"), changed = profile(root, name: "User B")
        var discovered = original
        var installed: [String] = [], cleaned: [KeepAwakeCodexEnvironment.Profile] = []
        let service = KeepAwakeService(defaults: defaults, root: root, codexSampler: {
            XCTFail("A hooks connection must never start a second RPC monitor")
            return .init(threads: [])
        }, codexAvailability: { false }, codexResolver: { discovered }, codexHookInstaller: { source, credential, selected in
            XCTAssertEqual(selected, original)
            XCTAssertTrue(credential.path.hasPrefix(root.path))
            installed.append(source.id)
        }, codexHookUninstaller: { _, _, selected in cleaned.append(selected) })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.start()
        try service.connect(source())
        try service.connect(source("codex-cli"))
        XCTAssertEqual(installed, ["codex-desktop", "codex-cli"])
        XCTAssertEqual(service.connections, ["codex-desktop", "codex-cli"])
        discovered = changed
        try service.disconnect(source())
        XCTAssertEqual(cleaned, [original])
        XCTAssertTrue(service.connections.contains("codex-cli"))
        try service.disconnect(source("codex-cli"))
        XCTAssertEqual(cleaned, [original, original])
        XCTAssertFalse(service.actualHold)
        XCTAssertFalse(service.engine.enabled)
    }
    @MainActor func testReadOnlyConsentCannotFallBackToConfigurationWrites() throws {
        let (name, defaults, root) = try fixture(); let selected = profile(root, name: "One")
        var endpointPresent = true, writes = 0
        let service = KeepAwakeService(defaults: defaults, root: root, codexAvailability: { endpointPresent },
            codexResolver: { selected }, codexHookInstaller: { _, _, _ in writes += 1 })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.start()
        let proposed = KeepAwakeCodexConnection(profile: selected, mode: .rpc)
        XCTAssertEqual(proposed.mode, .rpc)
        endpointPresent = false
        XCTAssertThrowsError(try service.connect(source(), codexConnection: proposed))
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(service.connections.isEmpty)
        XCTAssertTrue(service.engine.sessions.isEmpty)
    }
    @MainActor func testHookConsentRetainsItsHomeAndModeIfDiscoveryChanges() throws {
        let (name, defaults, root) = try fixture(); let first = profile(root, name: "First"), second = profile(root, name: "Second")
        var discovered = first, endpointPresent = false
        var written: KeepAwakeCodexEnvironment.Profile?
        let service = KeepAwakeService(defaults: defaults, root: root, codexAvailability: { endpointPresent },
            codexResolver: { discovered }, codexHookInstaller: { _, _, selected in written = selected })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.start()
        let proposed = try XCTUnwrap(service.prepareCodexConnection(source()))
        discovered = second; endpointPresent = true
        try service.connect(source(), codexConnection: proposed)
        XCTAssertEqual(written, first)
        XCTAssertEqual(KeepAwakeCodexConnection.load(defaults.data(forKey: KeepAwakeCodexConnection.defaultsKey))["codex-desktop"]?.mode, .hooks)
        XCTAssertFalse(service.actualHold)
    }
    @MainActor func testOrphanedInstallIntentBecomesCleanupAtOriginalHome() throws {
        let (name, defaults, root) = try fixture(); let original = profile(root, name: "Before Crash")
        defaults.set(try JSONEncoder().encode(["codex-desktop": KeepAwakeCodexConnection(profile: original, mode: .hooks)]),
                     forKey: KeepAwakeCodexConnection.defaultsKey)
        var cleaned: KeepAwakeCodexEnvironment.Profile?
        let service = KeepAwakeService(defaults: defaults, root: root, codexAvailability: { false },
            codexResolver: { self.profile(root, name: "After Crash") }, codexHookUninstaller: { _, _, value in cleaned = value })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.start()
        XCTAssertTrue(service.cleanupPendingSources.contains("codex-desktop"))
        XCTAssertFalse(service.connections.contains("codex-desktop"))
        XCTAssertThrowsError(try service.connect(source()))
        try service.disconnect(source())
        XCTAssertEqual(cleaned, original)
        XCTAssertTrue(service.cleanupPendingSources.isEmpty)
        XCTAssertTrue(KeepAwakeCodexConnection.load(defaults.data(forKey: KeepAwakeCodexConnection.defaultsKey)).isEmpty)
    }
    @MainActor func testRestartRestoresOnlyCredentialsWithoutRewritingCodexConfiguration() throws {
        let (name, defaults, root) = try fixture(); let selected = profile(root, name: "Saved")
        defaults.set(try JSONEncoder().encode(["codex-desktop": KeepAwakeCodexConnection(profile: selected, mode: .hooks)]),
                     forKey: KeepAwakeCodexConnection.defaultsKey)
        defaults.set(["codex-desktop"], forKey: "keepAwake.sources.v1")
        let service = KeepAwakeService(defaults: defaults, root: root, codexAvailability: { true }, codexResolver: {
            XCTFail("Restart cannot select a different home"); return selected
        }, codexHookInstaller: { _, _, _ in XCTFail("Restart cannot silently change external config") })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.start()
        XCTAssertTrue(service.connections.contains("codex-desktop"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("credentials/codex-desktop.json").path))
        XCTAssertTrue(service.cleanupPendingSources.isEmpty)
        XCTAssertFalse(service.actualHold)
    }
    func testBindingLoaderRejectsNonFileProfilesAndInvalidModesForCLI() throws {
        let bad = KeepAwakeCodexEnvironment.Profile(executableURL: URL(string: "https://example.com/codex")!,
            codexHome: URL(fileURLWithPath: "/Users/fixture/.codex"), socketURL: URL(fileURLWithPath: "/Users/fixture/control.sock"))
        XCTAssertTrue(KeepAwakeCodexConnection.load(try JSONEncoder().encode(["codex-desktop": KeepAwakeCodexConnection(profile: bad, mode: .hooks)])).isEmpty)
        let valid = profile(URL(fileURLWithPath: "/Users/fixture"), name: "local")
        XCTAssertTrue(KeepAwakeCodexConnection.load(try JSONEncoder().encode(["codex-cli": KeepAwakeCodexConnection(profile: valid, mode: .rpc)])).isEmpty)
    }
    @MainActor func testExistingSocketDoesNotCreateDuplicateRPCCoverageForCLIAndDesktop() throws {
        let (name, defaults, root) = try fixture(); let selected = profile(root, name: "Shared")
        var writes = 0
        let service = KeepAwakeService(defaults: defaults, root: root, codexSampler: {
            XCTFail("Socket presence must not silently add an overlapping monitor")
            return .init(threads: [])
        }, codexAvailability: { true }, codexResolver: { selected }, codexHookInstaller: { _, _, _ in writes += 1 },
            codexHookUninstaller: { _, _, _ in })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        service.start()
        XCTAssertEqual(try service.prepareCodexConnection(source())?.mode, .hooks)
        try service.connect(source("codex-cli"))
        try FileManager.default.createDirectory(at: selected.codexHome, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("same-home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected.codexHome)
        for home in [selected.codexHome, URL(fileURLWithPath: selected.codexHome.path + "/", isDirectory: true), alias] {
            let sameHome = KeepAwakeCodexEnvironment.Profile(executableURL: selected.executableURL,
                codexHome: home, socketURL: selected.socketURL)
            let rpc = KeepAwakeCodexConnection(profile: sameHome, mode: .rpc)
            XCTAssertThrowsError(try service.connect(source(), codexConnection: rpc))
        }
        try service.connect(source())
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(service.connections, ["codex-cli", "codex-desktop"])
        XCTAssertFalse(service.actualHold)
    }
}
