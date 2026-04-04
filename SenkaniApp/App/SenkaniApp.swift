import SwiftUI
import Core

struct SenkaniGUI: App {
    init() {
        do {
            try AutoRegistration.registerIfNeeded()
            try AutoRegistration.installHooksIfNeeded()
        } catch {
            // Non-fatal — log and continue. The app works without auto-registration.
            FileHandle.standardError.write(Data("[senkani] Auto-registration failed: \(error.localizedDescription)\n".utf8))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
    }
}
