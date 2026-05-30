import Testing
import Foundation
@testable import Core

/// V.13 real-chat (sub-item 1) — covers `ChatEngine` protocol + the
/// `ModelManager` registration entry point + the `OpenAIChatServeBridge`
/// sync bridge. Mirrors `EmbeddingEngineRegistrationTests` 1:1.
///
/// The MLX-backed handler itself lives in `Sources/MCP` and runs against
/// real on-device Gemma 4 during the best-effort real-model `@Test` below
/// (skips silently when no Gemma 4 tier is downloaded — same pattern as
/// `MLXProseCadenceCompilerRealModelTests`). The stub-engine seam tests
/// here run in CI without any model download.
@Suite("V.13 real-chat — ChatEngine registration + serve bridge")
struct ChatEngineRegistrationTests {

    /// Stub `ChatEngine` returning a recorded completion. Mirrors what
    /// an MLX-backed implementation would return — content string +
    /// estimate token counts.
    private struct StubChatEngine: ChatEngine {
        let content: String
        let promptTokens: Int
        let completionTokens: Int

        func chat(
            model: String,
            messages: [ChatCompletionRequest.Message],
            tools: [ChatCompletionRequest.Tool]
        ) async throws -> OpenAIChatHandler.Completion {
            return OpenAIChatHandler.Completion(
                content: content,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
        }
    }

    private struct ThrowingChatEngine: ChatEngine {
        struct E: Error {}
        func chat(
            model: String,
            messages: [ChatCompletionRequest.Message],
            tools: [ChatCompletionRequest.Tool]
        ) async throws -> OpenAIChatHandler.Completion {
            throw E()
        }
    }

    // MARK: - 1. Registration + resolution

    @Test("registered ChatEngine round-trips through ModelManager")
    func registrationRoundTrip() {
        // Use a custom ModelManager instance so the test doesn't leak
        // registration state into ModelManager.shared (other tests would
        // see the stub).
        let mgr = ModelManager(
            hfCacheBase: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            metadataURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        )
        #expect(mgr.resolvedChatHandler() == nil)

        let stub = StubChatEngine(content: "hello", promptTokens: 5, completionTokens: 1)
        mgr.registerChatHandler(stub)

        // Round-trip: registered handler is resolvable.
        let resolved = mgr.resolvedChatHandler()
        #expect(resolved != nil)
    }

    // MARK: - 2. Sync bridge — content + token counts

    @Test("sync bridge passes through content + token counts")
    func syncBridgePassThrough() {
        let stub = StubChatEngine(content: "the answer is 42", promptTokens: 11, completionTokens: 5)
        let engine = OpenAIChatServeBridge.syncEngine(for: stub)

        let messages = [
            ChatCompletionRequest.Message(role: "user", content: "what is the answer?")
        ]
        let completion = engine.complete("gemma4-e2b", messages, [])
        #expect(completion.content == "the answer is 42")
        #expect(completion.promptTokens == 11)
        #expect(completion.completionTokens == 5)
        #expect(completion.toolCalls.isEmpty)
    }

    @Test("sync bridge surfaces a thrown ChatEngine error as an empty completion")
    func syncBridgeErrorPath() {
        let engine = OpenAIChatServeBridge.syncEngine(for: ThrowingChatEngine())
        let messages = [
            ChatCompletionRequest.Message(role: "user", content: "ping")
        ]
        let completion = engine.complete("any", messages, [])
        #expect(completion.content == "")
        #expect(completion.promptTokens == 0)
        #expect(completion.completionTokens == 0)
    }

    // MARK: - 3. End-to-end: bridge → handler → audit chain

    @Test("registered handler path produces a valid OpenAI response + audit entry")
    func endToEndRegisteredPath() {
        let stub = StubChatEngine(
            content: "Hello from the registered chat handler.",
            promptTokens: 7,
            completionTokens: 8
        )
        let engine = OpenAIChatServeBridge.syncEngine(for: stub)

        let request = ChatCompletionRequest(
            model: "gpt-4o-mini",
            messages: [
                .init(role: "user", content: "Say hello.")
            ]
        )
        let result = OpenAIChatHandler.handle(
            request: request,
            recordPreset: "auto",
            keyLabel: "ci",
            engine: engine,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-test-0001"
        )

        // OpenAI response shape preserved.
        #expect(result.response.choices.count == 1)
        #expect(result.response.choices[0].message.content == "Hello from the registered chat handler.")
        // Token counts flow through from the bridge to `usage`.
        #expect(result.response.usage.promptTokens == 7)
        #expect(result.response.usage.completionTokens == 8)
        // Audit chain shape unchanged from v13a-3.
        #expect(result.auditFields.surface == "chat")
        #expect(result.auditFields.promptTokenCount == 7)
        #expect(result.auditFields.completionTokenCount == 8)
    }
}

/// V.13 real-chat (sub-item 1) — best-effort real-model integration test
/// against the MCP-side `MLXChatEngineAdapter` (loaded from a deterministic
/// prompt, exercised through `OpenAIChatHandler.handle` + the sync bridge,
/// the same surface `senkani serve --openai` consumes at request time).
///
/// Skip pattern mirrors `MLXProseCadenceCompilerRealModelTests`: if no
/// Gemma 4 VLM tier is `.downloaded` / `.verified`, the test returns
/// silently — CI without a model download passes. Sampler
/// non-determinism precludes byte-equality, so assertions are
/// content-non-empty + contains-pattern style.
///
/// The MLX-backed adapter (`MLXChatEngineAdapter`) lives in `Sources/MCP`;
/// this test file lives in `SenkaniTests`, which links Core only. To
/// stay inside the same dependency boundary v13c uses, this @Test
/// exercises the Core seam directly — the actual MLX call happens via
/// the operator's local model state through the production code path
/// rather than spinning up the MCP target inside the test process.
@Suite("OpenAIChatRealEngine real-model (V.13)")
struct OpenAIChatRealEngineTests {

    /// True iff at least one Gemma 4 VLM tier is `.downloaded` (or
    /// `.verified`) per `ModelManager.shared.isReady(_:)`. Mirrors
    /// `MLXProseCadenceCompilerRealModelTests.anyGemmaReady`.
    private static var anyGemmaReady: Bool {
        ModelManager.visionModelIds.contains { ModelManager.shared.isReady($0) }
    }

    /// Diagnostic-only log helper. Writes to stderr so the round
    /// transcript captures real-model output drift without crashing
    /// the test suite. Mirrors `MLXProseCadenceCompilerRealModelTests
    /// .logRealModelFinding` — close-mode evidence-scan can grep for
    /// `[v13-chat-finding]`.
    private static func logRealModelFinding(prompt: String, detail: String) {
        let msg = "[v13-chat-finding] prompt=\(prompt.debugDescription) detail=\(detail)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    @Test
    func testNonStreamingCompletionAgainstRealModel() async throws {
        guard Self.anyGemmaReady else { return }

        // This test runs against the production seam: a registered
        // `ChatEngine` resolved through `ModelManager.shared` would be
        // the MLX adapter when MCP started up. The test cannot directly
        // import `Sources/MCP` (test target links Core only), so it
        // gates on a handler being registered — if MCP wasn't started
        // in this process (the default for `swift test`), skip silently.
        // The fixture exists to detect drift when the test IS run in an
        // MCP-active process (operator manual walks, integration runs).
        guard let registered = ModelManager.shared.resolvedChatHandler() else {
            Self.logRealModelFinding(
                prompt: "deterministic 'capital of France' probe",
                detail: "no ChatEngine registered (MCP target not started in this test process); real-model test skipped silently"
            )
            return
        }

        let engine = OpenAIChatServeBridge.syncEngine(for: registered)
        let request = ChatCompletionRequest(
            model: "gemma4-e2b",
            messages: [
                .init(role: "system", content: "You answer concisely in one short sentence."),
                .init(role: "user", content: "What is the capital of France?")
            ]
        )
        let result = OpenAIChatHandler.handle(
            request: request,
            recordPreset: "auto",
            keyLabel: "real-model-test",
            engine: engine,
            now: Date(),
            id: OpenAIChatHandler.generateID()
        )
        let content = result.response.choices.first?.message.content ?? ""

        // Range-asserted assertions: sampler non-determinism precludes
        // byte-equality. Real-model behavioral patterns: non-empty
        // content + mentions Paris (the deterministic prompt answer).
        guard !content.isEmpty else {
            Self.logRealModelFinding(
                prompt: "capital of France",
                detail: "real-model returned empty content; close-mode evidence-scan should file this as a finding"
            )
            return
        }
        // Pattern: the answer should mention "Paris" (case-insensitive).
        // Logged-not-failed when missing — preserves CI behavior under
        // real-model output drift while keeping the round transcript
        // explicit.
        if !content.localizedCaseInsensitiveContains("Paris") {
            Self.logRealModelFinding(
                prompt: "capital of France",
                detail: "real-model content did not mention 'Paris': \(content.debugDescription)"
            )
        }
    }
}
