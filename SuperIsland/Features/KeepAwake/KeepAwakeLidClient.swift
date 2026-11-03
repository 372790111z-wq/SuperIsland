import Foundation
import ServiceManagement
import Combine
import AppKit
import Darwin

/// Metadata only. Do not launch, quit, configure, or read data from a competitor.
@MainActor
enum KeepAwakeLidConflict {
    static let alDenteIDs: Set<String> = ["com.apphousekitchen.aldente-pro", "com.davidwernhart.AlDente"]
    static let helperPath = "/Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro.helper"
    private static var checkedAt: TimeInterval = -.infinity
    private static var cached: String?

    static func reason(bundleIDs: Set<String>, helperPaths: Set<String>, inventoryComplete: Bool = true) -> String? {
        if !alDenteIDs.isDisjoint(with: bundleIDs) || helperPaths.contains(helperPath) {
            return "检测到 AlDente 正在运行，合盖设置存在冲突；请在它退出后手动恢复 SuperIsland 合盖运行。普通防休眠和任务监测不受影响。"
        }
        return inventoryComplete ? nil : "无法确认合盖控制冲突状态；请稍后重新检查，暂未启用合盖运行。"
    }

    static func current() -> String? {
        let now = KeepAwakeClock.now()
        if now >= checkedAt && now - checkedAt < 1 { return cached }
        checkedAt = now
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let reason = reason(bundleIDs: bundleIDs, helperPaths: []) { cached = reason; return reason }
        // The helper may outlive its UI and resets SleepDisabled during exit.
        // Only resolve a path for the known helper's process-name prefix.
        let required = proc_listallpids(nil, 0)
        guard required > 0, required < 65_536 else {
            cached = reason(bundleIDs: [], helperPaths: [], inventoryComplete: false); return cached
        }
        var pids = [pid_t](repeating: 0, count: Int(required) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0, Int(count) < pids.count else {
            cached = reason(bundleIDs: [], helperPaths: [], inventoryComplete: false); return cached
        }
        for pid in pids.prefix(Int(count)) where pid > 1 {
            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  String(cString: name).hasPrefix("com.apphousekit") else { continue }
            var path = [CChar](repeating: 0, count: 4_096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                cached = reason(bundleIDs: [], helperPaths: [], inventoryComplete: false); return cached
            }
            if let reason = reason(bundleIDs: [], helperPaths: [String(cString: path)]) {
                cached = reason; return reason
            }
        }
        cached = nil; return nil
    }
}

@MainActor
final class KeepAwakeLidClient: ObservableObject {
    nonisolated static let enabledIntentKey = "keepAwake.lid.enabledIntent.v1"
    typealias RemoteProxyFactory = (_ errorHandler: @escaping (Error) -> Void,
                                   _ connectionEnded: @escaping () -> Void) throws -> KeepAwakeHelperProtocol
    private enum RequestKind { case status(UInt64), renew, release }
    @Published private(set) var enabled = false
    @Published private(set) var applied = false
    @Published private(set) var message = "合盖运行未授权；普通防休眠独立可用"
    @Published private(set) var busy = false
    // UI projections are refreshed by the existing service tick. Operational
    // authorization/renewal/release checks still read the live service below.
    @Published private(set) var registered = false
    @Published private(set) var requiresApproval = false
    private let owner = UUID().uuidString
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var lastRenewal: TimeInterval = 0
    private var desiredHold = false
    private var releaseNeeded = false
    private var requestID: UUID?
    private var requestKind: RequestKind?
    private var blocked = false
    private var enableIntent = false
    private var intentGeneration: UInt64 = 0
    private var recovering = false
    private var conflictMessage: String?
    private let conflictReader: @MainActor () -> String?
    private var conflictLaunchObserver: AnyCancellable?
    private var preferences = KeepAwakeEngine.Preferences()
    private let serviceStatus: () -> SMAppService.Status
    private let signingRequirement: ([String]) -> String?
    private let remoteProxyFactory: RemoteProxyFactory?
    private let requestTimeout: TimeInterval
    private let registerService: () throws -> Void
    private let unregisterService: () async throws -> Void
    private let openSystemSettings: () -> Void
    private let readEnabledIntent: () -> Bool
    private let saveEnabledIntent: (Bool) -> Void
    func refreshRegistrationStatus() { _ = readServiceStatus() }
    private func readServiceStatus() -> SMAppService.Status {
        let status = serviceStatus()
        let isRegistered = status == .enabled || status == .requiresApproval
        let needsApproval = status == .requiresApproval
        if registered != isRegistered { registered = isRegistered }
        if requiresApproval != needsApproval { requiresApproval = needsApproval }
        return status
    }
    var shouldPrepareForTermination: Bool { enabled || applied || busy || releaseNeeded }
    /// Ownership, independent of whether the user enabled the module or helper.
    var hasPendingRelease: Bool { releaseNeeded }
    var releaseFailed: Bool { releaseNeeded && blocked }
    func retryOwnedRelease() {
        guard releaseNeeded, !busy else { return }
        retryRelease()
    }
    var releasedForCompletionSleep: Bool {
        enabled && !blocked && !busy && !applied && !releaseNeeded && readServiceStatus() == .enabled
    }

    init(readEnabledIntent: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: KeepAwakeLidClient.enabledIntentKey) },
         saveEnabledIntent: @escaping (Bool) -> Void = { UserDefaults.standard.set($0, forKey: KeepAwakeLidClient.enabledIntentKey) },
         serviceStatus: @escaping () -> SMAppService.Status = { SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).status },
         signingRequirement: @escaping ([String]) -> String? = { KeepAwakeHelperIdentity.requirement(identifiers: $0) },
         remoteProxyFactory: RemoteProxyFactory? = nil, requestTimeout: TimeInterval = 8,
         registerService: @escaping () throws -> Void = { try SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).register() },
         unregisterService: @escaping () async throws -> Void = { try await SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).unregister() },
         openSystemSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() },
         conflictReader: @escaping @MainActor () -> String? = { KeepAwakeLidConflict.current() }) {
        self.serviceStatus = serviceStatus
        self.signingRequirement = signingRequirement
        self.remoteProxyFactory = remoteProxyFactory
        self.requestTimeout = requestTimeout
        self.registerService = registerService
        self.unregisterService = unregisterService
        self.openSystemSettings = openSystemSettings
        self.readEnabledIntent = readEnabledIntent
        self.saveEnabledIntent = saveEnabledIntent
        self.conflictReader = conflictReader
        refreshRegistrationStatus()
        if remoteProxyFactory == nil {
            conflictLaunchObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .sink { [weak self] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          let id = application.bundleIdentifier else { return }
                    Task { @MainActor [weak self] in
                        // Capture even a short launch/quit between service ticks.
                        if let reason = KeepAwakeLidConflict.reason(bundleIDs: [id], helperPaths: []) {
                            self?.recordConflict(reason)
                        }
                    }
                }
        }
    }

    /// Restore only a previously confirmed choice. Starting the App must never
    /// register a daemon, prompt for approval, or treat registration as readiness.
    func restoreAuthorizedIntent() {
        guard readEnabledIntent(), !enabled, !busy, !recovering else { return }
        guard conflictMessage == nil, !detectConflict() else { return }
        guard readServiceStatus() == .enabled else {
            message = "先前启用的合盖辅助程序尚未获得系统授权，请在设置中检查后重新启用。"
            return
        }
        guard signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
            message = "当前包的签名身份无法确认，未恢复合盖运行。"
            return
        }
        intentGeneration &+= 1; enableIntent = true
        desiredHold = false
        message = "正在检查先前启用的合盖辅助程序。"
        perform(.status(intentGeneration))
    }

    func authorize() {
        guard !busy, !recovering else { message = "请等待当前辅助程序检查结束。"; return }
        guard !detectConflict() else { return }
        guard conflictMessage == nil || !releaseNeeded else {
            message = "合盖租约尚待释放确认，请先检查并释放租约。"; return
        }
        conflictMessage = nil
        enableIntent = false; intentGeneration &+= 1
        enabled = false; desiredHold = false
        guard signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
            message = "当前包未使用证书签名，不能授权合盖辅助程序。请使用经过签名验证的安装包。"; return
        }
        do {
            // An explicit authorization click must reach register() even when
            // status cannot yet resolve a backing service record. Registration
            // supplies the authoritative packaging/signature error, if any.
            switch readServiceStatus() {
            case .notRegistered, .notFound: try registerService()
            case .enabled, .requiresApproval: break
            @unknown default:
                enabled = false; message = "系统返回了未知辅助程序状态，未启用合盖运行。"; return
            }
            let status = readServiceStatus()
            if status == .requiresApproval {
                enabled = false
                message = "请在系统登录项中允许 SuperIsland 辅助程序，再点击启用。"
                openSystemSettings(); return
            }
            guard status == .enabled else { enabled = false; message = "系统尚未启用辅助程序（状态 \(status.rawValue)）。"; return }
            enableIntent = true
            message = "系统已授权；正在确认辅助程序能否连接。"
            perform(.status(intentGeneration))
        } catch {
            enabled = false
            let code = error as NSError
            // Error descriptions/userInfo can contain paths or other caller
            // data. Preserve only framework domain/code for diagnosis.
            message = "合盖授权失败：\(code.domain)（代码 \(code.code)）。"
        }
    }
    func disable() {
        saveEnabledIntent(false)
        suspendForShutdown()
    }
    /// Normal termination releases this process's lease, preserving the user's
    /// choice for the next launch. An explicit disable/revoke forgets it.
    func suspendForShutdown() {
        enableIntent = false; intentGeneration &+= 1
        cancelStatusRequest()
        enabled = false
        if conflictMessage != nil, releaseNeeded, !busy { perform(.release) }
        else { apply(hold: false) }
    }
    func apply(hold: Bool, preferences: KeepAwakeEngine.Preferences? = nil) {
        if let preferences, self.preferences != preferences { self.preferences = preferences; lastRenewal = 0 }
        if enabled || enableIntent || applied || releaseNeeded || busy {
            if detectConflict() { return }
        }
        if conflictMessage != nil { return } // Exit alone must never re-enable keeping.
        desiredHold = hold && enabled && !blocked
        guard !busy else { return }
        if !desiredHold {
            if releaseNeeded && !blocked { perform(.release) }
            return
        }
        if !applied || KeepAwakeClock.now() - lastRenewal >= 30 { perform(.renew) }
    }
    @discardableResult private func detectConflict() -> Bool {
        guard let reason = conflictReader() else { return false }
        recordConflict(reason)
        return true
    }
    private func recordConflict(_ reason: String) {
        if conflictMessage == nil {
            conflictMessage = reason
            saveEnabledIntent(false) // Relaunch must also require explicit recovery.
            intentGeneration &+= 1
            cancelStatusRequest()
            enabled = false; desiredHold = false; blocked = true
            message = reason
            // Do not cancel an in-flight renewal: its reply may reveal a lease
            // we still own. Release only that owner, once, then retain failure.
            if releaseNeeded && !busy { perform(.release) }
        }
    }
    private func proxy(id: UUID) throws -> KeepAwakeHelperProtocol {
        guard readServiceStatus() == .enabled,
              let requirement = signingRequirement([KeepAwakeHelperIdentity.label]) else {
            throw CocoaError(.featureUnsupported)
        }
        // Error handlers belong to their original request, never whichever
        // request happens to be active when a delayed XPC error arrives.
        let errorHandler: (Error) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(id: id, success: false, message: "辅助程序连接中断；合盖状态待恢复检查。")
            }
        }
        let transportID = connectionID ?? UUID()
        connectionID = transportID
        let connectionEnded: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.connectionEnded(id: transportID) }
        }
        if let remoteProxyFactory { return try remoteProxyFactory(errorHandler, connectionEnded) }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: KeepAwakeHelperIdentity.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.interruptionHandler = connectionEnded
            connection.invalidationHandler = connectionEnded
            connection.resume(); self.connection = connection
        }
        return connection!.remoteObjectProxyWithErrorHandler(errorHandler) as! KeepAwakeHelperProtocol
    }
    private func invalidateConnection() {
        // Ignore callbacks from a retired transport, including the invalidation
        // generated by our own cleanup of a failed request.
        connectionID = nil
        let retired = connection; connection = nil
        retired?.invalidate()
    }
    private func cancelStatusRequest() {
        guard case .status? = requestKind else { return }
        requestID = nil; requestKind = nil; busy = false
        invalidateConnection()
    }
    private func connectionEnded(id: UUID) {
        guard connectionID == id else { return }
        releaseNeeded = releaseNeeded || applied
        applied = false; lastRenewal = 0
        invalidateConnection()
        if let requestID {
            finish(id: requestID, success: false, message: "辅助程序连接中断；合盖状态待恢复检查。")
        } else {
            blocked = true; enabled = false; desiredHold = false
            message = "辅助程序连接中断；合盖保持未确认，请检查并恢复。"
        }
    }
    private func perform(_ kind: RequestKind) {
        let id = UUID(); requestID = id; requestKind = kind; busy = true
        if case .renew = kind { releaseNeeded = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            let message: String
            if case .status = kind { message = "系统已授权，但辅助程序未响应；尚未确认可用。" }
            else { message = "辅助程序响应超时；停止续期后最多 3 分钟恢复，当前尚未确认。" }
            self?.finish(id: id, success: false, message: message)
        }
        do {
            let remote = try proxy(id: id)
            let reply: (Bool, String) -> Void = { [weak self] success, message in
                Task { @MainActor [weak self] in self?.finish(id: id, success: success, message: message) }
            }
            switch kind {
            case .status: remote.status(reply: reply)
            case .renew: remote.renew(owner: owner, acOnly: preferences.acOnly, minimumBattery: preferences.minimumBattery, respectLowPower: preferences.respectLowPower, reply: reply)
            case .release: remote.release(owner: owner, reply: reply)
            }
        } catch {
            let code = error as NSError
            finish(id: id, success: false, message: "无法连接已授权辅助程序：\(code.domain)（代码 \(code.code)）。")
        }
    }
    private func finish(id: UUID, success: Bool, message: String) {
        guard requestID == id, let kind = requestKind else { return }
        busy = false; requestID = nil; requestKind = nil
        if case .release = kind {} else { _ = detectConflict() }
        if let conflictMessage {
            if case .status = kind {
                self.message = conflictMessage; return
            }
            let renewing: Bool
            if case .renew = kind { renewing = true } else { renewing = false }
            if success {
                applied = renewing
                if !renewing { releaseNeeded = false }
            } else { applied = false; invalidateConnection() }
            enabled = false; desiredHold = false; blocked = true
            self.message = success ? conflictMessage : conflictMessage + " 租约释放尚未确认，请检查并释放租约。"
            if renewing && releaseNeeded && !busy { perform(.release) }
            return
        }
        if case .status(let generation) = kind {
            guard generation == intentGeneration, enableIntent else { return }
            guard success, readServiceStatus() == .enabled,
                  signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
                applied = false; blocked = true; enabled = false
                self.message = success ? "检查期间系统授权已变化；合盖保持未开启，请重新检查授权。" : message
                invalidateConnection(); return
            }
            // A status reply proves reachability, not ownership of any existing
            // lease and not that a power change has been applied or restored.
            blocked = false; enabled = true; lastRenewal = 0
            saveEnabledIntent(true)
            self.message = "辅助程序连接已确认；等待保持请求，合盖效果需实机验收。"
            return
        }
        self.message = message
        let renew: Bool
        if case .renew = kind { renew = true } else { renew = false }
        if success {
            applied = renew; lastRenewal = KeepAwakeClock.now()
            if !renew { releaseNeeded = false }
        } else {
            applied = false; blocked = true; enabled = false
            invalidateConnection()
            // A failed release remains pending, but do not spam the daemon each
            // second. The explicit recovery action retries; the lease still expires.
        }
        if success && !desiredHold && releaseNeeded { apply(hold: false) }
    }
    func retryRelease() {
        enableIntent = false; intentGeneration &+= 1
        cancelStatusRequest()
        blocked = false; releaseNeeded = true; enabled = false
        if conflictMessage != nil { if !busy { perform(.release) }; return }
        apply(hold: false)
    }
    /// Called only by an explicit user recovery action after the ordinary
    /// protection checks pass. It never registers or requests new authorization.
    /// A user who never enabled lid support can still recover ordinary keeping.
    func recoverAndEnable(allowConflictRecovery: Bool = true) async -> Bool {
        guard !detectConflict() else { return false }
        if conflictMessage != nil {
            guard allowConflictRecovery else { return false }
            guard !busy else { return false }
            if releaseNeeded {
                perform(.release); await waitForRequest()
                guard !busy, !releaseNeeded else { return false }
            }
            guard !detectConflict() else { return false }
            conflictMessage = nil; blocked = false
        }
        guard enableIntent else { return true }
        guard !recovering else { return false }
        let generation = intentGeneration
        recovering = true
        defer { recovering = false }
        enabled = false; desiredHold = false
        await waitForRequest()
        guard !detectConflict() else { return false }
        guard !Task.isCancelled, !busy, generation == intentGeneration, enableIntent else { return false }
        guard readServiceStatus() == .enabled,
              signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
            applied = false; blocked = true
            message = "合盖辅助程序尚未授权或身份无法确认；请先检查系统授权。"
            return false
        }
        // Only a previous renewal can leave this owner's power lease unknown.
        // A client that only checked status must not release another owner's
        // lease or claim to have restored a power change it never requested.
        let needsRelease = releaseNeeded
        blocked = false
        perform(needsRelease ? .release : .status(generation))
        await waitForRequest()
        guard !detectConflict() else { return false }
        guard !Task.isCancelled, !busy, !releaseNeeded, !blocked,
              generation == intentGeneration, enableIntent else { return false }
        guard readServiceStatus() == .enabled,
              signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
            applied = false; blocked = true
            message = "恢复期间系统授权已变化；合盖保持未开启，请重新检查授权。"
            return false
        }
        enabled = true; lastRenewal = 0
        saveEnabledIntent(true)
        message = needsRelease ? "辅助程序恢复已确认；等待重新应用合盖保持。" : "辅助程序连接已确认；本次没有待恢复的合盖租约。"
        return true
    }
    private func waitForRequest() async {
        let deadline = KeepAwakeClock.now() + requestTimeout + 1
        while busy && KeepAwakeClock.now() < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    func revoke() async {
        saveEnabledIntent(false)
        enableIntent = false; intentGeneration &+= 1
        let generation = intentGeneration
        enabled = false; desiredHold = false
        cancelStatusRequest()
        guard !busy else { message = "请等待当前租约操作结束后再撤销。"; return }
        let hadOwnedLease = releaseNeeded
        // A local status or power snapshot cannot prove that an old/foreign
        // journal is absent. Require an owner-checked helper acknowledgement;
        // an unavailable daemon or a rejected owner must remain registered.
        releaseNeeded = true
        perform(.release)
        await waitForRequest()
        guard !Task.isCancelled, generation == intentGeneration, !releaseNeeded, !busy else {
            message += " 辅助程序保留，以便继续恢复。"; return
        }
        busy = true
        defer { busy = false }
        do {
            try await unregisterService()
            invalidateConnection(); blocked = false
            message = hadOwnedLease ? "合盖租约已确认释放，辅助程序已撤销。" : "辅助程序已确认可撤销；本次没有自身待释放的合盖租约。"
        } catch {
            let code = error as NSError
            message = "撤销辅助程序失败：\(code.domain)（代码 \(code.code)）。"
        }
    }
    func prepareForTermination() async {
        enableIntent = false; intentGeneration &+= 1
        enabled = false; desiredHold = false
        cancelStatusRequest()
        apply(hold: false)
        let deadline = KeepAwakeClock.now() + 9
        while busy && KeepAwakeClock.now() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        // A timeout is not reported as recovered; the independent daemon lease
        // remains the fallback, and is recovered on its next launch after a crash.
    }
}
