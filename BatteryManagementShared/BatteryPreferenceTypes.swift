import Foundation

#if BATTERY_HELPER || DEBUG
/// Shared plist types preserve absence and numeric/date representation.
enum BatteryPreferenceTypes {
    enum Key: String, Codable, CaseIterable {
        case checkpoint, currentState, mclTempDisabledUntilDate = "MCLTempDisabledUntilDate"
        case mclLimitValue, mclFeatureState = "MCLFeatureState", isEngaged, isManuallyChargeLimited
        case initialChargeLimitSetDate, disabledUntil, mclOverridenUntilDate = "MCLOverridenUntilDate"
        case mclSavedTargetSoC = "MCLSavedTargetSoC", modeOfOperation
        static let direct: [Self] = [.checkpoint, .currentState, .mclTempDisabledUntilDate, .mclLimitValue, .mclFeatureState, .isEngaged, .isManuallyChargeLimited]
        static let guards: [Self] = [.initialChargeLimitSetDate, .disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC]
        static let restoration: [Self] = [.mclLimitValue, .mclFeatureState, .isEngaged, .isManuallyChargeLimited, .mclTempDisabledUntilDate, .checkpoint, .currentState]
        var derived: Bool { self == .checkpoint || self == .currentState }
    }
    indirect enum Value: Codable, Equatable {
        case absent, bool(Bool), integer(Int64), real(Double), date(Date), data(Data), string(String)
        case array([Value]), dictionary([String: Value])

        /// CFBoolean is handled before CFNumber. NSNumber float/integer and
        /// CFDate remain different semantic plist types; NSNull is not absence.
        static func fromFoundation(_ object: Any?) throws -> Self {
            var budget = 65_536
            let result = try convert(object, depth: 0, budget: &budget)
            try result.validate(); return result
        }
        private static func convert(_ object: Any?, depth: Int, budget: inout Int) throws -> Self {
            guard depth <= 32 else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            try charge(32, budget: &budget)
            guard let object else { return .absent }
            let result: Self
            if let value = object as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { result = .bool(value.boolValue) }
                else {
                    guard CFGetTypeID(value) == CFNumberGetTypeID() else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
                    let type = String(cString: value.objCType)
                    if type == "d" || type == "f" { result = .real(value.doubleValue) }
                    else {
                        guard !["Q", "L", "I", "S", "C"].contains(type) || value.uint64Value <= UInt64(Int64.max) else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
                        result = .integer(value.int64Value)
                    }
                }
            } else if let value = object as? Date { result = .date(value) }
            else if let value = object as? Data { try charge(value.count, budget: &budget); result = .data(value) }
            else if let value = object as? String { try charge(value.utf8.count, budget: &budget); result = .string(value) }
            else if let value = object as? [Any] {
                guard value.count <= budget / 32 else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
                result = .array(try value.map { try convert($0, depth: depth + 1, budget: &budget) })
            } else if let value = object as? [String: Any] {
                guard value.count <= budget / 32 else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
                var converted: [String: Value] = [:]
                for (key, child) in value {
                    try charge(key.utf8.count, budget: &budget)
                    converted[key] = try convert(child, depth: depth + 1, budget: &budget)
                }
                result = .dictionary(converted)
            }
            else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            return result
        }
        func foundationValue() throws -> Any? {
            try validate()
            switch self {
            case .absent: return nil
            case .bool(let value): return NSNumber(value: value)
            case .integer(let value): return NSNumber(value: value)
            case .real(let value): return NSNumber(value: value)
            case .date(let value): return value
            case .data(let value): return value
            case .string(let value): return value
            case .array(let values): return try values.map { try $0.foundationValue()! }
            case .dictionary(let values): return try values.mapValues { try $0.foundationValue()! }
            }
        }
        var numeric: Double? {
            switch self { case .integer(let v): return Double(v); case .real(let v) where v.isFinite: return v; default: return nil }
        }
        func validate() throws {
            var budget = 65_536
            try validate(depth: 0, nested: false, budget: &budget)
        }
        private static func charge(_ count: Int, budget: inout Int) throws {
            guard count >= 0, count <= budget else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            budget -= count
        }
        private func validate(depth: Int, nested: Bool, budget: inout Int) throws {
            guard depth <= 32 else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            try Self.charge(32, budget: &budget)
            switch self {
            case .absent: if nested { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            case .real(let value): guard value.isFinite else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            case .date(let value): guard value.timeIntervalSinceReferenceDate.isFinite else { throw BatteryControlError.invalid("电池偏好类型或大小无效。") }
            case .data(let value): try Self.charge(value.count, budget: &budget)
            case .string(let value): try Self.charge(value.utf8.count, budget: &budget)
            case .array(let values): for value in values { try value.validate(depth: depth + 1, nested: true, budget: &budget) }
            case .dictionary(let values):
                for (key, value) in values {
                    try Self.charge(key.utf8.count, budget: &budget)
                    try value.validate(depth: depth + 1, nested: true, budget: &budget)
                }
            default: break
            }
        }
    }
}
#endif
