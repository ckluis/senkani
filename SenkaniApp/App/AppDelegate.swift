import AppKit

/// Supplements ContentView.onDisappear for quit paths where SwiftUI view
/// teardown may lag behind app termination (e.g. Cmd+Q on macOS).
/// Primary cleanup (sessions.stopAll, hook unregistration) lives in
/// ContentView.onDisappear — this is belt-and-suspenders only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // No-op: cleanup is handled by ContentView.onDisappear → sessions.stopAll()
        // This class exists so @NSApplicationDelegateAdaptor compiles and the
        // applicationWillTerminate hook is available for future use.
    }
}
