import SwiftUI

/// Wraps a pane with a Flock-inspired shell: accent line, header, inset body,
/// focus dimming, and an inline savings bar at the bottom.
struct PaneContainerView: View {
    @Bindable var pane: PaneModel
    let isActive: Bool
    var workspace: WorkspaceModel?

    var body: some View {
        VStack(spacing: 0) {
            // Accent line at the very top, colored by pane type
            Rectangle()
                .fill(SenkaniTheme.accentColor(for: pane.paneType))
                .frame(height: SenkaniTheme.accentLineHeight)

            // 32px header: type icon + title + close button
            paneHeader

            // Separator between header and body
            Rectangle()
                .fill(SenkaniTheme.appBackground)
                .frame(height: 1)

            // Inset body (darker than shell)
            paneBody
                .background(SenkaniTheme.paneBody)

            // Inline savings bar at the bottom
            SavingsBarView(pane: pane)
        }
        .background(SenkaniTheme.paneShell)
        .cornerRadius(SenkaniTheme.paneCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: SenkaniTheme.paneCornerRadius)
                .stroke(
                    isActive ? SenkaniTheme.focusBorder : SenkaniTheme.inactiveBorder,
                    lineWidth: isActive ? 1.5 : 0.5
                )
                .allowsHitTesting(false)
        )
        // Dim overlay on inactive panes — MUST NOT block hits
        .overlay(
            RoundedRectangle(cornerRadius: SenkaniTheme.paneCornerRadius)
                .fill(isActive ? Color.clear : SenkaniTheme.dimOverlay)
                .allowsHitTesting(false)
        )
        .animation(SenkaniTheme.focusAnimation, value: isActive)
    }

    // MARK: - Header

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: SenkaniTheme.iconName(for: pane.paneType))
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.accentColor(for: pane.paneType))

            Text(pane.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SenkaniTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            // Process state dot (terminal panes only)
            if pane.paneType == .terminal {
                Circle()
                    .fill(processStateColor)
                    .frame(width: 5, height: 5)
            }

            Button {
                workspace?.removePane(id: pane.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Close pane")
        }
        .padding(.horizontal, 10)
        .frame(height: SenkaniTheme.headerHeight)
        .background(SenkaniTheme.paneShell)
    }

    // MARK: - Body

    @ViewBuilder
    private var paneBody: some View {
        switch pane.paneType {
        case .terminal:
            TerminalViewRepresentable(
                paneId: pane.id,
                shellPath: pane.shellCommand,
                environment: pane.features.environmentVars.merging([
                    "SENKANI_METRICS_FILE": pane.metricsFilePath,
                    "SENKANI_CONFIG_FILE": pane.configFilePath,
                ]) { _, new in new },
                workingDirectory: NSHomeDirectory(),
                isActive: isActive,
                onProcessExited: { code in
                    pane.processState = .exited(code)
                },
                onActivate: {
                    workspace?.activePaneID = pane.id
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
        case .skillLibrary:
            SkillBrowserView()
        case .knowledgeBase:
            KnowledgeBaseView()
        case .modelManager:
            ModelManagerView()
        case .scheduleManager:
            ScheduleView()
        }
    }

    // MARK: - Helpers

    private var processStateColor: Color {
        switch pane.processState {
        case .notStarted: return SenkaniTheme.textTertiary
        case .running: return SenkaniTheme.accentTerminal
        case .exited(0): return SenkaniTheme.accentAnalytics
        case .exited: return .red
        }
    }
}

struct AnalyticsPlaceholderView: View {
    let pane: PaneModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Text("Analytics")
                .font(.headline)
                .foregroundStyle(SenkaniTheme.textPrimary)
            Text("\(pane.metrics.commandCount) commands tracked")
                .font(.caption)
                .foregroundStyle(SenkaniTheme.textSecondary)
            if pane.metrics.savedBytes > 0 {
                Text("\(pane.metrics.formattedSavings) saved (\(pane.metrics.formattedPercent))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.savingsGreen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SenkaniTheme.paneBody)
    }
}

struct PreviewPlaceholderView: View {
    let pane: PaneModel

    var body: some View {
        VStack {
            Image(systemName: "doc.richtext")
                .font(.system(size: 36))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Text("Preview pane -- drop a file or select from sidebar")
                .font(.caption)
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SenkaniTheme.paneBody)
    }
}
