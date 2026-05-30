import SwiftUI
import Core

/// Read-only feed of OpenAI-compatible served requests. Renders the
/// persisted `openai_request_log` rows (metadata-only — never request or
/// completion bodies) via `SessionDatabase.shared.recentOpenAIRequests`.
///
/// V.13 GUI a-2 — pane core (a-1) + the 500ms poll lifecycle. Rows refresh
/// every 500ms while the pane is visible (`onAppear` start, `onDisappear`
/// stop), matching `AgentTimelinePane`. Catalog registration + accessibility
/// land in a-3.
///
/// All presentation logic (status → color category, relative age, raw
/// `model_logged` pass-through, NULL tolerance) lives in
/// `Core.OpenAIServedRequestsPresenter`, and the poll lifecycle (cadence,
/// cancellation, no-drop wholesale read) lives in
/// `Core.OpenAIServedRequestsPoller` — both so they are unit-testable from
/// `SenkaniTests` (executable-target views are not importable). This view
/// is a thin shell: it owns an `@Observable` poller, maps
/// `Presenter.StatusCategory` → a concrete `Color` (the `AgentTimelinePane`
/// palette, verbatim), and lays out the row. There is NO reactive
/// SQLite-change seam — the 500ms poll is the only refresh path (operator
/// decompose decision 2026-05-30). Privacy: `model_logged` is rendered RAW —
/// the producer sanitized it at the trust boundary; the persisted schema has
/// no body columns.
struct OpenAIServedRequestsPane: View {
    @Bindable var pane: PaneModel
    let workspace: WorkspaceModel?

    @State private var poller = OpenAIServedRequestsPoller(store: SessionDatabase.shared, limit: 100)

    private var rows: [OpenAIRequestLogStore.Row] { poller.rows }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("served requests")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Spacer()
                Text("\(rows.count) shown")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneBody)

            Divider()

            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            ServedRequestRow(fields: OpenAIServedRequestsPresenter.fields(for: row))
                            Divider().opacity(0.3)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(SenkaniTheme.paneBody)
            }
        }
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 32))
                .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
            Text("No served requests yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("Run `senkani serve --openai` and provision a key with `senkani vault add` — every served /v1 request appears here.")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One served-request row. Maps the presenter's view-agnostic `Fields`
/// (Core) to SwiftUI, including the `StatusCategory` → `Color` mapping
/// (the `AgentTimelinePane` palette, verbatim).
private struct ServedRequestRow: View {
    let fields: OpenAIServedRequestsPresenter.Fields

    private var statusColor: Color {
        switch fields.statusCategory {
        case .ok:      return SenkaniTheme.savingsGreen
        case .warn:    return .orange
        case .error:   return .red
        case .neutral: return SenkaniTheme.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(fields.age)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(width: 38, alignment: .leading)

            Text(fields.surface)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .frame(width: 72, alignment: .leading)

            Text(fields.model)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(fields.tier)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(width: 48, alignment: .leading)

            Text(fields.tokens)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(width: 64, alignment: .trailing)

            Text(fields.keyLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 72, alignment: .leading)

            Text("\(fields.status)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
