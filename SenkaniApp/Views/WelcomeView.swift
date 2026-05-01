import SwiftUI
import Core

/// First-run experience when no panes are open.
///
/// Project-first, task-first flow. The user picks a project folder,
/// then chooses a verb-first task starter ("Ask Claude in <project>",
/// "Use Ollama", "Open a tracked shell", "Inspect this project").
/// The full pane gallery lives one level deeper behind a "Show all
/// panes" link so first-run isn't a feature inventory.
///
/// Plain Shell remains usable without a project as the deliberate
/// escape hatch for a tracked shell in `$HOME`.
struct WelcomeView: View {
    /// Workspace state — drives the "is a project chosen?" gate.
    let workspace: WorkspaceModel
    /// Resolve a task starter into a concrete launch. ContentView
    /// switches on `starter.kind` and routes through LaunchCoordinator.
    let onStartTask: (TaskStarter) -> Void
    /// Open the project-folder picker. ContentView wires this to
    /// `NSOpenPanel` + `workspace.addProject(...)`.
    let onChooseProject: () -> Void
    /// Show the full pane gallery (advanced path). ContentView wires
    /// this to `showAddPaneSheet = true`.
    let onShowAllPanes: () -> Void

    @State private var claudeAvailable: Bool?
    @State private var ollamaAvailable: Bool?

    /// True when the user has picked at least one project. The
    /// implicit "Default" project (auto-created by `addPane(...)` for
    /// non-Welcome call sites) is not user-chosen, so we treat
    /// `projects.isEmpty` as "no project" — that's the only state
    /// reachable on first run before the user clicks anything.
    private var hasProject: Bool {
        !workspace.projects.isEmpty
    }

    private var activeProjectName: String? {
        workspace.activeProject?.name
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("閃蟹")
                .font(.system(size: 48))

            Text("Senkani")
                .font(.system(size: 28, weight: .semibold))

            Text("Token compression for AI agents")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            // Step 1 — project chooser. Always rendered so the user
            // sees the precondition; the chosen project is shown
            // inline once selected, with a "Change" affordance.
            VStack(spacing: 8) {
                if hasProject, let name = activeProjectName {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Project: \(name)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Change") { onChooseProject() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Button(action: onChooseProject) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 14))
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Choose project folder")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Step 1 — pick the repo your agent will run in")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 320)

            // Step 2 — task starters. Outcome-first, verb-first labels.
            // The full pane gallery is one level deeper behind the
            // "Show all panes" link below so first-run isn't a feature
            // inventory.
            VStack(spacing: 12) {
                ForEach(TaskStarterCatalog.all()) { starter in
                    TaskStarterCard(
                        starter: starter,
                        projectName: activeProjectName,
                        toolAvailable: toolAvailability(for: starter),
                        installURL: installURL(for: starter)
                    ) {
                        onStartTask(starter)
                    }
                }
            }
            .frame(maxWidth: 320)

            // Advanced path — the 18-pane gallery. Demoted to a
            // single secondary affordance so first-run users see the
            // task starters first.
            Button(action: onShowAllPanes) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10))
                    Text("Show all panes")
                        .font(.system(size: 11))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .task { await detectTools() }
    }

    /// Tool-availability state for a starter — Claude card needs the
    /// `claude` CLI, Ollama card needs Ollama running, the rest are
    /// always available.
    private func toolAvailability(for starter: TaskStarter) -> Bool? {
        switch starter.kind {
        case .claude:         return claudeAvailable
        case .ollama:         return ollamaAvailable
        case .trackedShell,
             .inspectProject: return true
        }
    }

    /// Install URL when the underlying tool is missing.
    private func installURL(for starter: TaskStarter) -> URL? {
        switch starter.kind {
        case .claude where claudeAvailable == false:
            return URL(string: "https://claude.ai/download")
        case .ollama where ollamaAvailable == false:
            return URL(string: "https://ollama.com")
        default:
            return nil
        }
    }

    private func detectTools() async {
        async let claude = detectCLI("claude")
        async let ollama = detectOllama()
        let (c, o) = await (claude, ollama)
        claudeAvailable = c
        ollamaAvailable = o
    }

    /// Check if a CLI tool exists by searching common paths + PATH via login shell.
    private func detectCLI(_ name: String) async -> Bool {
        // Check common install locations directly (works even in Xcode sandbox)
        let commonPaths = [
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "\(NSHomeDirectory())/Library/Application Support/Claude/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }
        // Fall back to login shell which to pick up user's PATH
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "which \(name)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    /// Check if Ollama is running by hitting its local API. Delegates
    /// to the Core-level probe so the same check powers the
    /// `OllamaLauncherPane`'s availability gate.
    private func detectOllama() async -> Bool {
        await OllamaAvailability.detect()
    }
}

/// Card representation of a `TaskStarter`. Composes the verb-first
/// label, outcome subtitle, project gate, and tool-availability state
/// into one tappable affordance. Replaces the per-agent `AgentCard`
/// shape used before the task-starter round.
struct TaskStarterCard: View {
    let starter: TaskStarter
    let projectName: String?
    /// nil = still detecting; true = ready; false = tool not found.
    let toolAvailable: Bool?
    let installURL: URL?
    let action: () -> Void

    private var hasProject: Bool { projectName != nil }

    /// True when the user can act on the card right now. Project-
    /// gated starters need a project chosen AND (when applicable) the
    /// underlying tool installed/running.
    private var available: Bool {
        if starter.requiresProject && !hasProject { return false }
        if toolAvailable == false { return false }
        return true
    }

    private var detecting: Bool {
        toolAvailable == nil && (starter.kind == .claude || starter.kind == .ollama)
    }

    private var title: String {
        starter.displayLabel(for: projectName)
    }

    /// Subtitle composes the missing-precondition message ahead of
    /// the outcome description. Tool-not-found takes precedence over
    /// project-not-chosen so the user sees the actionable next step.
    private var subtitle: String {
        if toolAvailable == false {
            switch starter.kind {
            case .claude: return "Not found — install from claude.ai/download"
            case .ollama: return "Not found — install from ollama.com"
            default:      break
            }
        }
        return starter.displaySubtitle(for: projectName)
    }

    private var iconColor: Color {
        switch starter.kind {
        case .claude:         return .blue
        case .ollama:         return .green
        case .trackedShell:   return .gray
        case .inspectProject: return .purple
        }
    }

    var body: some View {
        Button(action: {
            if available {
                action()
            } else if let url = installURL {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: starter.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(available ? iconColor : .gray)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if detecting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else if !available, installURL != nil {
                    Text("Install")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(available || detecting ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
    }
}
