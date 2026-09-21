import SwiftUI

/// A drag can move between the outer island and its panes, or between
/// displays. Each destination owns a distinct ID in the shared presentation.
struct ShelfDropTargetState {
    private(set) var targets: Set<UUID> = []
    private(set) var generation: UInt64 = 0
    var isActive: Bool { !targets.isEmpty }

    mutating func setTarget(_ id: UUID, inside: Bool) {
        let changed = inside ? targets.insert(id).inserted : targets.remove(id) != nil
        if changed { generation &+= 1 }
    }

    mutating func completeDrop() {
        targets.removeAll()
        generation &+= 1
    }

    func canEnd(generation token: UInt64) -> Bool {
        token == generation && !isActive
    }
}

enum ShelfDropDestination: String {
    case surface, tray, airDrop, zip

    /// Once the three explicit actions are visible, their parent must not
    /// reinterpret a refused ZIP/share drop as a successful staging drop.
    func canReceive(shelfPanesVisible: Bool) -> Bool {
        self != .surface || !shelfPanesVisible
    }
}

enum ShelfLayoutMetrics {
    static let paneWidth: CGFloat = 142
    static let paneSpacing: CGFloat = 12
    static let preferredContentWidth = Constants.fullExpandedSize.width + paneWidth + paneSpacing

    static func contentWidth(screenWidth: CGFloat, windowOverhead: CGFloat) -> CGFloat {
        guard screenWidth > 0 else { return preferredContentWidth }
        return min(preferredContentWidth, max(0, screenWidth - windowOverhead - 24))
    }

    static func sidePaneWidth(contentWidth: CGFloat) -> CGFloat {
        // The container and full-expanded content contribute 80 pt padding.
        // Preserve both old pane widths on normal displays; leave a usable
        // tray and shrink the side panes only on small displays.
        let innerWidth = max(0, contentWidth - 80)
        let trayWidth = min(240, innerWidth * 0.56)
        return min(paneWidth, max(0, (innerWidth - trayWidth - paneSpacing * 2) / 2))
    }
}

/// SwiftUI's own-app drag does not pass through the external Finder monitor.
/// Keep its presentation hold alive between the source tile and a destination.
/// This polls physical state only during that drag, without injecting events.
@MainActor
final class ShelfInternalDragSession {
    static let shared = ShelfInternalDragSession()
    private weak var appState: AppState?
    private var targetID: UUID?
    private var inputGeneration: UInt64 = 0
    private var timer: Timer?
    private let isDragging: () -> Bool

    init(isDragging: @escaping () -> Bool = {
        CGEventSource.buttonState(.combinedSessionState, button: .left) &&
            !CGEventSource.keyState(.combinedSessionState, key: 53)
    }) {
        self.isDragging = isDragging
    }

    func begin(appState: AppState) {
        end()
        guard appState.shelfEnabled,
              appState.canHandleIslandInput(generation: appState.islandInputGeneration),
              isDragging() else { return }
        self.appState = appState
        inputGeneration = appState.islandInputGeneration
        let id = UUID()
        targetID = id
        appState.setShelfDropTarget(id, inside: true)
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func poll() {
        guard let appState, targetID != nil, isDragging(), appState.shelfEnabled,
              appState.isShelfDragActive,
              appState.canHandleIslandInput(generation: inputGeneration) else {
            end()
            return
        }
    }

    func end() {
        timer?.invalidate()
        timer = nil
        if let targetID { appState?.setShelfDropTarget(targetID, inside: false) }
        targetID = nil
        appState = nil
    }

    deinit { timer?.invalidate() }
}

extension View {
    func shelfDropTarget(
        _ destination: ShelfDropDestination,
        isTargeted: Binding<Bool>,
        enabled: Bool = true,
        perform: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        modifier(ShelfDropTargetModifier(
            destination: destination, isTargeted: isTargeted,
            enabled: enabled, perform: perform
        ))
    }
}

private struct ShelfDropTargetModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var targetID = UUID()
    let destination: ShelfDropDestination
    @Binding var isTargeted: Bool
    let enabled: Bool
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        content
            .onDrop(of: ShelfStore.acceptedDropTypes, delegate: ShelfDropDelegate(
                appState: appState, targetID: targetID, destination: destination,
                isTargeted: $isTargeted, enabled: enabled,
                inputGeneration: appState.islandInputGeneration, perform: perform
            ))
            .onAppear {
                ShelfDropDiagnostics.record("target.appear", destination: destination.rawValue,
                                            values: ["enabled": enabled ? 1 : 0])
            }
            .onDisappear {
                ShelfDropDiagnostics.record("target.disappear", destination: destination.rawValue)
                appState.setShelfDropTarget(targetID, inside: false)
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled {
                    isTargeted = false
                    appState.setShelfDropTarget(targetID, inside: false)
                }
            }
    }
}

private struct ShelfDropDelegate: DropDelegate {
    let appState: AppState
    let targetID: UUID
    let destination: ShelfDropDestination
    @Binding var isTargeted: Bool
    let enabled: Bool
    let inputGeneration: UInt64
    let perform: ([NSItemProvider]) -> Bool

    private var canReceive: Bool {
        enabled && appState.shelfEnabled &&
            destination.canReceive(shelfPanesVisible: appState.isShelfPanesVisible) &&
            appState.canHandleIslandInput(generation: inputGeneration)
    }

    func validateDrop(info: DropInfo) -> Bool {
        let permitted = canReceive
        let accepted = permitted && info.hasItemsConforming(to: ShelfStore.acceptedDropTypes)
        ShelfDropDiagnostics.record("validate", destination: destination.rawValue, values: [
            "permitted": permitted ? 1 : 0, "accepted": accepted ? 1 : 0,
            "enabled": enabled ? 1 : 0, "shelf": appState.shelfEnabled ? 1 : 0,
            "generation": Int64(clamping: inputGeneration),
            "currentGeneration": Int64(clamping: appState.islandInputGeneration)
        ])
        return accepted
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        isTargeted = true
        appState.setShelfDropTarget(targetID, inside: true)
        ShelfDropDiagnostics.record("entered", destination: destination.rawValue)
        NSLog("[ShelfDrop] target=%@ enter", destination.rawValue)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Staging and sharing leave the Finder source in place.
        let permitted = canReceive
        ShelfDropDiagnostics.record("updated", destination: destination.rawValue,
                                    values: ["copy": permitted ? 1 : 0])
        return DropProposal(operation: permitted ? .copy : .cancel)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        appState.setShelfDropTarget(targetID, inside: false)
        ShelfDropDiagnostics.record("exited", destination: destination.rawValue)
        NSLog("[ShelfDrop] target=%@ exit", destination.rawValue)
    }

    func performDrop(info: DropInfo) -> Bool {
        ShelfDropDiagnostics.record("perform.begin", destination: destination.rawValue)
        guard validateDrop(info: info) else {
            isTargeted = false
            appState.setShelfDropTarget(targetID, inside: false)
            ShelfDropDiagnostics.record("perform.rejected", destination: destination.rawValue)
            NSLog("[ShelfDrop] target=%@ rejected", destination.rawValue)
            return false
        }
        let providers = info.itemProviders(for: ShelfStore.acceptedDropTypes)
        ShelfDropDiagnostics.record("perform.providers", destination: destination.rawValue,
                                    values: ["count": Int64(providers.count)])
        let accepted = perform(providers)
        isTargeted = false
        appState.completeShelfDropTargets()
        ShelfDropDiagnostics.record("perform.return", destination: destination.rawValue,
                                    values: ["accepted": accepted ? 1 : 0])
        NSLog("[ShelfDrop] target=%@ drop providers=%ld accepted=%d",
              destination.rawValue, providers.count, accepted)
        return accepted
    }
}
