import Foundation

/// V.13b-4c — synchronous dispatch helper that the serve-path chatHandler
/// closure calls for `.quick/.balanced/.frontier` requests. Implements the
/// b-2b safety bundle:
///   - runs `ClaudeAPIChatEngine.chat(...)` OFF the listener thread via
///     `ServeBridge.runBlocking` (the engine is already configured with
///     `RetryPolicy.serveSafe` + per-request `URLRequest.timeoutInterval`
///     by `ClaudeAPIServeEngineFactory.make(...)`);
///   - NEVER wraps the call in `MLXInferenceLock.shared` — that's a
///     Gemma/Metal lock; a rate-limited Claude request only blocks its
///     own NWListener connection thread, and the lock would falsely
///     serialize independent network requests across the process;
///   - catches the TYPED `ClaudeAPIChatEngineError` (no `try?` swallow)
///     and maps to (httpStatus, wire bytes) via the static mapper at
///     `ClaudeAPIChatEngine.openAIWireResponse(_:)`;
///   - builds the matching `AuditFields` for ServeCommand's single
///     `OpenAIServedRequestSink.record(...)` call (one row per request,
///     real httpStatus across success / 429 / 502 / 400 branches).
///
/// All work in this enum is pure-sync; no actor hops, no shared mutable
/// state. The Anthropic key is held in the engine instance only — this
/// helper never sees the raw key, only the `keyLabel` for the audit row.
public enum ClaudeAPIServeDispatch {

    /// Outcome of one non-local-tier dispatch through the Claude engine.
    /// The caller (ServeCommand chatHandler closure) records exactly one
    /// audit row using `auditFields` + `httpStatus`, optionally with the
    /// opt-in `auditBodies` when `--audit-bodies` is on, and returns
    /// `data` as the wire response.
    public struct Outcome: Sendable {
        public let httpStatus: Int
        public let data: Data
        public let auditFields: OpenAIAuditChain.AuditFields
        public let auditBodies: OpenAIAuditChain.AuditBodies?

        public init(
            httpStatus: Int,
            data: Data,
            auditFields: OpenAIAuditChain.AuditFields,
            auditBodies: OpenAIAuditChain.AuditBodies?
        ) {
            self.httpStatus = httpStatus
            self.data = data
            self.auditFields = auditFields
            self.auditBodies = auditBodies
        }
    }

    /// Dispatch a single non-local-tier chat request through the Claude
    /// engine. Routing is precomputed by the caller (already-resolved tier
    /// + `actualModel`). `id` is the pre-allocated `chatcmpl-…` id used for
    /// both the response and any audit body.
    public static func dispatch(
        engine: ClaudeAPIChatEngine,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> Outcome {
        // Build the heuristic prompt-token count up front — it's used for
        // BOTH the success path and any error audit row (no completion
        // bytes in the error case, so completionTokenCount is 0).
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
        let model = routing.actualModel
        let messages = request.messages
        let tools = request.tools ?? []

        // Bridge async → sync OFF the listener thread (b-2b safety bundle).
        // We capture EITHER a successful Completion OR the typed error;
        // the closure cannot throw across the boundary, so we union them.
        enum Captured: Sendable {
            case success(OpenAIChatHandler.Completion)
            case engineError(ClaudeAPIChatEngineError)
            case cancellation
            case other(String)
        }
        let captured: Captured = ServeBridge.runBlocking {
            do {
                let completion = try await engine.chat(
                    model: model, messages: messages, tools: tools
                )
                return Captured.success(completion)
            } catch let e as ClaudeAPIChatEngineError {
                return Captured.engineError(e)
            } catch is CancellationError {
                return Captured.cancellation
            } catch {
                // Anything else collapses to a fixed sentinel — never
                // `String(describing:)` (Schneier info-leak guard).
                return Captured.other("unknown-error")
            }
        }

        switch captured {
        case .success(let completion):
            return successOutcome(
                completion: completion,
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                id: id
            )
        case .engineError(let err):
            return errorOutcome(
                error: err,
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                promptTokens: promptTokens
            )
        case .cancellation:
            // Listener-thread cancellation surfaces the same shape as a
            // generic network error so the wire contract is uniform.
            return errorOutcome(
                error: .networkError(code: -999),
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                promptTokens: promptTokens
            )
        case .other:
            return errorOutcome(
                error: .networkError(code: -1),
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                promptTokens: promptTokens
            )
        }
    }

    // MARK: - Success path

    private static func successOutcome(
        completion: OpenAIChatHandler.Completion,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> Outcome {
        let usesTools = !completion.toolCalls.isEmpty
        let choiceMessage: ChatCompletionResponse.Choice.Message = usesTools
            ? .init(role: "assistant", content: nil, toolCalls: completion.toolCalls)
            : .init(role: "assistant", content: completion.content)
        let finishReason = usesTools ? "tool_calls" : "stop"

        let resolvedPromptTokens = completion.realPromptTokens ?? completion.promptTokens
        let resolvedCompletionTokens = completion.realCompletionTokens ?? completion.completionTokens

        let response = ChatCompletionResponse(
            id: id,
            created: Int(now.timeIntervalSince1970),
            model: routing.actualModel,
            choices: [
                .init(index: 0, message: choiceMessage, finishReason: finishReason)
            ],
            usage: .init(
                promptTokens: resolvedPromptTokens,
                completionTokens: resolvedCompletionTokens,
                totalTokens: resolvedPromptTokens + resolvedCompletionTokens
            )
        )

        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: resolvedPromptTokens,
            completionTokenCount: resolvedCompletionTokens,
            status: "ok"
        )
        let responseBody = usesTools
            ? "tool_calls=[" + completion.toolCalls.map(\.function.name).joined(separator: ",") + "]"
            : completion.content
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: responseBody
        )
        return Outcome(
            httpStatus: 200,
            data: OpenAIChatHandler.encodeResponse(response),
            auditFields: fields,
            auditBodies: bodies
        )
    }

    // MARK: - Error path

    private static func errorOutcome(
        error: ClaudeAPIChatEngineError,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        promptTokens: Int
    ) -> Outcome {
        let mapped = ClaudeAPIChatEngine.openAIWireResponse(error)
        // Lauret re-audit FOLD: 401 → `upstream_auth_error` audit token to
        // match the wire `error.code`, so an operator querying the persisted
        // request log can distinguish auth failures from other upstream 502s
        // without reparsing wire bytes.
        let statusToken: String
        switch error {
        case .rateLimited:                statusToken = "upstream_rate_limited"
        case .upstreamError(let status, _) where status == 401:
                                          statusToken = "upstream_auth_error"
        case .upstreamError:              statusToken = "upstream_error"
        case .decodeError:                statusToken = "upstream_decode_error"
        case .networkError:               statusToken = "upstream_network_error"
        case .upstreamModelUnavailable:   statusToken = "model_not_found"
        }
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: promptTokens,
            completionTokenCount: 0,
            status: statusToken
        )
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: "[error: \(statusToken)]"
        )
        return Outcome(
            httpStatus: mapped.httpStatus,
            data: mapped.data,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    /// V.13b-4c — `stream:true` non-local-tier rendering. The listener
    /// closure detects the case + asks for this complete framed 501; no
    /// SSE byte is sent. ServeCommand records one audit row with the
    /// returned fields + httpStatus 501.
    public static func streamNotSupportedOutcome(
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date
    ) -> Outcome {
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
        let data = OpenAIChatHandler.errorResponse(
            code: 501,
            httpMessage: "Not Implemented",
            message: "streaming chat is not yet supported on non-local tiers; rerun with stream:false or against `.local`",
            type: "stream_not_supported_yet",
            errorCode: "stream_not_supported_yet"
        )
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: promptTokens,
            completionTokenCount: 0,
            status: "stream_not_supported_yet"
        )
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: "[stream_not_supported_yet]"
        )
        return Outcome(
            httpStatus: 501,
            data: data,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    /// V.13b-4c — `backend_not_configured` rendering when no anthropic
    /// key was loaded at serve start (zero labels in the vault). The 503
    /// preserves today's stub text verbatim so existing operator tooling
    /// stays compatible.
    public static func backendNotConfiguredOutcome(
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date
    ) -> Outcome {
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
        let data = OpenAIChatServeBridge.backendNotConfiguredResponse(tier: routing.resolvedTier)
            ?? OpenAIChatHandler.errorResponse(
                code: 503, httpMessage: "Service Unavailable",
                message: "backend not configured", type: "backend_not_configured",
                errorCode: "backend_not_configured"
            )
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: promptTokens,
            completionTokenCount: 0,
            status: "backend_not_configured"
        )
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: "[backend_not_configured]"
        )
        return Outcome(
            httpStatus: 503,
            data: data,
            auditFields: fields,
            auditBodies: bodies
        )
    }
}
