import Foundation
import ServiceManagement
import Combine

@MainActor
final class KeepAwakeLidClient: ObservableObject {
    typealias RemoteProxyFactory = (_ errorHandler: @escaping (Error) -> Void,
                                   _ connectionEnded: @escaping () -> Void) throws -> KeepAwakeHelperProtocol
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
    private var requestRenew = false
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
    private let openSystemSettings: () -> Void
    private var service: SMAppService { .daemon(plistName: KeepAwakeHelperIdentity.plist) }
    var registered: Bool { serviceStatus() == .enabled || serviceStatus() == .requiresApproval }
    var requiresApproval: Bool { serviceStatus() == .requiresApproval }
    var shouldPrepareForTermination: Bool { enabled || applied || busy || releaseNeeded }

    init(serviceStatus: @escaping () -> SMAppService.Status = { SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).status },
         signingRequirement: @escaping ([String]) -> String? = { KeepAwakeHelperIdentity.requirement(identifiers: $0) },
         remoteProxyFactory: RemoteProxyFactory? = nil, requestTimeout: TimeInterval = 8,
         registerService: @escaping () throws -> Void = { try SMAppService.daemon(plistName: KeepAwakeHelperIdentity.plist).register() },
         openSystemSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.serviceStatus = serviceStatus
        self.signingRequirement = signingRequirement
        self.remoteProxyFactory = remoteProxyFactory
        self.requestTimeout = requestTimeout
        self.registerService = registerService
        self.openSystemSettings = openSystemSettings
    }

    func authorize() {
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
            enableIntent = true; intentGeneration &+= 1
            blocked = false; enabled = true
            message = "辅助程序已注册；等待保持请求，合盖效果需实机验收。"
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
        enabled = false; apply(hold: false)
    }
    func apply(hold: Bool, preferences: KeepAwakeEngine.Preferences? = nil) {
        if let preferences, self.preferences != preferences { self.preferences = preferences; lastRenewal = 0 }
        desiredHold = hold && enabled && !blocked
        guard !busy else { return }
        if !desiredHold {
            if releaseNeeded && !blocked { perform(renew: false) }
            return
        }
        if !applied || KeepAwakeClock.now() - lastRenewal >= 30 { perform(renew: true) }
    }
    private func proxy(id: UUID, renew: Bool) throws -> KeepAwakeHelperProtocol {
        guard serviceStatus() == .enabled,
              let requirement = signingRequirement([KeepAwakeHelperIdentity.label]) else {
            throw CocoaError(.featureUnsupported)
        }
        // Error handlers belong to their original request, never whichever
        // request happens to be active when a delayed XPC error arrives.
        let errorHandler: (Error) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(id: id, renew: renew, success: false, message: "辅助程序连接中断；合盖状态待恢复检查。")
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
    private func connectionEnded(id: UUID) {
        guard connectionID == id else { return }
        releaseNeeded = releaseNeeded || applied
        applied = false; lastRenewal = 0
        invalidateConnection()
        if let requestID {
            finish(id: requestID, renew: requestRenew, success: false, message: "辅助程序连接中断；合盖状态待恢复检查。")
        } else {
            blocked = true; enabled = false; desiredHold = false
            message = "辅助程序连接中断；合盖保持未确认，请检查并恢复。"
        }
    }
    private func perform(renew: Bool) {
        let id = UUID(); requestID = id; requestRenew = renew; busy = true
        if renew { releaseNeeded = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            self?.finish(id: id, renew: renew, success: false, message: "辅助程序响应超时；停止续期后最多 3 分钟恢复，当前尚未确认。")
        }
        do {
            let remote = try proxy(id: id, renew: renew)
            let reply: (Bool, String) -> Void = { [weak self] success, message in
                Task { @MainActor [weak self] in self?.finish(id: id, renew: renew, success: success, message: message) }
            }
            if renew { remote.renew(owner: owner, acOnly: preferences.acOnly, minimumBattery: preferences.minimumBattery, respectLowPower: preferences.respectLowPower, reply: reply) }
            else { remote.release(owner: owner, reply: reply) }
        } catch { finish(id: id, renew: renew, success: false, message: "无法连接已授权辅助程序：" + error.localizedDescription) }
    }
    private func finish(id: UUID, renew: Bool, success: Bool, message: String) {
        guard requestID == id else { return }
        busy = false; requestID = nil; self.message = message
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
        // This release also clears a latched daemon protection/error only after
        // the daemon confirms recovery of its own previous power change.
        blocked = false; releaseNeeded = true
        perform(renew: false)
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
        message = "辅助程序恢复已确认；等待重新应用合盖保持。"
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
        enabled = false; desiredHold = false
        guard !busy else { message = "请等待当前租约操作结束后再撤销。"; return }
        // Confirm a release before unregistering the daemon that owns recovery.
        releaseNeeded = true; perform(renew: false)
        let deadline = KeepAwakeClock.now() + 9
        while busy && KeepAwakeClock.now() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard !releaseNeeded && !busy else { message += " 辅助程序保留，以便继续恢复。"; return }
        do { try await service.unregister(); message = "合盖租约已恢复，辅助程序已撤销。" }
        catch { message = "恢复完成，但撤销失败：" + error.localizedDescription }
    }
    func prepareForTermination() async {
        enableIntent = false; intentGeneration &+= 1
        enabled = false; desiredHold = false
        apply(hold: false)
        let deadline = KeepAwakeClock.now() + 9
        while busy && KeepAwakeClock.now() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        // A timeout is not reported as recovered; the independent daemon lease
        // remains the fallback, and is recovered on its next launch after a crash.
    }
}
