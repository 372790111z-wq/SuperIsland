import Foundation
import ObjectiveC
import Darwin

#if BATTERY_HELPER || DEBUG
/// One callback result with a monotonic deadline. Timeout closes the same
/// state as completion, so a late or duplicate XPC reply cannot replace it.
final class BatteryNativeAsyncReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let deadline: DispatchTime
    private var result: Result<Value, Error>?

    init(timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 3 else {
            throw BatteryControlError.invalid("无效的系统异步读取时限。")
        }
        deadline = .now() + timeout
    }

    private func timeoutError() -> Error {
        BatteryControlError.unavailable("系统限充异步读取超时。")
    }

    @discardableResult
    func complete(_ candidate: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        let timely = DispatchTime.now() < deadline
        result = timely ? candidate : .failure(timeoutError())
        lock.unlock()
        semaphore.signal()
        return timely
    }

    func wait() throws -> Value {
        lock.lock()
        let completed = result
        lock.unlock()
        if let completed { return try completed.get() }
        _ = semaphore.wait(timeout: deadline)
        lock.lock()
        if result == nil { result = .failure(timeoutError()) }
        let final = result ?? .failure(timeoutError())
        lock.unlock()
        return try final.get()
    }
}

enum BatteryNativeAsyncValidation {
    static func acceptsQuery(_ query: BatteryNativeReadQuery) -> Bool {
        switch query {
        case .supported, .enabled, .limit: return true
        default: return false
        }
    }

    static func result(query: BatteryNativeReadQuery, rawValue: UInt64, error: NSError?) -> Result<Int, Error> {
        guard acceptsQuery(query) else {
            return .failure(BatteryControlError.invalid("异步客户端只接受三项固定的基础读取。"))
        }
        if let error { return .failure(error) }
        guard rawValue <= UInt64(Int.max), query.accepts(Int(rawValue)) else {
            return .failure(BatteryControlError.unavailable("系统限充异步返回值无效。"))
        }
        return .success(Int(rawValue))
    }
}

/// Read-only PowerUI bridge. Construction never issues the synchronous
/// isMCLSupported probe; support is an explicit, bounded asynchronous query.
/// The owning worker provides the separate process/initialization boundary.
final class BatteryNativeAsyncReadClient {
    private let object: AnyObject
    private let dispatch: UnsafeMutableRawPointer

    init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let dispatch = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            throw BatteryControlError.unavailable("系统异步限充客户端不可用。")
        }
        let shapes = [
            "initWithClientName:": "@24@0:8@16",
            "isMCLSupportedWithHandler:": "v24@0:8@?16",
            "isMCLCurrentlyEnabledWithHandler:": "v24@0:8@?16",
            "getMCLLimitWithHandler:": "v24@0:8@?16"
        ]
        guard shapes.allSatisfy({ name, shape in
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let actual = method_getTypeEncoding(method) else { return false }
            return String(cString: actual) == shape
        }) else {
            throw BatteryControlError.unavailable("系统异步限充接口版本不兼容。")
        }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let allocated = unsafeBitCast(dispatch, to: Alloc.self)(cls, NSSelectorFromString("alloc"))
        guard let initialized = unsafeBitCast(dispatch, to: Init.self)(allocated.takeUnretainedValue(),
                NSSelectorFromString("initWithClientName:"), "SuperIsland.Battery") else {
            throw BatteryControlError.unavailable("系统异步限充客户端无法初始化。")
        }
        object = initialized.takeRetainedValue()
        self.dispatch = dispatch
    }

    func value(_ query: BatteryNativeReadQuery, timeout: TimeInterval = 0.9) throws -> Int {
        guard BatteryNativeAsyncValidation.acceptsQuery(query) else {
            throw BatteryControlError.invalid("异步客户端只接受三项固定的基础读取。")
        }
        let reply = try BatteryNativeAsyncReply<Int>(timeout: timeout)
        switch query {
        case .supported:
            typealias Handler = @convention(block) (Bool, NSError?) -> Void
            typealias Call = @convention(c) (AnyObject, Selector, Handler) -> Void
            let completion: Handler = { value, error in
                reply.complete(BatteryNativeAsyncValidation.result(query: query, rawValue: value ? 1 : 0, error: error))
            }
            unsafeBitCast(dispatch, to: Call.self)(object, NSSelectorFromString("isMCLSupportedWithHandler:"), completion)
            return try withExtendedLifetime(completion) { try reply.wait() }
        case .enabled:
            typealias Handler = @convention(block) (UInt64, NSError?) -> Void
            typealias Call = @convention(c) (AnyObject, Selector, Handler) -> Void
            let completion: Handler = { value, error in
                reply.complete(BatteryNativeAsyncValidation.result(query: query, rawValue: value, error: error))
            }
            unsafeBitCast(dispatch, to: Call.self)(object, NSSelectorFromString("isMCLCurrentlyEnabledWithHandler:"), completion)
            return try withExtendedLifetime(completion) { try reply.wait() }
        case .limit:
            typealias Handler = @convention(block) (UInt8, NSError?) -> Void
            typealias Call = @convention(c) (AnyObject, Selector, Handler) -> Void
            let completion: Handler = { value, error in
                reply.complete(BatteryNativeAsyncValidation.result(query: query, rawValue: UInt64(value), error: error))
            }
            unsafeBitCast(dispatch, to: Call.self)(object, NSSelectorFromString("getMCLLimitWithHandler:"), completion)
            return try withExtendedLifetime(completion) { try reply.wait() }
        default:
            throw BatteryControlError.invalid("异步客户端只接受三项固定的基础读取。")
        }
    }
    #if BATTERY_REVIEW || DEBUG
    /// A distinct, fixed review contract. Normal native reads and setters keep
    /// their 80...100 floor; a 79 result must never pass through that validator.
    func preferences79Limit(timeout: TimeInterval = 0.9) throws -> Int {
        let reply = try BatteryNativeAsyncReply<Int>(timeout: timeout)
        typealias Handler = @convention(block) (UInt8, NSError?) -> Void
        typealias Call = @convention(c) (AnyObject, Selector, Handler) -> Void
        let completion: Handler = { value, error in
            if let error { reply.complete(.failure(error)) }
            // A disabled manager returns 100; admission must pair it with the
            // independently read enabled state. This never permits a 100 write.
            else if (79...85).contains(Int(value)) || value == 100 { reply.complete(.success(Int(value))) }
            else { reply.complete(.failure(BatteryControlError.unavailable("79试验原始目标读回超出独立读取合同。"))) }
        }
        unsafeBitCast(dispatch, to: Call.self)(object, NSSelectorFromString("getMCLLimitWithHandler:"), completion)
        return try withExtendedLifetime(completion) { try reply.wait() }
    }
    #endif
}
#endif
