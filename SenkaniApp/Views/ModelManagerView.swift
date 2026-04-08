import SwiftUI
import Core

/// View for managing downloadable ML models used by senkani_embed and senkani_vision.
struct ModelManagerView: View {
    @ObservedObject var manager = ModelManager.shared
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteId: String?
    @State private var errorMessage: String?

    private var isAnyDownloading: Bool {
        manager.models.contains { $0.status == .downloading }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if manager.models.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        // Embeddings section
                        modelSection(
                            title: "Embeddings (Semantic Search)",
                            icon: "magnifyingglass.circle.fill",
                            color: .blue,
                            explanation: "Finds the right file without reading them all. Your projects may have thousands of files -- embeddings let Claude jump straight to the relevant ones instead of scanning everything. Saves 80-95% of tokens.",
                            whyLocal: "Runs entirely on your Mac. No data leaves your machine, no API costs, no rate limits.",
                            models: manager.models.filter { $0.id == "minilm-l6" },
                            recommended: "minilm-l6"
                        )

                        Divider()
                            .padding(.horizontal, 4)

                        // Vision section — Gemma 4 tiered by RAM
                        modelSection(
                            title: "Vision (Image Understanding)",
                            icon: "eye.circle.fill",
                            color: .purple,
                            explanation: "Analyzes screenshots, diagrams, and UI mockups locally instead of $0.01/image API calls. Useful for design review, bug screenshots, and documentation images.",
                            whyLocal: "Process sensitive screenshots without uploading them. No per-image charges.",
                            models: manager.models.filter { ModelManager.visionModelIds.contains($0.id) },
                            recommended: manager.recommendedVisionModel()?.id ?? "gemma4-e2b"
                        )
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
            Button("Delete", role: .destructive) { performDelete() }
        } message: {
            if let id = pendingDeleteId,
               let model = manager.models.first(where: { $0.id == id }) {
                let usage = manager.diskUsage(for: id)
                let freed = usage > 0 ? " (\(ModelManager.formatBytes(usage)) freed)" : ""
                Text("Remove \"\(model.name)\" from disk?\(freed)\nYou can re-download it later.")
            }
        }
        .overlay(alignment: .bottom) {
            if let error = errorMessage {
                errorBanner(error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: errorMessage != nil)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models")
                    .font(.system(size: 18, weight: .semibold))
                Text(diskUsageLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // RAM tier badge
            Text(manager.selectedTierDescription)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()

            if hasDownloadableModels {
                Button {
                    downloadAll()
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAnyDownloading)
                .help(isAnyDownloading ? "Download in progress..." : "Download all available models")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Models Configured")
                .font(.system(size: 16, weight: .medium))

            Text("ML models power senkani_embed (semantic search)\nand senkani_vision (image understanding).\nModels will appear here when available.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11))
            Spacer()
            Button {
                withAnimation { errorMessage = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }

    // MARK: - Model Section

    private func modelSection(
        title: String,
        icon: String,
        color: Color,
        explanation: String,
        whyLocal: String,
        models: [ModelInfo],
        recommended: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }

            // Explanation card
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)

                HStack(spacing: 4) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text(whyLocal)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(color.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Model cards
            ForEach(models) { model in
                ModelCardView(
                    model: model,
                    isRecommended: model.id == recommended,
                    comparisonNote: modelComparisonNote(model.id),
                    onDownload: { downloadModel(model.id) },
                    onDelete: { confirmDelete(model.id) }
                )
            }
        }
    }

    private func modelComparisonNote(_ id: String) -> String? {
        switch id {
        case "gemma4-26b-apex": return "Frontier-class (APEX quantization) — requires ≥16GB RAM"
        case "gemma4-e4b": return "Strong quality — requires ≥8GB RAM"
        case "gemma4-e2b": return "Good quality, small footprint — requires ≥4GB RAM"
        case "minilm-l6": return "Fast and lightweight — ideal for code search"
        default: return nil
        }
    }

    // MARK: - Helpers

    private var diskUsageLabel: String {
        let bytes = manager.totalDiskUsage()
        if bytes == 0 { return "No models on disk" }
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB on disk", Double(bytes) / 1_000_000_000)
        }
        return String(format: "%.0f MB on disk", Double(bytes) / 1_000_000)
    }

    private var hasDownloadableModels: Bool {
        manager.models.contains { $0.status == .available }
    }

    private func downloadModel(_ id: String) {
        Task {
            do {
                try await manager.download(modelId: id)
            } catch {
                withAnimation { errorMessage = error.localizedDescription }
            }
        }
    }

    private func downloadAll() {
        let available = manager.models.filter { $0.status == ModelStatus.available }
        for model in available {
            downloadModel(model.id)
        }
    }

    private func confirmDelete(_ id: String) {
        pendingDeleteId = id
        showDeleteConfirmation = true
    }

    private func performDelete() {
        guard let id = pendingDeleteId else { return }
        do {
            try manager.delete(modelId: id)
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
        }
        pendingDeleteId = nil
    }
}

// MARK: - Model Card

struct ModelCardView: View {
    let model: ModelInfo
    var isRecommended: Bool = false
    var comparisonNote: String? = nil
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .medium))
                    statusBadge

                    if isRecommended {
                        Text("Recommended")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    if let quant = model.quantMethod {
                        Text(quant)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if let note = comparisonNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if model.status == .downloading {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.3), value: model.downloadProgress)
                        .padding(.trailing, 4)
                }

                Text(sizeLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Size: \(sizeLabel)")
            }

            Spacer()

            actionButton
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Card Components

    @ViewBuilder
    private var statusIcon: some View {
        switch model.status {
        case .available:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
        case .downloading:
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.status {
        case .available:
            Text("Available")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .downloading:
            Text("\(Int(model.downloadProgress * 100))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .downloaded:
            Text("Ready")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.green)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .error:
            Text("Error")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch model.status {
        case .available, .error:
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Download \(model.name)")
        case .downloading:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 18, height: 18)
        case .downloaded:
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Delete \(model.name)")
        }
    }

    private var sizeLabel: String {
        let mb = Double(model.expectedSizeBytes) / 1_000_000
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }
}
