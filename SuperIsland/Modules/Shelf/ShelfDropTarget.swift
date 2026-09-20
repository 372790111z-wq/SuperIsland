import SwiftUI

/// A drag can move between the outer island and either pane, or between
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
    case surface, tray, airDrop
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
            .onDisappear {
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
            appState.canHandleIslandInput(generation: inputGeneration)
    }

    func validateDrop(info: DropInfo) -> Bool {
        canReceive && info.hasItemsConforming(to: ShelfStore.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        isTargeted = true
        appState.setShelfDropTarget(targetID, inside: true)
        NSLog("[ShelfDrop] target=%@ enter", destination.rawValue)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Staging and sharing leave the Finder source in place.
        DropProposal(operation: canReceive ? .copy : .cancel)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        appState.setShelfDropTarget(targetID, inside: false)
        NSLog("[ShelfDrop] target=%@ exit", destination.rawValue)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            isTargeted = false
            appState.setShelfDropTarget(targetID, inside: false)
            NSLog("[ShelfDrop] target=%@ rejected", destination.rawValue)
            return false
        }
        let providers = info.itemProviders(for: ShelfStore.acceptedDropTypes)
        let accepted = perform(providers)
        isTargeted = false
        appState.completeShelfDropTargets()
        NSLog("[ShelfDrop] target=%@ drop providers=%ld accepted=%d",
              destination.rawValue, providers.count, accepted)
        return accepted
    }
}
