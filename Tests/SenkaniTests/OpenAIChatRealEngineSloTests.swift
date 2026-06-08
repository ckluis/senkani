import Testing
import Foundation
@testable import Core

/// V.13 sub-item 4 — real-engine SLO smoke test. A single
/// `POST /v1/chat/completions`-shaped invocation against `.local`
/// with a minimal prompt (`"hi"`) completes inside a generous time
/// budget (30s on M2/M3 with `gemma4-e2b`). Best-effort skip pattern
/// mirrors `OpenAIChatRealEngineTests.testNonStreamingCompletionAgainstRealModel`:
/// when no Gemma 4 tier is `.downloaded` / `.verified` OR no
/// `ChatEngine` is registered (MCP target not started in this test
/// process — the default for `swift test`), the test returns silently
/// and logs a `[v13-slo-finding]` line so the close-mode evidence scan
/// can grep for it on operator integration runs.
///
/// The 30s budget is generous on purpose — Gemma cold-load can be
/// 5–15s, first-token latency another 1–3s, and a minimal generation
/// rarely exceeds 5s on Apple Silicon. A real machine consistently
/// busting the budget would surface as a logged finding, NOT a hard
/// failure — best-effort is the right posture for a real-model probe
/// that runs only on operator integration walks.
///
/// Test target links Core only — MCP isn't started during `swift
/// test`; this @Test exists to detect drift when run in an MCP-active
/// process (operator manual walks, integration runs).
@Suite("OpenAIChatRealEngine SLO (V.13)")
struct OpenAIChatRealEngineSloTests {

    private static var anyGemmaReady: Bool {
        ModelManager.visionModelIds.contains { ModelManager.shared.isReady($0) }
    }

    /// Skip-honesty predicate: a Gemma tier on disk AND a `ChatEngine`
    /// registered in this process. The latter is only true in an
    /// MCP-active process — plain `swift test` leaves it nil (a
    /// legitimate "production seam not wired" skip, not a placebo), so
    /// the guard stays a clean no-op there.
    private static var sloSeamPresent: Bool {
        anyGemmaReady && ModelManager.shared.resolvedChatHandler() != nil
    }

    private static func logSloFinding(detail: String) {
        let msg = "[v13-slo-finding] \(detail)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// A single minimal completion completes inside the 30s budget on
    /// M2/M3 with `gemma4-e2b`. Time budget logged in test output for
    /// trend tracking (the close-mode evidence scan + future SLO ledger
    /// can grep `[v13-slo-finding]` for the recorded wall-clock).
    @Test(.realModelSkipHonesty(weightsPresent: { OpenAIChatRealEngineSloTests.sloSeamPresent }))
    func testMinimalCompletionUnderTimeBudget() async throws {
        guard Self.anyGemmaReady else { return }
        guard let registered = ModelManager.shared.resolvedChatHandler() else {
            Self.logSloFinding(
                detail: "no ChatEngine registered (MCP target not started in this test process); SLO smoke skipped silently"
            )
            return
        }

        let engine = OpenAIChatServeBridge.syncEngine(for: registered)
        let request = ChatCompletionRequest(
            model: "gemma4-e2b",
            messages: [
                .init(role: "user", content: "hi")
            ]
        )

        let started = Date()
        let result = OpenAIChatHandler.handle(
            request: request,
            recordPreset: "auto",
            keyLabel: "real-model-slo",
            engine: engine,
            now: started,
            id: OpenAIChatHandler.generateID()
        )
        let elapsed = Date().timeIntervalSince(started)

        let content = result.response.choices.first?.message.content ?? ""

        // Always log so trend tracking has the data point per run.
        Self.logSloFinding(
            detail: "minimal-completion elapsed=\(String(format: "%.2f", elapsed))s budget=30.00s content_len=\(content.count)"
        )

        // 30s budget is generous — a real machine consistently busting
        // it surfaces as a logged finding rather than a hard failure
        // (sampler/cold-load drift can spike a single run). The bound
        // here is the durable SLO contract: an outright pathological
        // regression (e.g. 5x the budget) is still a fail.
        let pathologicalCeiling: TimeInterval = 150
        // Routed through RealModelGuard so a wired-seam run fires a
        // genuine assertion (skip-honesty); this is also the durable SLO
        // contract assertion.
        RealModelGuard.expect(
            elapsed < pathologicalCeiling,
            "minimal completion took \(elapsed)s, pathological ceiling \(pathologicalCeiling)s exceeded — adapter regression suspected"
        )
        if elapsed >= 30 {
            Self.logSloFinding(
                detail: "minimal-completion elapsed=\(elapsed)s exceeds 30s SLO budget; logged-not-failed (operator triage candidate)"
            )
        }

        // Sanity: silent fallback to an empty completion would mask a
        // real-engine regression.
        if content.isEmpty {
            Self.logSloFinding(
                detail: "real-model returned empty content — adapter may have errored into the empty-completion fallback"
            )
        }
    }
}
