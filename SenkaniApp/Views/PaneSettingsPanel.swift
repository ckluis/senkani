import SwiftUI

/// Settings panel that overlays the pane body when the gear icon is clicked.
/// Uses a list-detail pattern for scalability.
struct PaneSettingsPanel: View {
    @Bindable var pane: PaneModel
    @Binding var isPresented: Bool
    @State private var selectedSection: SettingsSection = .optimization

    enum SettingsSection: String, CaseIterable {
        case optimization = "Optimization"
        case display = "Display"
        case sizing = "Sizing"
        case advanced = "Advanced"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Section list (left)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack {
                            Image(systemName: iconForSection(section))
                                .font(.system(size: 10))
                                .frame(width: 16)
                            Text(section.rawValue)
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedSection == section
                            ? SenkaniTheme.accentColor(for: pane.paneType).opacity(0.15)
                            : Color.clear)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedSection == section
                        ? SenkaniTheme.textPrimary
                        : SenkaniTheme.textSecondary)
                }
                Spacer()
            }
            .frame(width: 140)
            .padding(8)
            .background(SenkaniTheme.paneShell)

            Rectangle()
                .fill(SenkaniTheme.appBackground)
                .frame(width: 0.5)

            // Detail (right)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedSection {
                    case .optimization:
                        optimizationSettings
                    case .display:
                        displaySettings
                    case .sizing:
                        sizingSettings
                    case .advanced:
                        advancedSettings
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SenkaniTheme.paneBody)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    // MARK: - Optimization Section

    private var optimizationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Optimization")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textPrimary)

            SettingsToggleRow(title: "Filter", subtitle: "Strip ANSI codes, compress output (saves 60-90%)",
                              isOn: $pane.features.filter, color: SenkaniTheme.toggleFilter)
            SettingsToggleRow(title: "Cache", subtitle: "Skip re-reading unchanged files (saves 50-99%)",
                              isOn: $pane.features.cache, color: SenkaniTheme.toggleCache)
            SettingsToggleRow(title: "Secrets", subtitle: "Auto-redact API keys and tokens before model sees them",
                              isOn: $pane.features.secrets, color: SenkaniTheme.toggleSecrets)
            SettingsToggleRow(title: "Indexer", subtitle: "Symbol-level code search instead of file reads (saves 95%)",
                              isOn: $pane.features.indexer, color: SenkaniTheme.toggleIndexer)
            SettingsToggleRow(title: "Terse Mode", subtitle: "Minimize agent output verbosity (saves 50-75%)",
                              isOn: $pane.features.terse, color: SenkaniTheme.toggleTerse)
        }
    }

    // MARK: - Display Section

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Display")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textPrimary)

            Text("Font size, color overrides, and terminal appearance")
                .font(.system(size: 11))
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
    }

    // MARK: - Sizing Section

    private var sizingSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sizing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textPrimary)

            HStack {
                Text("Column width")
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Spacer()
                Text("\(Int(pane.columnWidth))px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textSecondary)
            }
            Slider(value: $pane.columnWidth, in: 280...800, step: 20)

            HStack {
                Text("Width presets")
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Spacer()
            }
            HStack(spacing: 6) {
                SizePresetButton(label: "Narrow", value: 260, current: $pane.columnWidth)
                SizePresetButton(label: "Default", value: 300, current: $pane.columnWidth)
                SizePresetButton(label: "Medium", value: 400, current: $pane.columnWidth)
                SizePresetButton(label: "Wide", value: 520, current: $pane.columnWidth)
                SizePresetButton(label: "XWide", value: 700, current: $pane.columnWidth)
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Metrics file:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Text(pane.metricsFilePath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Config file:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Text(pane.configFilePath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Working directory:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Text(pane.workingDirectory)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func iconForSection(_ section: SettingsSection) -> String {
        switch section {
        case .optimization: return "slider.horizontal.3"
        case .display: return "paintbrush"
        case .sizing: return "arrow.left.and.right"
        case .advanced: return "wrench"
        }
    }
}

// MARK: - Settings Toggle Row

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(color)
        }
    }
}

// MARK: - Size Preset Button

private struct SizePresetButton: View {
    let label: String
    let value: CGFloat
    @Binding var current: CGFloat

    private var isSelected: Bool { abs(current - value) < 1 }

    var body: some View {
        Button {
            current = value
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? SenkaniTheme.accentTerminal.opacity(0.2) : SenkaniTheme.paneShell)
                )
                .foregroundStyle(isSelected ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}
