import SwiftUI
import UniformTypeIdentifiers
import Bench
import Core

/// Interactive benchmark pane with two modes:
/// - Fixture: runs deterministic benchmark suite (ceiling number)
/// - Live: aggregates real token_events into per-feature savings breakdown
struct SavingsTestView: View {
    let workspace: WorkspaceModel?

    private enum BenchMode: String, CaseIterable {
        case fixture = "Fixture"
        case live = "Live"
        case scenarios = "Scenarios"
    }

    // Shared
    @State private var selectedMode: BenchMode = .fixture

    // Fixture mode
    @State private var report: BenchmarkReport?
    @State private var isRunning = false

    // Live mode
    @State private var featureBreakdown: [SessionDatabase.FeatureSavings] = []
    @State private var liveStats: PaneTokenStats = .zero
    @State private var topEvents: [SessionDatabase.TimelineEvent] = []
    @State private var liveRefreshTask: Task<Void, Never>?

    // Scenario mode
    @State private var selectedScenarioId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Mode selector
            HStack(spacing: 0) {
                ForEach(BenchMode.allCases, id: \.self) { mode in
                    Button(action: { selectedMode = mode }) {
                        Text(mode.rawValue)
                            .font(.system(size: 10, weight: selectedMode == mode ? .bold : .regular, design: .monospaced))
                            .foregroundStyle(selectedMode == mode ? SenkaniTheme.accentColor(for: .savingsTest) : SenkaniTheme.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .background(SenkaniTheme.paneBody)

            Divider()

            switch selectedMode {
            case .fixture: fixtureContent
            case .live: liveContent
            case .scenarios: scenarioContent
            }
        }
        .onChange(of: selectedMode) { _, newMode in
            if newMode == .live { startLiveRefresh() } else { stopLiveRefresh() }
        }
        .onDisappear { stopLiveRefresh() }
    }

    // MARK: - Fixture Mode

    @ViewBuilder
    private var fixtureContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: runBenchmark) {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                        }
                        Text(isRunning ? "Running..." : "Run Benchmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning)

                if let report {
                    Spacer()

                    Text(String(format: "%.1fx", report.overallMultiplier))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(report.allGatesPassed ? SenkaniTheme.savingsGreen : .red)

                    Text("cost reduction")
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.textTertiary)

                    Spacer()

                    Text(report.allGatesPassed ? "PASS" : "FAIL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(report.allGatesPassed ? SenkaniTheme.savingsGreen : .red)
                        .cornerRadius(4)

                    Button(action: exportJSON) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Export report as JSON")
                }

                if report == nil && !isRunning {
                    Spacer()
                    Text("Click Run to measure token savings across all optimization layers.")
                        .font(.system(size: 11))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SenkaniTheme.paneBody)

            Divider()

            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        gatesSection(report.gates)
                        Divider().padding(.vertical, 8)
                        taskResultsSection(report)
                        metadataSection(report)
                    }
                    .padding(12)
                }
                .scrollContentBackground(.hidden)
                .background(SenkaniTheme.paneBody)
            } else if isRunning {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("Running 10 tasks × 7 configurations...")
                        .font(.system(size: 11))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 32))
                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                    Text("Token Savings Benchmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .padding(.top, 8)
                    Text("Measures filter, cache, indexer, terse, secrets, sandbox, and parse\noptimizations across 7 configurations.")
                        .font(.system(size: 11))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Live Mode

    @ViewBuilder
    private var liveContent: some View {
        if featureBreakdown.isEmpty && liveStats.savedTokens == 0 {
            VStack {
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 32))
                    .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                Text("No optimization data yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .padding(.top, 8)
                Text("Run MCP tools in a Senkani terminal to see live savings here.")
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    liveSummaryBar
                    Divider()
                    liveFeatureBreakdown
                    Divider()
                    liveTopEvents
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)
            .background(SenkaniTheme.paneBody)
        }
    }

    @ViewBuilder
    private var liveSummaryBar: some View {
        let totalRaw = liveStats.inputTokens + liveStats.outputTokens + liveStats.savedTokens
        let totalCompressed = liveStats.inputTokens + liveStats.outputTokens
        let multiplier = totalCompressed > 0 ? Double(totalRaw) / Double(totalCompressed) : 1.0
        let costSavedCents = liveStats.costCents

        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1fx", multiplier))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
                Text("session multiplier")
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatTokens(liveStats.savedTokens))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
                Text("tokens saved")
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "$%.2f", Double(costSavedCents) / 100.0))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
                Text("cost saved")
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            Divider().frame(height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(liveStats.commandCount)")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Text("tool calls")
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var liveFeatureBreakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Savings by Feature")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .padding(.bottom, 4)

            ForEach(featureBreakdown, id: \.feature) { item in
                let rawTokens = item.inputTokens + item.outputTokens + item.savedTokens
                let savingsPct = rawTokens > 0 ? Double(item.savedTokens) / Double(rawTokens) * 100 : 0

                HStack(spacing: 8) {
                    Text(item.feature)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .frame(width: 80, alignment: .leading)

                    Text(formatTokens(rawTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .frame(width: 48, alignment: .trailing)

                    Text("→")
                        .font(.system(size: 8))
                        .foregroundStyle(SenkaniTheme.textTertiary)

                    Text(formatTokens(item.savedTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                        .frame(width: 48, alignment: .trailing)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SenkaniTheme.savingsGreen.opacity(0.7))
                            .frame(width: max(2, geo.size.width * savingsPct / 100))
                    }
                    .frame(height: 12)

                    Text(String(format: "%.0f%%", savingsPct))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                        .frame(width: 36, alignment: .trailing)

                    Text("\(item.eventCount)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .frame(width: 24, alignment: .trailing)
                }
                .frame(height: 20)
            }
        }
    }

    @ViewBuilder
    private var liveTopEvents: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top Savings Events")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .padding(.bottom, 4)

            ForEach(topEvents.prefix(5)) { event in
                HStack(spacing: 8) {
                    Text(timeLabel(for: event.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .frame(width: 44, alignment: .leading)

                    Text(event.feature ?? event.toolName ?? "—")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .frame(width: 56, alignment: .leading)

                    Text(event.command?.prefix(40).description ?? "—")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(formatTokens(event.savedTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                }
            }

            if topEvents.isEmpty {
                Text("No savings events yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func timeLabel(for date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Scenario Mode

    @ViewBuilder
    private var scenarioContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How much would you save?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textSecondary)

                Text("Each scenario models a typical developer task with realistic tool-call patterns. Byte counts are grounded in measured ratios from the fixture bench.")
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(BenchmarkScenarios.all) { scenario in
                        scenarioCard(scenario)
                    }
                }

                if let selectedId = selectedScenarioId,
                   let scenario = BenchmarkScenarios.all.first(where: { $0.id == selectedId }) {
                    Divider().padding(.vertical, 8)
                    scenarioDetail(scenario)
                }
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
        .background(SenkaniTheme.paneBody)
    }

    @ViewBuilder
    private func scenarioCard(_ scenario: Scenario) -> some View {
        let isSelected = selectedScenarioId == scenario.id

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: scenario.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? SenkaniTheme.savingsGreen : SenkaniTheme.textTertiary)

                Spacer()

                Text(String(format: "%.0fx", scenario.multiplier))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
            }

            Text(scenario.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textSecondary)

            Text(scenario.description)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .lineLimit(2)

            HStack(spacing: 12) {
                Text("\(scenario.callCount) calls")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Text(String(format: "$%.2f → $%.2f", scenario.rawCostCents / 100, scenario.optimizedCostCents / 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
            }
        }
        .padding(12)
        .background(isSelected ? SenkaniTheme.savingsGreen.opacity(0.08) : SenkaniTheme.paneBody)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? SenkaniTheme.savingsGreen.opacity(0.3) : SenkaniTheme.textTertiary.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedScenarioId = selectedScenarioId == scenario.id ? nil : scenario.id
            }
        }
    }

    @ViewBuilder
    private func scenarioDetail(_ scenario: Scenario) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1fx", scenario.multiplier))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                    Text("estimated savings")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }

                Divider().frame(height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTokens(scenario.totalSaved))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                    Text("tokens saved")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }

                Divider().frame(height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scenario.callCount) calls")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                    Text("in this workflow")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Savings by Feature")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .padding(.bottom, 4)

                ForEach(scenario.featureBreakdown, id: \.feature) { item in
                    HStack(spacing: 8) {
                        Text(item.feature)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                            .frame(width: 100, alignment: .leading)

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(SenkaniTheme.savingsGreen.opacity(0.7))
                                .frame(width: max(2, geo.size.width * item.savedPct / 100))
                        }
                        .frame(height: 12)

                        Text(String(format: "%.0f%%", item.savedPct))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                            .frame(width: 36, alignment: .trailing)

                        Text("\(item.callCount) calls")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Per-Call Detail")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(scenario.calls) { call in
                    HStack(spacing: 8) {
                        Text(call.tool)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                            .frame(width: 50, alignment: .leading)

                        Text(call.description)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(formatBytes(call.rawBytes))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .frame(width: 44, alignment: .trailing)

                        Text("→")
                            .font(.system(size: 8))
                            .foregroundStyle(SenkaniTheme.textTertiary)

                        Text(formatBytes(call.optimizedBytes))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(call.savedPct > 50 ? SenkaniTheme.savingsGreen : SenkaniTheme.textSecondary)
                            .frame(width: 44, alignment: .trailing)

                        Text(String(format: "%.0f%%", call.savedPct))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Live Refresh

    private func startLiveRefresh() {
        stopLiveRefresh()
        refreshLiveData()
        liveRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                refreshLiveData()
            }
        }
    }

    private func stopLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func refreshLiveData() {
        guard let projectPath = workspace?.activeProject?.path ?? workspace?.projects.first?.path else { return }
        let db = SessionDatabase.shared

        let newStats = db.tokenStatsForProject(projectPath)
        let newBreakdown = db.tokenStatsByFeature(projectRoot: projectPath)
        let allRecent = db.recentTokenEvents(projectRoot: projectPath, limit: 50)
        let newTopEvents = allRecent
            .filter { $0.savedTokens > 0 }
            .sorted { $0.savedTokens > $1.savedTokens }

        if newStats != liveStats { liveStats = newStats }
        if newBreakdown != featureBreakdown { featureBreakdown = newBreakdown }
        if newTopEvents != topEvents { topEvents = newTopEvents }
    }

    // MARK: - Fixture Actions

    private func runBenchmark() {
        isRunning = true
        report = nil
        Task {
            let tasks = BenchmarkTasks.all()
            let result = SavingsTestRunner.run(tasks: tasks)
            await MainActor.run {
                report = result
                isRunning = false
            }
        }
    }

    private func exportJSON() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "senkani-bench-\(formattedTimestamp()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try BenchmarkReporter.jsonReport(report)
                try data.write(to: url)
            } catch {
                print("[SavingsTest] Export failed: \(error)")
            }
        }
    }

    // MARK: - Formatting

    private func formattedTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return fmt.string(from: Date())
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    @ViewBuilder
    private func gatesSection(_ gates: [QualityGate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quality Gates")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .padding(.bottom, 4)

            ForEach(gates, id: \.name) { gate in
                HStack(spacing: 8) {
                    Image(systemName: gate.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(gate.passed ? SenkaniTheme.savingsGreen : .red)

                    Text(gate.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    let unit = gate.category == "overall" && gate.name.contains("multiplier") ? "x" : "%"
                    Text(String(format: "%.1f\(unit)", gate.actual))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(gate.passed ? SenkaniTheme.savingsGreen : .red)

                    Text("≥ \(String(format: "%.0f\(unit)", gate.threshold))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func taskResultsSection(_ report: BenchmarkReport) -> some View {
        let byCategory = Dictionary(grouping: report.results, by: \.category)

        VStack(alignment: .leading, spacing: 12) {
            Text("Results by Category")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)

            ForEach(byCategory.keys.sorted(), id: \.self) { category in
                if let categoryResults = byCategory[category] {
                    categoryRow(category: category, results: categoryResults)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(category: String, results: [TaskResult]) -> some View {
        let byTask = Dictionary(grouping: results, by: \.taskId)

        VStack(alignment: .leading, spacing: 4) {
            Text(category.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.accentDiffViewer)
                .padding(.top, 4)

            ForEach(byTask.keys.sorted(), id: \.self) { taskId in
                if let taskResults = byTask[taskId] {
                    let baseline = taskResults.first { $0.configName == "baseline" }
                    let full = taskResults.first { $0.configName == "full" }

                    HStack(spacing: 8) {
                        Text(taskId.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)

                        if let baseline, let full {
                            Text(formatBytes(baseline.compressedBytes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.textTertiary)

                            Text("→")
                                .font(.system(size: 9))
                                .foregroundStyle(SenkaniTheme.textTertiary)

                            Text(formatBytes(full.compressedBytes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.savingsGreen)

                            Text(String(format: "%.0f%%", full.savedPct))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.savingsGreen)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ report: BenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.vertical, 8)

            Text("Run Info")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)

            HStack(spacing: 16) {
                Text("Tasks: \(Set(report.results.map(\.taskId)).count)")
                Text("Configs: \(report.configs.count)")
                Text("Duration: \(String(format: "%.0fms", report.durationMs))")
                Text("Date: \(formattedDate(report.timestamp))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(SenkaniTheme.textTertiary)
            .padding(.top, 4)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    private func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
