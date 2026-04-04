import SwiftUI

/// Main application view: custom HStack layout with sidebar + canvas + status bar.
/// Replaces NavigationSplitView for full control over the horizontal canvas.
struct ContentView: View {
    @State var workspace = WorkspaceModel()
    @State var sessions = SessionRegistry()
    @State var showModels = false
    @State var showAnalytics = false
    @State var showSkills = false
    @State var showSchedules = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Fixed-width sidebar
                SidebarView(
                    workspace: workspace,
                    showModels: $showModels,
                    showAnalytics: $showAnalytics,
                    showSkills: $showSkills,
                    showSchedules: $showSchedules
                )

                // Thin divider between sidebar and canvas
                Rectangle()
                    .fill(SenkaniTheme.appBackground)
                    .frame(width: 1)

                // Main canvas area
                canvasContent
            }

            // Status bar at the very bottom
            StatusBarView(workspace: workspace)
        }
        .background(SenkaniTheme.appBackground)
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SessionExportMenuButton(workspace: workspace)

                Button {
                    addPane(title: "Terminal", command: "/bin/zsh")
                } label: {
                    Image(systemName: "plus")
                }
                .help("New terminal pane (Cmd+N)")
                .keyboardShortcut("n")
            }
        }
        .onDisappear {
            SessionStore.shared.saveSession(workspace: workspace)
            sessions.stopAll()
        }
    }

    // MARK: - Canvas content

    @ViewBuilder
    private var canvasContent: some View {
        if showModels {
            ModelManagerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showAnalytics {
            AnalyticsView(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showSkills {
            SkillBrowserView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showSchedules {
            ScheduleView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.panes.isEmpty {
            WelcomeView { title, command in
                addPane(title: title, command: command)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PaneGridView(
                panes: workspace.panes,
                activePaneID: workspace.activePaneID,
                workspace: workspace
            )
        }
    }

    // MARK: - Actions

    private func addPane(title: String, command: String) {
        workspace.addPane(title: title, command: command)
        if let pane = workspace.panes.last {
            sessions.startSession(for: pane)
        }
    }
}
