import SwiftUI

/// Redesigned sidebar: tools section, per-project entries with panes,
/// and a settings gear for theme picker.
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
                    // MARK: - Tools section
                    sectionHeader("TOOLS")

                    toolRow(icon: "brain", label: "Models", isActive: showModels) {
                        showModels = true; showAnalytics = false; showSkills = false; showSchedules = false; showThemePicker = false
                        workspace.activePaneID = nil
                    }
                    toolRow(icon: "chart.bar.xaxis", label: "Analytics", isActive: showAnalytics) {
                        showAnalytics = true; showModels = false; showSkills = false; showSchedules = false; showThemePicker = false
                        workspace.activePaneID = nil
                    }
                    toolRow(icon: "puzzlepiece.extension", label: "Skills", isActive: showSkills) {
                        showSkills = true; showModels = false; showAnalytics = false; showSchedules = false; showThemePicker = false
                        workspace.activePaneID = nil
                    }
                    toolRow(icon: "calendar.badge.clock", label: "Schedules", isActive: showSchedules) {
                        showSchedules = true; showModels = false; showAnalytics = false; showSkills = false; showThemePicker = false
                        workspace.activePaneID = nil
                    }

                    // MARK: - Projects section
                    sectionHeader("PROJECTS")
                        .padding(.top, 12)

                    if workspace.projects.isEmpty {
                        // No projects yet — show flat pane list (backward compat)
                        ForEach(workspace.panes) { pane in
                            paneRow(pane)
                        }
                    } else {
                        ForEach(workspace.projects) { project in
                            projectSection(project)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            // MARK: - Bottom buttons
            VStack(spacing: 0) {
                Rectangle()
                    .fill(SenkaniTheme.inactiveBorder.opacity(0.3))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    addPaneButton
                    Spacer()
                    addProjectButton
                    themeGearButton
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(width: SenkaniTheme.sidebarWidth)
        .background(SenkaniTheme.sidebarBackground)
        .onChange(of: workspace.activePaneID) { _, newValue in
            if newValue != nil {
                showModels = false
                showAnalytics = false
                showSkills = false
                showSchedules = false
                showThemePicker = false
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

    // MARK: - Project section (collapsible)

    private func projectSection(_ project: ProjectModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header row
            Button {
                workspace.switchToProject(id: project.id)
                showModels = false; showAnalytics = false; showSkills = false; showSchedules = false; showThemePicker = false
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // Active indicator
                        Circle()
                            .fill(project.isActive ? SenkaniTheme.accentAnalytics : SenkaniTheme.textTertiary.opacity(0.4))
                            .frame(width: 5, height: 5)

                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(project.isActive ? SenkaniTheme.accentAnalytics : SenkaniTheme.textTertiary)
                            .frame(width: 14)

                        Text(project.name)
                            .font(.system(size: 11, weight: project.isActive ? .semibold : .regular))
                            .foregroundStyle(project.isActive ? SenkaniTheme.textPrimary : SenkaniTheme.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        // Savings badge
                        if project.totalSavedBytes > 0 {
                            Text(project.formattedSavings)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.savingsGreen)
                        }
                    }

                    // Usage bar
                    if project.totalRawBytes > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(SenkaniTheme.textTertiary.opacity(0.2))
                                    .frame(height: 2)
                                Rectangle()
                                    .fill(SenkaniTheme.accentAnalytics.opacity(0.6))
                                    .frame(
                                        width: geo.size.width * min(project.savingsPercent / 100.0, 1.0),
                                        height: 2
                                    )
                            }
                        }
                        .frame(height: 2)
                        .padding(.leading, 25)
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

            // Panes within this project (shown when active)
            if project.isActive {
                ForEach(project.panes) { pane in
                    paneRow(pane)
                        .padding(.leading, 8) // indent under project
                }
            }
        }
    }

    // MARK: - Pane row

    private func paneRow(_ pane: PaneModel) -> some View {
        Button {
            workspace.activePaneID = pane.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Active/inactive dot
                    Circle()
                        .fill(pane.id == workspace.activePaneID
                              ? SenkaniTheme.accentColor(for: pane.paneType)
                              : processStateColor(pane.processState))
                        .frame(width: 5, height: 5)

                    // Type icon
                    Image(systemName: SenkaniTheme.iconName(for: pane.paneType))
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.accentColor(for: pane.paneType).opacity(
                            pane.id == workspace.activePaneID ? 1.0 : 0.6
                        ))
                        .frame(width: 14)

                    // Title
                    Text(pane.title)
                        .font(.system(size: 11))
                        .foregroundStyle(pane.id == workspace.activePaneID
                                         ? SenkaniTheme.textPrimary
                                         : SenkaniTheme.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    // Small savings indicator
                    if pane.metrics.savedBytes > 0 {
                        Text(pane.metrics.formattedSavings)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                    }
                }

                // Usage bar: 2px, filled proportionally by savings percent
                if pane.metrics.totalRawBytes > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(SenkaniTheme.textTertiary.opacity(0.2))
                                .frame(height: 2)

                            Rectangle()
                                .fill(SenkaniTheme.accentColor(for: pane.paneType).opacity(0.6))
                                .frame(width: geo.size.width * min(pane.metrics.savingsPercent / 100.0, 1.0), height: 2)
                        }
                    }
                    .frame(height: 2)
                    .padding(.leading, 25) // align with title text
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
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

    // MARK: - Add pane

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

    // MARK: - Add project

    private var addProjectButton: some View {
        Button {
            openFolderPicker()
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help("Add Project")
    }

    // MARK: - Theme gear

    private var themeGearButton: some View {
        Button {
            showThemePicker.toggle()
            if showThemePicker {
                showModels = false; showAnalytics = false; showSkills = false; showSchedules = false
                workspace.activePaneID = nil
            }
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
