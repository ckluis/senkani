import Foundation

/// V.13 real-chat — async chat-completion seam consumed by `ServeCommand`
/// when the MCP target registers an MLX-backed handler at startup. Mirrors
/// `EmbeddingEngine`'s shape (1 async method, `Sendable`, Core-only) so
/// the CLI link surface stays MLX-free; the MCP target registers the
/// real Gemma-4-backed implementation.
///
/// Returns the assistant's content + any `toolCalls` it selected + prompt
/// and completion token estimates. Tokenizer-accurate usage counts (vs.
/// `OpenAIChatHandler.estimateTokens` heuristic) land in sub-item 3.
public protocol ChatEngine: Sendable {
    func chat(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) async throws -> OpenAIChatHandler.Completion
}
