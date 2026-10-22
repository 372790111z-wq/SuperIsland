import XCTest
@testable import SuperIsland

final class WindowFullScreenNativeStateTests: XCTestCase {
    private func display(_ name: String = "external", current: UInt64 = 642, type: Int = 0) -> [String: Any] {
        ["Display Identifier": name, "Current Space": ["ManagedSpaceID": current],
         "Spaces": [["ManagedSpaceID": UInt64(642), "type": type]]]
    }

    func testWindowOnSourceSpaceDoesNotMatchDestinationAfterAXMove() {
        let value = WindowFullScreenSpaceSnapshot.parse(displays: [display("internal")], windowSpaces: [642])
        XCTAssertNotNil(value)
        XCTAssertFalse(value!.matches(fullScreen: false, displayIdentifier: "external"))
        XCTAssertTrue(value!.matches(fullScreen: false, displayIdentifier: nil))
    }

    func testWindowOnInactiveSpaceWaitsDespiteCorrectDisplay() {
        let value = WindowFullScreenSpaceSnapshot.parse(displays: [display(current: 643)], windowSpaces: [642])
        XCTAssertFalse(value!.matches(fullScreen: false, displayIdentifier: "external"))
    }

    func testFullscreenRequiresNativeFullscreenSpace() {
        let windowed = WindowFullScreenSpaceSnapshot.parse(displays: [display()], windowSpaces: [642])!
        let fullscreen = WindowFullScreenSpaceSnapshot.parse(displays: [display(type: 4)], windowSpaces: [642])!
        XCTAssertFalse(windowed.matches(fullScreen: true, displayIdentifier: "external"))
        XCTAssertTrue(fullscreen.matches(fullScreen: true, displayIdentifier: "EXTERNAL"))
        XCTAssertFalse(fullscreen.matches(fullScreen: false, displayIdentifier: nil))
    }

    func testCompletedFullscreenDoesNotRequireUserToStayOnItsSpace() {
        let value = WindowFullScreenSpaceSnapshot.parse(displays: [display(current: 643, type: 4)], windowSpaces: [642])!
        XCTAssertTrue(value.matches(fullScreen: true, displayIdentifier: "external"))
    }

    func testMissingOrAmbiguousMembershipRemainsUnknown() {
        for spaces: Set<UInt64> in [[], [0], [641], [641, 642]] {
            XCTAssertNil(WindowFullScreenSpaceSnapshot.parse(displays: [display()], windowSpaces: spaces))
        }
        XCTAssertNil(WindowFullScreenSpaceSnapshot.parse(displays: [display(), display("internal")], windowSpaces: [642]))
        XCTAssertNil(WindowFullScreenSpaceSnapshot.parse(displays: [["Spaces": []]], windowSpaces: [642]))
    }

    func testSharedDesktopDoesNotPretendToBeAnUnknownPhysicalDisplay() {
        let shared = WindowFullScreenSpaceSnapshot.parse(displays: [display("Main")], windowSpaces: [642])!
        XCTAssertTrue(shared.matches(fullScreen: false, displayIdentifier: "external"))
        let ordinary = WindowFullScreenSpaceSnapshot.parse(displays: [display("unrecognized")], windowSpaces: [642])!
        XCTAssertFalse(ordinary.matches(fullScreen: false, displayIdentifier: "external"))
    }

    func testUnsupportedNativeSpaceTypeCannotAdmitEitherState() {
        let unknown = WindowFullScreenSpaceSnapshot.parse(displays: [display(type: 99)], windowSpaces: [642])!
        XCTAssertFalse(unknown.matches(fullScreen: false, displayIdentifier: nil))
        XCTAssertFalse(unknown.matches(fullScreen: true, displayIdentifier: nil))
    }
}
