import Testing
import Foundation
@testable import Core

// V.13b-sse-E (optional) — keepalive probe.
//
// SCOPE / IMPLEMENTATION APPROACH (indirect consumer probe):
//
// The spec's IDEAL probe spins up a real default-allow EgressListener +
// FixtureTCPServer terminating a CONNECT tunnel, then drives a real
// `chatStream(...)` through `URLSession`. That requires terminating TLS on
// the fixture (or wiring a self-signed cert + custom URLSession TLS trust
// override), which is infeasible in CI without significant new
// infrastructure and is OUT OF SCOPE for a P3 optional probe.
//
// Instead, this probe exercises the CONSUMER side of slow streams: the
// URLProtocol-level chunked-streaming seam (`MockSSEStreamProtocol`)
// delivers one SSE event per N seconds to a real `URLSession` (the
// `ClaudeAPIChatEngine`'s session uses the mock protocol). This validates
// that the translator + wire-emit path tolerates multi-second gaps between
// frames without:
//   (a) prematurely closing the wire,
//   (b) emitting an `.upstreamError(...)` terminal mode, or
//   (c) writing a non-"ok" audit row.
//
// This DOES NOT exercise the egress daemon's CONNECT-tunnel idle keepalive
// (the real-deployment concern Karpathy raised) — a real-operator-incident
// in production should trigger filing `phase-egress-daemon-sse-keepalive`
// (P1, daemon-side item) per the spec's note.
//
// N selection: we use N = 1s with 5 inter-event gaps (≈5s test runtime).
// The spec's ideal N = 30s is impractical for CI (would push the test past
// any reasonable suite timeout). 1s is enough to demonstrate the consumer
// tolerates multi-second gaps; for a more conservative bound the operator
// can rerun with N = 10s or 30s manually.

private let _kpAnthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func _kpStreamingEngine() -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockSSEStreamProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: "ak-sse-e-keepalive",
        session: session,
        endpoint: _kpAnthropicURL,
        sleeper: { _ in },
        requestTimeout: 30.0
    )
}

private func _kpRouting() -> OpenAIChatHandler.Routing {
    OpenAIChatHandler.Routing(
        presetUsed: .auto,
        resolvedTier: .quick,
        actualModel: "claude-haiku-3.5",
        modelLogged: "claude-haiku-3.5"
    )
}

private func _kpRequest() -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: "claude-haiku-3.5",
        messages: [.init(role: "user", content: "yo")],
        stream: true,
        tools: nil
    )
}

/// Split the standard 6-event happy-path SSE stream into 6 separate chunks
/// so `MockSSEStreamProtocol` can insert a per-event inter-chunk delay.
private func _kpSlowEmitChunks() -> [Data] {
    let messageStart = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_kp","usage":{"input_tokens":5}}}


    """
    let contentBlockStart = """
    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}


    """
    let delta1 = """
    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}


    """
    let delta2 = """
    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}


    """
    let contentBlockStop = """
    event: content_block_stop
    data: {"type":"content_block_stop","index":0}


    """
    let tail = """
    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    return [
        Data(messageStart.utf8),
        Data(contentBlockStart.utf8),
        Data(delta1.utf8),
        Data(delta2.utf8),
        Data(contentBlockStop.utf8),
        Data(tail.utf8),
    ]
}

private final class _KPCapturedSink: @unchecked Sendable {
    let lock = NSLock()
    var bytes = Data()
    var closed = false
    func write(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var snapshotString: String { String(data: snapshot, encoding: .utf8) ?? "" }
    var didClose: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

@Suite("ClaudeAPIServeDispatch.streamingPlan — long-lived SSE keepalive probe (Child E)",
       .serialized, .urlProtocolGate)
struct AnthropicSSEKeepaliveProbeTests {

    @Test func slowEmitStreamSurvivesMultiSecondGapsAndAuditsOk() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }

        // N = 1s between events × 5 gaps = ~5s total upstream lifetime.
        // The translator must consume the slow stream without
        // prematurely closing, raising .upstreamError, or writing a
        // non-"ok" audit row.
        MockSSEStreamProtocol.register(
            url: _kpAnthropicURL,
            chunks: _kpSlowEmitChunks(),
            delayBetweenMs: 1000
        )

        let engine = _kpStreamingEngine()
        let path = "/tmp/senkani-sse-e-keepalive-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        let chain = OpenAIAuditChain()

        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _kpRequest(),
            routing: _kpRouting(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_100),
            id: "chatcmpl-e-keepalive"
        )

        final class StatusBox: @unchecked Sendable {
            let lock = NSLock()
            var status: OpenAIChatStream.FinishStatus?
            func set(_ s: OpenAIChatStream.FinishStatus) { lock.lock(); status = s; lock.unlock() }
            var snapshot: OpenAIChatStream.FinishStatus? { lock.lock(); defer { lock.unlock() }; return status }
        }
        let statusBox = StatusBox()
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let recordCalls = Counter()

        let basePlan = outcome.plan
        let auditFieldsBuilder = outcome.auditFieldsBuilder
        let wrapped = OpenAIChatStream.Plan(
            head: basePlan.head,
            streamingEvents: basePlan.streamingEvents!,
            done: basePlan.done,
            onFinish: { status in
                statusBox.set(status)
                let fields = auditFieldsBuilder(status)
                recordCalls.bump()
                OpenAIServedRequestSink.record(
                    chain: chain, fields: fields, bodies: nil,
                    db: db, surface: .chatStream, httpStatus: 200
                )
            },
            errorTypeExtractor: basePlan.errorTypeExtractor,
            errorTerminatorBuilder: basePlan.errorTerminatorBuilder
        )

        let captured = _KPCapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )

        // Run with an overall budget well above the expected ~5s upstream
        // lifetime. If the consumer were to drop/timeout mid-stream this
        // would surface as an .upstreamError or .completed-with-partial.
        let startedAt = Date()
        let result = OpenAIChatStream.run(plan: wrapped, sink: sink)
        let elapsed = Date().timeIntervalSince(startedAt)

        // Acceptance: stream completed cleanly.
        #expect(result == .completed,
                "expected .completed after slow-emit stream; got \(result) after \(elapsed)s")
        #expect(captured.didClose)
        #expect(recordCalls.count == 1,
                "expected exactly ONE onFinish call; got \(recordCalls.count)")

        // No upstream-error terminal mode.
        if case .upstreamError = statusBox.snapshot {
            Issue.record("slow-emit stream must NOT terminate in .upstreamError; got \(String(describing: statusBox.snapshot))")
        }

        // Multi-second elapsed time is a load-bearing assertion: it
        // confirms the inter-chunk delays were actually applied (i.e.
        // we ARE testing the slow-emit path, not a coalesced fast path).
        #expect(elapsed >= 4.0,
                "expected slow-emit stream to take ≥4s (5 × 1s gaps); got \(elapsed)s — delay not applied?")
        // Upper bound keeps the suite under the 10s budget.
        #expect(elapsed <= 12.0,
                "slow-emit stream over budget: \(elapsed)s")

        let wire = captured.snapshotString
        // Wire-frame shape: head + role + 2 content + finish_reason + [DONE].
        #expect(wire.contains("HTTP/1.1 200 OK"))
        #expect(wire.contains("\"role\":\"assistant\""))
        #expect(wire.contains("\"content\":\"hello \""))
        #expect(wire.contains("\"content\":\"world\""))
        #expect(wire.contains("\"finish_reason\":\"stop\""),
                "expected finish_reason=stop after slow message_delta; wire: \(wire)")
        #expect(wire.contains("data: [DONE]"),
                "[DONE] sentinel missing — stream may have terminated early; wire: \(wire)")
        // Frame counting: at minimum 5 `data:` lines (role + 2 content +
        // finish_reason + [DONE]). The translator may also emit a
        // pre-role envelope or carry additional chunks; assert ≥5.
        // Count line-start occurrences of "data: " (including the first,
        // which follows the blank line after the HTTP headers).
        let dataLines = wire.components(separatedBy: "data: ").count - 1
        #expect(dataLines >= 5,
                "expected ≥5 SSE data: frames on the wire; counted \(dataLines). wire: \(wire)")

        // Audit row: status == "ok"; exactly one row.
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.status == 200)
        #expect(chain.entries.count == 1)
        #expect(chain.entries.first?.fields.status == "ok",
                "expected audit status \"ok\"; got \(String(describing: chain.entries.first?.fields.status))")
    }
}
