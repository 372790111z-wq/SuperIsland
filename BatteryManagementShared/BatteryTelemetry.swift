import Foundation
import IOKit
import IOKit.ps

struct BatteryTelemetry: Codable, Equatable {
    var timestamp = Date()
    var reportedPower: BatteryReportedPower?
    var hasBattery = false
    var level: Int?
    // Preserve the display bool while retaining whether the OS actually
    // returned it. Failed reads/default snapshots never prove power-off.
    var onAC = false { didSet { observedExternalPower = onAC } }
    private(set) var observedExternalPower: Bool?
    var powerSupplyObservation: Bool? { hasBattery ? observedExternalPower : nil }
    var adapterPhysicallyConnected: Bool?
    // AC-W remains diagnostic in production. Only the explicitly sealed Review
    // trial uses this device's plugged/cutoff/unplug contrast for connection;
    // it never supplies cutoff ownership or confirms input recovery.
    var adapterConnectionCandidate: Bool?
    var charging = false { didSet { observedCharging = charging } }
    private(set) var observedCharging: Bool?
    var chargingObservation: Bool? { hasBattery ? observedCharging : nil }
    var adapterConnectionObservation: Bool? {
        guard hasBattery else { return nil }
        if powerSupplyObservation == true || adapterPhysicallyConnected == true { return true }
        if powerSupplyObservation == false && adapterPhysicallyConnected == false { return false }
        return nil
    }
    var temperature: Double?
    var voltage: Double?
    var current: Double?
    var fullCapacity: Int?
    var designCapacity: Int?
    var remainingCapacity: Int?
    var cycles: Int?
    var adapterWatts: Int?
    var minutesRemaining: Int?

    var adapterPresent: Bool { onAC || adapterPhysicallyConnected == true }

    var power: Double? {
        guard let voltage, let current else { return nil }
        return voltage * current
    }
    var health: Double? {
        guard let fullCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(fullCapacity) / Double(designCapacity) * 100
    }
    var hardwarePercentage: Double? {
        guard let remainingCapacity, let fullCapacity, fullCapacity > 0 else { return nil }
        return Double(remainingCapacity) / Double(fullCapacity) * 100
    }

    static func read() -> BatteryTelemetry {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .init() }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return .init() }
        let smc = try? BatterySMC()
        var result = decode(dictionary, physicalAdapter: try? smc?.read("AC-W"))
        // SMC TB0T is a 32-bit little-endian float on Apple Silicon;
        // Intel sensors return sp78. Unknown types remain unavailable.
        if result.temperature == nil, let smc,
           let value = try? smc.read("TB0T") {
            if value.type == "flt ", value.bytes.count == 4 {
                let raw = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                let number = Double(Float(bitPattern: UInt32(littleEndian: raw)))
                if number.isFinite, (-10...90).contains(number) { result.temperature = number }
            } else if value.type == "sp78", value.bytes.count == 2 {
                let raw = Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
                let number = Double(raw) / 256
                if (-10...90).contains(number) { result.temperature = number }
            }
        }
        return result
    }

    static func decode(_ d: [String: Any], physicalAdapter: BatterySMC.Value? = nil, readAt: Date = Date()) -> BatteryTelemetry {
        var s = BatteryTelemetry(); s.timestamp = readAt
        s.reportedPower = BatteryReportedPower.decode(d["PowerTelemetryData"], readAt: readAt, batteryUpdateTime: d["UpdateTime"])
        let b = d["BatteryData"] as? [String: Any] ?? [:]
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        func positive(_ value: Any?) -> Int? {
            guard let n = number(value), n > 0, n < 100_000 else { return nil }
            return Int(n)
        }
        s.hasBattery = d["BatteryInstalled"] as? Bool == true
        if let level = number(d["CurrentCapacity"]), let max = number(d["MaxCapacity"]), max > 0 {
            let value = level / max * 100
            if (0...100).contains(value) { s.level = Int(value.rounded()) }
        }
        s.onAC = d["ExternalConnected"] as? Bool == true
        s.observedExternalPower = d["ExternalConnected"] as? Bool
        s.adapterPhysicallyConnected = d["AppleRawExternalConnected"] as? Bool
        s.adapterConnectionCandidate = BatteryPhysicalAdapterSignal.decode(physicalAdapter)
        s.charging = d["IsCharging"] as? Bool == true
        s.observedCharging = d["IsCharging"] as? Bool
        if let n = number(d["Temperature"]), n > 0 {
            let celsius = n / 100
            if (-10...90).contains(celsius) { s.temperature = celsius }
        }
        if let v = number(d["Voltage"]), (1_000...30_000).contains(v) { s.voltage = v / 1000 }
        if let raw = d["InstantAmperage"] as? NSNumber ?? d["Amperage"] as? NSNumber, raw.doubleValue.isFinite {
            let amps = Double(Int64(bitPattern: raw.uint64Value)) / 1000
            if abs(amps) < 30 { s.current = amps }
        }
        s.fullCapacity = positive(d["AppleRawMaxCapacity"]) ?? positive(b["FullChargeCapacity"]) ?? positive(b["NominalChargeCapacity"])
        s.designCapacity = positive(d["DesignCapacity"]) ?? positive(b["DesignCapacity"])
        s.remainingCapacity = positive(d["AppleRawCurrentCapacity"]) ?? positive(b["RemainingCapacity"])
        s.cycles = (d["CycleCount"] as? NSNumber)?.intValue
        s.adapterWatts = positive((d["AdapterDetails"] as? [String: Any])?["Watts"])
        let key = s.charging ? "AvgTimeToFull" : "AvgTimeToEmpty"
        // On AC while holding a limit, the gauge may extrapolate tiny battery
        // currents into hundreds of hours. That is not a battery-runtime
        // estimate for the current power source, so do not present it as one.
        if s.charging || !s.onAC,
           let n = (d[key] as? NSNumber ?? b[key] as? NSNumber)?.intValue, (1..<65_535).contains(n) { s.minutesRemaining = n }
        return s
    }
}

/// AlDente's native sensor checks AC-W !=0xff. Keep read success and type
/// validity: its wrapper discards success, so copying a failed0 is unsafe.
/// Review Mac: r18 observed4 under owned CHIE8; 2026-11-01 user unplug/replug
/// observed4→ff→4 with CHIE0. This is device evidence, not a fleet capability.
enum BatteryPhysicalAdapterSignal {
    static func decode(_ value: BatterySMC.Value?) -> Bool? {
        guard let value, value.type == "si8 ", value.bytes.count == 1 else { return nil }
        return value.bytes[0] != 0xff
    }
}

enum BatteryCutoffConnection {
    static func observation(_ telemetry: BatteryTelemetry, verifiedReviewTrial: Bool) -> Bool? {
        if verifiedReviewTrial { return telemetry.adapterConnectionCandidate }
        // Neither absence of the OS flags nor an unverified candidate proves
        // physical unplug. Production retains its existing unknown timeout.
        return telemetry.adapterPresent ? true : nil
    }
}

/// Independently read adapter input candidate. OS connection flags and cached
/// PowerTelemetryData do not prove useful input. These fixed sensors are readable
/// on the review Mac; their cutoff/unplug behavior still requires device acceptance.
/// >1W is a conservative recovery policy, not an Apple capability guarantee.
enum BatteryAdapterInput {
    static func watts(read: (String) throws -> BatterySMC.Value) -> Double? {
        func scalar(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let value = try? read(key), value.type == "flt ", value.bytes.count == 4 else { return nil }
            let raw = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let number = Double(Float(bitPattern: UInt32(littleEndian: raw)))
            return number.isFinite && range.contains(number) ? number : nil
        }
        guard let voltage = scalar("VD0R", range: 0...60),
              let current = scalar("ID0R", range: 0...20) else { return nil }
        return voltage * current
    }
    static func supplying(watts: Double?) -> Bool? {
        guard let watts, watts.isFinite, (0...1200).contains(watts) else { return nil }
        return watts > 1
    }
}

/// Fixed AppleSMC user-client ABI. Writes are compiled only into the helper.
/// The client-facing XPC protocol does not expose keys, byte buffers or paths.
final class BatterySMC {
    struct Value { var type: String; var bytes: [UInt8] }
    private var connection: io_connect_t = 0
    init() throws {
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"))
        if service == 0 { service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")) }
        guard service != 0 else { throw BatteryControlError.unavailable("AppleSMC不可用。") }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            throw BatteryControlError.unavailable("无法读取AppleSMC。")
        }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(key: String, command: UInt8, bytes: [UInt8] = [], size: Int = 0) throws -> [UInt8] {
        guard key.utf8.count == 4, bytes.count <= 32, (0...32).contains(size) else {
            throw BatteryControlError.invalid("无效SMC请求。")
        }
        var input = [UInt8](repeating: 0, count: 80), output = input
        var code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }.littleEndian
        withUnsafeBytes(of: &code) { input.replaceSubrange(0..<4, with: $0) }
        var length = UInt32(size).littleEndian
        withUnsafeBytes(of: &length) { input.replaceSubrange(28..<32, with: $0) }
        input[42] = command
        input.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        var outputSize = 80
        let status = input.withUnsafeBytes { i in
            output.withUnsafeMutableBytes { o in
                IOConnectCallStructMethod(connection, 2, i.baseAddress, 80, o.baseAddress, &outputSize)
            }
        }
        guard status == kIOReturnSuccess, outputSize == 80, output[40] == 0 else {
            throw BatteryControlError.unavailable("SMC \(key)不可用（\(status)/\(output[40])）。")
        }
        return output
    }
    func read(_ key: String) throws -> Value {
        let info = try call(key: key, command: 9)
        let size = Int(info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self).littleEndian })
        guard (1...32).contains(size) else { throw BatteryControlError.unavailable("SMC数据长度不可用。") }
        let typeCode = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self).littleEndian }
        let type = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: typeCode >> $0) }, encoding: .ascii) ?? ""
        let data = try call(key: key, command: 5, size: size)
        return .init(type: type, bytes: Array(data[48..<(48 + size)]))
    }
#if BATTERY_HELPER
    #if BATTERY_REVIEW || DEBUG
    /// Called only by the isolated, root-owned fixed diagnostic child. No
    /// daemon write path consumes these values; metadata failure does not
    /// prevent the separately recorded fixed-size command5 comparison.
    func fixedReadDiagnosticJSON() throws -> String {
        var rows: [[String: Any]] = []
        for (key, size) in BatteryFixedSMCReadDiagnostics.keys {
            for command in [UInt8(9), UInt8(5)] {
                var row: [String: Any] = ["key": key, "command": Int(command)]
                do {
                    let raw = try call(key: key, command: command, size: command == 5 ? size : 0)
                    if command == 5 { row["bytes"] = Array(raw[48..<(48 + size)]) }
                    else {
                        row["metadataSize"] = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self).littleEndian }
                        let code = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self).littleEndian }
                        row["metadataType"] = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
                    }
                } catch { row["error"] = String(error.localizedDescription.prefix(180)) }
                rows.append(row)
            }
        }
        let root: [String: Any] = ["sourceUID": getuid(), "pid": getpid(), "readAt": Date().timeIntervalSince1970,
                                   "hardwareWrites": false, "records": rows]
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }
    #endif
    #if BATTERY_REVIEW || BATTERY_PAUSE_REFRESH || DEBUG
    /// Sealed pulse caller validated CHIE0 before its durable intent. Unlike
    /// the general writer this fixed command does NOT query sensors before or
    /// after the write. Both readbacks happen only after release to0.
    func writePauseRefreshCHIE(_ value: Int) throws {
        guard value == 0 || value == 8 else { throw BatteryControlError.invalid("短暂切换仅支持CHIE0或8。") }
        _ = try call(key: "CHIE", command: 6, bytes: [UInt8(value)], size: 1)
    }
    #endif
    func write(_ key: String, bytes: [UInt8]) throws {
        let allowed = ["CHTE": 4, "CH0B": 1, "CH0C": 1, "CHIE": 1, "CH0I": 1, "CH0J": 1, "BCLM": 1, "ACLC": 1]
        guard allowed[key] == bytes.count, try read(key).bytes.count == bytes.count else {
            throw BatteryControlError.unavailable("未经支持矩阵确认的SMC写入。")
        }
        _ = try call(key: key, command: 6, bytes: bytes, size: bytes.count)
        // LED firmware can settle after the command returns. Allow only a
        // bounded read-only observation window for ACLC; all other registers
        // retain immediate confirmation. Never repeat the hardware write.
        guard try BatteryHardwareReadback.matches(expected: bytes, timeout: key == "ACLC" ? 1 : 0,
                                                  read: { try self.read(key).bytes }) else {
            throw BatteryControlError.recovery(key == "ACLC" ? "MagSafe灯色未得到设备读回确认；已停止控制并尝试恢复。" : "SMC写入后读回不一致。")
        }
    }
#endif
}

/// Diagnostic evidence only: a fixed read-only list, never capability or
/// control input. A failed read stays unknown, including permission failures.
#if BATTERY_REVIEW || DEBUG
struct BatterySMCDiscovery: Codable, Equatable {
    struct Register: Codable, Equatable {
        var key: String
        var type: String?
        var bytes: [UInt8]?
        var failure: String?
    }
    var timestamp = Date()
    var sourceUID: UInt32
    var registers: [Register]
    static func capture(sourceUID: UInt32, read: (String) throws -> BatterySMC.Value) -> Self {
        .init(sourceUID: sourceUID, registers: ["bfF0", "bfD0", "bfE0"].map { key in
            do {
                let value = try read(key)
                return .init(key: key, type: value.type, bytes: value.bytes)
            } catch { return .init(key: key, failure: error.localizedDescription) }
        })
    }
}
#endif
