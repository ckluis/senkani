import SwiftUI
import Core

/// Soft-flag list for Phase U.4a — operator labels each flag as
/// "False alarm" (FP) or "Real" (TP). Labels round-trip through the
/// chained `trust_audits` table; nothing on this screen blocks a
/// hook event. Promotion-to-blocking is U.4b.
struct TrustFlagsView: View {
    @State private var flags: [TrustFlagRow] = []
    @State private var latestLabel: [Int64: TrustLabel] = [:]
    @State private var refreshKey = UUID()

    /// Test seam — production resolves to `SessionDatabase.shared`.
    var database: SessionDatabase = .shared
    /// Test seam for the operator handle persisted in label rows.
    var operatorHandle: String = NSUserName()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if flags.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(flags) { flag in
                        flagRow(flag)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { reload() }
        .id(refreshKey)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Trust Flags")
                .font(.title2.weight(.semibold))
            Spacer()
            Text(legend)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var legend: String {
        let total = flags.count
        let fp = latestLabel.values.filter { $0 == .fp }.count
        let tp = latestLabel.values.filter { $0 == .tp }.count
        let unlabeled = total - fp - tp
        return "\(total) flags · \(unlabeled) unlabeled · FP \(fp) · TP \(tp)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No fragmentation flags in the last 30 days.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("FragmentationDetector is in soft-flag mode — calls are never blocked.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func flagRow(_ flag: TrustFlagRow) -> some View {
        let current = latestLabel[flag.id]
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(reasonHelp(flag.reason))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(flag.toolName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(reasonTitle(flag.reason))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("trust \(flag.score)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(scoreColor(flag.score))
                }
                HStack(spacing: 6) {
                    Text("session \(flag.sessionId.prefix(8))")
                    if let pane = flag.paneId {
                        Text("· pane \(pane.prefix(6))")
                    }
                    Text("· \(flag.correlationCount) correlated")
                    Text("· \(relativeTime(flag.createdAt))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 6) {
                if let current {
                    Text(current == .fp ? "False alarm" : "Real")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(current == .fp ? Color.gray.opacity(0.18) : Color.orange.opacity(0.18))
                        .foregroundStyle(current == .fp ? .secondary : .primary)
                        .cornerRadius(4)
                }
                Button("False alarm") {
                    label(flag, as: .fp)
                }
                .buttonStyle(.bordered)
                .help("Operator says this flag was wrong (FP)")

                Button("Real") {
                    label(flag, as: .tp)
                }
                .buttonStyle(.borderedProminent)
                .help("Operator confirms this flag was correct (TP)")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func reload() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        flags = database.recentTrustFlags(limit: 200, since: cutoff)
        var map: [Int64: TrustLabel] = [:]
        for f in flags {
            if let latest = database.trustLabelsForFlag(f.id).first {
                map[f.id] = latest.label
            }
        }
        latestLabel = map
    }

    private func label(_ flag: TrustFlagRow, as label: TrustLabel) {
        _ = database.recordTrustLabel(
            flagId: flag.id,
            label: label,
            labeledBy: operatorHandle
        )
        // Optimistic local update — reload pulls authoritative state.
        latestLabel[flag.id] = label
        reload()
    }

    // MARK: - Display helpers

    private func reasonTitle(_ r: FragmentationDetector.Reason) -> String {
        switch r {
        case .toolBurst:      return "tool burst"
        case .fragmentStitch: return "fragment stitch"
        case .crossPane:      return "cross-pane"
        }
    }

    private func reasonHelp(_ r: FragmentationDetector.Reason) -> String {
        switch r {
        case .toolBurst:      return "≥3 calls of the same tool inside the burst window."
        case .fragmentStitch: return "Prompt fragments overlap across tool calls."
        case .crossPane:      return "Same tool fires in two different panes inside one session."
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...:  return .secondary
        case 50..<80: return .orange
        default:      return .red
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#if DEBUG
#Preview {
    TrustFlagsView()
        .frame(width: 720, height: 480)
}
#endif
