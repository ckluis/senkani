import Foundation
import Core

/// Pure functions that assemble a `RenderFrame` from
/// `MonitorReadOnlyAPI` query results. Four regions, top-to-bottom:
///   1. Header bar — always contains the literal `READ-ONLY`.
///   2. Live tiles row — three tiles (`budget_burn`,
///      `validation_queue`, `repo_dirty_state`).
///   3. Panes table — one row per `MonitorProjectRow`.
///   4. Footer hints — keybinding preview (V.15a-2 wires the
///      bindings; V.15a-1 just renders the hint line).
///
/// No time-of-day stamps in the output — deterministic rendering is
/// a P1 acceptance criterion. Any timestamp the operator may want is
/// the responsibility of the caller's banner, not the dashboard.
public enum DashboardRender {
    public static let headerRegionId = "header"
    public static let liveTilesRegionId = "live_tiles"
    public static let panesTableRegionId = "panes_table"
    public static let footerRegionId = "footer"

    public static let readOnlyBadge = "READ-ONLY"
    public static let footerHint = "q quit · j/k nav · r refresh · / filter"

    /// Build a `RenderFrame` from the read-only API.
    public static func buildFrame(
        appName: String = "senkani monitor",
        appVersion: String,
        api: MonitorReadOnlyAPI
    ) throws -> RenderFrame {
        let snapshot = try api.fetchPaneSnapshot()
        let savings = try api.fetchFeatureSavings()
        let projects = try api.fetchProjectRows()

        let header = renderHeader(appName: appName, appVersion: appVersion)
        let tiles = renderLiveTiles(snapshot: snapshot)
        let table = renderPanesTable(projects: projects, savings: savings)
        let footer = renderFooter()

        return RenderFrame(regions: [header, tiles, table, footer])
    }

    // MARK: - Header

    static func renderHeader(appName: String, appVersion: String) -> Region {
        let line = "\(appName) v\(appVersion)  [\(readOnlyBadge)]"
        return Region(id: headerRegionId, lines: [line])
    }

    // MARK: - Live tiles row

    static func renderLiveTiles(snapshot: PaneRefreshCoordinator.Snapshot) -> Region {
        let budget = formatTile(label: "Budget Burn", state: snapshot.budgetBurn)
        let validation = formatTile(label: "Validation Queue", state: snapshot.validationQueue)
        let repoDirty = formatTile(label: "Repo Dirty", state: snapshot.repoDirtyState)
        let line = [budget, validation, repoDirty].joined(separator: "   ")
        return Region(id: liveTilesRegionId, lines: [line])
    }

    private static func formatTile(label: String, state: PaneRefreshState) -> String {
        let availability = state.contentAvailable ? "ok" : "—"
        let cacheLabel = "\(Int(state.cacheDuration))s"
        let notice = state.notice.map { " (\($0))" } ?? ""
        return "[\(label): \(availability) · cache \(cacheLabel)\(notice)]"
    }

    // MARK: - Panes table

    static func renderPanesTable(
        projects: [MonitorProjectRow],
        savings: [SessionDatabase.FeatureSavings]
    ) -> Region {
        var lines: [String] = []
        lines.append("Projects (\(projects.count))")
        lines.append("name           path                          today $  month $  save%  top opt          tokens/mo")
        if projects.isEmpty {
            lines.append("(no projects registered — pass --project / wire WorkspaceModel)")
        } else {
            for row in projects {
                lines.append(formatProjectRow(row))
            }
        }
        if !savings.isEmpty {
            lines.append("")
            lines.append("Feature savings (top \(min(savings.count, 5)))")
            for entry in savings.prefix(5) {
                lines.append("  \(entry.feature)  saved=\(entry.savedTokens)  events=\(entry.eventCount)")
            }
        }
        return Region(id: panesTableRegionId, lines: lines)
    }

    private static func formatProjectRow(_ row: MonitorProjectRow) -> String {
        let name = padRight(row.name, 14)
        let path = padRight(row.path, 30)
        let today = String(format: "%7.2f", row.todayCostSaved)
        let month = String(format: "%7.2f", row.monthCostSaved)
        let pct = String(format: "%5.1f", row.savingsPercent)
        let topOpt = padRight(row.topOptimization, 16)
        return "\(name) \(path) \(today)  \(month)  \(pct)  \(topOpt) \(row.savedTokensMonth)"
    }

    private static func padRight(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Footer

    static func renderFooter() -> Region {
        return Region(id: footerRegionId, lines: [footerHint])
    }
}
