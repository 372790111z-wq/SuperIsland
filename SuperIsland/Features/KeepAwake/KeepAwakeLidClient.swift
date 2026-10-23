import Foundation
import ServiceManagement
import Combine

@MainActor
final class KeepAwakeLidClient: ObservableObject {
    typealias RemoteProxyFactory = (_ errorHandler: @escaping (Error) -> Void,
                                   _ connectionEnded: @escaping () -> Void) throws -> KeepAwakeHelperProtocol
    private enum RequestKind { case status(UInt64), renew, release }
    @Published private(set) var enabled = false
    @Published private(set) var applied = false
    @Published private(set) var message = "合盖运行未授权；普通防休眠独立可用"
    @Published private(set) var busy = false
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
    private var preferences = KeepAwakeEngine.Preferences()
    private let serviceStatus: () -> SMAppService.Status
    private let signingRequirement: ([String]) -> String?
    private let remoteProxyFactory: RemoteProxyFactory?
    private let requestTimeout: TimeInterval
    private let registerService: () throws -> Void
    private let unregisterService: () async throws -> Void
    private let openSystemSettings: () -> Void
    var registered: Bool { serviceStatus() == .enabled || serviceStatus() == .requiresApproval }
    var requiresApproval: Bool { serviceStatus() == .requiresApproval }
    var shouldPrepareForTermination: Bool { enabled || applied || busy || releaseNeeded }

    init(serviceStatus: @escaping () -> SMAppService.Status = { SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).status },
         signingRequirement: @escaping ([String]) -> String? = { KeepAwakeHelperIdentity.requirement(identifiers: $0) },
         remoteProxyFactory: RemoteProxyFactory? = nil, requestTimeout: TimeInterval = 8,
         registerService: @escaping () throws -> Void = { try SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).register() },
         unregisterService: @escaping () async throws -> Void = { try await SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).unregister() },
         openSystemSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.serviceStatus = serviceStatus
        self.signingRequirement = signingRequirement
        self.remoteProxyFactory = remoteProxyFactory
        self.requestTimeout = requestTimeout
        self.registerService = registerService
        self.unregisterService = unregisterService
        self.openSystemSettings = openSystemSettings
    }

    func authorize() {
        guard !busy, !recovering else { message = "请等待当前辅助程序检查结束。"; return }
        enableIntent = false; intentGeneration &+= 1
        enabled = false; desiredHold = false
        guard signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
            message = "当前包未使用证书签名，不能授权合盖辅助程序。请使用经过签名验证的安装包。"; return
        }
        do {
            // An explicit authorization click must reach register() even when
            // status cannot yet resolve a backing service record. Registration
            // supplies the authoritative packaging/signature error, if any.
            switch serviceStatus() {
            case .notRegistered, .notFound: try registerService()
            case .enabled, .requiresApproval: break
            @unknown default:
                enabled = false; message = "系统返回了未知辅助程序状态，未启用合盖运行。"; return
            }
            let status = serviceStatus()
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
        enableIntent = false; intentGeneration &+= 1
        cancelStatusRequest()
        enabled = false; apply(hold: false)
    }
    func apply(hold: Bool, preferences: KeepAwakeEngine.Preferences? = nil) {
        if let preferences, self.preferences != preferences { self.preferences = preferences; lastRenewal = 0 }
        desiredHold = hold && enabled && !blocked
        guard !busy else { return }
        if !desiredHold {
            if releaseNeeded && !blocked { perform(.release) }
            return
        }
        if !applied || KeepAwakeClock.now() - lastRenewal >= 30 { perform(.renew) }
    }
    private func proxy(id: UUID) throws -> KeepAwakeHelperProtocol {
        guard serviceStatus() == .enabled,
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
        if case .status(let generation) = kind {
            guard generation == intentGeneration, enableIntent else { return }
            guard success, serviceStatus() == .enabled,
                  signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
                applied = false; blocked = true; enabled = false
                self.message = success ? "检查期间系统授权已变化；合盖保持未开启，请重新检查授权。" : message
                invalidateConnection(); return
            }
            // A status reply proves reachability, not ownership of any existing
            // lease and not that a power change has been applied or restored.
            blocked = false; enabled = true; lastRenewal = 0
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
        blocked = false; releaseNeeded = true; enabled = false; apply(hold: false)
    }
    /// Called only by an explicit user recovery action after the ordinary
    /// protection checks pass. It never registers or requests new authorization.
    /// A user who never enabled lid support can still recover ordinary keeping.
    func recoverAndEnable() async -> Bool {
        guard enableIntent else { return true }
        guard !recovering else { return false }
        let generation = intentGeneration
        recovering = true
        defer { recovering = false }
        enabled = false; desiredHold = false
        await waitForRequest()
        guard !Task.isCancelled, !busy, generation == intentGeneration, enableIntent else { return false }
        guard serviceStatus() == .enabled,
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
        guard !Task.isCancelled, !busy, !releaseNeeded, !blocked,
              generation == intentGeneration, enableIntent else { return false }
        guard serviceStatus() == .enabled,
              signingRequirement([KeepAwakeHelperIdentity.label]) != nil else {
            applied = false; blocked = true
            message = "恢复期间系统授权已变化；合盖保持未开启，请重新检查授权。"
            return false
        }
        enabled = true; lastRenewal = 0
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
