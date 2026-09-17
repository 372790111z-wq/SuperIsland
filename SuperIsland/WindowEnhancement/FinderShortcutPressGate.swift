/// Owns one physical key cycle and one Finder activation. A delayed Carbon
/// callback from a previous activation must never operate on the new selection.
struct FinderShortcutPressGate {
    struct Context: Equatable {
        let pid: Int32
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private(set) var context: Context?
    private(set) var generation: UInt64 = 0
    private(set) var requiresRelease = false

    mutating func configure(_ context: Context?, keyIsDown: Bool) {
        guard self.context != context else { return }
        invalidate()
        self.context = context
        requiresRelease = keyIsDown
    }

    mutating func invalidate() {
        generation &+= 1
        context = nil
        requiresRelease = false
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        context != nil && self.generation == generation
    }

    mutating func press(generation: UInt64) -> Bool {
        guard isCurrent(generation), !requiresRelease else { return false }
        requiresRelease = true
        return true
    }

    mutating func observeRelease(keyIsDown: Bool) {
        if !keyIsDown { requiresRelease = false }
    }
}

/// Uses the Carbon event clock for both checks. Claiming a press never renews
/// its deadline, and releasing a claimed press does not extend or cancel it.
struct FinderShortcutEventLifetime {
    static let maximumClaimAge = 0.100
    static let maximumDuration = 0.250
    private let eventTime: Double

    init?(eventTime: Double, now: Double) {
        guard eventTime.isFinite, now.isFinite, eventTime >= 0,
              now >= eventTime, now - eventTime <= Self.maximumClaimAge else { return nil }
        self.eventTime = eventTime
    }

    func isCurrent(now: Double) -> Bool {
        now.isFinite && now >= eventTime && now - eventTime < Self.maximumDuration
    }
}

/// Deduplicates Carbon events before they are queued onto the main actor.
/// A hotkey release invalidates pending work even if the next key cycle has
/// already started by the time that work is delivered.
struct FinderShortcutQueuedPressGate {
    private(set) var cycle: UInt64 = 0
    private var receivedPress = false
    mutating func enqueuePress() -> UInt64? {
        guard !receivedPress else { return nil }
        receivedPress = true
        return cycle
    }
    func isCurrent(_ ticket: UInt64) -> Bool { receivedPress && ticket == cycle }
    mutating func release() {
        cycle &+= 1
        receivedPress = false
    }
}

/// Only the hide/show toggle uses this gate; repeating layout shortcuts keep
/// their existing behavior. Entries belong to a live Carbon registration ID.
struct WindowVisibilityPressGate {
    private var pressedIDs: Set<UInt32> = []
    mutating func press(_ id: UInt32) -> Bool { pressedIDs.insert(id).inserted }
    mutating func release(_ id: UInt32) { pressedIDs.remove(id) }
    mutating func reset() { pressedIDs.removeAll() }
}
