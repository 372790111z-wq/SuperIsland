import Foundation

/// Recovery is complete only after the selected owner's AX operation objects
/// return. A captured/retained WindowServer surface alone must keep retrying.
enum WindowCommandTabRecoveryPolicy {
    static let delays: [UInt64] = [60_000_000, 120_000_000, 220_000_000]

    static func ownersNeedingRecovery<Window>(
        windows: [Window], owners: Set<Int32>,
        owner: (Window) -> Int32, hasOperation: (Window) -> Bool
    ) -> Set<Int32> {
        Set(owners.filter { pid in
            let owned = windows.filter { owner($0) == pid }
            return owned.isEmpty || owned.contains { !hasOperation($0) }
        })
    }

    private struct Target: Hashable {
        let owner: Int32
        let windowID: UInt32
    }

    /// A healthy sibling is neither progress nor permission to replace the
    /// entire owner's list. Only an exact missing target may be upgraded.
    static func restoringMissingWindows<Window>(
        current: [Window],
        refreshed: [Window],
        requestedOwners: Set<Int32>,
        owner: (Window) -> Int32,
        windowID: (Window) -> UInt32?,
        hasOperation: (Window) -> Bool
    ) -> [Window]? {
        func target(_ window: Window) -> Target? {
            guard let id = windowID(window), id > 0 else { return nil }
            return Target(owner: owner(window), windowID: id)
        }
        var byTarget: [Target: Window] = [:]
        for window in refreshed where requestedOwners.contains(owner(window)) {
            guard let key = target(window) else { continue }
            guard byTarget[key] == nil else { return nil }
            byTarget[key] = window
        }
        var madeProgress = false
        var result = current.map { window in
            guard !hasOperation(window), requestedOwners.contains(owner(window)),
                  let key = target(window), let replacement = byTarget[key],
                  hasOperation(replacement) else { return window }
            madeProgress = true
            return replacement
        }
        // A genuinely empty owner has no target IDs to restore yet. Admit its
        // validated fresh list once an actual operation arrives; retained
        // siblings remain noninteractive and stay in the finite retry set.
        let emptyOwners = requestedOwners.subtracting(current.map(owner))
        let discoveredOwners = Set(byTarget.values.filter(hasOperation).map(owner))
            .intersection(emptyOwners)
        for window in refreshed where discoveredOwners.contains(owner(window)) && target(window) != nil {
            result.append(window)
            madeProgress = true
        }
        return madeProgress ? result : nil
    }
}

/// A display policy for the two explicitly authorized WeChat installations.
/// It is separate from native tile identity and must not be used by Dock.
enum WindowCommandTabSharingPolicy {
    struct Application: Equatable, Sendable {
        let processID: Int32
        /// The caller supplies the current, canonical bundle path. No path
        /// prefix, basename, bundle-ID prefix, or localized-name inference.
        let bundlePath: String?
        let bundleIdentifier: String?
    }

    enum Installation: Int, CaseIterable, Sendable {
        case primary
        case secondary

        var bundlePath: String {
            switch self {
            case .primary: return "/Applications/WeChat.app"
            case .secondary: return "/Applications/WeChat-Work2.app"
            }
        }

        var bundleIdentifier: String {
            switch self {
            case .primary: return "com.tencent.xinWeChat"
            case .secondary: return "com.tencent.xinWeChat.work2"
            }
        }

        var label: String {
            switch self {
            case .primary: return "主微信"
            case .secondary: return "双开微信"
            }
        }
    }

    enum SelectionEvidence: Equatable {
        /// Only after the existing resolver has validated a consistent strong
        /// PID/URL/path identity. A conflicting or unmatched strong value must
        /// never be turned into this case by a later name match.
        case resolvedIdentity
        /// The caller has verified the selected element itself is AXButton.
        /// Title is its direct AXTitle, not a label gathered from an ancestor.
        /// A failed/truncated identity or children read is not a complete leaf.
        case weakSelectedButton(
            title: String, isLeaf: Bool, searchComplete: Bool, hasStrongIdentity: Bool
        )
        case unresolvedOrConflicting
    }

    struct Member: Equatable, Sendable {
        let application: Application
        let installation: Installation
        var label: String { installation.label }
    }

    struct Group: Equatable, Sendable {
        let members: [Member]

        fileprivate init(members: [Member]) { self.members = members }

        var processIDs: [Int32] { members.map { $0.application.processID } }

        func label(for processID: Int32) -> String? {
            members.first { $0.application.processID == processID }?.label
        }
    }

    /// Exact root and bundle ID must agree. In particular, WeChatAppEx and
    /// other nested bundles cannot become an independent installation here.
    static func installation(for application: Application) -> Installation? {
        guard application.processID > 0 else { return nil }
        return Installation.allCases.first {
            application.bundlePath == $0.bundlePath
                && application.bundleIdentifier == $0.bundleIdentifier
        }
    }

    /// `selected` is the full, unfiltered set matching this selection scope;
    /// filtering unknown matches first would hide third-party same-name apps.
    /// `running` is one current process snapshot, not a previously cached group.
    static func sharedWeChatGroup(
        selected: [Application],
        running: [Application],
        evidence: SelectionEvidence
    ) -> Group? {
        guard !selected.isEmpty,
              let runningByPID = uniqueApplications(running),
              let selectedByPID = uniqueApplications(selected),
              selectedByPID.values.allSatisfy({
                  runningByPID[$0.processID] == $0
              }) else { return nil }

        let members = runningByPID.values.compactMap { application -> Member? in
            guard let installation = installation(for: application) else { return nil }
            return Member(application: application, installation: installation)
        }.sorted {
            if $0.installation != $1.installation {
                return $0.installation.rawValue < $1.installation.rawValue
            }
            return $0.application.processID < $1.application.processID
        }
        guard Set(members.map(\.installation)) == Set(Installation.allCases) else { return nil }

        switch evidence {
        case .resolvedIdentity:
            // Several live processes at the same known installation are fine.
            // Strong evidence spanning distinct installations is a conflict.
            guard selectedByPID.values.allSatisfy({ installation(for: $0) != nil }),
                  Set(selectedByPID.values.compactMap { installation(for: $0) }).count == 1 else {
                return nil
            }
        case let .weakSelectedButton(title, isLeaf, searchComplete, hasStrongIdentity):
            let selectedRoots = selectedByPID.values.filter { installation(for: $0) != nil }
            guard (title == "微信" || title == "WeChat"),
                  isLeaf, searchComplete, !hasStrongIdentity,
                  Set(selectedRoots.map(\.processID)) == Set(members.map { $0.application.processID }),
                  selectedByPID.values.allSatisfy({ application in
                      installation(for: application) != nil
                          || isKnownNestedAppEx(application, rootMembers: members)
                  }) else {
                return nil
            }
        case .unresolvedOrConflicting:
            return nil
        }
        return Group(members: members)
    }

    /// AppEx can become a regular, same-name application while its root is
    /// running. Its exact bundle explains an extra weak match, but supplies
    /// neither an installation nor a window/action owner to the shared group.
    private static func isKnownNestedAppEx(_ application: Application, rootMembers: [Member]) -> Bool {
        guard application.processID > 0,
              application.bundleIdentifier == "com.tencent.flue.WeChatAppEx" else { return false }
        return rootMembers.contains {
            application.bundlePath == $0.installation.bundlePath + "/Contents/MacOS/WeChatAppEx.app"
        }
    }

    enum RequestedAction {
        case commandRelease
        case closeWindow
        case quitApplication
    }

    enum CommitPolicy: Equatable {
        /// Let the native switcher commit its selected application unchanged.
        case nativeOnly
        /// Intent only: the caller must still validate the process lifetime,
        /// exact window and AX ownership, and coordinate the native commit.
        case exactWindowOwner(processID: Int32)
        case unavailable
    }

    /// Pass an owner only after a concrete card was explicitly selected by
    /// the existing pointer/keyboard path. A default highlighted index is not
    /// a selection, and the first member is never an operation target.
    static func commitPolicy(
        for action: RequestedAction,
        group: Group,
        explicitlySelectedOwner: Application?
    ) -> CommitPolicy {
        guard let owner = explicitlySelectedOwner else {
            switch action {
            case .commandRelease: return .nativeOnly
            case .closeWindow, .quitApplication: return .unavailable
            }
        }
        guard group.members.contains(where: { $0.application == owner }) else { return .unavailable }
        return .exactWindowOwner(processID: owner.processID)
    }

    private static func uniqueApplications(_ applications: [Application]) -> [Int32: Application]? {
        var result: [Int32: Application] = [:]
        for application in applications {
            guard application.processID > 0 else { return nil }
            if let existing = result[application.processID], existing != application { return nil }
            result[application.processID] = application
        }
        return result
    }
}
