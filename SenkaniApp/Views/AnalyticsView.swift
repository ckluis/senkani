import SwiftUI
import Charts
import Core

/// Rich analytics dashboard with savings charts, command breakdowns, and cost projections.
struct AnalyticsView: View {
    let workspace: WorkspaceModel
    @State private var sessionStore = SessionStore.shared
    @State private var showExportMenu = false
    @State private var now = Date()
    @State private var budgetConfig = BudgetConfig()
    @State private var todayCostCents: Int = 0

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    summaryCards
                    budgetCard
                    savingsOverTimeChart
                    commandBreakdownChart
                    costProjectionChart
                    pastSessionsSection
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onReceive(timer) { tick in
            now = tick
            budgetConfig = BudgetConfig.load()
            todayCostCents = SessionDatabase.shared.costForToday()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics")
                    .font(.system(size: 18, weight: .semibold))
                Text("Session started \(formattedDuration) ago")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button {
                    exportAsJSON()
                } label: {
                    Label("Export JSON", systemImage: "doc.text")
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button {
                    exportAsReport()
                } label: {
                    Label("Export Report", systemImage: "doc.richtext")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button {
                    sessionStore.saveSession(workspace: workspace)
                } label: {
                    Label("Save Session", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(
                title: "Total Saved",
                value: workspace.formattedTotalSavings,
                subtitle: "\(String(format: "%.0f", workspace.globalSavingsPercent))% reduction",
                color: .green,
                icon: "arrow.down.right"
            )

            SummaryCard(
                title: "Est. Cost Saved",
                value: workspace.estimatedCostSaved,
                subtitle: "\(ModelPricing.active.displayName) $\(String(format: "%.2f", ModelPricing.active.inputPerMillion))/M",
                color: .blue,
                icon: "dollarsign.circle"
            )

            SummaryCard(
                title: "Commands",
                value: "\(totalCommands)",
                subtitle: "\(workspace.panes.count) pane\(workspace.panes.count == 1 ? "" : "s")",
                color: .purple,
                icon: "terminal"
            )

            SummaryCard(
                title: "Secrets Caught",
                value: "\(totalSecrets)",
                subtitle: totalSecrets > 0 ? "redacted" : "none detected",
                color: .orange,
                icon: "lock.shield"
            )
        }
    }

    // MARK: - Budget Card

    private var hasBudget: Bool {
        budgetConfig.dailyLimitCents != nil || budgetConfig.weeklyLimitCents != nil || budgetConfig.perSessionLimitCents != nil
    }

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "creditcard")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Budget")
                    .font(.system(size: 13, weight: .semibold))
            }

            if !hasBudget {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("No budget set")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Create ~/.senkani/budget.json to set limits")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                if let dailyLimit = budgetConfig.dailyLimitCents {
                    budgetRow(
                        label: "Daily",
                        spent: todayCostCents,
                        limit: dailyLimit
                    )
                }

                if let weeklyLimit = budgetConfig.weeklyLimitCents {
                    let weekCost = SessionDatabase.shared.costForWeek()
                    budgetRow(
                        label: "Weekly",
                        spent: weekCost,
                        limit: weeklyLimit
                    )
                }

                if let sessionLimit = budgetConfig.perSessionLimitCents {
                    let sessionCost = ModelPricing.costSavedCents(bytes: workspace.totalSavedBytes)
                    budgetRow(
                        label: "Session",
                        spent: sessionCost,
                        limit: sessionLimit
                    )
                }
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func budgetRow(label: String, spent: Int, limit: Int) -> some View {
        let ratio = limit > 0 ? Double(spent) / Double(limit) : 0
        let color: Color = ratio >= 0.8 ? .red : (ratio >= 0.5 ? .yellow : .green)
        let spentStr = String(format: "$%.2f", Double(spent) / 100.0)
        let limitStr = String(format: "$%.2f", Double(limit) / 100.0)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(spentStr) / \(limitStr)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.separatorColor))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * ratio)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Savings Over Time (Line Chart)

    private var savingsOverTimeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Savings Over Time")
                .font(.system(size: 13, weight: .semibold))

            if allTimeSeries.isEmpty {
                chartPlaceholder("Data will appear as commands are intercepted")
            } else {
                Chart(allTimeSeries) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Bytes Saved", point.cumulativeSavedBytes)
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Bytes Saved", point.cumulativeSavedBytes)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.green.opacity(0.3), .green.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
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
                .animation(.easeInOut(duration: 0.3), value: allTimeSeries.count)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Per-Command Breakdown (Bar Chart)

    private var commandBreakdownChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Command Breakdown")
                .font(.system(size: 13, weight: .semibold))

            if globalBreakdownEntries.isEmpty {
                chartPlaceholder("Command breakdown will appear after first intercepted call")
            } else {
                Chart(globalBreakdownEntries.prefix(10)) { entry in
                    BarMark(
                        x: .value("Command", entry.command),
                        y: .value("Bytes", entry.rawBytes)
                    )
                    .foregroundStyle(by: .value("Type", "Raw"))

                    BarMark(
                        x: .value("Command", entry.command),
                        y: .value("Bytes", entry.filteredBytes)
                    )
                    .foregroundStyle(by: .value("Type", "Compressed"))
                }
                .chartForegroundStyleScale([
                    "Raw": Color.red.opacity(0.7),
                    "Compressed": Color.green.opacity(0.7),
                ])
                .chartLegend(position: .top, alignment: .trailing)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 9, design: .monospaced))
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
                .animation(.easeInOut(duration: 0.3), value: globalBreakdownEntries.count)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Cost Projection (Area Chart)

    private var costProjectionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cost Projection")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(ModelPricing.active.displayName) @ $\(String(format: "%.2f", ModelPricing.active.inputPerMillion))/M input")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if allTimeSeries.isEmpty {
                chartPlaceholder("Cost projection builds as data flows in")
            } else {
                Chart {
                    ForEach(costProjectionData) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Cost", point.costWithout)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.red.opacity(0.3), .red.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Cost", point.costWithout)
                        )
                        .foregroundStyle(.red.opacity(0.7))
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Cost", point.costWith)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.green.opacity(0.3), .green.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Cost", point.costWith)
                        )
                        .foregroundStyle(.green.opacity(0.7))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let cost = value.as(Double.self) {
                                Text(String(format: "$%.2f", cost))
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(height: 200)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(.red.opacity(0.7)).frame(width: 6, height: 6)
                            Text("Without Senkani")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(.green.opacity(0.7)).frame(width: 6, height: 6)
                            Text("With Senkani")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }
                .animation(.easeInOut(duration: 0.3), value: allTimeSeries.count)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Past Sessions

    private var pastSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Past Sessions")
                .font(.system(size: 13, weight: .semibold))

            if sessionStore.pastSessions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("No saved sessions yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Use Export > Save Session to record this session")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ForEach(sessionStore.pastSessions.prefix(10)) { session in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateFormatter.localizedString(from: session.timestamp, dateStyle: .medium, timeStyle: .short))
                                .font(.system(size: 11))
                            Text("\(session.paneCount) panes, \(session.commandCount) commands, \(session.formattedDuration)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(session.formattedSavings) saved")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green)
                            Text(String(format: "$%.2f", session.estimatedCostSaved))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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

    // MARK: - Computed Data

    private var totalCommands: Int {
        workspace.panes.reduce(0) { $0 + $1.metrics.commandCount }
    }

    private var totalSecrets: Int {
        workspace.panes.reduce(0) { $0 + $1.metrics.secretsCaught }
    }

    /// Merge time-series from all panes, sorted by time.
    private var allTimeSeries: [MetricsDataPoint] {
        workspace.panes
            .flatMap { $0.metrics.timeSeries }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Global command breakdown across all panes.
    private var globalBreakdownEntries: [CommandBreakdownEntry] {
        var combined: [String: (raw: Int, filtered: Int)] = [:]
        for pane in workspace.panes {
            for (cmd, values) in pane.metrics.commandBreakdown {
                let existing = combined[cmd, default: (raw: 0, filtered: 0)]
                combined[cmd] = (raw: existing.raw + values.raw, filtered: existing.filtered + values.filtered)
            }
        }
        return combined.map { key, value in
            CommandBreakdownEntry(command: key, rawBytes: value.raw, filteredBytes: value.filtered)
        }
        .sorted { $0.savedBytes > $1.savedBytes }
    }

    /// Cost projection data points.
    private var costProjectionData: [CostDataPoint] {
        var cumulativeRaw = 0
        var cumulativeFiltered = 0

        return allTimeSeries.map { point in
            cumulativeRaw = point.cumulativeRawBytes
            cumulativeFiltered = point.cumulativeRawBytes - point.cumulativeSavedBytes

            let costWithout = ModelPricing.costSaved(bytes: cumulativeRaw)
            let costWith = ModelPricing.costSaved(bytes: cumulativeFiltered)

            return CostDataPoint(
                timestamp: point.timestamp,
                costWithout: costWithout,
                costWith: costWith
            )
        }
    }

    private var formattedDuration: String {
        let elapsed = now.timeIntervalSince(workspace.sessionStart)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    private func exportAsJSON() {
        guard let data = sessionStore.exportJSON(workspace: workspace) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "senkani-session.json"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func exportAsReport() {
        let report = sessionStore.exportReport(workspace: workspace)
        guard let data = report.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "senkani-report.md"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Cost Data Point

private struct CostDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let costWithout: Double
    let costWith: Double
}

// MARK: - Summary Card

private struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let icon: String

    var body: some View {
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
}
