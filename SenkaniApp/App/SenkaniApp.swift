import SwiftUI
import Core

struct SenkaniGUI: App {
    @State private var menuBarManager = MenuBarManager()

    init() {
        do {
            try AutoRegistration.registerIfNeeded()
            try AutoRegistration.installHooksIfNeeded()
        } catch {
            // Non-fatal -- log and continue. The app works without auto-registration.
            FileHandle.standardError.write(Data("[senkani] Auto-registration failed: \(error.localizedDescription)\n".utf8))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)

        MenuBarExtra("Senkani", systemImage: "bolt.circle") {
            MenuBarContentView(manager: menuBarManager)
        }
    }
}
