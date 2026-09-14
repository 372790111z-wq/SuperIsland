import Darwin
import Foundation
import XCTest
@testable import SuperIsland

@MainActor
final class ZilanSuppressionReceiverTests: XCTestCase {
    func testAcknowledgesOnlyAfterApplyingAndReleaseIsIdempotent() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        try fixture.receiver.start()
        var metadata = stat()
        XCTAssertEqual(lstat(fixture.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_uid, geteuid())

        let request = WireRequest()
        let client = try await connect(fixture.path, request: request)
        defer { client.close() }
        let ack = try await acknowledgement(client)
        XCTAssertEqual(ack?.messageType, "suppress.ack")
        XCTAssertEqual(ack?.protocolVersion, 1)
        XCTAssertEqual(ack?.requestID, request.requestID)
        XCTAssertEqual(ack?.accepted, true)
        XCTAssertEqual(ack?.expiresAtMonotonic, request.deadlineMonotonic)
        XCTAssertEqual(fixture.acquired.map(\.requestID), [request.requestID])
        XCTAssertEqual(fixture.activeID, request.requestID)

        try client.write(releaseData(request.requestID))
        await eventually { fixture.released.count == 1 }
        client.close()
        fixture.receiver.stop()
        fixture.receiver.stop()
        XCTAssertEqual(fixture.released, [request.requestID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testActiveTapCaptureRefusesAckAndNormalReleaseRestoresCapture() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        XCTAssertTrue(fixture.tapInteraction.beginCapture())
        let rejected = try await connect(fixture.path, request: WireRequest())
        defer { rejected.close() }
        try await assertAccepted(rejected, false)
        XCTAssertTrue(fixture.tapInteraction.isCapturing)
        XCTAssertFalse(fixture.tapInteraction.isSuppressed)
        XCTAssertTrue(fixture.released.isEmpty)

        fixture.tapInteraction.endCapture()
        let request = WireRequest()
        let accepted = try await connect(fixture.path, request: request)
        defer { accepted.close() }
        try await assertAccepted(accepted, true)
        XCTAssertFalse(fixture.tapInteraction.beginCapture())
        try accepted.write(releaseData(request.requestID))
        await eventually { fixture.released == [request.requestID] }
        XCTAssertTrue(fixture.tapInteraction.beginCapture())
    }

    func testDisconnectReleasesAppliedLease() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let request = WireRequest()
        let client = try await connect(fixture.path, request: request)
        try await assertAccepted(client, true)
        client.close()
        await eventually { fixture.released == [request.requestID] }
        XCTAssertNil(fixture.activeID)
    }

    func testTTLReleasesWithoutClientCooperation() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let request = WireRequest(lifetimeNanoseconds: 180_000_000)
        let client = try await connect(fixture.path, request: request)
        defer { client.close() }
        try await assertAccepted(client, true)
        await eventually { fixture.released == [request.requestID] }
        XCTAssertNil(fixture.activeID)
        XCTAssertFalse(fixture.tapInteraction.isSuppressed)
        XCTAssertTrue(fixture.tapInteraction.beginCapture())
        let eof = try await readLine(client)
        XCTAssertNil(eof)
    }

    func testAcquisitionCrossingDeadlineNeverAcknowledgesProtectionAndRestoresTap() async throws {
        let fixture = try ReceiverFixture(acquisitionDelay: 0.22)
        defer { fixture.stop() }
        try fixture.receiver.start()
        let request = WireRequest(lifetimeNanoseconds: 150_000_000)
        let client = try await connect(fixture.path, request: request)
        defer { client.close() }
        let ack = try await acknowledgement(client)
        XCTAssertNotEqual(ack?.accepted, true)
        await eventually { !fixture.tapInteraction.isSuppressed }
        XCTAssertNil(fixture.activeID)
        XCTAssertTrue(fixture.tapInteraction.beginCapture())
    }

    func testStopSynchronouslyReleasesAndCanRestart() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let first = WireRequest()
        let firstClient = try await connect(fixture.path, request: first)
        defer { firstClient.close() }
        try await assertAccepted(firstClient, true)
        fixture.receiver.stop()
        XCTAssertEqual(fixture.released, [first.requestID])
        XCTAssertNil(fixture.activeID)
        try fixture.receiver.start()
        let second = WireRequest()
        let secondClient = try await connect(fixture.path, request: second)
        defer { secondClient.close() }
        try await assertAccepted(secondClient, true)
        XCTAssertEqual(fixture.activeID, second.requestID)
        fixture.receiver.stop()
        XCTAssertEqual(fixture.released, [first.requestID, second.requestID])
    }

    func testDeclinedUIHasNegativeAckAndNoReleaseCallback() async throws {
        let fixture = try ReceiverFixture(accepts: false)
        defer { fixture.stop() }
        try fixture.receiver.start()
        let client = try await connect(fixture.path, request: WireRequest())
        defer { client.close() }
        try await assertAccepted(client, false)
        await pause()
        XCTAssertEqual(fixture.acquired.count, 1)
        XCTAssertEqual(fixture.released, [])
        XCTAssertNil(fixture.activeID)
    }

    func testSecondConnectionCannotReplaceActiveLease() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let first = WireRequest()
        let client = try await connect(fixture.path, request: first)
        defer { client.close() }
        try await assertAccepted(client, true)
        let other = try await connect(fixture.path, request: WireRequest())
        defer { other.close() }
        try await assertClosed(other)
        XCTAssertEqual(fixture.activeID, first.requestID)
        XCTAssertEqual(fixture.acquired.count, 1)
        XCTAssertTrue(fixture.released.isEmpty)
    }

    func testOldReleaseCannotReleaseNewLease() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let first = WireRequest()
        let oldClient = try await connect(fixture.path, request: first)
        try await assertAccepted(oldClient, true)
        oldClient.close()
        await eventually { fixture.released == [first.requestID] }
        let second = WireRequest()
        let client = try await connect(fixture.path, request: second)
        defer { client.close() }
        try await assertAccepted(client, true)
        try client.write(releaseData(first.requestID))
        await pause()
        XCTAssertEqual(fixture.activeID, second.requestID)
        XCTAssertEqual(fixture.released, [first.requestID])
        try client.write(releaseData(second.requestID))
        await eventually { fixture.released == [first.requestID, second.requestID] }
    }

    func testSecondRequestOnConnectionCannotRenewLease() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let first = WireRequest()
        let client = try await connect(fixture.path, request: first)
        defer { client.close() }
        try await assertAccepted(client, true)
        try client.write(try WireRequest().encoded())
        await eventually { fixture.released == [first.requestID] }
        XCTAssertEqual(fixture.acquired.count, 1)
        try await assertClosed(client)
    }

    func testFragmentedRequestIsAccepted() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let request = WireRequest()
        let client = try SocketClient(path: fixture.path)
        defer { client.close() }
        let data = try request.encoded()
        try client.write(Data(data.prefix(30)))
        await pause()
        XCTAssertTrue(fixture.acquired.isEmpty)
        try client.write(Data(data.dropFirst(30)))
        try await assertAccepted(client, true)
    }

    func testDisconnectBeforeMainActorRunsDoesNotApplyLate() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let path = fixture.path
        let pending = Task.detached {
            let client = try SocketClient(path: path)
            try client.write(try WireRequest().encoded())
            client.close()
        }
        stallMainActor(milliseconds: 160)
        try await pending.value
        await pause()
        XCTAssertTrue(fixture.acquired.isEmpty)
        XCTAssertTrue(fixture.released.isEmpty)
    }

    func testTTLBeforeMainActorRunsDoesNotApplyLate() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let path = fixture.path
        let pending = Task.detached {
            let client = try SocketClient(path: path)
            try client.write(try WireRequest(lifetimeNanoseconds: 70_000_000).encoded())
            return client
        }
        stallMainActor(milliseconds: 220)
        let client = try await pending.value
        defer { client.close() }
        await pause()
        XCTAssertTrue(fixture.acquired.isEmpty)
        XCTAssertTrue(fixture.released.isEmpty)
        try await assertClosed(client)
    }

    func testBufferedReleaseBeforeMainActorRunsDoesNotApplyLate() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let path = fixture.path
        let pending = Task.detached {
            let request = WireRequest()
            let client = try SocketClient(path: path)
            try client.write(try request.encoded() + releaseData(request.requestID))
            return client
        }
        stallMainActor(milliseconds: 160)
        let client = try await pending.value
        defer { client.close() }
        await pause()
        XCTAssertTrue(fixture.acquired.isEmpty)
        XCTAssertTrue(fixture.released.isEmpty)
        try await assertClosed(client)
    }

    func testStopGenerationRejectsQueuedRequestAfterRestart() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let path = fixture.path
        let pending = Task.detached {
            let client = try SocketClient(path: path)
            try client.write(try WireRequest().encoded())
            return client
        }
        stallMainActor(milliseconds: 120)
        fixture.receiver.stop()
        try fixture.receiver.start()
        let oldClient = try await pending.value
        defer { oldClient.close() }
        await pause()
        XCTAssertTrue(fixture.acquired.isEmpty)
        let newRequest = WireRequest()
        let newClient = try await connect(path, request: newRequest)
        defer { newClient.close() }
        try await assertAccepted(newClient, true)
        XCTAssertEqual(fixture.activeID, newRequest.requestID)
        XCTAssertTrue(fixture.released.isEmpty)
    }

    func testInvalidProtocolFieldsNeverReachUI() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        var invalid: [WireRequest] = []
        var request = WireRequest(); request.protocolVersion = 2; invalid.append(request)
        request = WireRequest(); request.requestID = "not-a-uuid"; invalid.append(request)
        request = WireRequest(); request.reasonCode = "any-action"; invalid.append(request)
        request = WireRequest(); request.messageType = "suppress.release"; invalid.append(request)
        request = WireRequest(); request.targetIdentityHash = ""; invalid.append(request)
        request = WireRequest(); request.targetIdentityHash = "a/b"; invalid.append(request)
        request = WireRequest(); request.targetIdentityHash = String(repeating: "a", count: 257); invalid.append(request)
        request = WireRequest(); request.deadlineMonotonic = 0; invalid.append(request)
        request = WireRequest(); request.deadlineMonotonic = UInt64.max; invalid.append(request)
        for request in invalid {
            let client = try await connect(fixture.path, request: request)
            try await assertClosed(client)
            client.close()
        }
        XCTAssertTrue(fixture.acquired.isEmpty)
        XCTAssertTrue(fixture.released.isEmpty)
    }

    func testMalformedUTF8AndOversizedLinesAreRejected() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        for data in [Data([0xff, 0x0a]), Data("{broken}\n".utf8),
                     Data(repeating: 65, count: 8193), Data(repeating: 65, count: 8193) + Data([10])] {
            let client = try SocketClient(path: fixture.path)
            try client.write(data)
            try await assertClosed(client)
            client.close()
        }
        XCTAssertTrue(fixture.acquired.isEmpty)
    }

    func testIncompleteLineHasBoundedInitialWait() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let client = try SocketClient(path: fixture.path)
        defer { client.close() }
        try client.write(Data("{".utf8))
        try await assertClosed(client)
        XCTAssertTrue(fixture.acquired.isEmpty)
    }

    func testDifferentUIDIsRejectedBeforeDecoding() async throws {
        let fixture = try ReceiverFixture(expectedUID: geteuid() &+ 1)
        defer { fixture.stop() }
        try fixture.receiver.start()
        // The transport rejects this identity before reading any payload. Do
        // not race a write against that intentional immediate disconnect.
        let client = try SocketClient(path: fixture.path)
        defer { client.close() }
        try await assertClosed(client)
        XCTAssertTrue(fixture.acquired.isEmpty)
    }

    func testOccupiedSocketIsNotTakenOver() async throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        let second = ZilanSuppressionReceiver(socketPath: fixture.path, acquire: { _ in true }, release: { _ in })
        defer { second.stop() }
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual($0 as? ZilanSuppressionReceiverError, .pathOccupied)
        }
        let client = try await connect(fixture.path, request: WireRequest())
        defer { client.close() }
        try await assertAccepted(client, true)
    }

    func testExistingRegularFileIsPreserved() throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        let contents = Data("preserve-existing-file".utf8)
        try contents.write(to: URL(fileURLWithPath: fixture.path))
        XCTAssertThrowsError(try fixture.receiver.start()) {
            XCTAssertEqual($0 as? ZilanSuppressionReceiverError, .pathOccupied)
        }
        fixture.receiver.stop()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.path)), contents)
    }

    func testExistingSymlinkIsPreserved() throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        let destination = fixture.path + "-target"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: destination))
        try FileManager.default.createSymbolicLink(atPath: fixture.path, withDestinationPath: destination)
        XCTAssertThrowsError(try fixture.receiver.start()) {
            XCTAssertEqual($0 as? ZilanSuppressionReceiverError, .pathOccupied)
        }
        fixture.receiver.stop()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.path), destination)
        XCTAssertEqual(try String(contentsOfFile: destination), "keep")
    }

    func testStopDoesNotDeletePathReplacedWithDifferentInode() throws {
        let fixture = try ReceiverFixture()
        defer { fixture.stop() }
        try fixture.receiver.start()
        XCTAssertEqual(unlink(fixture.path), 0)
        let replacement = Data("new-owner".utf8)
        try replacement.write(to: URL(fileURLWithPath: fixture.path))
        fixture.receiver.stop()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.path)), replacement)
    }

    func testInvalidPathsDoNotCreateAnything() throws {
        for path in ["relative.sock", "/tmp/\0bad.sock", "/tmp/" + String(repeating: "x", count: 150)] {
            let receiver = ZilanSuppressionReceiver(socketPath: path, acquire: { _ in true }, release: { _ in })
            XCTAssertThrowsError(try receiver.start()) {
                XCTAssertEqual($0 as? ZilanSuppressionReceiverError, .invalidPath)
            }
            receiver.stop()
        }
    }

    private func assertAccepted(_ client: SocketClient, _ accepted: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await acknowledgement(client)
        XCTAssertEqual(result?.accepted, accepted, file: file, line: line)
    }

    private func assertClosed(_ client: SocketClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await readLine(client)
        XCTAssertNil(result, file: file, line: line)
    }

    private func connect(_ path: String, request: WireRequest) async throws -> SocketClient {
        try await Task.detached {
            let client = try SocketClient(path: path)
            try client.write(try request.encoded())
            return client
        }.value
    }

    private func readLine(_ client: SocketClient) async throws -> Data? {
        try await Task.detached { try client.readLine() }.value
    }

    private func acknowledgement(_ client: SocketClient) async throws -> WireAcknowledgement? {
        guard let line = try await readLine(client) else { return nil }
        return try JSONDecoder().decode(WireAcknowledgement.self, from: line)
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Expected lifecycle transition did not arrive", file: file, line: line)
    }

    private func pause() async { try? await Task.sleep(nanoseconds: 50_000_000) }
    private func stallMainActor(milliseconds: Double) { Thread.sleep(forTimeInterval: milliseconds / 1000) }
}

@MainActor
private final class ReceiverFixture {
    let directory: URL
    let path: String
    var receiver: ZilanSuppressionReceiver!
    var acquired: [ZilanSuppressionLease] = []
    var released: [String] = []
    var activeID: String?
    let tapInteraction = ZilanEventTapInteractionState()

    init(accepts: Bool = true, expectedUID: uid_t = geteuid(), acquisitionDelay: TimeInterval = 0) throws {
        directory = URL(fileURLWithPath: "/tmp/zilan-rx-\(UUID().uuidString.prefix(12))", isDirectory: true)
        path = directory.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        receiver = ZilanSuppressionReceiver(socketPath: path, expectedUID: expectedUID, acquire: { [weak self] lease in
            guard let self else { return false }
            self.acquired.append(lease)
            guard accepts, self.tapInteraction.beginSuppression(requestID: lease.requestID) else { return false }
            self.activeID = lease.requestID
            if acquisitionDelay > 0 { Thread.sleep(forTimeInterval: acquisitionDelay) }
            return true
        }, release: { [weak self] requestID in
            self?.released.append(requestID)
            self?.tapInteraction.endSuppression(requestID: requestID)
            if self?.activeID == requestID { self?.activeID = nil }
        })
    }

    func stop() {
        receiver.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct WireRequest: Encodable, Sendable {
    var messageType = "suppress.request"
    var protocolVersion = 1
    var requestID = UUID().uuidString
    var targetIdentityHash = "ax-0011aabbcc"
    var deadlineMonotonic: UInt64
    var reasonCode = "menu-item-open"

    init(lifetimeNanoseconds: UInt64 = 1_500_000_000) {
        deadlineMonotonic = DispatchTime.now().uptimeNanoseconds + lifetimeNanoseconds
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) + Data([10]) }
}

private struct WireAcknowledgement: Decodable, Sendable {
    let messageType: String
    let protocolVersion: Int
    let requestID: String
    let accepted: Bool
    let expiresAtMonotonic: UInt64
}

private func releaseData(_ requestID: String) -> Data {
    Data("{\"messageType\":\"suppress.release\",\"protocolVersion\":1,\"requestID\":\"\(requestID)\"}\n".utf8)
}

private enum SocketFixtureError: Error { case systemCall(String, Int32) }

private final class SocketClient: @unchecked Sendable {
    private var descriptor: Int32

    init(path: String) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketFixtureError.systemCall("socket", errno) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let error = errno
            close()
            throw SocketFixtureError.systemCall("connect", error)
        }
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < data.count {
                let result = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw SocketFixtureError.systemCall("send", errno) }
                sent += result
            }
        }
    }

    func readLine() throws -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= 8192 {
            let count = recv(descriptor, &byte, 1, 0)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == ECONNRESET { return nil }
                throw SocketFixtureError.systemCall("recv", errno)
            }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw SocketFixtureError.systemCall("line-too-long", EMSGSIZE)
    }
}
