import AppKit
import ApplicationServices
import XCTest
@testable import SuperIsland

final class WindowInteractionEligibilityTests: XCTestCase {
    func testAccessoryAppsAreNotClassifiedAsSystemWindows() {
        XCTAssertTrue(WindowInteractionEligibility.allowsApplication(.regular))
        XCTAssertTrue(WindowInteractionEligibility.allowsApplication(.accessory))
        XCTAssertFalse(WindowInteractionEligibility.allowsApplication(.prohibited))
    }

    func testOnlyNonmodalStandardWindowsPassRoleGate() {
        XCTAssertTrue(WindowInteractionEligibility.isStandardWindow(role: "AXWindow", subrole: "AXStandardWindow", modal: false))
        XCTAssertTrue(WindowInteractionEligibility.isStandardWindow(role: "AXWindow", subrole: "AXStandardWindow", modal: nil))
        for subrole in ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXUnknown", nil] {
            XCTAssertFalse(WindowInteractionEligibility.isStandardWindow(role: "AXWindow", subrole: subrole, modal: false))
        }
        XCTAssertFalse(WindowInteractionEligibility.isStandardWindow(role: "AXSheet", subrole: "AXStandardWindow", modal: false))
        XCTAssertFalse(WindowInteractionEligibility.isStandardWindow(role: "AXWindow", subrole: "AXStandardWindow", modal: true))
    }

    @MainActor
    func testOwnWindowRequiresExactManagedVisibleKeyWindow() {
        let settings = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        defer { settings.orderOut(nil); overlay.orderOut(nil) }
        XCTAssertFalse(WindowInteractionEligibility.isOwnSettingsWindow(settings, managed: settings, key: settings))
        settings.orderFront(nil)
        XCTAssertTrue(WindowInteractionEligibility.isOwnSettingsWindow(settings, managed: settings, key: settings))
        XCTAssertFalse(WindowInteractionEligibility.isOwnSettingsWindow(settings, managed: overlay, key: settings))
        XCTAssertFalse(WindowInteractionEligibility.isOwnSettingsWindow(settings, managed: settings, key: overlay))
        XCTAssertFalse(WindowInteractionEligibility.isOwnSettingsWindow(overlay, managed: settings, key: overlay))
        settings.level = .floating
        XCTAssertFalse(WindowInteractionEligibility.isOwnSettingsWindow(settings, managed: settings, key: settings))
    }

    func testCoordinateConversionAcrossNegativeAndVerticalDisplays() {
        for frame in [CGRect(x: -1920, y: 120, width: 900, height: 700), CGRect(x: 0, y: 1100, width: 800, height: 600), CGRect(x: 1512, y: -100, width: 900, height: 700)] {
            let ax = WindowSettingsGeometry.flipped(frame, desktopTop: 982)
            XCTAssertEqual(ax.minY, 982 - frame.maxY)
            XCTAssertEqual(WindowSettingsGeometry.flipped(ax, desktopTop: 982), frame)
        }
    }

    func testHalfScreenRespectsMinimumAndRightEdge() {
        let available = CGRect(x: 0, y: 38, width: 1512, height: 900)
        let result = WindowSettingsGeometry.constrained(CGRect(x: 760, y: 38, width: 752, height: 900), minimum: CGSize(width: 800, height: 588), available: available)
        XCTAssertEqual(result, CGRect(x: 712, y: 38, width: 800, height: 900))
    }

    func testSmallDisplayDoesNotViolateMinimumOrLoseTitlebar() {
        let available = CGRect(x: -640, y: -480, width: 640, height: 480)
        let result = WindowSettingsGeometry.constrained(CGRect(x: -400, y: -300, width: 960, height: 680), minimum: CGSize(width: 800, height: 588), available: available)
        XCTAssertEqual(result.origin, available.origin)
        XCTAssertEqual(result.size, CGSize(width: 800, height: 588))
    }
}
