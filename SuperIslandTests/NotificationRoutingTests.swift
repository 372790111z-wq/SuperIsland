import XCTest
import UserNotifications
@testable import SuperIsland

@MainActor
final class NotificationRoutingTests: XCTestCase {
    func testMasterSwitchConsumesDisabledEventsAndDeduplicatesEnabledEvents() {
        var enabled = false, shown: [IslandNotification] = [], sent: [UNNotificationRequest] = []
        let router = TaskCompletionNotifications(enabled: { enabled }, show: { shown.append($0) },
            submit: { sent.append($0); $1() }, removePending: { _ in }, removeDelivered: { _ in })
        router.receive(.init(id: "task-completion:off", sourceName: "Codex"))
        enabled = true; router.synchronize()
        router.receive(.init(id: "task-completion:off", sourceName: "Codex"))
        XCTAssertTrue(shown.isEmpty); XCTAssertTrue(sent.isEmpty)
        for _ in 0..<3 { router.receive(.init(id: "task-completion:on", sourceName: "Other source")) }
        XCTAssertEqual(shown.count, 1); XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(shown.first?.sourceID, sent.first?.identifier)
        enabled = false; router.synchronize()
        router.receive(.init(id: "task-completion:off-again", sourceName: "Codex"))
        XCTAssertEqual(sent.count, 1)
    }

    func testInflightRequestIsRemovedEvenIfSwitchReopensBeforeCallback() async {
        var enabled = true, finished: (() -> Void)?, removed: [String] = [], delivered: [String] = []
        let router = TaskCompletionNotifications(enabled: { enabled }, show: { _ in }, submit: { _, done in finished = done },
            removePending: { removed += $0 }, removeDelivered: { delivered += $0 })
        router.receive(.init(id: "old", sourceName: "Codex"))
        enabled = false; router.synchronize()
        XCTAssertEqual(removed, ["old"])
        enabled = true; router.synchronize(); finished?()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(delivered, ["old"])
    }

    func testReentrantDisableBeforeSystemSubmissionDoesNotSend() {
        var enabled = true, sent = 0
        let router = TaskCompletionNotifications(enabled: { enabled }, show: { _ in enabled = false },
            submit: { _, _ in sent += 1 }, removePending: { _ in }, removeDelivered: { _ in })
        router.receive(.init(id: "one", sourceName: "Codex"))
        XCTAssertEqual(sent, 0)
    }

    func testSystemEchoSuppressionDoesNotHideOtherAppOrUnrelatedMessage() throws {
        var shown: IslandNotification?
        let router = TaskCompletionNotifications(enabled: { true }, show: { shown = $0 },
            submit: { _, done in done() }, removePending: { _ in }, removeDelivered: { _ in })
        router.receive(.init(id: "one", sourceName: "Codex"))
        let message = try XCTUnwrap(shown)
        func banner(_ source: String, bundle: String? = nil, title: String? = nil) -> IslandNotification {
            .init(sourceID: source, appName: "Mac 通知", bundleIdentifier: bundle, appIcon: "app", appIconURL: nil,
                  title: title ?? message.title, body: message.body, senderName: nil, previewText: nil,
                  avatarURL: nil, timestamp: message.timestamp, tapAction: nil)
        }
        XCTAssertTrue(router.isEcho(banner("macOS:echo")))
        XCTAssertFalse(router.isEcho(banner("macOS:other", bundle: "example.other")))
        XCTAssertFalse(router.isEcho(banner("macOS:unrelated", title: "Another task")))
        XCTAssertFalse(router.isEcho(banner("extension:one")))
    }

    func testCompletionRequiresObservedMatchingTaskAndExplicitSuccessAcrossSources() throws {
        for source in ["codex-desktop", "codex-cli", "claude-code", "zcode-desktop"] {
            for flag in [true, false] {
                var engine = KeepAwakeEngine(); engine.preferences.notifyCompletion = flag
                let start = KeepAwakeEngine.Event(source: source, session: "session", sequence: 1, state: .running, taskID: "turn", startsTask: true)
                XCTAssertTrue(engine.receive(start, now: 0)); XCTAssertFalse(engine.enabled)
                let previous = try XCTUnwrap(engine.sessions[start.storageKey])
                for state in [KeepAwakeEngine.TaskState.waiting, .idle, .failed, .cancelled, .ended] {
                    var other = start; other.sequence = 2; other.state = state
                    XCTAssertNil(TaskCompletionEvent.transition(from: previous, to: other))
                }
                var end = start; end.sequence = 2; end.state = .completed
                XCTAssertNotNil(TaskCompletionEvent.transition(from: previous, to: end))
                XCTAssertNil(TaskCompletionEvent.transition(from: nil, to: end))
                var wrong = end; wrong.taskID = "other"
                XCTAssertNil(TaskCompletionEvent.transition(from: previous, to: wrong))
                wrong = end; wrong.sequence = 1
                XCTAssertNil(TaskCompletionEvent.transition(from: previous, to: wrong))
                XCTAssertTrue(engine.receive(end, now: 1))
                end.sequence = 3
                XCTAssertNil(TaskCompletionEvent.transition(from: engine.sessions[end.storageKey], to: end))
            }
        }
    }

    func testPreferenceObserverStartsFromOffAndTracksBothEntryPointsAndSources() throws {
        let name = "NotificationsObserver-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "module.notifications.enabled")
        var changes = 0
        let observer = NotificationPreferencesObserver(defaults: defaults) { changes += 1 }
        XCTAssertEqual(changes, 0)
        defaults.set(true, forKey: "module.notifications.enabled")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(changes, 1)
        observer.refresh(); XCTAssertEqual(changes, 1)
        defaults.set("macOS", forKey: "module.notifications.enabledSources")
        observer.refresh(); XCTAssertEqual(changes, 2)
        defaults.set(false, forKey: "module.notifications.enabled")
        observer.refresh(); XCTAssertEqual(changes, 3)
        defaults.set("unused", forKey: "unrelated")
        observer.refresh(); XCTAssertEqual(changes, 3)
    }

    func testManagerAppliesMacActivationAndClearsFeedOnMasterOff() async {
        let state = AppState.shared
        let oldEnabled = state.notificationsEnabled, oldSources = state.enabledNotificationSourceIDs
        defer { state.notificationsEnabled = oldEnabled; state.enabledNotificationSourceIDs = oldSources }
        var activations: [Bool] = []
        let manager = NotificationManager(startMonitoring: false, macSourceActivation: { activations.append($0) })
        state.notificationsEnabled = true; state.enabledNotificationSourceIDs = ["macOS"]
        manager.applyFeedPreferences(); XCTAssertEqual(activations.last, true)
        manager.addNotification(.init(sourceID: "macOS:new", appName: "Fixture", bundleIdentifier: nil, appIcon: "app", appIconURL: nil,
            title: "Fixture title", body: "Fixture body", senderName: nil, previewText: nil, avatarURL: nil, timestamp: Date(), tapAction: nil))
        state.notificationsEnabled = false; manager.applyFeedPreferences()
        state.notificationsEnabled = true; manager.applyFeedPreferences()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(manager.recentNotifications.isEmpty, "An arrival queued before off/on must not reappear")
        manager.addNotification(.init(sourceID: "macOS:after-reopen", appName: "Fixture", bundleIdentifier: nil, appIcon: "app", appIconURL: nil,
            title: "New fixture", body: "New body", senderName: nil, previewText: nil, avatarURL: nil, timestamp: Date(), tapAction: nil))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(manager.recentNotifications.count, 1)
        state.notificationsEnabled = false; manager.applyFeedPreferences()
        XCTAssertEqual(activations.last, false); XCTAssertTrue(manager.recentNotifications.isEmpty)
        XCTAssertNil(manager.latestNotification)
        state.notificationsEnabled = true; state.enabledNotificationSourceIDs = ["extensions"]; manager.applyFeedPreferences()
        XCTAssertEqual(activations.last, false)
        state.enabledNotificationSourceIDs = ["extensions", "macOS"]; manager.applyFeedPreferences()
        XCTAssertEqual(activations.last, true)
        XCTAssertTrue(manager.recentNotifications.isEmpty)
    }
}
