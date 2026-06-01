import Foundation

/// V.13 real-chat — bridge between `ChatEngine` (async, registered by the
/// MCP target) and `OpenAIChatHandler.Engine` (sync, consumed inside the
/// `NWListener`'s synchronous response closure). Mirrors
/// `OpenAIEmbeddingsServeBridge.syncEngine` 1:1.
///
/// Sub-item 3 adds the two pre-dispatch 503 gates `ServeCommand` runs after
/// routing: `backendNotConfiguredResponse(tier:)` for non-local tiers
/// (`.quick` / `.balanced` / `.frontier`) — the Claude-API arm
/// (`phase-v13-real-chat-engine-claude-api-arm-2026-05-28`) is not yet
/// wired, so requests routed to those tiers deny with an actionable
/// message — and `readinessResponse(modelTier:isReady:)` for `.local`
/// when a real chat handler is registered but no Gemma 4 tier fits /
/// is installed (mirrors `OpenAIEmbeddingsServeBridge.readinessResponse`).
///
/// Why a sync bridge: the listener closure is `(Data) -> Data?` and runs
/// on the listener's dispatch queue; making it async would require
/// refactoring the listener. MLX inference is already gated by
/// `MLXInferenceLock.shared` (serial across the process), so blocking the
/// listener thread on the inference task is the same wait the lock
/// already imposes.
public enum OpenAIChatServeBridge {

    /// Wrap a registered `ChatEngine` as a sync
    /// `OpenAIChatHandler.Engine`. Bridges the async chat call via
    /// `ServeBridge.runBlocking` — the listener thread waits while the MLX
    /// task runs under `MLXInferenceLock.shared`. On thrown error,
    /// returns an empty completion so the caller can decide how to
    /// render (the production caller — `ServeCommand` — will gate on
    /// `ModelManager.isReady` upstream once sub-item 3 lands; until
    /// then this matches v13c's pre-readiness-gate semantics).
    public static func syncEngine(for handler: any ChatEngine) -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { model, messages, tools in
            let completion = ServeBridge.runBlocking {
                try? await handler.chat(model: model, messages: messages, tools: tools)
            }
            return completion ?? OpenAIChatHandler.Completion(content: "", promptTokens: 0, completionTokens: 0)
        }
    }

    /// V.13 real-chat (sub-item 3) — `backend_not_configured` tier gate.
    /// Returns a framed 503 when the resolved tier is non-local (`.quick`
    /// / `.balanced` / `.frontier`) because the Claude-API backend
    /// (`phase-v13-real-chat-engine-claude-api-arm-2026-05-28`) is not
    /// yet wired; returns nil to let `.local` dispatch continue.
    ///
    /// The 503 message names the filed Claude-API child item and the
    /// `senkani vault add anthropic-key` command so the operator has a
    /// working pointer rather than a generic "try again later". The
    /// vault + EgressProxy plumbing is OUT of scope for sub-item 3 — the
    /// helper text references them as the operator's next action.
    public static func backendNotConfiguredResponse(tier: ModelTier) -> Data? {
        switch tier {
        case .local:
            return nil
        case .quick, .balanced, .frontier:
            let message = "Non-local chat tier '\(tier.rawValue)' is not yet configured. "
                + "The Claude-API backend lands in `phase-v13-real-chat-engine-claude-api-arm-2026-05-28`; "
                + "until then, provision a key with `senkani vault add anthropic-key` and rerun "
                + "against a `.local` tier on this build."
            return OpenAIChatHandler.errorResponse(
                code: 503,
                httpMessage: "Service Unavailable",
                message: message,
                type: "backend_not_configured",
                errorCode: "backend_not_configured"
            )
        }
    }

    /// V.13 real-chat (sub-item 3) — `model_not_available` readiness gate
    /// for the `.local` tier. Returns a framed 503 when the registered
    /// chat handler exists but no Gemma 4 tier is downloaded (or fits
    /// this machine's RAM); returns nil to let dispatch continue. Mirrors
    /// `OpenAIEmbeddingsServeBridge.readinessResponse` 1:1.
    ///
    /// Scope decision (parent v13 2026-05-28): structured `HTTP 503` with
    /// `error.type: "model_not_available"` pointing at the Models pane /
    /// `senkani doctor`. No auto-pull on the request hot path.
    public static func readinessResponse(modelTier: ModelTier, isReady: Bool) -> Data? {
        guard !isReady else { return nil }
        let message = "No Gemma 4 tier is available for `.\(modelTier.rawValue)` chat. "
            + "Open the Models pane in the Senkani app or run `senkani doctor` to install "
            + "a Gemma 4 tier that fits this machine's RAM."
        return OpenAIChatHandler.errorResponse(
            code: 503,
            httpMessage: "Service Unavailable",
            message: message,
            type: "model_not_available",
            errorCode: "model_not_available"
        )
    }
}
