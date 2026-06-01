import Foundation

/// V.13c real-engine — bridge between `EmbeddingEngine` (async, registered
/// by the MCP target) and `OpenAIEmbeddingsHandler.Engine` (sync, consumed
/// inside the `NWListener`'s synchronous response closure). Plus the
/// `model_not_available` readiness gate `ServeCommand` runs BEFORE dispatch
/// when a real handler is registered.
///
/// Why a sync bridge: the listener closure is `(Data) -> Data?` and runs on
/// the listener's dispatch queue; making it async would require refactoring
/// the listener. MLX inference is already gated by `MLXInferenceLock.shared`
/// (serial across the process), so blocking the listener thread on the
/// inference task is the same wait the lock already imposes.
public enum OpenAIEmbeddingsServeBridge {

    /// Wrap a registered `EmbeddingEngine` as a sync
    /// `OpenAIEmbeddingsHandler.Engine`. Bridges the async embed call via
    /// `ServeBridge.runBlocking` — the listener thread waits while the
    /// MLX task runs under `MLXInferenceLock.shared`. On thrown error,
    /// returns an empty embedding so the caller can decide how to render
    /// (the production caller — `ServeCommand` — gates on
    /// `ModelManager.isReady` upstream, so this path is normally
    /// unreachable in shipped builds).
    public static func syncEngine(for handler: any EmbeddingEngine) -> OpenAIEmbeddingsHandler.Engine {
        OpenAIEmbeddingsHandler.Engine { model, inputs in
            let embedding = ServeBridge.runBlocking {
                try? await handler.embed(model: model, inputs: inputs)
            }
            return embedding ?? OpenAIEmbeddingsHandler.Embedding(vectors: [], promptTokens: 0)
        }
    }

    /// V.13c real-engine — `model_not_available` readiness gate. Returns a
    /// framed 503 response when the registered handler exists but the
    /// embedding model is NOT downloaded yet; returns nil to let dispatch
    /// continue otherwise.
    ///
    /// Scope decision (2026-05-28, Q2): structured `HTTP 503` with
    /// `error.type: "model_not_available"` pointing at the Models pane /
    /// `senkani doctor`. No auto-pull on the request hot path.
    public static func readinessResponse(modelId: String, isReady: Bool) -> Data? {
        guard !isReady else { return nil }
        return OpenAIEmbeddingsHandler.errorResponse(
            code: 503,
            httpMessage: "Service Unavailable",
            message: "Embedding model '\(modelId)' is not yet available. Open the Models pane in the Senkani app or run `senkani doctor` to install it.",
            type: "model_not_available",
            errorCode: "model_not_available"
        )
    }
}
