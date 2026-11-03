import Foundation

/// Presentation facts only. No Engine, IPC, task-control or power mutations.
enum KeepAwakeChatGrouping {
    enum Runtime: String, Codable { case running, waiting, idle, unknown
        var title: String { switch self { case .running: "运行中"; case .waiting: "等待确认"; case .idle: "当前无执行"; case .unknown: "状态待确认" } }
    }
    struct Identity: Codable, Equatable {
        var scope: String
        var session: String
        var root: String
        var parent: String?
        var availability: String? = nil
        var sessionRuntime: Runtime = .unknown
        var rootRuntime: Runtime = .unknown
        var observedAt: Double
        var valid: Bool {
            [scope, session, root].allSatisfy(KeepAwakeTurnMetadataReader.validHash) &&
            parent.map(KeepAwakeTurnMetadataReader.validHash) != false && parent != session &&
            observedAt.isFinite && observedAt >= 0 && (availability == nil || ["open", "closed"].contains(availability!))
        }
        var titleKey: String { scope + ":" + root }
    }
    enum State: String, CaseIterable {
        case running, waiting, unknown, ended
        var title: String { switch self { case .running: "运行中"; case .waiting: "等待确认"; case .unknown: "状态待确认"; case .ended: "本次执行已结束" } }
    }
    struct Member: Identifiable {
        var id: String
        var tasks: [KeepAwakeRecap.Task]
        var ordinal: Int { tasks.map(\.ordinal).min() ?? 0 }
        var latest: Identity? { latestIdentity(tasks) }
        var runtime: Runtime {
            if tasks.contains(where: { $0.state == .running }) { return .running }
            if tasks.contains(where: { $0.state == .waiting }) { return .waiting }
            if tasks.contains(where: { !$0.state.terminal }) { return .unknown }
            return latest?.sessionRuntime ?? .unknown
        }
    }
    struct Group: Identifiable {
        var id: String
        var source: String
        var root: String
        var scope: String
        var tasks: [KeepAwakeRecap.Task]
        var ordinal: Int { tasks.map(\.ordinal).min() ?? 0 }
        var kind: KeepAwakeRecap.Kind { tasks.allSatisfy { $0.kind == .user } ? .user : .unclassified }
        var titleKey: String { scope + ":" + root }
        var members: [Member] {
            Dictionary(grouping: tasks, by: { $0.chat!.session }).map { Member(id: $0.key, tasks: $0.value.sorted { $0.ordinal < $1.ordinal }) }
                .sorted { $0.ordinal < $1.ordinal }
        }
        var children: [Member] { members.filter { $0.id != root } }
        var rootRuntime: Runtime { members.first(where: { $0.id == root })?.runtime ?? latestIdentity(tasks)?.rootRuntime ?? .unknown }
        var state: State {
            let states = members.map(\.runtime) + [rootRuntime]
            if states.contains(.running) { return .running }
            if states.contains(.waiting) { return .waiting }
            if states.contains(.unknown) || tasks.isEmpty || tasks.contains(where: { !$0.state.terminal }) { return .unknown }
            return .ended
        }
        var hasUnknownMembers: Bool { members.contains { $0.runtime == .unknown } || rootRuntime == .unknown }
    }
    struct Projection {
        var groups: [Group]
        var unassigned: [KeepAwakeRecap.Task]
    }
    static func project(_ tasks: [KeepAwakeRecap.Task]) -> Projection {
        let admitted = tasks.filter { $0.kind != .background && $0.chat?.valid == true }
        let buckets = Dictionary(grouping: admitted) { $0.source + ":" + $0.chat!.scope + ":" + $0.chat!.root }
        let groups = buckets.map { key, values in
            Group(id: key, source: values[0].source, root: values[0].chat!.root, scope: values[0].chat!.scope, tasks: values)
        }.sorted { $0.ordinal < $1.ordinal }
        return .init(groups: groups, unassigned: tasks.filter { $0.chat?.valid != true || $0.kind == .background }.sorted { $0.ordinal < $1.ordinal })
    }
    private static func latestIdentity(_ tasks: [KeepAwakeRecap.Task]) -> Identity? {
        let values = tasks.compactMap(\.chat)
        guard let time = values.map(\.observedAt).max() else { return nil }
        let latest = values.filter { $0.observedAt == time }
        guard let first = latest.first,
              latest.allSatisfy({ $0.rootRuntime == first.rootRuntime && $0.sessionRuntime == first.sessionRuntime || $0.session != first.session && $0.rootRuntime == first.rootRuntime }) else { return nil }
        return first
    }
    static func roundTitle(_ state: KeepAwakeRecap.State) -> String {
        switch state { case .completed: "本轮已完成"; case .failed: "本轮失败"; case .cancelled: "本轮已取消"; case .ended: "本轮已结束"; case .running: "运行中"; case .waiting: "等待确认"; case .unknown: "本轮状态待确认" }
    }
    static func safeTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.utf8.count <= 512,
              !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet(charactersIn: "\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) }) else { return nil }
        return cleaned
    }
}
