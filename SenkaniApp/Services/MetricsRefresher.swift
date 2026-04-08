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
        // Cancel any existing loop
        refreshTask?.cancel()

        print("🚨🚨🚨 [METRICS-STORE] START called with \(projects.count) projects:")
        for p in projects {
            print("🚨 [METRICS-STORE]   project: \(p.name) path: \(p.path)")
        }

        refreshTask = Task { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                guard let self else {
                    print("💀 [METRICS-STORE] self is nil — task dying")
                    return
                }
                tickCount += 1
                self.refresh(projects: projects)

                // Print every tick for the first 5, then every 10th
                if tickCount <= 5 || tickCount % 10 == 0 {
                    print("🚨 [METRICS-STORE] tick #\(tickCount)")
                }

                try? await Task.sleep(for: .seconds(1))
            }
            print("💀 [METRICS-STORE] Task cancelled after \(tickCount) ticks")
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
