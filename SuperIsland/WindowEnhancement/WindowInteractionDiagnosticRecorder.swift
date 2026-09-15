import Foundation
import OSLog

/// Only compact state codes and numbers may cross this diagnostic boundary.
/// Never pass window titles, URLs, paths, image data, or arbitrary AX strings.
enum WindowInteractionDiagnosticValue: Encodable, Equatable, Sendable {
    case integer(Int64)
    case flag(Bool)
    case code(String)

    var isAllowed: Bool {
        if case let .code(value) = self {
            return WindowInteractionDiagnosticLimiter.isStateCode(value)
        }
        return true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .flag(value): try container.encode(value)
        case let .code(value): try container.encode(value)
        }
    }
}

/// Limits admission before dispatch, so rapid pointer input cannot accumulate
/// work behind a slow filesystem. All timestamps are monotonic nanoseconds.
struct WindowInteractionDiagnosticLimiter {
    private var lastByEvent: [String: UInt64] = [:]
    private var recentAdmissions: [UInt64] = []
    private(set) var pendingWrites = 0

    static func isStateCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    mutating func admit(component: String, event: String, now: UInt64) -> Bool {
        guard Self.isStateCode(component), Self.isStateCode(event),
              pendingWrites < 16 else { return false }
        let key = component + ":" + event
        if let last = lastByEvent[key], now < last || now - last < 500_000_000 {
            return false
        }
        guard recentAdmissions.last.map({ now >= $0 }) ?? true else { return false }
        recentAdmissions.removeAll { now - $0 >= 1_000_000_000 }
        guard recentAdmissions.count < 12 else { return false }
        // Fixed call-site codes should never reach this bound. Refuse new
        // streams instead of letting arbitrary metadata grow the dictionary.
        guard lastByEvent[key] != nil || lastByEvent.count < 128 else { return false }
        lastByEvent[key] = now
        recentAdmissions.append(now)
        pendingWrites += 1
        return true
    }

    mutating func completedWrite() {
        pendingWrites = max(0, pendingWrites - 1)
    }
}

final class WindowInteractionDiagnosticRecorder: @unchecked Sendable {
    static let shared = WindowInteractionDiagnosticRecorder()

    private struct Record: Encodable {
        let schemaVersion = 1
        let timestamp: Date
        let sessionID: String
        let buildNumber: String
        let processIdentifier: Int32
        let component: String
        let event: String
        let metadata: [String: WindowInteractionDiagnosticValue]
    }

    private let bundleIdentifier: String?
    private let fileURL: URL?
    private let maximumFileBytes: UInt64
    private let sessionID = UUID().uuidString
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let lock = NSLock()
    private var limiter = WindowInteractionDiagnosticLimiter()
    private let queue = DispatchQueue(
        label: "com.workview.SuperIsland.interaction-diagnostics",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    static var diagnosticFileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/SuperIsland-WE1-Debug/interaction-state.jsonl")
    }

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileURL: URL? = WindowInteractionDiagnosticRecorder.diagnosticFileURL,
        maximumFileBytes: UInt64 = 1_048_576
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.fileURL = fileURL
        self.maximumFileBytes = maximumFileBytes
    }

    func record(
        component: String,
        event: String,
        metadata: [String: WindowInteractionDiagnosticValue] = [:]
    ) {
#if DEBUG
        guard WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: bundleIdentifier),
              let fileURL, metadata.count <= 16,
              metadata.allSatisfy({
                  WindowInteractionDiagnosticLimiter.isStateCode($0.key) && $0.value.isAllowed
              }) else { return }
        let admitted = lock.withLock {
            limiter.admit(component: component, event: event, now: DispatchTime.now().uptimeNanoseconds)
        }
        guard admitted else { return }
        let record = Record(
            timestamp: Date(), sessionID: sessionID, buildNumber: buildNumber,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            component: component, event: event, metadata: metadata
        )
        queue.async { [self] in
            defer { lock.withLock { limiter.completedWrite() } }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                var line = try encoder.encode(record)
                line.append(0x0A)
                let manager = FileManager.default
                try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: fileURL.path) {
                    let attributes = try manager.attributesOfItem(atPath: fileURL.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    if size + UInt64(line.count) > maximumFileBytes {
                        let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.jsonl")
                        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                        try manager.moveItem(at: fileURL, to: previous)
                    }
                }
                if !manager.fileExists(atPath: fileURL.path) {
                    guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Diagnostics must not affect preview or input availability.
            }
        }
#endif
    }

    /// A barrier for deterministic readback; never used from an input callback.
    func flush(completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }
}

/// Describes missing attempted events without retaining their payloads.
struct WindowLifecycleDiagnosticGap: Equatable, Sendable {
    var firstSequence: Int64
    var lastSequence: Int64
    var count: Int64

    mutating func include(_ other: Self) {
        firstSequence = min(firstSequence, other.firstSequence)
        lastSequence = max(lastSequence, other.lastSequence)
        count += other.count
    }
}

/// Once full, coalesce the remainder of the burst until its gap is dequeued.
/// This keeps both memory and sequence ordering bounded, including a final
/// overflow that is not followed by another input event.
struct WindowLifecycleDiagnosticBuffer<Value> {
    enum Delivery {
        case event(sequence: Int64, value: Value)
        case gap(WindowLifecycleDiagnosticGap)

        var sequenceRange: WindowLifecycleDiagnosticGap {
            switch self {
            case let .event(sequence, _):
                return .init(firstSequence: sequence, lastSequence: sequence, count: 1)
            case let .gap(gap): return gap
            }
        }
    }

    private let capacity: Int
    private var values: [(sequence: Int64, value: Value)] = []
    private var overflow: WindowLifecycleDiagnosticGap?
    private(set) var lastAssignedSequence: Int64 = 0
    var bufferedCount: Int { values.count }
    var hasPending: Bool { !values.isEmpty || overflow != nil }

    init(capacity: Int = 128) {
        self.capacity = min(128, max(1, capacity))
    }

    @discardableResult
    mutating func append(makeValue: (Int64) -> Value) -> Bool {
        lastAssignedSequence += 1
        let sequence = lastAssignedSequence
        guard overflow == nil, values.count < capacity else {
            let gap = WindowLifecycleDiagnosticGap(firstSequence: sequence, lastSequence: sequence, count: 1)
            if overflow == nil { overflow = gap } else { overflow?.include(gap) }
            return false
        }
        values.append((sequence, makeValue(sequence)))
        return true
    }

    mutating func popFirst() -> Delivery? {
        if !values.isEmpty {
            let entry = values.removeFirst()
            return .event(sequence: entry.sequence, value: entry.value)
        }
        guard let gap = overflow else { return nil }
        overflow = nil
        return .gap(gap)
    }
}

/// Lifecycle transitions use an independent stream; pointer-log throttling
/// must never erase observer registration or retirement transitions.
final class WindowLifecycleDiagnosticRecorder: @unchecked Sendable {
    static let shared = WindowLifecycleDiagnosticRecorder()

    private struct Record: Encodable {
        let schemaVersion = 1
        let timestamp: Date
        let sessionID: String
        let buildNumber: String
        let processIdentifier: Int32
        let elapsedMS: UInt64
        let eventSequence: Int64
        let event: String
        let metadata: [String: WindowInteractionDiagnosticValue]
    }

    private enum WriteError: Error { case nonRegularFile, recordTooLarge, createFailed }

    private let bundleIdentifier: String?
    private let fileURL: URL?
    private let maximumFileBytes: UInt64
    private let sessionID = UUID().uuidString
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let processIdentifier = ProcessInfo.processInfo.processIdentifier
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var buffer: WindowLifecycleDiagnosticBuffer<Record>
    private var drainScheduled = false
    private let queue: DispatchQueue
    // Only accessed by the utility writer. At most one compact range survives
    // an unwritable filesystem; it never retains discarded event metadata.
    private var writeFailure: WindowLifecycleDiagnosticGap?
    private let reportFailure: (@Sendable (WindowLifecycleDiagnosticGap) -> Void)?

    static var diagnosticFileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/SuperIsland-WE1-Debug/window-lifecycle.jsonl")
    }

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileURL: URL? = WindowLifecycleDiagnosticRecorder.diagnosticFileURL,
        maximumFileBytes: UInt64 = 2_097_152,
        bufferCapacity: Int = 128,
        writerQueue: DispatchQueue? = nil,
        reportFailure: (@Sendable (WindowLifecycleDiagnosticGap) -> Void)? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.fileURL = fileURL
        self.maximumFileBytes = min(2_097_152, max(1, maximumFileBytes))
        self.buffer = .init(capacity: bufferCapacity)
        self.queue = writerQueue ?? DispatchQueue(
            label: "com.workview.SuperIsland.window-lifecycle-diagnostics",
            qos: .utility, autoreleaseFrequency: .workItem
        )
        self.reportFailure = reportFailure
    }

    func record(event: String, metadata: [String: WindowInteractionDiagnosticValue] = [:]) {
#if DEBUG
        guard WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: bundleIdentifier),
              fileURL != nil, WindowInteractionDiagnosticLimiter.isStateCode(event),
              metadata.count <= 16,
              metadata.allSatisfy({
                  WindowInteractionDiagnosticLimiter.isStateCode($0.key) && $0.value.isAllowed
              }) else { return }
        let schedule = lock.withLock {
            buffer.append { sequence in makeRecord(event: event, sequence: sequence, metadata: metadata) }
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in runScheduledDrain() } }
#endif
    }

    private func makeRecord(
        event: String, sequence: Int64,
        metadata: [String: WindowInteractionDiagnosticValue]
    ) -> Record {
        let now = DispatchTime.now().uptimeNanoseconds
        return Record(
            timestamp: Date(), sessionID: sessionID, buildNumber: buildNumber,
            processIdentifier: processIdentifier,
            elapsedMS: now >= startedAt ? (now - startedAt) / 1_000_000 : 0,
            eventSequence: sequence, event: event, metadata: metadata
        )
    }

    private func gapRecord(_ gap: WindowLifecycleDiagnosticGap, reason: String) -> Record {
        makeRecord(event: "diagnosticGap", sequence: gap.lastSequence, metadata: [
            "reason": .code(reason), "firstSequence": .integer(gap.firstSequence),
            "lastSequence": .integer(gap.lastSequence), "droppedCount": .integer(gap.count)
        ])
    }

    private func runScheduledDrain() {
        drainBatch()
        let continueDraining = lock.withLock {
            if buffer.hasPending { return true }
            drainScheduled = false
            return false
        }
        if continueDraining { queue.async { [self] in runScheduledDrain() } }
    }

    /// Does not own or change scheduling state. A flush can consume the queue
    /// without forking the one scheduled writer into additional drain chains.
    private func drainBatch() {
        var failedThisBatch = false
        if let gap = writeFailure {
            do {
                try write(gapRecord(gap, reason: "writeFailed"))
                writeFailure = nil
            } catch { failedThisBatch = true }
        }
        // Yield after a bounded batch. One buffered burst plus its gap fits
        // here, while sustained producers cannot monopolize the writer queue.
        for _ in 0..<129 {
            guard let delivery = lock.withLock({ buffer.popFirst() }) else { break }
            if !failedThisBatch {
                do {
                    switch delivery {
                    case let .event(_, record): try write(record)
                    case let .gap(gap): try write(gapRecord(gap, reason: "queueOverflow"))
                    }
                    continue
                } catch { failedThisBatch = true }
            }
            let gap = delivery.sequenceRange
            if writeFailure == nil { writeFailure = gap } else { writeFailure?.include(gap) }
        }
        if failedThisBatch, let gap = writeFailure {
            if let reportFailure { reportFailure(gap) }
            else {
                // A failed destination cannot report its own failure. Keep
                // fixed-code evidence even if no later input arrives.
                let elapsedMS = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                Logger(subsystem: "com.workview.SuperIsland.WE1Debug", category: "window-lifecycle")
                    .error("writeFailed session=\(self.sessionID, privacy: .public) build=\(self.buildNumber, privacy: .public) pid=\(self.processIdentifier, privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) first=\(gap.firstSequence, privacy: .public) last=\(gap.lastSequence, privacy: .public) count=\(gap.count, privacy: .public)")
            }
        }
    }

    private func write(_ record: Record) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)
        guard UInt64(line.count) <= maximumFileBytes else { throw WriteError.recordTooLarge }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: fileURL.path) {
            let attributes = try manager.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw WriteError.nonRegularFile }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if size > maximumFileBytes - UInt64(line.count) {
                let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.jsonl")
                if manager.fileExists(atPath: previous.path) {
                    let attributes = try manager.attributesOfItem(atPath: previous.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw WriteError.nonRegularFile }
                    try manager.removeItem(at: previous)
                }
                try manager.moveItem(at: fileURL, to: previous)
            }
        }
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw WriteError.createFailed
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do { try handle.write(contentsOf: line) }
        catch {
            // Avoid leaving an incomplete JSON line ahead of later recovery.
            try? handle.truncate(atOffset: offset)
            throw error
        }
    }

    /// Deterministic readback of the already admitted bounded burst, and one
    /// explicit retry of a failed destination. Never call from an input hook.
    func flush(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            drainBatch()
            completion()
        }
    }
}
