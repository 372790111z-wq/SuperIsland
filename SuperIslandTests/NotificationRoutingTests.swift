import XCTest
@testable import SuperIsland

@MainActor
final class NotificationRoutingTests: XCTestCase {
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
    func testSyntheticTaskEventsAreRejectedForEverySourceWhileRealNotificationsRemainVisible() async {
        let state = AppState.shared
        let oldEnabled = state.notificationsEnabled, oldSources = state.enabledNotificationSourceIDs
        defer { state.notificationsEnabled = oldEnabled; state.enabledNotificationSourceIDs = oldSources }
        state.notificationsEnabled = true
        state.enabledNotificationSourceIDs = ["macOS", "compatibleApps", "extensions"]
        let manager = NotificationManager(startMonitoring: false, macSourceActivation: { _ in })
        manager.applyFeedPreferences()
        func event(_ id: String, source: String) -> IslandNotification {
            .init(sourceID: id, appName: source, bundleIdentifier: "example.fixture", appIcon: "app", appIconURL: nil,
                  title: source + " · 任务完成", body: "本次任务已完成。", senderName: nil,
                  previewText: nil, avatarURL: nil, timestamp: Date(), tapAction: nil)
        }
        // No app-name allowlist: all current sources and an unknown future source.
        for source in KeepAwakeSource.all.map(\.id) + ["future-app"] {
            manager.addNotification(event("task-completion:" + source, source: source))
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(manager.recentNotifications.isEmpty)
        XCTAssertNil(manager.latestNotification)

        // Identical wording from a real ingress must not be suppressed as an echo.
        manager.addNotification(event("macOS:actual", source: "Codex"))
        manager.addNotification(event("extension:actual", source: "Future App"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(Set(manager.recentNotifications.map(\.sourceID)), ["macOS:actual", "extension:actual"])
        manager.clearAll()

        state.enabledNotificationSourceIDs = []
        manager.applyFeedPreferences()
        manager.addNotification(event("macOS:disabled", source: "Codex"))
        manager.addNotification(event("task-completion:disabled", source: "Future App"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(manager.recentNotifications.isEmpty)
    }
}
