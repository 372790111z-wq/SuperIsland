import AppKit
import Foundation

/// Closed metadata vocabulary: no titles, URLs, script text, extension IDs,
/// or keyboard input can enter this recorder through a free-form string.
final class IslandSwipeDiagnostics: @unchecked Sendable {
    enum Module: String, CaseIterable {
        case none, home, nowPlaying, volumeHUD, battery, shelf, connectivity
        case calendar, weather, notifications, teleprompter, extensionModule

        static func code(for module: ActiveModule?) -> Self {
            guard let module else { return .none }
            switch module {
            case .extension_: return .extensionModule
            case .builtIn(let builtIn):
                switch builtIn {
                case .nowPlaying: return .nowPlaying
                case .volumeHUD: return .volumeHUD
                case .battery: return .battery
                case .shelf: return .shelf
                case .connectivity: return .connectivity
                case .calendar: return .calendar
                case .weather: return .weather
                case .notifications: return .notifications
                case .teleprompter: return .teleprompter
                }
            }
        }
    }

    enum Event: String {
        case gestureReceived = "gesture.received"
        case gestureDecision = "gesture.decision"
        case gestureSummary = "gesture.summary"
        case generationGate = "generation.gate"
        case switchBefore = "switch.before"
        case switchAfter = "switch.after"
        case nextMainTurn = "switch.next-main-turn"
        case pageAppeared = "page.appeared"
    }

    enum Reason: String, CaseIterable {
        case none, received, notPrecise, suppressed, nestedScrollView, verticalLock
        case belowThreshold, triggered, momentum, ended, cancelled, timeout, restarted
        case detached, allowed, generationRejected, compact, noModules, duplicate
    }

    enum Metric: String {
        case gestureID, events, preciseEvents, deltaX100, deltaY100, durationMicros
        case decisions, state, generation, capturedGeneration, direction
        case switchID, elapsedMicros, queueMicros
    }

    struct Record {
        let event: Event
        let module: Module
        let reason: Reason
        let values: [Metric: Int64]
    }

    static let runtimeEnabled = isEnabled(
        environment: ProcessInfo.processInfo.environment,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )
    private static let shared = IslandSwipeDiagnostics(
        enabled: runtimeEnabled,
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SuperIsland-WE1-Debug/island-swipe.jsonl")
    )
    private let writer: ShelfDropDiagnostics

    static func isEnabled(environment: [String: String], bundleIdentifier: String?) -> Bool {
        bundleIdentifier == ShelfDropDiagnostics.debugBundleIdentifier &&
            environment["WE1_SWIPE_DIAGNOSTICS"] == "1"
    }

    init(enabled: Bool, fileURL: URL) {
        writer = ShelfDropDiagnostics(
            enabled: enabled, fileURL: fileURL, maximumPending: 64,
            maximumRecords: 2048, maximumFileBytes: 512 * 1024,
            queue: DispatchQueue(label: "com.workview.SuperIsland.island-swipe-diagnostics", qos: .utility)
        )
    }

    @discardableResult
    func record(_ record: Record) -> Bool {
        writer.record(record.event.rawValue, destination: record.module.rawValue,
                      values: Dictionary(uniqueKeysWithValues: record.values.map { ($0.key.rawValue, $0.value) }),
                      code: record.reason.rawValue)
    }

    static func record(_ record: Record) {
        guard runtimeEnabled else { return }
        _ = shared.record(record)
    }

    static func record(_ event: Event, module: Module = .none, reason: Reason = .none,
                       values: [Metric: Int64] = [:]) {
        record(Record(event: event, module: module, reason: reason, values: values))
    }

    func flush() { writer.flush() }

    static func integer(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }

    @MainActor
    static func module(in state: AppState) -> Module {
        if state.currentState == .fullExpanded {
            switch state.fullExpandedSelectedTab {
            case .home: return .home
            case .module(let module): return Module.code(for: module)
            }
        }
        return Module.code(for: state.activeModule)
    }

    static func stateCode(_ state: IslandState) -> Int64 {
        switch state {
        case .compact: return 0
        case .expanded: return 1
        case .fullExpanded: return 2
        }
    }

    @MainActor
    static func beginSwitch(in state: AppState, forward: Bool) -> UInt64? {
        guard runtimeEnabled else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        record(.switchBefore, module: module(in: state), values: [
            .switchID: Int64(clamping: start), .state: stateCode(state.currentState),
            .generation: Int64(clamping: state.islandInputGeneration), .direction: forward ? 1 : -1
        ])
        return start
    }

    @MainActor
    static func completeSwitch(in state: AppState, started: UInt64?) {
        guard let started else { return }
        let queued = DispatchTime.now().uptimeNanoseconds
        record(.switchAfter, module: module(in: state), values: [
            .switchID: Int64(clamping: started), .state: stateCode(state.currentState),
            .elapsedMicros: Int64(clamping: (queued - started) / 1_000)
        ])
        DispatchQueue.main.async { [weak state] in
            guard let state else { return }
            record(.nextMainTurn, module: module(in: state), values: [
                .switchID: Int64(clamping: started), .state: stateCode(state.currentState),
                .queueMicros: Int64(clamping: (DispatchTime.now().uptimeNanoseconds - queued) / 1_000)
            ])
        }
    }
}

/// Observes decisions without participating in gesture ownership or thresholds.
/// At most one row per reason plus a beginning/summary is emitted per gesture.
struct IslandSwipeGestureDiagnostics {
    typealias Log = IslandSwipeDiagnostics
    private struct Gesture {
        let id: Int64
        let start: TimeInterval
        let module: Log.Module
        let state: Int64
        let generation: UInt64
        var last: TimeInterval
        var events: Int64 = 0
        var preciseEvents: Int64 = 0
        var deltaX: Double = 0
        var deltaY: Double = 0
        var decisions: Set<Log.Reason> = []
    }
    private let enabled: Bool
    private let emit: (Log.Record) -> Void
    private var gesture: Gesture?

    init(enabled: Bool = IslandSwipeDiagnostics.runtimeEnabled,
         emit: @escaping (Log.Record) -> Void = IslandSwipeDiagnostics.record) {
        self.enabled = enabled
        self.emit = emit
    }

    mutating func receive(timestamp: TimeInterval, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                          precise: Bool, deltaX: Double, deltaY: Double,
                          module: Log.Module, state: Int64, generation: UInt64) {
        guard enabled else { return }
        if let current = gesture {
            if phase.contains(.began) {
                finish(.restarted)
            } else if timestamp - current.last > IslandSurfaceScrollOwnership.gestureTimeout {
                finish(.timeout)
            }
        }
        // Trailing momentum and end events must not create extra gestures.
        if gesture == nil {
            guard momentum.isEmpty, !phase.contains(.ended), !phase.contains(.cancelled) else { return }
            gesture = Gesture(id: Int64(clamping: DispatchTime.now().uptimeNanoseconds), start: timestamp,
                              module: module, state: state, generation: generation, last: timestamp)
            emitRow(.gestureReceived, reason: .received)
        }
        gesture?.last = timestamp
        gesture?.events += 1
        if precise { gesture?.preciseEvents += 1 }
        if deltaX.isFinite { gesture?.deltaX += deltaX }
        if deltaY.isFinite { gesture?.deltaY += deltaY }
        if !precise { decision(.notPrecise) }
        if !momentum.isEmpty { decision(.momentum) }
        if phase.contains(.cancelled) { finish(.cancelled) }
        else if phase.contains(.ended) { finish(.ended) }
    }

    mutating func decision(_ reason: Log.Reason) {
        guard enabled, gesture != nil, gesture?.decisions.insert(reason).inserted == true else { return }
        emitRow(.gestureDecision, reason: reason)
    }

    mutating func finish(_ reason: Log.Reason) {
        guard enabled, gesture != nil else { return }
        emitRow(.gestureSummary, reason: reason)
        gesture = nil
    }

    private func emitRow(_ event: Log.Event, reason: Log.Reason) {
        guard let gesture else { return }
        let mask = Log.Reason.allCases.enumerated().reduce(Int64(0)) { result, pair in
            gesture.decisions.contains(pair.element) ? result | (Int64(1) << pair.offset) : result
        }
        emit(Log.Record(event: event, module: gesture.module, reason: reason, values: [
            .gestureID: gesture.id, .events: gesture.events, .preciseEvents: gesture.preciseEvents,
            .deltaX100: Log.integer(gesture.deltaX * 100), .deltaY100: Log.integer(gesture.deltaY * 100),
            .durationMicros: Log.integer(max(0, gesture.last - gesture.start) * 1_000_000),
            .decisions: mask, .state: gesture.state, .generation: Int64(clamping: gesture.generation)
        ]))
    }
}
