import Foundation
import Core

/// V.13c real-engine — MCP-side adapter that registers an MLX-backed
/// `EmbeddingEngine` with `Core.ModelManager`. `ServeCommand` (in CLI)
/// resolves this at request time when `senkani serve --openai` handles
/// `POST /v1/embeddings`. Mirrors `MCPMain.run`'s
/// `registerDownloadHandler` / `registerVerificationHandler` pattern —
/// Core stays MLX-free; the CLI link surface is unchanged.
struct MLXEmbeddingEngineAdapter: EmbeddingEngine {
    func embed(model: String, inputs: [String]) async throws -> OpenAIEmbeddingsHandler.Embedding {
        // Reuse the SAME `EmbedEngine` actor + `MLXInferenceLock.shared`
        // the `senkani_embed` MCP tool already uses (no parallel embedding
        // stack). `model` is informational — `ModelManager.embeddingModelID`
        // is the single id this engine serves; the handler logs it.
        let result = try await EmbedTool.engine.embedStrings(inputs)
        return OpenAIEmbeddingsHandler.Embedding(
            vectors: result.vectors,
            promptTokens: result.promptTokens
        )
    }
}

enum EmbeddingHandlerRegistration {
    /// Register the MLX-backed embedding handler with `ModelManager.shared`.
    /// Called from `MCPMain.run` at startup; idempotent (the registration
    /// slot replaces on second call).
    static func register() {
        ModelManager.shared.registerEmbeddingHandler(MLXEmbeddingEngineAdapter())
    }
}
