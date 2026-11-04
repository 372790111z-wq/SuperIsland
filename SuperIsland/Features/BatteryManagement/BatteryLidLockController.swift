import AppKit
import Combine
import Darwin
import IOKit
import IOKit.pwr_mgt
import MachO
import Security

enum BatteryLidLockState: Equatable, Sendable { case unknown, unlocked, locked }

struct BatteryLidLockFacts: Equatable, Sendable {
    var closed: Bool?
    var session: UInt32?
    var lock: BatteryLidLockState = .unknown
}

/// A fresh edge is required. This controller owns no power assertion and never
/// changes Keep Awake, SleepDisabled, authentication preferences, or unlocking.
@MainActor
final class BatteryLidLockController: ObservableObject {
    enum Event { case changed, interrupted }
    @Published private(set) var status: String?
    @Published private(set) var availabilityReason: String?
    private let facts: () -> BatteryLidLockFacts
    private let available: () -> String?
    private let request: (UInt32) async throws -> Int32
    private let wait: () async throws -> Void
    private let installEvents: ((@escaping (Event) -> Void) -> (() -> Void))?
    private var removeEvents: (() -> Void)?
    private var running = false
    private var previous: BatteryLidLockFacts?
    private var generation: UInt64 = 0
    private var command: Task<Void, Never>?

    init(facts: (() -> BatteryLidLockFacts)? = nil, available: (() -> String?)? = nil,
         request: ((UInt32) async throws -> Int32)? = nil,
         wait: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) },
         installEvents: ((@escaping (Event) -> Void) -> (() -> Void))? = nil) {
        self.facts = facts ?? BatteryLidLockSystem.facts
        self.available = available ?? { BatteryLidLockSystem.platformReason }
        self.request = request ?? BatteryLidLockWorker.request
        self.wait = wait
        self.installEvents = installEvents
    }

    deinit {
        // Keep the observer alive until its main-queue port has been destroyed.
        let remove = removeEvents
        if Thread.isMainThread { MainActor.assumeIsolated { remove?() } }
        else { DispatchQueue.main.async { remove?() } }
    }

    func update(active: Bool, awake: Bool, enabled: Bool) {
        let next = active && awake && enabled
        if !next {
            if command == nil { status = nil }
            running = false; previous = nil; invalidate()
            removeEvents?(); removeEvents = nil
            availabilityReason = nil
            return
        }
        if !running {
            running = true; previous = nil
            let callback: (Event) -> Void = { [weak self] event in
                guard let self else { return }
                if event == .interrupted { self.previous = nil; self.invalidate() }
                else { self.observe() }
            }
            if let installEvents { removeEvents = installEvents(callback) }
            else {
                let observer = BatteryLidLockEvents(changed: callback)
                if observer.start() { removeEvents = { observer.stop() } }
                else {
                    availabilityReason = "无法监听合盖事件，未启用合盖锁屏。"
                    running = false; return
                }
            }
        }
        observe()
    }

    /// Notifications are only hints; their payload never establishes a lock.
    func observe() {
        guard running else { return }
        let current = facts()
        availabilityReason = available()
        if availabilityReason == nil, current.session == nil || current.closed == nil || current.lock == .unknown {
            availabilityReason = "无法确认当前会话、合盖或锁屏状态，未发起新的锁屏。"
        }
        let old = previous
        previous = current
        guard availabilityReason == nil, let session = current.session else {
            previous = nil; invalidate(); return
        }
        if old?.session != nil, old?.session != current.session { invalidate() }
        guard current.closed == true else {
            if command != nil { invalidate() }
            return
        }
        guard current.lock == .unlocked else { return }
        guard old?.closed == false, old?.session == session, command == nil else { return }
        generation &+= 1
        let expected = generation
        status = "正在请求系统锁屏；请求提交后可能已生效，不能承诺撤销。"
        command = Task { [weak self] in
            guard let self else { return }
            // A stop/open/session change before this actor turn prevents spawn.
            guard self.running, self.generation == expected, self.preflight(session) else {
                self.command = nil; return
            }
            var receipt: Int32?
            var failed = false
            do { receipt = try await self.request(session) } catch { failed = true }
            guard self.running, self.generation == expected else { self.command = nil; return }
            for _ in 0..<20 {
                let current = self.facts()
                guard current.session == session, current.closed == true, current.lock != .unknown else {
                    self.previous = nil
                    self.status = "会话、合盖或锁屏状态发生变化；先前请求可能已生效，结果未确认。"
                    self.command = nil; return
                }
                if current.lock == .locked {
                    self.status = failed || receipt != 0
                        ? "已读回系统锁屏；本次请求回执异常，不能归因为本次请求成功。"
                        : "已读回系统锁屏。"
                    self.command = nil; return
                }
                if failed || receipt != 0 { break }
                do { try await self.wait() } catch { break }
                guard self.running, self.generation == expected else { self.command = nil; return }
            }
            guard self.running, self.generation == expected else { self.command = nil; return }
            self.status = "锁屏未确认；未重复提交本次合盖请求。"
            self.command = nil
        }
    }

    private func preflight(_ session: UInt32) -> Bool {
        let current = facts()
        guard available() == nil, current.closed == true, current.session == session,
              current.lock == .unlocked else {
            previous = nil
            status = "执行前状态变化，未提交锁屏。"
            return false
        }
        return true
    }

    private func invalidate() {
        generation &+= 1
        if command != nil {
            command?.cancel()
            status = "已停止后续锁屏；先前系统请求可能已生效，不能承诺撤销。"
        }
    }

    func shutdown() {
        running = false; previous = nil; invalidate()
        removeEvents?(); removeEvents = nil
    }
}

/// Only this exact platform's producer/getter semantics and C ABI have static
/// evidence. A changed image/OS fails closed; symbol presence is not acceptance.
enum BatteryLidLockSystem {
    private static let login = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    private static let skylight = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    typealias Lock = @convention(c) () -> Int32
    static let platformReason: String? = {
        do { _ = try function(); return nil }
        catch { return "当前系统锁屏接口尚未核验，合盖锁屏不可用。" }
    }()

    static func function() throws -> Lock {
        #if arch(arm64)
        var version = [CChar](repeating: 0, count: 64), size = version.count
        guard sysctlbyname("kern.osversion", &version, &size, nil, 0) == 0,
              String(cString: version) == "26A434",
              let handle = dlopen(login, RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "SACLockScreenImmediate"),
              image(symbol, path: login, uuid: "5875BF3F-4059-3E58-8C6C-0F1282265483"),
              let sky = dlopen(skylight, RTLD_NOW | RTLD_LOCAL),
              let getter = dlsym(sky, "SLSessionCopyCurrentDictionary"),
              image(getter, path: skylight, uuid: "8A3B348E-4637-3685-92D0-6CBC2F36A234") else { throw unavailable() }
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        let executable = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow" as CFString
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: executable as String) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("anchor apple and identifier com.apple.loginwindow" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              hash == Data([0xbb, 0xbe, 0x1b, 0xa8, 0xcf, 0xde, 0x07, 0x99, 0x76, 0x38,
                            0x71, 0x7d, 0x53, 0x49, 0x71, 0x9f, 0xc5, 0xdf, 0xd4, 0x45]) else { throw unavailable() }
        return unsafeBitCast(symbol, to: Lock.self)
        #else
        throw unavailable()
        #endif
    }

    private static func image(_ symbol: UnsafeMutableRawPointer, path: String, uuid expected: String) -> Bool {
        var info = Dl_info()
        guard dladdr(symbol, &info) != 0, let name = info.dli_fname, String(cString: name) == path,
              let base = info.dli_fbase else { return false }
        let header = base.assumingMemoryBound(to: mach_header_64.self).pointee
        guard header.magic == MH_MAGIC_64, header.cputype == CPU_TYPE_ARM64,
              header.cpusubtype & 0x00ff_ffff == CPU_SUBTYPE_ARM64E,
              header.ncmds < 4096, header.sizeofcmds < 1_048_576 else { return false }
        var offset = MemoryLayout<mach_header_64>.size
        let end = offset + Int(header.sizeofcmds)
        for _ in 0..<header.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { return false }
            let command = base.advanced(by: offset).assumingMemoryBound(to: load_command.self).pointee
            guard command.cmdsize >= MemoryLayout<load_command>.size, offset + Int(command.cmdsize) <= end else { return false }
            if command.cmd == LC_UUID, command.cmdsize == MemoryLayout<uuid_command>.size {
                let value = base.advanced(by: offset).assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: value).uuidString == expected
            }
            offset += Int(command.cmdsize)
        }
        return false
    }

    static func unavailable() -> BatteryControlError { .unavailable("系统锁屏状态或接口无法确认。") }

    static func facts() -> BatteryLidLockFacts {
        guard getuid() != 0, geteuid() == getuid(), platformReason == nil else { return .init() }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return .init() }
        defer { IOObjectRelease(root) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any] else { return .init() }
        let power = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var closed: Bool?
        if power != 0 {
            closed = boolean(IORegistryEntryCreateCFProperty(power, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
            IOObjectRelease(power)
        }
        return parse(registry: registry, session: CGSessionCopyCurrentDictionary() as? [String: Any], uid: getuid(), closed: closed)
    }

    /// On this pinned platform loginwindow removes the screen-lock key when
    /// unlocking. Absence alone is insufficient: require explicit registry
    /// Boolean, one matching on-console session, and matching audit identities.
    static func parse(registry: [String: Any]?, session: [String: Any]?, uid: uid_t, closed: Bool?,
                      now: TimeInterval = Date().timeIntervalSince1970) -> BatteryLidLockFacts {
        var result = BatteryLidLockFacts(closed: closed)
        guard uid != 0, let registry, let session,
              let registryLock = boolean(registry["IOConsoleLocked"]),
              let users = registry["IOConsoleUsers"] as? [[String: Any]],
              users.allSatisfy({ boolean($0[kCGSessionOnConsoleKey as String]) != nil }),
              boolean(session[kCGSessionOnConsoleKey as String]) == true,
              boolean(session[kCGSessionLoginDoneKey as String]) == true,
              number(session[kCGSessionUserIDKey as String]) == uid,
              let audit = number(session["kCGSSessionAuditIDKey"]) else { return result }
        let console = users.filter { boolean($0[kCGSessionOnConsoleKey as String]) == true }
        guard console.count == 1, let user = console.first,
              number(user[kCGSessionUserIDKey as String]) == uid,
              boolean(user[kCGSessionLoginDoneKey as String]) == true,
              number(user["kCGSSessionAuditIDKey"]) == audit,
              let currentLock = screenFlag(session), let consoleLock = screenFlag(user),
              currentLock == consoleLock, currentLock == registryLock else { return result }
        if currentLock {
            guard now.isFinite, let time = lockTime(session["CGSSessionScreenLockedTime"]),
                  time == lockTime(user["CGSSessionScreenLockedTime"]), time <= now else { return result }
        } else {
            guard session["CGSSessionScreenLockedTime"] == nil, user["CGSSessionScreenLockedTime"] == nil else { return result }
        }
        result.session = audit
        result.lock = currentLock ? .locked : .unlocked
        return result
    }

    private static func screenFlag(_ properties: [String: Any]) -> Bool? {
        guard let value = properties["CGSSessionScreenIsLocked"] else { return false }
        return boolean(value)
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func number(_ value: Any?) -> UInt32? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFNumberGetTypeID(),
              value.doubleValue >= 0, value.doubleValue <= Double(UInt32.max),
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.uint32Value
    }
    private static func lockTime(_ value: Any?) -> TimeInterval? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFNumberGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue > 0,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.doubleValue
    }
}

enum BatteryLidLockWorker {
    static let argument = "--bm1-lid-lock-worker"
    static func request(_ session: UInt32) async throws -> Int32 {
        try Task.checkCancellation()
        guard let executable = Bundle.main.executableURL else { throw BatteryLidLockSystem.unavailable() }
        // Continuous time includes sleep: a delayed worker never catches up on wake.
        let deadline = mach_continuous_time() &+ ticksForHalfSecond()
        return try await transport(session, deadline: deadline, executable: executable)
    }
    static func transport(_ session: UInt32, deadline: UInt64, executable: URL,
                          run: @escaping @Sendable (URL, [String], TimeInterval, Int) throws -> Data = {
                              try BatteryNativeReadProcess.run(executable: $0, arguments: $1, timeout: $2, maximumOutput: $3)
                          }) async throws -> Int32 {
        try Task.checkCancellation()
        let child = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let output = try run(executable, [argument, String(session), String(deadline)], 2.5, 4096)
            guard output.count <= 4096, let reply = try? JSONDecoder().decode(Reply.self, from: output), reply.schema == 1 else { throw BatteryLidLockSystem.unavailable() }
            return reply.result
        }
        return try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
    }
    private struct Reply: Codable { var schema = 1; var result: Int32 }
    private static func ticksForHalfSecond() -> UInt64 {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        guard info.numer != 0 else { return 0 }
        return 500_000_000 * UInt64(info.denom) / UInt64(info.numer)
    }
    /// Runs before SwiftUI/AppDelegate construction; it cannot start battery control.
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 4, arguments[1] == argument,
              let session = UInt32(arguments[2]), String(session) == arguments[2],
              let deadline = UInt64(arguments[3]), String(deadline) == arguments[3],
              getuid() != 0, geteuid() == getuid(), parentIsSameApplication() else { return 77 }
        let now = mach_continuous_time()
        guard deadline >= now, deadline - now <= ticksForHalfSecond() else { return 77 }
        do {
            let function = try BatteryLidLockSystem.function()
            let current = BatteryLidLockSystem.facts()
            guard current.closed == true, current.session == session, current.lock == .unlocked,
                  mach_continuous_time() <= deadline else { return 77 }
            let result = function()
            let data = try JSONEncoder().encode(Reply(result: result))
            try FileHandle.standardOutput.write(contentsOf: data)
            return 0
        } catch { return 70 }
    }
    private static func parentIsSameApplication() -> Bool {
        let parent = getppid()
        guard parent > 1, let own = Bundle.main.executableURL?.path else { return false }
        var info = proc_bsdinfo(), path = [CChar](repeating: 0, count: 4096)
        return proc_pidinfo(parent, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size
            && info.pbi_uid == getuid() && info.pbi_ruid == getuid()
            && proc_pidpath(parent, &path, UInt32(path.count)) > 0 && String(cString: path) == own
    }
}

@MainActor
private final class BatteryLidLockEvents {
    // IOPM.h's function-like macro is not imported into Swift. This is exactly
    // UInt32(sys_iokit | sub_iokit_powermanagement | 0x100), not a guessed event.
    nonisolated private static let clamshellMessage: UInt32 = 0xe0034100
    private let changed: (BatteryLidLockController.Event) -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [NSObjectProtocol] = []
    init(changed: @escaping (BatteryLidLockController.Event) -> Void) { self.changed = changed }
    func start() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            if root != 0 { IOObjectRelease(root) }; return false
        }
        defer { IOObjectRelease(root) }
        self.port = port
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, type, _ in
            guard type == BatteryLidLockEvents.clamshellMessage, let context else { return }
            // The port delivers on the main queue, shared with stop/deallocation.
            MainActor.assumeIsolated { Unmanaged<BatteryLidLockEvents>.fromOpaque(context).takeUnretainedValue().changed(.changed) }
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        guard result == KERN_SUCCESS else { stop(); return false }
        IONotificationPortSetDispatchQueue(port, .main)
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(.changed) }
            })
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(name == NSWorkspace.sessionDidBecomeActiveNotification ? .changed : .interrupted) }
            })
        }
        return true
    }
    func stop() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let port { IONotificationPortSetDispatchQueue(port, nil) }
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }
}
