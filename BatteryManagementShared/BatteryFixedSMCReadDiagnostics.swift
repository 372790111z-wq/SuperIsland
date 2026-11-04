import Foundation
import CoreFoundation

#if BATTERY_REVIEW || DEBUG
/// A fixed diagnostic matrix; never used to authorize a write or a backend.
enum BatteryFixedSMCReadDiagnostics {
    static let keys: [(String, Int)] = [("bfF0", 1), ("bfD0", 4), ("bfE0", 4), ("CHIE", 1)]
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return nil }
        return number.intValue
    }
    static func validate(_ text: String, workerPID: Int32?) throws {
        guard text.utf8.count <= 3000,
              let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              integer(root["sourceUID"]) == 0,
              let pid = integer(root["pid"]), pid > 0, pid == workerPID.map(Int.init),
              let readAt = root["readAt"] as? Double, readAt.isFinite, readAt > 0,
              root["hardwareWrites"] as? Bool == false,
              let records = root["records"] as? [[String: Any]], records.count == keys.count * 2 else {
            throw BatteryControlError.unavailable("固定SMC只读矩阵不完整，未用结果开放能力。")
        }
        var seen = Set<String>()
        for record in records {
            guard let key = record["key"] as? String, let shape = keys.first(where: { $0.0 == key }),
                  let command = integer(record["command"]), command == 5 || command == 9,
                  seen.insert("\(key)/\(command)").inserted else {
                throw BatteryControlError.unavailable("固定SMC只读矩阵含重复或未知项。")
            }
            if let error = record["error"] as? String, !error.isEmpty, error.count <= 180 { continue }
            if command == 5 {
                guard let bytes = record["bytes"] as? [Any], bytes.count == shape.1,
                      bytes.allSatisfy({ integer($0).map { (0...255).contains($0) } == true }) else {
                    throw BatteryControlError.unavailable("固定SMC直接读取的字节形状无效。")
                }
            } else {
                guard let size = integer(record["metadataSize"]), size <= Int(UInt32.max),
                      let type = record["metadataType"] as? String, type.utf8.count <= 4 else {
                    throw BatteryControlError.unavailable("固定SMC元数据读取形状无效。")
                }
                _ = size // Report the raw metadata; it is not a capability check.
            }
        }
    }
}
#endif
