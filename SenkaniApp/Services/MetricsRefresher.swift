import Foundation
import Core

/// Shared metrics store that both SidebarView and StatusBarView consume.
/// One timer, one set of DB queries, two consumers.
/// Replaces the old no-op MetricsRefresher stub.
@MainActor
@Observable
final class MetricsStore {
    static let shared = MetricsStore()

    /// Per-project token stats, keyed by normalized project path.
    var projectStats: [String: PaneTokenStats] = [:]

    /// Aggregate stats across all projects.
    var allStats: PaneTokenStats = .zero

    /// Session start time (for duration display).
    var sessionStart = Date()

    private var refreshTask: Task<Void, Never>?

    /// Start the 1-second refresh loop for the given projects.
    func start(projects: [ProjectModel]) {
        refreshTask?.cancel()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh(projects: projects)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Refresh stats from the database for all known projects.
    func refresh(projects: [ProjectModel]) {
        let db = SessionDatabase.shared

        for project in projects {
            let normalized = URL(fileURLWithPath: project.path).standardized.path
            let stats = db.tokenStatsForProject(normalized)
            projectStats[normalized] = stats
        }

        allStats = db.tokenStatsAllProjects()
    }

    /// Stop the refresh loop.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Get stats for a specific project path (normalized automatically).
    func stats(for projectPath: String) -> PaneTokenStats {
        let normalized = URL(fileURLWithPath: projectPath).standardized.path
        return projectStats[normalized] ?? .zero
    }
}
