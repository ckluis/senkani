import SwiftUI
import Core

/// Tool pane → Provider Health (item `phase-v17b-2-dashboard-pane-row-2026-06-06`).
///
/// The SwiftUI render half of V.17b: one row per provider showing CLI
/// install / version / auth / staleness, with a visual tier (fresh =
/// normal, stale = yellow, error = red), a per-provider refresh button
/// that re-probes LOCALLY (runs `<binary> --version`, never a network
/// call), and a remediation hint when set.
///
/// All presentation logic is the shipped, CI-tested headless view-model
/// (`ProviderHealthRowViewModel`, Core); this view is the AppKit/SwiftUI
/// binding + the refresh interaction only — the operator-gated visual
/// half of V.17b. The no-network invariant is preserved: the refresh
/// button drives the SAME local probe the CLI `provider refresh` uses.
struct ProviderHealthDashboardView: View {
    @State private var rows: [ProviderHealthRow] = []
    @State private var refreshing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainer
                    if rows.isEmpty {
                        emptyState
                    } else {
                        providerList
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SenkaniTheme.paneBody)
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .foregroundStyle(.pink)
            Text("Provider Health")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-read the latest snapshots from the local store")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var explainer: some View {
        Text("Local-only health for each coding-agent provider: CLI install, version, auth, and staleness. Refresh re-probes the local CLI (runs `<binary> --version` — never a network call) and updates the row. Stale rows render yellow; error rows render red; fresh rows render normal.")
            .font(.system(size: 11))
            .foregroundStyle(SenkaniTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No provider snapshots yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SenkaniTheme.textPrimary)
            Text("Probe the known providers to populate the dashboard (local-only).")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Button {
                probeAllKnown()
            } label: {
                Label("Probe known providers", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(!refreshing.isEmpty)
        }
        .padding(12)
        .background(SenkaniTheme.paneShell)
        .cornerRadius(6)
    }

    // MARK: - Rows

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                providerRow(row)
            }
        }
    }

    private func providerRow(_ row: ProviderHealthRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(tierColor(row.tier))
                    .frame(width: 9, height: 9)
                    .help(row.staleness.rawValue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.displayName(for: row.providerID))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tierColor(row.tier))
                    Text(row.providerID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                Spacer()
                metaColumn(label: "version", value: row.versionLabel)
                metaColumn(label: "auth", value: row.authStateLabel)
                metaColumn(label: "tier", value: row.staleness.rawValue)
                refreshButton(row.providerID)
            }
            if row.showsRemediation, let hint = row.remediationHint {
                remediationStrip(hint)
            }
        }
        .padding(12)
        .background(SenkaniTheme.paneShell)
        .cornerRadius(6)
    }

    private func metaColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
        .frame(width: 96, alignment: .leading)
    }

    private func refreshButton(_ providerID: String) -> some View {
        Button {
            refresh(providerID)
        } label: {
            if refreshing.contains(providerID) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(refreshing.contains(providerID))
        .help("Re-probe \(providerID) locally (no network)")
    }

    private func remediationStrip(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(4)
    }

    // MARK: - Tier → color (mirrors DashboardView.toneTextColor)

    private func tierColor(_ tier: ProviderHealthVisualTier) -> Color {
        switch tier {
        case .normal: return SenkaniTheme.textPrimary
        case .warning: return .yellow
        case .danger: return .red
        }
    }

    // MARK: - Data

    private func reload() {
        let snapshots = SessionDatabase.shared.providerHealthSnapshotStore.readAll()
        rows = ProviderHealthRowViewModel.rows(from: snapshots, now: Date())
    }

    /// Re-probe one provider LOCALLY (no network), upsert, re-read. The
    /// probe is synchronous and blocks on `<binary> --version`, so run it
    /// off the main thread, then hop back to refresh the UI.
    private func refresh(_ providerID: String) {
        guard !refreshing.contains(providerID) else { return }
        refreshing.insert(providerID)
        Task.detached {
            let snapshot = ProviderHealthProbe.production().snapshot(providerID: providerID)
            SessionDatabase.shared.providerHealthSnapshotStore.upsert(snapshot)
            await MainActor.run {
                refreshing.remove(providerID)
                reload()
            }
        }
    }

    /// Empty-store convenience: probe every known provider once.
    private func probeAllKnown() {
        for id in ProviderHealthProbe.knownProviderIDs {
            refresh(id)
        }
    }

    // MARK: - Labels

    static func displayName(for providerID: String) -> String {
        switch providerID {
        case "codex": return "Codex"
        case "claude_code": return "Claude Code"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        default: return providerID
        }
    }
}
