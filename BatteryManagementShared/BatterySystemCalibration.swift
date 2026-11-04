import Foundation

#if BATTERY_HELPER || DEBUG
import Darwin

enum BatterySystemCalibration {
    static var isActive: Bool { observation == true }
    /// Strict review admission must distinguish an observed inactive state
    /// from an unavailable notification API.
    static var observation: Bool? {
        typealias Register = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
        typealias Read = @convention(c) (Int32, UnsafeMutablePointer<UInt64>) -> UInt32
        typealias Cancel = @convention(c) (Int32) -> UInt32
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let register = dlsym(handle, "notify_register_check"), let read = dlsym(handle, "notify_get_state"),
              let cancel = dlsym(handle, "notify_cancel") else { return nil }
        var token: Int32 = 0, state: UInt64 = 0
        guard unsafeBitCast(register, to: Register.self)("com.apple.system.powersources.chargingtofulloverride", &token) == 0 else { return nil }
        defer { _ = unsafeBitCast(cancel, to: Cancel.self)(token) }
        guard unsafeBitCast(read, to: Read.self)(token, &state) == 0, state <= 1 else { return nil }
        return state == 1
    }
}

#endif
