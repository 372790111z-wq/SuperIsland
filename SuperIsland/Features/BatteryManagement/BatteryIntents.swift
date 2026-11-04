import AppIntents

extension BatteryLED: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "MagSafe灯色" }
    static var caseDisplayRepresentations: [BatteryLED: DisplayRepresentation] {
        [.system: "跟随系统", .off: "关闭", .green: "绿色", .orange: "橙色", .atLimit: "达到上限时绿色"]
    }
}
extension BatteryEnergyScope: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "电源范围" }
    static var caseDisplayRepresentations: [BatteryEnergyScope: DisplayRepresentation] {
        [.never: "从不", .always: "始终", .battery: "仅电池", .adapter: "仅适配器"]
    }
}

struct BatteryTopUpIntent: AppIntent {
    static var title: LocalizedStringResource = "充满电池"
    static var description = IntentDescription("临时充至100%，保持至断开电源。返回实际控制状态，达到电量目标需继续观察。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.execute(mode: .topUp) })
    }
}
struct BatteryPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "暂停充电"
    static var description = IntentDescription("临时暂停充电，保留长期上限和低限值许可。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.execute(mode: .paused) })
    }
}
struct BatteryDischargeIntent: AppIntent {
    static var title: LocalizedStringResource = "放电至目标"
    static var description = IntentDescription("按设备支持的通道放电至目标；原生限值通道最低80%，不支持的低值会明确拒绝。")
    @Parameter(title: "目标电量（%）", default: 80, inclusiveRange: (20, 99)) var percentage: Int
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.execute(mode: .discharge, target: percentage) })
    }
}
struct BatteryCalibrateIntent: AppIntent {
    static var title: LocalizedStringResource = "开始电池校准"
    static var description = IntentDescription("执行100%→10%→100%→保持→原上限的校准；需持续接电，耗时较长。设备或辅助程序不支持时明确拒绝。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.startCalibration() })
    }
}
struct BatterySetLimitIntent: AppIntent {
    static var title: LocalizedStringResource = "设置充电上限"
    @Parameter(title: "长期上限（%）", default: 80, inclusiveRange: (20, 100)) var percentage: Int
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.setLimitFromAutomation(percentage) })
    }
}
struct BatteryLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "获取电池电量"
    static var openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try BatteryReadOnlyQueries().level())
    }
}
struct BatteryLimitIntent: AppIntent {
    static var title: LocalizedStringResource = "获取充电上限"
    static var openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    static var description = IntentDescription("返回保存的长期目标百分比，不代表当前系统已经应用。实际控制结果请用获取充电状态。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try BatteryReadOnlyQueries().limit())
    }
}
struct BatteryStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "获取充电状态"
    static var openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await BatteryReadOnlyQueries().status())
    }
}
struct BatteryTemperatureIntent: AppIntent {
    static var title: LocalizedStringResource = "获取电池温度"
    static var openAppWhenRun = false
    @available(macOS 26.0, *) static var supportedModes: IntentModes { .background }
    static var description = IntentDescription("返回传感器实测摄氏温度。没有传感器读数时返回错误。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        .result(value: try BatteryReadOnlyQueries().temperature())
    }
}
struct BatteryLEDIntent: AppIntent {
    static var title: LocalizedStringResource = "设置MagSafe灯色"
    @Parameter(title: "灯色", default: .system) var color: BatteryLED
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation {
            guard BatteryManagementService.shared.report.ledSupported else { throw BatteryControlError.unavailable("没有可确认的MagSafe LED控制能力。") }
            return try await BatteryManagementService.shared.changeFromAutomation { $0.led = color }
        })
    }
}
struct BatteryLowPowerIntent: AppIntent {
    static var title: LocalizedStringResource = "设置低功耗模式"
    @Parameter(title: "生效范围", default: .never) var scope: BatteryEnergyScope
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.changeFromAutomation { $0.lowPower = scope } })
    }
}
struct BatteryHighPowerIntent: AppIntent {
    static var title: LocalizedStringResource = "设置高功率模式"
    @Parameter(title: "生效范围", default: .never) var scope: BatteryEnergyScope
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BatteryManagementService.shared.performAutomation { try await BatteryManagementService.shared.setHighPowerFromAutomation(scope) })
    }
}

struct BatteryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BatteryLevelIntent(), phrases: ["用\(.applicationName)查看电池电量"], shortTitle: "电池电量", systemImageName: "battery.100")
        AppShortcut(intent: BatteryTopUpIntent(), phrases: ["用\(.applicationName)充满电池"], shortTitle: "充满电池", systemImageName: "battery.100.bolt")
        AppShortcut(intent: BatteryPauseIntent(), phrases: ["用\(.applicationName)暂停充电"], shortTitle: "暂停充电", systemImageName: "pause.circle")
        AppShortcut(intent: BatteryStatusIntent(), phrases: ["用\(.applicationName)查看充电状态"], shortTitle: "充电状态", systemImageName: "battery.75percent")
    }
}
