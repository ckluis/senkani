import SwiftUI
import Core

/// App-level status footer showing token metrics.
/// Left: active project stats. Right: all-projects aggregate (if >1 project).
/// Two rows: IN (input tokens) and OUT (output tokens).
/// Each row: total tokens, saved tokens (green), total cost, saved cost (green).
/// Reads from MetricsStore.shared — same source as SidebarView.
struct StatusBarView: View {
    let workspace: WorkspaceModel
    @State private var now = Date()

    private var pricing: ModelPricing { ModelPricing.active }

    private var activeProjectName: String {
        workspace.activeProject?.name ?? workspace.projects.first?.name ?? "No Project"
    }

    private var activeProjectPath: String {
        workspace.activeProject?.path ?? workspace.projects.first?.path ?? ""
    }

    private var showAllProjects: Bool {
        workspace.projects.count > 1
    }

    private var currentProjectStats: PaneTokenStats {
        guard !activeProjectPath.isEmpty else { return .zero }
        return MetricsStore.shared.stats(for: activeProjectPath)
    }

    var body: some View {
        HStack(spacing: 0) {
            // LEFT: Active project
            projectSection(
                label: activeProjectName,
                stats: currentProjectStats
            )

            if showAllProjects {
                // Vertical divider
                Rectangle()
                    .fill(SenkaniTheme.inactiveBorder)
                    .frame(width: 0.5)
                    .padding(.vertical, 3)

                // RIGHT: All projects aggregate
                projectSection(
                    label: "ALL",
                    stats: MetricsStore.shared.allStats
                )
            }

            Spacer(minLength: 4)

            // Far right: pane count + session duration
            HStack(spacing: 0) {
                Text("\(workspace.panes.count)")
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Text("p")
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Text("  ")
                Text(formattedDuration)
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(SenkaniTheme.statusBarBackground)
        .task {
            #if DEBUG
            SessionDatabase.shared.dumpTokenEvents()
            #endif
            // Keep the clock ticking for session duration display
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Project Section

    private func projectSection(label: String, stats: PaneTokenStats) -> some View {
        VStack(spacing: 0) {
            // Row 1: IN
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("IN")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .frame(width: 18, alignment: .leading)

                TokenNum(value: stats.inputTokens, color: SenkaniTheme.textSecondary)

                Spacer().frame(width: 6)

                TokenNum(value: stats.savedTokens, color: SenkaniTheme.savingsGreen)

                Spacer().frame(width: 6)

                DollarNum(amount: costForTokens(stats.inputTokens, input: true),
                          color: SenkaniTheme.textSecondary)

                Spacer().frame(width: 6)

                DollarNum(amount: costForTokens(stats.savedTokens, input: true),
                          color: SenkaniTheme.savingsGreen)
            }
            .padding(.horizontal, 8)
            .frame(height: 17)

            // Row 2: OUT
            HStack(spacing: 0) {
                Color.clear.frame(width: 72) // spacer matching label width

                Text("OUT")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .frame(width: 18, alignment: .leading)

                TokenNum(value: stats.outputTokens, color: SenkaniTheme.textSecondary)

                Spacer().frame(width: 6)

                TokenNum(value: 0, color: SenkaniTheme.savingsGreen) // OUT saved: 0 until terse tracking

                Spacer().frame(width: 6)

                DollarNum(amount: costForTokens(stats.outputTokens, input: false),
                          color: SenkaniTheme.textSecondary)

                Spacer().frame(width: 6)

                DollarNum(amount: 0.0, color: SenkaniTheme.savingsGreen)
            }
            .padding(.horizontal, 8)
            .frame(height: 17)
        }
    }

    private func costForTokens(_ tokens: Int, input: Bool) -> Double {
        let rate = input ? pricing.inputPerMillion : pricing.outputPerMillion
        return Double(tokens) / 1_000_000.0 * rate
    }

    private var formattedDuration: String {
        let elapsed = now.timeIntervalSince(workspace.sessionStart)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        }
        return "\(minutes)m \(String(format: "%02d", seconds))s"
    }
}

// MARK: - Compact Token Display

/// Compact token number: 000,000,000 with dimmed leading zeros.
struct TokenNum: View {
    let value: Int
    let color: Color

    private var formatted: String {
        let clamped = min(abs(value), 999_999_999)
        let s = String(format: "%09d", clamped)
        var r = ""
        for (i, c) in s.enumerated() {
            if i > 0 && (9 - i) % 3 == 0 { r.append(",") }
            r.append(c)
        }
        return r
    }

    private var firstSig: Int {
        for (i, c) in formatted.enumerated() {
            if c != "0" && c != "," { return i }
        }
        return formatted.count
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(formatted.enumerated()), id: \.offset) { idx, char in
                Text(String(char))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        char == "," ? color.opacity(0.15)
                        : idx < firstSig ? color.opacity(0.12)
                        : color
                    )
            }
        }
    }
}

/// Compact dollar display: $00,000.00 with dimmed leading zeros.
struct DollarNum: View {
    let amount: Double
    let color: Color

    private var parts: (intFormatted: String, decimal: String) {
        let clamped = min(abs(amount), 99_999.99)
        let intPart = Int(clamped)
        let fracPart = Int((clamped - Double(intPart)) * 100 + 0.5)
        let intStr = String(format: "%05d", intPart)
        var result = ""
        for (i, char) in intStr.enumerated() {
            if i > 0 && (5 - i) % 3 == 0 { result.append(",") }
            result.append(char)
        }
        return (result, String(format: ".%02d", fracPart))
    }

    private var firstSig: Int {
        let str = parts.intFormatted
        for (i, c) in str.enumerated() {
            if c != "0" && c != "," { return i }
        }
        return str.count
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("$")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(color.opacity(0.2))

            ForEach(Array(parts.intFormatted.enumerated()), id: \.offset) { idx, char in
                Text(String(char))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        char == "," ? color.opacity(0.15)
                        : idx < firstSig ? color.opacity(0.12)
                        : color
                    )
            }

            Text(parts.decimal)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    parts.decimal == ".00" ? color.opacity(0.12) : color
                )
        }
    }
}
