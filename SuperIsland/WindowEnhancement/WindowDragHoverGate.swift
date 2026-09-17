import Foundation

/// Prevents delayed notch hover work from running during, or immediately after,
/// a window drag. A release over the notch requires a fresh pointer entry.
struct WindowDragHoverGate {
    private(set) var generation: UInt64 = 0
    private(set) var isDragging = false
    private(set) var isPointerInside = false
    private(set) var requiresPointerExit = false

    var isSuppressed: Bool { isDragging || requiresPointerExit }

    /// A held pointer can reach the notch before a top-clamped window moves.
    /// Suppress only hover; file-drop and explicit click paths remain separate.
    mutating func suppressUntilPointerExit() {
        generation &+= 1
        isPointerInside = true
        requiresPointerExit = true
    }

    @discardableResult
    mutating func setDragging(_ dragging: Bool) -> Bool {
        guard isDragging != dragging else { return false }
        generation &+= 1
        isDragging = dragging
        requiresPointerExit = dragging ? false : isPointerInside
        return true
    }

    @discardableResult
    mutating func recordHover(_ inside: Bool) -> Bool {
        isPointerInside = inside
        if !inside {
            requiresPointerExit = false
            generation &+= 1
        }
        return !isSuppressed
    }

    func permitsActivation(generation token: UInt64) -> Bool {
        token == generation && !isSuppressed
    }
}

/// Recovers a drag whose mouse-up callback was missed without imposing a
/// duration limit on a real drag. Brief button-state gaps do not end a drag.
struct WindowDragReleaseRecovery {
    let releaseGraceInterval: TimeInterval
    private var firstReleasedAt: TimeInterval?

    init(releaseGraceInterval: TimeInterval = 0.3) {
        self.releaseGraceInterval = releaseGraceInterval
    }

    mutating func shouldCancel(buttonIsDown: Bool, now: TimeInterval) -> Bool {
        if buttonIsDown {
            reset()
            return false
        }
        guard let firstReleasedAt else {
            firstReleasedAt = now
            return false
        }
        return now - firstReleasedAt >= releaseGraceInterval
    }

    mutating func reset() {
        firstReleasedAt = nil
    }
}
