import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Darwin

@MainActor
final class KeepAwakePower {
    private(set) var systemID: IOPMAssertionID = 0
    private(set) var displayID: IOPMAssertionID = 0
    private(set) var error: String?
    private var didRequestScreenOff = false
    private var screenProcess: Process?
    private var screenError: String?
    private var lastPolicy: KeepAwakeEngine.ScreenPolicy = .system
    var isHolding: Bool { systemID != 0 }

    static func environment() -> KeepAwakeEngine.Environment {
        var result = KeepAwakeEngine.Environment()
        result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        result.thermalUnsafe = [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            let clamshell = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            result.hardware = clamshell is NSNumber ? .notebook : .desktop
            IOObjectRelease(root)
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                result.hardware = .notebook
                if let current = values[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    result.battery = max(0, min(100, Int(Double(current) / Double(maximum) * 100)))
                }
                if let power = values[kIOPSPowerSourceStateKey] as? String {
                    result.onAC = power == kIOPSACPowerValue
                }
            }
        }
        return result
    }
    static var hasExternalDisplay: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return true }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }
    }
    func apply(hold: Bool, policy: KeepAwakeEngine.ScreenPolicy, notebook: Bool) {
        error = screenError
        if lastPolicy != policy { didRequestScreenOff = false; lastPolicy = policy; screenError = nil; error = nil }
        if !hold {
            release(&displayID); release(&systemID)
            didRequestScreenOff = false; screenError = nil
            return
        }
        acquire(&systemID, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "SuperIsland 保持本地任务运行")
        guard isHolding else { release(&displayID); return }
        if policy == .awake {
            acquire(&displayID, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "SuperIsland 屏幕常亮")
        } else { release(&displayID) }
        if policy == .off {
            // Public displaysleepnow affects all screens. Do not pretend it can
            // preserve an external workstation display on a MacBook.
            if notebook && Self.hasExternalDisplay {
                error = "普通保持已生效；当前熄屏接口会影响外屏，已保留全部显示器。"
                return
            }
            if !didRequestScreenOff, screenProcess == nil, !NSScreen.screens.isEmpty {
                didRequestScreenOff = true
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] task in
                    Task { @MainActor [weak self] in
                        self?.screenProcess = nil
                        if task.terminationStatus != 0 { self?.screenError = "熄屏未成功；普通保持仍独立运行。" }
                    }
                }
                do { try process.run(); screenProcess = process }
                catch { self.screenError = "无法执行熄屏；普通保持仍独立运行。"; self.error = screenError }
            }
        }
    }
    private func acquire(_ id: inout IOPMAssertionID, type: String, reason: String) {
        guard id == 0 else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &newID)
        if result == kIOReturnSuccess { id = newID }
        else { error = "系统拒绝保持请求（\(result)）。" }
    }
    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        let result = IOPMAssertionRelease(id)
        if result == kIOReturnSuccess || result == kIOReturnNotFound { id = 0 }
        else { error = "保持释放未确认（\(result)），正在重试。" }
    }
}
