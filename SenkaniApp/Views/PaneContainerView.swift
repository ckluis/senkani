import SwiftUI
import Core

/// Wraps a pane with a minimal, premium shell: thin accent line, compact 24px header,
/// status dot, contextual info, and FCSIT toggles.
/// No dim overlay — focus is communicated through border color only.
/// Token metrics are in the app-level StatusBarView, not per-pane.
struct PaneContainerView: View {
    @Bindable var pane: PaneModel
    let isActive: Bool
    var workspace: WorkspaceModel?
    @State private var showSettings = false
    @State private var showFeatureDrawer = false
    @State private var selectedFeature: String?

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

            // FCSIT detail drawer — expandable per-feature breakdown
            if showFeatureDrawer, let feature = selectedFeature {
                FeatureDetailDrawer(featureKey: feature, pane: pane)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                Rectangle()
                    .fill(SenkaniTheme.appBackground)
                    .frame(height: 0.5)
            }

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
            // Process state dot — pulses when running, blue ring when unread output
            ZStack {
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

                if pane.hasUnreadOutput && !isActive {
                    Circle()
                        .stroke(Color.blue, lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .transition(.scale)
                }
            }
            .frame(width: 10, height: 10)
            .onChange(of: isActive) { _, newActive in
                if newActive { pane.hasUnreadOutput = false }
            }

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

            // Model routing preset — terminal panes only
            if pane.paneType == .terminal {
                Menu {
                    ForEach(ModelPreset.allCases, id: \.self) { preset in
                        Button {
                            pane.modelPreset = preset
                        } label: {
                            HStack {
                                Image(systemName: preset.icon)
                                Text(preset.displayName)
                                if preset != .local {
                                    let tier = ModelRouter.resolve(prompt: "", preset: preset).tier
                                    Text(String(format: "~$%.2f/hr", tier.estimatedCostPerHour))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("$0/hr").foregroundStyle(.secondary)
                                }
                                if pane.modelPreset == preset {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(pane.modelPreset.displayName)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(presetColor(pane.modelPreset))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(presetColor(pane.modelPreset).opacity(0.1))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Model routing: \(pane.modelPreset.description)")
            }

            // Process lifecycle controls — terminal panes only
            if pane.paneType == .terminal {
                if pane.processState.isRunning, let pid = pane.shellPid, pid > 0 {
                    Button {
                        kill(pid, SIGTERM)
                        // SIGKILL fallback after 3 seconds if still alive
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if pane.processState.isRunning { kill(pid, SIGKILL) }
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop process (PID \(pid))")
                }

                if case .exited = pane.processState {
                    Button {
                        // Reset state — the terminal view will restart on next layout
                        pane.processState = .notStarted
                        pane.shellPid = nil
                        pane.budgetStatus = .none  // clear budget indicator on restart
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Restart shell")
                }
            }

            // Per-pane budget status indicator — persistent until pane restart
            if pane.paneType == .terminal {
                switch pane.budgetStatus {
                case .none:
                    EmptyView()
                case .warning(let spent, let limit):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .help("Approaching pane budget: $\(String(format: "%.2f", Double(spent) / 100)) / $\(String(format: "%.2f", Double(limit) / 100))")
                case .blocked(let spent, let limit):
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.red)
                        Text("$\(String(format: "%.2f", Double(spent) / 100))/$\(String(format: "%.2f", Double(limit) / 100))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    .help("Pane session budget exceeded — tool calls blocked")
                }
            }

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

            // FCSIT feature toggles — tap letter to toggle, long-press to show detail drawer
            HStack(spacing: 4) {
                featureButton("F", key: "filter", isOn: $pane.features.filter, color: SenkaniTheme.toggleFilter)
                featureButton("C", key: "cache", isOn: $pane.features.cache, color: SenkaniTheme.toggleCache)
                featureButton("S", key: "secrets", isOn: $pane.features.secrets, color: SenkaniTheme.toggleSecrets)
                featureButton("I", key: "indexer", isOn: $pane.features.indexer, color: SenkaniTheme.toggleIndexer)
                featureButton("T", key: "terse", isOn: $pane.features.terse, color: SenkaniTheme.toggleTerse)
            }

            // Disclosure chevron for feature drawer
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if showFeatureDrawer {
                        showFeatureDrawer = false
                    } else {
                        selectedFeature = selectedFeature ?? "filter"
                        showFeatureDrawer = true
                    }
                }
            } label: {
                Image(systemName: showFeatureDrawer ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(showFeatureDrawer ? SenkaniTheme.textPrimary : SenkaniTheme.textTertiary)
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Feature detail drawer")

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
                    .padding(15)
                    .contentShape(Rectangle())
                    .padding(-15)
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
                environment: pane.features.environmentVars
                    .merging(PaneLaunchEnv.terminal(PaneLaunchEnv.Inputs(
                        paneID: pane.id,
                        projectRoot: pane.workingDirectory,
                        metricsFilePath: pane.metricsFilePath,
                        configFilePath: pane.configFilePath,
                        workspaceSlug: paneDiaryWorkspaceSlug(pane.workingDirectory),
                        paneSlug: pane.paneType.rawValue,
                        filterOn: pane.features.filter,
                        cacheOn: pane.features.cache,
                        secretsOn: pane.features.secrets,
                        indexerOn: pane.features.indexer,
                        terseOn: pane.features.terse
                    ))) { _, new in new }
                    .merging([
                        // Terminal-only extras (model routing) layered on top.
                        "CLAUDE_MODEL":         resolvedClaudeModel,
                        "SENKANI_MODEL_PRESET": pane.modelPreset.rawValue,
                    ]) { _, new in new },
                workingDirectory: pane.workingDirectory,
                isActive: isActive,
                fontSize: pane.fontSize,
                fontFamily: pane.fontFamily,
                onProcessExited: { code in
                    pane.processState = .exited(code)
                    pane.shellPid = nil
                },
                onProcessStarted: { pid in
                    pane.shellPid = pid
                    pane.processState = .running
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
        case .codeEditor:
            CodeEditorPane(pane: pane)
        case .dashboard:
            DashboardView(workspace: workspace)
        case .sprintReview:
            SprintReviewPane(workspace: workspace)
        case .ollamaLauncher:
            OllamaLauncherPane(pane: pane, isActive: isActive)
                .onChange(of: pane.features) { _, _ in pane.features.persist(to: pane.configFilePath) }
        }
    }

    // MARK: - Feature Button

    /// Feature toggle that also selects the feature for the detail drawer.
    /// Tap toggles the feature. Option-click opens the detail drawer for that feature.
    private func featureButton(_ label: String, key: String, isOn: Binding<Bool>, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(isOn.wrappedValue ? color : SenkaniTheme.textTertiary.opacity(0.5))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isOn.wrappedValue ? color.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(selectedFeature == key && showFeatureDrawer ? color.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isOn.wrappedValue.toggle()
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if selectedFeature == key && showFeatureDrawer {
                            showFeatureDrawer = false
                        } else {
                            selectedFeature = key
                            showFeatureDrawer = true
                        }
                    }
                }
            )
            .help("Tap to toggle \(key). Double-click for details.")
    }

    // MARK: - Helpers

    private func presetColor(_ preset: ModelPreset) -> Color {
        switch preset {
        case .auto: return .cyan
        case .build: return .orange
        case .research: return .purple
        case .quick: return .green
        case .local: return .blue
        }
    }

    private var resolvedClaudeModel: String {
        let gemma4Available = false // TODO: check ModelManager when accessible from app target
        let result = ModelRouter.resolve(prompt: "", preset: pane.modelPreset, gemma4Downloaded: gemma4Available)
        return result.tier.claudeModelValue
    }

    /// Derive the pane diary workspace slug from a pane's working
    /// directory. Mirrors `MCPSession.fallbackMetricsPath`'s suffix-2
    /// joined-with-"-" convention so `~/senkani` and
    /// `~/clones/senkani` don't collide on disk. Slashes, `..`, and
    /// empty components are stripped before joining — `PaneDiaryStore`
    /// hard-rejects those and we don't want the MCP subprocess to
    /// never-load a diary because of an unusual path shape.
    private func paneDiaryWorkspaceSlug(_ workingDirectory: String) -> String {
        let parts = workingDirectory
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { $0 != ".." && !$0.contains("\\") }
        let tail = parts.suffix(2)
        let joined = tail.joined(separator: "-")
        return joined.isEmpty ? "workspace" : joined
    }

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
        case .codeEditor:
            let file = (pane.previewFilePath as NSString).lastPathComponent
            return file.isEmpty ? "code" : file
        case .dashboard:
            return "\(workspace?.projects.count ?? 0) projects"
        case .sprintReview:
            return "review"
        case .ollamaLauncher:
            return pane.ollamaDefaultModel
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
