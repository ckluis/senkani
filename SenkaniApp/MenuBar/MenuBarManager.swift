import SwiftUI
import Core
import MCPServer

/// View model driving the menu bar extra's content.
/// Polls SessionDatabase.totalStats() on a timer so the menu always shows fresh numbers.
@MainActor @Observable
final class MenuBarManager {
    private(set) var stats = LifetimeStats(
        totalSessions: 0, totalCommands: 0,
        totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0
    )
    private(set) var socketServerRunning = false
    private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    // Budget tracking
    private(set) var budgetConfig = BudgetConfig()
    private(set) var todayCostCents: Int = 0
    private(set) var dailyLimitCents: Int? = nil

    var hasBudget: Bool {
        budgetConfig.dailyLimitCents != nil || budgetConfig.weeklyLimitCents != nil || budgetConfig.perSessionLimitCents != nil
    }

    var budgetText: String {
        guard hasBudget else { return "" }
        let spent = String(format: "$%.2f", Double(todayCostCents) / 100.0)
        if let limit = budgetConfig.dailyLimitCents {
            let limitStr = String(format: "$%.2f", Double(limit) / 100.0)
            return "Budget: \(spent) / \(limitStr) today"
        }
        return "Budget: \(spent) today"
    }

    /// Ratio of today's spend to daily limit (0...1+). Returns nil if no daily limit.
    var budgetRatio: Double? {
        guard let limit = budgetConfig.dailyLimitCents, limit > 0 else { return nil }
        return Double(todayCostCents) / Double(limit)
    }

    init() {
        refresh()
        // Refresh every 5 seconds so the menu stays reasonably current.
        // Task uses [weak self] so it naturally stops when the object deallocates.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
    }

    func refresh() {
        stats = SessionDatabase.shared.totalStats()
        launchAtLoginEnabled = LaunchAtLogin.isEnabled

        // Refresh budget state
        budgetConfig = BudgetConfig.load()
        todayCostCents = SessionDatabase.shared.costForToday()
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

            if manager.hasBudget {
                Divider()

                HStack(spacing: 4) {
                    Circle()
                        .fill(budgetColor)
                        .frame(width: 6, height: 6)
                    Text(manager.budgetText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(budgetColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

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

    private var budgetColor: Color {
        guard let ratio = manager.budgetRatio else { return .secondary }
        if ratio >= 0.8 { return .red }
        if ratio >= 0.5 { return .yellow }
        return .green
    }

    private func openMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
