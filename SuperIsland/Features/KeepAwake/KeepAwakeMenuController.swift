import AppKit
import Combine

@MainActor
final class KeepAwakeMenuController: NSObject, NSMenuDelegate {
    private let service: KeepAwakeService
    private var updateObserver: AnyCancellable?
    private weak var stateItem: NSMenuItem?
    private weak var detailItem: NSMenuItem?
    private weak var automaticItem: NSMenuItem?
    private weak var pauseItem: NSMenuItem?
    private weak var masterItem: NSMenuItem?
    private weak var retryItem: NSMenuItem?
    private var enableItems: [NSMenuItem] = []
    private weak var sourcesItem: NSMenuItem?
    init(service: KeepAwakeService = .shared) {
        self.service = service
        super.init()
        // Debounce on DispatchQueue so open/tracking menus also receive updates.
        updateObserver = service.objectWillChange.debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLiveValues() }
    }
    private func refreshLiveValues() {
        masterItem?.state = service.engine.enabled ? .on : .off
        masterItem?.isEnabled = service.canEnable
        retryItem?.isHidden = !service.releasePending
        retryItem?.isEnabled = !service.lid.busy
        for item in enableItems { item.isEnabled = service.canEnable }
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
        let master = add("启用保持唤醒", action: #selector(toggleMaster), to: menu)
        master.state = service.engine.enabled ? .on : .off
        master.isEnabled = service.canEnable; masterItem = master
        master.setAccessibilityIdentifier("data-annotation-id=si.ka.menu-master")
        let retry = add("重试恢复系统设置", action: #selector(retryRelease), to: menu)
        retry.isHidden = !service.releasePending; retry.isEnabled = !service.lid.busy; retryItem = retry
        retry.setAccessibilityIdentifier("data-annotation-id=si.ka.menu-recovery")
        let automatic = add("自动模式", action: #selector(toggleAutomatic), to: menu)
        automaticItem = automatic
        automatic.state = service.engine.enabled && service.engine.mode == .automatic ? .on : .off
        let manual30 = add("保持 30 分钟", action: #selector(manual30), to: menu)
        let manual60 = add("保持 1 小时", action: #selector(manual60), to: menu)
        enableItems = [automatic, manual30, manual60]
        for item in enableItems { item.isEnabled = service.canEnable }
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
    @objc private func toggleMaster() { service.setEnabled(!service.engine.enabled) }
    @objc private func retryRelease() { service.retryRelease() }
    @objc private func toggleAutomatic() { service.automatic(!(service.engine.enabled && service.engine.mode == .automatic)) }
    @objc private func manual30() { service.manual(minutes: 30) }
    @objc private func manual60() { service.manual(minutes: 60) }
    @objc private func togglePause() { service.pause() }
    @objc private func stop() { service.stop() }
    @objc private func manage() { service.openSettings?() }
}
