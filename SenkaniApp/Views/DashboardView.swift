import SwiftUI
import Charts
import Core

/// Multi-project portfolio dashboard.
/// The "executive summary" of Senkani's value — total savings, project breakdown,
/// feature charts, and auto-generated insights.
struct DashboardView: View {
    var workspace: WorkspaceModel?

    @State private var now = Date()
    @State private var portfolioStats: PaneTokenStats = .zero
    @State private var projectRows: [ProjectRow] = []
    @State private var allTimeSeries: [MetricsDataPoint] = []
    @State private var featureBreakdown: [SessionDatabase.FeatureSavings] = []
    @State private var insights: [Insight] = []
    @State private var hoveredProjectID: UUID?

    // V.1 round 2 — three live tiles backed by the pane refresh scheduler +
    // bounded worker pool. Coordinator persists state per-tick so values
    // survive an app restart.
    @State private var liveTiles: PaneRefreshCoordinator.Snapshot?
    @State private var coordinator: PaneRefreshCoordinator?

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    // MARK: - Data Models

    private struct ProjectRow: Identifiable {
        let id: UUID
        let name: String
        let path: String
        let todayCostSaved: Double
        let monthCostSaved: Double
        let savingsPercent: Double
        let topOptimization: String
        let savedTokensMonth: Int
    }

    private struct Insight: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let color: Color
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    heroSavingsCard
                    summaryCards
                    liveTilesSection
                    projectBreakdownTable
                    chartsSection
                    insightsSection
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onReceive(timer) { _ in
            refreshData()
            tickLiveTiles()
        }
        .onAppear {
            refreshData()
            startLiveTiles()
        }
    }

    // MARK: - Live tiles (V.1 round 2)

    private var liveTilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Tiles")
                .font(.system(size: 13, weight: .semibold))

            if let snapshot = liveTiles {
                HStack(spacing: 12) {
                    liveTileCard(
                        title: "Budget Burn",
                        state: snapshot.budgetBurn,
                        valueText: snapshot.budgetBurn.contentAvailable
                            ? "30s cache" : "warming"
                    )
                    liveTileCard(
                        title: "Validation Queue",
                        state: snapshot.validationQueue,
                        valueText: snapshot.validationQueue.contentAvailable
                            ? "5s cache" : "warming"
                    )
                    liveTileCard(
                        title: "Repo Dirty",
                        state: snapshot.repoDirtyState,
                        valueText: snapshot.repoDirtyState.contentAvailable
                            ? "10s cache" : "warming"
                    )
                }
            } else {
                Text("Live tiles will populate after first tick")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func liveTileCard(title: String, state: PaneRefreshState, valueText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(valueText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.lastError != nil ? .red
                                 : (state.notice != nil ? .yellow : .primary))
            if let notice = state.notice {
                Text(notice)
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func startLiveTiles() {
        guard coordinator == nil,
              let project = workspace?.activeProject ?? workspace?.projects.first else { return }
        let projectRoot = project.path
        let db = SessionDatabase.shared
        let coord = PaneRefreshCoordinator(
            database: db,
            projectRoot: projectRoot,
            budgetBurnFetch: { _ in
                let stats = db.tokenStatsForProject(projectRoot)
                return stats.commandCount > 0 ? .success : .partial(notice: "no spend yet")
            },
            validationQueueFetch: { _ in .success },
            repoDirtyStateFetch: { _ in .success }
        )
        coord.rehydrate()
        coordinator = coord
        liveTiles = coord.snapshot()
    }

    private func tickLiveTiles() {
        guard let coord = coordinator else { return }
        Task { @MainActor in
            await coord.tick()
            self.liveTiles = coord.snapshot()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.system(size: 18, weight: .semibold))
                Text(monthYearLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(workspace?.projects.count ?? 0) projects")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Hero Card (Jobs: #1 thing user sees — TOTAL MONEY SAVED)

    private var heroSavingsCard: some View {
        VStack(spacing: 8) {
            Text("TOTAL SAVED")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(2)

            Text(formattedDollarsSaved)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.savingsGreen)

            Text(heroSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    .linearGradient(
                        colors: [SenkaniTheme.savingsGreen.opacity(0.08), Color(.controlBackgroundColor)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SenkaniTheme.savingsGreen.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            summaryCard(title: "Tokens Saved", value: formatTokens(portfolioStats.savedTokens),
                       subtitle: "\(savingsPercent)% reduction", color: .blue, icon: "arrow.down.right")
            summaryCard(title: "Active Projects", value: "\(workspace?.projects.count ?? 0)",
                       subtitle: "\(totalPanes) panes", color: .purple, icon: "folder")
            summaryCard(title: "Commands", value: "\(portfolioStats.commandCount)",
                       subtitle: "intercepted", color: .purple, icon: "terminal")
            summaryCard(title: "Avg Savings", value: "\(avgSavingsPercent)%",
                       subtitle: "across projects", color: SenkaniTheme.savingsGreen, icon: "chart.line.uptrend.xyaxis")
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Project Breakdown Table

    private var projectBreakdownTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Breakdown")
                .font(.system(size: 13, weight: .semibold))

            if projectRows.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("Project data will appear as commands are intercepted")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("Project")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Today").frame(width: 70, alignment: .trailing)
                    Text("Month").frame(width: 70, alignment: .trailing)
                    Text("Savings").frame(width: 60, alignment: .trailing)
                    Text("Top Opt").frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)

                ForEach(projectRows) { row in
                    projectTableRow(row)
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func projectTableRow(_ row: ProjectRow) -> some View {
        let isHovered = hoveredProjectID == row.id
        return HStack(spacing: 0) {
            Text(row.name)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "$%.2f", row.todayCostSaved))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SenkaniTheme.savingsGreen)
                .frame(width: 70, alignment: .trailing)

            Text(String(format: "$%.2f", row.monthCostSaved))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SenkaniTheme.savingsGreen)
                .frame(width: 70, alignment: .trailing)

            Text(String(format: "%.0f%%", row.savingsPercent))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(savingsColor(row.savingsPercent))
                .frame(width: 60, alignment: .trailing)

            Text(row.topOptimization.capitalized)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(featureBadgeColor(row.topOptimization).opacity(0.15))
                .clipShape(Capsule())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let ws = workspace {
                ws.activeProjectID = row.id
            }
        }
        .onHover { hovering in hoveredProjectID = hovering ? row.id : nil }
    }

    // MARK: - Charts

    private var chartsSection: some View {
        VStack(spacing: 16) {
            // Savings over time (line chart)
            VStack(alignment: .leading, spacing: 8) {
                Text("Savings Over Time")
                    .font(.system(size: 13, weight: .semibold))

                if allTimeSeries.isEmpty {
                    chartPlaceholder("Data will appear as commands are intercepted")
                } else {
                    Chart(allTimeSeries) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Saved", point.cumulativeSavedBytes)
                        )
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Saved", point.cumulativeSavedBytes)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [SenkaniTheme.savingsGreen.opacity(0.3), SenkaniTheme.savingsGreen.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(Int.self) {
                                    Text(formatBytes(bytes))
                                        .font(.system(size: 9, design: .monospaced))
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
            .padding(12)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Savings by feature (horizontal bar chart)
            VStack(alignment: .leading, spacing: 8) {
                Text("Savings by Feature")
                    .font(.system(size: 13, weight: .semibold))

                if featureBreakdown.isEmpty {
                    chartPlaceholder("Feature breakdown will appear after optimization events")
                } else {
                    Chart(featureBreakdown, id: \.feature) { feature in
                        BarMark(
                            x: .value("Saved", feature.savedTokens),
                            y: .value("Feature", feature.feature.capitalized)
                        )
                        .foregroundStyle(featureBadgeColor(feature.feature))
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let tokens = value.as(Int.self) {
                                    Text(formatTokens(tokens))
                                        .font(.system(size: 9, design: .monospaced))
                                }
                            }
                        }
                    }
                    .frame(height: max(120, CGFloat(featureBreakdown.count) * 32))
                }
            }
            .padding(12)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Insights")
                .font(.system(size: 13, weight: .semibold))

            if insights.isEmpty {
                Text("Insights will appear as cross-project patterns emerge")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(insights) { insight in
                    HStack(spacing: 8) {
                        Image(systemName: insight.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(insight.color)
                            .frame(width: 14)
                        Text(insight.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Chart Placeholder

    private func chartPlaceholder(_ message: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    // MARK: - Data Refresh

    private func refreshData() {
        let db = SessionDatabase.shared
        let projects = workspace?.projects ?? []
        let startOfMonth = Self.startOfCurrentMonth
        let startOfToday = Calendar.current.startOfDay(for: Date())

        portfolioStats = db.tokenStatsAllProjects()

        projectRows = projects.map { project in
            let normalized = URL(fileURLWithPath: project.path).standardized.path
            let monthStats = db.tokenStatsForProject(normalized, since: startOfMonth)
            let todayStats = db.tokenStatsForProject(normalized, since: startOfToday)
            let features = db.tokenStatsByFeature(projectRoot: normalized, since: startOfMonth)
            let topOpt = features.first?.feature ?? "-"
            let rawMonth = monthStats.inputTokens + monthStats.savedTokens
            let pct = rawMonth > 0 ? Double(monthStats.savedTokens) / Double(rawMonth) * 100 : 0

            return ProjectRow(
                id: project.id, name: project.name, path: project.path,
                todayCostSaved: Double(todayStats.costCents) / 100.0,
                monthCostSaved: Double(monthStats.costCents) / 100.0,
                savingsPercent: pct, topOptimization: topOpt,
                savedTokensMonth: monthStats.savedTokens
            )
        }
        .sorted { $0.savedTokensMonth > $1.savedTokensMonth }

        let series = db.savingsTimeSeriesAllProjects(since: startOfMonth)
        let stride = max(1, series.count / 200)
        allTimeSeries = series.enumerated()
            .filter { $0.offset % stride == 0 || $0.offset == series.count - 1 }
            .map { MetricsDataPoint(timestamp: $0.element.timestamp,
                                    cumulativeSavedBytes: $0.element.cumulativeSaved,
                                    cumulativeRawBytes: $0.element.cumulativeRaw) }

        featureBreakdown = db.tokenStatsByFeatureAllProjects(since: startOfMonth)
        insights = generateInsights()
    }

    // MARK: - Insights Generator

    private func generateInsights() -> [Insight] {
        var results: [Insight] = []
        guard !projectRows.isEmpty else { return results }

        if let top = projectRows.first, !top.topOptimization.isEmpty, top.topOptimization != "-" {
            results.append(Insight(icon: "star.fill",
                text: "\(top.name) benefits most from \(top.topOptimization.capitalized)",
                color: SenkaniTheme.savingsGreen))
        }

        if let topFeature = featureBreakdown.first {
            let total = featureBreakdown.reduce(0) { $0 + $1.savedTokens }
            let pct = total > 0 ? Int(Double(topFeature.savedTokens) / Double(total) * 100) : 0
            results.append(Insight(icon: "trophy.fill",
                text: "\(topFeature.feature.capitalized) saves the most tokens overall (\(pct)%)",
                color: .blue))
        }

        if let best = projectRows.max(by: { $0.savingsPercent < $1.savingsPercent }), best.savingsPercent > 0 {
            results.append(Insight(icon: "arrow.up.right",
                text: "\(best.name) has the highest savings rate at \(String(format: "%.0f", best.savingsPercent))%",
                color: SenkaniTheme.savingsGreen))
        }

        let dailySaved = projectRows.reduce(0.0) { $0 + $1.todayCostSaved }
        if dailySaved > 0.01 {
            results.append(Insight(icon: "calendar",
                text: "Saving \(String(format: "$%.2f", dailySaved)) today across all projects",
                color: .blue))
        }

        return results
    }

    // MARK: - Helpers

    private static var startOfCurrentMonth: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    }

    private var monthYearLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: Date())
    }

    private var formattedDollarsSaved: String {
        let dollars = ModelPricing.costSaved(bytes: portfolioStats.savedTokens * 4)
        if dollars >= 100 { return String(format: "$%.0f", dollars) }
        if dollars >= 10 { return String(format: "$%.1f", dollars) }
        return String(format: "$%.2f", dollars)
    }

    private var heroSubtitle: String {
        let count = workspace?.projects.count ?? 0
        if count == 0 { return "add a project to start tracking" }
        return "this month across \(count) project\(count == 1 ? "" : "s")"
    }

    private var savingsPercent: String {
        let raw = portfolioStats.inputTokens + portfolioStats.savedTokens
        guard raw > 0 else { return "0" }
        return String(format: "%.0f", Double(portfolioStats.savedTokens) / Double(raw) * 100)
    }

    private var avgSavingsPercent: String {
        guard !projectRows.isEmpty else { return "0" }
        let avg = projectRows.reduce(0.0) { $0 + $1.savingsPercent } / Double(projectRows.count)
        return String(format: "%.0f", avg)
    }

    private var totalPanes: Int {
        workspace?.panes.count ?? 0
    }

    private func savingsColor(_ pct: Double) -> Color {
        if pct >= 70 { return SenkaniTheme.savingsGreen }
        if pct >= 40 { return .yellow }
        return .red
    }

    private func featureBadgeColor(_ feature: String) -> Color {
        switch feature {
        case "filter": return .blue
        case "cache": return .cyan
        case "secrets": return .orange
        case "indexer": return .indigo
        case "terse": return .purple
        case "exec": return .blue
        case "reread_suppression": return .teal
        case "command_replay": return .teal
        case "trivial_routing": return .mint
        default: return .gray
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }
}
