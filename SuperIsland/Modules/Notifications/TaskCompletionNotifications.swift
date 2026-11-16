import Foundation
import UserNotifications

/// Only an accepted, observed task transition can produce a completion event.
/// Monitoring is shared with KeepAwake, but power state is not notification policy.
struct TaskCompletionEvent {
    let id: String
    let sourceName: String
    static func transition(from previous: KeepAwakeEngine.Session?, to event: KeepAwakeEngine.Event) -> Self? {
        guard let previous, previous.isUnfinished, previous.event.storageKey == event.storageKey,
              event.sequence > previous.event.sequence, event.state == .completed,
              !KeepAwakeHookContract.isAuxiliaryTask(source: event.source, taskID: event.taskID),
              let source = KeepAwakeSource.all.first(where: { $0.id == event.source }) else { return nil }
        return .init(id: "task-completion:" + KeepAwakeHookContract.anonymousIdentity(event.storageKey + ":" + String(event.sequence)), sourceName: source.name)
    }
}

@MainActor
final class TaskCompletionNotifications {
    typealias Submit = (UNNotificationRequest, @escaping () -> Void) -> Void
    private let enabled: () -> Bool
    private let show: (IslandNotification) -> Void
    private let submit: Submit
    private let removePending: ([String]) -> Void
    private let removeDelivered: ([String]) -> Void
    private var lastEnabled: Bool
    private var generation: UInt64 = 0
    private var seen: [String] = []
    private var pending = Set<String>()
    private var echoes: [(title: String, body: String, at: Date)] = []

    init(enabled: @escaping () -> Bool, show: @escaping (IslandNotification) -> Void,
         submit: @escaping Submit = { request, finished in
             UNUserNotificationCenter.current().add(request) { _ in finished() }
         },
         removePending: @escaping ([String]) -> Void = { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) },
         removeDelivered: @escaping ([String]) -> Void = { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }) {
        self.enabled = enabled; self.show = show; self.submit = submit
        self.removePending = removePending; self.removeDelivered = removeDelivered
        lastEnabled = enabled()
    }
    func synchronize() {
        let value = enabled()
        guard value != lastEnabled else { return }
        lastEnabled = value; generation &+= 1
        if !value { removePending(Array(pending)) }
    }
    func receive(_ event: TaskCompletionEvent) {
        synchronize()
        guard !seen.contains(event.id) else { return }
        seen.append(event.id)
        if seen.count > 512 { seen.removeFirst(seen.count - 512) }
        guard enabled() else { return } // Consume while off; never replay history on enable.
        let title = event.sourceName + " · 任务完成", body = "本次任务已完成。"
        let now = Date()
        echoes.removeAll { now.timeIntervalSince($0.at) > 10 }
        echoes.append((title, body, now))
        if echoes.count > 80 { echoes.removeFirst(echoes.count - 80) }
        show(.init(sourceID: event.id, appName: event.sourceName, bundleIdentifier: nil,
            appIcon: "checkmark.circle", appIconURL: nil, title: title, body: body,
            senderName: nil, previewText: body, avatarURL: nil, timestamp: now, tapAction: nil))
        guard enabled() else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        content.categoryIdentifier = "superisland.task-completion"
        let epoch = generation
        pending.insert(event.id)
        submit(.init(identifier: event.id, content: content, trigger: nil)) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending.remove(event.id)
                if !self.enabled() || self.generation != epoch {
                    self.removePending([event.id]); self.removeDelivered([event.id])
                }
            }
        }
    }
    func isEcho(_ notification: IslandNotification) -> Bool {
        guard notification.sourceID.hasPrefix("macOS:"),
              notification.bundleIdentifier == nil || notification.bundleIdentifier == Bundle.main.bundleIdentifier else { return false }
        return echoes.contains { abs(notification.timestamp.timeIntervalSince($0.at)) <= 10 && $0.title == notification.title && $0.body == notification.body }
    }
}
