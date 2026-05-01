import SwiftUI
import Core

/// Compact "Senkani Active" proof strip for the active terminal pane.
///
/// Renders one chip per ``ActivationStatus/Component`` (PROJECT, MCP,
/// HOOKS, TRACK, EVENTS) using literal labels and a state token so the
/// strip's meaning never depends on color alone. When any component is
/// missing, a single banner row beneath the chips surfaces the first
/// missing component's next action — keeping the strip dense without
/// hiding remediation copy.
///
/// The strip refreshes on a 1-second `TimelineView` heartbeat so the
/// EVENTS chip's relative-age detail keeps updating without a global
/// refresh loop. Filesystem probes also re-run on each tick — they're
/// shallow JSON reads of two ~/.claude settings files, well below the
/// frame budget.
struct ActivationProofStrip: View {

    let projectRoot: String
    let isSessionWatcherRunning: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            stripContent(now: context.date)
        }
    }

    @ViewBuilder
    private func stripContent(now: Date) -> some View {
        let status = computeStatus(now: now)
        VStack(alignment: .leading, spacing: 0) {
            // Chip row.
            HStack(spacing: 6) {
                Text(status.isFullyActive ? "✓ Senkani active" : "Senkani")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        status.isFullyActive
                            ? SenkaniTheme.savingsGreen
                            : SenkaniTheme.textPrimary
                    )

                ForEach(status.components) { chip in
                    ActivationProofChip(status: chip)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stripBackground(status: status))

            // Single banner with the first missing component's next action.
            if let missing = status.firstMissing, let action = missing.nextAction {
                HStack(spacing: 6) {
                    Text("[\(missing.label)]")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                    Text(action)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.08))
            }

            // 0.5px divider above the terminal body.
            Rectangle()
                .fill(SenkaniTheme.inactiveBorder)
                .frame(height: 0.5)
        }
    }

    private func computeStatus(now: Date) -> ActivationStatus {
        let probes = ActivationProbes(
            projectRoot: projectRoot.isEmpty ? nil : projectRoot,
            mcpRegistered: ActivationProbeIO.mcpRegistered(),
            projectHooksRegistered: ActivationProbeIO.projectHooksRegistered(
                projectRoot: projectRoot
            ),
            sessionWatcherRunning: isSessionWatcherRunning,
            lastEventAt: latestEventTimestamp()
        )
        return ActivationStatusDerivation.derive(probes: probes, now: now)
    }

    private func latestEventTimestamp() -> Date? {
        guard !projectRoot.isEmpty else { return nil }
        let recents = SessionDatabase.shared.recentTokenEvents(
            projectRoot: projectRoot, limit: 1
        )
        return recents.first?.timestamp
    }

    private func stripBackground(status: ActivationStatus) -> Color {
        if status.isFullyActive {
            return SenkaniTheme.savingsGreen.opacity(0.06)
        }
        if status.firstMissing != nil {
            return Color.orange.opacity(0.05)
        }
        return SenkaniTheme.paneShell
    }
}

/// One chip in the proof strip — literal LABEL + state token + detail.
struct ActivationProofChip: View {
    let status: ActivationStatus.ComponentStatus

    var body: some View {
        HStack(spacing: 4) {
            Text(stateGlyph)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(stateColor)
            Text(status.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textPrimary)
            Text(status.detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(stateColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(stateColor.opacity(0.25), lineWidth: 0.5)
        )
        .help(helpText)
    }

    private var stateGlyph: String {
        switch status.state {
        case .ok:      return "OK"
        case .waiting: return "··"
        case .missing: return "!"
        }
    }

    private var stateColor: Color {
        switch status.state {
        case .ok:      return SenkaniTheme.savingsGreen
        case .waiting: return SenkaniTheme.textTertiary
        case .missing: return .orange
        }
    }

    private var helpText: String {
        if let action = status.nextAction {
            return "\(status.label): \(status.detail) — \(action)"
        }
        return "\(status.label): \(status.detail)"
    }
}
