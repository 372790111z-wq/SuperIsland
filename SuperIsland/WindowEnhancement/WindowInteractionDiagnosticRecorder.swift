import Foundation

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
