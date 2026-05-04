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

    // U.1c — tier-distribution chart state.
    @State private var tierWindow: TierChartWindow = .day
    @State private var tierStyle: TierChartStyle = .stacked
    @State private var tierBuckets: [AgentTraceTierBucket] = []
    @State private var tierDrillTier: String? = nil

    // U.6c — variance histogram state (planned-vs-actual cost residual).
    @State private var varianceWindow: TierChartWindow = .day
    @State private var variancePairs: [PlanActualPair] = []

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
                    tierDistributionChart
                    varianceHistogramChart
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
            refreshChartData()
        }
        .onAppear { refreshChartData() }
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

    // MARK: - Tier Distribution (U.1c)

    private var tierDistributionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Routing — TaskTier Distribution")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Picker("", selection: $tierWindow) {
                    ForEach(TierChartWindow.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .onChange(of: tierWindow) { _, _ in refreshChartData() }

                Picker("", selection: $tierStyle) {
                    ForEach(TierChartStyle.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if tierBuckets.isEmpty {
                tierEmptyState
            } else {
                Chart(tierChartEntries) { entry in
                    BarMark(
                        x: .value("Tier", entry.tier.uppercased()),
                        y: .value("Calls", entry.count)
                    )
                    .foregroundStyle(by: .value("Rung", entry.rungLabel))
                    .position(by: .value("Rung", entry.rungLabel), axis: .horizontal)
                    .annotation(position: .top, alignment: .center) {
                        if tierStyle == .grouped {
                            Text("\(entry.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartForegroundStyleScale(tierColorScale)
                .chartLegend(position: .top, alignment: .trailing)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text("\(n)")
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(height: 200)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geo[plotFrame]
                                let x = location.x - frame.origin.x
                                if let tier: String = proxy.value(atX: x) {
                                    tierDrillTier = tier.lowercased()
                                }
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: tierBuckets)

                Text("Click a bar to inspect the underlying trace rows.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(item: tierDrillBinding) { drill in
            TierDrillDownSheet(
                tier: drill.tier,
                window: tierWindow,
                onClose: { tierDrillTier = nil }
            )
        }
    }

    private var tierEmptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No routing data yet — TaskTier was introduced in u1a; charts populate as new traces land.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    /// Chart entries — collapsed to one row per tier in stacked mode, one
    /// row per (tier, rung) in grouped mode. Tier order is the canonical
    /// TaskTier ordering: simple → standard → complex → reasoning.
    private var tierChartEntries: [TierChartEntry] {
        let order = ["simple", "standard", "complex", "reasoning"]
        let sorted = tierBuckets.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.tier) ?? Int.max
            let ri = order.firstIndex(of: rhs.tier) ?? Int.max
            if li != ri { return li < ri }
            return (lhs.ladderPosition ?? -1) < (rhs.ladderPosition ?? -1)
        }
        switch tierStyle {
        case .stacked:
            // Collapse to one row per tier, single rung label "All".
            var totals: [String: Int] = [:]
            for b in sorted { totals[b.tier, default: 0] += b.count }
            return order.compactMap { tier in
                guard let n = totals[tier], n > 0 else { return nil }
                return TierChartEntry(tier: tier, ladderPosition: nil, count: n, rungLabel: "All")
            }
        case .grouped:
            return sorted.map { b in
                TierChartEntry(
                    tier: b.tier,
                    ladderPosition: b.ladderPosition,
                    count: b.count,
                    rungLabel: rungLabel(for: b.ladderPosition)
                )
            }
        }
    }

    private func rungLabel(for position: Int?) -> String {
        guard let p = position else { return "Unknown" }
        switch p {
        case 0: return "Primary"
        case 1: return "Fallback 1"
        case 2: return "Fallback 2"
        default: return "Rung \(p)"
        }
    }

    private var tierColorScale: KeyValuePairs<String, Color> {
        [
            "All":        Color.blue.opacity(0.7),
            "Primary":    Color.green.opacity(0.7),
            "Fallback 1": Color.yellow.opacity(0.8),
            "Fallback 2": Color.orange.opacity(0.8),
            "Unknown":    Color.gray.opacity(0.6),
        ]
    }

    private var tierDrillBinding: Binding<TierDrillTarget?> {
        Binding(
            get: { tierDrillTier.map { TierDrillTarget(tier: $0) } },
            set: { tierDrillTier = $0?.tier }
        )
    }

    // MARK: - Plan Variance Histogram (U.6c)

    private var varianceHistogramChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Plan Variance — Actual vs. Planned Cost")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Picker("", selection: $varianceWindow) {
                    ForEach(TierChartWindow.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .onChange(of: varianceWindow) { _, _ in refreshChartData() }
            }

            // Gelman gate — don't draw the histogram below N=3 paired plans.
            // Karpathy: residual = actual − planned. Negative = under, positive = over.
            let pairedExecuted = variancePairs.filter { $0.isPaired }
            let unpaired = variancePairs.count - pairedExecuted.count

            if pairedExecuted.count < 3 {
                varianceEmptyState(totalPlans: variancePairs.count)
            } else {
                let bins = VarianceHistogram.bins(pairs: pairedExecuted)
                let median = VarianceHistogram.median(
                    of: pairedExecuted.compactMap { $0.residualCents }
                )
                let pctPaired = variancePairs.isEmpty
                    ? 0.0
                    : Double(pairedExecuted.count) / Double(variancePairs.count)

                varianceHeaderStats(
                    paired: pairedExecuted.count,
                    unpaired: unpaired,
                    median: median,
                    pctPaired: pctPaired
                )

                Chart(bins) { bin in
                    BarMark(
                        x: .value("Residual (¢)", bin.label),
                        y: .value("Plans", bin.count)
                    )
                    .foregroundStyle(bin.kind == .under ? Color.green.opacity(0.7)
                                     : bin.kind == .exact ? Color.gray.opacity(0.6)
                                     : Color.red.opacity(0.7))
                    .annotation(position: .top, alignment: .center) {
                        if bin.count > 0 {
                            Text("\(bin.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 9, design: .monospaced))
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text("\(n)")
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(height: 200)
                .animation(.easeInOut(duration: 0.3), value: bins)

                Text("Residual = actual − planned cost. Under-budget left of 0¢, over-budget right.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func varianceEmptyState(totalPlans: Int) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(totalPlans == 0
                     ? "No combinator plans in this window — variance appears once split / filter / reduce calls land traces."
                     : "Need ≥ 3 paired plans for a stable histogram (have \(totalPlans), of which \(totalPlans) executed pending).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    private func varianceHeaderStats(
        paired: Int,
        unpaired: Int,
        median: Int,
        pctPaired: Double
    ) -> some View {
        HStack(spacing: 16) {
            varianceStatCell(label: "N paired", value: "\(paired)")
            varianceStatCell(label: "Unpaired", value: "\(unpaired)")
            varianceStatCell(
                label: "Median Δ",
                value: "\(median > 0 ? "+" : "")\(median)¢"
            )
            varianceStatCell(
                label: "% paired",
                value: String(format: "%.0f%%", pctPaired * 100)
            )
            Spacer()
        }
    }

    private func varianceStatCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
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
        let guidance = EmptyStateGuidance.entry(for: .analytics)
        return HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(guidance.nextAction)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
            }
            .padding(.vertical, 40)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(guidance.headline). \(guidance.populatingEvent) \(guidance.nextAction)"))
    }

    // MARK: - Computed Data

    private var totalCommands: Int {
        workspace.panes.reduce(0) { $0 + $1.metrics.commandCount }
    }

    private var totalSecrets: Int {
        workspace.panes.reduce(0) { $0 + $1.metrics.secretsCaught }
    }

    /// Time-series data from the persistent DB — survives app restart.
    @State private var cachedTimeSeries: [MetricsDataPoint] = []
    @State private var cachedBreakdown: [CommandBreakdownEntry] = []

    private var allTimeSeries: [MetricsDataPoint] { cachedTimeSeries }
    private var globalBreakdownEntries: [CommandBreakdownEntry] { cachedBreakdown }

    /// Reload chart data from the DB. Called on timer tick.
    private func refreshChartData() {
        let projectPath = workspace.activeProject?.path ?? NSHomeDirectory()
        let db = SessionDatabase.shared

        let series = db.savingsTimeSeries(projectRoot: projectPath)
        cachedTimeSeries = series.map { point in
            MetricsDataPoint(
                timestamp: point.timestamp,
                cumulativeSavedBytes: point.cumulativeSaved,
                cumulativeRawBytes: point.cumulativeRaw
            )
        }

        let breakdown = db.commandBreakdown(projectRoot: projectPath)
        cachedBreakdown = breakdown.map { entry in
            CommandBreakdownEntry(
                command: entry.command,
                rawBytes: entry.rawBytes,
                filteredBytes: entry.compressedBytes
            )
        }

        let since = Date().addingTimeInterval(-tierWindow.seconds)
        tierBuckets = db.agentTraceTierDistribution(since: since)

        let varianceSince = Date().addingTimeInterval(-varianceWindow.seconds)
        variancePairs = db.contextPlanPairs(since: varianceSince)
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

// MARK: - Tier Distribution helpers (U.1c)

enum TierChartWindow: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var label: String { self == .day ? "24h" : "7d" }
    var seconds: TimeInterval {
        switch self {
        case .day:  return 24 * 3600
        case .week: return 7 * 24 * 3600
        }
    }
}

enum TierChartStyle: String, CaseIterable, Identifiable {
    case stacked, grouped
    var id: String { rawValue }
    var label: String { self == .stacked ? "Stacked" : "Grouped" }
}

struct TierChartEntry: Identifiable, Equatable {
    let tier: String
    let ladderPosition: Int?
    let count: Int
    let rungLabel: String
    var id: String { "\(tier)#\(ladderPosition.map(String.init) ?? "all")" }
}

struct TierDrillTarget: Identifiable, Equatable {
    let tier: String
    var id: String { tier }
}

/// Drill-down sheet — lists agent_trace_event rows for a clicked tier.
private struct TierDrillDownSheet: View {
    let tier: String
    let window: TierChartWindow
    let onClose: () -> Void

    @State private var rows: [AgentTraceTierRow] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tier.uppercased()) — last \(window.label)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(rows.count) trace row\(rows.count == 1 ? "" : "s")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.ultraThinMaterial)

            Divider()

            if rows.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No traces in this tier+window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            tierRowView(row)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 600, height: 480)
        .onAppear {
            let since = Date().addingTimeInterval(-window.seconds)
            rows = SessionDatabase.shared.agentTraceRowsForTier(tier, since: since)
        }
    }

    private func tierRowView(_ row: AgentTraceTierRow) -> some View {
        let reprised = SessionDatabase.repriceTierRow(row)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.feature ?? "—")
                    .font(.system(size: 11, weight: .medium))
                Text(row.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.model ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                Text("\(row.tokensIn)/\(row.tokensOut) tok • \(row.latencyMs) ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "$%.4f", Double(row.costCents) / 100.0))
                    .font(.system(size: 10, design: .monospaced))
                if reprised.didReprice {
                    Text(String(format: "≈ $%.4f", Double(reprised.repricedCents) / 100.0))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("needs_validation")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.18))
                        .foregroundStyle(Color.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: 90, alignment: .trailing)

            Text(row.result)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(row.result == "success" ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                .foregroundStyle(row.result == "success" ? Color.green : Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
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
