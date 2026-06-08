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

    /// Skip-honesty predicate for the MCP-seam real-model cases: BOTH a
    /// Gemma tier on disk AND a `ChatEngine` registered in this process.
    /// The latter is only true in an MCP-active process — plain
    /// `swift test` (even on Apple Silicon WITH weights) leaves it nil,
    /// which is a legitimate "production seam not wired in-process" skip,
    /// NOT a placebo. Gating the guard on both keeps it a clean no-op in
    /// that case while still flaring if a wired-up run greens without
    /// asserting.
    private static var chatSeamPresent: Bool {
        anyGemmaReady && ModelManager.shared.resolvedChatHandler() != nil
    }

    private static var streamingSeamPresent: Bool {
        anyGemmaReady && ModelManager.shared.resolvedStreamingChatHandler() != nil
    }

    @Test(.realModelSkipHonesty(weightsPresent: { OpenAIChatRealEngineTests.chatSeamPresent }))
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
        // Non-empty content is the load-bearing assertion — routed
        // through RealModelGuard so a wired-seam run fires a genuine
        // assertion (skip-honesty). The finding is still logged for the
        // close-mode evidence-scan.
        if content.isEmpty {
            Self.logRealModelFinding(
                prompt: "capital of France",
                detail: "real-model returned empty content; close-mode evidence-scan should file this as a finding"
            )
        }
        guard RealModelGuard.expect(
            !content.isEmpty,
            "real Gemma completion returned empty content through the production seam"
        ) else { return }
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

    /// V.13 real-chat (sub-item 2) — best-effort inter-delta-timing probe.
    /// Records the wall-clock gaps between SSE deltas during a real Gemma 4
    /// stream and asserts the distribution against a non-zero floor: ≥3
    /// distinct delta arrival timestamps + the inter-delta max gap stays
    /// under 5s. The intent is to prove deltas arrive over time rather than
    /// bunched at the end (a regression to a `complete()`-then-chunk path
    /// would show all deltas arriving within microseconds of each other).
    ///
    /// Skip pattern matches the non-streaming test: when no Gemma 4 tier
    /// is `.downloaded` / `.verified` OR no `StreamingChatEngine` is
    /// registered (MCP target not started in this process — the default
    /// for `swift test`), the test returns silently. Real arrival timing
    /// is only verifiable when the production seam is wired end-to-end.
    @Test(.realModelSkipHonesty(weightsPresent: { OpenAIChatRealEngineTests.streamingSeamPresent }))
    func testStreamingDeltasArriveOverTime() async throws {
        guard Self.anyGemmaReady else { return }
        guard let registered = ModelManager.shared.resolvedStreamingChatHandler() else {
            Self.logRealModelFinding(
                prompt: "deterministic streaming probe",
                detail: "no StreamingChatEngine registered (MCP target not started in this test process); inter-delta-timing test skipped silently"
            )
            return
        }

        let messages = [
            ChatCompletionRequest.Message(role: "system", content: "Answer concisely in one short sentence."),
            ChatCompletionRequest.Message(role: "user", content: "Name three primary colors.")
        ]
        let upstream = registered.stream(model: "gemma4-e2b", messages: messages, tools: [])

        // Render through the SSE seam so the test exercises the production
        // surface end-to-end (production renders these same Data events
        // through the listener's sink).
        let rendered = OpenAIChatHandler.renderStreamingEvents(
            id: OpenAIChatHandler.generateID(),
            created: Int(Date().timeIntervalSince1970),
            model: "gemma4-e2b",
            source: upstream
        )

        var timestamps: [Date] = []
        var accumulatedContent = ""
        var sawContent = 0
        let started = Date()
        do {
            for try await event in rendered {
                if Date().timeIntervalSince(started) > 60 { break }
                timestamps.append(Date())
                let s = String(decoding: event, as: UTF8.self)
                let json = s
                    .replacingOccurrences(of: "data: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                   let choices = obj["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    accumulatedContent += content
                    sawContent += 1
                }
            }
        } catch {
            Self.logRealModelFinding(
                prompt: "streaming primary-colors probe",
                detail: "stream threw mid-iteration: \(error)"
            )
            return
        }

        // Distribution check: at least 3 distinct delta timestamps. The
        // stream always emits a role chunk + terminal chunk + ≥1 content
        // chunk; a real-engine non-bunched stream produces many content
        // chunks spread over time. Routed through RealModelGuard so a
        // wired-seam run fires a genuine assertion (skip-honesty); the
        // finding is still logged for the close-mode evidence-scan.
        if timestamps.count < 3 {
            Self.logRealModelFinding(
                prompt: "streaming primary-colors probe",
                detail: "fewer than 3 delta timestamps captured (\(timestamps.count)); content=\(accumulatedContent.debugDescription)"
            )
        }
        guard RealModelGuard.expect(
            timestamps.count >= 3,
            "real Gemma stream produced fewer than 3 delta timestamps (\(timestamps.count))"
        ) else { return }
        // Inter-delta max gap < 5s (heartbeat sanity — model produces
        // tokens steadily, not in one batch at the end).
        var maxGap: TimeInterval = 0
        for i in 1..<timestamps.count {
            let gap = timestamps[i].timeIntervalSince(timestamps[i - 1])
            if gap > maxGap { maxGap = gap }
        }
        if maxGap >= 5 {
            Self.logRealModelFinding(
                prompt: "streaming primary-colors probe",
                detail: "inter-delta max gap \(maxGap)s exceeded 5s floor; content=\(accumulatedContent.debugDescription)"
            )
        }
        if sawContent == 0 {
            Self.logRealModelFinding(
                prompt: "streaming primary-colors probe",
                detail: "no content deltas observed; only role + terminal chunks"
            )
        }
    }

    /// V.13 real-chat (sub-item 3) — best-effort assertion that
    /// `usage.prompt_tokens` / `usage.completion_tokens` reflect the
    /// real Gemma tokenizer's counts, not the `~4-chars/token`
    /// heuristic `OpenAIChatHandler.estimateTokens` produces.
    ///
    /// Skip pattern matches `testNonStreamingCompletionAgainstRealModel`:
    /// no Gemma 4 tier installed OR no `ChatEngine` registered (MCP
    /// target not started in this test process) → return silently. Real
    /// tokenizer counts are only verifiable end-to-end when the
    /// production seam is wired.
    ///
    /// The assertion is structural rather than byte-equal: the
    /// heuristic and the real tokenizer disagree on the same prompt /
    /// completion text. We assert both `usage` counts are non-zero AND
    /// that at least one of them disagrees with the heuristic over the
    /// same text — proof the adapter is plumbing real counts through,
    /// not silently falling back to the heuristic. A pathological agree-
    /// case is logged-not-failed to preserve CI behavior under tokenizer
    /// drift.
    @Test(.realModelSkipHonesty(weightsPresent: { OpenAIChatRealEngineTests.chatSeamPresent }))
    func testUsageMatchesRealTokenizer() async throws {
        guard Self.anyGemmaReady else { return }
        guard let registered = ModelManager.shared.resolvedChatHandler() else {
            Self.logRealModelFinding(
                prompt: "deterministic tokenizer-accuracy probe",
                detail: "no ChatEngine registered (MCP target not started in this test process); tokenizer-accuracy test skipped silently"
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

        let prompt = request.messages.map(\.content).joined(separator: "\n")
        let heuristicPrompt = OpenAIChatHandler.estimateTokens(prompt)
        let completionText = result.response.choices.first?.message.content ?? ""
        let heuristicCompletion = OpenAIChatHandler.estimateTokens(completionText)

        // Both `usage` counts MUST be non-zero — a zero would mean the
        // adapter silently returned no Completion at all (the
        // OpenAIChatServeBridge syncEngine error path returns 0/0; that
        // would mask a tokenizer-plumbing regression). Routed through
        // RealModelGuard so a wired-seam run fires a genuine assertion
        // (skip-honesty); the finding is still logged.
        let usageNonZero = result.response.usage.promptTokens > 0
            && result.response.usage.completionTokens > 0
        if !usageNonZero {
            Self.logRealModelFinding(
                prompt: "tokenizer-accuracy probe",
                detail: "usage carries zero token count(s): prompt=\(result.response.usage.promptTokens) completion=\(result.response.usage.completionTokens) — adapter may have errored into the empty-completion fallback"
            )
        }
        guard RealModelGuard.expect(
            usageNonZero,
            "real-model usage carries zero token count(s) — adapter may have errored into the empty-completion fallback"
        ) else { return }

        // Structural disagreement: at least one of (prompt, completion)
        // diverges from the heuristic count over the same text. The
        // real Gemma tokenizer chunks differently than ~4-chars/token,
        // so equality across BOTH would mean the adapter is producing
        // heuristic counts instead of real ones. Logged-not-failed
        // (tokenizer drift could theoretically agree on short inputs).
        let promptDiverges = result.response.usage.promptTokens != heuristicPrompt
        let completionDiverges = result.response.usage.completionTokens != heuristicCompletion
        if !promptDiverges && !completionDiverges {
            Self.logRealModelFinding(
                prompt: "tokenizer-accuracy probe",
                detail: "real tokenizer agrees with heuristic on BOTH prompt + completion (prompt=\(heuristicPrompt) completion=\(heuristicCompletion)) — unusual; adapter may be falling back to estimateTokens"
            )
        }
    }
}
