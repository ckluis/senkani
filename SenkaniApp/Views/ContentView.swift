import SwiftUI
import Core

/// Which sidebar tool view is currently shown (nil = workspace/panes).
enum ToolView: Equatable {
    case models, analytics, skills, schedules, themes
}

/// Main application view: custom HStack layout with sidebar + canvas + status bar.
/// Replaces NavigationSplitView for full control over the horizontal canvas.
struct ContentView: View {
    @State var workspace = WorkspaceModel()
    @State var sessions = SessionRegistry()
    @State var activeToolView: ToolView?
    @State var showAddPaneSheet = false
    @State private var paneCommandWatcher = PaneCommandWatcher()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Fixed-width sidebar
                SidebarView(
                    workspace: workspace,
                    activeToolView: $activeToolView,
                    onRequestAddPane: { showAddPaneSheet = true }
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
        .sheet(isPresented: $showAddPaneSheet) {
            AddPaneSheet { type, title, command in
                addPane(type: type, title: title, command: command)
            }
        }
        .onAppear {
            ThemeEngine.shared.restoreLastTheme()
            restoreWorkspace()  // Also starts MetricsStore after workspace is populated
            startPaneCommandWatcher()
        }
        .onDisappear {
            WorkspaceStorage.save(workspace)
            SessionStore.shared.saveSession(workspace: workspace)
            sessions.stopAll()
            paneCommandWatcher.stop()
            MetricsStore.shared.stop()
        }
        // Auto-save workspace when project/pane structure changes
        .onChange(of: workspace.projects.count) { _, _ in
            saveWorkspace()
            MetricsStore.shared.start(projects: workspace.projects)
        }
        .onChange(of: workspace.activeProjectID) { _, _ in saveWorkspace() }
        .onChange(of: workspace.panes.count) { _, _ in saveWorkspace() }
        // Periodic auto-save (every 30s) to persist metrics through crashes/rebuilds
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            saveWorkspace()
        }
    }

    // MARK: - Canvas content (ZStack keeps ALL project panes alive)

    @ViewBuilder
    private var canvasContent: some View {
        ZStack {
            // One PaneGridView PER PROJECT, all always in the view tree.
            // This keeps terminal NSViews alive when switching between
            // projects or navigating to tool views.
            ForEach(workspace.projects) { project in
                if !project.panes.isEmpty {
                    PaneGridView(
                        panes: project.panes,
                        activePaneID: workspace.activePaneID,
                        workspace: workspace
                    )
                    .opacity(project.isActive && activeToolView == nil ? 1 : 0)
                    .allowsHitTesting(project.isActive && activeToolView == nil)
                }
            }

            // Tool view overlay or welcome screen
            if let tool = activeToolView {
                toolContentView(for: tool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if workspace.panes.isEmpty {
                WelcomeView { title, command in
                    addPane(type: .terminal, title: title, command: command)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    @ViewBuilder
    private func toolContentView(for tool: ToolView) -> some View {
        switch tool {
        case .themes:    ThemePickerView()
        case .models:    ModelManagerView()
        case .analytics: AnalyticsView(workspace: workspace)
        case .skills:    SkillBrowserView()
        case .schedules: ScheduleView()
        }
    }

    // MARK: - Workspace Persistence

    private func restoreWorkspace() {
        if let restored = WorkspaceStorage.load() {
            workspace = restored
            // Start sessions (metrics watchers) for all restored panes
            for pane in workspace.allPanes {
                if pane.paneType == .terminal {
                    try? HookRegistration.registerForProject(
                        at: pane.workingDirectory,
                        hookBinaryPath: AutoRegistration.hookWrapperPath)
                }
                sessions.startSession(for: pane)
            }
        }
        // Always start metrics AFTER restore, so projects array is populated.
        // Safe even if restore fails — default project may still exist.
        print("🚨 [CONTENT-VIEW] restoreWorkspace done: \(workspace.projects.count) projects")
        MetricsStore.shared.start(projects: workspace.projects)
    }

    private func saveWorkspace() {
        WorkspaceStorage.save(workspace)
    }

    // MARK: - Pane Command Watcher (IPC from MCP tools)

    private func startPaneCommandWatcher() {
        paneCommandWatcher.onCommand = { [workspace, sessions] command in
            ContentView.handlePaneCommand(command, workspace: workspace, sessions: sessions)
        }
        paneCommandWatcher.start()
    }

    private static func handlePaneCommand(
        _ command: PaneIPCCommand,
        workspace: WorkspaceModel,
        sessions: SessionRegistry
    ) -> PaneIPCResponse {
        switch command.action {
        case .list:
            let paneInfos = workspace.allPanes.map { pane -> [String: String] in
                [
                    "id": pane.id.uuidString,
                    "type": pane.paneType.rawValue,
                    "title": pane.title,
                    "state": "\(pane.processState)",
                    "saved_bytes": "\(pane.metrics.savedBytes)",
                    "commands": "\(pane.metrics.commandCount)",
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: paneInfos, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                return PaneIPCResponse(id: command.id, success: true, result: json)
            }
            return PaneIPCResponse(id: command.id, success: true, result: "[]")

        case .add:
            let typeStr = command.params["type"] ?? "terminal"
            let paneType = PaneType(rawValue: typeStr) ?? .terminal
            let title = command.params["title"] ?? paneType.rawValue
            let cmd = command.params["command"] ?? ""

            workspace.addPane(type: paneType, title: title, command: cmd,
                              previewFilePath: command.params["url"] ?? "")
            if let pane = workspace.panes.last {
                if pane.paneType == .terminal {
                    try? HookRegistration.registerForProject(
                        at: pane.workingDirectory,
                        hookBinaryPath: AutoRegistration.hookWrapperPath)
                }
                sessions.startSession(for: pane)
                return PaneIPCResponse(id: command.id, success: true,
                                       result: "Added pane: \(pane.id.uuidString)")
            }
            return PaneIPCResponse(id: command.id, success: false, error: "Failed to add pane")

        case .remove:
            guard let idStr = command.params["pane_id"],
                  let uuid = UUID(uuidString: idStr) else {
                return PaneIPCResponse(id: command.id, success: false, error: "Invalid or missing pane_id")
            }
            sessions.stopSession(for: uuid)
            workspace.removePane(id: uuid)
            return PaneIPCResponse(id: command.id, success: true, result: "Removed pane: \(idStr)")

        case .setActive:
            guard let idStr = command.params["pane_id"],
                  let uuid = UUID(uuidString: idStr) else {
                return PaneIPCResponse(id: command.id, success: false, error: "Invalid or missing pane_id")
            }
            workspace.activePaneID = uuid
            return PaneIPCResponse(id: command.id, success: true, result: "Activated pane: \(idStr)")
        }
    }

    private func addPane(type: PaneType = .terminal, title: String, command: String) {
        workspace.addPane(type: type, title: title, command: command)
        if let pane = workspace.panes.last {
            if pane.paneType == .terminal {
                try? HookRegistration.registerForProject(
                    at: pane.workingDirectory,
                    hookBinaryPath: AutoRegistration.hookWrapperPath)
            }
            sessions.startSession(for: pane)
        }
        saveWorkspace()
    }
}
