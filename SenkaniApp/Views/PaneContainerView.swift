import SwiftUI

/// Wraps a pane with a minimal, premium shell: thin accent line, compact 24px header,
/// status dot, contextual info, and an 18px inline savings footer.
/// No dim overlay — focus is communicated through border color only.
struct PaneContainerView: View {
    @Bindable var pane: PaneModel
    let isActive: Bool
    var workspace: WorkspaceModel?

    var body: some View {
        VStack(spacing: 0) {
            // 1.5px accent line at the very top, colored by pane type
            Rectangle()
                .fill(accentColor.opacity(isActive ? 1.0 : 0.5))
                .frame(height: SenkaniTheme.accentLineHeight)

            // 24px header: status dot + type label + context + close
            paneHeader

            // 0.5px separator
            Rectangle()
                .fill(SenkaniTheme.appBackground)
                .frame(height: 0.5)

            // Body content
            paneBody
                .background(SenkaniTheme.paneBody)

            // 18px compact savings footer
            SavingsBarView(pane: pane)
        }
        .background(SenkaniTheme.paneShell)
        .cornerRadius(SenkaniTheme.paneCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: SenkaniTheme.paneCornerRadius)
                .stroke(
                    isActive ? accentColor.opacity(0.8) : SenkaniTheme.inactiveBorder,
                    lineWidth: isActive ? 1.0 : 0.5
                )
                .allowsHitTesting(false)
        )
        // No dim overlay — it blocks child window terminal content.
        // Focus state is communicated by accent line brightness and border color.
        .animation(SenkaniTheme.focusAnimation, value: isActive)
    }

    // MARK: - Header (24px)

    private var paneHeader: some View {
        HStack(spacing: 5) {
            // Process state dot — pulses gently when running
            Circle()
                .fill(processStateColor)
                .frame(width: 5, height: 5)
                .opacity(pane.processState.isRunning ? 1.0 : 0.7)
                .animation(
                    pane.processState.isRunning
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: pane.processState.isRunning
                )

            // Type label
            Text(pane.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SenkaniTheme.textPrimary)
                .lineLimit(1)

            // Contextual info — dim, right of title
            Text(contextLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Secret detection indicator
            if pane.features.secrets && pane.metrics.secretsCaught > 0 {
                Image(systemName: "shield.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(SenkaniTheme.toggleSecrets)
                    .help("\(pane.metrics.secretsCaught) secret(s) redacted")
            }

            // Close button
            Button {
                workspace?.removePane(id: pane.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close pane")
        }
        .padding(.horizontal, 8)
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

    private var accentColor: Color {
        SenkaniTheme.accentColor(for: pane.paneType)
    }

    /// Context label shown dim in header: working dir for terminal, item count for others.
    private var contextLabel: String {
        switch pane.paneType {
        case .terminal:
            // Show abbreviated working directory
            let home = NSHomeDirectory()
            let path = pane.previewFilePath.isEmpty ? "~" : pane.previewFilePath
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        case .analytics:
            return "\(pane.metrics.commandCount) cmds"
        case .skillLibrary:
            return "skills"
        case .knowledgeBase:
            return "knowledge"
        case .modelManager:
            return "models"
        case .scheduleManager:
            return "schedules"
        case .markdownPreview, .htmlPreview:
            let file = (pane.previewFilePath as NSString).lastPathComponent
            return file.isEmpty ? "preview" : file
        }
    }

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
