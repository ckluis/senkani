import Foundation

/// V.13 real-chat (sub-item 2) — async chat-completion STREAMING seam
/// consumed by `ServeCommand`'s `streamHandler` when the MCP target
/// registers an MLX-backed implementation at startup. Mirrors `ChatEngine`'s
/// shape (Sendable, Core-only) so the CLI link surface stays MLX-free; the
/// MCP target registers the real Gemma-4-backed implementation that yields
/// `TokenDelta` chunks as MLX's `container.generate` AsyncStream produces
/// them.
///
/// Trade-off (Karpathy 2026-05-30): mid-stream tokens are emitted verbatim —
/// the non-streaming `MLXChatEngine.complete` trims `.whitespacesAndNewlines`
/// on the collected string, but the streaming path can't trim trailing
/// whitespace without buffering, which would defeat real token-by-token
/// arrival. Clients accumulate `delta.content` exactly as MLX produces it.
///
/// Tool-call streaming (v13d-1's `OpenAIChatStream.toolCallEvents`) is NOT
/// expressed through this seam in sub-item 2 — `ServeCommand` routes tool-use
/// requests through the legacy v13b collected-then-chunk path so the
/// existing tool-call contract is preserved. Real tool-call streaming can be
/// a follow-up if v13d tests flag a parity gap.
public protocol StreamingChatEngine: Sendable {
    func stream(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) -> AsyncThrowingStream<OpenAIChatHandler.TokenDelta, Error>
}

extension OpenAIChatHandler {

    /// V.13 real-chat (sub-item 2) — one streamed delta from a
    /// `StreamingChatEngine`. Carries the next content slice plus an optional
    /// finish-reason sentinel set on the final delta. The SSE renderer
    /// (`renderStreamingEvents`) emits the terminal `finish_reason: "stop"`
    /// chunk regardless of whether the source flags it — the field exists
    /// for forward-compat (a future engine could thread `"length"` or
    /// provider-specific stop signals through here).
    public struct TokenDelta: Sendable, Equatable {
        public let content: String
        public let finishReason: String?
        public init(content: String, finishReason: String? = nil) {
            self.content = content
            self.finishReason = finishReason
        }
    }

    /// V.13 real-chat (sub-item 2) — injectable streaming completion
    /// backend. Mirrors `OpenAIChatHandler.Engine`'s shape so tests pass a
    /// deterministic stub `AsyncThrowingStream<TokenDelta, Error>` without
    /// any MLX runtime; the live `ServeCommand` wires the registered
    /// `StreamingChatEngine` here.
    public struct StreamingEngine: Sendable {
        public let stream: @Sendable (
            _ model: String,
            _ messages: [ChatCompletionRequest.Message],
            _ tools: [ChatCompletionRequest.Tool]
        ) -> AsyncThrowingStream<TokenDelta, Error>

        public init(stream: @escaping @Sendable (
            _ model: String,
            _ messages: [ChatCompletionRequest.Message],
            _ tools: [ChatCompletionRequest.Tool]
        ) -> AsyncThrowingStream<TokenDelta, Error>) {
            self.stream = stream
        }
    }

    /// V.13 real-chat (sub-item 2) — render an SSE event-byte stream from a
    /// `StreamingChatEngine`'s `TokenDelta` source. Yields the leading role
    /// chunk, then one content chunk per non-empty `TokenDelta` as they
    /// arrive, then the terminal `finish_reason: "stop"` chunk. The
    /// `[DONE]` sentinel is appended by the surrounding
    /// `OpenAIChatStream.run` driver, not this stream.
    ///
    /// Errors thrown by the source are forwarded so `OpenAIChatStream`'s
    /// drive loop tears the connection down and emits a `clientCancel`
    /// terminal audit (the upstream contract: a write error is the only
    /// signal the run loop has — semantically a stream failure looks like a
    /// dropped connection to the caller).
    public static func renderStreamingEvents(
        id: String,
        created: Int,
        model: String,
        source: AsyncThrowingStream<TokenDelta, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let roleChunk = OpenAIChatStream.Chunk(
                    id: id, created: created, model: model,
                    choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)]
                )
                continuation.yield(OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(roleChunk)))

                do {
                    for try await delta in source {
                        if Task.isCancelled { break }
                        guard !delta.content.isEmpty else { continue }
                        let chunk = OpenAIChatStream.Chunk(
                            id: id, created: created, model: model,
                            choices: [.init(index: 0, delta: .init(content: delta.content), finishReason: nil)]
                        )
                        continuation.yield(OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(chunk)))
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let stopChunk = OpenAIChatStream.Chunk(
                    id: id, created: created, model: model,
                    choices: [.init(index: 0, delta: .init(), finishReason: "stop")]
                )
                continuation.yield(OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(stopChunk)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
