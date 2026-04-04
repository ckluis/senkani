import SwiftUI

/// Redesigned sidebar: tools section at top, per-pane entries below
/// with savings indicators, usage bars, and active dots.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @Binding var showModels: Bool
    @Binding var showAnalytics: Bool
    @Binding var showSkills: Bool
    @Binding var showSchedules: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: - Tools section
                    sectionHeader("TOOLS")

                    toolRow(icon: "brain", label: "Models", isActive: showModels) {
                        showModels = true; showAnalytics = false; showSkills = false; showSchedules = false
                        workspace.activePaneID = nil
                    }
                    toolRow(icon: "chart.bar.xaxis", label: "Analytics", isActive: showAnalytics) {
                        showAnalytics = true; showModels = false; showSkills = false; showSchedules = false
                        workspace.activePaneID = nil
                    }
                    toolRow(icon: "puzzlepiece.extension", label: "Skills", isActive: showSkills) {
                        showSkills = true; showModels = false; showAnalytics = false; showSchedules = false
                        workspace.activePaneID = nil
                    }
                    toolRow(icon: "calendar.badge.clock", label: "Schedules", isActive: showSchedules) {
                        showSchedules = true; showModels = false; showAnalytics = false; showSkills = false
                        workspace.activePaneID = nil
                    }

                    // MARK: - Panes section
                    sectionHeader("PANES")
                        .padding(.top, 12)

                    ForEach(workspace.panes) { pane in
                        paneRow(pane)
                    }
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            // MARK: - Add pane button
            addPaneButton
        }
        .frame(width: SenkaniTheme.sidebarWidth)
        .background(SenkaniTheme.sidebarBackground)
        .onChange(of: workspace.activePaneID) { _, newValue in
            if newValue != nil {
                showModels = false
                showAnalytics = false
                showSkills = false
                showSchedules = false
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Add Pane")
                    .font(.system(size: 10))
            }
            .foregroundStyle(SenkaniTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SenkaniTheme.sidebarBackground)
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
}
