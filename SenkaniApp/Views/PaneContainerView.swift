import SwiftUI

/// Wraps a pane with its savings card header and focus indicator.
struct PaneContainerView: View {
    @Bindable var pane: PaneModel
    let isActive: Bool
    var workspace: WorkspaceModel?

    var body: some View {
        VStack(spacing: 0) {
            SavingsCardView(pane: pane)

            Divider()

            switch pane.paneType {
            case .terminal:
                TerminalViewRepresentable(
                    shellPath: pane.shellCommand,
                    environment: pane.features.environmentVars.merging([
                        "SENKANI_METRICS_FILE": pane.metricsFilePath,
                        "SENKANI_CONFIG_FILE": pane.configFilePath,
                        "TERM": "xterm-256color",
                    ]) { _, new in new },
                    workingDirectory: NSHomeDirectory(),
                    isActive: isActive,
                    onProcessExited: { code in
                        pane.processState = .exited(code)
                    }
                )
                .onAppear {
                    pane.processState = .running
                }
                .onChange(of: pane.features) { _, _ in pane.features.persist(to: pane.configFilePath) }
            case .analytics:
                if let workspace = workspace {
                    AnalyticsView(workspace: workspace)
                } else {
                    AnalyticsPlaceholderView(pane: pane)
                }
            case .markdownPreview:
                MarkdownPreviewView(pane: pane)
            case .htmlPreview:
                HTMLPreviewView(pane: pane)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
        )
    }
}

struct AnalyticsPlaceholderView: View {
    let pane: PaneModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Analytics")
                .font(.headline)
            Text("\(pane.metrics.commandCount) commands tracked")
                .font(.caption)
                .foregroundStyle(.secondary)
            if pane.metrics.savedBytes > 0 {
                Text("\(pane.metrics.formattedSavings) saved (\(pane.metrics.formattedPercent))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

struct PreviewPlaceholderView: View {
    let pane: PaneModel

    var body: some View {
        VStack {
            Image(systemName: "doc.richtext")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Preview pane — drop a file or select from sidebar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}
