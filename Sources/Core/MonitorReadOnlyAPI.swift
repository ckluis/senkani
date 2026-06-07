import Foundation

/// Read-only query surface for the `senkani monitor --tui` substrate.
///
/// `Sources/MonitorTUI/` imports this protocol and never references
/// `SessionDatabase` directly. The adapter's public surface is the
/// audit boundary: writes happen on the SessionDatabase the adapter
/// wraps, but nothing reachable through this protocol mutates state.
public protocol MonitorReadOnlyAPI: Sendable {
    func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot
    func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings]
    func fetchProjectRows() throws -> [MonitorProjectRow]
}

/// One row in the panes table of `senkani monitor --tui`. The GUI's
/// equivalent (`DashboardView.ProjectRow`) is `private` to the view
/// layer; this type ships the same shape as a public Core value
/// type the CLI / TUI / any read-only consumer can render.
public struct MonitorProjectRow: Sendable, Equatable {
    public let name: String
    public let path: String
    public let todayCostSaved: Double
    public let monthCostSaved: Double
    public let savingsPercent: Double
    public let topOptimization: String
    public let savedTokensMonth: Int

    public init(
        name: String,
        path: String,
        todayCostSaved: Double,
        monthCostSaved: Double,
        savingsPercent: Double,
        topOptimization: String,
        savedTokensMonth: Int
    ) {
        self.name = name
        self.path = path
        self.todayCostSaved = todayCostSaved
        self.monthCostSaved = monthCostSaved
        self.savingsPercent = savingsPercent
        self.topOptimization = topOptimization
        self.savedTokensMonth = savedTokensMonth
    }
}

/// Default `MonitorReadOnlyAPI` adapter. Reads pane refresh state
/// from `PaneRefreshStateStore`, feature savings from `SessionDatabase`,
/// and synthesizes project rows from a caller-supplied project list
/// (so the adapter does not need to crack open `WorkspaceModel`, which
/// is a SwiftUI surface). V.15a-1 substrate; V.15a-2 may wire a richer
/// project source.
public struct MonitorReadOnlyAdapter: MonitorReadOnlyAPI {
    public struct ProjectInput: Sendable {
        public let name: String
        public let path: String
        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public let database: SessionDatabase
    public let paneStateStore: PaneRefreshStateStore?
    public let paneStateProjectRoot: String
    public let projects: [ProjectInput]

    public init(
        database: SessionDatabase,
        paneStateStore: PaneRefreshStateStore? = nil,
        paneStateProjectRoot: String = "",
        projects: [ProjectInput] = []
    ) {
        self.database = database
        self.paneStateStore = paneStateStore
        self.paneStateProjectRoot = paneStateProjectRoot
        self.projects = projects
    }

    public func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot {
        let states = paneStateStore?.latestStates(projectRoot: paneStateProjectRoot) ?? [:]
        let budget = states[PaneRefreshCoordinator.budgetBurnTileId]
            ?? PaneRefreshState(cacheType: .duration, cacheDuration: 30)
        let validation = states[PaneRefreshCoordinator.validationQueueTileId]
            ?? PaneRefreshState(cacheType: .duration, cacheDuration: 5)
        let repoDirty = states[PaneRefreshCoordinator.repoDirtyStateTileId]
            ?? PaneRefreshState(cacheType: .duration, cacheDuration: 10)
        return PaneRefreshCoordinator.Snapshot(
            budgetBurn: budget,
            validationQueue: validation,
            repoDirtyState: repoDirty
        )
    }

    public func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings] {
        return database.tokenStatsByFeatureAllProjects()
    }

    public func fetchProjectRows() throws -> [MonitorProjectRow] {
        let startOfMonth = Self.startOfCurrentMonth
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return projects.map { project in
            let normalized = URL(fileURLWithPath: project.path).standardized.path
            let monthStats = database.tokenStatsForProject(normalized, since: startOfMonth)
            let todayStats = database.tokenStatsForProject(normalized, since: startOfToday)
            let features = database.tokenStatsByFeature(projectRoot: normalized, since: startOfMonth)
            let topOpt = features.first?.feature ?? "-"
            let rawMonth = monthStats.inputTokens + monthStats.savedTokens
            let pct = rawMonth > 0
                ? Double(monthStats.savedTokens) / Double(rawMonth) * 100
                : 0
            return MonitorProjectRow(
                name: project.name,
                path: project.path,
                todayCostSaved: Double(todayStats.costCents) / 100.0,
                monthCostSaved: Double(monthStats.costCents) / 100.0,
                savingsPercent: pct,
                topOptimization: topOpt,
                savedTokensMonth: monthStats.savedTokens
            )
        }
        .sorted { $0.savedTokensMonth > $1.savedTokensMonth }
    }

    private static var startOfCurrentMonth: Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }
}
