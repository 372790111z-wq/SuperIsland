import XCTest
import ServiceManagement
@testable import SuperIsland

@MainActor
final class BatteryServiceIdentityTests: XCTestCase {
    func testUnifiedHostUsesSeparateEndpointWithoutMovingRecoveryOrSigningIdentity() {
        let legacy = "com.workview.SuperIsland.BatteryManagementHelper"
        let unified = "com.workview.SuperIsland.WE1Debug.BatteryControl"
        XCTAssertEqual(BatteryManagementIdentity.serviceLabel(bundleIdentifier: "com.workview.SuperIsland.WE1Debug", executableURL: nil), unified)
        for host: String? in [nil, "com.workview.SuperIsland", "com.workview.SuperIsland.BM1Debug", "com.workview.SuperIsland.WE1Debug.other"] {
            XCTAssertEqual(BatteryManagementIdentity.serviceLabel(bundleIdentifier: host, executableURL: nil), legacy)
        }
        XCTAssertEqual(BatteryManagementIdentity.storageIdentifier, legacy,
            "Both daemons must use the SAME recovery journals, retry latch and exclusive control.lock")
        XCTAssertEqual(BatteryManagementIdentity.signingIdentifier, legacy,
            "Changing launchd endpoints must not change kernel-bound worker signing identity")
    }
    func testHelperEndpointComesFromEnclosingSealedApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = contents.appendingPathComponent("MacOS/BatteryManagementHelper")
        for host in ["com.workview.SuperIsland.WE1Debug", "com.workview.SuperIsland.BM1Debug"] {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": host], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            XCTAssertEqual(BatteryManagementIdentity.serviceLabel(bundleIdentifier: "unrelated.executable", executableURL: executable),
                BatteryManagementIdentity.serviceLabel(bundleIdentifier: host, executableURL: nil))
        }
    }
    func testLaunchDeclarationsSeparateEndpointsAndKeepOneExecutable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for label in [BatteryManagementIdentity.legacyLabel, BatteryManagementIdentity.unifiedLabel] {
            let data = try Data(contentsOf: root.appendingPathComponent("BatteryManagementHelper/\(label).plist"))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["Label"] as? String, label)
            XCTAssertEqual(Set((plist["MachServices"] as? [String: Bool] ?? [:]).keys), [label])
            XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/BatteryManagementHelper")
            if label == BatteryManagementIdentity.unifiedLabel {
                XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["com.workview.SuperIsland.WE1Debug"])
            }
        }
    }
    func testLegacyRetirementMustCompleteBeforeNewRegistrationAndNeverResetsApprovedNewRecord() async throws {
        let domain = "BatteryServiceMigration.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let registrar = Registrar(), client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new")
        registrar.failRetirement = true
        do { try await client.register(); XCTFail("Old retirement failure must block new registration") } catch {}
        XCTAssertEqual(registrar.events, ["retire"])
        XCTAssertNil(defaults.string(forKey: "batteryManagement.helperRegistrationBuild"))
        registrar.failRetirement = false; registrar.events = []
        try await client.register()
        XCTAssertEqual(registrar.events, ["retire", "register"])
        registrar.status = .requiresApproval; registrar.events = []
        try await client.register()
        XCTAssertEqual(registrar.events, ["retire", "register"], "Approval retry must not unregister the NEW endpoint")
    }
    func testNewEndpointIgnoresLegacyReceiptsButPreservesItsOwnUpgradeAndApprovalState() async throws {
        let domain = "BatteryEndpointReceipt.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacyKey = "batteryManagement.helperRegistrationBuild"
        let newKey = legacyKey + "." + BatteryManagementIdentity.unifiedLabel
        defaults.set("old-host-build", forKey: legacyKey)
        defaults.set("new", forKey: "batteryManagement.helperLaunchRepairAttemptBuild")
        let registrar = Registrar()
        let client = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "new",
            registrationServiceLabel: BatteryManagementIdentity.unifiedLabel)
        try await client.register()
        XCTAssertEqual(registrar.events, ["retire", "register"], "An absent endpoint must not be unregistered because of another endpoint's receipt")
        XCTAssertEqual(defaults.string(forKey: legacyKey), "old-host-build")
        XCTAssertEqual(defaults.string(forKey: newKey), "new")
        registrar.events = []; registrar.status = .requiresApproval
        try await client.register()
        XCTAssertEqual(registrar.events, ["retire", "register"])
        registrar.events = []; registrar.status = .notRegistered
        let upgraded = BatteryManagementClient(registrar: registrar, defaults: defaults, buildIdentifier: "newer",
            registrationServiceLabel: BatteryManagementIdentity.unifiedLabel)
        try await upgraded.register()
        XCTAssertEqual(registrar.events, ["retire", "unregister", "register"], "A real receipt for this endpoint must retain stale-build recovery")
        XCTAssertEqual(defaults.string(forKey: newKey), "newer")
    }
    private final class Registrar: BatteryHelperRegistering {
        var status = SMAppService.Status.notRegistered
        var events = [String](), failRetirement = false
        func retireLegacyServiceIfNeeded() async throws {
            events.append("retire")
            if failRetirement { throw NSError(domain: "test", code: 1) }
        }
        func register() throws { events.append("register"); status = .enabled }
        func unregister() async throws { events.append("unregister"); status = .notRegistered }
    }
}
