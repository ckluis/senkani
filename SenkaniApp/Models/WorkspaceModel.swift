import Foundation

/// Manages the collection of panes in the workspace.
@Observable
final class WorkspaceModel {
    var panes: [PaneModel] = []
    var activePaneID: UUID?
    var sessionStart = Date()

    var activePaneIndex: Int? {
        guard let id = activePaneID else { return nil }
        return panes.firstIndex { $0.id == id }
    }

    func addPane(type: PaneType = .terminal, title: String = "Terminal", command: String = "/bin/zsh", previewFilePath: String = "") {
        let pane = PaneModel(title: title, paneType: type, shellCommand: command, previewFilePath: previewFilePath)
        panes.append(pane)
        activePaneID = pane.id
    }

    func removePane(id: UUID) {
        panes.removeAll { $0.id == id }
        if activePaneID == id {
            activePaneID = panes.last?.id
        }
    }

    func navigateToPane(index: Int) {
        guard index < panes.count else { return }
        activePaneID = panes[index].id
    }

    // MARK: - Global metrics

    var totalSavedBytes: Int {
        panes.reduce(0) { $0 + $1.metrics.savedBytes }
    }

    var totalRawBytes: Int {
        panes.reduce(0) { $0 + $1.metrics.totalRawBytes }
    }

    var globalSavingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(totalSavedBytes) / Double(totalRawBytes) * 100
    }

    var sessionDuration: String {
        let elapsed = Date().timeIntervalSince(sessionStart)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    var formattedTotalSavings: String {
        let bytes = totalSavedBytes
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    /// Estimated cost saved: tokens ≈ bytes/4, cost ≈ tokens/1M × $3.00
    var estimatedCostSaved: String {
        let tokens = Double(totalSavedBytes) / 4.0
        let cost = (tokens / 1_000_000) * 3.0
        return String(format: "$%.2f saved", cost)
    }
}
