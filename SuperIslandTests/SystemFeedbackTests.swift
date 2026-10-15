import XCTest
import SwiftUI
import AppKit
@testable import SuperIsland

@MainActor
final class SystemFeedbackTests: XCTestCase {
    func testNonNotchedFeedbackUsesFullCapsuleAndKeepsItsSize() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.updatePresentationContext(screen: nil)
        let original = state.contentSize(for: .compact)
        state.showVolumeHUD()
        XCTAssertFalse(state.usesNotchSafeSystemFeedback)
        XCTAssertEqual(state.contentSize(for: .compact), original)
        XCTAssertEqual(original, Constants.nonNotchCompactSize)
        state.hideCompactSystemFeedback(if: .volume)
        state.showBrightnessHUD()
        XCTAssertFalse(state.usesNotchSafeSystemFeedback)
        XCTAssertEqual(state.contentSize(for: .compact), original)
        state.hideCompactSystemFeedback(if: .brightness)
    }

    func testControlCenterOnlyRecognizesSystemVolumeAndDisplayBrightness() {
        XCTAssertEqual(ControlCenterAdjustmentIdentity.kind(for: "controlcenter-volume-slider"), .volume)
        XCTAssertEqual(ControlCenterAdjustmentIdentity.kind(for: "controlcenter-display-brightness-slider"), .brightness)
        XCTAssertNil(ControlCenterAdjustmentIdentity.kind(for: "controlcenter-keyboard-brightness-slider"))
        XCTAssertNil(ControlCenterAdjustmentIdentity.kind(for: "controlcenter-display"))
        XCTAssertNil(ControlCenterAdjustmentIdentity.kind(for: "unrelated-slider"))
    }

    func testNotchedFeedbackFitsOutsideCameraAndRestoresOriginalSize() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }))
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.updatePresentationContext(screen: screen)
        let original = state.contentSize(for: .compact)
        state.showVolumeHUD()
        XCTAssertTrue(state.usesNotchSafeSystemFeedback)
        XCTAssertGreaterThan(state.contentSize(for: .compact).width, original.width)
        XCTAssertGreaterThanOrEqual(state.systemFeedbackCenterGapWidth, try XCTUnwrap(state.presentationNotchRect).width)
        XCTAssertEqual(state.currentState, .compact)
        state.hideCompactSystemFeedback(if: .volume)
        XCTAssertEqual(state.contentSize(for: .compact), original)
    }

    func testEarlyBrightnessObservationRejectsVolumeKeyboardBacklightAndKeyUp() {
        for key in [2, 3] {
            XCTAssertEqual(MediaKeyInterceptor.brightnessKeyDown(subtype: 8, data1: (key << 16) | 0x0A00), key)
            XCTAssertNil(MediaKeyInterceptor.brightnessKeyDown(subtype: 8, data1: (key << 16) | 0x0B00))
        }
        for key in [0, 1, 7, 21, 22] {
            XCTAssertNil(MediaKeyInterceptor.brightnessKeyDown(subtype: 8, data1: (key << 16) | 0x0A00))
        }
        XCTAssertNil(MediaKeyInterceptor.brightnessKeyDown(subtype: 7, data1: (2 << 16) | 0x0A00))
    }

    func testMediaKeyDecodeRejectsKeyUpAndUnrelatedSystemEvents() {
        for key in [0, 1, 2, 3, 7] {
            XCTAssertEqual(MediaKeyInterceptor.mediaKeyDown(subtype: 8, data1: (key << 16) | 0x0A00), key)
            XCTAssertNil(MediaKeyInterceptor.mediaKeyDown(subtype: 8, data1: (key << 16) | 0x0B00))
        }
        XCTAssertNil(MediaKeyInterceptor.mediaKeyDown(subtype: 7, data1: 0x0A00))
        XCTAssertNil(MediaKeyInterceptor.mediaKeyDown(subtype: 8, data1: (16 << 16) | 0x0A00))
    }

    func testCompactVolumePreservesModuleAndDoesNotExpand() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.activeModule = .builtIn(.weather)
        state.showVolumeHUD()
        XCTAssertEqual(state.compactSystemFeedback, .volume)
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(state.activeModule, .builtIn(.weather))
        state.hideCompactSystemFeedback(if: .volume)
    }

    func testLatestFeedbackCannotBeDismissedByOlderTimer() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.showBrightnessHUD(duration: 0.03)
        try await Task.sleep(nanoseconds: 10_000_000)
        state.showVolumeHUD()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(state.compactSystemFeedback, .volume)
        state.hideCompactSystemFeedback(if: .volume)
    }

    func testQueuedNotificationPresentsAfterFeedbackAndRestoresOriginalModule() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.activeModule = .builtIn(.weather)
        state.showBrightnessHUD(duration: 0.03)
        state.presentIncomingNotification("test", isAvailable: { true })
        XCTAssertEqual(state.currentState, .compact)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertNil(state.compactSystemFeedback)
        XCTAssertEqual(state.currentState, .expanded)
        XCTAssertEqual(state.activeModule, .builtIn(.notifications))
        state.dismiss()
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(state.activeModule, .builtIn(.weather))
    }

    func testRemovedOrDisabledPendingNotificationCannotReplay() async throws {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.activeModule = .builtIn(.weather)
        var available = true
        state.showBrightnessHUD(duration: 0.02)
        state.presentIncomingNotification("test", isAvailable: { available })
        available = false
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(state.activeModule, .builtIn(.weather))
        state.showBrightnessHUD(duration: 0.02)
        state.presentIncomingNotification("removed", isAvailable: { true })
        state.cancelPendingNotificationPresentation("removed")
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(state.currentState, .compact)
    }

    func testManualExpandedPresentationIsNotInterrupted() {
        let state = AppState(synchronizesRuntimeEnergyState: false)
        state.activeModule = .builtIn(.weather)
        state.expand()
        state.showBrightnessHUD()
        state.showVolumeHUD()
        state.presentIncomingNotification("test", isAvailable: { true })
        XCTAssertEqual(state.currentState, .expanded)
        XCTAssertEqual(state.activeModule, .builtIn(.weather))
        XCTAssertNil(state.compactSystemFeedback)
        state.cancelAutoDismiss()
    }

    func testBrightnessRejectsInvalidDeviceReadings() {
        XCTAssertFalse(BuiltInScreenBrightnessReader.isValid(.nan))
        XCTAssertFalse(BuiltInScreenBrightnessReader.isValid(.infinity))
        XCTAssertFalse(BuiltInScreenBrightnessReader.isValid(-0.1))
        XCTAssertFalse(BuiltInScreenBrightnessReader.isValid(1.1))
        XCTAssertTrue(BuiltInScreenBrightnessReader.isValid(0))
        XCTAssertTrue(BuiltInScreenBrightnessReader.isValid(1))
    }
}

final class MacNotificationBannerTests: XCTestCase {
    let app = NotificationApplicationIdentity(name: "Test App", bundleIdentifier: "example.test")

    func testUnknownSystemCardFallsBackWithoutInventingAppIdentity() {
        let banner = MacNotificationBannerParser.parse(["Test title", "Visible body"], applications: [app], allowUnknownSource: true)
        XCTAssertEqual(banner?.application.name, "Mac 通知")
        XCTAssertEqual(banner?.application.bundleIdentifier, "")
        XCTAssertEqual(banner?.title, "Test title")
        XCTAssertEqual(banner?.body, "Visible body")
        XCTAssertNil(MacNotificationBannerParser.parse(["Test title", "Visible body"], applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.parse(["Test title", "Body", "3分钟前"], applications: [app], allowUnknownSource: true))
        XCTAssertNil(MacNotificationBannerParser.parse(["Title A", "Body A", "Title B", "Body B"], applications: [app], allowUnknownSource: true))
        let hidden = MacNotificationBannerParser.parse(["Title", "内容已隐藏"], applications: [app], allowUnknownSource: true)
        XCTAssertEqual(hidden?.title, "新通知")
        XCTAssertEqual(hidden?.body, "")
    }

    func testSourceMetadataRequiresExactUnambiguousLabel() {
        XCTAssertEqual(MacNotificationBannerParser.applicationSource("TEST APP", applications: [app]), app)
        XCTAssertNil(MacNotificationBannerParser.applicationSource("TEST APP, Sender, Message", applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.applicationSource("Test App\nSender", applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.applicationSource("Sender mentions Test App", applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.applicationSource("Test App", applications: [app, .init(name: "TEST APP", bundleIdentifier: "other")]))
    }

    func testAppNameInTitleNeverPromotesPrivateBodyOrInventsSource() {
        let banner = MacNotificationBannerParser.parse(["Test App", "Private body"], applications: [app], allowUnknownSource: true)
        XCTAssertEqual(banner?.application.name, "Mac 通知")
        XCTAssertEqual(banner?.application.bundleIdentifier, "")
        XCTAssertEqual(banner?.title, "Test App")
        XCTAssertEqual(banner?.body, "Private body")
        XCTAssertNil(MacNotificationBannerParser.parse(["Test App", "Private body"], applications: [app]))
        let known = MacNotificationBannerParser.parse(["Test App", "Private body"], sourceLabel: "Test App", applications: [app])
        XCTAssertEqual(known?.title, "Test App")
        XCTAssertEqual(known?.body, "Private body")
    }

    func testBannerCardGeometryRejectsFullScreenHistoryAndOffscreenCards() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertFalse(MacNotificationBannerGeometry.isCard(display))
        XCTAssertTrue(MacNotificationBannerGeometry.isTopRightCard(CGRect(x: 1100, y: 40, width: 380, height: 100), display: display))
        XCTAssertFalse(MacNotificationBannerGeometry.isTopRightCard(CGRect(x: 1100, y: 500, width: 380, height: 100), display: display))
        XCTAssertTrue(MacNotificationBannerGeometry.isHistoryViewport(role: kAXScrollAreaRole, frame: CGRect(x: 1100, y: 0, width: 380, height: 982)))
        XCTAssertTrue(MacNotificationBannerGeometry.isHistoryViewport(role: kAXScrollAreaRole, frame: display, title: "通知中心"))
    }

    func testVisibleBannerParsesSourceAndOnlyExposedText() {
        let banner = MacNotificationBannerParser.parse(["Sender", "Test message", "现在", "关闭"], sourceLabel: "Test App", applications: [app])
        XCTAssertEqual(banner?.application, app)
        XCTAssertEqual(banner?.title, "Sender")
        XCTAssertEqual(banner?.body, "Test message")
        let hidden = MacNotificationBannerParser.parse(["新通知", "现在"], sourceLabel: "Test App", applications: [app])
        XCTAssertEqual(hidden?.body, "")
        let redacted = MacNotificationBannerParser.parse(["Sender", "内容已隐藏", "Do not expose this stale value"], sourceLabel: "Test App", applications: [app])
        XCTAssertEqual(redacted?.title, "新通知")
        XCTAssertEqual(redacted?.body, "")
    }

    func testUppercaseSourceLabelWorksButAmbiguousLabelsAreRejected() {
        XCTAssertEqual(MacNotificationBannerParser.parse(["Sender", "Test message"], sourceLabel: "TEST APP", applications: [app])?.application, app)
        let other = NotificationApplicationIdentity(name: "TEST APP", bundleIdentifier: "example.other")
        XCTAssertNil(MacNotificationBannerParser.parse(["Sender"], sourceLabel: "TEST APP", applications: [app, other]))
        XCTAssertNil(MacNotificationBannerParser.parse(["Container summary", "TEST APP", "Sender"], applications: [app]))
    }

    func testUnknownSourceAndHistoricalNotificationsAreRejected() {
        XCTAssertNil(MacNotificationBannerParser.parse(["Unknown App", "Sender", "Body"], applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.parse(["Sender", "Body", "3分钟前"], sourceLabel: "Test App", applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.parse(["Sender", "Body", "3 min ago"], sourceLabel: "Test App", applications: [app]))
        XCTAssertNil(MacNotificationBannerParser.parse(["Unknown App", "Sender", "Test App"], applications: [app]), "An app name mentioned in a message is not its source")
        XCTAssertNil(MacNotificationBannerParser.parse(["Sender", "Body", "Other App", "Other message"], sourceLabel: "Test App",
            applications: [app, .init(name: "Other App", bundleIdentifier: "example.other")]), "Do not flatten multiple source cards into one notification")
    }

    func testRepeatedReadsDoNotCreateEventsButSeparateCardsRemainSeparate() {
        var tracker = MacNotificationVisibilityTracker()
        XCTAssertTrue(tracker.update(keys: ["old"]).isEmpty, "Do not import already visible cards on enable")
        let first = tracker.update(keys: ["old", "card-a"])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(tracker.update(keys: ["old", "card-a"]).isEmpty)
        let second = tracker.update(keys: ["old", "card-a", "card-b"])
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first["card-a"], second["card-b"])
        _ = tracker.update(keys: [])
        XCTAssertTrue(tracker.update(keys: ["card-a"]).isEmpty, "The same system card uncovered again is not a new event")
        let separate = tracker.update(keys: ["card-a", "new-system-card-with-identical-text"])
        XCTAssertEqual(separate.count, 1)
        XCTAssertNotEqual(first["card-a"], separate["new-system-card-with-identical-text"])
    }

    func testRecoveringBaselineIgnoresCardsLoadedAfterAnEmptyAXRead() {
        var tracker = MacNotificationVisibilityTracker()
        _ = tracker.update(keys: [])
        _ = tracker.update(keys: ["previous-card"])
        tracker.reset()
        XCTAssertTrue(tracker.update(keys: [], establishingBaseline: true).isEmpty)
        XCTAssertTrue(tracker.update(keys: ["restored-persistent-card"], establishingBaseline: true).isEmpty)
        XCTAssertTrue(tracker.update(keys: ["restored-persistent-card"]).isEmpty)
        let fresh = tracker.update(keys: ["restored-persistent-card", "new-card"])
        XCTAssertEqual(Set(fresh.keys), ["new-card"])
    }

    func testPermissionOrLockResetDoesNotImportExistingHistory() {
        var tracker = MacNotificationVisibilityTracker()
        _ = tracker.update(keys: [])
        XCTAssertEqual(tracker.update(keys: ["a"]).count, 1)
        tracker.reset()
        XCTAssertTrue(tracker.update(keys: ["a", "b"]).isEmpty)
        XCTAssertEqual(tracker.update(keys: ["a", "b", "c"]).count, 1)
    }
}

@MainActor
final class MacNotificationPrivacyTests: XCTestCase {
    private func notification(_ id: String) -> IslandNotification {
        IslandNotification(sourceID: id, appName: "Test App", bundleIdentifier: "example.test", appIcon: "app.badge",
                           appIconURL: nil, title: "Sender", body: "Private test body", senderName: "Sender",
                           previewText: "Private test body", avatarURL: nil, timestamp: Date(), tapAction: nil)
    }

    func testMacPreviewNeedsBothGlobalAndSourceConsentWithoutChangingOldSources() {
        let mac = notification("macOS:a")
        XCTAssertNotEqual(NotificationPreviewPolicy.display(mac, globalPreviews: true, macPreviews: false).body, mac.body)
        XCTAssertEqual(NotificationPreviewPolicy.display(mac, globalPreviews: true, macPreviews: true).body, mac.body)
        let globallyHidden = NotificationPreviewPolicy.display(mac, globalPreviews: false, macPreviews: true)
        XCTAssertNotEqual(globallyHidden.body, mac.body)
        XCTAssertNil(globallyHidden.senderName)
        XCTAssertNil(globallyHidden.previewText)
        let old = notification("extension:a")
        XCTAssertEqual(NotificationPreviewPolicy.display(old, globalPreviews: true, macPreviews: false).body, old.body)
    }

    func testAppNameTitleKeepsBodyHiddenByMacPreviewPolicy() throws {
        let app = NotificationApplicationIdentity(name: "Test App", bundleIdentifier: "example.test")
        let banner = try XCTUnwrap(MacNotificationBannerParser.parse([app.name, "Private body"], applications: [app], allowUnknownSource: true))
        let record = IslandNotification(sourceID: "macOS:source-regression", appName: banner.application.name,
            bundleIdentifier: nil, appIcon: "app.badge", appIconURL: nil, title: banner.title, body: banner.body,
            senderName: nil, previewText: nil, avatarURL: nil, timestamp: Date(), tapAction: nil)
        let display = NotificationPreviewPolicy.display(record, globalPreviews: true, macPreviews: false)
        XCTAssertEqual(display.title, app.name)
        XCTAssertNotEqual(display.body, "Private body")
        XCTAssertNil(display.bundleIdentifier)
        XCTAssertNil(display.tapAction)
    }

    func testIdenticalTextInDifferentMacEventsDoesNotMerge() {
        let manager = NotificationManager(startMonitoring: false)
        let first = notification("macOS:a")
        let second = notification("macOS:b")
        XCTAssertFalse(manager.notificationsMatch(first, second))
        XCTAssertTrue(manager.notificationsMatch(first, first))
    }
}

@MainActor
final class SystemFeedbackRenderingTests: XCTestCase {
    func testNativeFeedbackComponentsRenderWithinCompactDimensions() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/SF1Validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (kind, name) in [(SystemFeedbackKind.volume, "volume"), (.brightness, "brightness")] {
            let renderer = ImageRenderer(content: SystemHUDCompactView(kind: kind)
                .padding(.horizontal, 12).frame(width: 220, height: 36).background(.black))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size, NSSize(width: 220, height: 36))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 500)
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        let manager = NotificationManager(startMonitoring: false)
        manager.latestNotification = IslandNotification(
            sourceID: "macOS:render-test", appName: "测试 App", bundleIdentifier: nil, appIcon: "app.badge",
            appIconURL: nil, title: "测试联系人", body: "仅用于原生组件渲染的测试内容", senderName: nil,
            previewText: nil, avatarURL: nil, timestamp: Date(), tapAction: nil
        )
        let renderer = ImageRenderer(content: NotificationCompactView(manager: manager)
            .padding(.horizontal, 12).frame(width: 220, height: 36).background(.black))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("notification.png"))
    }
}
