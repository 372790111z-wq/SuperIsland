import Foundation
import IOKit
import IOKit.pwr_mgt

/// Delivers trusted power events on the daemon's existing serial queue.
/// Never vetoes sleep or creates a power assertion.
final class BatterySystemPowerObserver {
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let transition: (Bool) -> Void

    init?(queue: DispatchQueue, transition: @escaping (Bool) -> Void) {
        self.transition = transition
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<BatterySystemPowerObserver>.fromOpaque(context).takeUnretainedValue()
            // IOMessage.h: sys_iokit (0x38 << 26) | sub_iokit_common | message.
            // These function-like C macros are not imported into Swift.
            switch message {
            case 0xe0000270:
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            case 0xe0000280:
                // Acknowledge on every path, including failed recovery.
                defer { IOAllowPowerChange(observer.connection, Int(bitPattern: argument)) }
                observer.transition(true)
            case 0xe0000300: observer.transition(false)
            default: break
            }
        }, &notifier)
        guard connection != 0, let port else { return nil }
        IONotificationPortSetDispatchQueue(port, queue)
    }
    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        if connection != 0 { IOServiceClose(connection) }
    }
}
