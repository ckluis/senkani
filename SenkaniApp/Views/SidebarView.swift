import SwiftUI

/// Redesigned sidebar: global tools at top, expandable project list with
/// inline pane entries and token usage, add project at bottom.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Binding var showModels: Bool
    @Binding var showAnalytics: Bool
    @Binding var showSkills: Bool
    @Binding var showSchedules: Bool
    @Binding var showThemePicker: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: - Global Tools
                    sectionHeader("TOOLS")

                    toolRow(icon: "puzzlepiece.extension", label: "Skills", isActive: showSkills) {
                        activateTool { showSkills = true }
                    }
                    toolRow(icon: "paintpalette", label: "Themes", isActive: showThemePicker) {
                        activateTool { showThemePicker = true }
                    }
                    toolRow(icon: "brain", label: "Models", isActive: showModels) {
                        activateTool { showModels = true }
                    }
                    toolRow(icon: "calendar.badge.clock", label: "Schedules", isActive: showSchedules) {
                        activateTool { showSchedules = true }
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
                        // No projects yet — show flat pane list (backward compat)
                        ForEach(workspace.panes) { pane in
                            paneRow(pane)
                        }
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

    // MARK: - Project row (expandable)

    private func projectRow(_ project: ProjectModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header — click to expand/activate
            Button {
                workspace.switchToProject(id: project.id)
                clearToolSelection()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Expand/collapse chevron
                        Image(systemName: project.isActive ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .frame(width: 8)

                        // Project name
                        Text(project.name)
                            .font(.system(size: 11, weight: project.isActive ? .semibold : .regular))
                            .foregroundStyle(project.isActive ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        // Token savings today (right-aligned, monospaced)
                        if project.totalSavedBytes > 0 {
                            Text("\(project.formattedSavings) today")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.savingsGreen)
                        }
                    }

                    // 2px usage bar under the project name
                    if project.totalRawBytes > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(SenkaniTheme.textTertiary.opacity(0.15))
                                    .frame(height: 2)
                                Rectangle()
                                    .fill(SenkaniTheme.accentAnalytics.opacity(0.5))
                                    .frame(
                                        width: geo.size.width * min(project.savingsPercent / 100.0, 1.0),
                                        height: 2
                                    )
                            }
                        }
                        .frame(height: 2)
                        .padding(.leading, 14)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(project.isActive ? SenkaniTheme.accentAnalytics.opacity(0.06) : Color.clear)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Remove Project") {
                    workspace.removeProject(id: project.id)
                }
            }

            // Pane entries (shown when project is active/expanded)
            if project.isActive {
                ForEach(project.panes) { pane in
                    paneRow(pane)
                        .padding(.leading, 14) // indent under project
                }
            }
        }
    }

    // MARK: - Pane row

    private func paneRow(_ pane: PaneModel) -> some View {
        Button {
            workspace.activePaneID = pane.id
        } label: {
            HStack(spacing: 6) {
                // Status dot colored by process state
                Circle()
                    .fill(pane.id == workspace.activePaneID
                          ? SenkaniTheme.accentColor(for: pane.paneType)
                          : processStateColor(pane.processState))
                    .frame(width: 5, height: 5)

                // Type icon
                Image(systemName: SenkaniTheme.iconName(for: pane.paneType))
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.accentColor(for: pane.paneType).opacity(
                        pane.id == workspace.activePaneID ? 1.0 : 0.5
                    ))
                    .frame(width: 12)

                // Title
                Text(pane.title)
                    .font(.system(size: 10))
                    .foregroundStyle(pane.id == workspace.activePaneID
                                     ? SenkaniTheme.textPrimary
                                     : SenkaniTheme.textSecondary)
                    .lineLimit(1)

                Spacer()

                // Inline savings
                if pane.metrics.savedBytes > 0 {
                    Text(pane.metrics.formattedSavings)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.savingsGreen)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pane.id == workspace.activePaneID
                        ? SenkaniTheme.accentColor(for: pane.paneType).opacity(0.08)
                        : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close") {
                workspace.removePane(id: pane.id)
            }
        }
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
                workspace.addPane(title: "claude", command: "claude")
            }
            Button("Shell") {
                workspace.addPane(title: "shell", command: "/bin/zsh")
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
    }

    // MARK: - Theme gear

    private var themeGearButton: some View {
        Button {
            activateTool { showThemePicker = true }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10))
                .foregroundStyle(showThemePicker ? SenkaniTheme.accentAnalytics : SenkaniTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help("Theme Settings")
    }

    // MARK: - Helpers

    private func processStateColor(_ state: ProcessState) -> Color {
        switch state {
        case .notStarted: return SenkaniTheme.textTertiary
        case .running: return SenkaniTheme.savingsGreen.opacity(0.5)
        case .exited(0): return SenkaniTheme.accentAnalytics.opacity(0.5)
        case .exited: return .red.opacity(0.6)
        }
    }

    /// Clear all tool selections.
    private func clearToolSelection() {
        showModels = false
        showAnalytics = false
        showSkills = false
        showSchedules = false
        showThemePicker = false
    }

    /// Activate a tool by clearing everything first, then running the setter.
    private func activateTool(_ setter: () -> Void) {
        clearToolSelection()
        setter()
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
