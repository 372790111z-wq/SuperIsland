import Foundation
import Darwin

#if BATTERY_REVIEW
/// The daemon's normal control queue reserves this separate operation first.
/// The runner serializes a typed journal and bounded IO children. No normal
/// lease, SMC cutoff, native setter or production capability is acquired.
final class BatteryPreferences79Controller: @unchecked Sendable {
    typealias Transaction = BatteryPreferences79Transaction
    typealias IO = BatteryPreferences79IO
    struct Status: Codable {
        var schema = 1
        var owner: UUID?
        var phase = "idle"
        var message = "79试验默认关闭；未执行。"
        var active = false
        var recoveryPending = false
        var mutationOutcomeUnknown = false
        var targetSaved = false
        var targetRegistered = false
        var physicalDischargeObserved = false
        var restored = false
        var observation: Transaction.Observation?
        var updatedAt = Date()
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "SuperIsland.preferences79-review", qos: .utility)
    private var state = Status()
    private var cancelled = false
    private var running = false
    let canStart = BatteryPreferences79Identity.sealed()
    var afterRecovery: (() -> Void)?

    var blocksNormalControl: Bool {
        lock.lock(); let busy = running || state.recoveryPending; lock.unlock()
        return busy || BatteryPreferences79Identity.pending
    }
    func data() -> Data {
        lock.lock(); let value = state; lock.unlock()
        return (try? JSONEncoder().encode(value)) ?? Data()
    }
    func begin(owner: UUID) throws {
        guard canStart, BatteryPreferences79Identity.sealed() else { throw IO.failure("未密封启用独立79试验；没有开始。") }
        try reserve(owner: owner, recovery: false)
    }
    func recoverAtStartup() throws { try reserve(owner: nil, recovery: true) }
    func finishReviewKeeping85(owner: UUID) throws {
        guard canStart, BatteryPreferences79Identity.sealed() else { throw IO.failure("当前包未密封启用交接。") }
        lock.lock(); defer { lock.unlock() }
        guard !running, state.recoveryPending || BatteryPreferences79Identity.pending else {
            throw IO.failure("试验仍在运行或没有恢复责任，未交接。")
        }
        running = true
        state.active = true; state.recoveryPending = true
        state.phase = "handoff85"; state.message = "只读核对用户85及旧进程退出；尚未完成交接。"; state.updatedAt = Date()
        queue.async { self.runHandoff85(owner: owner) }
    }
    private func runHandoff85(owner: UUID) {
        var opened: BatteryPreferences79JournalStore?
        var completed = false
        var stage = "检查平台与旧记录"
        defer {
            withExtendedLifetime(opened) {}
            opened = nil
            lock.lock(); running = false; lock.unlock()
            if completed { afterRecovery?() }
        }
        do {
            try IO.validatePlatform()
            let store = try BatteryPreferences79JournalStore(mutating: true); opened = store
            guard let data = try store.load() else { throw IO.failure("恢复记录不可见，未推断交接完成。") }
            let record = try JSONDecoder().decode(Transaction.Record.self, from: data)
            var evidence = try BatteryPreferences79Handoff(record: record, owner: owner, wall: Date(), now: IO.continuousNow)
            update { $0.owner = record.owner }
            while true {
                stage = "核对进程身份与只读电池快照"
                let sample = try BatteryPreferences79HandoffRead.capture()
                stage = "核对85目标、原守卫与连续新采样"
                if try evidence.observe(sample, now: IO.continuousNow) {
                    stage = "持久归档与结束独立试验"
                    try store.finishHandoff85(expected: data, receipt: evidence.receipt())
                    completed = true
                    update {
                        $0.phase = "superseded"; $0.active = false; $0.recoveryPending = false
                        $0.mutationOutcomeUnknown = false; $0.restored = false
                        $0.message = "独立试验已归档；系统暂保留85，SuperIsland长期目标未改变。未声称恢复原80。"
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        } catch {
            update {
                $0.active = false; $0.recoveryPending = true; $0.phase = "recovery-pending"
                $0.mutationOutcomeUnknown = true
                $0.message = "用户85交接未完成（" + stage + "）：" + error.localizedDescription + "；恢复记录保留。"
            }
        }
    }
    private func reserve(owner: UUID?, recovery: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running, recovery || !state.recoveryPending,
              recovery || !BatteryPreferences79Identity.pending else { throw IO.failure("试验/恢复责任仍存在，未开始新的79写入。") }
        running = true; cancelled = recovery
        state = Status(owner: owner, phase: recovery ? "recovering" : "preparing",
                       message: recovery ? "发现持久试验记录，只恢复，不重跑79。" : "准备固定79试验；尚未确认目标或物理效果。",
                       active: true, recoveryPending: recovery)
        queue.async { self.run(owner: owner, recovery: recovery) }
    }
    func cancel(owner: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        // Trial cancellation means restore its original target; it must never
        // be applied to the separate read-only acceptance of a user's 85.
        guard running, state.active, state.phase != "handoff85", state.owner == owner else { throw IO.failure("没有属于此请求的活动79试验。") }
        cancelled = true
        state.message = "已请求取消；等待当前有界IO结束并恢复，尚未确认。"; state.updatedAt = Date()
    }
    private var cancellationRequested: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func update(_ operation: (inout Status) -> Void) {
        lock.lock(); operation(&state); state.updatedAt = Date(); lock.unlock()
    }

    private func run(owner: UUID?, recovery: Bool) {
        var engine: Transaction?
        var transport: Transport?
        var store: BatteryPreferences79JournalStore?
        var issue: String?
        defer {
            // The file, not a displayed success badge, remains the write gate.
            // File absence after unlink+failed directory fsync does not erase
            // the live transaction's known, unacknowledged cleanup duty.
            let pending = BatteryPreferences79Identity.pending || engine?.record != nil || engine?.mutationOutcomeUnknown == true
            update { value in
                value.active = false; value.recoveryPending = pending
                value.mutationOutcomeUnknown = engine?.mutationOutcomeUnknown ?? pending
                if let issue { value.message = issue }
                if pending { value.phase = "recovery-pending" }
                else if value.restored { value.phase = "finished" }
                else { value.phase = "rejected" }
            }
            store = nil // Release the process lock before normal prepare resumes.
            lock.lock(); running = false; lock.unlock()
            if !pending { afterRecovery?() }
        }
        do {
            try IO.validatePlatform()
            let opened = try BatteryPreferences79JournalStore(mutating: true); store = opened
            let loaded = try opened.load().map { try JSONDecoder().decode(Transaction.Record.self, from: $0) }
            if recovery, loaded == nil { throw IO.failure("恢复记录已不可见，未推断已恢复。") }
            if !recovery, loaded != nil { throw IO.failure("已有试验恢复记录，未覆盖。") }
            let io = try Transport(beforeSubmission: { [weak self] in self?.cancellationRequested == true }); transport = io
            let transaction = try Transaction(record: loaded, read: io.read, write: io.write,
                save: { record in try opened.save(record.map { try JSONEncoder().encode($0) }) },
                signal: io.signal, inspect: { try io.observe().0 }, continuousNow: { IO.continuousNow })
            engine = transaction
            if let loaded {
                update { $0.owner = loaded.owner; $0.phase = "recovering"; $0.recoveryPending = true }
                io.controlDeadline = loaded.deadlineContinuous
            } else {
                guard let owner, !cancellationRequested else { throw IO.failure("准备期间已取消；未写入79。") }
                let observed = try io.observeAdmission().0, now = IO.continuousNow, boot = try IO.bootID()
                let record = try transaction.prepareAdmission(owner: owner, bootID: boot, now: now, observation: observed)
                io.controlDeadline = record.deadlineContinuous
                guard !cancellationRequested else { throw IO.failure("写入前已取消，转入原值恢复。") }
                try transaction.confirmAdmission(bootID: boot, now: IO.continuousNow)
                try transaction.apply(bootID: boot, now: IO.continuousNow)
                update { $0.phase = "observing79"; $0.recoveryPending = true; $0.message = "79目标已提交；保存、登记和物理效果仍分别观察。" }
                // Real native response and battery contexts can take a minute.
                // Submission acknowledgment is not a new physical sample.
                var evidence = try BatteryPreferences79DischargeEvidence(startedWall: Date(), startedContinuous: IO.continuousNow)
                let observeUntil = min(record.deadlineContinuous, IO.continuousNow + Transaction.observationDuration)
                repeat {
                    guard !cancellationRequested, IO.continuousNow < observeUntil else { break }
                    let observation = try transaction.observe(restoring: false)
                    guard !observation.competingController, !observation.calibrationActive,
                          observation.level >= 79, observation.level <= 85, observation.adapterPresent else { break }
                    let physicallyObserved = try evidence.observe(observation, updateTime: io.lastUpdateTime, now: IO.continuousNow)
                    update { value in
                        value.observation = observation
                        value.targetSaved = value.targetSaved ||
                            (observation.rawPreferenceLimit == 79 && observation.rawPreferenceEnabled == 1)
                        value.targetRegistered = value.targetRegistered || Set(observation.registrations) == [79]
                        value.physicalDischargeObserved = value.physicalDischargeObserved || physicallyObserved
                    }
                    if observation.level <= 79 || physicallyObserved { break }
                    Thread.sleep(forTimeInterval: 1)
                } while true
            }
        } catch { issue = "试验未完成：" + error.localizedDescription }

        guard let engine, let io = transport, engine.record != nil else { return }
        io.restoring = true
        update { $0.phase = "restoring"; $0.recoveryPending = true; $0.message = "恢复原80及直接控制值；独立验证完成前保留记录。" }
        do {
            try engine.restore(bootID: IO.bootID(), now: IO.continuousNow)
            // Count only updates published after the final restoration
            // submission was acknowledged, never updates from a slow restore.
            var evidence = try BatteryPreferences79RecoveryEvidence(startedWall: Date(), startedContinuous: IO.continuousNow)
            while true {
                let observation = try engine.observe(restoring: true), updateTime = io.lastUpdateTime
                update { $0.observation = observation; $0.mutationOutcomeUnknown = engine.mutationOutcomeUnknown }
                if try evidence.observe(observation, updateTime: updateTime, now: IO.continuousNow) {
                    if try engine.finishRestoration(validated: true) {
                        update { value in
                            value.restored = true
                            value.message = value.physicalDischargeObserved
                                ? "本次固定79观察及原80恢复已确认；未开放生产低限值或完整校准。"
                                : "原80恢复已确认；本次79物理效果未确认。"
                        }
                        return
                    }
                }
                if engine.mutationOutcomeUnknown {
                    throw IO.failure("存在超时/未确认写入；即使暂时恢复80也不能清除责任。没有提交栅栏证据，恢复记录保留。")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        } catch { issue = (issue.map { $0 + "；" } ?? "") + "恢复未完成：" + error.localizedDescription }
    }

    private final class Transport {
        private let executable: URL
        private var cached: [Transaction.Key: Transaction.Value] = [:]
        var restoring = false
        var controlDeadline = 0.0
        private(set) var lastUpdateTime: Date?
        private let beforeSubmission: () -> Bool
        init(beforeSubmission: @escaping () -> Bool) throws {
            self.beforeSubmission = beforeSubmission
            guard let source = Bundle.main.executableURL else { throw IO.failure("系统辅助程序路径缺失。") }
            executable = try BatteryReadWorkerExecutable.securedCopyOfCurrentHelper(source: source)
        }
        private func call(_ arguments: [String]) throws -> IO.Reply {
            guard restoring || !beforeSubmission() else { throw Transaction.Failure.notSubmitted }
            let data = try BatteryNativeReadProcess.run(executable: executable, arguments: [IO.argument] + arguments, timeout: 3, maximumOutput: 32_768)
            let reply = try JSONDecoder().decode(IO.Reply.self, from: data)
            guard reply.schema == 1, reply.error == nil else { throw IO.failure(reply.error ?? "试验IO回执无效。") }
            return reply
        }
        func read(_ key: Transaction.Key) throws -> Transaction.Value {
            guard let value = try call(["get", key.rawValue]).value else { throw IO.failure("偏好读取缺少带类型结果。") }
            cached[key] = value; return value
        }
        private func guards() throws -> [Transaction.Key: Transaction.Value] {
            let keys: [Transaction.Key] = [.initialChargeLimitSetDate, .disabledUntil, .mclOverridenUntilDate, .mclSavedTargetSoC]
            guard keys.allSatisfy({ cached[$0] != nil }) else { throw IO.failure("执行前守卫快照不完整。") }
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, cached[$0]!) })
        }
        func write(_ key: Transaction.Key, _ value: Transaction.Value) throws {
            guard let expected = cached[key] else { throw IO.failure("写入前没有确认原值。") }
            let request = IO.Write(desired: value, expected: expected, guards: try guards(), bootID: try IO.bootID(),
                                   expiresContinuous: IO.continuousNow + 2.9, controlDeadline: controlDeadline, restoring: restoring)
            _ = try call(["set", key.rawValue, IO.encode(request)])
            cached[key] = value // The fixed child already read back this exact type/value.
        }
        func signal() throws {
            let keys: [Transaction.Key] = [.mclLimitValue, .mclFeatureState, .isEngaged, .isManuallyChargeLimited]
            // Refresh strong fields immediately before notifying, then the child
            // compares again. CFPreferences still offers no atomic CAS primitive.
            var expected: [Transaction.Key: Transaction.Value] = [:]
            for key in keys {
                guard let prior = cached[key], try read(key) == prior else { throw IO.failure("通知前强控制值已被修改，未接受新外部值作为本次目标。") }
                expected[key] = prior
            }
            let request = IO.Signal(expected: expected, guards: try guards(), bootID: try IO.bootID(),
                                    expiresContinuous: IO.continuousNow + 2.9, controlDeadline: controlDeadline, restoring: restoring)
            _ = try call(["signal", IO.encode(request)])
        }
        func observe() throws -> (Transaction.Observation, Date?) {
            let reply = try call(["observe"])
            guard let observation = reply.observation else { throw IO.failure("试验物理/原生读回缺失。") }
            lastUpdateTime = reply.updateTime
            return (observation, reply.updateTime)
        }
        func observeAdmission() throws -> (Transaction.Observation, Date?) {
            let reply = try call(["observe-admission"])
            guard let observation = reply.observation,
                  observation.nativeLimit == nil, observation.nativeEnabled == nil else { throw IO.failure("纯准入观察结果无效。") }
            return (observation, reply.updateTime)
        }
    }
}
#endif
