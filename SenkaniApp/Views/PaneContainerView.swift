import SwiftUI

/// Wraps a pane with a minimal, premium shell: thin accent line, compact 24px header,
/// status dot, contextual info, and FCSIT toggles.
/// No dim overlay — focus is communicated through border color only.
/// Token metrics are in the app-level StatusBarView, not per-pane.
struct PaneContainerView: View {
    @Bindable var pane: PaneModel
    let isActive: Bool
    var workspace: WorkspaceModel?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Accent line — thicker when active
            Rectangle()
                .fill(accentColor.opacity(isActive ? 1.0 : 0.5))
                .frame(height: isActive ? SenkaniTheme.activeAccentLineHeight : SenkaniTheme.accentLineHeight)

            // 24px header: status dot + title + FCSIT + gear + close
            paneHeader

            // 0.5px separator
            Rectangle()
                .fill(SenkaniTheme.appBackground)
                .frame(height: 0.5)

            // Body content (with settings overlay)
            ZStack {
                paneBody
                    .background(SenkaniTheme.paneBody)
                    .clipped()

                if showSettings {
                    PaneSettingsPanel(pane: pane, isPresented: $showSettings)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showSettings)

            // No per-pane footer — token metrics live in the app-level status bar
        }
        .background(SenkaniTheme.paneShell)
        .cornerRadius(SenkaniTheme.paneCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: SenkaniTheme.paneCornerRadius)
                .stroke(
                    isActive ? accentColor : SenkaniTheme.inactiveBorder,
                    lineWidth: isActive ? SenkaniTheme.activeBorderWidth : SenkaniTheme.inactiveBorderWidth
                )
                .allowsHitTesting(false)
        )
        // Drop shadow on active pane for depth
        .shadow(
            color: isActive ? accentColor.opacity(0.25) : .clear,
            radius: isActive ? 8 : 0
        )
        // Click anywhere to activate
        .contentShape(Rectangle())
        .onTapGesture {
            workspace?.activePaneID = pane.id
        }
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

            // Passthrough toggle — left of FCSIT, visually distinct
            Button {
                pane.features.passthrough.toggle()
            } label: {
                Image(systemName: pane.features.passthrough ? "arrow.right.circle.fill" : "arrow.right.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(pane.features.passthrough ? .red : SenkaniTheme.textTertiary.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pane.features.passthrough ? "Passthrough ON — hooks disabled" : "Passthrough OFF — hooks active")

            // FCSIT feature toggles
            HStack(spacing: 4) {
                FeatureToggleCompact(label: "F", isOn: $pane.features.filter, color: SenkaniTheme.toggleFilter)
                FeatureToggleCompact(label: "C", isOn: $pane.features.cache, color: SenkaniTheme.toggleCache)
                FeatureToggleCompact(label: "S", isOn: $pane.features.secrets, color: SenkaniTheme.toggleSecrets)
                FeatureToggleCompact(label: "I", isOn: $pane.features.indexer, color: SenkaniTheme.toggleIndexer)
                FeatureToggleCompact(label: "T", isOn: $pane.features.terse, color: SenkaniTheme.toggleTerse)
            }

            // Gear icon → settings panel
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 9))
                    .foregroundStyle(showSettings ? SenkaniTheme.textPrimary : SenkaniTheme.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pane settings")

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
        .background(isActive ? accentColor.opacity(0.08) : SenkaniTheme.paneShell)
        .onDrag {
            NSItemProvider(object: pane.id.uuidString as NSString)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var paneBody: some View {
        switch pane.paneType {
        case .terminal:
            TerminalViewRepresentable(
                paneId: pane.id,
                initialCommand: pane.initialCommand,
                environment: pane.features.environmentVars.merging([
                    "SENKANI_METRICS_FILE": pane.metricsFilePath,
                    "SENKANI_CONFIG_FILE":  pane.configFilePath,
                    "SENKANI_INTERCEPT":    "on",
                    "SENKANI_HOOK":         "on",
                    "SENKANI_PROJECT_ROOT": pane.workingDirectory,
                    "SENKANI_PANE_ID":      pane.id.uuidString,
                    // MCP-name aliases: MCPSession.resolve() reads SENKANI_MCP_*
                    "SENKANI_MCP_FILTER":   pane.features.filter  ? "on" : "off",
                    "SENKANI_MCP_CACHE":    pane.features.cache   ? "on" : "off",
                    "SENKANI_MCP_SECRETS":  pane.features.secrets ? "on" : "off",
                    "SENKANI_MCP_INDEX":    pane.features.indexer ? "on" : "off",
                    "SENKANI_MCP_TERSE":    pane.features.terse   ? "on" : "off",
                ]) { _, new in new },
                workingDirectory: pane.workingDirectory,
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
        case .browser:
            BrowserPaneView(pane: pane)
        case .diffViewer:
            DiffViewerPane(pane: pane)
        case .logViewer:
            LogViewerPane(pane: pane)
        case .scratchpad:
            ScratchpadPane(pane: pane)
        case .savingsTest:
            SavingsTestView(workspace: workspace)
        case .agentTimeline:
            AgentTimelinePane(pane: pane, workspace: workspace)
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
        case .browser:
            let url = pane.previewFilePath
            return url.isEmpty ? "browser" : url.replacingOccurrences(of: "https://", with: "").prefix(40).description
        case .diffViewer:
            return "diff"
        case .logViewer:
            return "log"
        case .scratchpad:
            return "notes"
        case .savingsTest:
            return "test suite"
        case .agentTimeline:
            return "\(pane.metrics.commandCount) events"
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
