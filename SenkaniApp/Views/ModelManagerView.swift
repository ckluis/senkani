import SwiftUI
import Core

/// View for managing downloadable ML models used by senkani_embed and senkani_vision.
struct ModelManagerView: View {
    @ObservedObject var manager = ModelManager.shared
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteId: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if manager.models.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(manager.models) { model in
                            ModelCardView(
                                model: model,
                                onDownload: { downloadModel(model.id) },
                                onDelete: { confirmDelete(model.id) }
                            )
                        }
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
                Text("Remove \"\(model.name)\" from disk? You can re-download it later.")
            }
        }
        .overlay(alignment: .bottom) {
            if let error = errorMessage {
                errorBanner(error)
            }
        }
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
        .padding(10)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                }

                Text(modelDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if model.status == .downloading {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.3), value: model.downloadProgress)
                }

                Text(sizeLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
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

    private var modelDescription: String {
        switch model.id {
        case "minilm-l6":
            return "Semantic embedding for indexed code search (~90 MB)"
        case "qwen2-vl-2b":
            return "Image understanding for screenshot analysis (~1.5 GB)"
        case "gemma3-4b":
            return "Advanced vision model for screenshot analysis (~5 GB)"
        default:
            return "ML model for Senkani tools"
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
