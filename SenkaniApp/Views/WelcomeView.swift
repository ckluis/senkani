import SwiftUI
import Core

/// First-run experience when no panes are open.
///
/// Project-first flow: the user picks a project folder before Claude/
/// Ollama launches become available. This forces the launch site to
/// match the user's mental model ("run this agent in this repo")
/// instead of silently dropping a session into `~`.
///
/// Plain Shell remains usable without a project as the deliberate
/// escape hatch for a tracked shell in `$HOME`.
struct WelcomeView: View {
    /// Workspace state — drives the "is a project chosen?" gate.
    let workspace: WorkspaceModel
    /// Terminal launch (Claude Code shell, Plain Shell).
    let onStart: (String, String) -> Void  // (title, command)
    /// Ollama launch: opens a first-class `ollamaLauncher` pane rather
    /// than shelling out `ollama run <hardcoded>` via a terminal pane.
    /// The pane owns its default-model selector + availability gate.
    let onStartOllama: () -> Void
    /// Open the project-folder picker. ContentView wires this to
    /// `NSOpenPanel` + `workspace.addProject(...)`.
    let onChooseProject: () -> Void

    @State private var claudeAvailable: Bool?
    @State private var ollamaAvailable: Bool?
    @State private var showClaudeLaunch = false

    /// True when the user has picked at least one project. The
    /// implicit "Default" project (auto-created by `addPane(...)` for
    /// non-Welcome call sites) is not user-chosen, so we treat
    /// `projects.isEmpty` as "no project" — that's the only state
    /// reachable on first run before the user clicks anything.
    private var hasProject: Bool {
        !workspace.projects.isEmpty
    }

    private var activeProjectName: String {
        workspace.activeProject?.name ?? ""
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
                if hasProject {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Project: \(activeProjectName)")
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

            VStack(spacing: 12) {
                AgentCard(
                    title: hasProject
                        ? "Start Claude in \(activeProjectName)"
                        : "Start Claude Code",
                    subtitle: agentCardSubtitle(
                        toolAvailable: claudeAvailable,
                        notFoundMessage: "Not found — install from claude.ai/download",
                        readyMessage: hasProject
                            ? "Run Claude Code in \(activeProjectName)"
                            : "Choose a project folder first"
                    ),
                    icon: "brain",
                    color: .blue,
                    available: (claudeAvailable ?? false) && hasProject,
                    detecting: claudeAvailable == nil,
                    installURL: claudeAvailable == false
                        ? URL(string: "https://claude.ai/download")
                        : nil
                ) {
                    showClaudeLaunch = true
                }

                AgentCard(
                    title: hasProject
                        ? "Start Ollama in \(activeProjectName)"
                        : "Start Ollama",
                    subtitle: agentCardSubtitle(
                        toolAvailable: ollamaAvailable,
                        notFoundMessage: "Not found — install from ollama.com",
                        readyMessage: hasProject
                            ? "Run Ollama in \(activeProjectName)"
                            : "Choose a project folder first"
                    ),
                    icon: "cpu",
                    color: .green,
                    available: (ollamaAvailable ?? false) && hasProject,
                    detecting: ollamaAvailable == nil,
                    installURL: ollamaAvailable == false
                        ? URL(string: "https://ollama.com")
                        : nil
                ) {
                    onStartOllama()
                }

                // Plain Shell is the deliberate escape hatch — it
                // works without a project so a user who really wants
                // a tracked shell in $HOME can get one. The subtitle
                // names the directory so this isn't a silent default.
                AgentCard(
                    title: hasProject
                        ? "Open Plain Shell in \(activeProjectName)"
                        : "Open Plain Shell in home folder",
                    subtitle: hasProject
                        ? "Tracked terminal in \(activeProjectName)"
                        : "Tracked terminal in your home folder (no project)",
                    icon: "terminal",
                    color: .gray,
                    available: true,
                    detecting: false
                ) {
                    onStart("Terminal", "")
                }
            }
            .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .task { await detectTools() }
        .sheet(isPresented: $showClaudeLaunch) {
            ClaudeLaunchSheet { command in
                onStart("Claude Code", command)
            }
        }
    }

    /// Compose an agent card subtitle that tells the user why the
    /// card is or isn't actionable. Project-gate state takes priority
    /// over availability so the user sees the missing precondition,
    /// not a stale "ready" message.
    private func agentCardSubtitle(
        toolAvailable: Bool?,
        notFoundMessage: String,
        readyMessage: String
    ) -> String {
        if toolAvailable == false { return notFoundMessage }
        if !hasProject { return "Choose a project folder first" }
        return readyMessage
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

struct AgentCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var available: Bool = true
    var detecting: Bool = false
    var installURL: URL? = nil
    let action: () -> Void

    var body: some View {
        Button(action: {
            if available {
                action()
            } else if let url = installURL {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(available ? color : .gray)
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
