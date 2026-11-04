import Foundation

#if BATTERY_HELPER || DEBUG

/// Read-only confirmation after one hardware write. The write transaction owns
/// rollback; polling must neither rewrite a command nor hide read failures.
enum BatteryHardwareReadback {
    static func matches(expected: [UInt8], timeout: TimeInterval,
                        read: () throws -> [UInt8],
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> Bool {
        guard timeout.isFinite, (0...1).contains(timeout) else { return false }
        let deadline = now() + timeout
        while true {
            if try read() == expected { return true }
            let remaining = deadline - now()
            guard remaining > 0 else { return false }
            wait(min(0.05, remaining))
        }
    }
}

enum BatteryNativeRegistration {
    /// Requires every active registration to be the same manual target with
    /// Apple's drain flag. Unknown fields remain unknown, never affirmative.
    static func manualDrainMatches(_ text: String, target: Int) -> Bool? {
        guard let limits = parse(text) else { return nil }
        guard limits == [target] else { return false }
        guard let expression = try? NSRegularExpression(pattern: #"\{([^{}]*)\}"#) else { return nil }
        let blocks = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var active = 0
        for block in blocks {
            guard let range = Range(block.range(at: 1), in: text) else { return nil }
            let fields = String(text[range])
            func field(_ key: String) -> String? {
                let pattern = #"\b"# + key + #"\s*=\s*([^;]+)\s*;"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                let matches = regex.matches(in: fields, range: NSRange(fields.startIndex..., in: fields))
                guard matches.count == 1, let valueRange = Range(matches[0].range(at: 1), in: fields) else { return nil }
                return String(fields[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let ended = field("Terminated"), ended == "0" || ended == "1" else { return nil }
            if ended == "1" { continue }
            guard let reason = field("chargeSocLimitReason"), let drain = field("chargeSocLimitDrain"),
                  drain == "0" || drain == "1" else { return nil }
            guard let rawTarget = field("chargeSocLimitSoc"), let registeredTarget = Int(rawTarget) else { return nil }
            guard registeredTarget == target else { return false }
            guard reason == "manualChargeLimit", drain == "1" else { return false }
            active += 1
        }
        return active > 0
    }

    /// Verify even a partial transaction that changed enablement but failed
    /// before it acquired a manual-limit original. Nil registration is unknown.
    static func restorationMatches(limit: Int?, enabled: Int?, savedManualLimit: Int?, registrations: Set<Int>?) -> Bool {
        guard limit != nil || enabled != nil,
              enabled == nil || enabled == 0 || enabled == 1 else { return false }
        if let limit, savedManualLimit != limit { return false }
        if enabled == 0 { return registrations == Set<Int>() }
        guard let target = limit ?? savedManualLimit, (80...100).contains(target) else { return false }
        return registrations == Set([target])
    }

    /// nil is unreadable/ambiguous output; [] is positively observed absence.
    /// A second active target is evidence, never discarded in favor of the first.
    static func parse(_ text: String) -> Set<Int>? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "No battery level limits set" { return [] }
        guard text.hasPrefix("Battery level limits:"),
              let expression = try? NSRegularExpression(pattern: #"\{([^{}]*)\}"#) else { return nil }
        let blocks = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !blocks.isEmpty else { return nil }
        var result: Set<Int> = []
        for block in blocks {
            guard let range = Range(block.range(at: 1), in: text) else { return nil }
            let fields = String(text[range])
            func number(_ key: String) -> Int? {
                guard let range = fields.range(of: #"\b"# + key + #"\s*=\s*[0-9]+\s*;"#, options: .regularExpression) else { return nil }
                return Int(fields[range].split(separator: "=").last?.replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
            guard let terminated = number("Terminated"), terminated == 0 || terminated == 1 else { return nil }
            if terminated == 1 { continue }
            guard let limit = number("chargeSocLimitSoc"), (1...100).contains(limit) else { return nil }
            result.insert(limit)
        }
        return result
    }
}

/// Confirms the manual-limit getter, powerd registration and physical charging
/// separately from accepted writes. currentChargeLimit: is an optimization
/// threshold (80/100 on the investigated system), not a manual MCL readback.
/// A timeout stops renewal and leaves the existing compare-and-restore path in
/// charge of recovery. It never bypasses firmware or disconnects an adapter.
struct BatteryControlVerification {
    enum Observation: Equatable {
        case unplugged, systemOverride, waitingForRegistration, charging, waitingForCharge, holding, waitingForStop
    }
    private var lastTarget: Int?
    private var registrationSince: TimeInterval?
    private var stoppingSince: TimeInterval?
    private(set) var lastTime: TimeInterval?
    let timeout: TimeInterval
    init(timeout: TimeInterval = 90) { self.timeout = timeout }

    mutating func observe(target: Int, mustStop: Bool, charging: Bool, onAC: Bool,
                          registrations: Set<Int>?, savedManualLimit: Int?, systemOverride: Bool,
                          now: TimeInterval) throws -> Observation {
        if let lastTime, now < lastTime { self = .init(timeout: timeout) }
        lastTime = now
        guard onAC else { reset(); return .unplugged }
        if systemOverride { reset(); return .systemOverride }
        if lastTarget != target { reset(); lastTarget = target }
        if registrations != [target] || savedManualLimit != target {
            if registrationSince == nil { registrationSince = now }
            if now - registrationSince! >= timeout {
                throw BatteryControlError.recovery("系统限充目标未在时限内一致登记；已停止控制并尝试恢复，实际充电状态尚未确认。")
            }
            // Do not let target-registration lag defer an already needed stop.
            try checkStop(mustStop: mustStop, charging: charging, now: now)
            return .waitingForRegistration
        }
        registrationSince = nil
        try checkStop(mustStop: mustStop, charging: charging, now: now)
        if mustStop { return charging ? .waitingForStop : .holding }
        return charging ? .charging : .waitingForCharge
    }
    private mutating func checkStop(mustStop: Bool, charging: Bool, now: TimeInterval) throws {
        guard mustStop && charging else { stoppingSince = nil; return }
        if stoppingSince == nil { stoppingSince = now }
        if now - stoppingSince! >= timeout {
            throw BatteryControlError.recovery("设备在停充请求后仍持续充电；已停止控制并尝试恢复。请检查电源及电池工具，不能将目标登记视为停充成功。")
        }
    }
    /// SMC readback confirms a register, not that battery charging has stopped.
    /// This path has no native target/registration values to substitute.
    mutating func confirmPhysicalStop(target: Int, required: Bool, charging: Bool, now: TimeInterval) throws -> Bool {
        if let lastTime, now < lastTime { reset() }
        if lastTarget != target { reset(); lastTarget = target }
        lastTime = now
        try checkStop(mustStop: required, charging: charging, now: now)
        return !required || !charging
    }
    mutating func reset() { lastTarget = nil; registrationSince = nil; stoppingSince = nil }
}

#endif
