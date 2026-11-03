import AppKit
import SwiftUI

@MainActor final class KeepAwakeRecapPanel {
    final class Panel: NSPanel {
        var acceptsKeys = false
        var dismissHandler: (() -> Void)?
        override var canBecomeMain: Bool { false }
        override var canBecomeKey: Bool { acceptsKeys }
        override func cancelOperation(_ sender: Any?) { dismissHandler?() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 53 { dismissHandler?(); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func mouseDown(with event: NSEvent) {
            acceptsKeys = true; makeKey(); super.mouseDown(with: event)
        }
    }
    @MainActor final class Presentation: ObservableObject {
        @Published private(set) var summary: KeepAwakeRecap.Cycle
        @Published var autoShow: Bool
        @Published var editable: Bool
        @Published var expandedChats = Set<String>()
        @Published var expandedMembers = Set<String>()
        @Published var preferenceError: String?
        @Published var persistenceError: String?
        let toggle: (Bool) -> Bool
        var close: (() -> Void)?
        init(summary: KeepAwakeRecap.Cycle, autoShow: Bool, editable: Bool, toggle: @escaping (Bool) -> Bool) {
            self.summary = summary; self.autoShow = autoShow; self.editable = editable; self.toggle = toggle
        }
        func change(_ value: Bool) {
            if toggle(value) { autoShow = value; preferenceError = nil }
            else { preferenceError = "自动显示偏好未保存，原选择仍生效。" }
        }
        func refresh(_ value: KeepAwakeRecap.Cycle) {
            // Only evidence belonging to this frozen cycle may update an open view.
            guard value.id == summary.id else { return }
            summary = value
        }
    }
    let panel: Panel
    let presentation: Presentation
    init(summary: KeepAwakeRecap.Cycle, autoShow: Bool, editable: Bool, toggle: @escaping (Bool) -> Bool) {
        presentation = Presentation(summary: summary, autoShow: autoShow, editable: editable, toggle: toggle)
        let available = NSScreen.main?.visibleFrame.height ?? 800
        let rows = min(3, max(1, summary.userTasks.count))
        let states = Set(summary.userTasks.map(\.state)).count
        let preferred = 240 + Double(rows * 34 + max(0, states - 1) * 12)
            + (summary.incomplete ? 36 : 0) + (summary.auxiliary.isEmpty ? 0 : 18)
        let height = max(240, min(360, preferred, available - 70))
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isOpaque = true; panel.backgroundColor = .windowBackgroundColor; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = UserDefaults.standard.bool(forKey: "general.showInScreenRecordings") ? .readOnly : .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        let host = NSHostingView(rootView: KeepAwakeRecapView(model: presentation)
            .ignoresSafeArea(.container, edges: .top).frame(width: 300, height: height))
        panel.contentView = host
        panel.setAccessibilityIdentifier("data-annotation-id=si.ka.recap")
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXDialog"))
        presentation.close = { [weak self] in self?.dismiss() }
        panel.dismissHandler = { [weak self] in self?.dismiss() }
    }
    static func frameOrigin(size: NSSize, visibleFrame: NSRect) -> NSPoint {
        let topInset = min(64, max(0, visibleFrame.height - size.height))
        return NSPoint(x: max(visibleFrame.minX, visibleFrame.midX - size.width / 2),
                       y: max(visibleFrame.minY, visibleFrame.maxY - topInset - size.height))
    }
    @discardableResult func present(manual: Bool) -> Bool {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(Self.frameOrigin(size: panel.frame.size, visibleFrame: visible))
        }
        panel.acceptsKeys = manual
        panel.orderFrontRegardless()
        if manual { panel.makeKey() }
        return panel.isVisible
    }
    func dismiss() { panel.orderOut(nil) }
    func updateSummary(_ value: KeepAwakeRecap.Cycle?) { if let value { presentation.refresh(value) } }
    func showPersistenceError(_ error: String?) { presentation.persistenceError = error }
    func updatePreference(_ value: Bool, editable: Bool) {
        if presentation.autoShow != value { presentation.autoShow = value }
        if presentation.editable != editable { presentation.editable = editable }
    }
}

private struct KeepAwakeRecapView: View {
    @ObservedObject var model: KeepAwakeRecapPanel.Presentation
    private var summary: KeepAwakeRecap.Cycle { model.summary }
    private var projection: KeepAwakeChatGrouping.Projection { summary.chatProjection }
    private func time(_ value: Double?) -> String {
        guard let value else { return "时间未记录" }
        return Date(timeIntervalSince1970: value).formatted(date: .omitted, time: .shortened)
    }
    private var powerText: String {
        guard summary.power == .released else { return summary.power.title }
        switch summary.releaseReason {
        case .tasksEnded: return "已自动释放"
        case .manual: return "已手动停止并释放"
        case .timer: return "手动保持已结束"
        case .pause: return "已暂停保持"
        case .unknown: return summary.power.title
        }
    }
    private var sleepText: String {
        if let when = summary.sleepAt { return "已确认休眠 · " + time(when) + "左右" }
        return summary.sleepRequested ? "休眠尚未确认" : "未确认休眠记录"
    }
    private func color(_ state: KeepAwakeRecap.State) -> Color {
        state == .failed ? .red : state == .completed ? .green : state.terminal ? .secondary : .orange
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) { Text("SuperIsland").font(.system(size: 12, weight: .semibold)); Text("本次合盖回顾").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Button { model.close?() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.07), in: Circle())
                    .accessibilityLabel("关闭合盖回顾").dataAnnotationID("si.ka.recap.close")
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(time(summary.start?.wall) + " — " + time(summary.end?.wall) + " · 截至本次开盖")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        metric("合盖时长", KeepAwakeRecap.durationText(summary.duration), accent: false)
                        Spacer()
                        metric("保持运行时长", KeepAwakeRecap.durationText(summary.holdDuration), accent: true)
                    }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.recap.metrics")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(KeepAwakeChatGrouping.State.allCases, id: \.self) { state in
                            let count = projection.groups.filter { $0.kind == .user && $0.state == state }.count
                            if count > 0 { Text("\(count) 个主聊天 · " + state.title).font(.caption.weight(.semibold))
                                .foregroundStyle(state == .ended ? Color.green : Color.orange) }
                        }
                        if summary.tasks.contains(where: { $0.kind == .unclassified }) {
                            Text("部分任务类型待确认，不计入用户任务汇总").font(.caption).foregroundStyle(.orange)
                        }
                    }.accessibilityElement(children: .contain).dataAnnotationID("si.ka.recap.summary")
                    VStack(spacing: 5) {
                        fact("保持状态", powerText + (summary.power == .released ? " · " + time(summary.releasedAt) : ""))
                        Divider(); fact("系统休眠", sleepText)
                    }.padding(7).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .contain).dataAnnotationID("si.ka.recap.power")
                    if summary.incomplete {
                        Text((summary.issues.sorted() + (summary.tasks.contains(where: { $0.kind == .unclassified }) ? ["来源未提供可靠的用户/后台分类；未读取正文猜测。"] : [])).joined(separator: " "))
                            .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                            .dataAnnotationID("si.ka.recap.notice")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        let groups = projection.groups.filter { $0.kind == .user }
                        HStack { Text("主聊天").font(.caption.weight(.semibold)); Spacer()
                            Text("\(groups.count) 个 · \(groups.reduce(0) { $0 + $1.children.count }) 个子任务").font(.caption2).foregroundStyle(.secondary) }
                        if groups.isEmpty { Text(summary.auxiliary.isEmpty ? "本次没有已确认归属的用户聊天" : "尚无分类明确的用户聊天，其他记录见下方。")
                            .font(.caption).foregroundStyle(.secondary) }
                        LazyVStack(alignment: .leading, spacing: 4) { ForEach(groups) { groupRow($0) } }
                        let unassigned = projection.unassigned.filter { $0.kind == .user }
                        if !unassigned.isEmpty {
                            DisclosureGroup("归属待确认 · \(unassigned.count) 条执行记录") {
                                ForEach(unassigned) { taskRow($0) }
                            }.font(.caption)
                        }
                    }.dataAnnotationID("si.ka.recap.tasks")
                    if !summary.auxiliary.isEmpty {
                        DisclosureGroup("后台检查 \(summary.auxiliary.filter { $0.kind == .background }.count) 项 · 类型待确认 \(summary.auxiliary.filter { $0.kind == .unclassified }.count) 条执行记录") {
                            let groups = projection.groups.filter { $0.kind == .unclassified }
                            if !groups.isEmpty { Text("\(groups.count) 个主聊天 · \(groups.reduce(0) { $0 + $1.children.count }) 个子任务，不计入用户汇总")
                                    .font(.caption2).foregroundStyle(.secondary) }
                            LazyVStack(alignment: .leading, spacing: 4) { ForEach(groups) { groupRow($0) } }
                            let unassigned = projection.unassigned.filter { $0.kind != .user }
                            if unassigned.contains(where: { $0.kind == .unclassified }) { Text("以下记录归属待确认").font(.caption2).foregroundStyle(.orange) }
                            LazyVStack(spacing: 0) { ForEach(unassigned) { taskRow($0) } }
                        }.font(.caption).dataAnnotationID("si.ka.recap.auxiliary")
                    }
                    Divider()
                    DisclosureGroup("本次时间线") {
                        ForEach(summary.timeline.sorted { $0.continuous < $1.continuous }) { entry in
                            HStack(alignment: .top) { Text(time(entry.wall)).monospacedDigit().foregroundStyle(.secondary); Spacer(); Text(entry.title).multilineTextAlignment(.trailing) }.font(.caption).padding(.vertical, 3)
                        }
                    }.font(.caption).dataAnnotationID("si.ka.recap.timeline")
                    DisclosureGroup("统计说明") {
                        Text("合盖时长是本次关盖到开盖的时间。保持运行时长只计本功能实际生效的时段，并发只计一次，也包含释放前等待，不代表 CPU 工作时间。\n\n主聊天按可信父子身份归并；同名不同聊天不合并。子任务与轮次分别显示；本轮完成不代表主聊天结束，会话未关闭也不等于正在运行。仅已接入且证据完整的本次执行均终结时显示本次执行已结束，不代表长期目标或未监控工作完成。开盖后的新轮不改写本次快照。后台检查只在明确分类时分列，其余保留待确认。仅受理休眠请求不算真正睡眠，需睡眠/唤醒和时钟证据。时间点来自本机观察记录，无法确认时不补零。").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }.font(.caption).dataAnnotationID("si.ka.recap.explanation")
                }.padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider().padding(.horizontal, 12)
            if let error = model.preferenceError ?? model.persistenceError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.top, 6) }
            HStack {
                Toggle("开盖后自动显示", isOn: Binding(get: { model.autoShow }, set: model.change))
                    .toggleStyle(.switch).controlSize(.mini).disabled(!model.editable).dataAnnotationID("si.ka.recap.auto")
                Spacer(); Text("关闭窗口不会停止任务").foregroundStyle(.secondary)
            }.font(.caption2).padding(.horizontal, 12).padding(.vertical, 7)
        }.background(Color(nsColor: .windowBackgroundColor)).accessibilityElement(children: .contain)
    }
    private func metric(_ title: String, _ value: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: value.count > 7 ? 18 : 22, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(accent ? Color.green : Color.primary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.caption)
    }
    private func groupRow(_ group: KeepAwakeChatGrouping.Group) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { model.expandedChats.contains(group.id) }, set: { value in
            if value { model.expandedChats.insert(group.id) } else { model.expandedChats.remove(group.id) }
        })) {
            VStack(alignment: .leading, spacing: 6) {
                Text("主聊天自身：" + group.rootRuntime.title).font(.caption2).foregroundStyle(.secondary)
                ForEach(group.members) { member in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top) {
                            Text(member.id == group.root ? "主聊天执行" : "子任务 \(member.ordinal)")
                            Spacer(); Text(member.runtime.title).foregroundStyle(member.runtime == .idle ? Color.secondary : Color.orange)
                        }.font(.caption)
                        Text(member.latest?.availability == "open" ? "会话未关闭" : member.latest?.availability == "closed" ? "会话关系已关闭，不代表成功" : "会话关系状态未提供").font(.caption2).foregroundStyle(.secondary)
                        DisclosureGroup("\(member.tasks.count) 轮执行记录", isExpanded: Binding(get: { model.expandedMembers.contains(group.id + ":" + member.id) }, set: { value in
                            let key = group.id + ":" + member.id
                            if value { model.expandedMembers.insert(key) } else { model.expandedMembers.remove(key) }
                        })) {
                            ForEach(Array(member.tasks.enumerated()), id: \.element.id) { index, task in
                                HStack(alignment: .top) {
                                    Text("第 \(index + 1) 轮 · " + time(task.changedAt)).foregroundStyle(.secondary)
                                    Spacer(); Text(KeepAwakeChatGrouping.roundTitle(task.state)).foregroundStyle(color(task.state))
                                }.font(.caption2).padding(.vertical, 2)
                            }
                        }.font(.caption2).dataAnnotationID("si.ka.recap.rounds")
                    }.padding(.top, 4).dataAnnotationID("si.ka.recap.member")
                }
                if group.hasUnknownMembers { Text("部分执行状态待确认，不据此判断全部结束。").font(.caption2).foregroundStyle(.orange) }
            }.padding(.leading, 3).padding(.vertical, 5)
        } label: {
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.displayTitles[group.titleKey] ?? "主聊天 \(group.ordinal)")
                        .font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Text((KeepAwakeSource.all.first { $0.id == group.source }?.name ?? "未知来源") + " · 聊天 \(group.ordinal) · \(group.children.count) 个子任务")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                Text(group.state.title).font(.caption2.weight(.medium))
                    .foregroundStyle(group.state == .ended ? Color.green : Color.orange).multilineTextAlignment(.trailing)
            }
        }.padding(.vertical, 4).dataAnnotationID("si.ka.recap.chat")
    }
    private func taskRow(_ task: KeepAwakeRecap.Task) -> some View {
        HStack(spacing: 8) {
            Image(systemName: task.kind == .background ? "gearshape" : "terminal").frame(width: 22, height: 22).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(KeepAwakeSource.all.first { $0.id == task.source }?.name ?? "未知来源").font(.system(size: 11, weight: .medium))
                Text("执行记录 \(task.ordinal) · " + time(task.changedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(); Text(KeepAwakeChatGrouping.roundTitle(task.state)).font(.caption.weight(.medium)).foregroundStyle(color(task.state))
        }.padding(.vertical, 4)
    }
}
