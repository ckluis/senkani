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
    // Karpathy r19 P2 re-audit — tail-split for gap-before-finish_reason.
    // The mock fixture used to coalesce `message_delta` + `message_stop`
    // into a single tail chunk. Splitting them into TWO emissions with an
    // inter-chunk gap exercises the path where the OpenAI translator
    // emits the `finish_reason` terminal AFTER a real upstream gap (i.e.
    // the translator must hold its terminal chunk until `message_stop`
    // arrives, not flush on `message_delta` alone).
    let messageDelta = """
    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}


    """
    let messageStop = """
    event: message_stop
    data: {"type":"message_stop"}


    """
    return [
        Data(messageStart.utf8),
        Data(contentBlockStart.utf8),
        Data(delta1.utf8),
        Data(delta2.utf8),
        Data(contentBlockStop.utf8),
        Data(messageDelta.utf8),
        Data(messageStop.utf8),
    ]
}

/// Decoder type for wire-frame JSON-decode parity assertion. Each `data:`
/// chunk on the OpenAI SSE wire JSON-decodes into this struct.
private struct _KPDecodedChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let role: String?
            let content: String?
        }
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
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

        // N = 1s between events × 6 gaps = ~6s total upstream lifetime.
        // (Karpathy r19 tail-split: message_delta and message_stop are
        // now two separate chunks, exercising the gap-before-finish_reason
        // path.) The translator must consume the slow stream without
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
        defer { TempSessionDatabase.close(db, path: path) }
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

        // Run with an overall budget well above the expected ~6s upstream
        // lifetime. If the consumer were to drop/timeout mid-stream this
        // would surface as an .upstreamError or .completed-with-partial.
        //
        // Karpathy r19 P2 — HANG-GUARD: wrap the sync `OpenAIChatStream.run`
        // call in a `withTaskGroup` race against a `Task.sleep(.seconds(15))`
        // racer. If the run-task hangs indefinitely (translator bug,
        // upstream contract violation, AsyncBytes iterator livelock,
        // ...), the racer wins after ~15s and we surface an `Issue.record`
        // — instead of hanging the entire test suite. On the happy path
        // (run-task wins in ~6s) the racer task is cancelled cleanly.
        let startedAt = Date()
        enum _RaceOutcome { case ran(OpenAIChatStream.FinishStatus); case hung }
        let raceOutcome: _RaceOutcome = await withTaskGroup(of: _RaceOutcome.self) { group in
            group.addTask {
                // Run the synchronous driver inside an async task so it can
                // be raced against the sleeper. The driver fully owns the
                // sink + onFinish callbacks (single-audit-row invariant
                // preserved).
                let status = OpenAIChatStream.run(plan: wrapped, sink: sink)
                return .ran(status)
            }
            group.addTask {
                // 15s racer: if the run-task hangs the racer wins and we
                // bail with an Issue.record rather than parking the suite.
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return .hung
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let result: OpenAIChatStream.FinishStatus
        switch raceOutcome {
        case .ran(let s):
            result = s
        case .hung:
            Issue.record("hang-guard fired: OpenAIChatStream.run did not return within 15s on the slow-emit fixture — possible translator / AsyncBytes hang")
            return
        }

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

        // Karpathy r19 P2 — wire-frame JSON-decode parity. Split the wire
        // body on `data: ` boundaries and JSON-decode each non-[DONE]
        // chunk into `_KPDecodedChunk`. Assert delta.role / delta.content
        // / finish_reason on the expected frame indices. This replaces
        // brittle substring sniffing with a contract-level check on the
        // OpenAI chunk envelope.
        //
        // Split strategy: find the SSE body (after the blank-line head
        // terminator) and break it at `data: ` markers. Skip the leading
        // empty fragment, decode JSON for non-[DONE] entries, and stash
        // the terminal [DONE] separately.
        let bodyStartRange = wire.range(of: "\r\n\r\n") ?? wire.range(of: "\n\n")
        let body = bodyStartRange.map { String(wire[$0.upperBound...]) } ?? wire
        // Each chunk is `data: <payload>\n\n` — split on `data: ` and
        // strip the trailing `\n\n` from each non-empty fragment.
        let rawFragments = body.components(separatedBy: "data: ")
            .dropFirst()  // leading empty before first `data: `
            .map { fragment -> String in
                if let nn = fragment.range(of: "\n\n") {
                    return String(fragment[..<nn.lowerBound])
                }
                return fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        var decoded: [_KPDecodedChunk] = []
        var sawDone = false
        for frag in rawFragments {
            if frag == "[DONE]" { sawDone = true; continue }
            guard let data = frag.data(using: .utf8) else {
                Issue.record("non-UTF8 SSE fragment: \(frag)"); continue
            }
            do {
                decoded.append(try JSONDecoder().decode(_KPDecodedChunk.self, from: data))
            } catch {
                Issue.record("could not JSON-decode SSE fragment as chunk envelope: \(frag) — \(error)")
            }
        }
        #expect(sawDone, "terminal [DONE] sentinel missing from wire JSON-decode pass")
        #expect(decoded.count >= 4,
                "expected ≥4 JSON-decodable chunks (role + 2 content + terminal); got \(decoded.count)")

        // Frame[0] = role chunk: delta.role == "assistant", no content,
        // no finish_reason.
        if let role = decoded.first {
            #expect(role.object == "chat.completion.chunk")
            #expect(role.choices.first?.delta.role == "assistant")
            #expect(role.choices.first?.delta.content == nil)
            #expect(role.choices.first?.finish_reason == nil)
        }
        // Frame[1] + Frame[2] = content chunks: delta.content set, no
        // role, no finish_reason.
        if decoded.count >= 3 {
            #expect(decoded[1].choices.first?.delta.content == "hello ")
            #expect(decoded[1].choices.first?.delta.role == nil)
            #expect(decoded[1].choices.first?.finish_reason == nil)
            #expect(decoded[2].choices.first?.delta.content == "world")
            #expect(decoded[2].choices.first?.delta.role == nil)
            #expect(decoded[2].choices.first?.finish_reason == nil)
        }
        // Terminal frame: finish_reason == "stop", no content, no role.
        if let terminal = decoded.last {
            #expect(terminal.choices.first?.finish_reason == "stop")
            #expect(terminal.choices.first?.delta.content == nil)
            #expect(terminal.choices.first?.delta.role == nil)
        }

        // Audit row: status == "ok"; exactly one row.
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.status == 200)
        #expect(chain.entries.count == 1)
        #expect(chain.entries.first?.fields.status == "ok",
                "expected audit status \"ok\"; got \(String(describing: chain.entries.first?.fields.status))")
    }
}
