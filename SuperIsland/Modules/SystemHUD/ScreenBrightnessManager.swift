import AppKit
import Combine
import CoreGraphics
import Darwin

enum SystemFeedbackKind: Equatable {
    case volume
    case brightness
}

/// Reads only the built-in panel. No brightness writes, DDC or keyboard backlight.
struct BuiltInScreenBrightnessReader {
    enum Result: Equatable {
        case value(Float)
        case noBuiltInDisplay
        case unavailable
    }

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    static func read() -> Result {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return .noBuiltInDisplay
        }
        // Availability-checked because DisplayServices is not a stable public API.
        guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
            return .unavailable
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return .unavailable }
        let get = unsafeBitCast(symbol, to: GetBrightness.self)
        var value: Float = 0
        guard get(display, &value) == 0, isValid(value) else { return .unavailable }
        return .value(value)
    }

    static func isValid(_ value: Float) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

@MainActor
final class ScreenBrightnessManager: ObservableObject {
    static let shared = ScreenBrightnessManager()
    @Published private(set) var brightness: Float?
    @Published private(set) var statusText = "正在检测内置屏幕"
    private var enabled = false
    private var generation: UInt64 = 0
    private var screenObserver: NSObjectProtocol?

    private init() {
        refresh()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func apply(enabled: Bool) {
        self.enabled = enabled
        generation &+= 1
        refresh()
        if !enabled { AppState.shared.hideCompactSystemFeedback(if: .brightness) }
    }

    /// Brightness keys pass through to macOS. Read after macOS has applied them.
    /// A key press, rather than a poll, authorizes the transient presentation.
    func noteUserInitiatedChange() {
        guard enabled else { return }
        generation &+= 1
        let currentGeneration = generation
        let deadline = ProcessInfo.processInfo.systemUptime + Constants.hudAutoDismissDelay
        for delay in [0.06, 0.18, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.enabled, self.generation == currentGeneration else { return }
                self.refresh()
                guard self.brightness != nil else {
                    AppState.shared.hideCompactSystemFeedback(if: .brightness)
                    return
                }
                AppState.shared.showBrightnessHUD(
                    duration: max(0, deadline - ProcessInfo.processInfo.systemUptime)
                )
            }
        }
    }

    func refresh() {
        switch BuiltInScreenBrightnessReader.read() {
        case .value(let value):
            brightness = value
            statusText = "内置屏幕可用 · 调节亮度键时在岛内提示"
            SystemFeedbackDiagnostics.write("brightnessReading", fields: ["readable": true, "value": value])
        case .noBuiltInDisplay:
            brightness = nil
            statusText = "没有可用的 Mac 内置屏幕；首版不支持外接显示器"
            SystemFeedbackDiagnostics.write("brightnessReading", fields: ["readable": false, "builtInDisplay": false])
        case .unavailable:
            brightness = nil
            statusText = "暂时无法读取内置屏幕亮度"
            SystemFeedbackDiagnostics.write("brightnessReading", fields: ["readable": false, "builtInDisplay": true])
        }
    }
}
