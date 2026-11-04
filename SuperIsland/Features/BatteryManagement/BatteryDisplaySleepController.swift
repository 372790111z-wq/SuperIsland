import AppKit
import Combine
import IOKit.pwr_mgt

enum BatteryDisplaySleepPolicy: String, Codable, CaseIterable, Identifiable {
    case system, after5, after15, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .after5: return "无操作5分钟后关闭显示器"
        case .after15: return "无操作15分钟后关闭显示器"
        case .never: return "保持显示器常亮"
        }
    }
    var idleThreshold: TimeInterval? {
        switch self {
        case .after5: return 300
        case .after15: return 900
        case .system, .never: return nil
        }
    }
}

/// Independent battery-owned display policy. It never changes pmset settings
/// or acquires/releases assertions belonging to Keep Awake or another module.
@MainActor
final class BatteryDisplaySleepController: ObservableObject {
    struct Environment {
        var displayCount: Int?
        var externalDisplayCount: Int?
    }
    enum Conflict { case none, awake, off, unknown }
    @Published private(set) var reason: String?
    @Published private(set) var isHoldingDisplay = false
    @Published private(set) var offRequested = false
    private let environment: () -> Environment
    private let idleTime: () -> TimeInterval?
    private let uptime: () -> TimeInterval
    private let keepAwakeConflict: () -> Conflict
    private let hold: () throws -> IOPMAssertionID
    private let release: (IOPMAssertionID) throws -> Void
    private let turnOff: () async throws -> Void
    private var assertion: IOPMAssertionID?
    private var policy: BatteryDisplaySleepPolicy?
    private var lastObservedInput: TimeInterval?
    private var lastUptime: TimeInterval?
    private var offTask: Task<Void, Never>?
    private var commandID: UUID?
    private var offResultReason: String?
    private var cancellationUnconfirmed = false
    private var cancellationReason: String { "已请求取消先前熄屏；命令退出和屏幕状态尚未确认，先前请求可能已生效。" }

    init(environment: (() -> Environment)? = nil, idleTime: (() -> TimeInterval?)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         keepAwakeConflict: @escaping () -> Conflict = { .unknown },
         hold: (() throws -> IOPMAssertionID)? = nil, release: ((IOPMAssertionID) throws -> Void)? = nil,
         turnOff: (() async throws -> Void)? = nil) {
        self.environment = environment ?? Self.systemEnvironment
        self.idleTime = idleTime ?? Self.systemIdleTime
        self.uptime = uptime
        self.keepAwakeConflict = keepAwakeConflict
        self.hold = hold ?? Self.acquireDisplayAssertion
        self.release = release ?? Self.releaseDisplayAssertion
        // One reusable runner prevents another command being launched while a
        // timed-out child's termination is still unconfirmed.
        let command = BatteryDisplaySleepCommand()
        self.turnOff = turnOff ?? { try await command.run() }
    }

    func update(active: Bool, awake: Bool, policy next: BatteryDisplaySleepPolicy) {
        if policy != next {
            policy = next; offRequested = false; lastObservedInput = nil; lastUptime = nil; offResultReason = nil
            cancelCommand()
        }
        reason = cancellationUnconfirmed ? cancellationReason : offResultReason
        guard active, awake else {
            reason = cancellationUnconfirmed ? cancellationReason : nil
            cancelCommand()
            releaseOwnAssertion()
            return
        }
        if next == .system {
            cancelCommand(); releaseOwnAssertion()
            return
        }
        let conflict = keepAwakeConflict()
        if next == .never {
            cancelCommand()
            guard conflict != .off, conflict != .unknown else {
                releaseOwnAssertion()
                if reason == nil { reason = conflict == .off ? "保持唤醒正在要求熄屏；电池显示常亮已暂停。" : "无法确认保持唤醒的屏幕策略；电池显示常亮已暂停。" }
                return
            }
            acquireOwnAssertion()
            return
        }
        guard let idle = idleTime(), idle.isFinite, idle >= 0, let threshold = next.idleThreshold else {
            pauseTimedPolicy("无法确认用户空闲时间，未请求熄屏。")
            return
        }
        let monotonicNow = uptime(), inputTime = monotonicNow - idle
        guard monotonicNow.isFinite, monotonicNow >= 0, inputTime.isFinite,
              idle <= monotonicNow + 1, lastUptime.map({ monotonicNow >= $0 }) ?? true else {
            pauseTimedPolicy("无法确认用户输入时间，未请求熄屏。"); return
        }
        // Half a second ignores sampling skew between the two public clocks.
        // A jump while already beyond the threshold is not observed input:
        // sleep or an unobserved interval must never silently rearm a command.
        if let previous = lastObservedInput, inputTime > previous + 0.5 {
            if idle < threshold {
                offRequested = false; offResultReason = nil; reason = cancellationUnconfirmed ? cancellationReason : nil; cancelCommand()
            } else if offRequested {
                reason = "空闲时钟发生变化；等待新的输入操作后再启用本次熄屏。"
            }
        }
        lastObservedInput = inputTime; lastUptime = monotonicNow
        guard conflict == .none else {
            let message: String
            switch conflict {
            case .awake: message = "保持唤醒正在要求屏幕常亮；电池定时熄屏已暂停。"
            case .off: message = "保持唤醒正在要求熄屏；电池已释放自身显示保持并让位。"
            case .unknown: message = "无法确认保持唤醒的屏幕策略；电池定时熄屏已暂停。"
            case .none: message = ""
            }
            pauseTimedPolicy(message)
            return
        }
        let displays = environment()
        guard let count = displays.displayCount, count > 0,
              let external = displays.externalDisplayCount, external == 0 else {
            pauseTimedPolicy(displays.externalDisplayCount.map { $0 > 0 ? "熄屏接口会影响外接显示器，已跳过自动熄屏。" : "没有可确认的在线显示器，已跳过自动熄屏。" }
                ?? "外接显示器状态未知，已跳过自动熄屏。")
            return
        }
        if idle < threshold {
            // Prevent a shorter system idle timeout (for example one minute)
            // from closing the display before the selected five/fifteen limit.
            acquireOwnAssertion()
            return
        }
        releaseOwnAssertion()
        guard assertion == nil, !offRequested, offTask == nil else { return }
        offRequested = true
        let id = UUID(); commandID = id
        offTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.commandID == id, self.policy == next else { return }
                let currentDisplays = self.environment(), currentIdle = self.idleTime(), currentUptime = self.uptime()
                guard self.keepAwakeConflict() == .none,
                      currentDisplays.displayCount.map({ $0 > 0 }) == true, currentDisplays.externalDisplayCount == 0,
                      let currentIdle, currentIdle.isFinite, currentIdle >= threshold,
                      currentUptime.isFinite, currentUptime >= monotonicNow, currentIdle <= currentUptime + 1 else {
                    self.reason = "执行前输入、显示器或保持唤醒条件已改变；本次熄屏已跳过。"
                    self.offResultReason = self.reason
                    self.offTask = nil; self.commandID = nil
                    return
                }
                try await self.turnOff()
                guard self.commandID == id, !Task.isCancelled else { return }
                self.cancellationUnconfirmed = false
                self.reason = "已提交关闭显示器请求；不代表系统已确认屏幕熄灭。"
                self.offResultReason = self.reason
            } catch {
                guard self.commandID == id else { return }
                self.reason = "关闭显示器未确认：" + error.localizedDescription + "；输入操作或更改显示策略后才会重新尝试。"
                self.offResultReason = self.reason
            }
            if self.commandID == id { self.offTask = nil; self.commandID = nil }
        }
    }

    func shutdown() {
        cancelCommand()
        releaseOwnAssertion()
    }

    private func cancelCommand() {
        if offTask != nil {
            cancellationUnconfirmed = true
            reason = cancellationReason
        }
        commandID = nil
        offTask?.cancel(); offTask = nil
    }
    private func acquireOwnAssertion() {
        guard assertion == nil else { return }
        do {
            let value = try hold()
            guard value != 0 else { throw BatteryControlError.unavailable("系统未返回有效显示断言。") }
            assertion = value; isHoldingDisplay = true
        } catch { reason = "电池显示保持未生效：" + error.localizedDescription }
    }
    private func pauseTimedPolicy(_ message: String) {
        cancelCommand()
        releaseOwnAssertion()
        if assertion == nil { reason = message + (cancellationUnconfirmed ? "；" + cancellationReason : "") }
    }
    private func releaseOwnAssertion() {
        guard let assertion else { return }
        do { try release(assertion); self.assertion = nil; isHoldingDisplay = false }
        catch { reason = "本电池显示断言释放尚未确认：" + error.localizedDescription }
    }
    private static func acquireDisplayAssertion() throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "SuperIsland 电池显示策略" as CFString, &id)
        guard result == kIOReturnSuccess else { throw BatteryControlError.unavailable("系统拒绝显示断言（\(result)）。") }
        return id
    }
    private static func releaseDisplayAssertion(_ id: IOPMAssertionID) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess || result == kIOReturnNotFound else {
            throw BatteryControlError.unavailable("系统未确认释放（\(result)）。")
        }
    }
    private static func systemIdleTime() -> TimeInterval? {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return nil }
        let value = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return value.isFinite && value >= 0 ? value : nil
    }
    private static func systemEnvironment() -> Environment {
        var displays = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
              count > 0, Int(count) < displays.count else {
            return .init(displayCount: nil, externalDisplayCount: nil)
        }
        return .init(displayCount: Int(count), externalDisplayCount: displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count)
    }
}

/// The production action runs off the main actor, without a shell or pipes.
/// A timeout requests termination and reports uncertainty; it never pretends
/// that the process exited or that a physical display state was observed.
private final class BatteryDisplaySleepCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SuperIsland.battery.display-command")
    private var process: Process?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: DispatchSourceTimer?
    private var ownerID: UUID?
    private final class RunState: @unchecked Sendable {
        let id = UUID()
        // Read and written only on the command queue.
        var cancelled = false
    }

    func run() async throws {
        let state = RunState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { self.start(continuation, state: state) }
            }
        } onCancel: {
            self.queue.async { state.cancelled = true; self.cancel(owner: state.id) }
        }
    }
    private func start(_ reply: CheckedContinuation<Void, Error>, state: RunState) {
        guard process == nil else {
            reply.resume(throwing: BatteryControlError.unavailable("上次熄屏命令尚未确认退出，没有启动新命令。")); return
        }
        guard !state.cancelled else {
            reply.resume(throwing: CancellationError()); return
        }
        continuation = reply
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        child.arguments = ["displaysleepnow"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [self] child in queue.async { self.terminated(child) } }
        process = child; ownerID = state.id
        do { try child.run() }
        catch { child.terminationHandler = nil; process = nil; ownerID = nil; finish(.failure(error)); return }
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + 5)
        timeout.setEventHandler { [self] in
            if let process, process.isRunning { process.terminate() }
            finish(.failure(BatteryControlError.unavailable("命令超时，已请求终止，退出状态尚未确认。")))
        }
        timer = timeout; timeout.resume()
    }
    private func cancel(owner: UUID) {
        guard ownerID == owner, let process else { return }
        if process.isRunning { process.terminate() }
        finish(.failure(CancellationError()))
    }
    private func terminated(_ child: Process) {
        guard process === child else { return }
        child.terminationHandler = nil; process = nil; ownerID = nil
        if child.terminationStatus == 0 { finish(.success(())) }
        else { finish(.failure(BatteryControlError.unavailable("熄屏命令退出码\(child.terminationStatus)。"))) }
    }
    private func finish(_ result: Result<Void, Error>) {
        timer?.cancel(); timer = nil
        let reply = continuation; continuation = nil
        reply?.resume(with: result)
    }
}
