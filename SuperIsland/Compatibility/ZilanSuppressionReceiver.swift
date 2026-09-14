import Darwin
import Foundation

struct ZilanSuppressionLease: Sendable, Equatable {
    let requestID: String
    let targetIdentityHash: String
    let expiresAtUptimeNanoseconds: UInt64
}

enum ZilanSuppressionReceiverError: Error, Equatable {
    case invalidPath
    case pathOccupied
    case systemCall(String, Int32)
}

/// The UI actor owns the applied suppression. Socket I/O never blocks this
/// actor; acceptance is acknowledged only after the synchronous UI callback.
@MainActor
final class ZilanSuppressionReceiver {
    nonisolated static var defaultSocketPath: String {
        "/tmp/com.muyz.zilan.superisland.v1.\(getuid()).sock"
    }

    private let socketPath: String
    private let expectedUID: uid_t
    private let acquire: @MainActor @Sendable (ZilanSuppressionLease) -> Bool
    private let release: @MainActor @Sendable (String) -> Void
    private var server: ZilanSuppressionSocketServer?
    private var generation: UUID?
    private var activeToken: ZilanSuppressionToken?

    init(socketPath: String = ZilanSuppressionReceiver.defaultSocketPath,
         expectedUID: uid_t = geteuid(),
         acquire: @escaping @MainActor @Sendable (ZilanSuppressionLease) -> Bool,
         release: @escaping @MainActor @Sendable (String) -> Void) {
        self.socketPath = socketPath
        self.expectedUID = expectedUID
        self.acquire = acquire
        self.release = release
    }

    func start() throws {
        guard server == nil else { return }
        let run = UUID()
        let worker = ZilanSuppressionSocketServer(path: socketPath, expectedUID: expectedUID,
            request: { [weak self] token, completion in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run, self.activeToken == nil else {
                        token.cancel()
                        completion(false)
                        return
                    }
                    let accepted = token.applyIfPending { self.acquire(token.lease) }
                    if accepted { self.activeToken = token }
                    completion(accepted)
                }
            }, cancel: { [weak self] token in
                Task { @MainActor [weak self] in self?.releaseIfOwned(token) }
            })
        try worker.start()
        generation = run
        server = worker
    }

    func stop() {
        generation = nil
        let worker = server
        server = nil
        worker?.stop()
        if let token = activeToken {
            token.cancel()
            releaseIfOwned(token)
        }
    }

    private func releaseIfOwned(_ token: ZilanSuppressionToken) {
        guard activeToken === token else { return }
        activeToken = nil
        release(token.lease.requestID)
    }
}

/// An observed disconnect/expiry and UI application serialize on this token.
/// No await occurs while its lock is held. A delayed MainActor request cannot
/// enable suppression after the I/O worker has cancelled it.
private final class ZilanSuppressionToken: @unchecked Sendable {
    let lease: ZilanSuppressionLease
    private let lock = NSLock()
    private enum State { case pending, applied, refused, cancelled }
    private var state: State = .pending

    init(lease: ZilanSuppressionLease) { self.lease = lease }

    @MainActor
    func applyIfPending(_ apply: @MainActor () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending,
              DispatchTime.now().uptimeNanoseconds < lease.expiresAtUptimeNanoseconds else {
            if state == .pending { state = .refused }
            return false
        }
        let accepted = apply()
        state = accepted ? .applied : .refused
        return accepted
    }

    var isApplied: Bool { lock.withLock { state == .applied } }
    func cancel() { lock.withLock { state = .cancelled } }
}

private struct ZilanSuppressionRequest: Decodable {
    let messageType: String
    let protocolVersion: Int
    let requestID: String
    let targetIdentityHash: String
    let deadlineMonotonic: UInt64
    let reasonCode: String

    func validatedLease(now: UInt64) -> ZilanSuppressionLease? {
        guard messageType == "suppress.request", protocolVersion == 1,
              let uuid = UUID(uuidString: requestID),
              uuid.uuidString.caseInsensitiveCompare(requestID) == .orderedSame,
              reasonCode == "menu-item-open",
              !targetIdentityHash.isEmpty, targetIdentityHash.utf8.count <= 256,
              targetIdentityHash.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                      (97...122).contains(byte) || [45, 46, 58, 95].contains(byte)
              }),
              deadlineMonotonic > now, deadlineMonotonic - now <= 2_000_000_000
        else { return nil }
        return ZilanSuppressionLease(requestID: requestID, targetIdentityHash: targetIdentityHash,
                                    expiresAtUptimeNanoseconds: deadlineMonotonic)
    }
}

private struct ZilanSuppressionRelease: Decodable {
    let messageType: String
    let protocolVersion: Int
    let requestID: String
}

private struct ZilanSuppressionAcknowledgement: Encodable {
    let messageType = "suppress.ack"
    let protocolVersion = 1
    let requestID: String
    let accepted: Bool
    let expiresAtMonotonic: UInt64
}

private final class ZilanSuppressionConnection: @unchecked Sendable {
    let descriptor: Int32
    let identity = UUID()
    var input = Data()
    var token: ZilanSuppressionToken?
    var readSource: DispatchSourceRead?
    var expiry: DispatchWorkItem?
    var receivedRequest = false

    init(descriptor: Int32) { self.descriptor = descriptor }
}

/// All mutable transport state belongs to queue. The only cross-queue state is
/// the cancellation token above. Descriptors are nonblocking and writes bounded.
private final class ZilanSuppressionSocketServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.superisland.zilan-suppression")
    private let path: String
    private let expectedUID: uid_t
    private let request: @Sendable (ZilanSuppressionToken, @escaping @Sendable (Bool) -> Void) -> Void
    private let cancel: @Sendable (ZilanSuppressionToken) -> Void
    private var listener: DispatchSourceRead?
    private var listenerDescriptor: Int32 = -1
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var connections: [Int32: ZilanSuppressionConnection] = [:]
    private var owner: ZilanSuppressionToken?
    private var running = false
    private let maximumLineBytes = 8 * 1024

    init(path: String, expectedUID: uid_t,
         request: @escaping @Sendable (ZilanSuppressionToken, @escaping @Sendable (Bool) -> Void) -> Void,
         cancel: @escaping @Sendable (ZilanSuppressionToken) -> Void) {
        self.path = path
        self.expectedUID = expectedUID
        self.request = request
        self.cancel = cancel
    }

    func start() throws {
        try queue.sync {
            guard !running else { return }
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard path.hasPrefix("/"), !bytes.contains(0),
                  bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw ZilanSuppressionReceiverError.invalidPath
            }
            var existing = stat()
            guard lstat(path, &existing) != 0 else { throw ZilanSuppressionReceiverError.pathOccupied }
            guard errno == ENOENT else { throw ZilanSuppressionReceiverError.systemCall("lstat", errno) }
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ZilanSuppressionReceiverError.systemCall("socket", errno) }
            var didBind = false
            do {
                try makeNonblocking(descriptor)
                address.sun_family = sa_family_t(AF_UNIX)
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                withUnsafeMutableBytes(of: &address.sun_path) { destination in
                    destination.copyBytes(from: bytes + [0])
                }
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else {
                    if errno == EADDRINUSE { throw ZilanSuppressionReceiverError.pathOccupied }
                    throw ZilanSuppressionReceiverError.systemCall("bind", errno)
                }
                didBind = true
                var info = stat()
                guard lstat(path, &info) == 0,
                      info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
                    throw ZilanSuppressionReceiverError.systemCall("socket-identity", errno)
                }
                socketIdentity = (info.st_dev, info.st_ino)
                // Bind first, restrict access before listen accepts any client.
                guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                    throw ZilanSuppressionReceiverError.systemCall("chmod", errno)
                }
                guard listen(descriptor, 8) == 0 else {
                    throw ZilanSuppressionReceiverError.systemCall("listen", errno)
                }
                running = true
                listenerDescriptor = descriptor
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptConnections() }
                source.setCancelHandler { Darwin.close(descriptor) }
                listener = source
                source.resume()
            } catch {
                Darwin.close(descriptor)
                if didBind { removeOwnedSocketPath() }
                throw error
            }
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            for connection in Array(connections.values) { closeConnection(connection) }
            listener?.cancel()
            listener = nil
            listenerDescriptor = -1
            removeOwnedSocketPath()
        }
    }

    private func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ZilanSuppressionReceiverError.systemCall("fcntl", errno)
        }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ZilanSuppressionReceiverError.systemCall("nosigpipe", errno)
        }
    }

    private func acceptConnections() {
        guard running else { return }
        for _ in 0..<16 {
            let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
            guard descriptor >= 0 else {
                if errno == EINTR { continue }
                return
            }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard connections.count < 16,
                  getpeereid(descriptor, &peerUID, &peerGID) == 0,
                  peerUID == expectedUID else {
                Darwin.close(descriptor)
                continue
            }
            do { try makeNonblocking(descriptor) } catch {
                Darwin.close(descriptor)
                continue
            }
            let connection = ZilanSuppressionConnection(descriptor: descriptor)
            connections[descriptor] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let connection else { return }
                self?.readAvailable(connection)
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            connection.readSource = source
            source.resume()
            armExpiry(connection, at: DispatchTime.now().uptimeNanoseconds + 250_000_000)
        }
    }

    private func readAvailable(_ connection: ZilanSuppressionConnection) {
        guard connections[connection.descriptor] === connection else { return }
        var bytes = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<8 {
            let count = recv(connection.descriptor, &bytes, bytes.count, 0)
            if count == 0 { closeConnection(connection); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                closeConnection(connection)
                return
            }
            connection.input.append(contentsOf: bytes.prefix(count))
            while let newline = connection.input.firstIndex(of: 10) {
                let length = connection.input.distance(from: connection.input.startIndex, to: newline)
                guard length <= maximumLineBytes else { closeConnection(connection); return }
                let line = connection.input.prefix(upTo: newline)
                connection.input.removeSubrange(...newline)
                handleLine(Data(line), on: connection)
                guard connections[connection.descriptor] === connection else { return }
            }
            guard connection.input.count <= maximumLineBytes else { closeConnection(connection); return }
        }
    }

    private func handleLine(_ line: Data, on connection: ZilanSuppressionConnection) {
        if !connection.receivedRequest {
            connection.receivedRequest = true
            guard let message = try? JSONDecoder().decode(ZilanSuppressionRequest.self, from: line),
                  let lease = message.validatedLease(now: DispatchTime.now().uptimeNanoseconds),
                  owner == nil else {
                closeConnection(connection)
                return
            }
            let token = ZilanSuppressionToken(lease: lease)
            owner = token
            connection.token = token
            armExpiry(connection, at: lease.expiresAtUptimeNanoseconds)
            request(token) { [weak self, weak connection] accepted in
                guard let self, let connection else { return }
                self.queue.async { self.completeAcquisition(token, accepted: accepted, connection: connection) }
            }
        } else {
            guard let message = try? JSONDecoder().decode(ZilanSuppressionRelease.self, from: line),
                  message.messageType == "suppress.release", message.protocolVersion == 1 else {
                // A second request is never a lease renewal.
                closeConnection(connection)
                return
            }
            // A stale token does not release the current lease or connection.
            guard message.requestID == connection.token?.lease.requestID else { return }
            closeConnection(connection)
        }
    }

    private func completeAcquisition(_ token: ZilanSuppressionToken, accepted: Bool,
                                     connection: ZilanSuppressionConnection) {
        guard running, connections[connection.descriptor] === connection,
              connection.token === token, owner === token else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard accepted, token.isApplied, now < token.lease.expiresAtUptimeNanoseconds else {
            sendAcknowledgement(token, accepted: false, descriptor: connection.descriptor)
            closeConnection(connection)
            return
        }
        if !sendAcknowledgement(token, accepted: true, descriptor: connection.descriptor) {
            closeConnection(connection)
        }
    }

    @discardableResult
    private func sendAcknowledgement(_ token: ZilanSuppressionToken, accepted: Bool,
                                     descriptor: Int32) -> Bool {
        let acknowledgement = ZilanSuppressionAcknowledgement(requestID: token.lease.requestID,
            accepted: accepted, expiresAtMonotonic: token.lease.expiresAtUptimeNanoseconds)
        guard var data = try? JSONEncoder().encode(acknowledgement), data.count < maximumLineBytes else { return false }
        data.append(10)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), data.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private func armExpiry(_ connection: ZilanSuppressionConnection, at deadline: UInt64) {
        connection.expiry?.cancel()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  self.connections[connection.descriptor] === connection else { return }
            self.closeConnection(connection)
        }
        connection.expiry = work
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work)
    }

    private func closeConnection(_ connection: ZilanSuppressionConnection) {
        guard connections.removeValue(forKey: connection.descriptor) === connection else { return }
        connection.expiry?.cancel()
        connection.expiry = nil
        if let token = connection.token {
            token.cancel()
            if owner === token { owner = nil }
            cancel(token)
        }
        connection.readSource?.cancel()
        connection.readSource = nil
    }

    private func removeOwnedSocketPath() {
        guard let identity = socketIdentity else { return }
        defer { socketIdentity = nil }
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == identity.device, current.st_ino == identity.inode,
              current.st_uid == geteuid(), (current.st_mode & S_IFMT) == S_IFSOCK else { return }
        _ = unlink(path)
    }
}
