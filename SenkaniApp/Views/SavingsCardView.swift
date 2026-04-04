import SwiftUI

/// The card header above each terminal pane showing feature toggles and live savings.
struct SavingsCardView: View {
    @Bindable var pane: PaneModel

    var body: some View {
        HStack(spacing: 12) {
            // Feature toggles
            HStack(spacing: 6) {
                FeatureToggle(label: "F", isOn: $pane.features.filter, color: .blue)
                FeatureToggle(label: "C", isOn: $pane.features.cache, color: .green)
                FeatureToggle(label: "S", isOn: $pane.features.secrets, color: .orange)
                FeatureToggle(label: "I", isOn: $pane.features.indexer, color: .purple)
            }

            Spacer()

            // Live savings counter
            HStack(spacing: 4) {
                Text("閃")
                    .font(.system(size: 12))
                Text("\(pane.metrics.formattedSavings) saved")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("(\(pane.metrics.formattedPercent))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Command count
            if pane.metrics.commandCount > 0 {
                Text("\(pane.metrics.commandCount) calls")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

/// A small toggle button for a feature flag.
struct FeatureToggle: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? .white : .secondary)
                .frame(width: 20, height: 18)
                .background(isOn ? color.opacity(0.8) : Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help("\(label == "F" ? "Filter" : label == "C" ? "Cache" : label == "S" ? "Secrets" : "Indexer"): \(isOn ? "ON" : "OFF")")
    }
}
