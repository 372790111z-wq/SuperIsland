import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Darwin

/// Public console-user API only. No privileged RPC or system preference changes.
@MainActor
enum KeepAwakeSystemSleep {
    static func snapshot() -> KeepAwakeCompletionSleep.Snapshot {
        var result = KeepAwakeCompletionSleep.Snapshot()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            defer { IOObjectRelease(root) }
            func boolean(_ key: String) -> Bool? {
                guard let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                return (value as? NSNumber)?.boolValue
            }
            result.lidClosed = boolean("AppleClamshellState")
            result.sleepDisabled = boolean("SleepDisabled")
            // Recap evidence is independent of whether our hold has already
            // returned. In particular, a new task can reacquire it in DarkWake,
            // and the first open-lid frame must still freeze the final interval.
            if let pair = kernelSleepWake() {
                result.kernelSleepTime = pair.sleep; result.kernelWakeTime = pair.wake
            }
            let driver = IORegistryEntryCreateCFProperty(root,
                "DriverPMAssertions" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            // DriverPMAssertions publishes only kernel drivers. powerd's
            // BackgroundTask/push/network assertions also feed the CPU veto.
            // Query aggregate levels only when a completion request is possible;
            // never inspect other processes, assertion names or descriptions.
            if result.lidClosed == true && result.sleepDisabled == false {
                var status: Unmanaged<CFDictionary>?
                let code = IOPMCopyAssertionsStatus(&status)
                let levels = status?.takeRetainedValue() as? [String: Any]
                result.cpuSleepBlocked = aggregateCPUSleepBlocked(driver: driver,
                    levels: code == kIOReturnSuccess ? levels : nil)
                result.cpuBlockingTypes = cpuBlockingTypes(driver: driver,
                    levels: code == kIOReturnSuccess ? levels : nil)
            }
        }
        // One bounded query avoids a hot-plug race between querying the count
        // and fetching a smaller list. A full buffer is unknown, not no external.
        var displays = [CGDirectDisplayID](repeating: 0, count: 128)
        var actual: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(displays.count), &displays, &actual) == .success,
           Int(actual) < displays.count {
            result.externalDisplays = displays.prefix(Int(actual)).filter { CGDisplayIsBuiltin($0) == 0 }.count
        }
        return result
    }

    /// Bounded read-only public sysctls. Reject a pair racing a wake update;
    /// an unavailable timestamp is unknown and cannot manufacture retry proof.
    nonisolated static func kernelSleepWake() -> (sleep: TimeInterval, wake: TimeInterval)? {
        func read(_ key: String) -> timeval? {
            var value = timeval(), size = MemoryLayout<timeval>.size
            guard sysctlbyname(key, &value, &size, nil, 0) == 0,
                  size == MemoryLayout<timeval>.size, value.tv_sec > 0,
                  value.tv_usec >= 0, value.tv_usec < 1_000_000 else { return nil }
            return value
        }
        guard let before = read("kern.waketime"), let slept = read("kern.sleeptime"),
              let woke = read("kern.waketime"), before.tv_sec == woke.tv_sec,
              before.tv_usec == woke.tv_usec else { return nil }
        let sleep = Double(slept.tv_sec) + Double(slept.tv_usec) / 1_000_000
        let wake = Double(woke.tv_sec) + Double(woke.tv_usec) / 1_000_000
        guard wake > sleep else { return nil }
        return (sleep, wake)
    }

    /// CPU is one bit, not all driver assertions (e.g. MAGICWAKE). Missing or
    /// malformed registry data must not be converted to an all-clear result.
    nonisolated static func cpuSleepBlocked(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let bits = number.int64Value
        guard bits >= 0, bits <= Int64(UInt32.max), number.doubleValue == Double(bits) else { return nil }
        return bits & Int64(kIOPMDriverAssertionCPUBit) != 0
    }

    // powerd PMAssertions.c:setKernelAssertions maps these seven types to the
    // CPU bit. Idle/display assertions deliberately do not participate.
    nonisolated static let cpuAssertionTypes = ["BackgroundTask", "PreventSystemSleep", "ApplePushServiceTask",
        "InteractivePushServiceTask", "InternalPreventSleep", "NetworkClientActive", "SoftwareUpdateTask"]

    nonisolated static func aggregateCPUSleepBlocked(driver: Any?, levels: [String: Any]?) -> Bool? {
        let kernel = cpuSleepBlocked(driver)
        if kernel == true { return true }
        var unknown = kernel == nil
        for key in cpuAssertionTypes {
            guard let value = levels?[key] as? NSNumber, CFGetTypeID(value) == CFNumberGetTypeID(),
                  value.doubleValue == 0 || value.doubleValue == 1 else { unknown = true; continue }
            if value.doubleValue == 1 { return true }
        }
        return unknown ? nil : false
    }

    /// Aggregate public type names only: no PID, process/assertion description,
    /// client name or user content is collected for continuous diagnostics.
    nonisolated static func cpuBlockingTypes(driver: Any?, levels: [String: Any]?) -> [String]? {
        guard let blocked = aggregateCPUSleepBlocked(driver: driver, levels: levels) else { return nil }
        guard blocked else { return [] }
        var types = cpuSleepBlocked(driver) == true ? ["KernelCPU"] : []
        types += cpuAssertionTypes.filter { key in
            guard let number = levels?[key] as? NSNumber,
                  CFGetTypeID(number) == CFNumberGetTypeID() else { return false }
            return number.doubleValue == 1
        }
        return types
    }

    static func request() -> Int32 {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { return kIOReturnNotReady }
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port)
    }
}

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
    var hasPendingAssertions: Bool { systemID != 0 || displayID != 0 }

    static func environment() -> KeepAwakeEngine.Environment {
        var result = KeepAwakeEngine.Environment()
        result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        result.thermalUnsafe = [.serious, .critical].contains(thermal)
        result.thermalLevel = thermal.rawValue
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
