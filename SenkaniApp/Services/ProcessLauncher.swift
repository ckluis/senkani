import Foundation

/// Manages the lifecycle of a pane's metrics watcher.
/// Created when a terminal pane starts, watches JSONL for live updates.
final class PaneSession: @unchecked Sendable {
    let pane: PaneModel
    private var watcher: MetricsWatcher?

    init(pane: PaneModel) {
        self.pane = pane
    }

    func start() {
        watcher = MetricsWatcher(path: pane.metricsFilePath, metrics: pane.metrics)
        watcher?.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        // Clean up metrics file
        try? FileManager.default.removeItem(atPath: pane.metricsFilePath)
    }

    deinit {
        stop()
    }
}

/// Registry of active pane sessions. Manages watcher lifecycle.
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
