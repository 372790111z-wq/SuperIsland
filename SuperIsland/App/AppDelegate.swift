import AppKit
import AVFoundation
import SwiftUI
import Carbon.HIToolbox
import Combine
import Darwin
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct RuntimeDefaultsSnapshot: Equatable {
        let showMenuBarIcon: Bool
        let nowPlayingEnabled: Bool
        let volumeHUDEnabled: Bool
        let batteryEnabled: Bool
        let shelfEnabled: Bool
        let connectivityEnabled: Bool
        let calendarEnabled: Bool
        let weatherEnabled: Bool
        let notificationsEnabled: Bool
        let teleprompterEnabled: Bool
        let energyMode: String
        let disableBackgroundExtensionRefresh: Bool

        init(defaults: UserDefaults = .standard) {
            func bool(_ key: String, default defaultValue: Bool) -> Bool {
                guard defaults.object(forKey: key) != nil else { return defaultValue }
                return defaults.bool(forKey: key)
            }

            showMenuBarIcon = bool("general.showMenuBarIcon", default: true)
            nowPlayingEnabled = bool("module.nowPlaying.enabled", default: true)
            volumeHUDEnabled = bool("module.volumeHUD.enabled", default: true)
            batteryEnabled = bool("module.battery.enabled", default: true)
            shelfEnabled = bool("module.shelf.enabled", default: true)
            connectivityEnabled = bool("module.connectivity.enabled", default: true)
            calendarEnabled = bool("module.calendar.enabled", default: true)
            weatherEnabled = bool("module.weather.enabled", default: true)
            notificationsEnabled = bool("module.notifications.enabled", default: true)
            teleprompterEnabled = bool("module.teleprompter.enabled", default: false)
            energyMode = defaults.string(forKey: "energy.mode") ?? EnergyMode.smart.rawValue
            disableBackgroundExtensionRefresh = bool(
                "energy.disableBackgroundExtensionRefresh",
                default: false
            )
        }
    }

    private static let linearExtensionID = "superisland.linear-mentions"
    private static let linearOAuthStoreKey = "extensions.\(linearExtensionID).store.oauth"
    private static let lastFmExtensionID = "superisland.lastfm-scrobbler"
    private static let lastFmOAuthStoreKey = "extensions.\(lastFmExtensionID).store.oauth"
    private var islandWindowController: IslandWindowController?
    private var zilanSuppressionReceiver: ZilanSuppressionReceiver?
    private var onboardingWindowController: OnboardingWindowController?
    private var updateWindowController: UpdateWindowController?
    private var updateCancellable: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var menuBarDefaultsObserver: NSObjectProtocol?
    private var settingsResetObservers: [NSObjectProtocol] = []
    private var runtimeDefaultsSnapshot: RuntimeDefaultsSnapshot?
    private var powerStateObserver: NSObjectProtocol?
    private var quitHotkeyMonitor: Any?
    private var deferredTerminationTask: Task<Void, Never>?
    private var terminationSignalSource: DispatchSourceSignal?
    private let terminationSignalScheduler = WE1TerminationSignalScheduler()
    private var didBootstrapApp = false
    private var didInitializeNowPlayingManager = false
    private static var fallbackSettingsWindowController: NSWindowController?
    private static let settingsInitialContentSize = NSSize(width: 960, height: 680)
    private static let settingsMinimumContentSize = NSSize(width: 800, height: 560)

    private static var isWE1DebugBundle: Bool {
        Bundle.main.bundleIdentifier == "com.workview.SuperIsland.WE1Debug"
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        // The WE1 package is an isolated local test harness. It must not report
        // production analytics or claim the production superisland:// URL
        // handler while both builds are installed side by side.
        if !Self.isWE1DebugBundle {
            Analytics.start()
            Analytics.track("app_launched", properties: [
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            ])
            registerURLHandler()
        } else {
            installWE1TerminationSignalHandler()
        }
        installQuitHotkeyMonitor()

        // Do not inherit or present production onboarding in the isolated
        // window-enhancement test bundle. Its only startup surface is the WE1
        // settings page, where permissions are requested deliberately.
        if Self.isWE1DebugBundle {
            bootstrapApp()
            return
        }

        // defaults write com.workview.SuperIsland "debug.alwaysShowOnboarding" -bool true
        let shouldShowOnboarding = !AppState.shared.onboardingCompleted || AppState.shared.debugAlwaysShowOnboarding
        if shouldShowOnboarding {
            showOnboardingIfNeeded()
        } else {
            bootstrapApp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        zilanSuppressionReceiver?.stop()
        WindowEnhancementController.shared.stop()
        if didInitializeNowPlayingManager {
            NowPlayingManager.shared.shutdownExternalProcesses()
        }
        if let provider = ExtensionOAuthCoordinator.shared.activeProvider {
            ExtensionOAuthCoordinator.shared.cancel(provider)
        }
        ExtensionManager.shared.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningUnitTests else { return .terminateNow }
        if Self.isWE1DebugBundle {
            terminationSignalScheduler.terminationDidBegin()
        }
        guard deferredTerminationTask == nil else { return .terminateLater }
        guard WindowEnhancementController.shared.requiresTerminationPreparation else {
            return .terminateNow
        }

        deferredTerminationTask = Task { @MainActor [weak self] in
            let safeToTerminate = await WindowEnhancementController.shared.prepareForTermination()
            self?.deferredTerminationTask = nil
            sender.reply(toApplicationShouldTerminate: safeToTerminate)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        AppState.shared.setAppActive(true)
        WindowEnhancementController.shared.refreshSystemIntegrations()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        AppState.shared.setAppActive(false)
    }

    deinit {
        terminationSignalSource?.cancel()
        if let quitHotkeyMonitor {
            NSEvent.removeMonitor(quitHotkeyMonitor)
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }

    /// Local package replacement tools commonly stop a test build with
    /// SIGTERM. AppKit does not promise to call `applicationWillTerminate` for
    /// that signal, which previously left the MediaRemote Perl stream adopted
    /// by launchd. Route SIGTERM through normal application termination only
    /// in the isolated WE1 harness; production keeps its existing lifecycle.
    private func installWE1TerminationSignalHandler() {
        guard terminationSignalSource == nil else { return }
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.terminationSignalScheduler.request(
                isTerminationDeferred: { [weak self] in
                    self == nil || self?.deferredTerminationTask != nil
                },
                terminate: { [weak self] in
                    guard let self else { return }
                    // Stop children idempotently before normal termination.
                    // The run-loop handoff lets deferred MainActor recovery
                    // progress while AppKit waits for its termination reply.
                    if self.didInitializeNowPlayingManager {
                        NowPlayingManager.shared.shutdownExternalProcesses()
                    }
                    NSApp.terminate(nil)
                }
            )
        }
        terminationSignalSource = source
        source.resume()
    }

    private func bootstrapApp() {
        guard !didBootstrapApp else { return }
        didBootstrapApp = true
        defer { startZilanSuppressionReceiver() }

        // The WE1 bundle remains isolated from production analytics, updates,
        // URL handling, and extension subprocesses, but its island must use the
        // real SuperIsland content and interaction state machine. Window
        // enhancement is an added capability, not a replacement island UI.
        if Self.isWE1DebugBundle {
            setupIslandWindow()
            // The debug bundle exposes the original General settings, so its
            // menu-bar switch must remain a real local shell behavior. This
            // does not enable analytics, URL handling, extension discovery or
            // update checks, which stay gated below.
            applyMenuBarVisibility()
            observeMenuBarSetting()
            observePowerState()
            initializeManagers()
            DispatchQueue.main.async {
                Self.showSettingsWindow(initialPane: .windowEnhancement)
            }
            return
        }

        setupIslandWindow()
        applyMenuBarVisibility()
        observeMenuBarSetting()
        observePowerState()
        initializeManagers()
    }

    private func startZilanSuppressionReceiver() {
        guard !Self.isRunningUnitTests, zilanSuppressionReceiver == nil else { return }
        let receiver = ZilanSuppressionReceiver(acquire: { [weak self] lease in
            let bundles: Set<String> = ["com.workview.SuperIsland", "com.workview.SuperIsland.WE1Debug"]
            let processes = NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
                guard let bundle = application.bundleIdentifier, bundles.contains(bundle) else { return nil }
                return application.processIdentifier
            }
            guard let self, let controller = self.islandWindowController,
                  Self.isSoleZilanSuppressionInstance(processIdentifiers: processes, ownPID: getpid()) else { return false }
            return ZilanSuppressionAcquisition.acquire([
                .init(acquire: { AppState.shared.beginZilanSuppression(lease) },
                      rollback: { AppState.shared.endZilanSuppression(requestID: lease.requestID) }),
                .init(acquire: { WindowEnhancementController.shared.beginZilanSuppression(requestID: lease.requestID) },
                      rollback: { WindowEnhancementController.shared.endZilanSuppression(requestID: lease.requestID) }),
                .init(acquire: { controller.beginZilanSuppression(requestID: lease.requestID) },
                      rollback: { _ = controller.endZilanSuppression(requestID: lease.requestID) }),
            ])
        }, release: { [weak self] requestID in
            let requiresHoverExit = self?.islandWindowController?.endZilanSuppression(requestID: requestID) ?? false
            AppState.shared.endZilanSuppression(requestID: requestID, requiresHoverExit: requiresHoverExit)
            WindowEnhancementController.shared.endZilanSuppression(requestID: requestID)
        })
        do {
            try receiver.start()
            zilanSuppressionReceiver = receiver
        } catch {
            // Receiver failure leaves the normal island unchanged. Zilan's
            // existing protocol gate will refuse an unprotected menu click.
            NSLog("Zilan compatibility receiver unavailable: %@", String(describing: error))
        }
    }

    static func isSoleZilanSuppressionInstance(processIdentifiers: [pid_t], ownPID: pid_t) -> Bool {
        ownPID > 0 && processIdentifiers == [ownPID]
    }

    private func showOnboardingIfNeeded() {
        applyMenuBarVisibility()
        observeMenuBarSetting()

        // LSUIElement apps can't reliably bring windows to the front.
        // Temporarily become a regular app so the onboarding window appears.
        NSApp.setActivationPolicy(.regular)

        guard onboardingWindowController == nil else {
            onboardingWindowController?.show()
            return
        }

        onboardingWindowController = OnboardingWindowController { [weak self] in
            self?.completeOnboarding()
        } onOpenSettings: {
            Self.showSettingsWindow()
        }
        onboardingWindowController?.show()
    }

    private func completeOnboarding() {
        AppState.shared.onboardingCompleted = true
        onboardingWindowController?.close()
        onboardingWindowController = nil

        // Revert to agent app (no dock icon) now that onboarding is done.
        NSApp.setActivationPolicy(.accessory)
        bootstrapApp()
    }

    // MARK: - Manager Initialization

    private func initializeManagers() {
        let state = AppState.shared

        // Eagerly initialize all enabled managers so they start monitoring
        if state.nowPlayingEnabled {
            _ = NowPlayingManager.shared
            didInitializeNowPlayingManager = true
        }
        applyVolumeHUDSetting()
        if state.batteryEnabled { _ = BatteryManager.shared }
        if state.connectivityEnabled {
            _ = WiFiManager.shared
            if PermissionsManager.shared.check(.bluetooth) {
                _ = BluetoothManager.shared
            }
        }
        if state.calendarEnabled, PermissionsManager.shared.check(.calendar) {
            _ = CalendarManager.shared
        }
        // The isolated WE1 harness must not request unrelated Location access
        // at launch. Its real weather page remains available and will construct
        // WeatherManager only when the user deliberately opens that module.
        if state.weatherEnabled, !Self.isWE1DebugBundle {
            _ = WeatherManager.shared
        }
        if state.notificationsEnabled {
            _ = NotificationManager.shared
        }
        // WE1 Debug is a window-enhancement harness. Keep the Teleprompter UI
        // available, but do not initialize Speech or request unrelated privacy
        // access during launch merely because an old local preference is on.
        // Production behavior is unchanged; WE1 can initialize the manager
        // when the user deliberately enters the Teleprompter flow.
        if state.teleprompterEnabled, !Self.isWE1DebugBundle {
            _ = TeleprompterManager.shared
            let permissions = PermissionsManager.shared
            if permissions.microphoneAuthorizationStatus() == .notDetermined ||
                permissions.speechRecognitionAuthorizationStatus() == .notDetermined {
                permissions.requestTeleprompterWordTrackingAccess()
            }
        }

        // WE1 uses its own extension settings and storage. Newly restored
        // extensions stay off until explicitly enabled in the existing UI.
        let extensions = ExtensionManager.shared
        extensions.discoverExtensions()
        extensions.activateDiscoveredExtensions()
        rebuildStatusMenu()
        observeSettingsReset()
        state.refreshEnergyState()

        UpdateChecker.shared.checkIfDue()
        observeUpdateState()
        WindowEnhancementController.shared.start()
    }

    private func observeSettingsReset() {
        guard settingsResetObservers.isEmpty else { return }
        settingsResetObservers.append(NotificationCenter.default.addObserver(
            forName: .superIslandSettingsWillReset, object: nil, queue: .main
        ) { _ in
            // Deactivation can save extension state: finish it before the
            // persistent domain is removed by the confirmed reset action.
            MainActor.assumeIsolated {
                if let provider = ExtensionOAuthCoordinator.shared.activeProvider {
                    ExtensionOAuthCoordinator.shared.cancel(provider)
                }
                ExtensionManager.shared.shutdown()
                let state = AppState.shared
                if case .extension_ = state.activeModule {
                    state.dismiss()
                    state.activeModule = nil
                    state.previousModule = nil
                }
                if case .module(.extension_) = state.fullExpandedSelectedTab {
                    state.showHomeTab()
                }
            }
        })
        settingsResetObservers.append(NotificationCenter.default.addObserver(
            forName: .superIslandSettingsDidReset, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let extensions = ExtensionManager.shared
                extensions.discoverExtensions()
                extensions.activateDiscoveredExtensions()
                self.runtimeDefaultsSnapshot = RuntimeDefaultsSnapshot()
                self.applyMenuBarVisibility()
                self.applyVolumeHUDSetting()
                self.rebuildStatusMenu()
                AppState.shared.refreshEnergyState()
                ModuleRefreshScheduler.shared.refreshScheduling()
            }
        })
    }

    private func observeUpdateState() {
        updateCancellable = UpdateChecker.shared.$checkState
            .compactMap { state -> (String, URL, URL?)? in
                if case .updateAvailable(let version, let releaseURL, let downloadURL) = state {
                    return (version, releaseURL, downloadURL)
                }
                return nil
            }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] version, releaseURL, downloadURL in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.showUpdateDialog(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
                }
            }
    }

    private func showUpdateDialog(version: String, releaseURL: URL, downloadURL: URL?) {
        let controller = UpdateWindowController(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
        updateWindowController = controller
        controller.show()
    }

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleIncomingURL(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func installQuitHotkeyMonitor() {
        guard quitHotkeyMonitor == nil else { return }

        quitHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            QuitHotkeyGuard.shouldBlock(event) ? nil : event
        }
    }

    @objc
    private func handleIncomingURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor?) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        handleOAuthCallback(url: url)
    }

    private func handleOAuthCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "superisland",
              components.host?.lowercased() == "auth",
              components.path.lowercased() == "/callback" else {
            return
        }

        var queryItems: [String: String] = [:]
        for item in components.queryItems ?? [] {
            queryItems[item.name.lowercased()] = item.value ?? ""
        }

        let provider = queryItems["provider"]?.lowercased() ?? ""
        let routing: (extensionID: String, storeKey: String, label: String)?
        switch provider {
        case "linear":
            routing = (Self.linearExtensionID, Self.linearOAuthStoreKey, "Linear")
        case "lastfm":
            routing = (Self.lastFmExtensionID, Self.lastFmOAuthStoreKey, "Last.fm")
        default:
            routing = nil
        }
        guard let routing else {
            return
        }

        let accessToken = queryItems["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            ExtensionLogger.shared.log(routing.extensionID, .warning, "Received \(routing.label) OAuth callback without access token")
            return
        }

        let expiresIn = Int(queryItems["expires_in"] ?? "") ?? 0
        var payload: [String: Any] = [
            "provider": provider,
            "accessToken": accessToken,
            "access_token": accessToken,
            "tokenType": queryItems["token_type"] ?? "Bearer",
            "token_type": queryItems["token_type"] ?? "Bearer",
            "expiresIn": expiresIn,
            "expires_in": expiresIn,
            "scope": queryItems["scope"] ?? "",
            "receivedAt": Int(Date().timeIntervalSince1970),
            "callbackURL": url.absoluteString
        ]

        if let username = queryItems["username"], !username.isEmpty {
            payload["username"] = username
        }
        if let name = queryItems["name"], !name.isEmpty, payload["username"] == nil {
            payload["username"] = name
        }

        if provider == "lastfm" {
            if let apiKey = queryItems["api_key"], !apiKey.isEmpty {
                payload["apiKey"] = apiKey
                payload["api_key"] = apiKey
            }
            if let apiSecret = queryItems["api_secret"], !apiSecret.isEmpty {
                payload["apiSecret"] = apiSecret
                payload["api_secret"] = apiSecret
            }
        }

        UserDefaults.standard.set(payload as NSDictionary, forKey: routing.storeKey)
        UserDefaults.standard.synchronize()

        let extensions = ExtensionManager.shared
        if extensions.runtimes[routing.extensionID] == nil {
            extensions.activate(extensionID: routing.extensionID)
        }
        extensions.scheduleImmediateRefresh(extensionID: routing.extensionID)
        ExtensionLogger.shared.log(routing.extensionID, .info, "Stored \(routing.label) OAuth token from callback")
    }

    // MARK: - Island Window

    private func setupIslandWindow(contentMode: IslandContentMode = .production) {
        islandWindowController = IslandWindowController(contentMode: contentMode)
        islandWindowController?.showIsland()
    }

    // MARK: - Menu Bar

    private func applyMenuBarVisibility() {
        if AppState.shared.showMenuBarIcon {
            installStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let appName = Self.isWE1DebugBundle ? "SuperIsland WE1" : "SuperIsland"
            button.image = NSImage(systemSymbolName: Constants.menuBarIconName, accessibilityDescription: appName)
            button.toolTip = appName
        }

        item.menu = buildStatusMenu()
        statusItem = item
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        item.menu = buildStatusMenu()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "正在播放", action: #selector(showNowPlaying)))
        menu.addItem(makeMenuItem(title: "电池", action: #selector(showBattery)))
        menu.addItem(NSMenuItem.separator())

        let modulesItem = NSMenuItem(title: "模块", action: nil, keyEquivalent: "")
        let modulesMenu = NSMenu()

        for module in ModuleType.allCases {
            let moduleItem = NSMenuItem(title: module.displayName, action: #selector(toggleModule(_:)), keyEquivalent: "")
            moduleItem.target = self
            moduleItem.representedObject = module.rawValue
            moduleItem.state = AppState.shared.isModuleEnabled(module) ? .on : .off
            moduleItem.image = NSImage(systemSymbolName: module.iconName, accessibilityDescription: module.displayName)
            modulesMenu.addItem(moduleItem)
        }

        let extensionModules = ExtensionManager.shared.installed
            .filter { !$0.capabilities.notificationFeed }

        if !extensionModules.isEmpty {
            modulesMenu.addItem(.separator())
            for manifest in extensionModules {
                let extensionItem = NSMenuItem(title: manifest.name, action: #selector(toggleExtension(_:)), keyEquivalent: "")
                extensionItem.target = self
                extensionItem.representedObject = manifest.id
                extensionItem.state = ExtensionManager.shared.runtimes[manifest.id] != nil ? .on : .off
                extensionItem.image = menuIconImage(for: manifest)
                modulesMenu.addItem(extensionItem)
            }
        }

        modulesItem.submenu = modulesMenu
        menu.addItem(modulesItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "退出 SuperIsland", action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    @MainActor
    private func menuIconImage(for manifest: ExtensionManifest) -> NSImage? {
        guard let image = manifest.iconImage?.copy() as? NSImage else { return nil }
        image.isTemplate = false
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func observeMenuBarSetting() {
        guard menuBarDefaultsObserver == nil else { return }
        runtimeDefaultsSnapshot = RuntimeDefaultsSnapshot()
        menuBarDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let nextSnapshot = RuntimeDefaultsSnapshot()
                guard nextSnapshot != self.runtimeDefaultsSnapshot else { return }
                self.runtimeDefaultsSnapshot = nextSnapshot

                self.applyMenuBarVisibility()
                self.applyVolumeHUDSetting()
                ModuleRefreshScheduler.shared.refreshScheduling()
                ExtensionManager.shared.syncRuntimeEnergyState()
            }
        }
    }

    private func applyVolumeHUDSetting() {
        let enabled = AppState.shared.volumeHUDEnabled
        if enabled {
            _ = VolumeManager.shared
        }
        MediaKeyInterceptor.shared.apply(enabled: enabled)
    }

    private func observePowerState() {
        guard powerStateObserver == nil else { return }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppState.shared.refreshEnergyState()
            }
        }
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Menu Actions

    @objc private func showNowPlaying() {
        AppState.shared.showHUD(module: .nowPlaying, autoDismiss: false)
    }

    @objc private func showBattery() {
        AppState.shared.showHUD(module: .battery, autoDismiss: false)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let module = ModuleType(rawValue: rawValue) else { return }

        let newState = !AppState.shared.isModuleEnabled(module)
        switch module {
        case .nowPlaying: AppState.shared.nowPlayingEnabled = newState
        case .volumeHUD:
            AppState.shared.volumeHUDEnabled = newState
            applyVolumeHUDSetting()
        case .battery: AppState.shared.batteryEnabled = newState
        case .shelf: AppState.shared.shelfEnabled = newState
        case .connectivity: AppState.shared.connectivityEnabled = newState
        case .calendar: AppState.shared.calendarEnabled = newState
        case .weather: AppState.shared.weatherEnabled = newState
        case .notifications: AppState.shared.notificationsEnabled = newState
        case .teleprompter:
            AppState.shared.teleprompterEnabled = newState
            if newState {
                PermissionsManager.shared.requestTeleprompterWordTrackingAccess()
            }
        }
        sender.state = newState ? .on : .off
        rebuildStatusMenu()
    }

    @objc private func toggleExtension(_ sender: NSMenuItem) {
        guard let extensionID = sender.representedObject as? String else { return }

        if ExtensionManager.shared.runtimes[extensionID] != nil {
            ExtensionManager.shared.disableByUser(extensionID: extensionID)
        } else {
            ExtensionManager.shared.activate(extensionID: extensionID)
        }

        sender.state = ExtensionManager.shared.runtimes[extensionID] != nil ? .on : .off
        rebuildStatusMenu()
    }

    @objc private func openSettings() {
        // NSStatusItem menu actions run while the menu is still tracking.
        // Defer window presentation to the next runloop tick so it reliably appears.
        DispatchQueue.main.async {
            Self.showSettingsWindow()
        }
    }

    static func showSettingsWindow(initialPane: SettingsPane = .general) {
        // Avoid opening the SwiftUI Settings scene via AppKit selectors in menu-bar mode.
        // macOS may reject those calls with a "use SettingsLink" warning.
        showFallbackSettingsWindow(initialPane: initialPane)
    }

    private static func showFallbackSettingsWindow(initialPane: SettingsPane = .general) {
        if let window = fallbackSettingsWindowController?.window {
            configureSettingsWindow(window, restoreInitialSizeIfNeeded: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .superIslandSettingsPaneRequested,
                object: initialPane.rawValue
            )
            return
        }

        let rootView = SettingsView(initialPane: initialPane)
            .environmentObject(AppState.shared)
        let hostingController = NSHostingController(rootView: rootView)
        // AppKit owns the settings-window frame. Do not let the SwiftUI
        // controller feed its transient fitting size back into NSWindow.
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = Self.isWE1DebugBundle ? "SuperIsland WE1 设置" : "SuperIsland 设置"
        configureSettingsWindow(window, restoreInitialSizeIfNeeded: true)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        fallbackSettingsWindowController = NSWindowController(window: window)
        fallbackSettingsWindowController?.showWindow(nil)
    }

    private static func configureSettingsWindow(
        _ window: NSWindow,
        restoreInitialSizeIfNeeded: Bool
    ) {
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.contentMinSize = settingsMinimumContentSize

        guard restoreInitialSizeIfNeeded else { return }
        let currentContentSize = window.contentLayoutRect.size
        guard currentContentSize.width < settingsMinimumContentSize.width ||
                currentContentSize.height < settingsMinimumContentSize.height else { return }

        window.setContentSize(settingsInitialContentSize)
        window.center()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
