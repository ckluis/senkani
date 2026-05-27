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
        public let promptTokens: Int
        public let completionTokens: Int
        public init(content: String, promptTokens: Int, completionTokens: Int) {
            self.content = content
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
        }
    }

    /// Produces the assistant completion for a routed request. Injected so
    /// tests (and the placeholder serve path) supply a deterministic body
    /// without a network round-trip.
    public struct Engine: Sendable {
        public let complete: @Sendable (_ model: String, _ messages: [ChatCompletionRequest.Message]) -> Completion
        public init(complete: @escaping @Sendable (_ model: String, _ messages: [ChatCompletionRequest.Message]) -> Completion) {
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
        let completion = engine.complete(routing.actualModel, request.messages)

        let response = ChatCompletionResponse(
            id: id,
            created: Int(now.timeIntervalSince1970),
            model: routing.actualModel,
            choices: [
                .init(
                    index: 0,
                    message: .init(role: "assistant", content: completion.content),
                    finishReason: "stop"
                )
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

        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: requestSummary(request),
            responseBody: completion.content
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
    static func requestSummary(_ request: ChatCompletionRequest) -> String {
        let roles = request.messages.map(\.role).joined(separator: ",")
        return "model=\(request.model) messages=\(request.messages.count) roles=[\(roles)]"
    }
}
