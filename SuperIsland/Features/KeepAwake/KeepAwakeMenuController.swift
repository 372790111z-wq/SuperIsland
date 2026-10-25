import AppKit
import Combine

@MainActor
final class KeepAwakeMenuController: NSObject, NSMenuDelegate {
    private enum Role: Int {
        case state = 4101, detail, master, retry, automatic, manual30, manual60, pause, sources
    }
    private final class MenuReference {
        weak var menu: NSMenu?
        init(_ menu: NSMenu) { self.menu = menu }
    }
    private let service: KeepAwakeService
    private var updateObserver: AnyCancellable?
    private var menus: [MenuReference] = []
    private var statusItem: NSStatusItem?

    init(service: KeepAwakeService = .shared) {
        self.service = service
        super.init()
        // The main App menu and the standalone icon use different NSMenus,
        // but both project the same service. Keep only weak menu references.
        updateObserver = service.objectWillChange.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLiveValues() }
    }

    /// Installed by normal bootstrap, independently of the main App icon or
    /// module enablement. Switching the module off must retain this entry point.
    @discardableResult func installStandaloneStatusItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "SuperIsland 保持唤醒")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityIdentifier("data-annotation-id=si.ka.status-item")
        item.menu = makeMenu()
        statusItem = item
        refreshLiveValues()
        return item
    }

    private func refreshLiveValues() {
        menus.removeAll { $0.menu == nil }
        for reference in menus {
            if let menu = reference.menu { refresh(menu) }
        }
        statusItem?.button?.toolTip = "保持唤醒 · " + service.decision.title
    }
    private func refresh(_ menu: NSMenu) {
        func row(_ role: Role) -> NSMenuItem? { menu.item(withTag: role.rawValue) }
        row(.master)?.state = service.engine.enabled ? .on : .off
        row(.master)?.isEnabled = service.canEnable
        row(.retry)?.isHidden = !service.releasePending
        row(.retry)?.isEnabled = !service.lid.busy
        for role: Role in [.automatic, .manual30, .manual60] { row(role)?.isEnabled = service.canEnable }
        row(.state)?.title = service.decision.title
        row(.detail)?.title = service.decision.detail
        row(.automatic)?.state = service.engine.enabled && service.engine.mode == .automatic ? .on : .off
        row(.pause)?.title = service.engine.pauseDeadline.map { $0 > KeepAwakeClock.now() } == true ? "结束暂停" : "暂停 30 分钟"
        row(.pause)?.isEnabled = service.engine.enabled
        row(.sources)?.title = "\(service.decision.runningSources) 个运行来源 · \(service.lidStatus)"
    }
    func item() -> NSMenuItem {
        let item = NSMenuItem(title: "保持唤醒", action: nil, keyEquivalent: "")
        item.setAccessibilityIdentifier("data-annotation-id=si.ka.menu")
        item.submenu = makeMenu()
        return item
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "保持唤醒")
        menu.delegate = self
        menus.removeAll { $0.menu == nil }
        menus.append(MenuReference(menu))
        populate(menu)
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { service.tick(); refresh(menu) }
    private func populate(_ menu: NSMenu) {
        func information(_ text: String, _ role: Role) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.tag = role.rawValue; item.isEnabled = false; menu.addItem(item)
        }
        information(service.decision.title, .state)
        information(service.decision.detail, .detail)
        menu.addItem(.separator())
        let master = add("启用保持唤醒", action: #selector(toggleMaster), role: .master, to: menu)
        master.setAccessibilityIdentifier("data-annotation-id=si.ka.menu-master")
        let retry = add("重试恢复系统设置", action: #selector(retryRelease), role: .retry, to: menu)
        retry.setAccessibilityIdentifier("data-annotation-id=si.ka.menu-recovery")
        add("自动模式", action: #selector(toggleAutomatic), role: .automatic, to: menu)
        add("保持 30 分钟", action: #selector(manual30), role: .manual30, to: menu)
        add("保持 1 小时", action: #selector(manual60), role: .manual60, to: menu)
        add("暂停 30 分钟", action: #selector(togglePause), role: .pause, to: menu)
        add("停止并恢复", action: #selector(stop), to: menu)
        menu.addItem(.separator())
        information("", .sources)
        add("管理保持唤醒…", action: #selector(manage), to: menu)
        menu.autoenablesItems = false
        refresh(menu)
    }
    @discardableResult private func add(_ title: String, action: Selector, role: Role? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let role { item.tag = role.rawValue }
        item.target = self; menu.addItem(item); return item
    }
    @objc private func toggleMaster() { service.setEnabled(!service.engine.enabled) }
    @objc private func retryRelease() { service.retryRelease() }
    @objc private func toggleAutomatic() { service.automatic(!(service.engine.enabled && service.engine.mode == .automatic)) }
    @objc private func manual30() { service.manual(minutes: 30) }
    @objc private func manual60() { service.manual(minutes: 60) }
    @objc private func togglePause() { service.pause() }
    @objc private func stop() { service.stop() }
    @objc private func manage() { service.openSettings?() }
}
