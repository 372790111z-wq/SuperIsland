import AppKit
import ApplicationServices

/// Diagnostic-only UI. It never starts normal product services or hotkeys.
@MainActor
final class ChromeFullScreenProbe: NSObject {
    private let item: NSStatusItem
    private var panel: NSPanel?
    private var sequenceTask: Task<Void, Never>?
    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.title = "FS探针"
        let menu = NSMenu()
        for (title, action) in [("原版：移到上个显示器", #selector(previous)), ("原版：移到下个显示器", #selector(next)), ("连续往返 6 次", #selector(roundTrips)), ("退出诊断探针", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
        let panel = NSPanel(contentRect: NSRect(x: 60, y: 100, width: 340, height: 195),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Chrome 原版跨屏诊断"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 10
        for (title, action) in [("原版：移到上个显示器", #selector(previous)), ("原版：移到下个显示器", #selector(next)), ("连续往返 6 次", #selector(roundTrips)), ("退出诊断探针", #selector(quit))] {
            stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.frame = NSRect(x: 20, y: 12, width: 300, height: 155)
        panel.contentView?.addSubview(stack)
        self.panel = panel
        panel.orderFrontRegardless()
    }
    private func run(_ action: WindowQuickAction) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else { return }
            WindowInteractionDiagnosticRecorder.shared.record(component: "chromeBaselineProbe", event: "triggered",
                metadata: ["frontmostPID": .integer(Int64(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0))])
            WindowEnhancementController.shared.perform(action: action)
        }
    }
    @objc private func previous() { run(.previousDisplay) }
    @objc private func next() { run(.nextDisplay) }
    @objc private func roundTrips() {
        guard sequenceTask == nil else { return }
        sequenceTask = Task { @MainActor [weak self] in
            defer { self?.sequenceTask = nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let application = AXUIElementCreateApplication(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
            func focusedNumber() -> CGWindowID? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                let window = unsafeBitCast(value, to: AXUIElement.self)
                var fullScreen: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
                      fullScreen as? Bool == true else { return nil }
                return windowDirectWindowNumber(of: window)
            }
            guard let expectedWindow = focusedNumber() else { return }
            for index in 0..<6 {
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome",
                      focusedNumber() == expectedWindow else { break }
                WindowInteractionDiagnosticRecorder.shared.record(component: "chromeBaselineProbe", event: "sequence_step",
                    metadata: ["step": .integer(Int64(index + 1)), "windowID": .integer(Int64(expectedWindow))])
                WindowEnhancementController.shared.perform(action: index.isMultiple(of: 2) ? .previousDisplay : .nextDisplay)
                await WindowEnhancementController.shared.awaitDiagnosticMutationCompletion()
            }
        }
    }
    @objc private func quit() { sequenceTask?.cancel(); NSApp.terminate(nil) }
}
