import Foundation

/// V.13a-3 — pure request→route→respond pipeline for
/// `POST /v1/chat/completions` (non-streaming), plus the per-request
/// audit-entry construction. No socket, no `Network` import — every
/// acceptance bullet is unit-testable.
///
/// Routing contract (Karpathy):
///   - The provisioned key's `ModelPreset` WINS. The request's `model`
///     field (e.g. `gpt-4o`) is logged for telemetry but does NOT change
///     routing. The response's `model` field reports the ACTUAL model.
///   - A key whose stored preset string is not a `ModelPreset` raw value
///     (the v13a-2 provisioner currently stores provider names like
///     `openai`) falls back to `.auto` — difficulty-scored routing. See
///     the round's filed follow-up for reconciling the provisioner's
///     `--preset` vocabulary with `ModelPreset`.
///
/// Model serving (scope, V.13a-3): this child ships the routing + audit
/// SURFACE. The assistant content is produced by an injectable `Engine`
/// so the surface is testable without a live LLM; `ServeCommand` wires a
/// placeholder engine that reports the routing decision. Real in-process
/// model inference is a later V.13 child (filed follow-up).
public enum OpenAIChatHandler {

    // MARK: - Engine (injectable completion backend)

    public struct Completion: Sendable, Equatable {
        public let content: String
        /// V.13d — non-empty when the model called a tool. When set, the
        /// response message carries `tool_calls` + `content: null` and
        /// `finish_reason: "tool_calls"`; `content` above is ignored.
        public let toolCalls: [OpenAIToolCall]
        public let promptTokens: Int
        public let completionTokens: Int
        public init(
            content: String,
            toolCalls: [OpenAIToolCall] = [],
            promptTokens: Int,
            completionTokens: Int
        ) {
            self.content = content
            self.toolCalls = toolCalls
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
        }
    }

    /// Produces the assistant completion for a routed request. Injected so
    /// tests (and the placeholder serve path) supply a deterministic body
    /// without a network round-trip. V.13d adds `tools` so the engine can
    /// decide to call a declared tool.
    public struct Engine: Sendable {
        public let complete: @Sendable (_ model: String, _ messages: [ChatCompletionRequest.Message], _ tools: [ChatCompletionRequest.Tool]) -> Completion
        public init(complete: @escaping @Sendable (_ model: String, _ messages: [ChatCompletionRequest.Message], _ tools: [ChatCompletionRequest.Tool]) -> Completion) {
            self.complete = complete
        }
    }

    // MARK: - Routing

    public struct Routing: Sendable, Equatable {
        public let presetUsed: ModelPreset
        public let resolvedTier: ModelTier
        /// The concrete model the tier maps to — the response's `model`.
        public let actualModel: String
        /// The client-requested model — telemetry only.
        public let modelLogged: String
    }

    /// Telemetry surfaced per request — `modelLogged` (the client's ask)
    /// is deliberately DISTINCT from `resolvedTier` (what actually ran).
    public struct TelemetryEvent: Sendable, Equatable {
        public let surface: String
        public let modelLogged: String
        public let resolvedTier: String
        public let presetUsed: String
    }

    public struct Result: Sendable {
        public let response: ChatCompletionResponse
        public let routing: Routing
        public let telemetry: TelemetryEvent
        public let auditFields: OpenAIAuditChain.AuditFields
        public let auditBodies: OpenAIAuditChain.AuditBodies
    }

    /// Map a stored preset string to a `ModelPreset`. Unrecognized values
    /// (e.g. provider names) fall back to `.auto`.
    public static func preset(forRecordPreset raw: String) -> ModelPreset {
        ModelPreset(rawValue: raw.lowercased()) ?? .auto
    }

    /// Resolve the routing decision. The preset wins; the request `model`
    /// is carried as `modelLogged` only.
    public static func route(request: ChatCompletionRequest, recordPreset: String) -> Routing {
        let preset = preset(forRecordPreset: recordPreset)
        let prompt = request.messages.map(\.content).joined(separator: "\n")
        let decision = ModelRouter.resolve(prompt: prompt, preset: preset)
        return Routing(
            presetUsed: preset,
            resolvedTier: decision.tier,
            actualModel: decision.tier.claudeModelValue,
            modelLogged: request.model
        )
    }

    // MARK: - Full pipeline

    /// Build the OpenAI response + telemetry + audit fields for a decoded
    /// request. Pure — `now` and `id` are injected for determinism.
    public static func handle(
        request: ChatCompletionRequest,
        recordPreset: String,
        keyLabel: String?,
        engine: Engine,
        now: Date,
        id: String
    ) -> Result {
        let routing = route(request: request, recordPreset: recordPreset)
        let completion = engine.complete(routing.actualModel, request.messages, request.tools ?? [])

        // V.13d — a tool-call completion sets `tool_calls` + `content: null`
        // + `finish_reason: "tool_calls"`; a normal completion sets the
        // string content + `finish_reason: "stop"`.
        let usesTools = !completion.toolCalls.isEmpty
        let choiceMessage: ChatCompletionResponse.Choice.Message = usesTools
            ? .init(role: "assistant", content: nil, toolCalls: completion.toolCalls)
            : .init(role: "assistant", content: completion.content)
        let finishReason = usesTools ? "tool_calls" : "stop"

        let response = ChatCompletionResponse(
            id: id,
            created: Int(now.timeIntervalSince1970),
            model: routing.actualModel,
            choices: [
                .init(index: 0, message: choiceMessage, finishReason: finishReason)
            ],
            usage: .init(
                promptTokens: completion.promptTokens,
                completionTokens: completion.completionTokens,
                totalTokens: completion.promptTokens + completion.completionTokens
            )
        )

        let telemetry = TelemetryEvent(
            surface: "chat",
            modelLogged: routing.modelLogged,
            resolvedTier: routing.resolvedTier.rawValue,
            presetUsed: routing.presetUsed.rawValue
        )

        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: completion.promptTokens,
            completionTokenCount: completion.completionTokens,
            status: "ok"
        )

        // When the model called a tool the response carries no text — the
        // audit body names the called tool(s) instead of an empty string.
        let responseBody = usesTools
            ? "tool_calls=[" + completion.toolCalls.map(\.function.name).joined(separator: ",") + "]"
            : completion.content
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: requestSummary(request),
            responseBody: responseBody
        )

        return Result(
            response: response,
            routing: routing,
            telemetry: telemetry,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    // MARK: - Decode / encode (JSON + HTTP framing)

    /// Decode an OpenAI chat-completion request body. Returns nil for
    /// malformed JSON or an unsupported shape (e.g. array-valued
    /// `content`, which yields a `String` decode failure).
    public static func decodeRequest(_ body: Data) -> ChatCompletionRequest? {
        try? JSONDecoder().decode(ChatCompletionRequest.self, from: body)
    }

    /// Render a successful `chat.completion` as a framed `200` HTTP
    /// response. Uses sorted keys so the body is byte-deterministic.
    public static func encodeResponse(_ response: ChatCompletionResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"error\":{\"message\":\"encode failure\",\"type\":\"server_error\"}}"
        return OpenAIHTTPResponse.render(code: 200, message: "OK", body: json)
    }

    /// Render an OpenAI-shaped error as a framed HTTP response.
    public static func errorResponse(code: Int, httpMessage: String, message: String, type: String, errorCode: String?) -> Data {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body: String
        if let errorCode {
            body = "{\"error\":{\"message\":\"\(escaped)\",\"type\":\"\(type)\",\"code\":\"\(errorCode)\"}}"
        } else {
            body = "{\"error\":{\"message\":\"\(escaped)\",\"type\":\"\(type)\"}}"
        }
        return OpenAIHTTPResponse.render(code: code, message: httpMessage, body: body)
    }

    // MARK: - Helpers

    /// Rough token estimate — ~4 chars/token, floor of 1 for non-empty.
    /// Good enough for `usage` accounting on the placeholder path; a real
    /// engine reports exact counts.
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.count + 3) / 4)
    }

    /// Generate a `chatcmpl-…` id. Random hex; not security-sensitive.
    public static func generateID() -> String {
        let hex = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        return "chatcmpl-\(hex)"
    }

    /// Non-sensitive request summary stored in the audit `request_body`
    /// column when `--audit-bodies` is on: model + message count + roles.
    /// (The full prompt text is the response engine's input; the audit
    /// body captures the request envelope, not a transcript dump.)
    public static func requestSummary(_ request: ChatCompletionRequest) -> String {
        let roles = request.messages.map(\.role).joined(separator: ",")
        var summary = "model=\(request.model) messages=\(request.messages.count) roles=[\(roles)]"
        // V.13d — append the declared-tool count ONLY when the request uses
        // tools, so a non-tool request's summary (and therefore its audit
        // hash) is byte-identical to the v13a-3 shape.
        let toolCount = request.tools?.count ?? 0
        if toolCount > 0 { summary += " tools=\(toolCount)" }
        return summary
    }

    // MARK: - V.13d tool-use scope + validation

    /// True when the request declares one or more tools (a tool-use
    /// round-trip is requested). A nil or empty `tools` array is not a
    /// tool-use request.
    public static func requestUsesTools(_ request: ChatCompletionRequest) -> Bool {
        !(request.tools ?? []).isEmpty
    }

    /// The `tools` surface scope gate. A key may use tool-use only when its
    /// scope includes `"tools"`. Path-based `chat`/`embeddings` scope is
    /// enforced by `OpenAIAuthGate`; the `tools` scope is body-derived (the
    /// request carries `tools:`), so it is enforced here — see
    /// `OpenAIAuthGate.surface(forPath:)`.
    public static func scopeAllowsTools(_ scope: [String]) -> Bool {
        scope.contains("tools")
    }

    /// Validate the declared tools' shape. Returns a human-readable reason
    /// when a tool is malformed (a non-`function` type, or an empty
    /// function name), or nil when every declared tool is well-formed.
    /// (A structurally malformed `tools` — missing `function`/`name`, a
    /// non-array — fails JSON decode upstream and never reaches here.)
    public static func toolsValidationMessage(_ request: ChatCompletionRequest) -> String? {
        for tool in request.tools ?? [] {
            if tool.type != "function" {
                return "unsupported tool type '\(tool.type)' (only 'function' is supported)"
            }
            if tool.function.name.isEmpty {
                return "tool function name must be non-empty"
            }
        }
        return nil
    }

    /// Single pre-flight for a tool-use request: a framed `400` when the
    /// declared tools are malformed, a framed `403` (`insufficient_scope`)
    /// when the key's scope excludes `tools`, or nil when the request is
    /// acceptable (no tools, or tools + valid schema + in-scope key). Both
    /// the non-streaming chat handler and the streaming handler funnel
    /// through this so the error shape is rendered in exactly one place.
    public static func toolsPreflightError(request: ChatCompletionRequest, scope: [String]) -> Data? {
        guard requestUsesTools(request) else { return nil }
        if let reason = toolsValidationMessage(request) {
            return errorResponse(
                code: 400, httpMessage: "Bad Request",
                message: reason,
                type: "invalid_request_error", errorCode: "invalid_request"
            )
        }
        if !scopeAllowsTools(scope) {
            return errorResponse(
                code: 403, httpMessage: "Forbidden",
                message: "key scope does not include surface 'tools'",
                type: "invalid_request_error", errorCode: "insufficient_scope"
            )
        }
        return nil
    }
}
