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
        let summary: KeepAwakeRecap.Cycle
        @Published var autoShow: Bool
        @Published var editable: Bool
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
    }
    let panel: Panel
    let presentation: Presentation
    init(summary: KeepAwakeRecap.Cycle, autoShow: Bool, editable: Bool, toggle: @escaping (Bool) -> Bool) {
        presentation = Presentation(summary: summary, autoShow: autoShow, editable: editable, toggle: toggle)
        let available = NSScreen.main?.visibleFrame.height ?? 800
        let height = max(360, min(660, available - 70))
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 460, height: height),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isOpaque = true; panel.backgroundColor = .windowBackgroundColor; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = UserDefaults.standard.bool(forKey: "general.showInScreenRecordings") ? .readOnly : .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        let host = NSHostingView(rootView: KeepAwakeRecapView(model: presentation).frame(width: 460, height: height))
        panel.contentView = host
        panel.setAccessibilityIdentifier("data-annotation-id=si.ka.recap")
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXDialog"))
        presentation.close = { [weak self] in self?.dismiss() }
        panel.dismissHandler = { [weak self] in self?.dismiss() }
    }
    @discardableResult func present(manual: Bool) -> Bool {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
        }
        panel.acceptsKeys = manual
        panel.orderFrontRegardless()
        if manual { panel.makeKey() }
        return panel.isVisible
    }
    func dismiss() { panel.orderOut(nil) }
    func showPersistenceError(_ error: String?) { presentation.persistenceError = error }
    func updatePreference(_ value: Bool, editable: Bool) { presentation.autoShow = value; presentation.editable = editable }
}

private struct KeepAwakeRecapView: View {
    @ObservedObject var model: KeepAwakeRecapPanel.Presentation
    private var summary: KeepAwakeRecap.Cycle { model.summary }
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
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 42, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) { Text("SuperIsland").font(.headline); Text("本次合盖回顾").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.close?() } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).background(Color.primary.opacity(0.07), in: Circle())
                    .accessibilityLabel("关闭合盖回顾").dataAnnotationID("si.ka.recap.close")
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text(time(summary.start?.wall) + " — " + time(summary.end?.wall) + " · 截至本次开盖")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        metric("合盖时长", KeepAwakeRecap.durationText(summary.duration), accent: false)
                        Spacer()
                        metric("保持运行时长", KeepAwakeRecap.durationText(summary.holdDuration), accent: true)
                    }.dataAnnotationID("si.ka.recap.metrics")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(KeepAwakeRecap.State.allCases, id: \.self) { state in
                            let count = summary.userTasks.filter { $0.state == state }.count
                            if count > 0 { Text("\(count) 项" + state.title).font(.caption.weight(.semibold)).foregroundStyle(color(state)) }
                        }
                        if summary.tasks.contains(where: { $0.kind == .unclassified }) {
                            Text("部分任务类型待确认，不计入用户任务汇总").font(.caption).foregroundStyle(.orange)
                        }
                    }.dataAnnotationID("si.ka.recap.summary")
                    VStack(spacing: 10) {
                        fact("保持状态", powerText + (summary.power == .released ? " · " + time(summary.releasedAt) : ""))
                        Divider(); fact("系统休眠", sleepText)
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).dataAnnotationID("si.ka.recap.power")
                    if summary.incomplete {
                        Text((summary.issues.sorted() + (summary.tasks.contains(where: { $0.kind == .unclassified }) ? ["来源未提供可靠的用户/后台分类；未读取正文猜测。"] : [])).joined(separator: " "))
                            .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                            .dataAnnotationID("si.ka.recap.notice")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("本次任务").font(.caption.weight(.semibold)); Spacer(); Text("\(summary.userTasks.count) 项").font(.caption).foregroundStyle(.secondary) }
                        if summary.userTasks.isEmpty { Text(summary.auxiliary.isEmpty ? "本次没有用户任务" : "尚无分类明确的用户任务，其他记录见下方。").font(.caption).foregroundStyle(.secondary) }
                        LazyVStack(spacing: 0) { ForEach(summary.userTasks) { task in taskRow(task) } }
                    }.dataAnnotationID("si.ka.recap.tasks")
                    if !summary.auxiliary.isEmpty {
                        DisclosureGroup("后台检查 \(summary.auxiliary.filter { $0.kind == .background }.count) 项 · 类型待确认 \(summary.auxiliary.filter { $0.kind == .unclassified }.count) 条") {
                            LazyVStack(spacing: 0) { ForEach(summary.auxiliary) { task in taskRow(task) } }
                        }.font(.caption).dataAnnotationID("si.ka.recap.auxiliary")
                    }
                    Divider()
                    DisclosureGroup("本次时间线") {
                        ForEach(summary.timeline.sorted { $0.continuous < $1.continuous }) { entry in
                            HStack(alignment: .top) { Text(time(entry.wall)).monospacedDigit().foregroundStyle(.secondary); Spacer(); Text(entry.title).multilineTextAlignment(.trailing) }.font(.caption).padding(.vertical, 3)
                        }
                    }.font(.caption).dataAnnotationID("si.ka.recap.timeline")
                    DisclosureGroup("统计说明") {
                        Text("合盖时长是本次关盖到开盖的时间。保持运行时长只计本功能实际生效的时段，并发只计一次，也包含释放前等待，不代表 CPU 工作时间。\n\n任务按来源和身份去重；后台检查只在有明确分类时分列，其余保留待确认。仅受理休眠请求不算真正睡眠，需睡眠/唤醒和时钟证据。时间点来自本机观察记录，无法确认时不补零。").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }.font(.caption).dataAnnotationID("si.ka.recap.explanation")
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider().padding(.horizontal, 24)
            if let error = model.preferenceError ?? model.persistenceError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24).padding(.top, 6) }
            HStack {
                Toggle("开盖后自动显示", isOn: Binding(get: { model.autoShow }, set: model.change))
                    .toggleStyle(.switch).controlSize(.mini).disabled(!model.editable).dataAnnotationID("si.ka.recap.auto")
                Spacer(); Text("关闭窗口不会停止任务").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 24).padding(.vertical, 16)
        }.background(Color(nsColor: .windowBackgroundColor)).accessibilityElement(children: .contain)
    }
    private func metric(_ title: String, _ value: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: value.count > 7 ? 25 : 32, weight: .semibold)).monospacedDigit().foregroundStyle(accent ? Color.green : Color.primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.caption)
    }
    private func taskRow(_ task: KeepAwakeRecap.Task) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.kind == .background ? "gearshape" : "terminal").frame(width: 30, height: 30).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(KeepAwakeSource.all.first { $0.id == task.source }?.name ?? "未知来源").font(.callout.weight(.medium))
                Text("任务 \(task.ordinal) · " + time(task.changedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(); Text(task.state.title).font(.caption.weight(.medium)).foregroundStyle(color(task.state))
        }.padding(.vertical, 10)
    }
}
