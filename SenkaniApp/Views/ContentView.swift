import SwiftUI
import Core
import MCPServer

/// Which sidebar tool view is currently shown (nil = workspace/panes).
enum ToolView: Equatable {
    case models, analytics, skills, schedules, themes, knowledge, trustFlags
}

/// Main application view: custom HStack layout with sidebar + canvas + status bar.
/// Replaces NavigationSplitView for full control over the horizontal canvas.
struct ContentView: View {
    @State var workspace = WorkspaceModel()
    @State var sessions = SessionRegistry()
    @State var activeToolView: ToolView?
    @State var showAddPaneSheet = false
    @State var showCommandPalette = false
    @State private var broadcastEnabled = false
    @State private var broadcastText = ""

    /// Single launch primitive — every user-visible pane creation
    /// (Welcome, AddPaneSheet, Sidebar Claude, CommandPalette, IPC
    /// `.add`) routes through this coordinator so hook registration
    /// and session-watcher start are never skipped.
    @State private var launcher: LaunchCoordinator?

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Fixed-width sidebar
                SidebarView(
                    workspace: workspace,
                    activeToolView: $activeToolView,
                    onRequestAddPane: { showAddPaneSheet = true },
                    onLaunchPane: { type, title, command in
                        ensureLauncher().launchPane(
                            type: type, title: title, command: command
                        )
                    }
                )

                // Thin divider between sidebar and canvas
                Rectangle()
                    .fill(SenkaniTheme.appBackground)
                    .frame(width: 1)

                // Workstream sidebar (conditional — only when 2+ workstreams)
                if let project = workspace.activeProject, project.workstreams.count > 1 {
                    WorkstreamSidebarView(project: project, workspace: workspace)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Rectangle()
                        .fill(SenkaniTheme.appBackground)
                        .frame(width: 1)
                }

                // Main canvas area
                canvasContent
            }

            // Broadcast bar (visible when broadcast mode is on)
            if broadcastEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    TextField("Broadcast to all terminals...", text: $broadcastText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit {
                            if !broadcastText.isEmpty {
                                NotificationCenter.default.post(
                                    name: .senkaniSendBroadcast,
                                    object: broadcastText + "\n"
                                )
                                broadcastText = ""
                            }
                        }
                    Button {
                        broadcastEnabled = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
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
            registerPaneSocketHandler()
        }
        .onDisappear {
            WorkspaceStorage.save(workspace)
            SessionStore.shared.saveSession(workspace: workspace)
            sessions.stopAll()
            SocketServerManager.shared.paneHandler = nil
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

            // ⌘K command palette overlay
            if showCommandPalette {
                CommandPaletteView(
                    isVisible: $showCommandPalette,
                    workspace: workspace,
                    onAddPane: { typeId in
                        addPaneByTypeId(typeId)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(100)
            }
        }  // ZStack
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: showCommandPalette)
        .onAppear {
            // Install ⌘K monitor — catches the shortcut before terminal NSViews
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k" {
                    showCommandPalette.toggle()
                    return nil  // consumed
                }
                return event
            }
        }
    }

    // MARK: - Canvas content (ZStack keeps ALL project panes alive)

    @ViewBuilder
    private var canvasContent: some View {
        ZStack {
            // One PaneGridView PER WORKSTREAM PER PROJECT, all always in the view tree.
            // This keeps terminal NSViews alive when switching between
            // projects, workstreams, or navigating to tool views.
            ForEach(workspace.projects) { project in
                ForEach(project.workstreams) { workstream in
                    if !workstream.panes.isEmpty {
                        PaneGridView(
                            panes: workstream.panes,
                            activePaneID: workspace.activePaneID,
                            workspace: workspace
                        )
                        .opacity(project.isActive && workstream.isActive && activeToolView == nil ? 1 : 0)
                        .allowsHitTesting(project.isActive && workstream.isActive && activeToolView == nil)
                    }
                }
            }

            // Tool view overlay or welcome screen
            if let tool = activeToolView {
                toolContentView(for: tool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if workspace.panes.isEmpty {
                WelcomeView(
                    onStart: { title, command in
                        addPane(type: .terminal, title: title, command: command)
                    },
                    onStartOllama: {
                        addPane(type: .ollamaLauncher, title: "Ollama", command: "")
                    }
                )
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
        case .knowledge: KnowledgeBaseView()
        case .trustFlags: TrustFlagsView()
        }
    }

    // MARK: - Workspace Persistence

    private func restoreWorkspace() {
        if let restored = WorkspaceStorage.load() {
            workspace = restored
            // Start sessions (metrics watchers) for all restored panes.
            // Restore is not a launch — panes already exist, so we run
            // the same per-pane side effects (hook reg + session start)
            // inline rather than going through LaunchCoordinator (which
            // would also call workspace.addPane and saveWorkspace).
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
        MetricsStore.shared.start(projects: workspace.projects)
    }

    /// Lazy-initialize the LaunchCoordinator so `@State workspace` and
    /// `@State sessions` are first observed by SwiftUI before we
    /// capture references. The coordinator owns no state of its own —
    /// it's a thin façade — so re-using the same instance for the
    /// lifetime of the view is fine.
    private func ensureLauncher() -> LaunchCoordinator {
        if let existing = launcher { return existing }
        let coord = LaunchCoordinator(
            workspace: workspace,
            sessions: sessions,
            saveWorkspace: { WorkspaceStorage.save(workspace) }
        )
        launcher = coord
        return coord
    }

    private func saveWorkspace() {
        WorkspaceStorage.save(workspace)
    }

    // MARK: - Pane Socket Handler (IPC from MCP tools over ~/.senkani/pane.sock)

    /// Install a pane-command handler on `SocketServerManager.shared`. The
    /// manager invokes the closure on `paneQueue` (background); we hop to
    /// the main thread (SwiftUI/WorkspaceModel require it) and block with a
    /// semaphore until the response is encoded. Each connection sends one
    /// length-prefixed command frame and expects one length-prefixed
    /// response — this mirrors the `hookHandler` shape.
    private func registerPaneSocketHandler() {
        SocketServerManager.shared.paneHandler = { [workspace, sessions] cmdData in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let response: PaneIPCResponse
            if let command = try? decoder.decode(PaneIPCCommand.self, from: cmdData) {
                // Dispatch to main thread; workspace mutations touch SwiftUI
                // state and must run on the main actor.
                var resolved: PaneIPCResponse?
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    resolved = ContentView.handlePaneCommand(
                        command,
                        workspace: workspace,
                        sessions: sessions
                    )
                    semaphore.signal()
                }
                semaphore.wait()
                response = resolved ?? PaneIPCResponse(
                    id: command.id, success: false,
                    error: "handler produced no response"
                )
            } else {
                response = PaneIPCResponse(
                    id: "unknown", success: false,
                    error: "failed to decode PaneIPCCommand"
                )
            }

            return (try? encoder.encode(response)) ?? Data("{}".utf8)
        }
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

            // Route IPC `.add` through the same primitive UI launch
            // paths use, so programmatic creation matches user-driven
            // creation (hooks registered, session started, workspace
            // saved). The handler always runs on the main actor —
            // see `registerPaneSocketHandler` above.
            let coord = LaunchCoordinator(
                workspace: workspace,
                sessions: sessions,
                saveWorkspace: { WorkspaceStorage.save(workspace) }
            )
            if let pane = coord.launchPane(
                type: paneType, title: title, command: cmd,
                previewFilePath: command.params["url"] ?? ""
            ) {
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

        case .setBudgetStatus:
            guard let idStr = command.params["pane_id"],
                  let uuid = UUID(uuidString: idStr) else {
                return PaneIPCResponse(id: command.id, success: false, error: "Invalid or missing pane_id")
            }
            guard let pane = workspace.allPanes.first(where: { $0.id == uuid }) else {
                return PaneIPCResponse(id: command.id, success: false, error: "Pane not found: \(idStr)")
            }
            let status = command.params["status"] ?? "none"
            let spentCents = Int(command.params["spent_cents"] ?? "0") ?? 0
            let limitCents = Int(command.params["limit_cents"] ?? "0") ?? 0
            switch status {
            case "warning": pane.budgetStatus = .warning(spentCents: spentCents, limitCents: limitCents)
            case "blocked":  pane.budgetStatus = .blocked(spentCents: spentCents, limitCents: limitCents)
            default:         pane.budgetStatus = .none
            }
            return PaneIPCResponse(id: command.id, success: true, result: "Budget status updated: \(status)")
        }
    }

    /// Thin shim around `LaunchCoordinator.launchPane(...)` so call
    /// sites that only know type/title/command (AddPaneSheet,
    /// WelcomeView, CommandPalette) keep their compact API. All
    /// SwiftUI launch paths funnel through here, which funnels into
    /// the coordinator.
    private func addPane(type: PaneType = .terminal, title: String, command: String) {
        ensureLauncher().launchPane(type: type, title: title, command: command)
    }

    /// Add a pane by type ID string (from command palette).
    private func addPaneByTypeId(_ typeId: String) {
        let typeMap: [String: PaneType] = [
            "terminal": .terminal, "browser": .browser,
            "markdownPreview": .markdownPreview, "htmlPreview": .htmlPreview,
            "scratchpad": .scratchpad, "logViewer": .logViewer,
            "diffViewer": .diffViewer, "analytics": .analytics,
            "skillLibrary": .skillLibrary, "knowledgeBase": .knowledgeBase,
            "modelManager": .modelManager, "schedules": .scheduleManager,
            "savingsTest": .savingsTest, "codeEditor": .codeEditor,
            "agentTimeline": .agentTimeline,
            "dashboard": .dashboard,
            "sprintReview": .sprintReview,
            "ollamaLauncher": .ollamaLauncher,
        ]
        guard let type = typeMap[typeId] else { return }
        addPane(type: type, title: type == .terminal ? "Terminal" : typeId.capitalized, command: "")
    }
}
