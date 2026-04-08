import SwiftUI
import Core

/// Redesigned sidebar: global tools at top, expandable project list with
/// inline pane entries and token usage, add project at bottom.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Binding var activeToolView: ToolView?
    @State private var showClaudeLaunch = false

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
                            projectRow(project)
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
        .onChange(of: workspace.activePaneID) { _, newValue in
            if newValue != nil {
                clearToolSelection()
            }
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
                // Row 1: project name
                Text(project.name)
                    .font(.system(size: 11, weight: project.isActive ? .semibold : .regular))
                    .foregroundStyle(project.isActive ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)
                    .lineLimit(1)

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
        .contextMenu {
            Button("Remove Project") {
                workspace.removeProject(id: project.id)
            }
        }
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
            Button("Claude Code") {
                showClaudeLaunch = true
            }
            Button("Shell") {
                workspace.addPane(title: "Terminal", command: "")
            }
            Divider()
            Button("Markdown Preview") {
                workspace.addPane(type: .markdownPreview, title: "Markdown")
            }
            Button("HTML Preview") {
                workspace.addPane(type: .htmlPreview, title: "HTML")
            }
            Divider()
            Button("Skill Library") {
                workspace.addPane(type: .skillLibrary, title: "Skills")
            }
            Button("Knowledge Base") {
                workspace.addPane(type: .knowledgeBase, title: "Knowledge")
            }
            Button("Analytics") {
                workspace.addPane(type: .analytics, title: "Analytics")
            }
            Button("Model Manager") {
                workspace.addPane(type: .modelManager, title: "Models")
            }
            Button("Schedules") {
                workspace.addPane(type: .scheduleManager, title: "Schedules")
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
                workspace.addPane(title: "Claude Code", command: command)
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
