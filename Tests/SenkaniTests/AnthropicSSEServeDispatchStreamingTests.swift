import Testing
import Foundation
@testable import Core

// V.13b-sse-b — translator + listener-wire tests for the
// `ClaudeAPIServeDispatch.streamingPlan(...)` factory shipped by Child B of
// the v13b-followup-anthropic-sse-streaming decomposition.
//
// Coverage:
//   1. Translator unit — happy-path Anthropic event sequence translates to
//      the expected ordered chunk envelope (role chunk + content chunks +
//      terminal stop chunk + [DONE] sentinel).
//   2. Envelope-parity — translator-emitted bytes are byte-equal to the
//      reference shape constructed manually via
//      `OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(...))`.
//   3. End-to-end via MockSSEStreamProtocol — the producer body lazily
//      opens engine.chatStream(...) and translates wire bytes through the
//      `OpenAIChatStream.run(plan:sink:)` driver to a captured sink.
//   4. Single-audit-row invariant — drive the same end-to-end pipeline with
//      ServeCommand-equivalent onFinish-wraps-record wiring; the persisted
//      `openai_request_log` row count is exactly 1, surface == "chat_stream"
//      (the SQLite TEXT value for OpenAIRequestLogStore.Surface.chatStream),
//      promptTokens = 7, completionTokens = 3.
//   5. streamingPlan factory invariants — produces a non-nil Plan with a
//      streamingEvents source (the configured-engine case is wired in the
//      streamHandler); the no-engine case is preserved upstream as nil.

// MARK: - Helpers

private let _anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func _makeStreamingEngine(apiKey: String = "ak-sse-b-test") -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockSSEStreamProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: apiKey,
        session: session,
        endpoint: _anthropicURL,
        sleeper: { _ in },
        requestTimeout: 5.0
    )
}

private func _happyPathSSEChunks() -> [Data] {
    // Same shape as AnthropicSSEFrameParserTests' chatStream happy path,
    // but tuned to inputTokens=7 / outputTokens=3 so the single-audit-row
    // test can assert the captured usage end-to-end.
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_b","usage":{"input_tokens":7}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    return [Data(frame.utf8)]
}

private func _routing() -> OpenAIChatHandler.Routing {
    OpenAIChatHandler.Routing(
        presetUsed: .auto,
        resolvedTier: .quick,
        actualModel: "claude-haiku-3.5",
        modelLogged: "claude-haiku-3.5"
    )
}

private func _request() -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: "claude-haiku-3.5",
        messages: [.init(role: "user", content: "yo")],
        stream: true,
        tools: nil
    )
}

private struct _DecodedChunk: Decodable {
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

private func _decodeChunk(_ event: Data) throws -> _DecodedChunk {
    // Strip "data: " prefix + "\n\n" suffix.
    guard let s = String(data: event, encoding: .utf8),
          s.hasPrefix("data: ") else {
        Issue.record("event missing data: prefix: \(String(data: event, encoding: .utf8) ?? "<nil>")")
        throw CocoaError(.coderInvalidValue)
    }
    let jsonPart = s.dropFirst("data: ".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try JSONDecoder().decode(_DecodedChunk.self, from: Data(jsonPart.utf8))
}

/// Lauret r12 re-audit P2 — sse-B envelope key-set introspection. Returns
/// the top-level JSON object and the `choices[0].delta` sub-object so a
/// test can assert "delta keys present match EXACTLY" (no extra keys
/// silently shipping over the wire).
private func _rawChunk(_ event: Data) throws -> (top: [String: Any], delta: [String: Any]) {
    guard let s = String(data: event, encoding: .utf8),
          s.hasPrefix("data: ") else {
        Issue.record("event missing data: prefix")
        throw CocoaError(.coderInvalidValue)
    }
    let jsonPart = s.dropFirst("data: ".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let top = try JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String: Any] else {
        Issue.record("event JSON is not a top-level object")
        throw CocoaError(.coderInvalidValue)
    }
    let choices = top["choices"] as? [[String: Any]] ?? []
    let delta = choices.first?["delta"] as? [String: Any] ?? [:]
    return (top, delta)
}

// MARK: - 1. Translator unit (mock engine seam)

@Suite("ClaudeAPIServeDispatch.streamingPlan — translator + wire", .serialized, .urlProtocolGate)
struct AnthropicSSEServeDispatchStreamingTests {

    @Test func translatorEmitsRolePlusContentPlusTerminalChunkPlusDone() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _happyPathSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-bbb"
        )
        guard let source = outcome.plan.streamingEvents else {
            Issue.record("streamingEvents source missing on Plan"); return
        }
        // Drain the producer stream + collect events. Add the doneSentinel
        // as the run loop would.
        var emitted: [Data] = []
        for try await chunk in source() { emitted.append(chunk) }
        emitted.append(outcome.plan.done)

        // 4 chunks total: role + 2 content + terminal stop. Then DONE.
        #expect(emitted.count == 5, "expected 4 chunks + DONE sentinel; got \(emitted.count)")

        // chunk[0]: role chunk
        let role = try _decodeChunk(emitted[0])
        #expect(role.id == "chatcmpl-bbb")
        #expect(role.object == "chat.completion.chunk")
        #expect(role.model == "claude-haiku-3.5")
        #expect(role.choices.first?.delta.role == "assistant")
        #expect(role.choices.first?.delta.content == nil)
        #expect(role.choices.first?.finish_reason == nil)

        // Lauret r12 re-audit P2 — sse-B envelope JSON-decode parity:
        // top-level chunk envelope MUST carry exactly
        // {id, object, created, model, choices} — no extras leaking — and
        // `object == "chat.completion.chunk"`. The role chunk's delta MUST
        // carry exactly {role} — no `content`, no `tool_calls`, no
        // `finish_reason` (finish_reason lives on the Choice, not the delta).
        let roleRaw = try _rawChunk(emitted[0])
        #expect(Set(roleRaw.top.keys) == Set(["id", "object", "created", "model", "choices"]),
                "top envelope keys must be exactly {id,object,created,model,choices}; got \(roleRaw.top.keys.sorted())")
        #expect((roleRaw.top["object"] as? String) == "chat.completion.chunk")
        #expect(Set(roleRaw.delta.keys) == Set(["role"]),
                "role-chunk delta keys must be exactly {role}; got \(roleRaw.delta.keys.sorted())")

        // chunk[1] + chunk[2]: content chunks
        let c1 = try _decodeChunk(emitted[1])
        #expect(c1.choices.first?.delta.role == nil)
        #expect(c1.choices.first?.delta.content == "Hello ")
        #expect(c1.choices.first?.finish_reason == nil)
        let c2 = try _decodeChunk(emitted[2])
        #expect(c2.choices.first?.delta.content == "world")
        #expect(c2.choices.first?.finish_reason == nil)

        // Lauret r12 re-audit P2 — content-chunk delta must carry EXACTLY
        // {content}; no role, no tool_calls keys leak.
        let c1Raw = try _rawChunk(emitted[1])
        #expect(Set(c1Raw.delta.keys) == Set(["content"]),
                "content-chunk delta keys must be exactly {content}; got \(c1Raw.delta.keys.sorted())")
        let c2Raw = try _rawChunk(emitted[2])
        #expect(Set(c2Raw.delta.keys) == Set(["content"]),
                "content-chunk delta keys must be exactly {content}; got \(c2Raw.delta.keys.sorted())")

        // chunk[3]: terminal stop chunk
        let term = try _decodeChunk(emitted[3])
        #expect(term.choices.first?.delta.role == nil)
        #expect(term.choices.first?.delta.content == nil)
        #expect(term.choices.first?.finish_reason == "stop")

        // Terminal delta must be EXACTLY empty {} per the OpenAI contract
        // (finish_reason rides on the Choice; no delta keys).
        let termRaw = try _rawChunk(emitted[3])
        #expect(termRaw.delta.isEmpty,
                "terminal-chunk delta must be empty {}; got keys \(termRaw.delta.keys.sorted())")

        // emitted[4]: [DONE] sentinel
        #expect(emitted[4] == OpenAIChatStream.doneSentinel())
    }

    // MARK: - 2. Envelope-parity

    @Test func envelopeParityWithManualChunkConstruction() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _happyPathSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-parity"
        )
        var emitted: [Data] = []
        for try await chunk in outcome.plan.streamingEvents!() { emitted.append(chunk) }

        // Build the EXPECTED chunks manually and assert byte equality with
        // the translator's output. This pins the OpenAIChatStream envelope-
        // parity invariant (Lauret P0).
        let created = 1_700_000_000
        let model = "claude-haiku-3.5"
        let id = "chatcmpl-parity"
        let expectedRole = OpenAIChatStream.Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)]
        )
        let expectedContent1 = OpenAIChatStream.Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(content: "Hello "), finishReason: nil)]
        )
        let expectedContent2 = OpenAIChatStream.Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(content: "world"), finishReason: nil)]
        )
        let expectedTerm = OpenAIChatStream.Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(), finishReason: "stop")]
        )
        #expect(emitted[0] == OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(expectedRole)))
        #expect(emitted[1] == OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(expectedContent1)))
        #expect(emitted[2] == OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(expectedContent2)))
        #expect(emitted[3] == OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(expectedTerm)))
    }

    // MARK: - 3. End-to-end via OpenAIChatStream.run(plan:sink:)

    @Test func endToEndDriveThroughCapturedSink() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _happyPathSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-e2e"
        )

        final class Captured: @unchecked Sendable {
            let lock = NSLock()
            var bytes = Data()
            var closed = false
            func write(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
            func close() { lock.lock(); closed = true; lock.unlock() }
            var snapshot: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        }
        let captured = Captured()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )

        let status = OpenAIChatStream.run(plan: outcome.plan, sink: sink)
        #expect(status == .completed)
        #expect(captured.closed)

        let wire = String(data: captured.snapshot, encoding: .utf8) ?? ""
        // Head (HTTP/1.1 200 OK with SSE content type), role/content chunks
        // (data: {…"role":"assistant"…}, "Hello ", "world"), terminal stop
        // chunk, and the [DONE] sentinel — all in order.
        #expect(wire.contains("HTTP/1.1 200 OK"))
        #expect(wire.contains("Content-Type: text/event-stream"))
        #expect(wire.contains("\"role\":\"assistant\""))
        #expect(wire.contains("\"content\":\"Hello \""))
        #expect(wire.contains("\"content\":\"world\""))
        #expect(wire.contains("\"finish_reason\":\"stop\""))
        #expect(wire.contains("data: [DONE]\n\n"))
        // Lauret r12 re-audit P3 — sse-B role-chunk exactly-once: lock
        // "role chunk emitted exactly once" per the OpenAI contract.
        // One occurrence of "role":"assistant" → split yields 2 components.
        #expect(wire.components(separatedBy: "\"role\":\"assistant\"").count == 2,
                "role chunk must be emitted EXACTLY once; wire: \(wire)")
        // Order: role chunk precedes content chunks precedes terminal stop
        // precedes DONE sentinel.
        let roleIdx = wire.range(of: "\"role\":\"assistant\"")!.lowerBound
        let helloIdx = wire.range(of: "\"content\":\"Hello \"")!.lowerBound
        let worldIdx = wire.range(of: "\"content\":\"world\"")!.lowerBound
        let stopIdx = wire.range(of: "\"finish_reason\":\"stop\"")!.lowerBound
        let doneIdx = wire.range(of: "data: [DONE]\n\n")!.lowerBound
        #expect(roleIdx < helloIdx)
        #expect(helloIdx < worldIdx)
        #expect(worldIdx < stopIdx)
        #expect(stopIdx < doneIdx)
    }

    // MARK: - 4. Single-audit-row invariant

    @Test func singleAuditRowPerStreamedRequest() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _happyPathSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let path = "/tmp/senkani-sse-b-audit-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }
        let chain = OpenAIAuditChain()

        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: "anthropic-test-label",
            now: Date(timeIntervalSince1970: 1_700_000_001),
            id: "chatcmpl-audit"
        )
        // Wrap Plan.onFinish to call record(...) via the builder (mirror
        // ServeCommand wiring exactly).
        let basePlan = outcome.plan
        let auditFieldsBuilder = outcome.auditFieldsBuilder
        let wrapped = OpenAIChatStream.Plan(
            head: basePlan.head,
            streamingEvents: basePlan.streamingEvents!,
            done: basePlan.done,
            onFinish: { status in
                let fields = auditFieldsBuilder(status)
                OpenAIServedRequestSink.record(
                    chain: chain, fields: fields, bodies: nil,
                    db: db, surface: .chatStream, httpStatus: 200
                )
            }
        )
        final class Captured: @unchecked Sendable {
            let lock = NSLock()
            var closed = false
            func close() { lock.lock(); closed = true; lock.unlock() }
        }
        let captured = Captured()
        let sink = OpenAIChatStream.Sink(
            write: { _ in },
            isCancelled: { false },
            close: { captured.close() }
        )
        let status = OpenAIChatStream.run(plan: wrapped, sink: sink)
        #expect(status == .completed)
        #expect(captured.closed)

        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1, "expected exactly one audit row; got \(rows.count)")
        guard let row = rows.first else { return }
        // OpenAIRequestLogStore.Surface.chatStream serializes as the SQLite
        // TEXT value "chat_stream" (rawValue).
        #expect(row.surface == OpenAIRequestLogStore.Surface.chatStream.rawValue)
        #expect(row.status == 200)
        #expect(row.keyLabel == "anthropic-test-label")
        #expect(row.inputTokens == 7, "expected captured realPromptTokens=7; got \(row.inputTokens ?? -1)")
        #expect(row.outputTokens == 3, "expected captured realCompletionTokens=3; got \(row.outputTokens ?? -1)")
        #expect(row.resolvedTier == "quick")
    }

    // MARK: - 5. Factory invariants for the streamHandler wire

    @Test func streamingPlanFactoryProducesNonNilPlanForConfiguredEngine() async throws {
        // Pure invariant — no upstream traffic; just assert the factory
        // returns a Plan with a non-nil streamingEvents source so the
        // ServeCommand streamHandler wire can return it. The
        // `claudeEngine == nil` case is enforced at the ServeCommand site
        // (`guard let claudeEngine else { return nil }`) and is not
        // exercised through this factory.
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-factory"
        )
        #expect(outcome.plan.streamingEvents != nil,
            "streaming factory must produce a Plan whose streamingEvents source is set")
        // Drive a no-op audit-fields builder to verify the builder is
        // wired and emits the expected envelope token (status=ok / cancel).
        let okFields = outcome.auditFieldsBuilder(.completed)
        #expect(okFields.status == "ok")
        #expect(okFields.surface == "chat")
        #expect(okFields.resolvedTier == "quick")
        let cancelFields = outcome.auditFieldsBuilder(.clientCancel)
        #expect(cancelFields.status == "client_cancel")
    }
}
