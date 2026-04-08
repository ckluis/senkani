import SwiftUI

/// First-run experience when no panes are open.
/// Auto-detects available AI tools and grays out unavailable options.
struct WelcomeView: View {
    let onStart: (String, String) -> Void  // (title, command)

    @State private var claudeAvailable: Bool?
    @State private var ollamaAvailable: Bool?
    @State private var showClaudeLaunch = false

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

            VStack(spacing: 12) {
                AgentCard(
                    title: "Start Claude Code",
                    subtitle: claudeAvailable == false
                        ? "Not found — install from claude.ai/download"
                        : "Full compression pipeline + MCP integration",
                    icon: "brain",
                    color: .blue,
                    available: claudeAvailable ?? false,
                    detecting: claudeAvailable == nil,
                    installURL: URL(string: "https://claude.ai/download")
                ) {
                    showClaudeLaunch = true
                }

                AgentCard(
                    title: "Start Ollama",
                    subtitle: ollamaAvailable == false
                        ? "Not found — install from ollama.com"
                        : "Local LLM with filtered output",
                    icon: "cpu",
                    color: .green,
                    available: ollamaAvailable ?? false,
                    detecting: ollamaAvailable == nil,
                    installURL: URL(string: "https://ollama.com")
                ) {
                    onStart("Ollama", "ollama run llama3")
                }

                AgentCard(
                    title: "Plain Shell",
                    subtitle: "Terminal with token tracking only",
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

    /// Check if Ollama is running by hitting its local API.
    private func detectOllama() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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
