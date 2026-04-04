import SwiftUI

/// Global status bar at the bottom of the window.
/// Spec: "閃 42.3K saved (72%) | $2.14 saved | 2 panes | 1h 03m"
struct StatusBarView: View {
    let workspace: WorkspaceModel
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text("閃")
                Text("\(workspace.formattedTotalSavings) saved")
                    .fontWeight(.medium)
                Text("(\(String(format: "%.0f", workspace.globalSavingsPercent))%)")
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Text(workspace.estimatedCostSaved)
                .foregroundStyle(.green)

            Divider().frame(height: 12)

            Text("\(workspace.panes.count) pane\(workspace.panes.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)

            Divider().frame(height: 12)

            Text(formattedDuration)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .onReceive(timer) { tick in
            now = tick
        }
    }

    /// Live-updating session duration driven by the timer.
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
