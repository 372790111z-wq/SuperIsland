import SwiftUI

@main
struct SuperIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppState.shared)
        }
        .commands {
            // Keep the Settings scene only as the required SwiftUI app scene,
            // but route the system Settings command to the single AppKit-owned
            // resizable window. Otherwise macOS creates a second content-sized
            // Settings window that can collapse to a tiny, non-resizable panel.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    DispatchQueue.main.async {
                        AppDelegate.showSettingsWindow()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
