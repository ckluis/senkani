import Foundation

/// V.13c — pure request→embed→respond pipeline for `POST /v1/embeddings`,
/// plus the per-request audit-entry construction. No socket, no `Network`
/// import — every acceptance bullet is unit-testable.
///
/// Model source (Karpathy, scope V.13c): the embedding model is sourced
/// from `ModelManager` (the SAME `minilm-l6` the MCP `senkani_embed` tool
/// and the RRF ranker use, via `ModelManager.embeddingModelID`). This
/// surface introduces NO parallel embedding stack — it resolves the model
/// identity from the registry and reports it as the response `model`.
///
/// Vector serving (scope, V.13c — mirrors v13a-3): this child ships the
/// embeddings SURFACE (OpenAI shape + audit + ModelManager-sourced model
/// identity). The raw vectors are produced by an injectable `Engine` so the
/// surface is testable without a live MLX run; `ServeCommand` wires a
/// placeholder engine that sources the model id from `ModelManager`. Real
/// on-device MiniLM inference is the shared V.13 backend (filed follow-up).
public enum OpenAIEmbeddingsHandler {

    /// The audit/telemetry surface name for this endpoint.
    public static let surface = "embeddings"

    // MARK: - Engine (injectable embedding backend)

    public struct Embedding: Sendable, Equatable {
        public let vectors: [[Float]]
        public let promptTokens: Int
        public init(vectors: [[Float]], promptTokens: Int) {
            self.vectors = vectors
            self.promptTokens = promptTokens
        }
    }

    /// Produces one vector per input. Injected so tests (and the placeholder
    /// serve path) supply deterministic vectors without an MLX round-trip.
    public struct Engine: Sendable {
        public let embed: @Sendable (_ model: String, _ inputs: [String]) -> Embedding
        public init(embed: @escaping @Sendable (_ model: String, _ inputs: [String]) -> Embedding) {
            self.embed = embed
        }
    }

    // MARK: - Model resolution (sourced from ModelManager)

    /// The model id this surface serves, resolved from `ModelManager`. When
    /// the registry has the embedding model (the production path), its
    /// registered `id` is returned; otherwise the canonical constant is the
    /// fallback. Either way the value is the SINGLE
    /// `ModelManager.embeddingModelID` — no parallel id is invented here.
    public static func resolvedModel() -> String {
        ModelManager.shared.model(ModelManager.embeddingModelID)?.id
            ?? ModelManager.embeddingModelID
    }

    public struct TelemetryEvent: Sendable, Equatable {
        public let surface: String
        public let modelLogged: String
        public let resolvedModel: String
        public let inputCount: Int
    }

    public struct Result: Sendable {
        public let response: EmbeddingsResponse
        public let telemetry: TelemetryEvent
        public let auditFields: OpenAIAuditChain.AuditFields
        public let auditBodies: OpenAIAuditChain.AuditBodies
    }

    // MARK: - Full pipeline

    /// Build the OpenAI response + telemetry + audit fields for a decoded
    /// request. Pure — `now` is injected for determinism.
    public static func handle(
        request: EmbeddingsRequest,
        keyLabel: String?,
        engine: Engine,
        now: Date
    ) -> Result {
        let actualModel = resolvedModel()
        let embedding = engine.embed(actualModel, request.input)

        let data = embedding.vectors.enumerated().map { index, vector in
            EmbeddingsResponse.Datum(index: index, embedding: vector)
        }
        let response = EmbeddingsResponse(
            data: data,
            model: actualModel,
            // Embeddings have no completion — total == prompt.
            usage: .init(promptTokens: embedding.promptTokens, totalTokens: embedding.promptTokens)
        )

        let telemetry = TelemetryEvent(
            surface: surface,
            modelLogged: request.model,
            resolvedModel: actualModel,
            inputCount: request.input.count
        )

        // The audit chain shape is shared with the chat surface — populate
        // `resolved_tier` with the actual embedding model (what ran) and
        // `preset_used` with the fixed surface name; `completion_token_count`
        // is 0 (no generation).
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: surface,
            modelLogged: request.model,
            presetUsed: surface,
            resolvedTier: actualModel,
            promptTokenCount: embedding.promptTokens,
            completionTokenCount: 0,
            status: "ok"
        )

        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: requestSummary(request),
            responseBody: "embeddings=\(data.count) dim=\(data.first?.embedding.count ?? 0)"
        )

        return Result(
            response: response,
            telemetry: telemetry,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    // MARK: - Decode / encode (JSON + HTTP framing)

    /// Decode an OpenAI embeddings request body. Returns nil for malformed
    /// JSON or an unsupported `input` shape (token ids / array-of-arrays /
    /// object), which the caller maps to a `400`. The string form of
    /// `input` is normalized to a one-element array.
    public static func decodeRequest(_ body: Data) -> EmbeddingsRequest? {
        guard let request = try? JSONDecoder().decode(EmbeddingsRequest.self, from: body) else {
            return nil
        }
        // An empty `input` array is a client error → 400.
        guard !request.input.isEmpty else { return nil }
        return request
    }

    /// Render a successful embeddings list as a framed `200` HTTP response.
    /// Uses sorted keys so the body is byte-deterministic.
    public static func encodeResponse(_ response: EmbeddingsResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"error\":{\"message\":\"encode failure\",\"type\":\"server_error\"}}"
        return OpenAIHTTPResponse.render(code: 200, message: "OK", body: json)
    }

    /// Render an OpenAI-shaped error as a framed HTTP response. Shares the
    /// chat handler's error JSON contract.
    public static func errorResponse(code: Int, httpMessage: String, message: String, type: String, errorCode: String?) -> Data {
        OpenAIChatHandler.errorResponse(
            code: code, httpMessage: httpMessage,
            message: message, type: type, errorCode: errorCode
        )
    }

    // MARK: - Helpers

    /// Rough token estimate across all inputs — reuses the chat handler's
    /// ~4 chars/token heuristic. A real engine reports exact counts.
    public static func estimateTokens(_ inputs: [String]) -> Int {
        inputs.reduce(0) { $0 + OpenAIChatHandler.estimateTokens($1) }
    }

    /// Non-sensitive request summary for the audit `request_body` column
    /// (`--audit-bodies` only): model + input count. The input TEXT is never
    /// stored in the audit fields — only in the opt-in body, and even then
    /// as an envelope, matching the chat surface's posture.
    static func requestSummary(_ request: EmbeddingsRequest) -> String {
        "model=\(request.model) inputs=\(request.input.count)"
    }
}
