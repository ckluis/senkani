import Testing
import Foundation
@testable import Core

// V.13b-sse-a — Adversarial parser + engine integration tests for the
// Anthropic SSE streaming seam (Child A of the v13b-sse decomposition).
//
// Hardening surfaces exercised:
//   1. Happy-path frame sequence ordering.
//   2. `event: ping` body is dropped UNPARSED (defensive).
//   3. `maxFrameBytes` cap → `frameTooLarge`; error description does NOT
//      echo any oversized body bytes.
//   4. `event: error` redaction — only `error.type` surfaces; `error.message`
//      is dropped at the parser boundary.
//   5. Frame split across chunk boundary — line / frame accumulation is
//      stable even when bytes arrive in arbitrary batches.
//   6. Engine integration: `chatStream(...)` builds the right request
//      headers (`accept: text/event-stream`, `x-api-key`, ...) and a
//      `stream: true` body; yields the expected event sequence.
//   7. Cancel-propagation probe: consumer-task cancellation reaches
//      `MockSSEStreamProtocol.stopLoading()` within ≤500ms.

// MARK: - Helpers

/// Wrap a `[UInt8]` array as a Sendable AsyncSequence of bytes. The parser
/// is generic over `S: AsyncSequence & Sendable where S.Element == UInt8`.
private struct ByteFeed: AsyncSequence, Sendable {
    typealias Element = UInt8
    let bytes: [UInt8]
    /// Optional split points (indices BEFORE which to artificially suspend)
    /// — exercises the chunk-boundary code path.
    let splitPoints: Set<Int>

    init(_ bytes: [UInt8], splitAt splitPoints: Set<Int> = []) {
        self.bytes = bytes
        self.splitPoints = splitPoints
    }

    struct Iterator: AsyncIteratorProtocol {
        var bytes: [UInt8]
        var i: Int = 0
        let splitPoints: Set<Int>
        mutating func next() async -> UInt8? {
            if i >= bytes.count { return nil }
            // Surrender the thread briefly at each split point so the
            // parser observes a true chunk boundary (no more bytes
            // available momentarily). `Task.yield()` is the lightweight
            // mechanism — no real time delay needed.
            if splitPoints.contains(i) {
                await Task.yield()
            }
            let b = bytes[i]
            i += 1
            return b
        }
    }
    func makeAsyncIterator() -> Iterator {
        Iterator(bytes: bytes, splitPoints: splitPoints)
    }
}

private func collect(
    _ stream: AsyncThrowingStream<AnthropicStreamEvent, Error>
) async throws -> [AnthropicStreamEvent] {
    var out: [AnthropicStreamEvent] = []
    for try await ev in stream { out.append(ev) }
    return out
}

private func feed(_ s: String) -> ByteFeed { ByteFeed(Array(s.utf8)) }

// MARK: - Parser tests

@Suite("AnthropicSSEFrameParser — defensive parsing", .serialized)
struct AnthropicSSEFrameParserTests {

    @Test func happyPathFrameSequence() async throws {
        // Concatenated frames for a tiny end-to-end conversation.
        let wire = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_xyz","usage":{"input_tokens":7}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}


        """

        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        #expect(events == [
            .messageStart(id: "msg_xyz", inputTokens: 7),
            .contentBlockStart(index: 0, block: .text),
            .contentBlockDelta(index: 0, delta: .textDelta("Hel")),
            .contentBlockDelta(index: 0, delta: .textDelta("lo ")),
            .contentBlockDelta(index: 0, delta: .textDelta("world")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn", outputTokens: 3),
            .messageStop,
        ])
    }

    @Test func pingFrameIsDroppedUnparsedAndDoesNotBreakStream() async throws {
        // The ping body here is DELIBERATELY garbage (non-JSON) — the
        // parser MUST NOT attempt to decode it. The two valid frames
        // around it must still surface in order.
        let wire = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_a","usage":{"input_tokens":1}}}

        event: ping
        data: !!! not-json garbage <<>> %%%

        event: message_stop
        data: {"type":"message_stop"}


        """
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        #expect(events == [
            .messageStart(id: "msg_a", inputTokens: 1),
            .messageStop,
        ])
    }

    @Test func oversizedFrameThrowsAndDoesNotEchoBody() async throws {
        // Build `data: AAAA...` >256 KiB WITHOUT a terminating blank line.
        // Mark with a distinctive sentinel character so we can assert it
        // never leaks into the error description.
        let sentinel = "PROMPT_BLEED_MARKER_QQQ"
        let head = "data: \(sentinel)"
        let pad = String(repeating: "A", count: AnthropicSSEFrameParser.maxFrameBytes + 1024)
        let wire = head + pad  // NO blank line — frame never terminates

        var caught: Error?
        do {
            _ = try await collect(
                AnthropicSSEFrameParser.parseFrames(feed(wire))
            )
            Issue.record("expected frameTooLarge")
        } catch {
            caught = error
        }

        // Variant + identifier check.
        #expect(caught is AnthropicSSEFrameParser.FrameError)
        if let fe = caught as? AnthropicSSEFrameParser.FrameError {
            #expect(fe == .frameTooLarge)
        }
        // Info-leak guard: error stringification must NOT echo the
        // sentinel marker nor a run of body bytes.
        let described = String(describing: caught as Any)
        #expect(!described.contains(sentinel),
            "error description echoed sentinel marker — info leak")
        #expect(!described.contains("AAAAAAAAAA"),
            "error description echoed body bytes — info leak")
    }

    @Test func errorFrameRedactsMessageKeepsOnlyType() async throws {
        let leakMarker = "sk-ant-LEAK-FRAGMENT-XYZ"
        let wire = """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"prompt content \(leakMarker) bleed"}}


        """
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        #expect(events == [.error(type: "overloaded_error")])

        // Stringify each event and assert the leak marker is absent.
        let stringified = events.map { "\($0)" }.joined(separator: "|")
        #expect(!stringified.contains(leakMarker),
            "stringified event echoed error.message bytes — info leak")
        #expect(!stringified.contains("prompt content"),
            "stringified event echoed error.message bytes — info leak")
    }

    @Test func frameSplitAcrossChunkBoundaryAccumulatesCorrectly() async throws {
        // Single frame whose `event:` line is split mid-token; we add a
        // chunk-boundary in the middle of `message_start` and another in
        // the middle of the JSON body.
        let frame = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_01\",\"usage\":{\"input_tokens\":7}}}\n\n"
        let bytes = Array(frame.utf8)

        // Split points: in the middle of "message_start" and inside the
        // JSON body. The custom AsyncSequence inserts `Task.yield()` at
        // those indices to force a true async chunk boundary.
        let split1 = (frame.range(of: "messag")!.upperBound.utf16Offset(in: frame)) // after "messag"
        let split2 = (frame.range(of: "\"id\":\"")!.upperBound.utf16Offset(in: frame)) // mid JSON
        let splits: Set<Int> = [split1, split2]
        let feed = ByteFeed(bytes, splitAt: splits)

        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed)
        )
        #expect(events == [.messageStart(id: "msg_01", inputTokens: 7)])
    }

    @Test func commentLinesAreSkipped() async throws {
        // SSE comment lines (`:`-prefixed) are common heartbeats.
        let wire = """
        : this is a heartbeat
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_z","usage":{"input_tokens":1}}}

        : another heartbeat
        : and another
        event: message_stop
        data: {"type":"message_stop"}


        """
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        #expect(events == [
            .messageStart(id: "msg_z", inputTokens: 1),
            .messageStop,
        ])
    }

    // Schneier P2 FOLD verifier: a malformed payload of a KNOWN event type
    // (e.g. `message_delta` with `delta` as a string, not an object) MUST
    // drop silently — the parser must continue yielding subsequent valid
    // frames. A single hostile / buggy frame must NOT abort the whole
    // session.
    @Test func malformedKnownTypePayloadIsSkippedAndStreamContinues() async throws {
        let wire = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_x","usage":{"input_tokens":2}}}

        event: message_delta
        data: {"type":"message_delta","delta":"not-an-object","usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        // The malformed message_delta is dropped; messageStart and messageStop
        // still arrive — stream is NOT aborted by the bad frame.
        #expect(events == [
            .messageStart(id: "msg_x", inputTokens: 2),
            .messageStop,
        ])
    }

    // Schneier r11 re-audit P3 — sse-A adversarial gap (a): a `data:`
    // frame with NO `event:` line AND a JSON body that lacks the `type`
    // field. The `TypeSniff try?` path in `decodeEvent(from:eventName:)`
    // must drop it silently — and the surrounding valid frames must
    // continue to flow.
    @Test func dataFrameWithoutEventAndWithoutTypeFieldIsSilentlyDropped() async throws {
        let wire = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_q","usage":{"input_tokens":1}}}

        data: {"not_type":"orphan","payload":"ignored"}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        // The orphan frame (no event:, no type:) is dropped silently;
        // the surrounding valid frames are unaffected.
        #expect(events == [
            .messageStart(id: "msg_q", inputTokens: 1),
            .messageStop,
        ])
    }

    // Schneier r11 re-audit P3 — sse-A adversarial gap (b): mixed `\n`
    // and `\r\n` line endings WITHIN A SINGLE FRAME. The parser strips
    // trailing CR on line finalize, so both terminations are tolerated
    // and the frame still decodes correctly.
    @Test func mixedLfAndCrlfLineEndingsWithinSingleFrameParseCorrectly() async throws {
        // Hand-craft the bytes: event line ends in \r\n, data line ends
        // in \n, then \r\n\r\n frame terminator (mixed within the frame).
        let bytes: [UInt8] =
            Array("event: message_start\r\n".utf8) +
            Array("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_mix\",\"usage\":{\"input_tokens\":3}}}\n".utf8) +
            Array("\r\n".utf8)
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(ByteFeed(bytes))
        )
        #expect(events == [.messageStart(id: "msg_mix", inputTokens: 3)])
    }

    @Test func toolUseBlockAndInputJsonDelta() async throws {
        let wire = """
        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_abc","name":"get_weather"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"loc\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"SF\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}


        """
        let events = try await collect(
            AnthropicSSEFrameParser.parseFrames(feed(wire))
        )
        #expect(events == [
            .contentBlockStart(index: 1, block: .toolUse(id: "tu_abc", name: "get_weather")),
            .contentBlockDelta(index: 1, delta: .inputJsonDelta("{\"loc\":")),
            .contentBlockDelta(index: 1, delta: .inputJsonDelta("\"SF\"}")),
            .contentBlockStop(index: 1),
        ])
    }
}

// MARK: - Engine integration (chatStream)

private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func makeStreamingEngine(apiKey: String = "ak-stream-test") -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockSSEStreamProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: apiKey,
        session: session,
        endpoint: anthropicURL,
        sleeper: { _ in },
        requestTimeout: 5.0
    )
}

@Suite("AnthropicArmStreamEngine — chatStream wire+contract", .serialized, .urlProtocolGate)
struct AnthropicArmStreamEngineTests {

    @Test func chatStreamSetsAcceptAndStreamTrueAndYieldsEvents() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }

        // Build a small chunked SSE response, splitting across two chunks
        // to exercise the byte-level boundary.
        let part1 = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_eng","usage":{"input_tokens":4}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}


        """
        let part2 = """
        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        MockSSEStreamProtocol.register(
            url: anthropicURL,
            chunks: [Data(part1.utf8), Data(part2.utf8)]
        )

        let engine = makeStreamingEngine()
        let stream = engine.chatStream(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "yo")],
            tools: []
        )

        var events: [AnthropicStreamEvent] = []
        for try await ev in stream { events.append(ev) }

        #expect(events == [
            .messageStart(id: "msg_eng", inputTokens: 4),
            .contentBlockStart(index: 0, block: .text),
            .contentBlockDelta(index: 0, delta: .textDelta("hi")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn", outputTokens: 1),
            .messageStop,
        ])

        // Request shape assertions.
        let req = MockSSEStreamProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(req?.value(forHTTPHeaderField: "x-api-key") == "ak-stream-test")
        #expect(req?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // Per-attempt request timeout was set per `requestTimeout`.
        if let interval = req?.timeoutInterval {
            #expect(interval == 5.0)
        } else {
            Issue.record("URLRequest.timeoutInterval not set")
        }

        // Body envelope: must include stream:true and the wire model id.
        let recordedBody: String = {
            guard let req = MockSSEStreamProtocol.lastRequest else { return "" }
            if let body = req.httpBody { return String(data: body, encoding: .utf8) ?? "" }
            guard let stream = req.httpBodyStream else { return "" }
            stream.open(); defer { stream.close() }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return String(data: out, encoding: .utf8) ?? ""
        }()
        #expect(recordedBody.contains("\"stream\":true"))
        #expect(recordedBody.contains("\"model\":\"claude-3-5-haiku-latest\""))
    }

    @Test func chatStreamRejectsUnknownModelBeforeWire() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        let engine = makeStreamingEngine()
        let stream = engine.chatStream(
            model: "claude-fake-2",
            messages: [.init(role: "user", content: "x")],
            tools: []
        )
        var caught: Error?
        do {
            for try await _ in stream { Issue.record("expected throw") }
        } catch {
            caught = error
        }
        #expect((caught as? ClaudeAPIChatEngineError) == .upstreamModelUnavailable(model: "claude-fake-2"))
        #expect(MockSSEStreamProtocol.lastRequest == nil)
    }

    @Test func cancelPropagatesToURLProtocolStopLoading() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }

        // Register a stream that sends one chunk, then delays a long time
        // before the next. We want the consumer to cancel mid-stream.
        let head = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_cancel","usage":{"input_tokens":1}}}


        """
        // Provide many chunks with delays so the protocol thread spends
        // most of its time sleeping, giving the cancel a place to land.
        var chunks: [Data] = [Data(head.utf8)]
        for _ in 0..<20 {
            chunks.append(Data("""
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}


            """.utf8))
        }
        MockSSEStreamProtocol.register(
            url: anthropicURL,
            chunks: chunks,
            delayBetweenMs: 100  // 20 chunks × 100ms ≈ 2s window
        )

        let engine = makeStreamingEngine()

        // Run iteration inside a Task we can cancel from outside; the
        // task holds the stream + iterator until it's cancelled (which
        // triggers the AsyncThrowingStream onTermination → explicit
        // dataTask.cancel() seam in the engine).
        let firstEventArrived = AsyncSignal()
        let consumer = Task {
            let stream = engine.chatStream(
                model: "claude-haiku-3.5",
                messages: [.init(role: "user", content: "cancel-probe")],
                tools: []
            )
            do {
                for try await _ in stream {
                    await firstEventArrived.signal()
                    // Block forever waiting for more events; cancellation
                    // will tear us down.
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch { /* cancelled */ }
        }

        // Wait for the first event to land, then cancel.
        await firstEventArrived.wait()
        consumer.cancel()

        // Poll up to 500ms for stopLoading observation.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if MockSSEStreamProtocol.observedStopLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        _ = await consumer.value
        #expect(MockSSEStreamProtocol.observedStopLoading,
            "cancellation did not propagate to URLProtocol.stopLoading() within 500ms")
    }
}

/// Tiny one-shot async signal — primary use here is the cancel-propagation
/// probe coordinating "first event arrived" between consumer + outer test.
private actor AsyncSignal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        if let w = waiter { waiter = nil; w.resume(); return }
        fired = true
    }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiter = cont
        }
    }
}
