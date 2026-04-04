import SwiftUI

/// Ultra-compact inline savings bar at the bottom of each pane.
/// 18px height. Format: "12.4K  72%  $0.03  F C S I"
/// All monospaced, 9px. Savings in green, rest dim.
struct SavingsBarView: View {
    @Bindable var pane: PaneModel

    var body: some View {
        HStack(spacing: 0) {
            // Savings amount (green accent)
            Text(pane.metrics.formattedSavings)
                .foregroundStyle(SenkaniTheme.savingsGreen)

            fixedSpacer

            // Savings percentage
            Text(pane.metrics.formattedPercent)
                .foregroundStyle(SenkaniTheme.textTertiary)

            fixedSpacer

            // Estimated cost
            Text(estimatedCost)
                .foregroundStyle(SenkaniTheme.textTertiary)

            fixedSpacer

            // Feature toggles: F C S I
            HStack(spacing: 4) {
                FeatureToggle(label: "F", isOn: $pane.features.filter, color: SenkaniTheme.toggleFilter)
                FeatureToggle(label: "C", isOn: $pane.features.cache, color: SenkaniTheme.toggleCache)
                FeatureToggle(label: "S", isOn: $pane.features.secrets, color: SenkaniTheme.toggleSecrets)
                FeatureToggle(label: "I", isOn: $pane.features.indexer, color: SenkaniTheme.toggleIndexer)
            }

            Spacer()

            // Command count (if any)
            if pane.metrics.commandCount > 0 {
                Text("\(pane.metrics.commandCount)")
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(height: SenkaniTheme.savingsBarHeight)
        .background(SenkaniTheme.paneShell)
    }

    private var fixedSpacer: some View {
        Text("  ")
    }

    private var estimatedCost: String {
        let tokens = Double(pane.metrics.savedBytes) / 4.0
        let cost = (tokens / 1_000_000) * 3.0
        return String(format: "$%.3f", cost)
    }
}

/// A small toggle letter for a feature flag.
struct FeatureToggle: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color
    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? color : SenkaniTheme.textTertiary.opacity(0.5))
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isOn ? color.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .help(featureTooltip)
    }

    private var featureTooltip: String {
        let state = isOn ? "ON" : "OFF"
        switch label {
        case "F": return "Filter (\(state)): Strip ANSI codes, compress output (saves 60-90%)"
        case "C": return "Cache (\(state)): Skip re-reading unchanged files (saves 50-99%)"
        case "S": return "Secrets (\(state)): Auto-redact API keys and tokens"
        case "I": return "Indexer (\(state)): Symbol-level code navigation (saves 95%)"
        default: return "\(label): \(state)"
        }
    }
}
