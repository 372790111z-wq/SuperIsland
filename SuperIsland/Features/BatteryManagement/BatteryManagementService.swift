import AppKit
import Combine
import IOKit.pwr_mgt
import ServiceManagement

enum BatteryMetric: String, Codable, CaseIterable, Identifiable {
    case temperature, power, averagePower, health, cycles, remaining, voltage, current, rawCharge, adapter, systemInput, systemLoad
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperature: return "温度"
        case .power: return "电池功率"
        case .averagePower: return "平均功率"
        case .health: return "最大容量"
        case .cycles: return "循环次数"
        case .remaining: return "预计时间"
        case .voltage: return "电压"
        case .current: return "电池电流"
        case .rawCharge: return "硬件电量"
        case .adapter: return "适配器额定"
        case .systemInput: return "系统输入"
        case .systemLoad: return "系统报告负载"
        }
    }
    func value(_ s: BatteryTelemetry, averagePower: BatteryPowerWindow.Summary? = nil) -> String {
        switch self {
        case .temperature: return s.temperature.map { String(format: "%.1f°C", $0) } ?? "—"
        case .power: return s.power.map { String(format: "%+.1f W", $0) } ?? "—"
        case .averagePower: return averagePower.map { String(format: "%+.1f W", $0.watts) } ?? "—"
        case .health: return s.health.map { String(format: "%.1f%%", $0) } ?? "—"
        case .cycles: return s.cycles.map(String.init) ?? "—"
        case .remaining: return s.minutesRemaining.map { "\($0 / 60)时\($0 % 60)分" } ?? "—"
        case .voltage: return s.voltage.map { String(format: "%.2f V", $0) } ?? "—"
        case .current: return s.current.map { String(format: "%+.2f A", $0) } ?? "—"
        case .rawCharge: return s.hardwarePercentage.map { String(format: "%.1f%%", $0) } ?? "—"
        case .adapter: return s.adapterWatts.map { "\($0) W" } ?? "—"
        case .systemInput: return s.reportedPower?.formatted(.input) ?? "—"
        case .systemLoad: return s.reportedPower?.formatted(.load) ?? "—"
        }
    }
}

enum BatteryIndicatorStyle: String, Codable, CaseIterable, Identifiable {
    case native, colored, ios
    var id: String { rawValue }
    var title: String { self == .native ? "macOS 原生" : self == .colored ? "macOS 彩色" : "iOS 样式" }
}
enum BatteryRightClickAction: String, Codable, CaseIterable, Identifiable {
    case settings, same, pause
    var id: String { rawValue }
    var title: String { self == .settings ? "电池设置" : self == .same ? "同左击" : "暂停 / 恢复充电" }
}
enum BatteryEntryStatistic: String, Codable, CaseIterable, Identifiable {
    case percentage, state, temperature, capacity, cycles, voltage, power, remaining, adapter, system, hardware, condition
    var id: String { rawValue }
    var metric: BatteryMetric? {
        switch self {
        case .temperature: return .temperature
        case .capacity: return .health
        case .cycles: return .cycles
        case .voltage: return .voltage
        case .power: return .power
        case .remaining: return .remaining
        case .adapter: return .adapter
        case .system: return .systemLoad
        case .hardware: return .rawCharge
        default: return nil
        }
    }
    var title: String { metric?.title ?? (self == .percentage ? "百分比" : self == .state ? "控制状态" : "macOS 条件") }
}
enum BatteryPopupField: String, Codable, CaseIterable, Identifiable {
    case percentage, source, trend, controls
    var id: String { rawValue }
    var title: String {
        switch self { case .percentage: return "电量"; case .source: return "电源"; case .trend: return "趋势"; case .controls: return "快捷控制" }
    }
}
enum BatteryRuntimeMode: String, Codable, CaseIterable, Identifiable {
    case average, instant
    var id: String { rawValue }
    var title: String { self == .average ? "平均功耗" : "即时功耗" }
}

struct BatteryDisplayPreferences: Codable, Equatable {
    var metrics: [BatteryMetric] = [.temperature, .power, .health, .cycles, .remaining, .voltage]
    var showPercentage = true
    var showAtStartup = true
    var backgroundMetrics = false
    var includeBackgroundProcesses = false
    var consumerThreshold = 0.0
    var opacity = 1.0
    var rightClickSettings = true
    var indicatorStyle = BatteryIndicatorStyle.native
    var entryStatistics: [BatteryEntryStatistic] = [.percentage, .state]
    var indicatorSpacing = 5
    var refreshInterval = 5
    var rightClickAction = BatteryRightClickAction.settings
    var popupFields = BatteryPopupField.allCases
    var reduceTransparency = false
    var runtimeMode = BatteryRuntimeMode.average
    var averageMinutes = 15
    var screenSleepPolicy = BatteryDisplaySleepPolicy.system
    var lockOnLidClose = false
    var pauseOnExit = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case metrics, showPercentage, showAtStartup, backgroundMetrics, includeBackgroundProcesses, consumerThreshold, opacity, rightClickSettings
        case indicatorStyle, entryStatistics, indicatorSpacing, refreshInterval, rightClickAction, popupFields, reduceTransparency, runtimeMode, averageMinutes, screenSleepPolicy, lockOnLidClose, pauseOnExit
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = try c.decodeIfPresent([BatteryMetric].self, forKey: .metrics) ?? metrics
        showPercentage = try c.decodeIfPresent(Bool.self, forKey: .showPercentage) ?? showPercentage
        showAtStartup = try c.decodeIfPresent(Bool.self, forKey: .showAtStartup) ?? showAtStartup
        backgroundMetrics = try c.decodeIfPresent(Bool.self, forKey: .backgroundMetrics) ?? backgroundMetrics
        includeBackgroundProcesses = try c.decodeIfPresent(Bool.self, forKey: .includeBackgroundProcesses) ?? includeBackgroundProcesses
        consumerThreshold = try c.decodeIfPresent(Double.self, forKey: .consumerThreshold) ?? consumerThreshold
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        rightClickSettings = try c.decodeIfPresent(Bool.self, forKey: .rightClickSettings) ?? rightClickSettings
        indicatorStyle = try c.decodeIfPresent(BatteryIndicatorStyle.self, forKey: .indicatorStyle) ?? indicatorStyle
        entryStatistics = try c.decodeIfPresent([BatteryEntryStatistic].self, forKey: .entryStatistics) ?? entryStatistics
        indicatorSpacing = try c.decodeIfPresent(Int.self, forKey: .indicatorSpacing) ?? indicatorSpacing
        refreshInterval = try c.decodeIfPresent(Int.self, forKey: .refreshInterval) ?? refreshInterval
        rightClickAction = try c.decodeIfPresent(BatteryRightClickAction.self, forKey: .rightClickAction) ?? (rightClickSettings ? .settings : .same)
        popupFields = try c.decodeIfPresent([BatteryPopupField].self, forKey: .popupFields) ?? popupFields
        reduceTransparency = try c.decodeIfPresent(Bool.self, forKey: .reduceTransparency) ?? reduceTransparency
        runtimeMode = try c.decodeIfPresent(BatteryRuntimeMode.self, forKey: .runtimeMode) ?? runtimeMode
        averageMinutes = try c.decodeIfPresent(Int.self, forKey: .averageMinutes) ?? averageMinutes
        screenSleepPolicy = try c.decodeIfPresent(BatteryDisplaySleepPolicy.self, forKey: .screenSleepPolicy) ?? screenSleepPolicy
        lockOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lockOnLidClose) ?? lockOnLidClose
        pauseOnExit = try c.decodeIfPresent(Bool.self, forKey: .pauseOnExit) ?? pauseOnExit
        normalize()
    }
    mutating func normalize() {
        func unique<T: Hashable>(_ values: [T]) -> [T] { var seen = Set<T>(); return values.filter { seen.insert($0).inserted } }
        metrics = Array(unique(metrics).prefix(6))
        entryStatistics = unique(entryStatistics); popupFields = unique(popupFields)
        opacity = opacity.isFinite ? min(1, max(0.5, opacity)) : 1
        consumerThreshold = consumerThreshold.isFinite ? max(0, consumerThreshold) : 0
        indicatorSpacing = min(20, max(0, indicatorSpacing)); refreshInterval = min(20, max(2, refreshInterval))
        if ![5, 15, 30, 60].contains(averageMinutes) { averageMinutes = 15 }
    }
    mutating func resetEntryDisplay() { entryStatistics = [.percentage, .state]; indicatorStyle = .native }
}

@MainActor
final class BatteryManagementService: ObservableObject {
    static let shared = BatteryManagementService()
    @Published private(set) var preferences: BatteryControlPreferences
    @Published private(set) var display: BatteryDisplayPreferences
    @Published private(set) var telemetry = BatteryTelemetry.read()
    @Published private(set) var averagePower: BatteryPowerWindow.Summary?
    @Published private(set) var reportedPower = BatteryReportedPowerWindow.State()
    @Published private(set) var report = BatteryControlReport()
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var authorizing = false
    @Published private(set) var mode = BatteryControlMode.automatic
    @Published private(set) var notice: String?
    @Published private(set) var displaySleepStatus: String?
    @Published private(set) var exitPreparationInProgress = false
    @Published var focusLowLimit = false
    var openSettings: () -> Void = {}
    var presentNotice: () -> Void = {}
    var dismissNotice: () -> Void = {}
    private let defaults: UserDefaults
    private let client: any BatteryManagementTransport
    private let telemetryReader: () -> BatteryTelemetry
    private let conflictChecker: () -> String?
    private let authorizationOpener: () -> Void
    private let scheduleStarter: () -> Void
    private let displaySleepController: BatteryDisplaySleepController
    private let lidLockController: BatteryLidLockController
    private var lidLockObservation: AnyCancellable?
    private var authorizationError: String?
    private let owner = UUID()
    private var started = false
    private var automaticStartupDeferred = false
    private var automationSessionActive = false
    private var userDisabledControl = false
    private var schedulesStarted = false
    private var wantsEnabled = false
    private var mayOwnOverrides = false
    private var revision: UInt64 = 0
    private var dirty = false
    private var sleeping = false
    private var faultAcknowledged = false
    private var acknowledgedFaultID: UUID?
    private var terminationRequested = false
    private var exitHoldTransferred = false
    private var exitPreparationCancelled = false
    private let exitPreparationTimeout: TimeInterval
    private var dischargeTarget: Int?
    private var operationID = UUID()
    private var controlSubmissionCount: UInt64 = 0
    private var calibrationCommand: BatteryCalibrationCommand?
    private var heartbeat: Timer?
    private var metricsToken: ModuleRefreshToken?
    private var powerWindow = BatteryPowerWindow(window: 3600, maximumGap: 45)
    private var reportedPowerWindow = BatteryReportedPowerWindow()
    private var visibleMetricSurfaces: Set<String> = []
    private var metricWindowObservations: [NSObjectProtocol] = []
    private var observations: [NSObjectProtocol] = []
    private var assertion: IOPMAssertionID = 0
    private var assertionHeld = false

    init(defaults: UserDefaults = .standard, client: (any BatteryManagementTransport)? = nil,
         telemetryReader: @escaping () -> BatteryTelemetry = BatteryTelemetry.read,
         conflictChecker: (() -> String?)? = nil, authorizationOpener: (() -> Void)? = nil,
         scheduleStarter: (() -> Void)? = nil, displaySleepController: BatteryDisplaySleepController? = nil,
         lidLockController: BatteryLidLockController? = nil, exitPreparationTimeout: TimeInterval = 150) {
        self.defaults = defaults
        self.exitPreparationTimeout = exitPreparationTimeout.isFinite ? max(0, min(150, exitPreparationTimeout)) : 150
        self.client = client ?? BatteryManagementClient.defaultTransport()
        self.telemetryReader = telemetryReader
        self.conflictChecker = conflictChecker ?? Self.conflictingApplication
        self.authorizationOpener = authorizationOpener ?? { SMAppService.openSystemSettingsLoginItems() }
        self.scheduleStarter = scheduleStarter ?? { BatteryScheduleService.shared.start() }
        self.displaySleepController = displaySleepController ?? BatteryDisplaySleepController(keepAwakeConflict: {
            let keepAwake = KeepAwakeService.shared
            guard !keepAwake.releasePending, keepAwake.runtimeError == nil else { return .unknown }
            guard keepAwake.actualHold else { return .none }
            switch keepAwake.preferences.screen {
            case .awake: return .awake
            case .off: return .off
            case .system: return .none
            }
        })
        self.lidLockController = lidLockController ?? BatteryLidLockController()
        let stored = defaults.data(forKey: "batteryManagement.preferences").flatMap { try? JSONDecoder().decode(BatteryControlPreferences.self, from: $0) }
        preferences = stored.flatMap { (try? $0.validate()) != nil ? $0 : nil } ?? .init()
        display = defaults.data(forKey: "batteryManagement.display").flatMap { try? JSONDecoder().decode(BatteryDisplayPreferences.self, from: $0) } ?? .init()
        display.normalize()
        lidLockObservation = self.lidLockController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    var lidLockAvailabilityReason: String? { BatteryLidLockSystem.platformReason }
    var lidLockStatus: String {
        if let status = lidLockController.status { return status }
        if let reason = lidLockController.availabilityReason { return reason }
        if !display.lockOnLidClose { return "合盖锁屏未开启。" }
        if !enabled || automaticStartupDeferred || sleeping { return "仅保存锁屏偏好；充电控制启用且系统醒着时等待新的合盖事件。" }
        return "等待本轮新的合盖事件；锁定后需本人解锁，仍按系统设置睡眠。"
    }
    var authorizationDescription: String {
        let statusDescription: String = {
        switch client.authorization {
        case .enabled: return "系统已授权"
        case .requiresApproval: return "等待系统批准后台辅助程序"
        case .notFound: return client.helperBundled ? "辅助程序等待注册或系统后台批准" : "当前应用包未包含有效辅助程序"
        default: return "尚未注册电池辅助程序"
        }
        }()
        return (authorizationError.map { $0 + "；" } ?? "") + statusDescription
    }
    var canControl: Bool { enabled && report.available && report.capabilities.backend != nil && !busy && !authorizing && !terminationRequested && telemetry.hasBattery && !report.recoveryPending }
    var reviewTrialActive: Bool { report.nativeCutoffReviewTrial == true }
    var canPauseCharging: Bool {
        guard canControl, telemetry.adapterPresent else { return false }
        return report.capabilities.canPause(at: telemetry.level)
    }
    var sailingConfigurationWarning: String? {
        if reviewTrialActive { return "本验证包未开放航海模式；已保存的规则可以关闭。" }
        guard report.capabilities.minimumDischargeTarget != nil else { return "主动放电能力尚未确认，暂不能开启航海模式。" }
        let lower = minimumDischargeTarget
        guard preferences.sailingLower >= lower, preferences.sailingLower < preferences.limit else {
            return "航海下限需至少\(lower)%且低于长期上限。请先调整上限和下限，再开启；原值已保留。"
        }
        return nil
    }
    func scheduleCapabilityWarning(_ task: BatteryScheduledTask) -> String? {
        BatteryPreferenceCompatibility.taskWarning(task, report: report, preferences: preferences)
    }
    private var incompatiblePreferencesMessage: String? {
        if report.capabilityDetectionPending {
            return "电池控制能力尚未确认；已保留全部规则，请重新检查，无需关闭已保存的功能。"
        }
        let issues = BatteryPreferenceCompatibility.issues(preferences, report: report)
        guard !issues.isEmpty else { return nil }
        return "充电控制保持关闭；仍有当前不可执行的已保存规则：" + issues.map(\.title).joined(separator: "、") + "。请逐项关闭或调整后再启用。"
    }
    var minimumDischargeTarget: Int {
        report.capabilities.minimumDischargeTarget ?? report.minimumSupportedLimit
    }

    var pauseRefreshPending: Bool {
        mode == .paused && report.mode == .paused && report.pauseRefreshOperationID == operationID
            && report.leaseHeldByRequester == true && report.requiresManualRetry != true && report.lastFailure == nil
    }
    var canCancelPauseRefresh: Bool {
        pauseRefreshPending && mayOwnOverrides && enabled && !busy && !authorizing && !terminationRequested
    }
    var canResumeCharging: Bool {
        mode == .paused && ((canControl && telemetry.adapterPresent) || canCancelPauseRefresh)
    }

    var canStopDischarge: Bool {
        guard mode == .discharge else { return false }
        if canControl && telemetry.adapterPresent { return true }
        return enabled && report.available && !busy && !authorizing && !terminationRequested
            && !report.recoveryPending && mayOwnOverrides && report.leaseHeldByRequester == true
            && report.ownedAdapterCutoff == true && report.cutoffPhase == .discharging
    }

    var calibrationActive: Bool { report.calibration?.isActive == true || calibrationCommand != nil }
    var canStartCalibration: Bool { canControl && mode == .automatic && !calibrationActive && report.capabilities.calibration && telemetry.adapterPresent }

    // UI-only context: a requested discharge can precede the helper's reply
    // and OS power notification. This must never authorize hardware control.
    var suppressesEnergySuggestions: Bool {
        guard mayOwnOverrides || enabled || busy else { return false }
        return mode == .discharge || calibrationActive || report.ownedAdapterCutoff == true || report.cutoffPhase != nil
    }

    static func makeLeaseHeartbeat(interval: TimeInterval = 15, tick: @escaping @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        timer.tolerance = min(1, interval / 10)
        // Keep the timer eligible during native menu and modal event tracking.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func start(automaticallyEnable: Bool = true) {
        guard !terminationRequested else { return }
        if started {
            // Only an explicit reopen may consume a deferred background launch.
            // A manual on/off choice clears the deferral, so reopening cannot
            // undo the user's choice later in the same process.
            guard automaticallyEnable, automaticStartupDeferred else { return }
            automaticStartupDeferred = false
            wantsEnabled = true
            revision &+= 1
            synchronizeAtStartup()
            return
        }
        started = true
        wantsEnabled = automaticallyEnable
        automaticStartupDeferred = !automaticallyEnable
        // Control renewal must not be throttled by an invisible island's UI policy.
        // It is active only while a real helper lease may be owned.
        heartbeat = Self.makeLeaseHeartbeat { [weak self] in
            Task { @MainActor in
                guard let self, self.wantsEnabled || self.mayOwnOverrides || self.displaySleepController.isHoldingDisplay else { return }
                self.queueSync()
            }
        }
        registerMetricsRefresh()
        // A retained AppKit settings window may close or minimize without
        // removing its SwiftUI content. Track the real window as well as the
        // mounted battery pane so closed windows cannot keep polling alive.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            metricWindowObservations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard self?.visibleMetricSurfaces.contains("settings") == true else { return }
                    ModuleRefreshScheduler.shared.refreshScheduling()
                }
            })
        }
        let nc = NSWorkspace.shared.notificationCenter
        observations.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.updateDisplaySleep(); self?.queueSync() }
        })
        observations.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false; self.queueSync()
                if self.schedulesStarted { BatteryScheduleService.shared.evaluate() }
            }
        })
        guard automaticallyEnable else {
            refreshTelemetry()
            report.message = "后台查询启动；充电控制尚未启用"
            return
        }
        synchronizeAtStartup()
    }
    private func startSchedulesIfNeeded() {
        guard !schedulesStarted else { return }
        schedulesStarted = true
        scheduleStarter()
    }
    private func synchronizeAtStartup() {
        Task {
            await synchronize()
            notice = report.message + " · 长期上限\(preferences.limit)%"
            if display.showAtStartup { presentNotice() }
        }
    }
    func refreshTelemetry() {
        telemetry = telemetryReader()
        powerWindow.record(telemetry)
        reportedPowerWindow.record(telemetry.reportedPower)
        reportedPower = reportedPowerWindow.state
        averagePower = powerWindow.summary(at: telemetry.timestamp, window: Double(display.averageMinutes * 60))
    }
    func setMetricsVisible(_ surface: String, visible: Bool) {
        let wasVisible = !visibleMetricSurfaces.isEmpty
        if visible { visibleMetricSurfaces.insert(surface) }
        else { visibleMetricSurfaces.remove(surface) }
        if started && wasVisible != !visibleMetricSurfaces.isEmpty { ModuleRefreshScheduler.shared.refreshScheduling() }
    }
    private var metricsVisibleOutsideIsland: Bool {
        guard visibleMetricSurfaces.contains("settings"), let window = AppDelegate.managedSettingsWindow else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    private var metricsVisible: Bool {
        metricsVisibleOutsideIsland || (!visibleMetricSurfaces.isDisjoint(with: ["island", "compact", "expanded"]) && AppState.shared.isModuleVisibleForRefresh(.builtIn(.battery)))
    }
    func updatePreferences(_ mutation: (inout BatteryControlPreferences) -> Void) throws {
        guard !authorizing, !terminationRequested else { throw BatteryControlError.unavailable("正在刷新辅助程序或退出，请稍后设置。") }
        guard !calibrationActive else { throw BatteryControlError.conflict("校准期间不能修改充电偏好，请先停止校准并确认恢复。") }
        var next = preferences; mutation(&next); try next.validate()
        do {
            try BatteryPreferenceCompatibility.validate(next, report: report)
        } catch {
            // A partially repaired stored configuration must never renew a
            // lease. Only explicit removal of incompatible fields is saved.
            guard !enabled, !busy, !mayOwnOverrides, !report.recoveryPending,
                  BatteryPreferenceCompatibility.isPartialRepair(from: preferences, to: next, report: report) else { throw error }
            preferences = next
            defaults.set(try JSONEncoder().encode(next), forKey: "batteryManagement.preferences")
            setEnabled(false)
            return
        }
        preferences = next
        defaults.set(try JSONEncoder().encode(next), forKey: "batteryManagement.preferences")
        queueSync()
    }
    private func registerMetricsRefresh() {
        metricsToken = ModuleRefreshScheduler.shared.register(id: "battery.management.metrics", name: "Battery instrument snapshot", module: .builtIn(.battery), policy: .interval(Double(display.refreshInterval), tolerance: 1), enabled: { [weak self] in
            guard let self else { return false }
            return self.metricsVisible || self.display.backgroundMetrics
        }, visibleOutsideIsland: { [weak self] in self?.metricsVisibleOutsideIsland == true }) { [weak self] in self?.refreshTelemetry() }
    }
    func updateDisplay(_ mutation: (inout BatteryDisplayPreferences) -> Void) {
        let previous = display
        var next = display; mutation(&next); next.normalize()
        display = next
        if !next.pauseOnExit { cancelExitPreparation() }
        defaults.set(try? JSONEncoder().encode(next), forKey: "batteryManagement.display")
        averagePower = powerWindow.summary(at: telemetry.timestamp, window: Double(next.averageMinutes * 60))
        updateDisplaySleep()
        if started && previous.refreshInterval != next.refreshInterval { registerMetricsRefresh() }
        else if previous.backgroundMetrics != next.backgroundMetrics { ModuleRefreshScheduler.shared.refreshScheduling() }
    }
    var runtimeMinutes: Int? { BatteryRuntimeEstimate.minutes(snapshot: telemetry, mode: display.runtimeMode, average: averagePower) }
    func metricTitle(_ metric: BatteryMetric) -> String { metric == .remaining ? (telemetry.charging ? "预计充满时间" : "预计电池续航") : metric.title }
    func metricValue(_ metric: BatteryMetric) -> String {
        guard metric == .remaining else { return metric.value(telemetry, averagePower: averagePower) }
        return runtimeMinutes.map { "约\($0 / 60)时\($0 % 60)分" } ?? "—"
    }
    func entryValue(_ item: BatteryEntryStatistic) -> String {
        if let metric = item.metric { return metricValue(metric) }
        if item == .percentage { return telemetry.level.map { "\($0)%" } ?? "—" }
        if item == .state { return enabled ? (calibrationActive ? "校准" : mode.title) : "控制未启用" }
        return "—"
    }
    var averagePowerDescription: String {
        averagePower.map { "最近\(display.averageMinutes)分钟内实测时间加权，实际覆盖\(Int($0.coverage))秒；充入为正、放出为负。" }
            ?? "正在收集实测样本，至少覆盖10秒才显示；缺失读数、休眠或采样间隔超过45秒后重新收集。"
    }
    func setEnabled(_ value: Bool) {
        guard !authorizing, !terminationRequested else { return }
        // An explicit UI action can reach this service before shell bootstrap.
        // Install its observer/heartbeat lifecycle without a default write first.
        if !started { start(automaticallyEnable: false) }
        automaticStartupDeferred = false
        userDisabledControl = !value
        wantsEnabled = value
        if value { faultAcknowledged = true; operationID = UUID(); acknowledgedFaultID = nil }
        else { faultAcknowledged = false; acknowledgedFaultID = nil }
        if !value { enabled = false; report.recoveryPending = mayOwnOverrides; mode = .automatic; dischargeTarget = nil; calibrationCommand = nil }
        updateDisplaySleep()
        queueSync()
    }
    func authorize() async {
        guard !authorizing else { return }
        authorizing = true
        let resumeRequested = wantsEnabled
        var restored = false
        wantsEnabled = false; enabled = false; revision &+= 1; dirty = true
        authorizationError = nil
        updateDisplaySleep()
        do {
            guard client.helperBundled else { throw BatteryControlError.unavailable("当前应用包缺少电池辅助程序，不能申请授权。") }
            let deadline = Date().addingTimeInterval(12)
            while busy && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard !busy else { throw BatteryControlError.recovery("等待原控制恢复超时，未刷新系统注册。") }
            await synchronize()
            guard !mayOwnOverrides else { throw BatteryControlError.recovery("原控制恢复尚未确认，未注销辅助程序。") }
            restored = true
            try await client.register()
            report.message = authorizationDescription
        } catch {
            authorizationError = "系统授权未完成：" + error.localizedDescription
            report.message = authorizationError!
        }
        // On macOS27, a pending BTM approval can first throw EPERM and report
        // notFound before it settles to requiresApproval. Keep the actual
        // error visible, and provide the system approval page for that case.
        if client.helperBundled && client.authorization != .enabled { authorizationOpener() }
        if restored { wantsEnabled = resumeRequested && !terminationRequested }
        authorizing = false
        queueSync()
    }
    func openSystemAuthorization() { authorizationOpener() }
    /// Explicit UI inspection must also work while control is off. Background
    /// retries retain their existing no-query behavior for an idle controller.
    func recheckStatus() async {
        guard !busy, !authorizing, !terminationRequested else { return }
        if wantsEnabled || mayOwnOverrides {
            retry()
            return
        }
        guard client.authorization == .enabled else {
            report.available = false
            report.message = authorizationDescription
            return
        }
        busy = true
        let inspectedRevision = revision
        defer {
            busy = false
            if dirty { queueSync() }
        }
        refreshTelemetry()
        let result: Result<(Bool, BatteryControlReport), Error>
        do { result = .success(try await client.call(.refreshCapabilities)) }
        catch { result = .failure(error) }
        guard inspectedRevision == revision, !authorizing, !terminationRequested else { return }
        switch result {
        case .success(let (success, response)):
            guard success, response.protocolVersion == BatteryControlReport.currentProtocolVersion else {
                report.available = false
                report.message = "辅助程序查询失败或版本不兼容。"
                return
            }
            report = response
            report.message += "；充电控制保持关闭"
        case .failure(let error):
            report.available = false
            report.message = error.localizedDescription
        }
    }

    private var capabilityRefreshRequested = false
    func retry() {
        guard !authorizing, !terminationRequested else { return }
        capabilityRefreshRequested = true
        if report.requiresManualRetry == true { faultAcknowledged = true; wantsEnabled = true; operationID = UUID(); acknowledgedFaultID = nil }
        queueSync()
    }
    func closeNotice() { notice = nil; dismissNotice() }
    var shouldPrepareForTermination: Bool { mayOwnOverrides || authorizing }
    func prepareForTermination() async -> Bool {
        if exitHoldTransferred { return true }
        if display.pauseOnExit && enabled && wantsEnabled {
            return await prepareExitHoldForTermination()
        }
        terminationRequested = true
        updateDisplaySleep()
        wantsEnabled = false; revision &+= 1; dirty = true
        let deadline = Date().addingTimeInterval(12)
        while (busy || authorizing) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard !busy, !authorizing else { terminationRequested = false; report.message = "等待辅助程序恢复超时，请稍后重试退出。"; return false }
        repeat {
            await synchronize()
            if !mayOwnOverrides { return true }
            guard report.cutoffPhase == .restoring, Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        terminationRequested = false
        return false
    }

    func cancelExitPreparation() {
        guard exitPreparationInProgress else { return }
        exitPreparationCancelled = true
        report.message = "正在取消退出停充并恢复原设置。"
    }

    private func prepareExitHoldForTermination() async -> Bool {
        guard report.capabilities.exitHoldSupported, !calibrationActive else {
            report.message = calibrationActive ? "请先停止校准并确认恢复，再准备退出停充。" : "当前通道不能交接退出停充，请关闭该选项后重试退出。"
            return false
        }
        terminationRequested = true; revision &+= 1
        exitPreparationInProgress = true; exitPreparationCancelled = false
        updateDisplaySleep()
        openSettings()
        let deadline = ProcessInfo.processInfo.systemUptime + exitPreparationTimeout
        while (busy || authorizing) && ProcessInfo.processInfo.systemUptime < deadline && !exitPreparationCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !busy, !authorizing else {
            terminationRequested = false; exitPreparationInProgress = false
            report.message = "前一项控制尚未结束，未交接退出停充。"
            return false
        }
        busy = true; wantsEnabled = false; enabled = false; dirty = false
        defer { busy = false; exitPreparationInProgress = false; dirty = false }
        do {
            while ProcessInfo.processInfo.systemUptime < deadline && !exitPreparationCancelled && !Task.isCancelled {
                // Even a lost reply may have transferred control; retain the
                // recovery obligation until a release explicitly succeeds.
                mayOwnOverrides = true
                let (accepted, response) = try await client.prepareExitHold(owner: owner)
                report = response
                guard accepted, response.protocolVersion == BatteryControlReport.currentProtocolVersion,
                      !response.recoveryPending else { throw BatteryControlError.recovery(response.message) }
                if !exitPreparationCancelled && !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                   response.exitHoldReady == true, response.leaseHeldByRequester == true {
                    exitHoldTransferred = true
                    return true
                }
                report.message = "正在确认退出停充，等待系统更新电池读数；可取消退出并恢复。"
                try await Task.sleep(for: .milliseconds(500))
            }
            throw BatteryControlError.unavailable(exitPreparationCancelled || Task.isCancelled ? "已取消退出停充。" : "退出停充未在限定时间内确认。")
        } catch {
            let reason = error.localizedDescription
            _ = await releaseExitHold()
            report.message = reason + "；" + report.message
            terminationRequested = false
            return false
        }
    }

    /// Another module can veto the same quit request after the battery handoff.
    /// Undo the handoff rather than leaving a detached hold in a running app.
    func cancelPreparedTermination() async {
        guard exitHoldTransferred else { terminationRequested = false; return }
        busy = true
        _ = await releaseExitHold()
        terminationRequested = false; busy = false; dirty = false
    }

    @discardableResult
    private func releaseExitHold() async -> Bool {
        exitHoldTransferred = false
        do {
            let (success, response) = try await client.call(.release(owner))
            report = response
            guard success, response.protocolVersion == BatteryControlReport.currentProtocolVersion,
                  !response.recoveryPending else { throw BatteryControlError.recovery(response.message) }
            mayOwnOverrides = false
            report.message = "退出停充已撤回，原设置已确认恢复。"
            return true
        } catch {
            mayOwnOverrides = true
            report.message = "退出已取消，恢复尚未确认；请在电池设置重试恢复。"
            return false
        }
    }

    func execute(mode requested: BatteryControlMode, target: Int? = nil) async throws -> String {
        guard !busy else { throw BatteryControlError.unavailable("正在同步上一项请求，请稍后。") }
        guard !calibrationActive else { throw BatteryControlError.conflict("校准正在进行，请先停止校准并确认恢复，再切换模式。") }
        guard requested != .topUp || !reviewTrialActive else {
            throw BatteryControlError.unavailable("本验证包未开放临时充满；未提交控制请求。")
        }
        guard requested != .discharge || !reviewTrialActive || target == 80 else {
            throw BatteryControlError.invalid("本验证包的手动放电目标固定为80%；未提交控制请求。")
        }
        // Cancelling an accepted pulse is release-only, including while input
        // is absent/unknown. Never issue a fresh automatic lease in this path.
        if requested == .automatic && canCancelPauseRefresh {
            wantsEnabled = false; enabled = false; userDisabledControl = true
            automaticStartupDeferred = false; faultAcknowledged = false; acknowledgedFaultID = nil
            mode = .automatic; dischargeTarget = nil; calibrationCommand = nil
            revision &+= 1; dirty = true
            let cancelledOperation = operationID
            await synchronize()
            guard operationID == cancelledOperation, mode == .automatic, !wantsEnabled, !enabled else {
                throw BatteryControlError.conflict("取消期间控制请求已改变，请以当前状态为准。")
            }
            guard report.requiresManualRetry != true else { throw BatteryControlError.recovery(report.message) }
            report.message = mayOwnOverrides || report.recoveryPending || report.leaseHeldByRequester != false
                ? "已取消暂停，正在恢复原设置；充电控制保持关闭，恢复完成后可重新启用。"
                : "已取消暂停并恢复原设置；充电控制已关闭，可重新启用。"
            return report.message
        }
        refreshTelemetry()
        guard (canControl && telemetry.adapterPresent) || (requested == .automatic && canStopDischarge) else {
            throw BatteryControlError.unavailable(telemetry.adapterPresent ? report.message : "请先接入电源适配器。")
        }
        // Returning an owned adapter cutoff to automatic is a recovery action;
        // retain its dedicated path even if current telemetry is incomplete.
        if requested != .automatic {
            try preferences.validate()
            try BatteryPreferenceCompatibility.validate(preferences, report: report)
            if requested == .paused && !report.capabilities.canPause(at: telemetry.level) {
                throw BatteryControlError.unavailable("当前电量或控制通道无法确认临时暂停充电，未执行。")
            }
        }
        if requested == .discharge {
            guard let target, (minimumDischargeTarget...99).contains(target) else {
                throw BatteryControlError.unavailable("当前控制通道的放电目标需为\(minimumDischargeTarget)–99%；未提交控制请求。")
            }
            guard report.capabilities.minimumDischargeTarget != nil, target >= 20, target < (telemetry.level ?? 0) else {
                throw BatteryControlError.invalid("设备需支持主动放电，目标不低于20%，且低于当前电量。")
            }
        }
        mode = requested; dischargeTarget = target; operationID = UUID(); revision &+= 1
        await synchronize()
        guard enabled, report.available || (requested == .paused && pauseRefreshPending) else { throw BatteryControlError.unavailable(report.message) }
        return report.message
    }
    /// A write Intent may launch without the normal Dock/Finder startup.
    /// Inspect before its explicit action, but never apply a default automatic
    /// request or start unrelated scheduled work as a side effect.
    func performAutomation(_ action: @MainActor () async throws -> String) async throws -> String {
        guard !automationSessionActive, !authorizing, !terminationRequested else {
            throw BatteryControlError.conflict("已有自动化请求、授权或退出流程，请稍后。")
        }
        guard !userDisabledControl else {
            throw BatteryControlError.unavailable("本次运行已手动关闭充电控制；请在电池设置中重新启用。")
        }
        if !started { start(automaticallyEnable: false) }
        guard wantsEnabled || automaticStartupDeferred else {
            throw BatteryControlError.unavailable("本次运行已手动关闭充电控制；请在电池设置中重新启用。")
        }
        automationSessionActive = true
        defer { automationSessionActive = false }
        let deadline = Date().addingTimeInterval(6)
        while busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard !busy else { throw BatteryControlError.unavailable("等待上一项控制请求超时，未提交自动化。") }
        guard wantsEnabled || automaticStartupDeferred else {
            throw BatteryControlError.unavailable("充电控制已手动关闭，未提交自动化。")
        }
        let previousEnabled = enabled, previousWantsEnabled = wantsEnabled
        let previousSubmissions = controlSubmissionCount
        if !canControl {
            refreshTelemetry()
            guard telemetry.hasBattery, client.authorization == .enabled else {
                throw BatteryControlError.unavailable("需要内置电池和已批准的辅助程序；未提交自动化。")
            }
            if let conflict = conflictChecker() { throw BatteryControlError.conflict("检测到\(conflict)正在运行；未提交自动化。") }
            let inspectedRevision = revision
            let (_, observed) = try await client.call(.inspect)
            guard revision == inspectedRevision, !authorizing, !terminationRequested,
                  wantsEnabled || automaticStartupDeferred else {
                throw BatteryControlError.conflict("控制选择已改变，未提交自动化。")
            }
            guard observed.protocolVersion == BatteryControlReport.currentProtocolVersion,
                  observed.available, !observed.recoveryPending,
                  observed.requiresManualRetry != true else {
                throw BatteryControlError.unavailable(observed.message + "；请在电池设置中检查后重试。")
            }
            report = observed
            enabled = true; wantsEnabled = true
        }
        do {
            let result = try await action()
            if !previousWantsEnabled, controlSubmissionCount == previousSubmissions {
                wantsEnabled = previousWantsEnabled; enabled = previousEnabled
            }
            return result
        } catch {
            // A validation failure must not leave a cold-started controller
            // enabled and let its next heartbeat apply unrelated defaults.
            if !previousWantsEnabled {
                wantsEnabled = false; enabled = previousEnabled
                if mayOwnOverrides { await synchronize() }
            }
            throw error
        }
    }

    var scheduleObservation: BatteryScheduleObservation {
        .init(operationID: operationID, preferences: preferences, telemetry: telemetry, report: report, enabled: enabled)
    }

    func setLimitFromAutomation(_ value: Int) async throws -> String {
        try await changeFromAutomation { $0.limit = value }
    }
    func changeFromAutomation(_ mutation: (inout BatteryControlPreferences) -> Void) async throws -> String {
        guard !busy, canControl else { throw BatteryControlError.unavailable(report.message) }
        try updatePreferences(mutation)
        // queueSync owns the resulting revision; wait until its drain finishes.
        while busy || dirty { try await Task.sleep(for: .milliseconds(50)) }
        guard enabled, report.available else { throw BatteryControlError.unavailable(report.message) }
        return report.message
    }
    func startCalibration() async throws -> String {
        guard !busy, !calibrationActive else { throw BatteryControlError.conflict("已有控制请求或校准会话，请等待完成或先停止校准。") }
        refreshTelemetry()
        guard canStartCalibration else { throw BatteryControlError.unavailable("校准需要已接电、控制就绪且支持完整充放电及恢复的设备。") }
        mode = .automatic; dischargeTarget = nil
        calibrationCommand = .start(UUID()); revision &+= 1
        await synchronize()
        guard enabled, report.available, report.calibration?.isActive == true else {
            calibrationCommand = nil
            throw BatteryControlError.unavailable(report.message)
        }
        return report.message
    }
    func cancelCalibration() async throws -> String {
        guard !busy, let status = report.calibration, status.isActive else {
            throw BatteryControlError.unavailable("当前没有可停止的校准，或正在同步控制请求。")
        }
        calibrationCommand = .cancel(status.id); revision &+= 1
        await synchronize()
        guard report.available, !report.recoveryPending else { throw BatteryControlError.recovery(report.message) }
        return report.message
    }
    func setHighPowerFromAutomation(_ scope: BatteryEnergyScope) async throws -> String {
        try await changeFromAutomation { $0.highPowerScope = scope }
    }

    private func queueSync() {
        revision &+= 1; dirty = true
        guard !busy, !authorizing else { return }
        Task { await self.synchronize() }
    }
    private func synchronize() async {
        guard !exitHoldTransferred else { return }
        guard !busy else { dirty = true; return }
        busy = true
        repeat {
            dirty = false
            let currentRevision = revision
            refreshTelemetry()
            do {
                if !wantsEnabled {
                    if mayOwnOverrides {
                        let (success, response) = try await client.call(.release(owner))
                        report = response
                        mayOwnOverrides = response.leaseHeldByRequester ?? !success
                        guard success else { throw BatteryControlError.recovery(response.message) }
                        mayOwnOverrides = false
                    } else { report.message = incompatiblePreferencesMessage ?? "本次运行已关闭充电控制" }
                    enabled = false
                } else {
                    guard telemetry.hasBattery else { throw BatteryControlError.unavailable("没有内置电池；充电控制未启用。") }
                    if let conflict = conflictChecker() { throw BatteryControlError.conflict("检测到\(conflict)正在运行；未启用充电控制，请先在该工具中停止控制。") }
                    guard client.authorization == .enabled else {
                        throw BatteryControlError.unavailable(authorizationDescription + "；尚未启用充电控制")
                    }
                    authorizationError = nil
                    if !mayOwnOverrides || faultAcknowledged {
                        let refresh = capabilityRefreshRequested && !mayOwnOverrides
                        capabilityRefreshRequested = false
                        let (_, response) = try await client.call(refresh ? .refreshCapabilities : .inspect)
                        // Inspection may yield to shutdown, manual off, or a newer request.
                        // Re-enter the loop before acquiring any new hardware ownership.
                        guard currentRevision == revision, wantsEnabled, !terminationRequested else {
                            dirty = true
                            continue
                        }
                        report = response
                        guard response.protocolVersion == BatteryControlReport.currentProtocolVersion, response.controlEpoch != nil else {
                            throw BatteryControlError.unavailable("当前运行的电池辅助程序版本不兼容；请更新并重新启用后台辅助程序，尚未发起控制。")
                        }
                        if response.requiresManualRetry == true && !faultAcknowledged {
                            wantsEnabled = false
                            throw BatteryControlError.recovery(response.message + "；请手动重新检查后再启用。")
                        }
                        guard response.available, !response.recoveryPending else { throw BatteryControlError.recovery(response.message) }
                        if faultAcknowledged {
                            acknowledgedFaultID = response.manualRetryID
                            guard response.requiresManualRetry != true || acknowledgedFaultID != nil else {
                                throw BatteryControlError.recovery("后台故障记录尚未可确认，未发起新控制。")
                            }
                        }
                    }
                    let request = BatteryControlRequest(owner: owner, preferences: preferences, mode: mode, dischargeTarget: dischargeTarget, sleeping: sleeping, calibration: calibrationCommand, operationID: operationID, controlEpoch: report.controlEpoch, acknowledgedFaultID: acknowledgedFaultID)
                    guard preferences.highPowerScope == .never || report.highPowerSupported == true else {
                        throw BatteryControlError.unavailable("该辅助程序或设备无法确认高功率能力；没有提交控制请求。")
                    }
                    mayOwnOverrides = true
                    controlSubmissionCount &+= 1
                    let (success, response) = try await client.call(.renew(request))
                    mayOwnOverrides = response.leaseHeldByRequester ?? true
                    // Faults are authoritative even when a newer UI edit raced
                    // the response; no subsequent heartbeat may acknowledge one.
                    if response.requiresManualRetry == true {
                        report = response; wantsEnabled = false; faultAcknowledged = false; acknowledgedFaultID = nil
                        throw BatteryControlError.recovery(response.message)
                    }
                    // A late response must not replace a newer UI preference.
                    if currentRevision == revision {
                        report = response; mode = response.mode
                        if mode != .discharge { dischargeTarget = nil }
                        if response.calibration?.isActive != true { calibrationCommand = nil }
                    }
                    guard success else { throw BatteryControlError.unavailable(response.message) }
                    faultAcknowledged = false; acknowledgedFaultID = nil
                    if currentRevision == revision && wantsEnabled { enabled = true }
                }
            } catch {
                faultAcknowledged = false; acknowledgedFaultID = nil
                if report.requiresManualRetry == true { wantsEnabled = false; faultAcknowledged = false; acknowledgedFaultID = nil }
                calibrationCommand = nil
                enabled = false; report.available = false; report.message = error.localizedDescription
                report.recoveryPending = mayOwnOverrides
                if mayOwnOverrides {
                    do {
                        let (success, response) = try await client.call(.release(owner))
                        mayOwnOverrides = response.leaseHeldByRequester ?? !success
                        report.recoveryPending = mayOwnOverrides
                        report.cutoffPhase = response.cutoffPhase
                        if !success { report.message += "；" + response.message }
                    } catch { report.message += "；恢复尚未确认，辅助程序将按45秒租约尝试恢复" }
                }
            }
            updateAwakeAssertion()
        } while dirty
        busy = false
        updateDisplaySleep()
        // Startup inspection/renewal must finish before a due schedule runs.
        // Background query launches never reach this with control enabled.
        if started && enabled && !automaticStartupDeferred && !automationSessionActive { startSchedulesIfNeeded() }
    }
    private func updateAwakeAssertion() {
        let needed = BatteryAwakePolicy.needed(enabled: enabled, telemetry: telemetry,
            preferences: preferences, mode: mode, calibrationActive: calibrationActive)
        if needed && !assertionHeld {
            assertionHeld = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "SuperIsland battery charging" as CFString, &assertion) == kIOReturnSuccess
        } else if !needed && assertionHeld { IOPMAssertionRelease(assertion); assertionHeld = false }
    }
    private func updateDisplaySleep() {
        let active = enabled && !automaticStartupDeferred && report.available && !report.recoveryPending && !authorizing && !terminationRequested
        displaySleepController.update(active: active,
                                      awake: !sleeping, policy: display.screenSleepPolicy)
        lidLockController.update(active: active, awake: !sleeping, enabled: display.lockOnLidClose)
        if let reason = displaySleepController.reason { displaySleepStatus = reason }
        else if display.screenSleepPolicy == .system { displaySleepStatus = "显示屏策略：跟随系统" }
        else if !active || sleeping { displaySleepStatus = "仅保存显示偏好；充电控制启用且系统醒着时执行。" }
        else if displaySleepController.isHoldingDisplay {
            displaySleepStatus = display.screenSleepPolicy == .never ? "本电池模块的显示常亮断言已启用。" : "正在等待所选空闲时长，持有本电池模块自己的显示断言。"
        }
        else { displaySleepStatus = "已选择\(display.screenSleepPolicy.title)，等待空闲条件；未确认屏幕已关闭。" }
    }
    func shutdown() {
        terminationRequested = true
        wantsEnabled = false; enabled = false; automaticStartupDeferred = false
        revision &+= 1; dirty = true
        observations.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observations.removeAll()
        lidLockController.shutdown()
        lidLockObservation?.cancel(); lidLockObservation = nil
        displaySleepController.shutdown()
        heartbeat?.invalidate(); heartbeat = nil
        ModuleRefreshScheduler.shared.unregister(metricsToken); metricsToken = nil
        metricWindowObservations.forEach(NotificationCenter.default.removeObserver)
        metricWindowObservations.removeAll()
        if assertionHeld { IOPMAssertionRelease(assertion); assertionHeld = false }
        // Termination cannot wait for an asynchronous reply. The independent
        // daemon owns the durable journal and expires this process's lease.
        // A normal quit sends release as a best-effort fast path as well.
        if mayOwnOverrides && !exitHoldTransferred { Task { _ = try? await client.call(.release(owner)) } }
    }
    private static func conflictingApplication() -> String? {
        let known: Set<String> = ["com.apphousekitchen.aldente-pro", "com.davidwernhart.AlDente", "com.micropixels.BatFi", "com.batterytoolkit.app", "com.az-code-lab.ampere"]
        return NSWorkspace.shared.runningApplications.first { known.contains($0.bundleIdentifier ?? "") }?.localizedName
    }
#if DEBUG
    func attemptStartupForTesting() async {
        wantsEnabled = true
        await synchronize()
    }
#endif
}
