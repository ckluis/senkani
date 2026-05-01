import SwiftUI
import Core

/// Live feed of optimization events. Polls `token_events` every 500ms and
/// renders each row with color-coded savings, timestamp, tool, and cost.
struct AgentTimelinePane: View {
    @Bindable var pane: PaneModel
    let workspace: WorkspaceModel?

    @State private var events: [SessionDatabase.TimelineEvent] = []
    @State private var expandedEventId: Int64?
    @State private var paused = false
    @State private var refreshTask: Task<Void, Never>?

    private let pollInterval: TimeInterval = 0.5
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
                                onTap: {
                                    if expandedEventId == event.id {
                                        expandedEventId = nil
                                    } else {
                                        expandedEventId = event.id
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
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
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
