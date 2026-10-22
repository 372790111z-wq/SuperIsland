import XCTest
import ServiceManagement
@testable import SuperIsland

final class KeepAwakeLidAuthorizationTests: XCTestCase {
    @MainActor
    func testNotFoundExplicitAuthorizationActuallyRegisters() async {
        var status: SMAppService.Status = .notFound
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1; status = .enabled },
            openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied, "Registration cannot claim an applied power lease")
    }

    @MainActor
    func testNotRegisteredRegistersThenRequiresUserApproval() async {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1; status = .requiresApproval },
            openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertTrue(client.requiresApproval)
        XCTAssertFalse(client.enabled)
    }

    @MainActor
    func testRegisterErrorKeepsDisabledAndPreservesOnlyDomainAndCode() async {
        var status: SMAppService.Status = .enabled
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            registerService: {
                registrations += 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "PRIVATE-TOKEN-FROM-DESCRIPTION",
                    NSFilePathErrorKey: "/Users/private-test/secret-file"
                ])
            }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertTrue(client.enabled)
        status = .notFound
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
        XCTAssertTrue(client.message.contains("SMAppServiceErrorDomain"))
        XCTAssertTrue(client.message.contains("3"))
        XCTAssertFalse(client.message.contains("PRIVATE-TOKEN"))
        XCTAssertFalse(client.message.contains("private-test"))
    }

    @MainActor
    func testRequiresApprovalOpensSettingsWithoutRegisteringOrEnabling() async {
        var status: SMAppService.Status = .enabled
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { status }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertTrue(client.enabled)
        status = .requiresApproval
        client.authorize()
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertFalse(client.enabled)
        XCTAssertFalse(client.applied)
    }

    @MainActor
    func testEnabledServiceIsNotRegisteredAgain() async {
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { .enabled }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        client.authorize()
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertTrue(client.enabled)
        XCTAssertFalse(client.applied)
    }

    @MainActor
    func testUnresolvedStatusAfterRegisterDoesNotPretendEnabled() async {
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { .notFound }, signingRequirement: { _ in "test-only" },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(client.enabled)
        XCTAssertTrue(client.message.contains("状态 3"))
    }

    @MainActor
    func testUnsignedPackageCannotRequestRegistrationOrSettings() async {
        var registrations = 0
        var settingsOpened = 0
        let client = KeepAwakeLidClient(serviceStatus: { .notFound }, signingRequirement: { _ in nil },
            registerService: { registrations += 1 }, openSystemSettings: { settingsOpened += 1 })
        client.authorize()
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(client.enabled)
    }
}
