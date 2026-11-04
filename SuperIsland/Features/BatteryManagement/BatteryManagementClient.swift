import Foundation
import ServiceManagement

@MainActor
protocol BatteryHelperRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func failedLaunchNeedsRebind() async -> Bool
}

extension BatteryHelperRegistering {
    func failedLaunchNeedsRebind() async -> Bool { false }
}

@MainActor
private struct SystemBatteryHelperRegistration: BatteryHelperRegistering {
    private var service: SMAppService { .daemon(plistName: BatteryManagementIdentity.plist) }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func failedLaunchNeedsRebind() async -> Bool {
        await BatteryHelperLaunchFailure.probe(bundle: Bundle.main.bundleURL,
            parent: Bundle.main.bundleIdentifier ?? "", build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }
}

@MainActor
protocol BatteryManagementTransport: AnyObject {
    var authorization: SMAppService.Status { get }
    var helperBundled: Bool { get }
    func register() async throws
    func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport)
    func prepareExitHold(owner: UUID) async throws -> (Bool, BatteryControlReport)
}

extension BatteryManagementTransport {
    func prepareExitHold(owner: UUID) async throws -> (Bool, BatteryControlReport) {
        throw BatteryControlError.unavailable("当前辅助程序不能交接退出停充。")
    }
}

@MainActor
final class BatteryManagementClient: BatteryManagementTransport {
    enum Command { case inspect, renew(BatteryControlRequest), release(UUID) }
    static let readOnlyPreviewIdentifier = "com.workview.SuperIsland.BM1ReadOnlyPreview"
    static func defaultTransport() -> any BatteryManagementTransport {
        if Bundle.main.bundleIdentifier == readOnlyPreviewIdentifier { return BatteryReadOnlyPreviewTransport() }
        return BatteryManagementClient()
    }
    private let diagnosticsOnly: Bool
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var pending: [UUID: CheckedContinuation<(Bool, BatteryControlReport), Error>] = [:]
    private let registrar: any BatteryHelperRegistering
    private let defaults: UserDefaults
    private let buildIdentifier: String
    private let registrationKey = "batteryManagement.helperRegistrationBuild"
    private let repairKey = "batteryManagement.helperLaunchRepairAttemptBuild"
    private var registering = false
    init(registrar: (any BatteryHelperRegistering)? = nil, defaults: UserDefaults = .standard, buildIdentifier: String? = nil, diagnosticsOnly: Bool? = nil) {
        self.diagnosticsOnly = diagnosticsOnly ?? BatteryStartupContext.currentProcessIsDiagnostic
        self.registrar = registrar ?? SystemBatteryHelperRegistration()
        self.defaults = defaults
        self.buildIdentifier = buildIdentifier ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }
    var authorization: SMAppService.Status { registrar.status }
    var helperBundled: Bool {
        let root = Bundle.main.bundleURL.appendingPathComponent("Contents")
        return FileManager.default.isReadableFile(atPath: root.appendingPathComponent("Library/LaunchDaemons/" + BatteryManagementIdentity.plist).path)
            && FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("MacOS/BatteryManagementHelper").path)
    }

    func register() async throws {
        guard !registering else { throw BatteryControlError.unavailable("辅助程序登记正在进行，请等待结果。") }
        registering = true; defer { registering = false }
        // A replaced bundle can retain an unresolvable BTM record even while
        // SMAppService temporarily reports notRegistered. A prior build receipt
        // still requires one refresh before registering changed executable code.
        // Refresh at most once per build: retrying after human approval must not
        // unregister the very record the user just approved.
        let previousBuild = defaults.string(forKey: registrationKey)
        let changed = previousBuild != buildIdentifier && (previousBuild != nil || registrar.status != .notRegistered)
        var repaired = false
        if changed { try await unregisterCurrent() }
        else if try await confirmedLaunchFailure() { try await repairOnce(); repaired = true }
        defaults.set(buildIdentifier, forKey: registrationKey)
        if let connectionID { disconnect(id: connectionID) }
        try registrar.register()
        // A previously absent job may only fail after register creates it.
        // One post-check covers that ordering; this is deliberately not a loop.
        if !repaired, try await confirmedLaunchFailure() {
            try await repairOnce()
            try registrar.register()
        }
    }
    private func confirmedLaunchFailure() async throws -> Bool {
        guard defaults.string(forKey: registrationKey) == buildIdentifier, mayInspectFailedLaunch,
              defaults.string(forKey: repairKey) != buildIdentifier else { return false }
        let failed = await registrar.failedLaunchNeedsRebind()
        try Task.checkCancellation()
        guard defaults.string(forKey: registrationKey) == buildIdentifier else {
            throw BatteryControlError.conflict("辅助程序登记版本已改变；未注销其他版本。")
        }
        return failed && mayInspectFailedLaunch && defaults.string(forKey: repairKey) != buildIdentifier
    }
    private var mayInspectFailedLaunch: Bool {
        // BTM can invalidate a failed job while launchd still retains it. Its
        // service status then becomes notRegistered/notFound; the independently
        // verified, same-build failed job is still required to authorize repair.
        // A pending approval alone must never cause a rebind.
        switch registrar.status {
        case .enabled, .notRegistered, .notFound: return true
        default: return false
        }
    }
    private func repairOnce() async throws {
        // Persist before yielding: approval retries or a lost reply cannot
        // turn this explicit recovery into an unregister loop.
        defaults.set(buildIdentifier, forKey: repairKey)
        guard defaults.synchronize() else {
            throw BatteryControlError.unavailable("登记修复记录未确认保存；未注销辅助程序。")
        }
        try await unregisterCurrent()
    }
    private func unregisterCurrent() async throws {
        do { try await registrar.unregister() }
        catch {
            let error = error as NSError
            // The named domain constant is macOS15+, while the app supports14.
            guard registrar.status == .notRegistered, error.domain == "SMAppServiceErrorDomain",
                  error.code == Int(kSMErrorJobNotFound) else { throw error }
        }
    }
    func call(_ command: Command) async throws -> (Bool, BatteryControlReport) {
        try await perform(command)
    }
    func prepareExitHold(owner: UUID) async throws -> (Bool, BatteryControlReport) {
        try await perform(.inspect, exitHoldOwner: owner)
    }
    private func perform(_ command: Command, exitHoldOwner: UUID? = nil) async throws -> (Bool, BatteryControlReport) {
        if diagnosticsOnly {
            guard exitHoldOwner == nil else { throw BatteryControlError.unavailable("只读诊断模式不能准备退出停充。") }
            guard case .inspect = command else {
                throw BatteryControlError.unavailable("只读诊断模式不提交充放电控制或恢复写入。")
            }
        }
        guard authorization == .enabled else { throw BatteryControlError.unavailable("电池辅助程序尚未获系统授权。") }
        guard let requirement = KeepAwakeHelperIdentity.requirement(identifiers: [BatteryManagementIdentity.label]) else {
            throw BatteryControlError.unavailable("当前构建没有可信签名，不能连接充电辅助程序。")
        }
        if connection == nil {
            let transportID = UUID(); connectionID = transportID
            let c = NSXPCConnection(machServiceName: BatteryManagementIdentity.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: BatteryManagementProtocol.self)
            c.setCodeSigningRequirement(requirement)
            c.interruptionHandler = { [weak self] in Task { @MainActor in self?.disconnect(id: transportID) } }
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.disconnect(id: transportID) } }
            connection = c; c.resume()
        }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finish(id, result: .failure(BatteryControlError.unavailable("辅助程序响应超时；实际状态未确认。")))
            }
            guard let remote = connection?.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                Task { @MainActor in self?.finish(id, result: .failure(BatteryControlError.unavailable("辅助程序连接中断；停止续期后将尝试恢复。"))) }
            }) as? BatteryManagementProtocol else {
                finish(id, result: .failure(BatteryControlError.unavailable("辅助程序不可用。"))); return
            }
            let reply: (Bool, Data) -> Void = { [weak self] success, data in
                Task { @MainActor in
                    guard data.count < 65_536, let report = try? JSONDecoder().decode(BatteryControlReport.self, from: data) else {
                        self?.finish(id, result: .failure(BatteryControlError.unavailable("辅助程序返回了无效状态。"))); return
                    }
                    self?.finish(id, result: .success((success, report)))
                }
            }
            if let exitHoldOwner {
                remote.prepareExitHold(owner: exitHoldOwner.uuidString, reply: reply)
                return
            }
            switch command {
            case .inspect: remote.inspect { reply(true, $0) }
            case .renew(let request):
                do { remote.renew(request: try JSONEncoder().encode(request), reply: reply) }
                catch { finish(id, result: .failure(error)) }
            case .release(let owner): remote.release(owner: owner.uuidString, reply: reply)
            }
        }
    }
    private func finish(_ id: UUID, result: Result<(Bool, BatteryControlReport), Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func disconnect(id: UUID) {
        guard connectionID == id else { return }; connectionID = nil
        let retired = connection; connection = nil
        retired?.invalidationHandler = nil; retired?.interruptionHandler = nil; retired?.invalidate()
        let callbacks = pending; pending.removeAll()
        for c in callbacks.values { c.resume(throwing: BatteryControlError.unavailable("辅助程序失联；恢复结果尚未确认。")) }
    }
}

/// Separate local UI harness: no XPC connection or ServiceManagement instance
/// exists in this transport, even if a preview control is clicked by mistake.
@MainActor
final class BatteryReadOnlyPreviewTransport: BatteryManagementTransport {
    var authorization: SMAppService.Status { .enabled }
    var helperBundled: Bool { false }
    func register() async throws { throw BatteryControlError.unavailable("只读预览不能注册辅助程序。") }
    func call(_ command: BatteryManagementClient.Command) async throws -> (Bool, BatteryControlReport) {
        guard case .inspect = command else { throw BatteryControlError.unavailable("只读预览拒绝所有充电控制写入。") }
        var report = BatteryControlReport()
        report.mechanism = "只读界面预览"
        report.message = "只读预览：未连接辅助程序，充电控制不可用。"
        return (true, report)
    }
}
