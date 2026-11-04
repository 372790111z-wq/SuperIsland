import Foundation
import Dispatch

// An explicitly invoked, one-shot client for the sealed Preferences79 Review
// endpoint. Compile with the shared sources and the existing signing identity.
// It never registers a helper or calls SMC, CFPreferences or PowerUI directly.
private struct ReviewClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class ReviewReply: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Data, Error>?
    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; lock.unlock(); semaphore.signal()
    }
    func take() throws -> Data {
        guard semaphore.wait(timeout: .now() + 8) == .success else {
            throw ReviewClientError(message: "XPC reply timed out; acceptance and restoration remain unknown. Inspect before retrying.")
        }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }
}

@main private enum Preferences79ReviewClient {
    static func main() {
        do { try run() }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--fixed-79-review", arguments.count >= 2,
              ["inspect", "start", "cancel", "keep85"].contains(arguments[1]),
              arguments.count == (arguments[1] == "inspect" ? 2 : 3) else {
            fputs("Usage: preferences79-review --fixed-79-review inspect | start UUID | cancel UUID | keep85 UUID\n", stderr)
            exit(2)
        }
        guard getuid() != 0 else { throw ReviewClientError(message: "Run as the signed ordinary user, not root.") }
        let action = arguments[1]
        let owner: String
        if action == "inspect" { owner = "" }
        else {
            guard let id = UUID(uuidString: arguments[2]) else { throw ReviewClientError(message: "A valid explicit owner UUID is required.") }
            owner = id.uuidString
        }
        guard let requirement = KeepAwakeHelperIdentity.requirement(identifiers: [BatteryManagementIdentity.label]) else {
            throw ReviewClientError(message: "Existing signing leaf is unavailable; no connection made.")
        }
        let connection = NSXPCConnection(machServiceName: BatteryManagementIdentity.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BatteryManagementProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume(); defer { connection.invalidate() }
        func request(_ invoke: (BatteryManagementProtocol, @escaping (Data) -> Void) -> Void) throws -> Data {
            let box = ReviewReply()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ box.finish(.failure($0)) }) as? BatteryManagementProtocol else {
                throw ReviewClientError(message: "No trusted XPC proxy.")
            }
            invoke(proxy) { box.finish(.success($0)) }
            let data = try box.take()
            guard !data.isEmpty, data.count < 65_536 else { throw ReviewClientError(message: "Oversized or missing reply.") }
            return data
        }
        // The old r22 helper is protocol 14. Do not send it an unknown selector.
        let ordinaryData = try request { proxy, reply in proxy.inspect(reply: reply) }
        let ordinary = try JSONDecoder().decode(BatteryControlReport.self, from: ordinaryData)
        guard ordinary.protocolVersion == 15, ordinary.preferences79Review == true,
              ordinary.diagnosticOnly != true, ordinary.nativeCutoffReviewTrial != true else {
            throw ReviewClientError(message: "Helper is not the sealed protocol-15 Preferences79 candidate; no trial RPC sent.")
        }
        if action == "start" {
            guard ordinary.available, !ordinary.recoveryPending, ordinary.registeredTarget == nil else {
                throw ReviewClientError(message: "Helper is not idle; no start sent.")
            }
        }
        let data = try request { proxy, reply in proxy.preferences79(action: action, owner: owner, reply: reply) }
        guard let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              status["schema"] as? Int == 1, let phase = status["phase"] as? String else {
            throw ReviewClientError(message: "Trial reply has no supported status schema.")
        }
        // Preserve the daemon's saved/registered/physical/restored/unknown fields
        // individually. A preparing reply only acknowledges receipt.
        let output = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
        if phase == "rejected" { exit(3) }
    }
}
