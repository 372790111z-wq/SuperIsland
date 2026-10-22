import Foundation

/// AX geometry can settle before WindowServer assigns a moved window to its
/// destination Space. Keep that separate from the AX fullscreen flag.
struct WindowFullScreenSpaceSnapshot {
    let spaceID: UInt64
    let currentSpaceID: UInt64
    let spaceType: Int
    let displayIdentifier: String
    let isSharedDisplaySpace: Bool

    func matches(fullScreen: Bool, displayIdentifier expectedDisplay: String?) -> Bool {
        guard spaceType == (fullScreen ? 4 : 0) else { return false }
        // Preparing a menu command requires the active windowed desktop.
        // A completed fullscreen window may legitimately be on a Space the
        // user has since left; do not undo it merely because it is inactive.
        guard fullScreen || spaceID == currentSpaceID else { return false }
        guard let expectedDisplay else { return true }
        return isSharedDisplaySpace || displayIdentifier.caseInsensitiveCompare(expectedDisplay) == .orderedSame
    }

    static func parse(displays: [[String: Any]], windowSpaces: Set<UInt64>) -> Self? {
        guard windowSpaces.count == 1, let windowSpace = windowSpaces.first,
              windowSpace > 0, !displays.isEmpty, displays.count <= 32 else { return nil }
        func identifier(_ space: [String: Any]) -> UInt64? {
            for key in ["ManagedSpaceID", "id64", "id"] {
                if let number = space[key] as? NSNumber, number.int64Value > 0 { return number.uint64Value }
            }
            return nil
        }
        var matches: [Self] = []
        for display in displays {
            guard let name = display["Display Identifier"] as? String, !name.isEmpty,
                  let current = display["Current Space"] as? [String: Any], let currentID = identifier(current),
                  let spaces = display["Spaces"] as? [[String: Any]], spaces.count <= 512 else { return nil }
            for space in spaces where identifier(space) == windowSpace {
                guard let type = space["type"] as? NSNumber else { return nil }
                matches.append(.init(spaceID: windowSpace, currentSpaceID: currentID,
                                     spaceType: type.intValue, displayIdentifier: name,
                                     isSharedDisplaySpace: displays.count == 1 && name == "Main"))
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
