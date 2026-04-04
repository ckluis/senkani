import SwiftUI

/// Main application view: sidebar + pane grid + status bar.
struct ContentView: View {
    @State var workspace = WorkspaceModel()
    @State var sessions = SessionRegistry()
    @State var showModels = false
    @State var showAnalytics = false
    @State var showSkills = false

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace, showModels: $showModels, showAnalytics: $showAnalytics, showSkills: $showSkills)
                .frame(minWidth: 160, maxWidth: 220)
        } detail: {
            VStack(spacing: 0) {
                if showModels {
                    ModelManagerView()
                } else if showAnalytics {
                    AnalyticsView(workspace: workspace)
                } else if showSkills {
                    SkillBrowserView()
                } else if workspace.panes.isEmpty {
                    WelcomeView { title, command in
                        addPane(title: title, command: command)
                    }
                } else {
                    PaneGridView(
                        panes: workspace.panes,
                        activePaneID: workspace.activePaneID,
                        workspace: workspace
                    )
                }

                Divider()

                StatusBarView(workspace: workspace)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle("Senkani")
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

    private func addPane(title: String, command: String) {
        workspace.addPane(title: title, command: command)
        if let pane = workspace.panes.last {
            sessions.startSession(for: pane)
        }
    }
}
