import Testing
import Foundation
@testable import Core

// V.13b-sse-d — terminal-mode tests for the Anthropic serve-path streaming
// dispatch shipped by Child D of the v13b-followup-anthropic-sse-streaming
// decomposition.
//
// Coverage (≥6 tests):
//   1. Happy-path completed — single audit row with status "ok".
//   2. clientCancel mid-content — sink cancels; status "client_cancel",
//      observed stopLoading propagation through the URLSessionDataTask.
//   3. upstreamError mid-stream — `event: error` after some content;
//      wire ends with error line (no [DONE]); status
//      "upstream_error:overloaded_error".
//   4. upstreamError before messageStart — error is the first frame; wire
//      contains only HTTP head + error line (no role chunk).
//   5. Info-leak guard — emitted wire bytes + audit row contain NEITHER
//      the upstream `error.message` text nor any sensitive marker.
//   6. First-frame-retry NOT attempted — documented limitation: a 200 OK
//      followed by `event: error` as the first frame surfaces
//      `.upstreamError(code:)` after exactly ONE upstream OPEN.
//   7. tool_arguments_malformed mid-stream — Child C's defensive throw
//      surfaces as `.upstreamError(code: "tool_arguments_malformed")`.

// MARK: - Helpers

private let _anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func _makeStreamingEngine(apiKey: String = "ak-sse-d-test") -> ClaudeAPIChatEngine {
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

private func _happyPathChunks() -> [Data] {
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_ok","usage":{"input_tokens":5}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    return [Data(frame.utf8)]
}

private func _midStreamErrorChunks() -> [Data] {
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_err","usage":{"input_tokens":5}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"start "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"now"}}

    event: error
    data: {"type":"error","error":{"type":"overloaded_error","message":"server is overloaded"}}


    """
    return [Data(frame.utf8)]
}

private func _errorBeforeMessageStartChunks() -> [Data] {
    let frame = """
    event: error
    data: {"type":"error","error":{"type":"overloaded_error"}}


    """
    return [Data(frame.utf8)]
}

private func _infoLeakErrorChunks(marker: String) -> [Data] {
    // The upstream's `error.message` carries a unique marker. The Anthropic
    // SSE frame parser MUST drop the message field; the serve-path's
    // streamErrorLine must emit only the short type/code identifier; the
    // audit row's `status` must never contain the marker.
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_leak","usage":{"input_tokens":3}}}

    event: error
    data: {"type":"error","error":{"type":"overloaded_error","message":"PROMPT CONTENT WITH \(marker) INSIDE"}}


    """
    return [Data(frame.utf8)]
}

private func _malformedToolUseChunks() -> [Data] {
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_tu","usage":{"input_tokens":3}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_bad","name":"buggy"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"loc"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    return [Data(frame.utf8)]
}

private final class _CapturedSink: @unchecked Sendable {
    let lock = NSLock()
    var bytes = Data()
    var closed = false
    func write(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var snapshotString: String { String(data: snapshot, encoding: .utf8) ?? "" }
    var didClose: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

// MARK: - Tests

@Suite("ClaudeAPIServeDispatch.streamingPlan — cancellation + upstream-error (Child D)",
       .serialized, .urlProtocolGate)
struct AnthropicSSEServeDispatchCancellationErrorTests {

    // 1. Happy-path completed → exactly one audit row, status "ok".
    @Test func happyPathCompletedYieldsOkAuditRow() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: _anthropicURL, chunks: _happyPathChunks())

        let engine = _makeStreamingEngine()
        let path = "/tmp/senkani-sse-d-ok-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }
        let chain = OpenAIAuditChain()

        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-d-ok"
        )

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func bump() { lock.lock(); calls += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let recordCalls = Counter()
        let basePlan = outcome.plan
        let auditFieldsBuilder = outcome.auditFieldsBuilder
        let wrapped = OpenAIChatStream.Plan(
            head: basePlan.head,
            streamingEvents: basePlan.streamingEvents!,
            done: basePlan.done,
            onFinish: { status in
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
        let captured = _CapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )
        let status = OpenAIChatStream.run(plan: wrapped, sink: sink)
        #expect(status == .completed)
        #expect(captured.didClose)
        #expect(recordCalls.count == 1, "expected exactly ONE record() call; got \(recordCalls.count)")

        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.status == 200)
        #expect(chain.entries.count == 1)
        #expect(chain.entries.first?.fields.status == "ok")
    }

    // 2. clientCancel mid-content → status "client_cancel"; stopLoading
    //    flag observed (CancelBox seam from Child A still works).
    @Test func clientCancelMidContentPropagatesAndAudits() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        // Two-chunk stream with a small delay so the sink can cancel mid-flight.
        let p1 = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_c","usage":{"input_tokens":4}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial "}}


        """
        let p2 = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"more"}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: [Data(p1.utf8), Data(p2.utf8)],
            delayBetweenMs: 200
        )

        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine, request: _request(), routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_001),
            id: "chatcmpl-d-cancel"
        )

        // CancellingSink: flips isCancelled after the first data write
        // (after the head was written).
        final class CancellingState: @unchecked Sendable {
            let lock = NSLock()
            private var writes = 0
            private var closed = false
            func recordWrite() { lock.lock(); writes += 1; lock.unlock() }
            var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
            // Cancel after head + 1 data event = 2 writes.
            var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return writes >= 2 }
            func setClosed() { lock.lock(); closed = true; lock.unlock() }
            var didClose: Bool { lock.lock(); defer { lock.unlock() }; return closed }
        }
        let state = CancellingState()
        final class StatusBox: @unchecked Sendable {
            let lock = NSLock()
            var status: OpenAIChatStream.FinishStatus?
            func set(_ s: OpenAIChatStream.FinishStatus) { lock.lock(); status = s; lock.unlock() }
            var snapshot: OpenAIChatStream.FinishStatus? { lock.lock(); defer { lock.unlock() }; return status }
        }
        let statusBox = StatusBox()
        final class CountBox: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let recordCalls = CountBox()
        let auditFieldsBuilder = outcome.auditFieldsBuilder
        let basePlan = outcome.plan
        let wrapped = OpenAIChatStream.Plan(
            head: basePlan.head,
            streamingEvents: basePlan.streamingEvents!,
            done: basePlan.done,
            onFinish: { status in
                statusBox.set(status)
                _ = auditFieldsBuilder(status)
                recordCalls.bump()
            },
            errorTypeExtractor: basePlan.errorTypeExtractor,
            errorTerminatorBuilder: basePlan.errorTerminatorBuilder
        )
        let sink = OpenAIChatStream.Sink(
            write: { _ in state.recordWrite() },
            isCancelled: { state.isCancelled },
            close: { state.setClosed() }
        )
        let result = OpenAIChatStream.run(plan: wrapped, sink: sink)
        #expect(result == .clientCancel)
        #expect(statusBox.snapshot == .clientCancel)
        #expect(state.didClose)
        #expect(recordCalls.count == 1, "expected exactly ONE onFinish call; got \(recordCalls.count)")

        // Karpathy r10 P1: cancellation propagates to URLSessionDataTask
        // via Child A's CancelBox → URLProtocol.stopLoading().
        // Give the cancel signal a brief window to propagate (~100ms SLA).
        let deadline = Date().addingTimeInterval(0.5)
        while !MockSSEStreamProtocol.observedStopLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(MockSSEStreamProtocol.observedStopLoading,
            "expected stopLoading to be observed within SLA (Child A CancelBox seam)")
    }

    // 3. upstreamError mid-stream → wire ends with error line + NO [DONE];
    //    audit row "upstream_error:overloaded_error"; exactly one record().
    @Test func upstreamErrorMidStreamEmitsErrorLineAndAudits() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: _anthropicURL, chunks: _midStreamErrorChunks())

        let engine = _makeStreamingEngine()
        let path = "/tmp/senkani-sse-d-mid-err-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }
        let chain = OpenAIAuditChain()

        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine, request: _request(), routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_002),
            id: "chatcmpl-d-err"
        )
        let basePlan = outcome.plan
        let auditFieldsBuilder = outcome.auditFieldsBuilder
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let recordCalls = Counter()
        final class StatusBox: @unchecked Sendable {
            let lock = NSLock(); var s: OpenAIChatStream.FinishStatus?
            func set(_ x: OpenAIChatStream.FinishStatus) { lock.lock(); s = x; lock.unlock() }
            var get: OpenAIChatStream.FinishStatus? { lock.lock(); defer { lock.unlock() }; return s }
        }
        let statusBox = StatusBox()
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
        let captured = _CapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )
        let result = OpenAIChatStream.run(plan: wrapped, sink: sink)
        if case .upstreamError(let code) = result {
            #expect(code == "overloaded_error")
        } else {
            Issue.record("expected .upstreamError(code: overloaded_error); got \(result)")
        }
        if case .upstreamError(let code) = statusBox.get {
            #expect(code == "overloaded_error")
        } else {
            Issue.record("expected statusBox upstreamError; got \(String(describing: statusBox.get))")
        }
        #expect(recordCalls.count == 1)

        let wire = captured.snapshotString
        #expect(wire.contains("HTTP/1.1 200 OK"))
        #expect(wire.contains("\"role\":\"assistant\""))
        #expect(wire.contains("\"content\":\"start \""))
        #expect(wire.contains("\"content\":\"now\""))
        let errorLine = #"data: {"error":{"type":"upstream_error","code":"overloaded_error"}}"#
        #expect(wire.contains(errorLine),
            "expected wire to contain the upstream error line; got: \(wire)")
        // No [DONE] sentinel after the error.
        #expect(!wire.contains("data: [DONE]"),
            "[DONE] must NOT appear after upstream error (Schneier r10 P0)")

        // Audit row carries upstream_error:overloaded_error.
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        #expect(chain.entries.count == 1)
        #expect(chain.entries.first?.fields.status == "upstream_error:overloaded_error")
    }

    // 4. upstreamError BEFORE messageStart → no role chunk; just head +
    //    error line; FinishStatus.upstreamError("overloaded_error").
    @Test func upstreamErrorBeforeMessageStartEmitsOnlyErrorLine() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: _anthropicURL, chunks: _errorBeforeMessageStartChunks())

        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine, request: _request(), routing: _routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_003),
            id: "chatcmpl-d-pre"
        )
        let basePlan = outcome.plan
        let auditFieldsBuilder = outcome.auditFieldsBuilder
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let recordCalls = Counter()
        final class FieldsBox: @unchecked Sendable {
            let lock = NSLock(); var f: OpenAIAuditChain.AuditFields?
            func set(_ x: OpenAIAuditChain.AuditFields) { lock.lock(); f = x; lock.unlock() }
            var get: OpenAIAuditChain.AuditFields? { lock.lock(); defer { lock.unlock() }; return f }
        }
        let fbox = FieldsBox()
        let wrapped = OpenAIChatStream.Plan(
            head: basePlan.head,
            streamingEvents: basePlan.streamingEvents!,
            done: basePlan.done,
            onFinish: { status in
                let fields = auditFieldsBuilder(status)
                fbox.set(fields)
                recordCalls.bump()
            },
            errorTypeExtractor: basePlan.errorTypeExtractor,
            errorTerminatorBuilder: basePlan.errorTerminatorBuilder
        )
        let captured = _CapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )
        let result = OpenAIChatStream.run(plan: wrapped, sink: sink)
        if case .upstreamError(let code) = result {
            #expect(code == "overloaded_error")
        } else {
            Issue.record("expected .upstreamError; got \(result)")
        }
        #expect(recordCalls.count == 1)

        let wire = captured.snapshotString
        #expect(wire.contains("HTTP/1.1 200 OK"))
        // No role chunk: the upstream `event: error` arrived before
        // `event: message_start`, so no chat.completion.chunk was emitted.
        #expect(!wire.contains("\"role\":\"assistant\""),
            "no role chunk should appear when error precedes messageStart; wire: \(wire)")
        let errorLine = #"data: {"error":{"type":"upstream_error","code":"overloaded_error"}}"#
        #expect(wire.contains(errorLine))
        #expect(!wire.contains("data: [DONE]"))

        // realPromptTokens nil (no messageStart) → audit row falls back to
        // the heuristic prompt-token count, NOT real. We assert the status
        // is the upstream-error variant.
        #expect(fbox.get?.status == "upstream_error:overloaded_error")
    }

    // 5. Info-leak guard: upstream error.message MUST never reach the wire
    //    or the audit row.
    @Test func upstreamErrorMessageNeverLeaksToWireOrAudit() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        // Unique marker — if any of these substrings appears on the wire
        // or in the audit row's status, info has leaked.
        let marker = "sk-ant-LEAK-FRAGMENT-xxx"
        MockSSEStreamProtocol.register(url: _anthropicURL, chunks: _infoLeakErrorChunks(marker: marker))

        let engine = _makeStreamingEngine()
        let path = "/tmp/senkani-sse-d-leak-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }
        let chain = OpenAIAuditChain()

        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine, request: _request(), routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_004),
            id: "chatcmpl-d-leak"
        )
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
            },
            errorTypeExtractor: basePlan.errorTypeExtractor,
            errorTerminatorBuilder: basePlan.errorTerminatorBuilder
        )
        let captured = _CapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )
        _ = OpenAIChatStream.run(plan: wrapped, sink: sink)

        let wire = captured.snapshotString
        // None of the marker substrings should appear anywhere on the wire.
        #expect(!wire.contains(marker),
            "marker leaked to wire: \(wire)")
        #expect(!wire.contains("PROMPT CONTENT"))
        #expect(!wire.contains("LEAK-FRAGMENT"))
        #expect(!wire.contains("sk-ant-LEAK"))
        // The error line itself must contain ONLY the short identifier.
        let errorLine = #"data: {"error":{"type":"upstream_error","code":"overloaded_error"}}"#
        #expect(wire.contains(errorLine))

        // Audit row's status field carries ONLY the short identifier.
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        guard let entry = chain.entries.first else {
            Issue.record("no audit chain entry written"); return
        }
        let statusStr = entry.fields.status
        #expect(statusStr == "upstream_error:overloaded_error")
        #expect(!statusStr.contains(marker))
        #expect(!statusStr.contains("PROMPT CONTENT"))
        #expect(!statusStr.contains("LEAK-FRAGMENT"))
    }

    // 6. First-frame retry NOT attempted: a 200 OK followed by `event: error`
    //    as the FIRST upstream frame surfaces .upstreamError(code:) without
    //    a retry-of-OPEN. Documents the Karpathy r10 limitation (a
    //    follow-up item can extend this to a first-frame retry loop).
    @Test func firstFrameErrorIsNotRetriedOnceUpstreamOpens() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: _anthropicURL, chunks: _errorBeforeMessageStartChunks())

        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine, request: _request(), routing: _routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_005),
            id: "chatcmpl-d-noretry"
        )
        let basePlan = outcome.plan
        let captured = _CapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )
        let result = OpenAIChatStream.run(plan: basePlan, sink: sink)
        if case .upstreamError(let code) = result {
            #expect(code == "overloaded_error")
        } else {
            Issue.record("expected .upstreamError; got \(result)")
        }
        // Only ONE upstream OPEN happened — the MockSSEStreamProtocol's
        // `lastRequest` is set on startLoading and never reset within a
        // single registered stream. We assert it via a single registered
        // chunk fixture and check that no second URLSession.bytes(for:)
        // attempt would have observed a different request: the protocol
        // would have hit the `streams[k]` lookup again and pushed the
        // same chunks. We confirm via the wire shape — exactly ONE error
        // line, exactly ONE HTTP head.
        let wire = captured.snapshotString
        let httpHeads = wire.components(separatedBy: "HTTP/1.1 200 OK").count - 1
        let errLines = wire.components(separatedBy: #""code":"overloaded_error""#).count - 1
        #expect(httpHeads == 1, "expected exactly ONE HTTP head; got \(httpHeads). wire: \(wire)")
        #expect(errLines == 1, "expected exactly ONE error line; got \(errLines)")
    }

    // 7. tool_arguments_malformed mid-stream (Child C defensive throw) →
    //    surfaces as .upstreamError(code: "tool_arguments_malformed").
    @Test func toolArgumentsMalformedSurfacesAsUpstreamError() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: _anthropicURL, chunks: _malformedToolUseChunks())

        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine, request: _request(), routing: _routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_006),
            id: "chatcmpl-d-toolbad"
        )
        let basePlan = outcome.plan
        let captured = _CapturedSink()
        let sink = OpenAIChatStream.Sink(
            write: { d in captured.write(d) },
            isCancelled: { false },
            close: { captured.close() }
        )
        let result = OpenAIChatStream.run(plan: basePlan, sink: sink)
        if case .upstreamError(let code) = result {
            #expect(code == "tool_arguments_malformed")
        } else {
            Issue.record("expected .upstreamError(tool_arguments_malformed); got \(result)")
        }
        let wire = captured.snapshotString
        let errorLine = #"data: {"error":{"type":"upstream_error","code":"tool_arguments_malformed"}}"#
        #expect(wire.contains(errorLine))
        // No terminal `finish_reason: "tool_calls"` chunk + no [DONE].
        #expect(!wire.contains("\"finish_reason\":\"tool_calls\""))
        #expect(!wire.contains("data: [DONE]"))
    }

    // 8. streamErrorLine code sanitizer: even a code containing JSON
    //    injection characters strips down to identifier chars only.
    @Test func streamErrorLineSanitizesCodeForJSONInjection() {
        let evil = "evil\"}\n\ninjected_event\ndata: poisoned"
        let line = ClaudeAPIServeDispatch.streamErrorLine(code: evil)
        let s = String(data: line, encoding: .utf8) ?? ""
        // The bytes are the form: `data: {"error":{"type":"upstream_error","code":"<safe>"}}\n\n`
        // <safe> must be `evilinjected_eventdataposioned`-shape stripped of
        // all non-identifier bytes.
        #expect(s.hasPrefix("data: {\"error\":{\"type\":\"upstream_error\",\"code\":\""))
        #expect(s.hasSuffix("\"}}\n\n"))
        // The injected fragments must not survive intact.
        #expect(!s.contains("injected_event\ndata:"))
        #expect(!s.contains("\"}\n\n"))
        // Re-parse the JSON envelope and confirm it's a well-formed object.
        let prefix = "data: ".count
        let bodyStart = s.index(s.startIndex, offsetBy: prefix)
        let bodyEnd = s.index(s.endIndex, offsetBy: -2)  // strip trailing "\n\n"
        let body = String(s[bodyStart..<bodyEnd])
        let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8))
        #expect(parsed != nil, "envelope must remain valid JSON after sanitization; body: \(body)")
        // Schneier sse-D re-audit P3 FOLD: pin the EXACT sanitized output so
        // a future sanitizer regression (e.g. accidentally allowing `:` or
        // `"`) fails this test even though the envelope still re-parses.
        let dict = parsed as? [String: Any]
        let error = dict?["error"] as? [String: Any]
        let code = error?["code"] as? String
        #expect(code == "evilinjected_eventdatapoisoned",
                "sanitized code must whitelist-strip ALL non-ASCII-alphanumeric-underscore bytes; got \(String(describing: code))")
        #expect(error?["type"] as? String == "upstream_error")
    }

    @Test func streamErrorLineFallsBackToUnknownOnFullyStrippedCode() {
        // Schneier sse-D re-audit P3 FOLD: a code that sanitizes to empty
        // (all bytes are non-whitelisted) must fall back to `"unknown"` to
        // keep the wire/audit semantics consistent with the parser's
        // existing `extractErrorTypeOrUnknown` sentinel — never emit
        // `"code":""` to the wire.
        let allSpecial = "!@#$%^&*()"
        let line = ClaudeAPIServeDispatch.streamErrorLine(code: allSpecial)
        let s = String(data: line, encoding: .utf8) ?? ""
        #expect(s.contains("\"code\":\"unknown\""),
                "fully-stripped code must fall back to \"unknown\"; got: \(s)")
        #expect(!s.contains("\"code\":\"\""), "empty-code wire surface is forbidden")
    }

    @Test func auditStatusSanitizesUpstreamCodeAgainstLogInjection() {
        // Schneier sse-D re-audit P3 FOLD: FinishStatus.auditStatus applies
        // the SAME whitelist sanitizer as the wire. A hostile / MITM
        // upstream that returns `error.type` containing newlines or
        // control chars CANNOT plant those bytes into the audit-row
        // `status` column. Defense-in-depth: SQLite param-binding stops
        // SQL injection, but log readers / dashboards rendering the
        // status as text could see log-injection without this guard.
        let hostile = "evil\nINJECTED\rLINE"
        let status = OpenAIChatStream.FinishStatus.upstreamError(code: hostile)
        let audit = status.auditStatus
        #expect(audit == "upstream_error:evilINJECTEDLINE",
                "auditStatus must sanitize via the same whitelist as the wire; got \(audit)")
        #expect(!audit.contains("\n"))
        #expect(!audit.contains("\r"))
        // And the empty-after-sanitize fallback applies here too.
        let empty = OpenAIChatStream.FinishStatus.upstreamError(code: "!!!")
        #expect(empty.auditStatus == "upstream_error:unknown")
    }
}
