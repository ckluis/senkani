import SwiftUI

/// Compact inline savings bar at the bottom of each pane.
/// Format: "12.4K saved | 72% | $1.24 | F C S I"
/// Replaces the old SavingsCardView header card.
struct SavingsBarView: View {
    @Bindable var pane: PaneModel

    var body: some View {
        HStack(spacing: 0) {
            // Savings amount (green accent)
            HStack(spacing: 3) {
                Text(pane.metrics.formattedSavings)
                    .foregroundStyle(SenkaniTheme.savingsGreen)
                Text("saved")
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            separator

            // Savings percentage
            Text(pane.metrics.formattedPercent)
                .foregroundStyle(SenkaniTheme.textSecondary)

            separator

            // Estimated cost
            Text(estimatedCost)
                .foregroundStyle(SenkaniTheme.textSecondary)

            separator

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
                    .padding(.leading, 4)
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(SenkaniTheme.paneShell)
    }

    private var separator: some View {
        Text(" | ")
            .foregroundStyle(SenkaniTheme.textTertiary)
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

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? color : SenkaniTheme.textTertiary)
        }
        .buttonStyle(.plain)
        .help("\(featureName): \(isOn ? "ON" : "OFF")")
    }

    private var featureName: String {
        switch label {
        case "F": return "Filter"
        case "C": return "Cache"
        case "S": return "Secrets"
        case "I": return "Indexer"
        default: return label
        }
    }
}
