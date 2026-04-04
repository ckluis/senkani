import SwiftUI
import Core
import MCPServer

/// View model driving the menu bar extra's content.
/// Polls SessionDatabase.totalStats() on a timer so the menu always shows fresh numbers.
@Observable
final class MenuBarManager {
    private(set) var stats = LifetimeStats(
        totalSessions: 0, totalCommands: 0,
        totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0
    )
    private(set) var socketServerRunning = false
    private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    private var refreshTimer: Timer?

    init() {
        refresh()
        // Refresh every 5 seconds so the menu stays reasonably current.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        stats = SessionDatabase.shared.totalStats()
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    // MARK: - Formatted accessors

    var formattedSavings: String {
        let bytes = stats.totalSavedBytes
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    var savingsPercent: Double {
        guard stats.totalRawBytes > 0 else { return 0 }
        return Double(stats.totalSavedBytes) / Double(stats.totalRawBytes) * 100
    }

    var formattedCostSaved: String {
        let dollars = Double(stats.totalCostSavedCents) / 100.0
        return String(format: "$%.2f", dollars)
    }

    // MARK: - Actions

    func toggleSocketServer() {
        if socketServerRunning {
            SocketServerManager.shared.stop()
            socketServerRunning = false
        } else {
            SocketServerManager.shared.start()
            socketServerRunning = true
        }
    }

    func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.toggle()
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        } catch {
            FileHandle.standardError.write(
                Data("[senkani] Launch at login toggle failed: \(error.localizedDescription)\n".utf8))
        }
    }
}

/// SwiftUI view for the MenuBarExtra content.
struct MenuBarContentView: View {
    @Bindable var manager: MenuBarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\u{9583} \(manager.formattedSavings) saved (\(String(format: "%.0f", manager.savingsPercent))%)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            Text("Sessions: \(manager.stats.totalSessions) | Cost Saved: \(manager.formattedCostSaved)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            Button("Open Senkani") {
                openMainWindow()
            }
            .keyboardShortcut("o")

            Button(manager.socketServerRunning ? "Stop MCP Server" : "Start MCP Server") {
                manager.toggleSocketServer()
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { manager.launchAtLoginEnabled },
                set: { _ in manager.toggleLaunchAtLogin() }
            ))

            Divider()

            Button("Quit Senkani") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func openMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
