import SwiftUI

/// Dense 25px status bar at the bottom of the window.
/// Left: focused pane type + title. Right: global savings, cost, session duration.
struct StatusBarView: View {
    let workspace: WorkspaceModel
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            // Left: focused pane context
            if let pane = activePaneModel {
                HStack(spacing: 5) {
                    Circle()
                        .fill(SenkaniTheme.accentColor(for: pane.paneType))
                        .frame(width: 5, height: 5)

                    Image(systemName: SenkaniTheme.iconName(for: pane.paneType))
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.accentColor(for: pane.paneType))

                    Text(pane.title)
                        .foregroundStyle(SenkaniTheme.textPrimary)
                        .lineLimit(1)
                }
            } else {
                Text("No focus")
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            Spacer()

            // Right: global metrics
            HStack(spacing: 0) {
                Text(workspace.formattedTotalSavings)
                    .foregroundStyle(SenkaniTheme.savingsGreen)

                Text(" saved")
                    .foregroundStyle(SenkaniTheme.textTertiary)

                statusSeparator

                Text(workspace.estimatedCostSaved)
                    .foregroundStyle(SenkaniTheme.textSecondary)

                statusSeparator

                Text("\(workspace.panes.count)")
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Text(" pane\(workspace.panes.count == 1 ? "" : "s")")
                    .foregroundStyle(SenkaniTheme.textTertiary)

                statusSeparator

                Text(formattedDuration)
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: SenkaniTheme.statusBarHeight)
        .background(SenkaniTheme.statusBarBackground)
        .onReceive(timer) { tick in
            now = tick
        }
    }

    private var statusSeparator: some View {
        Text("  |  ")
            .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
    }

    private var activePaneModel: PaneModel? {
        guard let id = workspace.activePaneID else { return nil }
        return workspace.panes.first { $0.id == id }
    }

    private var formattedDuration: String {
        let elapsed = now.timeIntervalSince(workspace.sessionStart)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        }
        return "\(minutes)m \(String(format: "%02d", seconds))s"
    }
}
