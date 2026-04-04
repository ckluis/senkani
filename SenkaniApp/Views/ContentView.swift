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
    @State var showAddPaneSheet = false
    @State var showThemePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Fixed-width sidebar
                SidebarView(
                    workspace: workspace,
                    showModels: $showModels,
                    showAnalytics: $showAnalytics,
                    showSkills: $showSkills,
                    showSchedules: $showSchedules,
                    showThemePicker: $showThemePicker
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
        .environment(\.themeEngine, ThemeEngine.shared)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SessionExportMenuButton(workspace: workspace)

                Button {
                    showAddPaneSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add pane (Cmd+N)")
                .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $showAddPaneSheet) {
            AddPaneSheet { type, title, command in
                addPane(type: type, title: title, command: command)
            }
        }
        .onAppear {
            ThemeEngine.shared.restoreLastTheme()
        }
        .onDisappear {
            SessionStore.shared.saveSession(workspace: workspace)
            sessions.stopAll()
        }
    }

    // MARK: - Canvas content

    @ViewBuilder
    private var canvasContent: some View {
        if showThemePicker {
            ThemePickerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if showModels {
            ModelManagerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if showAnalytics {
            AnalyticsView(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if showSkills {
            SkillBrowserView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if showSchedules {
            ScheduleView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if workspace.panes.isEmpty {
            WelcomeView { title, command in
                addPane(type: .terminal, title: title, command: command)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else {
            PaneGridView(
                panes: workspace.panes,
                activePaneID: workspace.activePaneID,
                workspace: workspace
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    // MARK: - Actions

    private func addPane(type: PaneType = .terminal, title: String, command: String) {
        workspace.addPane(type: type, title: title, command: command)
        if let pane = workspace.panes.last {
            sessions.startSession(for: pane)
        }
    }
}
