import Foundation
import CoreFoundation

/// Keeps an AppKit termination request out of the signal source's main-dispatch
/// callback. terminateLater enters a nested run loop; that loop must be free to
/// service the MainActor work which eventually replies to the request.
@MainActor
final class WE1TerminationSignalScheduler {
    typealias Operation = @MainActor () -> Void
    typealias Enqueue = (@escaping Operation) -> Void

    private let enqueue: Enqueue
    private var queuedRequest: UUID?
    private var isInvokingTermination = false

    init(enqueue: Enqueue? = nil) {
        self.enqueue = enqueue ?? Self.enqueueOnMainRunLoop
    }

    func request(
        isTerminationDeferred: @escaping @MainActor () -> Bool,
        terminate: @escaping Operation
    ) {
        guard queuedRequest == nil, !isInvokingTermination,
              !isTerminationDeferred() else { return }
        let request = UUID()
        queuedRequest = request
        enqueue { [weak self] in
            guard let self, self.queuedRequest == request else { return }
            self.queuedRequest = nil
            guard !isTerminationDeferred() else { return }
            self.isInvokingTermination = true
            // If AppKit cancels termination, a later signal must be able to
            // retry. A still-deferred request is covered by the predicate.
            defer { self.isInvokingTermination = false }
            terminate()
        }
    }

    /// A regular Quit can overtake a queued signal. Let that quit own the
    /// recovery and discard the stale signal even if the regular quit fails.
    func terminationDidBegin() {
        guard !isInvokingTermination else { return }
        queuedRequest = nil
    }

    private static func enqueueOnMainRunLoop(_ operation: @escaping Operation) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, RunLoop.Mode.common.rawValue as CFString) {
            MainActor.assumeIsolated { operation() }
        }
        CFRunLoopWakeUp(runLoop)
    }
}
