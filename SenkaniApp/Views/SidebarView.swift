import SwiftUI
import Core
import MCPServer

/// Redesigned sidebar: global tools at top, expandable project list with
/// inline pane entries and token usage, add project at bottom.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Binding var activeToolView: ToolView?
    let onRequestAddPane: () -> Void
    /// Launch a pane through the parent's `LaunchCoordinator`. The
    /// sidebar must NOT call `workspace.addPane(...)` directly —
    /// doing so skipped hook + session setup and was the original
    /// motivation for the LaunchCoordinator round.
    let onLaunchPane: (PaneType, String, String) -> Void
    /// V.3d — the observed pane-metadata resolver. The per-pane row reads the
    /// last cached `PaneMetadata` snapshot for a pane via the synchronous
    /// cache-hit `metadata(for:)` hover path (never blocks on a probe or DB).
    /// `ContentView` constructs the resolver (wired to the real
    /// `PaneMetadataProbes` + `PaneMetadataRefreshCoordinator` in
    /// `PaneMetadataWiring`) and passes it in here. Chip rendering + the hover
    /// popover keyed off this snapshot are OUT OF SCOPE this round — the
    /// sibling `phase-v3d-sidebar-chips-popover-visual-walk` Cowork walk
    /// validates those; this scaffold only establishes the read seam.
    let paneMetadataResolver: PaneMetadataResolver
    @State private var showClaudeLaunch = false
    @State private var enrichmentBadge: Int = 0
    @State private var hoveredProjectID: UUID?
    @State private var removalTarget: ProjectModel?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: - Global Tools
                    sectionHeader("TOOLS")

                    toolRow(icon: "puzzlepiece.extension", label: "Skills", isActive: activeToolView == .skills) {
                        activateTool(.skills)
                    }
                    toolRow(icon: "paintpalette", label: "Themes", isActive: activeToolView == .themes) {
                        activateTool(.themes)
                    }
                    toolRow(icon: "brain", label: "Models", isActive: activeToolView == .models) {
                        activateTool(.models)
                    }
                    toolRow(icon: "calendar.badge.clock", label: "Schedules", isActive: activeToolView == .schedules) {
                        activateTool(.schedules)
                    }
                    HStack(spacing: 0) {
                        toolRow(icon: "brain.head.profile", label: "Knowledge",
                                isActive: activeToolView == .knowledge) {
                            activateTool(.knowledge)
                        }
                        if enrichmentBadge > 0 {
                            Text("\(enrichmentBadge)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.orange))
                                .padding(.trailing, 8)
                                .help("\(enrichmentBadge) enrichment candidate(s)")
                        }
                    }
                    toolRow(icon: "exclamationmark.triangle", label: "Trust Flags",
                            isActive: activeToolView == .trustFlags) {
                        activateTool(.trustFlags)
                    }
                    toolRow(icon: "bell.badge", label: "Notifications",
                            isActive: activeToolView == .notifications) {
                        activateTool(.notifications)
                    }
                    toolRow(icon: "heart.text.square", label: "Provider Health",
                            isActive: activeToolView == .providerHealth) {
                        activateTool(.providerHealth)
                    }

                    // Thin divider
                    Rectangle()
                        .fill(SenkaniTheme.inactiveBorder.opacity(0.3))
                        .frame(height: 1)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)

                    // MARK: - Projects
                    sectionHeader("PROJECTS")

                    if workspace.projects.isEmpty {
                        // No projects yet — prompt to add one
                        Text("No projects yet")
                            .font(.system(size: 10))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(workspace.projects) { project in
                            VStack(alignment: .leading, spacing: 0) {
                                projectRow(project)

                                // MARK: - V.3d per-pane row sub-list
                                // One row per pane inside the project row —
                                // structurally absent before this wiring bridge
                                // (the only prior `ForEach` was
                                // `ForEach(workspace.projects)`). Each row reads
                                // the pane's cached `PaneMetadata` snapshot via
                                // the observed resolver. Chip content + hover
                                // popover are OUT OF SCOPE (sibling visual walk).
                                ForEach(project.panes) { pane in
                                    paneRow(pane)
                                }
                            }
                        }
                    }

                    // Add Project button
                    addProjectRow
                        .padding(.top, 4)
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            // MARK: - Bottom bar: add pane + settings gear
            VStack(spacing: 0) {
                Rectangle()
                    .fill(SenkaniTheme.inactiveBorder.opacity(0.3))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    addPaneButton
                    Spacer()
                    themeGearButton
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(width: SenkaniTheme.sidebarWidth)
        .background(SenkaniTheme.sidebarBackground)
        .task {
            enrichmentBadge = await KBReader.tracker.state().enrichmentCandidates.count
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { @MainActor in
                enrichmentBadge = await KBReader.tracker.state().enrichmentCandidates.count
            }
        }
        .onChange(of: workspace.activePaneID) { _, newValue in
            if newValue != nil {
                clearToolSelection()
            }
        }
        .sheet(item: $removalTarget) { project in
            ProjectRemoveSheet(project: project, workspace: workspace)
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .default))
            .foregroundStyle(SenkaniTheme.textTertiary)
            .tracking(1.2)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    // MARK: - Tool row

    private func toolRow(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? SenkaniTheme.accentAnalytics : SenkaniTheme.textTertiary)
                    .frame(width: 14)

                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isActive ? SenkaniTheme.accentAnalytics.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Project row (health-focused)

    private func projectRow(_ project: ProjectModel) -> some View {
        Button {
            workspace.switchToProject(id: project.id)
            clearToolSelection()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Row 1: project name + git branch + hover-revealed remove X
                HStack(spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 11, weight: project.isActive ? .semibold : .regular))
                        .foregroundStyle(project.isActive ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)
                        .lineLimit(1)

                    if let branch = project.gitBranch {
                        Text(branch)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.cyan.opacity(0.1)))
                            .lineLimit(1)
                    }

                    Spacer()

                    if hoveredProjectID == project.id {
                        Button {
                            removalTarget = project
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove project…")
                    }
                }

                // Row 2–3: metrics grid
                HStack(spacing: 0) {
                    // Labels column
                    VStack(alignment: .leading, spacing: 2) {
                        Text("saved")
                            .foregroundStyle(SenkaniTheme.textTertiary)
                        Text("processed")
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }
                    .font(.system(size: 9, design: .monospaced))

                    Spacer()

                    // Values column (right-aligned) — reads from DB via MetricsStore
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formattedTokens(MetricsStore.shared.stats(for: project.path).savedTokens))
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                        Text(formattedTokens(MetricsStore.shared.stats(for: project.path).inputTokens))
                            .foregroundStyle(SenkaniTheme.textSecondary)
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                }

                // Row 4: status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(projectStatusColor(project))
                        .frame(width: 5, height: 5)
                    Text(projectStatusLabel(project))
                        .font(.system(size: 9))
                        .foregroundStyle(projectStatusColor(project))

                    if project.totalSecretsCaught > 0 {
                        Spacer()
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(SenkaniTheme.toggleSecrets)
                        Text("\(project.totalSecretsCaught)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.toggleSecrets)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(project.isActive ? SenkaniTheme.accentAnalytics.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredProjectID = inside ? project.id : (hoveredProjectID == project.id ? nil : hoveredProjectID)
        }
    }

    // MARK: - Per-pane row (V.3d scaffold)

    /// One row per pane inside the project row. Reads the last cached
    /// `PaneMetadata` snapshot for the pane through the observed
    /// `PaneMetadataResolver` (synchronous cache-hit hover path — never blocks
    /// on a probe or DB). This scaffold establishes the row structure + the
    /// resolver read seam ONLY. The chip content (port / branch / PR pills),
    /// the hover popover (content + redaction), the PR-chip click, and the
    /// perceived <100ms p95 render timing are explicitly OUT OF SCOPE for this
    /// wiring bridge — the sibling
    /// `phase-v3d-sidebar-chips-popover-visual-walk` Cowork walk validates
    /// them. The metadata snapshot is read here so the wiring seam is
    /// exercised; the rendered chip pills are deferred.
    private func paneRow(_ pane: PaneModel) -> some View {
        let metadata = paneMetadataResolver.metadata(for: pane.id.uuidString)
        return HStack(spacing: 4) {
            Image(systemName: "chevron.forward")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(width: 10)

            Text(pane.title)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .lineLimit(1)

            Spacer()

            // Chip slot — populated by the sibling visual-walk round. The
            // metadata snapshot is READ here (exercising the resolver seam);
            // the port/branch/PR pills + hover popover are deferred to that
            // walk, so a present snapshot only surfaces a neutral placeholder
            // dot for now.
            if metadata != nil {
                Circle()
                    .fill(SenkaniTheme.accentAnalytics.opacity(0.4))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Project status helpers

    private func projectStatusColor(_ project: ProjectModel) -> Color {
        let running = project.runningPaneCount
        if running > 0 { return SenkaniTheme.savingsGreen }
        if project.panes.isEmpty { return SenkaniTheme.textTertiary }
        // Check if any exited with error
        if project.panes.contains(where: {
            if case .exited(let code) = $0.processState, code != 0 { return true }
            return false
        }) {
            return .red.opacity(0.7)
        }
        return SenkaniTheme.accentAnalytics.opacity(0.5)
    }

    private func projectStatusLabel(_ project: ProjectModel) -> String {
        let running = project.runningPaneCount
        let total = project.panes.count
        if total == 0 { return "no panes" }
        if running > 0 { return "\(running) running" }
        if project.panes.contains(where: {
            if case .exited(let code) = $0.processState, code != 0 { return true }
            return false
        }) {
            return "error"
        }
        return "idle"
    }

    private func formattedTokens(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fk", Double(bytes) / 1_000) }
        if bytes > 0 { return "\(bytes)" }
        return "—"
    }

    // MARK: - Add Project row (inline, not in bottom bar)

    private var addProjectRow: some View {
        Button {
            openFolderPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .frame(width: 14)

                Text("Add Project")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add pane menu

    private var addPaneButton: some View {
        Menu {
            Button("Claude Code...") {
                showClaudeLaunch = true
            }
            Button("New Pane...") {
                onRequestAddPane()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Add Pane")
                    .font(.system(size: 10))
            }
            .foregroundStyle(SenkaniTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $showClaudeLaunch) {
            ClaudeLaunchSheet { command in
                onLaunchPane(.terminal, "Claude Code", command)
            }
        }
    }

    // MARK: - Theme gear

    private var themeGearButton: some View {
        Button {
            activateTool(.themes)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10))
                .foregroundStyle(activeToolView == .themes ? SenkaniTheme.accentAnalytics : SenkaniTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help("Theme Settings")
    }

    // MARK: - Helpers

    /// Clear tool selection (return to workspace view).
    private func clearToolSelection() {
        activeToolView = nil
    }

    /// Activate a tool view in the canvas.
    private func activateTool(_ tool: ToolView) {
        activeToolView = tool
        workspace.activePaneID = nil
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        if panel.runModal() == .OK, let url = panel.url {
            workspace.addProject(path: url.path)
        }
    }
}
