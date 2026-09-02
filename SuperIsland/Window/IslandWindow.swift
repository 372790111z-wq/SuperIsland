import AppKit

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private static let showInScreenRecordingsDefaultsKey = "general.showInScreenRecordings"
    private static let requiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if QuitHotkeyGuard.shouldBlock(event) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    init(showOnAllSpaces: Bool) {
        let initialCompactSize = ScreenDetector.primaryScreen
            .flatMap(ScreenDetector.compactIslandMetrics(screen:))?
            .size ?? Constants.compactSize

        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: initialCompactSize.width,
                height: initialCompactSize.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        setShowOnAllSpaces(showOnAllSpaces)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false

        let shouldShowInRecordings = UserDefaults.standard.object(
            forKey: Self.showInScreenRecordingsDefaultsKey
        ) as? Bool ?? false
        setVisibleInScreenRecordings(shouldShowInRecordings)
    }

    func setVisibleInScreenRecordings(_ visible: Bool) {
        sharingType = visible ? .readOnly : .none
    }

    /// Keep the island eligible as an auxiliary full-screen panel without
    /// forcing it onto every regular Space when the user disables that
    /// setting. Replacing the option set also prevents stale Space behavior
    /// from surviving a settings toggle.
    func setShowOnAllSpaces(_ showOnAllSpaces: Bool) {
        var behavior = Self.requiredCollectionBehavior
        if showOnAllSpaces {
            behavior.insert(.canJoinAllSpaces)
        }
        if collectionBehavior != behavior {
            collectionBehavior = behavior
        }
    }
}
