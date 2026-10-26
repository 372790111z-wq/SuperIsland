import Foundation

/// A separate bounded stream: pointer traffic must not throttle quit evidence.
/// Call sites supply only fixed state codes, booleans and aggregate counts.
/// This recorder never queries AX or participates in the termination decision.
final class WindowTerminationDiagnostics: @unchecked Sendable {
    enum Event: String {
        case launched, signalReceived, requestEntered, requestAlreadyPending
        case requestDeferred, requestAllowedImmediately
        case deferredTaskStarted, deferredTaskFinished, willTerminate
        case preparationStarted, recoveryProgress, recoveryAttempt, preparationFinished
        case mutationStarted, mutationFinished
    }

    static let shared = WindowTerminationDiagnostics()

    static var diagnosticFileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/SuperIsland-WE1-Debug/termination.jsonl")
    }

    private let enabled: Bool
    private let recorder: WindowLifecycleDiagnosticRecorder

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileURL: URL? = WindowTerminationDiagnostics.diagnosticFileURL,
        maximumFileBytes: UInt64 = 262_144,
        writerQueue: DispatchQueue? = nil
    ) {
        enabled = WindowInventoryDiagnosticGate.isEnabled(bundleIdentifier: bundleIdentifier)
        recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: bundleIdentifier,
            fileURL: fileURL,
            maximumFileBytes: min(262_144, maximumFileBytes),
            writerQueue: writerQueue ?? DispatchQueue(
                label: "com.workview.SuperIsland.termination-diagnostics",
                qos: .utility, autoreleaseFrequency: .workItem
            )
        )
    }

    func record(_ event: Event, metadata: [String: WindowInteractionDiagnosticValue] = [:]) {
        recorder.record(event: event.rawValue, metadata: metadata)
    }

    /// Best effort only, called once from applicationWillTerminate. The writer
    /// has no main-thread work. A slow/unwritable filesystem cannot veto exit or
    /// introduce another terminateLater/MainActor handshake.
    @discardableResult
    func flushBeforeExit(timeout: TimeInterval = 0.15) -> Bool {
#if DEBUG
        guard enabled else { return true }
        let completed = DispatchSemaphore(value: 0)
        recorder.flush { completed.signal() }
        let boundedTimeout = timeout.isFinite ? min(0.15, max(0, timeout)) : 0.15
        return completed.wait(timeout: .now() + boundedTimeout) == .success
#else
        return true
#endif
    }

    func flush(completion: @escaping @Sendable () -> Void) {
        recorder.flush(completion: completion)
    }
}
