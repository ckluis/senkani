import Testing
import Foundation
@testable import Core

/// V.13c real-engine — covers `EmbeddingEngine` protocol + the
/// `ModelManager` registration entry point + the `OpenAIEmbeddingsServeBridge`
/// (sync bridge + `model_not_available` readiness gate).
///
/// The MLX-backed handler itself lives in `Sources/MCP` and runs against
/// real on-device MiniLM during the operator/Cowork manual-log walk; here
/// we exercise the seam with a stub `EmbeddingEngine` so the assertions
/// run in CI without a model download.
@Suite("V.13c real-engine — EmbeddingEngine registration + serve bridge")
struct EmbeddingEngineRegistrationTests {

    /// Stub `EmbeddingEngine` returning recorded vectors + a known
    /// tokenizer count. Mirrors what an MLX-backed implementation would
    /// return — vectors are 384-dim per the MiniLM-L6 surface contract.
    private struct StubEmbeddingEngine: EmbeddingEngine {
        let vectorsPerInput: [Float]
        let promptTokens: Int

        func embed(model: String, inputs: [String]) async throws -> OpenAIEmbeddingsHandler.Embedding {
            let vectors = inputs.map { _ in vectorsPerInput }
            return OpenAIEmbeddingsHandler.Embedding(
                vectors: vectors,
                promptTokens: promptTokens
            )
        }
    }

    private struct ThrowingEmbeddingEngine: EmbeddingEngine {
        struct E: Error {}
        func embed(model: String, inputs: [String]) async throws -> OpenAIEmbeddingsHandler.Embedding {
            throw E()
        }
    }

    // MARK: - 1. Registration + resolution

    @Test("registered EmbeddingEngine round-trips through ModelManager")
    func registrationRoundTrip() {
        // Use a custom ModelManager instance so the test doesn't leak
        // registration state into ModelManager.shared (other tests would
        // see the stub).
        let mgr = ModelManager(
            hfCacheBase: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            metadataURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        )
        #expect(mgr.resolvedEmbeddingHandler() == nil)

        let stub = StubEmbeddingEngine(vectorsPerInput: [0.1, 0.2, 0.3], promptTokens: 7)
        mgr.registerEmbeddingHandler(stub)

        // Round-trip: registered handler is resolvable.
        let resolved = mgr.resolvedEmbeddingHandler()
        #expect(resolved != nil)
    }

    // MARK: - 2. Sync bridge — vectors + real tokenizer count

    @Test("sync bridge passes through vectors + real tokenizer count")
    func syncBridgePassThrough() {
        let recorded: [Float] = (0..<384).map { Float($0) / 384.0 }
        let stub = StubEmbeddingEngine(vectorsPerInput: recorded, promptTokens: 42)
        let engine = OpenAIEmbeddingsServeBridge.syncEngine(for: stub)

        let embedding = engine.embed(ModelManager.embeddingModelID, ["alpha", "beta"])
        #expect(embedding.vectors.count == 2)
        #expect(embedding.vectors[0].count == 384)
        #expect(embedding.vectors[0] == recorded)
        // Real tokenizer count from the stub — not the
        // `OpenAIEmbeddingsHandler.estimateTokens` ~4-chars/token heuristic.
        #expect(embedding.promptTokens == 42)
    }

    @Test("sync bridge surfaces a thrown EmbeddingEngine error as an empty embedding")
    func syncBridgeErrorPath() {
        let engine = OpenAIEmbeddingsServeBridge.syncEngine(for: ThrowingEmbeddingEngine())
        let embedding = engine.embed("any", ["input"])
        #expect(embedding.vectors.isEmpty)
        #expect(embedding.promptTokens == 0)
    }

    // MARK: - 3. Readiness gate — model_not_available

    @Test("readiness gate returns a framed 503 with error.type=model_not_available when not ready")
    func readinessGateNotAvailable() {
        let response = OpenAIEmbeddingsServeBridge.readinessResponse(
            modelId: ModelManager.embeddingModelID,
            isReady: false
        )
        #expect(response != nil)
        let text = String(decoding: response!, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 503 Service Unavailable"))
        #expect(text.contains("\"type\":\"model_not_available\""))
        #expect(text.contains("minilm-l6"))
        // Operator-grade message points at the install path (Models pane /
        // `senkani doctor`) — not a generic "try again later".
        #expect(text.contains("Models pane") || text.contains("senkani doctor"))
    }

    @Test("readiness gate returns nil when the model is ready")
    func readinessGateReady() {
        let response = OpenAIEmbeddingsServeBridge.readinessResponse(
            modelId: ModelManager.embeddingModelID,
            isReady: true
        )
        #expect(response == nil)
    }

    // MARK: - 4. End-to-end: bridge → handler → audit chain

    @Test("registered handler path produces a valid OpenAI response + audit entry")
    func endToEndRegisteredPath() {
        let stub = StubEmbeddingEngine(
            vectorsPerInput: (0..<384).map { _ in Float(0.5) },
            promptTokens: 13
        )
        let engine = OpenAIEmbeddingsServeBridge.syncEngine(for: stub)

        let result = OpenAIEmbeddingsHandler.handle(
            request: .init(model: "text-embedding-3-small", input: ["hello", "world"]),
            keyLabel: "ci",
            engine: engine,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // OpenAI response shape preserved.
        #expect(result.response.data.count == 2)
        #expect(result.response.data[0].embedding.count == 384)
        // Real tokenizer count flows through to `usage.prompt_tokens`.
        #expect(result.response.usage.promptTokens == 13)
        #expect(result.response.usage.totalTokens == 13)
        // Audit chain shape unchanged from v13c.
        #expect(result.auditFields.surface == "embeddings")
        #expect(result.auditFields.completionTokenCount == 0)
        #expect(result.auditFields.resolvedTier == ModelManager.embeddingModelID)
    }
}
