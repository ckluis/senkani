import Testing
import Foundation
@testable import Core

/// Regression for the phase-t1d-6 P0 serve-bridge deadlock.
///
/// THE BUG (test-only): `OpenAIChatServeBridge.syncEngine` /
/// `OpenAIEmbeddingsServeBridge.syncEngine` bridged their async engine call
/// to the synchronous listener closure by spawning a `Task` on the DEFAULT
/// global cooperative executor and blocking on a `DispatchSemaphore.wait()`.
/// Under a full `swift test` (many concurrent async `@Test`s), every
/// cooperative-pool thread (capped at `activeProcessorCount`, does not grow)
/// could park in `wait()`, leaving no thread free to RUN the spawned `Task`
/// → deadlock. Production never self-starves because its callers
/// (ServeCommand → NWListener's sync `(Data)->Data?` closure) block a
/// GCD/NWListener thread, never a cooperative thread.
///
/// THE FIX: host the bridge `Task` on a dedicated `TaskExecutor`
/// (`ServeBridge.runBlocking`, SE-0417, macOS 15+) whose threads are NOT in
/// the cooperative pool, so the bridge `Task` can START even when every
/// cooperative thread is parked.
///
/// WHY THIS TEST IS STRUCTURAL (deterministic + parallel-safe): the fix's
/// load-bearing invariant is that the bridge's awaited engine work runs ON
/// the dedicated executor — OFF the cooperative pool. That is exactly the
/// property that lets the bridge `Task` start under a saturated pool, so it
/// is exactly what prevents the deadlock. We assert it DIRECTLY via the
/// `ServeBridge.isRunningOnDedicatedExecutor()` seam (a `DispatchSpecificKey`
/// marker set on the dedicated executor's queue): a stub engine, driven
/// through the REAL bridge, records the marker from inside its awaited call.
///
/// This is deterministic and has zero cross-test interference — no global
/// pool saturation, no watchdog, no timing. Reproducing the LITERAL
/// full-pool deadlock would require globally saturating the SHARED
/// cooperative pool, which is irreconcilable with `swift test`'s parallel
/// runner (other concurrently-scheduled tests hold pool threads, so the
/// saturation either can't complete or starves unrelated work) — that is why
/// the prior saturation test was flaky. The end-to-end LIVENESS proof is
/// simply that the FULL `swift test` now completes without hanging.
///
/// FAIL-BEFORE / PASS-AFTER: regressing the fix (dropping `executorPreference`
/// so the bridge `Task` runs back on the cooperative pool) makes the marker
/// read `false` inside the awaited call → tests 1 and 2 deterministically
/// fail. The control test (`cooperativePoolTaskDoesNotSeeMarker`) proves the
/// marker genuinely distinguishes the two paths, so 1 and 2 are not trivially
/// true.
@Suite
struct ServeBridgeDeadlockTests {

    /// `@unchecked Sendable` reference box: the marker is written exactly once
    /// from inside the awaited engine call and read after `runBlocking` has
    /// returned (the bridge's `DispatchSemaphore` establishes happens-before),
    /// so there is never a concurrent access.
    private final class MarkerBox: @unchecked Sendable {
        /// Defaults to `false` so a regression (the awaited work never running
        /// on the dedicated executor, or never running at all) reads as
        /// off-executor — making the `#expect(marker.onDedicatedExecutor)`
        /// assertions a plain, unambiguous `Bool` test rather than an
        /// optional comparison.
        var onDedicatedExecutor = false
    }

    /// Local stub `ChatEngine`: records whether its awaited `chat(...)` body
    /// runs on the dedicated executor, then returns a known completion.
    private struct StubChatEngine: ChatEngine {
        let marker: MarkerBox
        let content: String
        let promptTokens: Int
        let completionTokens: Int
        func chat(
            model: String,
            messages: [ChatCompletionRequest.Message],
            tools: [ChatCompletionRequest.Tool]
        ) async throws -> OpenAIChatHandler.Completion {
            marker.onDedicatedExecutor = ServeBridge.isRunningOnDedicatedExecutor()
            return OpenAIChatHandler.Completion(
                content: content,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
        }
    }

    /// Local stub `EmbeddingEngine`: records the marker from inside its awaited
    /// `embed(...)` body, then returns known vectors + token count.
    private struct StubEmbeddingEngine: EmbeddingEngine {
        let marker: MarkerBox
        let vectorPerInput: [Float]
        let promptTokens: Int
        func embed(model: String, inputs: [String]) async throws -> OpenAIEmbeddingsHandler.Embedding {
            marker.onDedicatedExecutor = ServeBridge.isRunningOnDedicatedExecutor()
            return OpenAIEmbeddingsHandler.Embedding(
                vectors: inputs.map { _ in vectorPerInput },
                promptTokens: promptTokens
            )
        }
    }

    /// The chat bridge's awaited engine call runs on the dedicated executor
    /// (off the cooperative pool) — the invariant that prevents the deadlock.
    /// Drive a stub through the REAL bridge and assert the marker is `true`,
    /// plus that the returned completion equals the stub's recorded values
    /// (behavior preserved). Tests run on the macOS 15+ toolchain, which takes
    /// the dedicated-executor `if` branch in `ServeBridge.runBlocking`.
    @Test
    func bridgeChatWorkRunsOffCooperativePool() {
        let marker = MarkerBox()
        let stub = StubChatEngine(
            marker: marker,
            content: "bridge ran off the cooperative pool",
            promptTokens: 17,
            completionTokens: 3
        )
        let engine = OpenAIChatServeBridge.syncEngine(for: stub)
        let c = engine.complete(
            "gemma4-e2b",
            [ChatCompletionRequest.Message(role: "user", content: "ping")],
            []
        )

        // The awaited engine call ran ON the dedicated executor (off the
        // cooperative pool) — the property that lets the bridge Task start
        // under a saturated pool, i.e. what prevents the phase-t1d-6 deadlock.
        #expect(marker.onDedicatedExecutor)

        // Behavior preserved: the bridge returned the stub's recorded values.
        #expect(c.content == "bridge ran off the cooperative pool")
        #expect(c.promptTokens == 17)
        #expect(c.completionTokens == 3)
    }

    /// Mirror of the chat assertion for the embeddings bridge: the awaited
    /// `embed(...)` call runs on the dedicated executor, and the returned
    /// vectors/tokens match the stub.
    @Test
    func bridgeEmbedWorkRunsOffCooperativePool() {
        let marker = MarkerBox()
        let recordedVector: [Float] = (0..<384).map { Float($0) / 384.0 }
        let stub = StubEmbeddingEngine(
            marker: marker,
            vectorPerInput: recordedVector,
            promptTokens: 29
        )
        let engine = OpenAIEmbeddingsServeBridge.syncEngine(for: stub)
        let embedding = engine.embed(ModelManager.embeddingModelID, ["alpha", "beta"])

        #expect(marker.onDedicatedExecutor)

        #expect(embedding.vectors.count == 2)
        #expect(embedding.vectors.first == recordedVector)
        #expect(embedding.vectors.last == recordedVector)
        #expect(embedding.promptTokens == 29)
    }

    /// Control: a plain `Task` runs on Swift's cooperative pool, NOT the
    /// dedicated serve-bridge executor, so the marker must be ABSENT there.
    /// This proves `isRunningOnDedicatedExecutor()` genuinely distinguishes the
    /// two execution contexts — so the `true` assertions above are meaningful
    /// rather than trivially satisfied everywhere.
    @Test
    func cooperativePoolTaskDoesNotSeeMarker() async {
        let onPool = await Task { ServeBridge.isRunningOnDedicatedExecutor() }.value
        #expect(!onPool)
    }
}
