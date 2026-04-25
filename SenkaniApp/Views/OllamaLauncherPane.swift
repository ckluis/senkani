import SwiftUI
import Core

/// First-class Ollama-launcher pane. Wraps a terminal subprocess that
/// runs `ollama run <tag>` against the user's selected default model,
/// with a detect-first availability gate and an install CTA when the
/// Ollama daemon is missing.
///
/// Bounded context (Evans' gate, 2026-04-20): this pane is for
/// user-facing LLM chat via Ollama. It is NOT the senkani-internal
/// Model Manager (`ModelManagerView`), which owns minilm-l6 + gemma4
/// for embedding/vision. Do not cross-wire them.
struct OllamaLauncherPane: View {
    @Bindable var pane: PaneModel
    let isActive: Bool

    /// Tri-state: `nil` = probing, `true` = Ollama daemon reachable,
    /// `false` = absent (show install CTA).
    @State private var ollamaAvailable: Bool?

    /// Bump this to restart the terminal with a new model tag after the
    /// user picks a different model. The terminal view is keyed on
    /// `(pane.id, restartToken)` so changing the token tears down the
    /// old NSView and spawns a fresh one.
    @State private var restartToken: Int = 0

    /// Owns per-tag pull state + `ollama pull` subprocesses. Lives on
    /// the pane (not globally) so each pane's cancel is scoped.
    @StateObject private var downloadController = OllamaModelDownloadController()

    @State private var showingModelsDrawer: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(SenkaniTheme.appBackground)
                .frame(height: 0.5)

            content
        }
        .background(SenkaniTheme.paneBody)
        .task(id: restartToken) {
            ollamaAvailable = await OllamaAvailability.detect()
        }
        .onChange(of: pane.ollamaDefaultModel) { _, _ in
            // Drawer "Use" action mutates the default — take the cue to
            // restart the terminal so chat reflects the new model.
            restartToken &+= 1
        }
        .sheet(isPresented: $showingModelsDrawer) {
            OllamaModelsDrawer(
                selectedTag: $pane.ollamaDefaultModel,
                ollamaAvailable: ollamaAvailable == true,
                controller: downloadController,
                onDismiss: { showingModelsDrawer = false }
            )
        }
    }

    // MARK: - Header

    /// Compact model-picker row. Placed inside the pane body (the
    /// outer pane header is owned by `PaneContainerView` and carries
    /// the FCSIT toggles + gear + close controls).
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.accentOllamaLauncher)

            Menu {
                ForEach(OllamaLauncherSupport.defaultModelTags, id: \.self) { tag in
                    Button {
                        if pane.ollamaDefaultModel != tag {
                            pane.ollamaDefaultModel = tag
                            restartToken &+= 1
                        }
                    } label: {
                        HStack {
                            Text(tag)
                            if pane.ollamaDefaultModel == tag {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(pane.ollamaDefaultModel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Ollama model — switching restarts the chat session")

            Spacer()

            if ollamaAvailable == true {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("connected")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }

            Button {
                showingModelsDrawer = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .help("Manage local models — pull or switch the active model")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch ollamaAvailable {
        case .none:
            detectingView
        case .some(false):
            absentCTA
        case .some(true):
            terminalBody
        }
    }

    private var detectingView: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text("Detecting Ollama…")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Install CTA when the Ollama daemon isn't reachable on the local
    /// port. Button opens ollama.com in the user's browser — no silent
    /// download, no background install (Schneier's supply-chain gate).
    private var absentCTA: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 32))
                .foregroundStyle(SenkaniTheme.accentOllamaLauncher)

            VStack(spacing: 4) {
                Text("Ollama isn't running")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Text("Install it, then start the daemon to launch a local LLM pane.")
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 8) {
                Button {
                    if let url = URL(string: "https://ollama.com/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Get Ollama")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(SenkaniTheme.accentOllamaLauncher)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    restartToken &+= 1
                } label: {
                    Text("Retry")
                        .font(.system(size: 11))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(SenkaniTheme.inactiveBorder, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(SenkaniTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Terminal subprocess running `ollama run <tag>` with the same MCP
    /// env var bundle regular terminal panes receive, so senkani
    /// tooling attached via the pane socket sees `SENKANI_PANE_ID` etc.
    /// just like in a plain shell. (Verification of MCP survival is
    /// the job of the `mcp-in-ollama-pane-verify` sub-item.)
    private var terminalBody: some View {
        let resolvedTag = OllamaLauncherSupport.resolveModelTag(pane.ollamaDefaultModel)
        let cmd = OllamaLauncherSupport.launchCommand(modelTag: resolvedTag) ?? ""
        let mcpEnv = PaneLaunchEnv.ollamaLauncher(
            PaneLaunchEnv.Inputs(
                paneID: pane.id,
                projectRoot: pane.workingDirectory,
                metricsFilePath: pane.metricsFilePath,
                configFilePath: pane.configFilePath,
                workspaceSlug: paneDiaryWorkspaceSlug(pane.workingDirectory),
                paneSlug: pane.paneType.rawValue,
                filterOn: pane.features.filter,
                cacheOn: pane.features.cache,
                secretsOn: pane.features.secrets,
                indexerOn: pane.features.indexer,
                terseOn: pane.features.terse
            ),
            resolvedModelTag: resolvedTag
        )
        return TerminalViewRepresentable(
            paneId: pane.id,
            initialCommand: cmd,
            environment: pane.features.environmentVars.merging(mcpEnv) { _, new in new },
            workingDirectory: pane.workingDirectory,
            isActive: isActive,
            fontSize: pane.fontSize,
            fontFamily: pane.fontFamily,
            onProcessExited: { code in
                pane.processState = .exited(code)
                pane.shellPid = nil
            },
            onProcessStarted: { pid in
                pane.shellPid = pid
                pane.processState = .running
            }
        )
        .id("\(pane.id.uuidString)-\(restartToken)")
    }

    /// Mirrors `PaneContainerView.paneDiaryWorkspaceSlug` — kept
    /// duplicated rather than hoisted because this view is in the app
    /// target and the helper stays private there. If a third caller
    /// appears, extract to a shared helper.
    private func paneDiaryWorkspaceSlug(_ workingDirectory: String) -> String {
        let parts = workingDirectory
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { $0 != ".." && !$0.contains("\\") }
        let tail = parts.suffix(2)
        let joined = tail.joined(separator: "-")
        return joined.isEmpty ? "workspace" : joined
    }
}
