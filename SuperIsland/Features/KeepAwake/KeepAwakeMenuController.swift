import AppKit
import Combine

@MainActor
final class KeepAwakeMenuController: NSObject, NSMenuDelegate {
    private let service = KeepAwakeService.shared
    private var updateObserver: AnyCancellable?
    private weak var stateItem: NSMenuItem?
    private weak var detailItem: NSMenuItem?
    private weak var automaticItem: NSMenuItem?
    private weak var pauseItem: NSMenuItem?
    private weak var sourcesItem: NSMenuItem?
    override init() {
        super.init()
        // Debounce on DispatchQueue so open/tracking menus also receive updates.
        updateObserver = service.objectWillChange.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLiveValues() }
    }
    private func refreshLiveValues() {
        stateItem?.title = service.decision.title
        detailItem?.title = service.decision.detail
        automaticItem?.state = service.engine.enabled && service.engine.mode == .automatic ? .on : .off
        pauseItem?.title = service.engine.pauseDeadline.map { $0 > KeepAwakeClock.now() } == true ? "结束暂停" : "暂停 30 分钟"
        pauseItem?.isEnabled = service.engine.enabled
        sourcesItem?.title = "\(service.decision.runningSources) 个运行来源 · \(service.lidStatus)"
    }
    func item() -> NSMenuItem {
        let item = NSMenuItem(title: "保持唤醒", action: nil, keyEquivalent: "")
        item.setAccessibilityIdentifier("data-annotation-id=si.ka.menu")
        let menu = NSMenu(); menu.delegate = self; item.submenu = menu
        populate(menu); return item
    }
    func menuWillOpen(_ menu: NSMenu) { service.tick(); populate(menu) }
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: service.decision.title, action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title); stateItem = title
        let detail = NSMenuItem(title: service.decision.detail, action: nil, keyEquivalent: "")
        detail.isEnabled = false; menu.addItem(detail); detailItem = detail
        menu.addItem(.separator())
        let automatic = add("自动模式", action: #selector(toggleAutomatic), to: menu)
        automaticItem = automatic
        automatic.state = service.engine.enabled && service.engine.mode == .automatic ? .on : .off
        add("保持 30 分钟", action: #selector(manual30), to: menu)
        add("保持 1 小时", action: #selector(manual60), to: menu)
        let paused = service.engine.pauseDeadline.map { $0 > KeepAwakeClock.now() } == true
        let pause = add(paused ? "结束暂停" : "暂停 30 分钟", action: #selector(togglePause), to: menu)
        pause.isEnabled = service.engine.enabled; pauseItem = pause
        add("停止并恢复", action: #selector(stop), to: menu)
        menu.addItem(.separator())
        let status = NSMenuItem(title: "\(service.decision.runningSources) 个运行来源 · \(service.lidStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status); sourcesItem = status
        add("管理保持唤醒…", action: #selector(manage), to: menu)
        menu.autoenablesItems = false
    }
    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }
    @objc private func toggleAutomatic() { service.automatic(!(service.engine.enabled && service.engine.mode == .automatic)) }
    @objc private func manual30() { service.manual(minutes: 30) }
    @objc private func manual60() { service.manual(minutes: 60) }
    @objc private func togglePause() { service.pause() }
    @objc private func stop() { service.stop() }
    @objc private func manage() { service.openSettings?() }
}
