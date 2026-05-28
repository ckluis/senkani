import Foundation

/// V.13c real-engine — async embedding-backend seam consumed by
/// `ServeCommand` when the MCP target registers an MLX-backed handler at
/// startup. Mirrors `ModelManager.registerDownloadHandler` /
/// `registerVerificationHandler`: Core declares the protocol so the CLI
/// link surface stays MLX-free; the MCP target registers the real
/// `MLXEmbedders`-backed implementation.
///
/// Returns vectors plus the REAL tokenizer count (not v13c's
/// ~4-chars/token heuristic), so `usage.prompt_tokens` reflects what the
/// model actually saw.
public protocol EmbeddingEngine: Sendable {
    func embed(model: String, inputs: [String]) async throws -> OpenAIEmbeddingsHandler.Embedding
}
