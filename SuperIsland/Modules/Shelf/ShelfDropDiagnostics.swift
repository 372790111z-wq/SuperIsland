import Darwin
import Foundation

/// Explicitly enabled, bounded metadata only. Never records file names or payloads.
final class ShelfDropDiagnostics: @unchecked Sendable {
    static let debugBundleIdentifier = "com.workview.SuperIsland.WE1Debug"
    private static let shared = ShelfDropDiagnostics(
        enabled: isEnabled(environment: ProcessInfo.processInfo.environment,
                           bundleIdentifier: Bundle.main.bundleIdentifier),
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SuperIsland-WE1-Debug/shelf-drop.jsonl")
    )

    static func isEnabled(environment: [String: String], bundleIdentifier: String?) -> Bool {
        bundleIdentifier == debugBundleIdentifier && environment["WE1_SHELF_DIAGNOSTICS"] == "1"
    }

    @discardableResult
    static func record(_ event: String, destination: String = "none",
                       values: [String: Int64] = [:], code: String = "none") -> Bool {
        shared.record(event, destination: destination, values: values, code: code)
    }

    private let enabled: Bool
    private let fileURL: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let maximumPending: Int
    private let maximumRecords: Int
    private let maximumFileBytes: Int
    private var pending = 0
    private var admitted = 0
    private var stopped = false
    private var lastUpdated: UInt64?
    // Accessed only on the writer queue; changed files are recounted under flock.
    private var knownIdentity: String?
    private var knownSize: Int = -1
    private var knownLines = 0

    init(enabled: Bool, fileURL: URL, maximumPending: Int = 64,
         maximumRecords: Int = 2048, maximumFileBytes: Int = 512 * 1024,
         queue: DispatchQueue? = nil) {
        self.enabled = enabled && fileURL.isFileURL
        self.fileURL = fileURL
        self.maximumPending = min(64, max(1, maximumPending))
        self.maximumRecords = min(2048, max(1, maximumRecords))
        self.maximumFileBytes = min(512 * 1024, max(1, maximumFileBytes))
        self.queue = queue ?? DispatchQueue(label: "com.workview.SuperIsland.shelf-drop-diagnostics", qos: .utility)
    }

    @discardableResult
    func record(_ event: String, destination: String = "none",
                values: [String: Int64] = [:], code: String = "none") -> Bool {
        guard enabled, Self.validCode(event), Self.validCode(destination), Self.validCode(code),
              values.count <= 16, values.keys.allSatisfy(Self.validCode) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, pending < maximumPending, admitted < maximumRecords else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if event == "updated", let previous = lastUpdated, now - previous < 250_000_000 { return false }
        if event == "updated" { lastUpdated = now }
        pending += 1
        admitted += 1
        queue.async { [self] in
            lock.lock()
            let shouldWrite = !stopped
            lock.unlock()
            let row: [String: Any] = ["uptimeNanoseconds": now, "pid": getpid(), "event": event,
                                      "destination": destination, "code": code, "values": values]
            let success: Bool
            if shouldWrite, var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                data.append(10)
                success = append(data)
            } else {
                success = false
            }
            lock.lock()
            pending -= 1
            if !success { stopped = true }
            lock.unlock()
        }
        return true
    }

    /// Wait for previously admitted records; use only outside the writer queue.
    func flush() { queue.sync {} }

    private static func validCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
                $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private func append(_ data: Data) -> Bool {
        guard data.count <= maximumFileBytes else { return false }
        let parent = openParentDirectory()
        guard parent >= 0 else { return false }
        defer { close(parent) }
        let descriptor = openat(parent, fileURL.lastPathComponent,
                                O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumFileBytes,
              fchmod(descriptor, mode_t(0o600)) == 0 else { return false }
        let size = Int(info.st_size)
        guard size <= maximumFileBytes - data.count else { return false }
        let identity = "\(info.st_dev):\(info.st_ino)"
        if identity != knownIdentity || size != knownSize {
            var bytes = [UInt8](repeating: 0, count: size)
            if size > 0 {
                let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, size, 0) }
                guard count == size, bytes.last == 10 else { return false }
            }
            knownLines = bytes.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            knownSize = size
            knownIdentity = identity
        }
        guard knownLines < maximumRecords else { return false }
        let written = data.withUnsafeBytes { bytes -> Int in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        guard written == data.count else { return false }
        knownSize += written
        knownLines += 1
        return true
    }

    /// Walk directory descriptors so neither parents nor the file follow symlinks.
    private func openParentDirectory() -> Int32 {
        let components = fileURL.deletingLastPathComponent().pathComponents
        guard components.first == "/", !components.contains(".."), !components.contains(".") else { return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components.dropFirst() {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                    close(descriptor)
                    return -1
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid() else {
            close(descriptor)
            return -1
        }
        return descriptor
    }
}
