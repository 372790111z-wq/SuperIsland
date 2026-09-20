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
