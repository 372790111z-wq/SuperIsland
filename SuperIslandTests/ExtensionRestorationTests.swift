import XCTest
@testable import SuperIsland

final class ExtensionRestorationTests: XCTestCase {
    func testWE1FirstRestorationDisablesEveryExtensionEvenWithOldSeenState() {
        withDefaults { defaults in
            defaults.set(["pomodoro", "ai-usage"], forKey: ExtensionActivationPolicy.seenKey)
            defaults.set(true, forKey: "extensions.superisland.agents-status.settings.hooksCodex")
            ExtensionActivationPolicy.register(installedIDs: ["pomodoro", "ai-usage", "agents"], defaultDisabledIDs: [], defaults: defaults, isWE1: true)
            XCTAssertEqual(Set(defaults.stringArray(forKey: ExtensionActivationPolicy.disabledKey) ?? []), ["pomodoro", "ai-usage", "agents"])
            XCTAssertFalse(defaults.bool(forKey: "extensions.superisland.agents-status.settings.hooksCodex"))
            XCTAssertFalse(defaults.bool(forKey: "extensions.superisland.agents-status.settings.hooksClaudeCode"))
        }
    }

    func testOptInAndHookChoicesSurviveRediscoveryWhileNewExtensionsStayOff() {
        withDefaults { defaults in
            ExtensionActivationPolicy.register(installedIDs: ["pomodoro", "agents"], defaultDisabledIDs: [], defaults: defaults, isWE1: true)
            defaults.set(["agents"], forKey: ExtensionActivationPolicy.disabledKey)
            defaults.set(true, forKey: "extensions.superisland.agents-status.settings.hooksClaudeCode")
            ExtensionActivationPolicy.register(installedIDs: ["pomodoro", "agents", "new-extension"], defaultDisabledIDs: [], defaults: defaults, isWE1: true)
            XCTAssertEqual(Set(defaults.stringArray(forKey: ExtensionActivationPolicy.disabledKey) ?? []), ["agents", "new-extension"])
            XCTAssertTrue(defaults.bool(forKey: "extensions.superisland.agents-status.settings.hooksClaudeCode"))
        }
    }

    func testProductionDefaultsRemainManifestControlled() {
        withDefaults { defaults in
            ExtensionActivationPolicy.register(installedIDs: ["default-on", "default-off"], defaultDisabledIDs: ["default-off"], defaults: defaults, isWE1: false)
            XCTAssertEqual(defaults.stringArray(forKey: ExtensionActivationPolicy.disabledKey), ["default-off"])
            XCTAssertNil(defaults.object(forKey: ExtensionActivationPolicy.we1OptInKey))
        }
    }

    func testWE1DiscoversOnlyItsInstalledAndBundledCopies() {
        let installed = URL(fileURLWithPath: "/sandbox/WE1/Extensions")
        let bundled = URL(fileURLWithPath: "/sandbox/WE1.app/BundledExtensions")
        let paths = ExtensionHostEnvironment.discoveryDirectories(
            isWE1: true, installed: installed,
            development: URL(fileURLWithPath: "/repo/ExtensionsDev"),
            local: URL(fileURLWithPath: "/unrelated-cwd/Extensions"),
            repository: URL(fileURLWithPath: "/stale-worktree/Extensions"), bundled: bundled
        )
        XCTAssertEqual(paths, [installed, bundled])
        XCTAssertNotEqual(
            ExtensionHostEnvironment.applicationSupportDirectoryName(bundleIdentifier: ExtensionHostEnvironment.we1BundleIdentifier),
            ExtensionHostEnvironment.applicationSupportDirectoryName(bundleIdentifier: "com.workview.SuperIsland")
        )
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "WE1ExtensionRestorationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}

@MainActor
final class ExtensionRuntimeShutdownTests: XCTestCase {
    func testQueuedWhatsAppCommandsCannotRunAfterDisableOrAcrossReactivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "SuperIsland.registerModule({});".write(to: directory.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let manifestJSON = """
        {"id":"test.whatsapp-lifecycle","name":"Test","version":"1.0.0","main":"index.js","permissions":["network"]}
        """
        try manifestJSON.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        var commands: [ExtensionJSRuntime.WhatsAppCommand] = []
        let runtime = try ExtensionJSRuntime(
            manifest: ExtensionManifest.load(from: directory), manager: nil,
            whatsAppCommand: { commands.append($0); return ["ok": true] }
        )
        let invokeCommands = """
        SuperIsland.system.startWhatsAppWeb();
        SuperIsland.system.refreshWhatsAppWebQR();
        SuperIsland.system.sendWhatsAppWebMessageAsync('fixture-recipient', 'fixture-body');
        """
        runtime.activate()
        runtime.context.evaluateScript(invokeCommands)
        runtime.deactivate()
        runtime.activate()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(commands.isEmpty, "A new activation must not execute commands queued by the previous instance")

        runtime.context.evaluateScript(invokeCommands)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(commands, [.start, .refreshQRCode, .sendMessage(recipient: "fixture-recipient", body: "fixture-body")])

        runtime.deactivate()
        runtime.context.evaluateScript(invokeCommands)
        let response = runtime.context.evaluateScript("SuperIsland.system.sendWhatsAppWebMessage('fixture-recipient', 'fixture-body')")
        XCTAssertEqual(response?.forProperty("error")?.toString(), "extension_inactive")
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(commands.count, 3)
    }

    func testPendingHTTPCallbackCannotRestartAnInactiveRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        var received = false;
        SuperIsland.registerModule({});
        """
        try script.write(to: directory.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let manifestJSON = """
        {"id":"test.runtime-shutdown","name":"Test","version":"1.0.0","minAppVersion":"1.0.0","main":"index.js","description":"Test","permissions":[]}
        """
        try manifestJSON.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let manifest = try ExtensionManifest.load(from: directory)
        let runtime = try ExtensionJSRuntime(manifest: manifest, manager: nil)
        runtime.activate()
        // No network permission: the real asynchronous host path returns an
        // immediate local error. Its pending callback previously survived stop.
        runtime.context.evaluateScript("SuperIsland.__fetchAsync('https://unused.invalid', {}, function() { received = true; setInterval(function(){}, 10); });")
        runtime.deactivate()
        runtime.activate()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(runtime.context.objectForKeyedSubscript("received").toBool())
        runtime.deactivate()
    }
}
