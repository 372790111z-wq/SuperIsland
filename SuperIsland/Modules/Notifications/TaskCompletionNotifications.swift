import Foundation

/// Only an accepted, observed task transition can produce a completion event.
/// Internal task observation only. Completion is not evidence of an app notification.
/// Never route this event to island or system notifications.
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
