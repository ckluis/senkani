import SwiftUI
import Core

/// Live feed of optimization events. Polls `token_events` every 500ms and
/// renders each row with color-coded savings, timestamp, tool, and cost.
///
/// V.18a-7 — adds a runtime-error badge surface. Rows whose
/// `session_id` / `tool_call_id` / `validation_run_id` correlate to
/// spans with `status_code = ERROR` or `duration > p99` of the
/// visible-window span set show a small badge dot. First click
/// expands a compact summary inline (slow-span list + error count +
/// total duration). Second click opens the side pane that loads the
/// full span tree on demand. The compact summary stays summary-only;
/// the full tree is NOT embedded in prompt context.
struct AgentTimelinePane: View {
    @Bindable var pane: PaneModel
    let workspace: WorkspaceModel?

    @State private var events: [SessionDatabase.TimelineEvent] = []
    @State private var expandedEventId: Int64?
    @State private var paused = false
    @State private var refreshTask: Task<Void, Never>?
    /// V.18a-7 — per-event badge / compact summary cache. Rebuilt
    /// on each correlation pass (~2s cadence, see correlationTask).
    @State private var correlations: [Int64: TimelineTelemetryCorrelator.RowCorrelation] = [:]
    @State private var correlationTask: Task<Void, Never>?
    /// V.18a-7 — second-click target. When non-nil the side pane
    /// renders and calls `getTrace` on appear.
    @State private var openTraceId: String?

    private let pollInterval: TimeInterval = 0.5
    private let correlationInterval: TimeInterval = 2.0
    private let maxEvents: Int = 100

    private var activeProjectPath: String? {
        workspace?.activeProject?.path ?? workspace?.projects.first?.path
    }

    private var totalSaved: Int {
        events.reduce(0) { $0 + $1.savedTokens }
    }

    private var totalCostCents: Int {
        events.reduce(0) { $0 + $1.costCents }
    }

    var body: some View {
        HStack(spacing: 0) {
            timelineColumn
            if let traceId = openTraceId {
                Divider()
                TimelineSpanSidePane(
                    traceId: traceId,
                    onClose: { openTraceId = nil }
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }
        }
        .onAppear {
            startPolling()
            startCorrelation()
        }
        .onDisappear {
            stopPolling()
            stopCorrelation()
        }
    }

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            // Control bar
            HStack(spacing: 6) {
                Button(action: { paused.toggle() }) {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(paused ? "Resume live feed" : "Pause live feed")

                if paused {
                    Text("PAUSED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.accentDiffViewer)
                        .padding(.horizontal, 4)
                }

                Spacer()

                Text("\(events.count) events")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneBody)

            Divider()

            // Event list
            if events.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform.path")
                        .font(.system(size: 32))
                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                    Text("No optimization events yet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Text("Use the terminal next to this pane — every Senkani-aware tool call appears here with bytes saved.")
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            TimelineRow(
                                event: event,
                                isExpanded: expandedEventId == event.id,
                                correlation: correlations[event.id],
                                onTap: {
                                    let already = (expandedEventId == event.id)
                                    if !already {
                                        expandedEventId = event.id
                                    } else if let trace = correlations[event.id]?.summary.primaryTraceId {
                                        // Second click on an expanded badged row
                                        // promotes to the side pane.
                                        openTraceId = trace
                                    } else {
                                        expandedEventId = nil
                                    }
                                }
                            )
                            Divider().opacity(0.3)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(SenkaniTheme.paneBody)
            }

            Divider()

            // Footer: summary stats
            HStack(spacing: 8) {
                Text("\(events.count)")
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    + Text(" events")
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Spacer().frame(width: 12)

                Text(formatTokens(totalSaved))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
                    + Text(" saved")
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Spacer().frame(width: 12)

                Text(formatCost(totalCostCents))
                    .foregroundStyle(SenkaniTheme.savingsGreen)

                Spacer()
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneBody)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                if !paused {
                    refreshEvents()
                }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    private func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refreshEvents() {
        let db = SessionDatabase.shared
        let newEvents: [SessionDatabase.TimelineEvent]
        if let project = activeProjectPath {
            newEvents = db.recentTokenEvents(projectRoot: project, limit: maxEvents)
        } else {
            newEvents = db.recentTokenEventsAllProjects(limit: maxEvents)
        }
        if newEvents != events {
            events = newEvents
        }
    }

    // MARK: - Telemetry correlation (V.18a-7)

    private func startCorrelation() {
        stopCorrelation()
        correlationTask = Task { @MainActor in
            while !Task.isCancelled {
                if !paused {
                    refreshCorrelations()
                }
                try? await Task.sleep(for: .seconds(correlationInterval))
            }
        }
    }

    private func stopCorrelation() {
        correlationTask?.cancel()
        correlationTask = nil
    }

    private func refreshCorrelations() {
        guard !events.isEmpty else {
            if !correlations.isEmpty { correlations = [:] }
            return
        }
        let store = SessionDatabase.shared.runtimeTelemetryStore
        guard let store else { return }

        // Build a unique sessionId set across the visible events,
        // capped at 10 to bound DB cost per refresh.
        let sessionIds: [String] = Array(
            Set(events.compactMap { $0.sessionId })
        ).prefix(10).map { $0 }

        var allSpans: [RuntimeTelemetryStore.SpanResult] = []
        for sid in sessionIds {
            var filter = RuntimeTelemetryStore.QueryFilter()
            filter.sessionId = sid
            let spans = store.querySpans(filter: filter, limit: 200, cursorAfterId: nil)
            allSpans.append(contentsOf: spans)
        }

        let keys = events.map { ev in
            TimelineTelemetryCorrelator.EventKeys(
                eventId: ev.id,
                sessionId: ev.sessionId,
                toolCallId: nil,
                validationRunId: nil
            )
        }
        let result = TimelineTelemetryCorrelator.correlate(events: keys, spans: allSpans)
        if result != correlations {
            correlations = result
        }
    }

    // MARK: - Formatting helpers

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func formatCost(_ cents: Int) -> String {
        return String(format: "$%.2f", Double(cents) / 100.0)
    }
}

/// A single event row in the timeline.
private struct TimelineRow: View {
    let event: SessionDatabase.TimelineEvent
    let isExpanded: Bool
    let correlation: TimelineTelemetryCorrelator.RowCorrelation?
    let onTap: () -> Void

    private var tierColor: Color {
        let rawEstimate = event.savedTokens + event.outputTokens
        guard rawEstimate > 0 else { return SenkaniTheme.textTertiary }
        let pct = Double(event.savedTokens) / Double(rawEstimate) * 100
        if pct >= 80 { return SenkaniTheme.savingsGreen }
        if pct >= 40 { return SenkaniTheme.accentDiffViewer }
        return SenkaniTheme.textTertiary
    }

    private var toolIcon: String {
        switch event.toolName ?? event.feature ?? "" {
        case "read":            return "doc.text"
        case "exec":            return "terminal"
        case "search":          return "magnifyingglass"
        case "fetch":           return "arrow.down.doc"
        case "explore":         return "folder"
        case "outline":         return "list.bullet.indent"
        case "deps":            return "arrow.triangle.branch"
        case "validate":        return "checkmark.seal"
        case "parse":           return "doc.text.magnifyingglass"
        case "embed":           return "sparkles"
        case "vision":          return "eye"
        case "session":         return "gearshape"
        case "pane":            return "rectangle.3.group"
        default:                return "circle.fill"
        }
    }

    private var timeLabel: String {
        let interval = Date().timeIntervalSince(event.timestamp)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: event.timestamp)
    }

    private var commandPreview: String {
        let raw = event.command ?? event.toolName ?? event.feature ?? ""
        let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count > 50 {
            return String(collapsed.prefix(47)) + "..."
        }
        return collapsed
    }

    private var badgeColor: Color? {
        switch correlation?.badge ?? .none {
        case .error: return .red
        case .slow:  return .orange
        case .none:  return nil
        }
    }

    private var badgeTooltip: String {
        guard let c = correlation else { return "" }
        switch c.badge {
        case .error:
            return "\(c.summary.errorCount) error span(s) · click for details"
        case .slow:
            return "\(c.summary.slowSpans.count) slow span(s) · click for details"
        case .none:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Single-line row
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(tierColor)
                    .frame(width: 14)

                Text(timeLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .frame(width: 38, alignment: .leading)

                Text(event.feature ?? event.toolName ?? event.source)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .frame(width: 56, alignment: .leading)

                Text(commandPreview)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // V.18a-7 — runtime-error badge dot.
                if let color = badgeColor {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .help(badgeTooltip)
                        .accessibilityLabel(Text(badgeTooltip))
                }

                // V.5d — token_events doesn't carry authorship; the
                // badge surfaces the "Untagged" affordance with a
                // tooltip explaining where the column lives today.
                AuthorshipBadgeView(tag: nil, context: .timeline)

                if event.savedTokens > 0 {
                    Text(formatCompact(event.savedTokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                }

                if event.costCents > 0 {
                    Text(String(format: "$%.2f", Double(event.costCents) / 100.0))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen.opacity(0.7))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // Expanded detail view
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let cmd = event.command {
                        detailRow(label: "cmd:", value: cmd, selectable: true)
                    }
                    detailRow(label: "source:", value: event.source)
                    detailRow(label: "in:", value: "\(event.inputTokens) tok")
                    detailRow(label: "out:", value: "\(event.outputTokens) tok")
                    HStack(spacing: 4) {
                        Text("saved:")
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .frame(width: 40, alignment: .trailing)
                        Text("\(event.savedTokens) tok")
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                    }
                    // V.18a-7 — compact runtime-error summary
                    // (inline). The full span tree is not rendered
                    // here; click again to open the side pane.
                    if let c = correlation, c.badge != .none {
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 4) {
                            Text("errors:")
                                .foregroundStyle(SenkaniTheme.textTertiary)
                                .frame(width: 40, alignment: .trailing)
                            Text("\(c.summary.errorCount)")
                                .foregroundStyle(c.summary.errorCount > 0 ? .red : SenkaniTheme.textSecondary)
                        }
                        HStack(spacing: 4) {
                            Text("dur:")
                                .foregroundStyle(SenkaniTheme.textTertiary)
                                .frame(width: 40, alignment: .trailing)
                            Text("\(c.summary.totalDurationMs) ms")
                                .foregroundStyle(SenkaniTheme.textSecondary)
                        }
                        if !c.summary.slowSpans.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Text("slow:")
                                    .foregroundStyle(SenkaniTheme.textTertiary)
                                    .frame(width: 40, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(c.summary.slowSpans.enumerated()), id: \.offset) { _, sp in
                                        Text("\(sp.name) — \(sp.durationMs) ms")
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        if c.summary.primaryTraceId != nil {
                            Text("click again → open trace side pane")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.8))
                                .padding(.top, 2)
                        }
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SenkaniTheme.paneBody.opacity(0.5))
            }
        }
    }

    private func detailRow(label: String, value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(width: 40, alignment: .trailing)
            if selectable {
                Text(value)
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .foregroundStyle(SenkaniTheme.textSecondary)
            }
        }
    }

    private func formatCompact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// V.18a-7 — side pane that fetches and renders the full span tree
/// for one trace_id. Loaded on demand (second click on a badged
/// row) via `TelemetryQueryDispatcher.getTrace`; the inline compact
/// summary stays summary-only.
private struct TimelineSpanSidePane: View {
    let traceId: String
    let onClose: () -> Void

    @State private var spans: [TelemetryQueryDispatcher.QueryResponse.SpanEntry] = []
    @State private var truncated = false
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("trace ")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                Text(String(traceId.prefix(12)))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .textSelection(.enabled)
                Spacer()
                if truncated {
                    Text("TRUNCATED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Close trace side pane")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneBody)

            Divider()

            if !loaded {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if spans.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                    Text("No spans for this trace")
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(spans, id: \.id) { sp in
                            HStack(alignment: .top, spacing: 4) {
                                Text(sp.status_code == 2 ? "ERR" : "OK ")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(sp.status_code == 2 ? .red : SenkaniTheme.textTertiary)
                                Text(sp.name)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(SenkaniTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text("\(Int((sp.end_unix_ns - sp.start_unix_ns) / 1_000_000)) ms")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(SenkaniTheme.textTertiary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(SenkaniTheme.paneBody)
            }
        }
        .background(SenkaniTheme.paneBody)
        .onAppear { load() }
    }

    private func load() {
        guard !loaded else { return }
        let store = SessionDatabase.shared.runtimeTelemetryStore
        guard let store else {
            loaded = true
            return
        }
        let resp = TelemetryQueryDispatcher.getTrace(store: store, traceId: traceId)
        spans = resp.spans.sorted { $0.start_unix_ns < $1.start_unix_ns }
        truncated = resp.truncated
        loaded = true
    }
}
