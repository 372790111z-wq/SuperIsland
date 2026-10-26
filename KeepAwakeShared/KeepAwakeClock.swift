import Foundation
import Darwin

/// Continuous time includes sleep and is unaffected by wall-clock corrections.
enum KeepAwakeClock {
    static func now() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
