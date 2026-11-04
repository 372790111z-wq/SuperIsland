import Foundation
import Darwin
import OSLog

final class BatteryManagementDaemon: NSObject, NSXPCListenerDelegate, BatteryManagementProtocol {
    private let queue = DispatchQueue(label: BatteryManagementIdentity.label)
    private let driver = BatteryHardwareDriver()
    private let diagnosticOnly = BatteryManagementIdentity.diagnosticHelper(arguments: ProcessInfo.processInfo.arguments,
        packageFlag: BatteryManagementIdentity.packageDiagnosticsOnly(executableURL: Bundle.main.executableURL))
    private var calibration: BatteryCalibrationRuntime?
    private var lease: BatteryOverrideLease?
    private var controlLock: Int32 = -1
    private var cutoff: BatteryCutoffSession?
    private var request: BatteryControlRequest?
    private var lastAdmittedRequest: BatteryControlRequest?
    private let pauseRefreshTrial = BatteryManagementIdentity.packagePauseRefreshTrial(executableURL: Bundle.main.executableURL)
    private var pauseRefreshTicket: BatteryPauseRefreshTicket?
    private var pauseRefreshVerification: BatteryPauseRefresh.Verification?
    private var exitHoldVerification: BatteryExitHoldVerification?
    private var lastExitHoldObservation = -Double.infinity
    private var completedRequest: BatteryCompletedRequest?
    private var policy = BatteryControlPolicy()
    private var verification = BatteryControlVerification()
    private var nativeDrainVerification = BatteryNativeDrainVerification()
    private var timer: DispatchSourceTimer?
    private var report = BatteryControlReport()
    private var manualRetry: BatteryManualRetry?
    private var failed = false
    private var recoveryUnknown = true
    #if BATTERY_REVIEW || DEBUG
    private var lastNativeReadDiagnostic: TimeInterval?
    #endif
    private var executionStage = "辅助程序初始化"
    #if BATTERY_REVIEW
    private let preferences79 = BatteryPreferences79Controller()
    #endif
    private let controlLog = Logger(subsystem: BatteryManagementIdentity.label, category: "control")

    func prepare() {
        report.mechanism = driver.reportedMechanism?.rawValue ?? "此设备没有可用的充电控制接口"
        report.dischargeSupported = driver.dischargeSupported
        report.minimumDischargeTarget = driver.minimumDischargeTarget
        report.dischargeMechanism = driver.dischargeMechanism
        report.ledSupported = driver.ledSupported
        report.highPowerSupported = driver.highPowerSupported
        report.calibrationSupported = driver.calibrationSupported
        report.nativeCutoffReviewTrial = driver.nativeCutoffReviewTrial
        #if BATTERY_REVIEW
        report.preferences79Review = preferences79.canStart
        preferences79.afterRecovery = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.lease == nil { self.prepare() }
                else {
                    self.report.available = !self.failed && !self.recoveryUnknown && self.driver.mechanism != nil
                    self.report.recoveryPending = false
                    self.report.message = "独立79试验已退出；普通控制尚未接管。"
                }
            }
        }
        #endif
        do {
            guard getuid() == 0 else { throw BatteryControlError.unavailable("辅助程序需要系统授权。") }
            // This check precedes ordinary journal auto-recovery and all writes.
            // An unreadable/corrupt/pending experimental journal is not absence.
            if BatteryPreferences79Identity.pending {
                report.available = false; report.recoveryPending = true
                report.message = "存在79试验恢复记录；普通控制与自动恢复未启动。"
                #if BATTERY_REVIEW
                if !diagnosticOnly { try preferences79.recoverAtStartup() }
                #endif
                return
            }
            #if BATTERY_REVIEW || DEBUG
            report.smcDiscovery = BatterySMCDiscovery.capture(sourceUID: getuid()) { key in
                guard let smc = self.driver.smc else { throw BatteryControlError.unavailable("SMC未连接。") }
                return try smc.read(key)
            }
            #endif
            report.diagnosticOnly = diagnosticOnly
            if diagnosticOnly {
                report.available = false; report.dischargeSupported = false; report.calibrationSupported = false
                report.message = "固定只读诊断：未启用控制，未读取或恢复历史控制日志。"
                return // No recovery-directory I/O, lease, watchdog or hardware writes.
            }
            let fm = FileManager.default
            let directory = URL(fileURLWithPath: "/Library/Application Support/\(BatteryManagementIdentity.label)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try fm.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0 else {
                throw BatteryControlError.recovery("恢复目录所有权不可信。")
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if controlLock < 0 {
                let descriptor = open(directory.appendingPathComponent("control.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw BatteryControlError.recovery("控制互斥锁不可用。") }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      info.st_nlink == 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    close(descriptor); throw BatteryControlError.recovery("另一个辅助程序仍持有控制锁。")
                }
                controlLock = descriptor
            }
            let leaseStore = BatteryLeaseJournalStore(directory: directory)
            var journal: BatteryOverrideLease.Journal?
            if let data = try leaseStore.load() {
                journal = try JSONDecoder().decode(BatteryOverrideLease.Journal.self, from: data)
                guard journal?.schemaVersion == nil || journal?.schemaVersion == 2 || journal?.schemaVersion == 3 || journal?.schemaVersion == 4 else {
                    throw BatteryControlError.recovery("恢复记录版本未知，已保留记录并停止控制。")
                }
                if let journal {
                    if let preferences = journal.preferences {
                        guard journal.schemaVersion == 4, !journal.entries.keys.contains(where: { $0.hasPrefix("native") }) else {
                            throw BatteryControlError.recovery("偏好恢复记录版本或后端所有权冲突。")
                        }
                        try BatteryPreferencesLease.validate(preferences)
                    }
                    if journal.detachedExitHold == true {
                        guard journal.schemaVersion == 4, journal.entries.isEmpty, journal.preferences?.phase == .active else {
                            throw BatteryControlError.recovery("退出暂停恢复记录不一致。")
                        }
                    }
                    try BatteryCutoffTargets.validateRestoration(journal)
                    guard journal.entries.allSatisfy({ driver.canRestore($0.key, value: $0.value.original) }) else {
                        throw BatteryControlError.recovery("恢复记录包含未支持的原值，已保留记录并停止控制。")
                    }
                }
            }
            lease = BatteryOverrideLease(journal: journal, read: driver.read, write: driver.write, save: { journal in
                // Even when fault persistence failed, restore hardware first.
                // Retain the sole recovery journal so restart cannot appear clean.
                if journal == nil, self.manualRetry?.durable != true {
                    throw BatteryControlError.recovery("故障记录未持久保存，保留恢复日志。")
                }
                try leaseStore.save(journal.map { try JSONEncoder().encode($0) })
            })
            // A trusted original and persisted write intent suffice to release
            // CHIE even if a later cutoff record/checkpoint cannot be read.
            try lease?.releaseCHIEImmediately()
            let retryStore = BatteryLeaseJournalStore(directory: directory, name: "manual-retry")
            manualRetry = BatteryManualRetry(load: retryStore.load, save: { try retryStore.save($0) })
            pauseRefreshTicket = BatteryPauseRefreshTicket(directory: directory)
            if let backend = driver.preferencesBackend, let lease {
                lease.preferencesIO = backend.io(expiry: { [weak lease] in lease?.expires ?? 0 })
                lease.confirmPreferences = { record in
                    try BatteryPreferencesLease.restored(record, snapshot: backend.snapshot(),
                        registrations: self.driver.registeredLimits(fresh: true))
                }
            }
            let cutoffFile = directory.appendingPathComponent("cutoff.json")
            var cutoffRecord: BatteryCutoffSession.Record?
            if fm.fileExists(atPath: cutoffFile.path) {
                let attrs = try fm.attributesOfItem(atPath: cutoffFile.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                      (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 65_536 else {
                    throw BatteryControlError.recovery("断供恢复记录不可信，已停止控制。")
                }
                cutoffRecord = try JSONDecoder().decode(BatteryCutoffSession.Record.self, from: Data(contentsOf: cutoffFile))
            }
            cutoff = try BatteryCutoffSession(record: cutoffRecord, save: { record in
                guard let record else {
                    if fm.fileExists(atPath: cutoffFile.path) { try fm.removeItem(at: cutoffFile) }
                    let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard dir >= 0 else { throw BatteryControlError.recovery("断供记录删除尚未同步。") }
                    defer { close(dir) }
                    guard fsync(dir) == 0 else { throw BatteryControlError.recovery("断供记录删除尚未同步。") }
                    return
                }
                try JSONEncoder().encode(record).write(to: cutoffFile, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cutoffFile.path)
                let descriptor = open(cutoffFile.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw BatteryControlError.recovery("无法保存断供恢复记录。") }
                defer { close(descriptor) }
                guard fsync(descriptor) == 0 else { throw BatteryControlError.recovery("断供恢复记录未落盘。") }
                let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard dir >= 0 else { throw BatteryControlError.recovery("断供恢复目录未同步。") }
                defer { close(dir) }
                guard fsync(dir) == 0 else { throw BatteryControlError.recovery("断供恢复目录未同步。") }
            })
            let calibrationFile = directory.appendingPathComponent("calibration.json")
            var calibrationRecord: BatteryCalibrationRuntime.Record?
            if fm.fileExists(atPath: calibrationFile.path) {
                let attributes = try fm.attributesOfItem(atPath: calibrationFile.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 65_536 else {
                    throw BatteryControlError.recovery("校准恢复记录不可信，已停止控制。")
                }
                calibrationRecord = try JSONDecoder().decode(BatteryCalibrationRuntime.Record.self, from: Data(contentsOf: calibrationFile))
            }
            calibration = try BatteryCalibrationRuntime(record: calibrationRecord, save: { record in
                try JSONEncoder().encode(record).write(to: calibrationFile, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: calibrationFile.path)
                let descriptor = open(calibrationFile.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw BatteryControlError.recovery("无法保存校准恢复记录。") }
                defer { close(descriptor) }
                guard fsync(descriptor) == 0 else { throw BatteryControlError.recovery("校准恢复记录未落盘。") }
            })
            if let record = cutoff?.record, record.owner != lease?.journal?.owner {
                throw BatteryControlError.recovery("断供恢复会话缺少同一所有者的原值日志，已保留责任并停止新控制。")
            }
            recoveryUnknown = false
            if let journal = lease?.journal, journal.detachedExitHold != true {
                manualRetry?.fail(owner: journal.owner, operation: nil, reason: "辅助程序重启时仍有控制恢复责任。")
            }
            if lease?.journal != nil {
                _ = try releaseControl(reason: .exit)
            } else { try calibration?.recoveredAfterRestart() }
            report.available = driver.mechanism != nil && cutoff?.recovering != true
            if cutoff?.recovering == true { report.message = cutoff!.message }
            else {
                report.message = report.available ? "辅助程序就绪；尚未开始控制" : "设备没有可用的控制接口；仅显示电池读数"
                if driver.mechanism == nil, let failure = driver.nativeReadInitializationFailure {
                    report.preserveFailure(stage: "初始化原生读取", detail: failure)
                    report.message = "原生读取尚未确认，未启用控制：" + failure
                }
            }
        } catch { record(error) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let rapidObservation = driver.nativeCutoffReviewTrial || pauseRefreshTrial
        timer.schedule(deadline: .now() + (rapidObservation ? 1 : 5),
            repeating: rapidObservation ? 1 : 5, leeway: .milliseconds(rapidObservation ? 0 : 1000))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: BatteryManagementProtocol.self)
        connection.exportedObject = self
        connection.resume(); return true
    }
    private func hasCutoffIntent(_ journal: BatteryOverrideLease.Journal?) -> Bool {
        guard let key = driver.dischargeKey, let entry = journal?.entries[key] else { return false }
        let enabled = key == "CHIE" ? 8 : 1
        return entry.expected == enabled || entry.prior == enabled
    }
    private func ownedCutoff(owner: UUID) throws -> Bool {
        guard let cutoff, cutoff.record?.phase == .discharging else { return false }
        let key = driver.dischargeKey
        return try cutoff.ownsCutoff(owner: owner, journal: lease?.journal, key: key,
            actual: try key.map { try driver.read($0) })
    }

    private func controlsMatch(_ journal: BatteryOverrideLease.Journal) throws -> Bool {
        if let key = driver.dischargeKey, let value = journal.entries[key]?.expected,
           try driver.read(key) != value { return false }
        if let preferences = journal.preferences {
            guard let backend = driver.preferencesBackend else { return false }
            return try BatteryPreferencesLease.restored(preferences, snapshot: backend.snapshot(),
                registrations: driver.registeredLimits(fresh: true))
        }
        let limit = journal.entries["nativeAPILimit"]?.expected
        let enabled = journal.entries["nativeAPIEnabled"]?.expected
        if limit != nil || enabled != nil {
            return BatteryNativeRegistration.restorationMatches(limit: limit, enabled: enabled,
                savedManualLimit: driver.savedNativeLimit(), registrations: driver.registeredLimits(fresh: true))
        }
        return true
    }
    @discardableResult
    private func observeRecovery() throws -> Bool {
        guard let cutoff, cutoff.recovering, let journal = lease?.journal else { return self.cutoff?.record == nil }
        let recovered: Bool
        if cutoff.record?.pausePulse != nil, let lease {
            // A: supply release only. Cancellation/restart must not wait for B
            // (successful pause) before restoring the original preferences.
            try lease.releaseCHIEImmediately(owner: journal.owner)
            recovered = try cutoff.observeRecovery(powered: driver.adapterInputObservation(),
                controlsMatch: try driver.read("CHIE") == 0, now: BatteryPauseRefresh.continuousTime())
        } else if cutoff.record?.requiresSupplyRecovery == true, let lease {
            recovered = try BatteryCutoffHandoff.recover(lease: lease, session: cutoff,
                now: ProcessInfo.processInfo.systemUptime, powered: driver.adapterInputObservation,
                controlsMatch: controlsMatch)
        } else {
            // Native preference restoration needs matching registrations, not
            // a power cycle: the original lower limit may intentionally drain.
            recovered = try cutoff.observeRecovery(powered: nil,
                controlsMatch: controlsMatch(journal), now: ProcessInfo.processInfo.systemUptime)
        }
        if !recovered {
            report.available = false; report.message = cutoff.message
            if cutoff.needsAttention {
                try lease?.releaseCHIEImmediately()
                manualRetry?.fail(owner: request?.owner ?? lastAdmittedRequest?.owner ?? lease?.journal?.owner,
                                  operation: request?.operationID ?? lastAdmittedRequest?.operationID, reason: cutoff.message)
                report.requiresManualRetry = true
            }
        }
        return recovered
    }
    /// Shared normal/calibration path: persist cutoff intent before the lease
    /// can write it, and start observation BEFORE any matching release write.
    private func applyTargets(_ targets: [String: Int], owner: UUID, telemetry: BatteryTelemetry) throws -> Bool {
        guard let lease, let cutoff else { throw BatteryControlError.recovery("断供恢复服务尚未就绪。") }
        let now = ProcessInfo.processInfo.systemUptime
        if let key = driver.dischargeKey, targets[key] == (key == "CHIE" ? 8 : 1) {
            if cutoff.record == nil {
                if driver.nativeCutoffReviewTrial { try BatteryNativeCutoffTrial.validateStart(telemetry: telemetry) }
                let original = try lease.journal?.entries[key]?.original ?? driver.read(key)
                guard original == 0 else { throw BatteryControlError.conflict("断供原值不属于本实例，未开始覆盖。") }
            }
            if driver.mechanism == .native, cutoff.record == nil {
                guard targets["nativeAPILimit"] == driver.nativeDischargeNeutralTarget, targets["nativeAPIEnabled"] == 1 else {
                    throw BatteryControlError.invalid("主动断供前系统限充未中和，未写入断供。")
                }
                guard try BatteryCutoffHandoff.prepareNative(lease: lease, owner: owner, neutralTarget: driver.nativeDischargeNeutralTarget,
                    registrationsMatch: controlsMatch) else {
                    report.message = "正在等待系统限充退出干预；尚未开始主动放电"
                    report.registeredTarget = driver.registeredLimit(); report.nativeSavedLimit = driver.savedNativeLimit()
                    return false
                }
            }
            // ExternalConnected is insufficient: r17 retained AC=true during
            // native-only drain. Missing/low input cannot authorize a cutoff.
            try cutoff.arm(owner: owner, powered: telemetry.onAC && driver.adapterInputObservation() == true, now: now)
        } else if cutoff.record?.phase == .discharging {
            try cutoff.beginRecovery(owner: owner, releasingLease: false, now: now,
                mayHaveApplied: hasCutoffIntent(lease.journal))
        }
        if cutoff.recovering, try !observeRecovery() { return false }
        var registerTargets = targets
        let preferenceTarget = registerTargets.removeValue(forKey: "preferencesTarget")
        try lease.apply(registerTargets, owner: owner)
        if let preferenceTarget { try lease.applyPreferences(target: preferenceTarget, owner: owner) }
        return true
    }
    @discardableResult
    private func releaseControl(owner: UUID? = nil, reason: BatteryCalibrationSession.EndReason) throws -> Bool {
        executionStage = "恢复自有控制"
        guard let lease, let cutoff else { throw BatteryControlError.recovery("恢复服务尚未就绪。") }
        let effectiveOwner = lease.journal?.owner ?? cutoff.record?.owner
        if let owner, let effectiveOwner, owner != effectiveOwner { throw BatteryControlError.conflict("不能释放其他实例的控制。") }
        // Release before any new recovery checkpoint or preference operation.
        try lease.releaseCHIEImmediately(owner: owner)
        manualRetry?.retryPersistence()
        request = nil; completedRequest = nil; exitHoldVerification = nil; pauseRefreshVerification = nil
        report.completedOperationID = nil; report.completionReason = nil
        if let effectiveOwner {
            if hasCutoffIntent(lease.journal) || cutoff.record != nil {
                try cutoff.beginRecovery(owner: effectiveOwner, releasingLease: true,
                    now: cutoff.record?.pausePulse != nil ? BatteryPauseRefresh.continuousTime() : ProcessInfo.processInfo.systemUptime,
                    mayHaveApplied: hasCutoffIntent(lease.journal))
            }
        }
        // Physical recovery completes with the native backend still neutral.
        // Never restore a lower original MCL before this independent check.
        if cutoff.record?.requiresSupplyRecovery == true, try !observeRecovery() { return false }
        if cutoff.record == nil, let effectiveOwner,
           (lease.journal?.preferences != nil || lease.journal?.entries.keys.contains(where: { $0 == "nativeAPILimit" || $0 == "nativeAPIEnabled" }) == true) {
            try cutoff.beginRecovery(owner: effectiveOwner, releasingLease: true,
                now: ProcessInfo.processInfo.systemUptime, requiresSupplyRecovery: false)
        }
        let restored: Bool
        if cutoff.recovering {
            restored = try lease.release(owner: owner) { _ in try self.observeRecovery() }
        } else { restored = try lease.release(owner: owner) }
        guard restored, cutoff.record == nil else { return false }
        try calibration?.released(reason: reason)
        try manualRetry?.releasedSuccessfully()
        policy = BatteryControlPolicy(); verification.reset(); nativeDrainVerification.reset()
        report.registeredTarget = nil; report.nativeSavedLimit = nil; report.mode = .automatic
        report.available = driver.mechanism != nil
        report.message = "自有控制恢复已确认；供电及系统目标按实际读回显示"
        return true
    }
    private func data(for owner: UUID? = nil) -> Data {
        report.timestamp = Date()
        report.requiresManualRetry = manualRetry?.required ?? true
        report.manualRetryID = manualRetry?.faultID
        report.exitHoldReady = lease?.journal?.detachedExitHold == true
        report.calibration = calibration?.record?.status
        report.ownedAdapterCutoff = owner.map { (try? ownedCutoff(owner: $0)) == true }
        report.cutoffPhase = cutoff?.record?.phase
        report.recoveryPending = recoveryUnknown || cutoff?.recovering == true || (failed && lease?.journal != nil)
        if BatteryPreferences79Identity.pending {
            report.available = false; report.recoveryPending = true
            report.message = "存在79试验恢复责任，普通控制未执行。"
        }
        #if BATTERY_REVIEW
        if preferences79.blocksNormalControl {
            report.available = false; report.recoveryPending = true
            report.message = "独立79试验或恢复责任仍存在；普通控制未执行。"
        }
        #endif
        report.leaseHeldByRequester = recoveryUnknown ? nil : owner.map { lease?.journal?.owner == $0 || cutoff?.record?.owner == $0 }
        return (try? JSONEncoder().encode(report)) ?? Data()
    }
    private func record(_ error: Error, attempted: BatteryControlRequest? = nil) {
        report.preserveFailure(stage: executionStage, detail: error.localizedDescription)
        controlLog.error("Control failure: \(self.executionStage, privacy: .public): \(error.localizedDescription, privacy: .public)")
        // Hardware release precedes fault-file writes or calibration journals.
        try? lease?.releaseCHIEImmediately()
        manualRetry?.fail(owner: attempted?.owner ?? request?.owner ?? lastAdmittedRequest?.owner ?? lease?.journal?.owner,
                          operation: attempted?.operationID ?? request?.operationID ?? lastAdmittedRequest?.operationID, reason: report.lastFailure ?? error.localizedDescription)
        try? calibration?.interrupt(.permissionLost)
        failed = true; request = nil; completedRequest = nil
        report.completedOperationID = nil; report.completionReason = nil
        report.requiresManualRetry = true
        report.available = false; report.message = error.localizedDescription
        // The watchdog still attempts restoration, even after a write failed.
    }
    private func tick() {
        guard !BatteryPreferences79Identity.pending else { return }
        #if BATTERY_REVIEW
        guard !preferences79.blocksNormalControl else { return }
        #endif
        do {
            executionStage = "检查恢复责任和控制租约"
            guard let lease else { return }
            if manualRetry?.required == true { try lease.releaseCHIEImmediately() }
            manualRetry?.retryPersistence()
            if recoveryUnknown, lease.journal?.entries["CHIE"] != nil {
                // A corrupt/missing cutoff record cannot authorize restoring a
                // native preference before independent input recovery.
                try lease.releaseCHIEImmediately()
                report.available = false; return
            }
            if recoveryUnknown {
                // Metadata is missing/corrupt: restore only proven originals,
                // but never erase the lease or acknowledge physical recovery.
                _ = try lease.release(verifyRestoration: { _ in false })
                report.available = false; return
            }
            if let manualRetry, try manualRetry.handleRecovery({
                if lease.journal != nil || self.cutoff?.record != nil {
                    if try self.releaseControl(reason: .permissionLost) { self.failed = false }
                } else {
                    self.request = nil; self.completedRequest = nil; self.failed = false
                    self.report.available = self.driver.mechanism != nil
                }
            }) { return }
            if lease.journal?.detachedExitHold == true { return } // Explicit successful graceful-exit transfer only.
            if let preparing = exitHoldVerification, ProcessInfo.processInfo.systemUptime - preparing.started > 150 {
                _ = try releaseControl(reason: .timeout); return
            }
            if lease.journal != nil, ProcessInfo.processInfo.systemUptime >= lease.expires {
                _ = try releaseControl(reason: .timeout); return
            }
            if cutoff?.recovering == true {
                if cutoff?.record?.releasingLease == true { _ = try releaseControl(reason: .exit) }
                else { _ = try observeRecovery() }
                return
            }
            if lease.journal == nil {
                try calibration?.released()
                if request != nil || failed {
                    request = nil; completedRequest = nil; report.registeredTarget = nil; report.nativeSavedLimit = nil
                    report.completedOperationID = nil; report.completionReason = nil
                    report.message = failed ? report.message + "；自有变更已恢复，请手动重试" : "控制租约已到期；已恢复自身变更"
                    verification.reset()
                    failed = false; report.available = driver.mechanism != nil
                }
                return
            }
            guard !failed, var request else { return }
            executionStage = "读取电池遥测"
            let telemetry = BatteryTelemetry.read()
            if driver.mechanism == .native, telemetry.chargingObservation == nil {
                throw BatteryControlError.unavailable("实际充电状态未知，未将缺失读数当成停充确认。")
            }
            // Pending pulse verification is observe-only. In particular a SOC
            // change must never re-plan/apply a new paused ceiling before the
            // fixed candidate's range and freshness checks.
            if try BatteryPauseRefresh.handlePending(pauseRefreshVerification, request: request, telemetry: telemetry,
                observe: { target in _ = try self.refreshPausedTarget(request, target: target, telemetry: telemetry) },
                cancel: { _ = try self.releaseControl(reason: .cancelled) }) { return }
            if driver.nativeCutoffReviewTrial {
                try cutoff?.enforceDischargeDeadline(now: ProcessInfo.processInfo.systemUptime,
                    maximum: BatteryNativeCutoffTrial.maximumDuration)
                try BatteryNativeCutoffTrial.validate(request, level: telemetry.level)
            }
            executionStage = "核对断供所有权"
            let ownsCutoff = try ownedCutoff(owner: request.owner)
            if ownsCutoff {
                executionStage = "观察断供与物理连接"
                try cutoff?.observeDischarge(owner: request.owner, owned: true, powered: driver.adapterInputObservation(),
                    physicalConnection: BatteryCutoffConnection.observation(telemetry, verifiedReviewTrial: driver.nativeCutoffReviewTrial),
                    now: ProcessInfo.processInfo.systemUptime)
            }
            report.systemCalibration = BatterySystemCalibration.isActive
            if let calibration, calibration.isActive {
                try calibration.tick(telemetry: telemetry, sleeping: request.sleeping,
                    systemCalibration: report.systemCalibration, now: ProcessInfo.processInfo.systemUptime,
                    date: Date(), ownsAdapterCutoff: ownsCutoff, strictTelemetry: driver.preferencesBackend != nil) { action, preferences in
                        try self.applyCalibration(action, preferences: preferences, owner: request.owner, telemetry: telemetry)
                    }
                report.available = cutoff?.recovering != true; report.mode = .automatic
                report.message = cutoff?.recovering == true ? cutoff!.message : calibration.record?.status.title ?? "校准状态尚未确认"
                if !calibration.isActive {
                    policy.resumeAfterCalibration(limit: request.preferences.limit)
                    self.request?.calibration = nil
                }
                return
            }
            executionStage = "计算充电策略"
            var decision = try policy.decide(request: request, snapshot: telemetry, ownsAdapterCutoff: ownsCutoff)
            if decision.completed {
                report.completedOperationID = request.operationID
                report.completionReason = decision.completionReason
                let completion = BatteryCompletedRequest(request)
                completedRequest = completion; request = completion.automatic
                self.request = request
                decision = try policy.decide(request: request, snapshot: telemetry)
            }
            executionStage = "规划控制目标与校验原值"
            if driver.mechanism == .native {
                try nativeDrainVerification.prepare(active: decision.forceDischarge,
                    operationID: request.operationID, now: ProcessInfo.processInfo.systemUptime,
                    maximumDuration: driver.nativeCutoffReviewTrial ? BatteryNativeCutoffTrial.maximumDuration : nil)
            }
            let targets = try driver.targets(for: decision, request: request, telemetry: telemetry, ownedKeys: Set(lease.journal?.entries.keys.map { $0 } ?? []))
            var effectiveTargets = targets
            report.systemCalibration = BatterySystemCalibration.isActive
            if report.systemCalibration, driver.mechanism == .native, request.mode != .topUp {
                // Keep the registered preference unchanged and stop our active
                // discharge while macOS performs its own calibration charge.
                if driver.preferencesBackend != nil {
                    // Do not fight a system override with direct preferences.
                    throw BatteryControlError.conflict("macOS校准进行中，停止偏好控制并保留恢复责任。")
                }
                let existing = try driver.read("nativeAPILimit")
                effectiveTargets["nativeAPILimit"] = lease.journal?.entries["nativeAPILimit"]?.expected ?? existing
                if let key = driver.dischargeKey { effectiveTargets[key] = 0 }
            }
            executionStage = "应用控制目标并读取确认"
            guard try applyTargets(effectiveTargets, owner: request.owner, telemetry: telemetry) else {
                report.mode = request.mode; return
            }
            report.mode = request.mode; report.available = true
            if driver.mechanism == .native {
                executionStage = "核对原生限值和系统登记"
                report.registeredTarget = driver.registeredLimit()
                report.nativeSavedLimit = driver.savedNativeLimit()
                let expected = effectiveTargets[driver.nativeTargetKey]!
                if try refreshPausedTarget(request, target: expected, telemetry: telemetry) { return }
                let observation = try verification.observe(target: expected, mustStop: decision.inhibit || (telemetry.level ?? 0) >= expected,
                    charging: telemetry.charging, onAC: telemetry.onAC, registrations: driver.registeredLimits(),
                    savedManualLimit: report.nativeSavedLimit, systemOverride: report.systemCalibration,
                    now: ProcessInfo.processInfo.systemUptime)
                executionStage = "观察原生目标放电"
                let nativeDischargeActive = decision.forceDischarge
                let draining = try nativeDrainVerification.observe(active: nativeDischargeActive,
                    operationID: request.operationID, current: telemetry.current,
                    registered: nativeDischargeActive ? driver.nativeDrainRegistered(target: expected) : nil,
                    now: ProcessInfo.processInfo.systemUptime,
                    suspended: report.systemCalibration,
                    maximumDuration: driver.nativeCutoffReviewTrial ? BatteryNativeCutoffTrial.maximumDuration : nil)
                let observed = telemetry.charging ? "；设备仍在充电" : "；设备当前未充电"
                switch observation {
                case .waitingForRegistration: report.message = decision.reason + "；系统目标尚未一致登记" + observed
                case .waitingForStop: report.message = decision.reason + "；系统目标已登记，尚未确认停充" + observed
                case .holding: report.message = decision.reason + "；系统目标已登记" + observed
                case .charging: report.message = decision.reason + "；系统目标已登记；设备正在充电"
                case .waitingForCharge: report.message = decision.reason + "；系统目标已登记；设备尚未开始充电"
                case .systemOverride: report.message = decision.reason + "；macOS正在校准，系统可能临时充满" + observed
                case .unplugged: report.message = decision.reason + "；适配器当前未供电，正在使用电池"
                }
                if nativeDischargeActive && !report.systemCalibration {
                    report.message = decision.reason + (draining
                        ? "；原生Drain目标已登记，当前读数确认电池正在放电"
                        : "；等待一致的原生Drain登记及实际负电流，尚未确认放电")
                }
            } else {
                report.registeredTarget = decision.target
                report.message = decision.reason + "；控制寄存器已读回，实际充电以读数为准"
            }
        } catch {
            record(error)
            do { _ = try releaseControl(reason: .permissionLost) } catch { report.message += "；" + error.localizedDescription }
        }
    }
    /// The package seal + machine-wide ticket make this ONE review attempt,
    /// not an automatic production retry policy.
    private func refreshPausedTarget(_ request: BatteryControlRequest, target: Int,
                                     telemetry: BatteryTelemetry) throws -> Bool {
        guard pauseRefreshTrial, request.mode == .paused, driver.preferencesBackend != nil else { return false }
        if var pending = pauseRefreshVerification {
            guard pending.operationID == request.operationID else { pauseRefreshVerification = nil; return false }
            guard let record = lease?.journal?.preferences, let backend = driver.preferencesBackend else {
                throw BatteryControlError.recovery("暂停确认缺少原偏好事务。")
            }
            let matches = try BatteryPreferencesLease.activeMatches(record, snapshot: backend.snapshot(),
                target: pending.target, registrations: driver.registeredLimits(fresh: true))
            let ready = try pending.observe(telemetry, activeMatches: matches,
                input: driver.adapterInputObservation(), now: BatteryPauseRefresh.continuousTime(), date: Date())
            pauseRefreshVerification = ready ? nil : pending
            report.available = ready
            report.message = ready ? "暂停已确认：目标一致，新电池状态未充电，供电已恢复。"
                : "供电已释放；等待暂停目标与新电池状态稳定，尚未确认暂停。"
            return true
        }
        // Already stopped/matched requires no pulse. Unknown registrations must
        // never be treated as a mismatch that authorizes a hardware mutation.
        let registered = driver.registeredLimits(fresh: true)
        guard telemetry.chargingObservation == true, let registered, registered != [target] else { return false }
        guard let lease, let cutoff, cutoff.record == nil,
              let ticket = pauseRefreshTicket, let backend = driver.preferencesBackend,
              let preferences = lease.journal?.preferences else {
            throw BatteryControlError.recovery("短暂切换缺少恢复所有权。")
        }
        var lastAdmissionUpdate: Date?
        func admit() throws {
            try BatteryPreferencesBackend.validateNoCompetingController()
            guard BatterySystemCalibration.observation == false,
                  ProcessInfo.processInfo.systemUptime < lease.expires,
                  try BatteryPreferencesLease.activeMatches(preferences, snapshot: backend.snapshot(),
                      target: target, registrations: [target]) else {
                throw BatteryControlError.conflict("暂停控制租约、偏好或其他控制器状态改变。")
            }
            let latest = BatteryTelemetry.read()
            try BatteryPauseRefresh.validate(request, telemetry: latest, target: target,
                saved: driver.savedNativeLimit(), registered: driver.registeredLimits(fresh: true),
                input: driver.adapterInputObservation(), calibrationActive: calibration?.isActive == true || BatterySystemCalibration.isActive,
                now: Date())
            guard try driver.read("CHIE") == 0 else { throw BatteryControlError.conflict("CHIE已被占用。") }
            lastAdmissionUpdate = latest.reportedPower?.batteryUpdateTimeContext
        }
        try admit()
        try ticket.consume(operationID: request.operationID)
        let date = Date()
        try cutoff.armPausePulse(owner: request.owner,
            pulse: .init(operationID: request.operationID, target: target, submittedAt: date),
            now: BatteryPauseRefresh.continuousTime())
        executionStage = "单次暂停供电切换"
        let elapsed = try lease.pulseCHIE(owner: request.owner, admit: admit,
            now: BatteryPauseRefresh.continuousTime, wait: Thread.sleep(forTimeInterval:),
            writePulse: driver.writePauseRefreshCHIE)
        guard let baseline = lastAdmissionUpdate else { throw BatteryControlError.recovery("缺少最后准入时的电池更新时间。") }
        // Set acceptance's lower time bound AFTER release/readback/checkpoint.
        // An update during admission or the pulse cannot prove pause success.
        pauseRefreshVerification = .init(operationID: request.operationID, target: target,
            started: BatteryPauseRefresh.continuousTime(), submittedAt: Date(), baselineUpdate: baseline)
        controlLog.notice("Pause refresh CHIE0 acknowledged; command interval=\(elapsed, privacy: .public)s; awaiting independent supply and pause verification")
        report.available = false; report.message = "短暂切换已释放；正在独立确认供电和暂停结果。"
        return true
    }

    private func applyCalibration(_ action: BatteryCalibrationRuntime.Action, preferences: BatteryControlPreferences,
                                  owner: UUID, telemetry: BatteryTelemetry) throws -> Bool {
        guard let lease else { throw BatteryControlError.recovery("校准缺少恢复租约。") }
        let decision: BatteryControlDecision
        switch action {
        case .drive(let value): decision = value
        case .yieldToSystem: decision = .init(target: 100, reason: "等待系统校准")
        case .restorePreferences:
            decision = .init(target: preferences.limit, inhibit: (telemetry.level ?? 0) >= preferences.limit,
                reason: "恢复校准前设置", nativeHoldTarget: preferences.limit)
        }
        let request = BatteryControlRequest(owner: owner, preferences: preferences)
        var targets = try driver.targets(for: decision, request: request, telemetry: telemetry,
            ownedKeys: Set(lease.journal?.entries.keys.map { $0 } ?? []), calibrating: true)
        if case .yieldToSystem = action, driver.mechanism == .native {
            if driver.preferencesBackend != nil {
                throw BatteryControlError.conflict("系统校准取得控制，停止本次校准并保留恢复责任。")
            }
            if let expected = lease.journal?.entries["nativeAPILimit"]?.expected { targets["nativeAPILimit"] = expected }
            else { targets["nativeAPILimit"] = try driver.read("nativeAPILimit") }
        }
        guard try applyTargets(targets, owner: owner, telemetry: telemetry) else { return false }
        if driver.mechanism == .native, let target = targets[driver.nativeTargetKey] {
            report.registeredTarget = driver.registeredLimit(); report.nativeSavedLimit = driver.savedNativeLimit()
            if case .yieldToSystem = action { verification.reset(); return false }
            let observed = try verification.observe(target: target,
                mustStop: decision.forceDischarge || decision.inhibit,
                charging: telemetry.charging, onAC: telemetry.adapterPresent,
                registrations: driver.registeredLimits(), savedManualLimit: report.nativeSavedLimit,
                systemOverride: false, now: ProcessInfo.processInfo.systemUptime)
            let draining = decision.forceDischarge
            try nativeDrainVerification.prepare(active: draining, operationID: owner, now: ProcessInfo.processInfo.systemUptime)
            let drainConfirmed = try nativeDrainVerification.observe(active: draining, operationID: owner,
                current: telemetry.current, registered: draining ? driver.nativeDrainRegistered(target: target) : nil,
                now: ProcessInfo.processInfo.systemUptime)
            return report.registeredTarget == target && report.nativeSavedLimit == target
                && observed != .waitingForRegistration && observed != .waitingForStop && (!draining || drainConfirmed)
        }
        report.registeredTarget = decision.target
        return try verification.confirmPhysicalStop(target: decision.target,
            required: decision.forceDischarge || decision.inhibit, charging: telemetry.charging,
            now: ProcessInfo.processInfo.systemUptime)
    }
    func inspect(reply: @escaping (Data) -> Void) { queue.async { reply(self.data()) } }
    func diagnoseNativeReads(reply: @escaping (Data) -> Void) {
        #if BATTERY_REVIEW || DEBUG
        queue.async {
            #if BATTERY_REVIEW
            guard !self.preferences79.blocksNormalControl else { reply(self.data()); return }
            #endif
            // Diagnostics never create/renew/release ownership, acknowledge a
            // fault or share the watchdog queue with an active control session.
            guard !self.recoveryUnknown, self.lease != nil, self.cutoff != nil,
                  self.lease?.journal == nil, self.cutoff?.record == nil,
                  self.calibration?.isActive != true else {
                var response = self.report
                response.nativeReadDiagnostics = nil
                response.smcDirectReadDiagnostics = nil
                response.smcDirectReadError = nil
                response.message = "控制或恢复会话存在/状态未知；未运行原生查询诊断。"
                reply((try? JSONEncoder().encode(response)) ?? Data()); return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = self.lastNativeReadDiagnostic, now - previous < 10 {
                reply(self.data()); return
            }
            self.report.nativeReadDiagnostics = self.driver.nativeReadDiagnostics()
            do {
                self.report.smcDirectReadDiagnostics = try BatteryNativeReadTransport().fixedSMCReadDiagnostics()
                self.report.smcDirectReadError = nil
            } catch {
                self.report.smcDirectReadDiagnostics = nil
                self.report.smcDirectReadError = String(error.localizedDescription.prefix(768))
            }
            self.lastNativeReadDiagnostic = ProcessInfo.processInfo.systemUptime
            reply(self.data())
        }
        #else
        queue.async {
            var response = self.report
            response.message = "固定只读探针仅由独立验证包提供；本次未运行诊断。"
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
        #endif
    }
    func preferences79(action: String, owner: String, reply: @escaping (Data) -> Void) {
        #if BATTERY_REVIEW
        queue.async {
            do {
                guard action.utf8.count <= 16, owner.utf8.count <= 36, !self.diagnosticOnly else {
                    throw BatteryControlError.unavailable("只读诊断不执行79试验。")
                }
                switch action {
                case "inspect": break
                case "start":
                    guard self.report.available, !self.recoveryUnknown, !self.failed,
                          self.lease != nil, self.lease?.journal == nil, self.cutoff?.record == nil,
                          self.calibration?.isActive != true, let id = UUID(uuidString: owner) else {
                        throw BatteryControlError.conflict("普通控制/校准/恢复未空闲或身份无效，未开始79试验。")
                    }
                    try self.preferences79.begin(owner: id)
                case "cancel":
                    guard let id = UUID(uuidString: owner) else { throw BatteryControlError.invalid("试验取消身份无效。") }
                    try self.preferences79.cancel(owner: id)
                case "keep85":
                    guard let id = UUID(uuidString: owner) else { throw BatteryControlError.invalid("交接身份无效。") }
                    // Ending an independent Review cannot settle or replace an
                    // ordinary policy request, even while its lease is empty.
                    guard self.request == nil, self.lease?.journal == nil, self.cutoff?.record == nil,
                          self.calibration?.isActive != true else {
                        throw BatteryControlError.conflict("正式充电控制仍有请求或恢复责任；不能用独立试验交接改变长期策略。")
                    }
                    try self.preferences79.finishReviewKeeping85(owner: id)
                default: throw BatteryControlError.invalid("只允许固定start/inspect/cancel/keep85试验操作。")
                }
                reply(self.preferences79.data())
            } catch {
                var status = BatteryPreferences79Controller.Status()
                status.phase = "rejected"; status.message = error.localizedDescription
                reply((try? JSONEncoder().encode(status)) ?? Data())
            }
        }
        #else
        reply(Data(#"{"schema":1,"phase":"rejected","message":"生产辅助程序未开放79试验。"}"#.utf8))
        #endif
    }
    func renew(request data: Data, reply: @escaping (Bool, Data) -> Void) {
        queue.async {
            guard !self.diagnosticOnly else { reply(false, self.data()); return }
            guard !BatteryPreferences79Identity.pending else { reply(false, self.data()); return }
            #if BATTERY_REVIEW
            guard !self.preferences79.blocksNormalControl else { reply(false, self.data()); return }
            #endif
            var admissionMutationStarted = false
            do {
                guard data.count < 16_384, !self.failed, let lease = self.lease else {
                    throw BatteryControlError.unavailable(self.report.message)
                }
                // Reject malformed/range/capability requests before a detached
                // hold can cause any restoration write.
                let incoming = try JSONDecoder().decode(BatteryControlRequest.self, from: data)
                try incoming.validate()
                try incoming.validateEpoch(self.report.controlEpoch)
                guard let manualRetry = self.manualRetry else { throw BatteryControlError.recovery("故障确认服务未就绪。") }
                let recovered = !self.recoveryUnknown && self.cutoff?.record == nil && lease.journal == nil
                try manualRetry.validate(incoming, recovered: recovered)
                if lease.journal?.detachedExitHold == true {
                    try self.driver.capabilities.validate(incoming, currentLevel: BatteryTelemetry.read().level)
                    guard try self.releaseControl(reason: .exit) else {
                        throw BatteryControlError.recovery("上次退出暂停仍在恢复，尚未开始新控制。")
                    }
                }
                guard self.exitHoldVerification == nil else { throw BatteryControlError.conflict("退出暂停正在确认；请先取消退出或等待完成。") }
                let semantic = incoming.withoutFaultAcknowledgment
                let request = self.completedRequest?.normalize(semantic) ?? semantic
                try request.validate()
                if self.driver.nativeCutoffReviewTrial {
                    try BatteryNativeCutoffTrial.validate(request, level: BatteryTelemetry.read().level)
                }
                let incomingTelemetry = BatteryTelemetry.read()
                guard incomingTelemetry.hasBattery else { throw BatteryControlError.unavailable("没有内置电池。") }
                if let owner = lease.journal?.owner, owner != request.owner {
                    throw BatteryControlError.conflict("已有其他实例持有控制，未修改校准。")
                }
                if self.cutoff?.recovering == true {
                    if self.cutoff?.record?.pausePulse != nil, request.mode == .automatic,
                       request.calibration == nil, !request.sleeping,
                       request.preferences == self.request?.preferences {
                        let restored = try self.releaseControl(owner: request.owner, reason: .cancelled)
                        reply(restored, self.data(for: request.owner)); return
                    }
                    guard self.cutoff?.acceptsRecoveryRequest(request, previous: self.request) == true else {
                        throw BatteryControlError.recovery(self.cutoff!.message)
                    }
                    if case .cancel = request.calibration {
                        try self.calibration?.accept(request.calibration, owner: request.owner,
                            preferences: request.preferences, supported: self.driver.calibrationSupported, date: Date())
                        self.request = request
                    }
                    try lease.renew(owner: request.owner, now: ProcessInfo.processInfo.systemUptime)
                    self.tick(); reply(!self.failed, self.data(for: request.owner)); return
                }
                // Recovery-only requests above retain their existing ownership
                // checks. Ordinary admission is read-only for EVERY route.
                try BatteryControlAdmission.preflight(request, previous: self.request,
                    policy: self.policy, capabilities: self.driver.capabilities,
                    telemetry: incomingTelemetry, calibrationActive: self.calibration?.isActive == true,
                    ownsAdapterCutoff: { try self.ownedCutoff(owner: request.owner) }) { proposed in
                        _ = try self.driver.targets(for: proposed, request: request, telemetry: incomingTelemetry,
                            ownedKeys: Set(lease.journal?.entries.keys.map { $0 } ?? []))
                }
                guard let calibration = self.calibration else { throw BatteryControlError.unavailable("校准恢复服务尚未就绪。") }
                if case .start = request.calibration, !calibration.isActive, let previous = self.request, previous.mode != .automatic {
                    throw BatteryControlError.conflict("当前临时模式尚未结束，请先恢复自动模式再校准。")
                }
                try manualRetry.accept(incoming, recovered: recovered)
                admissionMutationStarted = true
                try calibration.accept(request.calibration, owner: request.owner, preferences: request.preferences,
                    supported: self.driver.calibrationSupported, date: Date())
                try lease.renew(owner: request.owner, now: ProcessInfo.processInfo.systemUptime)
                self.policy.configure(previous: self.request, next: request)
                if self.report.requiresManualRetry == true { self.report.lastFailure = nil }
                self.report.requiresManualRetry = false
                if self.request?.operationID != request.operationID {
                    self.report.completedOperationID = nil; self.report.completionReason = nil
                }
                if request != self.completedRequest?.automatic { self.completedRequest = nil }
                self.request = request; self.lastAdmittedRequest = request
                self.tick()
                reply(!self.failed, self.data(for: request.owner))
            } catch {
                // A post-admission persistence/write failure is a new fault,
                // unlike rejected input, and must issue a fresh acknowledgment.
                if admissionMutationStarted {
                    self.record(error, attempted: try? JSONDecoder().decode(BatteryControlRequest.self, from: data))
                    do { _ = try self.releaseControl(reason: .permissionLost) }
                    catch { self.report.message += "；恢复尚未完成：" + error.localizedDescription }
                }
                // Invalid input must not disable another owner's valid lease.
                _ = self.data()
                var response = self.report; response.message = error.localizedDescription
                if let rejected = try? JSONDecoder().decode(BatteryControlRequest.self, from: data) {
                    response.leaseHeldByRequester = self.lease?.journal?.owner == rejected.owner || self.cutoff?.record?.owner == rejected.owner
                }
                reply(false, (try? JSONEncoder().encode(response)) ?? Data())
            }
        }
    }
    func prepareExitHold(owner: String, reply: @escaping (Bool, Data) -> Void) {
        queue.async {
            var beganPreparation = false
            do {
                guard !self.diagnosticOnly, !self.failed, !self.recoveryUnknown,
                      self.driver.capabilities.exitHoldSupported, !BatteryPreferences79Identity.pending,
                      let owner = UUID(uuidString: owner), let lease = self.lease,
                      lease.journal?.owner == owner, self.cutoff?.record == nil,
                      self.calibration?.isActive != true else {
                    throw BatteryControlError.unavailable("当前控制状态不能准备退出暂停。")
                }
                if lease.journal?.detachedExitHold == true { reply(true, self.data(for: owner)); return }
                let telemetry = BatteryTelemetry.read(), now = ProcessInfo.processInfo.systemUptime
                if self.exitHoldVerification == nil {
                    guard self.request != nil, let level = telemetry.level, (20...100).contains(level),
                          telemetry.powerSupplyObservation == true, self.driver.adapterInputObservation() == true else {
                        throw BatteryControlError.unavailable("退出暂停需要有效电池控制及适配器输入。")
                    }
                    beganPreparation = true
                    try lease.renew(owner: owner, now: now)
                    // Restore energy/LED controls; only the typed charge baseline
                    // is eligible for explicit transfer after physical proof.
                    try lease.apply([:], owner: owner)
                    try lease.applyPreferences(target: level, owner: owner)
                    self.request = nil; self.completedRequest = nil
                    self.exitHoldVerification = .init(target: level, started: now, submittedAt: Date())
                    self.lastExitHoldObservation = -Double.infinity
                }
                try lease.renew(owner: owner, now: now)
                if now - self.lastExitHoldObservation < 5 { reply(true, self.data(for: owner)); return }
                self.lastExitHoldObservation = now
                var verifier = self.exitHoldVerification!
                let ready = try verifier.observe(telemetry, registered: self.driver.registeredLimits(fresh: true),
                    saved: self.driver.savedNativeLimit(), input: self.driver.adapterInputObservation(), now: now, date: Date())
                self.exitHoldVerification = verifier
                if ready {
                    try lease.detachExitHold(owner: owner, confirmed: true)
                    self.exitHoldVerification = nil
                    self.report.message = "退出暂停已独立确认；下次启用、后台或系统重启时恢复原设置。"
                } else { self.report.message = "正在确认退出暂停：等待新的电池读数和一致系统目标，尚未移交。" }
                reply(true, self.data(for: owner))
            } catch {
                self.report.message = error.localizedDescription
                if beganPreparation || self.exitHoldVerification != nil {
                    do { _ = try self.releaseControl(reason: .cancelled) }
                    catch { self.record(error) }
                }
                reply(false, self.data())
            }
        }
    }
    func release(owner: String, reply: @escaping (Bool, Data) -> Void) {
        queue.async {
            guard !self.diagnosticOnly else { reply(false, self.data()); return }
            guard !BatteryPreferences79Identity.pending else { reply(false, self.data()); return }
            #if BATTERY_REVIEW
            guard !self.preferences79.blocksNormalControl else { reply(false, self.data()); return }
            #endif
            guard let owner = UUID(uuidString: owner) else {
                var response = self.report; response.message = "无效的恢复身份"; response.leaseHeldByRequester = false
                reply(false, (try? JSONEncoder().encode(response)) ?? Data()); return
            }
            if let existing = self.lease?.journal?.owner ?? self.cutoff?.record?.owner, existing != owner {
                // A rejected client cannot poison the active owner's watchdog.
                var response = self.report; response.message = "不能释放其他实例的控制"; response.leaseHeldByRequester = false
                reply(false, (try? JSONEncoder().encode(response)) ?? Data()); return
            }
            do {
                let restored = try self.releaseControl(owner: owner, reason: .exit)
                if restored { self.failed = false }
                reply(restored, self.data(for: owner))
            } catch { self.record(error); reply(false, self.data(for: owner)) }
        }
    }
}

// Isolated children must not construct the daemon or recurse into its driver.
// Native-read is read-only. The sealed Preferences79 worker performs only its
// fixed, journalled preference writes; private PowerUI setters never run here.
#if BATTERY_REVIEW
if CommandLine.arguments.dropFirst().contains(BatteryPreferences79IO.argument) {
    BatteryPreferences79IO.run(arguments: CommandLine.arguments)
}
#endif
if CommandLine.arguments.dropFirst().first == BatteryPreferencesBackend.argument {
    BatteryPreferencesBackend.run(arguments: CommandLine.arguments)
}
if CommandLine.arguments.dropFirst().first == "--bm1-native-read" {
    exit(BatteryNativeReadWorker.run(arguments: CommandLine.arguments))
}

// Unsigned/ad-hoc helpers cannot even start their hardware or journal paths.
let startupLog = Logger(subsystem: BatteryManagementIdentity.label, category: "startup")
let permittedClients = BatteryManagementIdentity.packagePauseRefreshTrial(executableURL: Bundle.main.executableURL)
    ? ["com.workview.SuperIsland.BM1Debug"] : ["com.workview.SuperIsland", "com.workview.SuperIsland.WE1Debug", "com.workview.SuperIsland.BM1Debug"]
guard let requirement = KeepAwakeHelperIdentity.requirement(identifiers: permittedClients, diagnostic: {
    startupLog.error("Signing identity unavailable: \($0, privacy: .public)")
}) else { exit(78) }
let daemon = BatteryManagementDaemon()
daemon.prepare()
let listener = NSXPCListener(machServiceName: BatteryManagementIdentity.label)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = daemon; listener.resume()
RunLoop.current.run()
