import SwiftUI
import Core

/// Settings drawer for the Ollama-launcher pane.
///
/// Round `ollama-model-curation` — shows `OllamaModelCatalog.curated`
/// as rows with per-tag state (not-pulled / pulling / pulled) and a
/// button that either pulls, cancels, or reports installed. Kept inside
/// the Ollama pane's sheet hierarchy because the curated list is
/// user-facing-LLM context (distinct from `ModelManagerView`, which
/// owns senkani-internal ML).
///
/// Ollama's daemon availability gates the surface: when the daemon is
/// absent we still render the list but the buttons deep-link to
/// ollama.com/download instead of kicking off a pull that can't land.
struct OllamaModelsDrawer: View {

    /// Currently-selected pane default tag — the drawer reports
    /// installed state relative to this (no row check mark yet, but
    /// the default can be swapped via the Use-as-default action).
    @Binding var selectedTag: String

    /// Whether the Ollama daemon is reachable. When false, pull
    /// buttons deep-link to the install page.
    let ollamaAvailable: Bool

    /// Controller owning per-tag pull state + subprocess references.
    /// Injected so the pane can share one instance across drawer opens.
    @ObservedObject var controller: OllamaModelDownloadController

    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(OllamaModelCatalog.curated) { model in
                        row(for: model)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 420)
        .background(SenkaniTheme.paneBody)
        .task {
            await controller.refreshInstalled()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(SenkaniTheme.accentOllamaLauncher)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local LLMs")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Text("Pull one to chat locally — size is disclosed before download.")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textSecondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func row(for model: OllamaCuratedModel) -> some View {
        let state = controller.state(for: model.tag)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SenkaniTheme.textPrimary)
                    Text(model.tag)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    if selectedTag == model.tag {
                        Text("default")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(SenkaniTheme.accentOllamaLauncher)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(SenkaniTheme.accentOllamaLauncher,
                                            lineWidth: 0.5)
                            )
                    }
                }
                Text(model.useCase)
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                progressLine(state: state, size: model.sizeLabel)
            }
            Spacer(minLength: 8)
            actionButton(model: model, state: state)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SenkaniTheme.appBackground.opacity(0.4))
        )
    }

    @ViewBuilder
    private func progressLine(state: OllamaPullState, size: String) -> some View {
        switch state {
        case .notPulled:
            Text(size)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
        case .pulling(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text("\(Int(progress * 100))%  \(size)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
        case .pulled(let digest):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                if let digest, !digest.isEmpty {
                    Text("installed · \(String(digest.prefix(12)))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                } else {
                    Text("installed")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func actionButton(model: OllamaCuratedModel,
                              state: OllamaPullState) -> some View {
        if !ollamaAvailable {
            Button {
                if let url = URL(string: "https://ollama.com/download") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Install Ollama")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(SenkaniTheme.accentOllamaLauncher)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Ollama isn't running — install it, then reopen this pane")
        } else {
            switch state {
            case .notPulled, .failed:
                Button {
                    Task { await controller.startPull(tag: model.tag) }
                } label: {
                    Text(model.pullButtonCopy)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SenkaniTheme.accentOllamaLauncher)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Download \(model.displayName) (\(model.sizeLabel))")
            case .pulling:
                Button {
                    controller.cancelPull(tag: model.tag)
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(SenkaniTheme.inactiveBorder,
                                        lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(SenkaniTheme.textSecondary)
            case .pulled:
                Button {
                    selectedTag = model.tag
                } label: {
                    Text(selectedTag == model.tag ? "Current" : "Use")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(SenkaniTheme.accentOllamaLauncher
                                    .opacity(selectedTag == model.tag ? 1 : 0.5),
                                        lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTag == model.tag
                                 ? SenkaniTheme.accentOllamaLauncher
                                 : SenkaniTheme.textPrimary)
                .disabled(selectedTag == model.tag)
                .help(selectedTag == model.tag
                      ? "Already the pane's default"
                      : "Set as the default model for this pane")
            }
        }
    }
}
