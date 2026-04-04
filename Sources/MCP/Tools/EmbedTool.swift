import Foundation
import MCP
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers
import Indexer
import Core

/// Local semantic search using on-device embedding model.
/// Indexes project files, returns most relevant files for a query.
/// Cost: $0 (local Apple Silicon inference) vs $0.003+ per API call.
actor EmbedEngine {
    private var modelContainer: MLXEmbedders.ModelContainer?
    private var fileEmbeddings: [String: [Float]] = [:]  // relative path → embedding
    private var projectRoot: String = ""
    private var indexedAt: Date?

    /// The model ID used for ModelManager tracking.
    static let modelId = "minilm-l6"

    /// Load the embedding model. ModelManager must report ready before calling this.
    func ensureModel() async throws -> MLXEmbedders.ModelContainer {
        if let mc = modelContainer { return mc }
        ModelManager.shared.updateProgress(Self.modelId, progress: 0.0)
        let mc = try await MLXEmbedders.loadModelContainer(configuration: .minilm_l6) { progress in
            ModelManager.shared.updateProgress(Self.modelId, progress: progress.fractionCompleted)
        }
        modelContainer = mc
        ModelManager.shared.markDownloaded(Self.modelId)
        return mc
    }

    /// Index all source files in the project.
    func indexProject(root: String, files: [String]) async throws {
        let mc = try await ensureModel()
        projectRoot = root

        // Read file contents and create embeddings
        var texts: [String] = []
        var paths: [String] = []

        for file in files {
            let fullPath = root + "/" + file
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            // Use first 500 chars as the file's representation (fast, good enough for similarity)
            let preview = String(content.prefix(500))
            texts.append(preview)
            paths.append(file)
        }

        guard !texts.isEmpty else { return }

        // Generate embeddings in batches
        let capturedTexts = texts
        let embeddings = await mc.perform {
            (model: EmbeddingModel, tokenizer: Tokenizer, pooling: Pooling) -> [[Float]] in

            var results: [[Float]] = []
            let batchSize = 32

            for batchStart in stride(from: 0, to: capturedTexts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, capturedTexts.count)
                let batch = Array(capturedTexts[batchStart..<batchEnd])

                let inputs = batch.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
                let maxLength = inputs.reduce(into: 16) { acc, elem in acc = max(acc, elem.count) }

                let padded = stacked(inputs.map { elem in
                    MLXArray(elem + Array(repeating: tokenizer.eosTokenId ?? 0,
                                          count: maxLength - elem.count))
                })
                let mask = (padded .!= tokenizer.eosTokenId ?? 0)
                let tokenTypes = MLXArray.zeros(like: padded)

                let output = pooling(
                    model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                    normalize: true, applyLayerNorm: true
                )
                output.eval()
                results.append(contentsOf: output.map { $0.asArray(Float.self) })
            }

            return results
        }

        // Store embeddings
        for (path, embedding) in zip(paths, embeddings) {
            fileEmbeddings[path] = embedding
        }

        indexedAt = Date()
        fputs("senkani: indexed \(fileEmbeddings.count) files for semantic search\n", stderr)
    }

    /// Find files most similar to a query.
    func search(query: String, topK: Int = 5) async throws -> [(file: String, score: Float)] {
        guard !fileEmbeddings.isEmpty else { return [] }
        let mc = try await ensureModel()

        // Embed the query
        let queryEmbedding = await mc.perform {
            (model: EmbeddingModel, tokenizer: Tokenizer, pooling: Pooling) -> [Float] in
            let input = tokenizer.encode(text: "search_query: \(query)", addSpecialTokens: true)
            let padded = MLXArray(input).reshaped([1, input.count])
            let mask = MLXArray.ones(like: padded)
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                normalize: true, applyLayerNorm: true
            )
            output.eval()
            return output[0].asArray(Float.self)
        }

        // Compute cosine similarity with all indexed files
        var similarities: [(file: String, score: Float)] = []
        for (file, embedding) in fileEmbeddings {
            let score = cosineSimilarity(queryEmbedding, embedding)
            similarities.append((file: file, score: score))
        }

        return similarities.sorted { $0.score > $1.score }.prefix(topK).map { $0 }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).map(*).reduce(0, +)
        let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        guard normA > 0 && normB > 0 else { return 0 }
        return dot / (normA * normB)
    }
}

enum EmbedTool {
    static let engine = EmbedEngine()

    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'query' is required", annotations: nil, _meta: nil)], isError: true)
        }

        // Gate on ModelManager readiness — if not downloaded, guide the user
        let mgr = ModelManager.shared
        if !mgr.isReady(EmbedEngine.modelId) {
            let info = mgr.model(EmbedEngine.modelId)
            let size = ModelManager.formatBytes(info?.expectedSizeBytes ?? 90_000_000)
            let status = info?.status ?? .available
            switch status {
            case .downloading:
                let pct = Int((info?.downloadProgress ?? 0) * 100)
                return .init(content: [.text(text: "Embedding model is downloading (\(pct)%). Please wait and retry.", annotations: nil, _meta: nil)], isError: true)
            case .error:
                let msg = info?.lastError ?? "unknown error"
                return .init(content: [.text(text: "Embedding model failed to download: \(msg). The model (\(size)) will re-download on next attempt.", annotations: nil, _meta: nil)], isError: true)
            case .available:
                // Model not yet cached — allow the download to proceed via ensureModel()
                break
            case .downloaded:
                break // shouldn't reach here given the isReady check above
            }
        }

        let topK = arguments?["top_k"]?.intValue ?? 5
        let fileFilter = arguments?["file_filter"]?.stringValue

        do {
            // Auto-index on first call
            let walk = FileWalker.walk(projectRoot: session.projectRoot)
            var files = walk.files
            if let filter = fileFilter {
                files = files.filter { $0.lowercased().contains(filter.lowercased()) }
            }

            try await engine.indexProject(root: session.projectRoot, files: files)

            // Search
            let results = try await engine.search(query: query, topK: topK)

            guard !results.isEmpty else {
                return .init(content: [.text(text: "No matching files found for: \(query)", annotations: nil, _meta: nil)])
            }

            var lines: [String] = ["// senkani_embed: \(results.count) results for \"\(query)\"\n"]
            for (i, r) in results.enumerated() {
                let pct = String(format: "%.0f", r.score * 100)
                // Read first line of file as preview
                let fullPath = session.projectRoot + "/" + r.file
                let preview = (try? String(contentsOfFile: fullPath, encoding: .utf8))?
                    .components(separatedBy: "\n")
                    .prefix(2)
                    .joined(separator: " ")
                    .prefix(80) ?? ""
                lines.append("  \(i+1). \(r.file) (score: \(pct)%)")
                if !preview.isEmpty { lines.append("     \(preview)") }
            }

            let output = lines.joined(separator: "\n")
            session.recordMetrics(rawBytes: files.count * 300, compressedBytes: output.utf8.count, feature: "embed")

            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
        } catch {
            return .init(content: [.text(text: "Embed error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
