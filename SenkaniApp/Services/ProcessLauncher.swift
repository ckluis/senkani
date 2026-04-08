import Foundation

/// Manages the lifecycle of a pane's session resources.
/// Starts ClaudeSessionWatcher for terminal panes, handles cleanup on stop.
/// Metrics are now DB-driven via MetricsRefresher (no more JSONL file watchers).
final class PaneSession: @unchecked Sendable {
    let pane: PaneModel

    init(pane: PaneModel) {
        self.pane = pane
    }

    func start() {
        // Start Claude session watcher for terminal panes (tracks exact token usage)
        if pane.paneType == .terminal {
            let watcher = ClaudeSessionWatcher(projectRoot: pane.workingDirectory, paneId: pane.id)
            watcher.start()
            pane.claudeSessionWatcher = watcher
        }
    }

    func stop() {
        // Stop Claude session watcher
        pane.claudeSessionWatcher?.stop()
        pane.claudeSessionWatcher = nil
        // Clean up metrics file and per-project MCP config
        try? FileManager.default.removeItem(atPath: pane.metricsFilePath)
        pane.cleanupMCPConfig()
    }

    deinit {
        stop()
    }
}

/// Registry of active pane sessions. Manages session lifecycle.
@Observable
final class SessionRegistry {
    private var sessions: [UUID: PaneSession] = [:]

    func startSession(for pane: PaneModel) {
        let session = PaneSession(pane: pane)
        sessions[pane.id] = session
        session.start()
    }

    func stopSession(for paneID: UUID) {
        sessions[paneID]?.stop()
        sessions.removeValue(forKey: paneID)
    }

    func stopAll() {
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
    }
}
