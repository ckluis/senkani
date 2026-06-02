import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13b — SSE streaming for POST /v1/chat/completions (`stream: true`).
/// Covers the acceptance checklist from
/// `spec/autonomous/backlog/phase-v13b-chat-streaming-sse.md`:
///
///   1. chunk-shape (chat.completion.chunk + SSE framing)
///   2. DONE-sentinel
///   3. delta-accumulates-to-full-message
///   4. disconnect-cancels-<100ms
///   5. no-connection-leak-on-cancel (and on completion)
///   6. rate-limit-mid-stream-contract (pre-flight refusal, no half-open)
///   7. single-audit-entry
///   8. status-reflects-cancel
///   + live listener SSE round-trip (Network)
@Suite("OpenAI chat streaming (SSE, V.13b)")
struct OpenAIChatStreamTests {

    private static let fixedNow = 1_700_000_000
    private static let model = "claude-haiku"

    /// Strip the `data: ` prefix and trailing blank line from one SSE event.
    private static func payload(_ data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        return s
            .replacingOccurrences(of: "data: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode an event payload's `choices[0].delta.content`, if present.
    private static func deltaContent(_ data: Data) -> String? {
        let json = payload(data)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    /// Decode an event payload's `choices[0].delta.tool_calls[]` fragment
    /// array (V.13d-1), if present. Returns nil for non-tool-call chunks.
    private static func deltaToolCalls(_ data: Data) -> [[String: Any]]? {
        let json = payload(data)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let tcs = delta["tool_calls"] as? [[String: Any]] else { return nil }
        return tcs
    }

    // MARK: - 1. chunk shape

    @Test("events are well-formed chat.completion.chunk objects, SSE-framed")
    func chunkShape() {
        let events = OpenAIChatStream.events(
            id: "chatcmpl-x", created: Self.fixedNow, model: Self.model, content: "hello world"
        )
        // role + 2 content pieces ("hello ", "world") + final = 4 events.
        #expect(events.count == 4)

        // Every event is `data: {...}\n\n`.
        for ev in events {
            let s = String(decoding: ev, as: UTF8.self)
            #expect(s.hasPrefix("data: "))
            #expect(s.hasSuffix("\n\n"))
            #expect(Self.payload(ev).contains("\"object\":\"chat.completion.chunk\""))
        }

        // First chunk carries the assistant role + null finish_reason.
        let first = Self.payload(events[0])
        #expect(first.contains("\"role\":\"assistant\""))
        #expect(first.contains("\"finish_reason\":null"))

        // Final chunk: empty delta + finish_reason "stop".
        let last = Self.payload(events[3])
        #expect(last.contains("\"delta\":{}"))
        #expect(last.contains("\"finish_reason\":\"stop\""))
    }

    // MARK: - 2. DONE sentinel

    @Test("the terminal sentinel is exactly `data: [DONE]\\n\\n`")
    func doneSentinel() {
        let done = OpenAIChatStream.doneSentinel()
        #expect(String(decoding: done, as: UTF8.self) == "data: [DONE]\n\n")
    }

    // MARK: - 3. delta accumulates to full message

    @Test("concatenated delta.content reconstructs the full completion")
    func deltaAccumulatesToFullMessage() {
        let content = "the quick brown fox jumps"
        let events = OpenAIChatStream.events(
            id: "x", created: Self.fixedNow, model: Self.model, content: content
        )
        let reconstructed = events.compactMap { Self.deltaContent($0) }.joined()
        #expect(reconstructed == content)

        // The splitter itself preserves bytes for awkward whitespace.
        #expect(OpenAIChatStream.splitForStreaming("a  b").joined() == "a  b")
        #expect(OpenAIChatStream.splitForStreaming("").isEmpty)
        #expect(OpenAIChatStream.splitForStreaming("nospaces").joined() == "nospaces")
    }

    // MARK: - in-memory sink recorder

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var written: [Data] = []
        private(set) var closes = 0
        private var attempts = 0
        /// Throw on the Nth write attempt (0-based) — simulates a peer that
        /// closed its read side mid-stream.
        var throwAtAttempt: Int?
        /// `isCancelled` returns true once `attempts >= cancelAtAttempt`.
        var cancelAtAttempt: Int?

        func sink() -> OpenAIChatStream.Sink {
            OpenAIChatStream.Sink(
                write: { [self] data in
                    lock.lock()
                    let attempt = attempts
                    attempts += 1
                    let shouldThrow = (throwAtAttempt == attempt)
                    lock.unlock()
                    if shouldThrow { throw SinkGone.gone }
                    lock.lock(); written.append(data); lock.unlock()
                },
                isCancelled: { [self] in
                    lock.lock(); defer { lock.unlock() }
                    if let c = cancelAtAttempt { return attempts >= c }
                    return false
                },
                close: { [self] in
                    lock.lock(); closes += 1; lock.unlock()
                }
            )
        }

        var writeCount: Int { lock.lock(); defer { lock.unlock() }; return written.count }
        var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    }

    private enum SinkGone: Error { case gone }

    // MARK: - 4. disconnect cancels in-flight generation < 100 ms

    @Test("a peer disconnect (write error) cancels the stream within 100 ms")
    func disconnectCancelsWithin100ms() {
        let rec = Recorder()
        rec.throwAtAttempt = 2   // head (0) ok, role event (1) ok, content (2) throws
        let events = OpenAIChatStream.events(
            id: "x", created: Self.fixedNow, model: Self.model, content: "a b c d e f g h"
        )

        let start = Date()
        let status = OpenAIChatStream.run(
            head: OpenAIChatStream.head(), events: events,
            done: OpenAIChatStream.doneSentinel(), sink: rec.sink()
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(status == .clientCancel)
        #expect(elapsed < 0.1)               // reaction bounded — no sleeps between chunks
        #expect(rec.writeCount == 2)         // only head + first event landed
        // The remaining content/DONE bytes were NOT written after disconnect.
        #expect(rec.writeCount < events.count + 2)
    }

    @Test("the pre-write cancellation flag also stops the stream")
    func cancellationFlagStops() {
        let rec = Recorder()
        rec.cancelAtAttempt = 1   // after the head write, isCancelled() flips true
        let events = OpenAIChatStream.events(
            id: "x", created: Self.fixedNow, model: Self.model, content: "one two three"
        )
        let status = OpenAIChatStream.run(
            head: OpenAIChatStream.head(), events: events,
            done: OpenAIChatStream.doneSentinel(), sink: rec.sink()
        )
        #expect(status == .clientCancel)
        #expect(rec.writeCount == 1)   // only the head landed
    }

    // MARK: - 5. no connection leak

    @Test("close is called exactly once — on completion and on cancel")
    func noConnectionLeak() {
        let events = OpenAIChatStream.events(
            id: "x", created: Self.fixedNow, model: Self.model, content: "hi there"
        )
        // Completion path.
        let okRec = Recorder()
        let okStatus = OpenAIChatStream.run(
            head: OpenAIChatStream.head(), events: events,
            done: OpenAIChatStream.doneSentinel(), sink: okRec.sink()
        )
        #expect(okStatus == .completed)
        #expect(okRec.closeCount == 1)

        // Cancel path.
        let cancelRec = Recorder()
        cancelRec.throwAtAttempt = 1
        let cancelStatus = OpenAIChatStream.run(
            head: OpenAIChatStream.head(), events: events,
            done: OpenAIChatStream.doneSentinel(), sink: cancelRec.sink()
        )
        #expect(cancelStatus == .clientCancel)
        #expect(cancelRec.closeCount == 1)
    }

    // MARK: - 6. rate-limit pre-flight contract (no half-open stream)

    @Test("a rate-limited request is refused with a framed 429 before any SSE byte")
    func rateLimitPreFlightContract() {
        // A key with a 1-request window: the second request crosses the
        // limit and the gate returns `rateLimited` — BEFORE the stream
        // surface (and thus before any `text/event-stream` byte) is reached.
        let key = "sk-senkani-ratelimit"
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: "quick", scope: ["chat"], rateLimit: 1,
            createdAt: Self.dateNow, expiresAt: nil, label: "rl"
        )
        let limiter = OpenAIRateLimiter()
        let header = "Bearer \(key)"

        let first = OpenAIAuthGate.decide(
            authorizationHeader: header, requestedSurface: "chat",
            now: Self.dateNow, records: [record], rateLimiter: limiter
        )
        guard case .ok = first else { Issue.record("first request should be admitted"); return }

        let second = OpenAIAuthGate.decide(
            authorizationHeader: header, requestedSurface: "chat",
            now: Self.dateNow, records: [record], rateLimiter: limiter
        )
        guard case .rateLimited(let retryAfter) = second else {
            Issue.record("second request should be rate-limited, got \(second)"); return
        }
        #expect(retryAfter > 0)

        // The refusal is a COMPLETE framed JSON response, not a stream.
        let framed = OpenAIAuthGate.errorResponse(for: second)
        let text = String(decoding: framed ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 429 Too Many Requests"))
        #expect(text.contains("Content-Type: application/json"))
        #expect(text.contains("Retry-After:"))
        #expect(!text.contains("text/event-stream"))   // never a half-open SSE
        #expect(text.contains("\"type\":\"rate_limit_error\""))
    }

    // MARK: - 7 & 8. single audit entry + status reflects completion vs cancel

    @Test("a completed stream records exactly one audit entry with status ok")
    func singleAuditEntryCompleted() {
        let chain = OpenAIAuditChain()
        let plan = Self.makePlan(chain: chain, content: "done streaming")
        let rec = Recorder()
        let status = OpenAIChatStream.run(plan: plan, sink: rec.sink())

        #expect(status == .completed)
        #expect(chain.count == 1)
        #expect(chain.entries[0].fields.status == "ok")
        #expect(chain.verify() == .ok(count: 1))
    }

    @Test("a client-cancelled stream records exactly one audit entry with status client_cancel")
    func singleAuditEntryCancelled() {
        let chain = OpenAIAuditChain()
        let plan = Self.makePlan(chain: chain, content: "interrupted stream of words")
        let rec = Recorder()
        rec.throwAtAttempt = 2   // disconnect mid-stream
        let status = OpenAIChatStream.run(plan: plan, sink: rec.sink())

        #expect(status == .clientCancel)
        #expect(chain.count == 1)                                   // still exactly one entry
        #expect(chain.entries[0].fields.status == "client_cancel")  // distinguishes cancel
        #expect(chain.verify() == .ok(count: 1))
    }

    // MARK: - V.13d-1 streaming tool_calls deltas

    private static let weatherArgs = #"{"location": "San Francisco", "unit": "celsius"}"#

    // 1. tool-call-delta-shape
    @Test("a tool-call completion streams OpenAI-shaped tool_calls deltas (id+name on first, arguments after)")
    func toolCallDeltaShape() throws {
        let call = OpenAIToolCall(
            id: "call_abc", function: .init(name: "get_weather", arguments: Self.weatherArgs)
        )
        let events = OpenAIChatStream.toolCallEvents(
            id: "chatcmpl-tc", created: Self.fixedNow, model: Self.model, toolCalls: [call]
        )
        // role + header + one fragment per splitter piece + terminal.
        let fragmentCount = OpenAIChatStream.splitForStreaming(Self.weatherArgs).count
        #expect(events.count == 3 + fragmentCount)

        // Every event is `data: {chat.completion.chunk}\n\n`.
        for ev in events {
            let s = String(decoding: ev, as: UTF8.self)
            #expect(s.hasPrefix("data: "))
            #expect(s.hasSuffix("\n\n"))
            #expect(Self.payload(ev).contains("\"object\":\"chat.completion.chunk\""))
        }

        // events[0]: the leading role chunk (no tool_calls yet).
        #expect(Self.payload(events[0]).contains("\"role\":\"assistant\""))
        #expect(Self.deltaToolCalls(events[0]) == nil)

        // events[1]: the header fragment — index + id + type + function.name
        // + empty arguments string.
        let header = try #require(Self.deltaToolCalls(events[1])?.first)
        #expect(header["index"] as? Int == 0)
        #expect(header["id"] as? String == "call_abc")
        #expect(header["type"] as? String == "function")
        let headerFn = try #require(header["function"] as? [String: Any])
        #expect(headerFn["name"] as? String == "get_weather")
        #expect(headerFn["arguments"] as? String == "")

        // events[2]: a continuation fragment — index + function.arguments,
        // but NOT id/type/name (those land only on the first fragment).
        let cont = try #require(Self.deltaToolCalls(events[2])?.first)
        #expect(cont["index"] as? Int == 0)
        #expect(cont["id"] == nil)
        #expect(cont["type"] == nil)
        let contFn = try #require(cont["function"] as? [String: Any])
        #expect(contFn["name"] == nil)
        #expect(contFn["arguments"] as? String != nil)
    }

    // 2. arguments-fragment-concatenation
    @Test("delta.tool_calls[].function.arguments fragments concatenate to the full JSON arguments string")
    func argumentsFragmentConcatenation() {
        let call = OpenAIToolCall(
            id: "call_1", function: .init(name: "get_weather", arguments: Self.weatherArgs)
        )
        let events = OpenAIChatStream.toolCallEvents(
            id: "x", created: Self.fixedNow, model: Self.model, toolCalls: [call]
        )
        let pieces = events
            .compactMap { Self.deltaToolCalls($0)?.first }
            .compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
        let reconstructed = pieces.joined()
        #expect(reconstructed == Self.weatherArgs)
        // …and the reconstruction is valid JSON.
        #expect((try? JSONSerialization.jsonObject(with: Data(reconstructed.utf8))) != nil)

        // Empty-arguments edge: the header's `arguments: ""` is the only
        // fragment; concatenation is the empty string.
        let emptyCall = OpenAIToolCall(id: "call_2", function: .init(name: "noop", arguments: ""))
        let emptyEvents = OpenAIChatStream.toolCallEvents(
            id: "y", created: Self.fixedNow, model: Self.model, toolCalls: [emptyCall]
        )
        let emptyPieces = emptyEvents
            .compactMap { Self.deltaToolCalls($0)?.first }
            .compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
        #expect(emptyPieces.joined() == "")

        // Compact `{}` arguments (the placeholder-engine shape) round-trips
        // as a single fragment.
        let compactCall = OpenAIToolCall(id: "call_3", function: .init(name: "ping", arguments: "{}"))
        let compactEvents = OpenAIChatStream.toolCallEvents(
            id: "z", created: Self.fixedNow, model: Self.model, toolCalls: [compactCall]
        )
        let compactPieces = compactEvents
            .compactMap { Self.deltaToolCalls($0)?.first }
            .compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String }
        #expect(compactPieces.joined() == "{}")
    }

    // 3. terminal-finish-reason
    @Test("the terminal tool-call chunk carries finish_reason tool_calls; non-terminal chunks carry null")
    func terminalFinishReasonToolCalls() {
        let call = OpenAIToolCall(id: "call_1", function: .init(name: "f", arguments: "{}"))
        let events = OpenAIChatStream.toolCallEvents(
            id: "x", created: Self.fixedNow, model: Self.model, toolCalls: [call]
        )
        // Final chunk: empty delta + finish_reason "tool_calls".
        let last = Self.payload(events[events.count - 1])
        #expect(last.contains("\"delta\":{}"))
        #expect(last.contains("\"finish_reason\":\"tool_calls\""))

        // Every non-terminal chunk carries an explicit `null` finish_reason.
        for ev in events.dropLast() {
            #expect(Self.payload(ev).contains("\"finish_reason\":null"))
        }

        // The `[DONE]` sentinel is unchanged and follows (sent by `run`).
        #expect(String(decoding: OpenAIChatStream.doneSentinel(), as: UTF8.self) == "data: [DONE]\n\n")
    }

    // 4. no-tools-scope-403-stream
    @Test("a streaming tool-use request from a key WITHOUT tools scope → 403 insufficient_scope, no SSE bytes")
    func noToolsScope403Stream() throws {
        let tool = ChatCompletionRequest.Tool(function: .init(name: "get_weather"))
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather?")],
            stream: true, tools: [tool]
        )
        // The streamHandler funnels a `stream: true` tool-use request through
        // the SAME `toolsPreflightError` as the non-streaming path; an
        // out-of-scope key yields a framed 403 that the listener returns
        // BEFORE opening a stream (the plan is nil → no SSE head is written).
        let preflight = try #require(
            OpenAIChatHandler.toolsPreflightError(request: request, scope: ["chat", "embeddings"])
        )
        let text = String(decoding: preflight, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(text.contains("\"code\":\"insufficient_scope\""))
        #expect(!text.contains("text/event-stream"))   // never a half-open SSE

        // An in-scope key passes pre-flight → the stream emits tool_calls deltas.
        #expect(OpenAIChatHandler.toolsPreflightError(request: request, scope: ["chat", "tools"]) == nil)
    }

    // 5. single-audit-entry
    @Test("a streamed tool-use request lands exactly one audit-chain entry with status ok")
    func singleAuditEntryToolCallStream() {
        let chain = OpenAIAuditChain()
        let plan = Self.makeToolCallPlan(chain: chain)
        let rec = Recorder()
        let status = OpenAIChatStream.run(plan: plan, sink: rec.sink())

        #expect(status == .completed)
        #expect(chain.count == 1)
        #expect(chain.entries[0].fields.status == "ok")
        #expect(chain.verify() == .ok(count: 1))
    }

    // 6. no-parallel-streaming-stack
    @Test("tool-call streaming reuses the v13b Chunk + run + splitter machinery (no parallel stack)")
    func noParallelStreamingStack() {
        let call = OpenAIToolCall(id: "call_1", function: .init(name: "f", arguments: "{}"))
        let events = OpenAIChatStream.toolCallEvents(
            id: "x", created: Self.fixedNow, model: Self.model, toolCalls: [call]
        )
        // Same `chat.completion.chunk` object type as the content path — the
        // tool-call deltas are NOT a forked event shape.
        for ev in events {
            #expect(Self.payload(ev).contains("\"object\":\"chat.completion.chunk\""))
        }
        // The identical `run` drive + `Sink` contract handles a tool-call
        // event list: completion returns `.completed` and `close` fires once.
        let rec = Recorder()
        let status = OpenAIChatStream.run(
            head: OpenAIChatStream.head(), events: events,
            done: OpenAIChatStream.doneSentinel(), sink: rec.sink()
        )
        #expect(status == .completed)
        #expect(rec.closeCount == 1)
        // The same `splitForStreaming` splitter underlies both content and
        // arguments fragmentation.
        #expect(OpenAIChatStream.splitForStreaming("a b").joined() == "a b")
    }

    // MARK: - live listener SSE round-trip (Network)

    #if canImport(Network)
    @Test("live listener streams an SSE chat.completion for an authorized POST")
    func liveStreamRoundTrip() throws {
        let key = "sk-senkani-livestream"
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: "quick", scope: ["chat"], rateLimit: 60,
            createdAt: Self.dateNow, expiresAt: nil, label: "live"
        )
        let limiter = OpenAIRateLimiter()
        let authenticator = OpenAIListener.Authenticator { _, path, headers in
            OpenAIAuthGate.decide(
                authorizationHeader: headers["authorization"],
                requestedSurface: OpenAIAuthGate.surface(forPath: path),
                now: Date(), records: [record], rateLimiter: limiter
            )
        }
        let chain = OpenAIAuditChain()
        let engine = OpenAIChatHandler.Engine { _, _, _ in
            OpenAIChatHandler.Completion(content: "live stream ok", promptTokens: 5, completionTokens: 3)
        }
        let streamHandler = OpenAIListener.StreamHandler { _, _, headers, body in
            guard let request = OpenAIChatHandler.decodeRequest(body), request.stream == true else { return nil }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let rec = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: [record]) }
            let result = OpenAIChatHandler.handle(
                request: request, recordPreset: rec?.preset ?? "auto",
                keyLabel: rec?.label, engine: engine, now: Date(), id: "chatcmpl-livestream"
            )
            let resp = result.response
            let content = resp.choices.first.flatMap { $0.message.content } ?? ""
            let base = result.auditFields
            return OpenAIChatStream.Plan(
                head: OpenAIChatStream.head(),
                events: OpenAIChatStream.events(id: resp.id, created: resp.created, model: resp.model, content: content),
                done: OpenAIChatStream.doneSentinel(),
                onFinish: { status in
                    let fields = OpenAIAuditChain.AuditFields(
                        ts: base.ts, keyLabel: base.keyLabel, surface: base.surface,
                        modelLogged: base.modelLogged, presetUsed: base.presetUsed,
                        resolvedTier: base.resolvedTier,
                        promptTokenCount: base.promptTokenCount,
                        completionTokenCount: base.completionTokenCount,
                        status: status.auditStatus
                    )
                    chain.append(fields, bodies: nil)
                }
            )
        }

        let listener = OpenAIListener(
            config: .init(bind: "127.0.0.1", port: 0),
            authenticator: authenticator, chatHandler: nil, streamHandler: streamHandler
        )
        try listener.start()
        defer { listener.stop() }
        let port = listener.port
        #expect(port > 0)

        let bodyJSON = #"{"model":"gpt-4o","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        let requestText =
            "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(key)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(bodyJSON.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(bodyJSON)"
        let request = Data(requestText.utf8)
        let fd = try #require(connectToLocalhost(port: port))
        defer { close(fd) }
        #expect(writeAllToFD(fd, request))
        shutdown(fd, Int32(SHUT_WR))
        let response = String(decoding: readAllUntilEOF(fd), as: UTF8.self)

        // SSE head, not a JSON-framed body.
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("Content-Type: text/event-stream"))
        #expect(!response.contains("Content-Length:"))
        // Chunk shape + delta content + terminal sentinel.
        #expect(response.contains("\"object\":\"chat.completion.chunk\""))
        #expect(response.contains("\"role\":\"assistant\""))
        #expect(response.contains("data: [DONE]"))
        // Response model is the actual (Quick→Haiku) model, not gpt-4o.
        #expect(response.contains(ModelTier.quick.claudeModelValue))
        #expect(!response.contains("\"model\":\"gpt-4o\""))
        // Exactly one audit entry (status ok), and it verifies. onFinish
        // fires before the connection closes, so it is recorded by EOF.
        #expect(chain.count == 1)
        #expect(chain.entries[0].fields.status == "ok")
        #expect(chain.verify() == .ok(count: 1))
    }
    #endif

    // MARK: - helpers

    private static let dateNow = Date(timeIntervalSince1970: TimeInterval(fixedNow))

    /// Build a stream plan whose `onFinish` appends one entry to `chain`.
    private static func makePlan(chain: OpenAIAuditChain, content: String) -> OpenAIChatStream.Plan {
        let request = ChatCompletionRequest(model: "gpt-4o", messages: [.init(role: "user", content: "hi")])
        let engine = OpenAIChatHandler.Engine { _, _, _ in
            OpenAIChatHandler.Completion(content: content, promptTokens: 6, completionTokens: 4)
        }
        let result = OpenAIChatHandler.handle(
            request: request, recordPreset: "quick", keyLabel: "ci",
            engine: engine, now: dateNow, id: "chatcmpl-plan"
        )
        let resp = result.response
        let base = result.auditFields
        return OpenAIChatStream.Plan(
            head: OpenAIChatStream.head(),
            events: OpenAIChatStream.events(id: resp.id, created: resp.created, model: resp.model, content: content),
            done: OpenAIChatStream.doneSentinel(),
            onFinish: { status in
                let fields = OpenAIAuditChain.AuditFields(
                    ts: base.ts, keyLabel: base.keyLabel, surface: base.surface,
                    modelLogged: base.modelLogged, presetUsed: base.presetUsed,
                    resolvedTier: base.resolvedTier,
                    promptTokenCount: base.promptTokenCount,
                    completionTokenCount: base.completionTokenCount,
                    status: status.auditStatus
                )
                chain.append(fields, bodies: nil)
            }
        )
    }

    /// V.13d-1 — build a tool-call stream plan whose events are
    /// `toolCallEvents` and whose `onFinish` appends one entry to `chain`.
    /// Mirrors the live `ServeCommand` wiring: `handle()` resolves the
    /// tool-call completion, the plan streams its `tool_calls` deltas, and
    /// the single audit entry is recorded in `onFinish`.
    private static func makeToolCallPlan(chain: OpenAIAuditChain) -> OpenAIChatStream.Plan {
        let tool = ChatCompletionRequest.Tool(function: .init(name: "get_weather"))
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather?")],
            stream: true, tools: [tool]
        )
        let engine = OpenAIChatHandler.Engine { _, _, tools in
            let call = OpenAIToolCall(
                id: "call_x",
                function: .init(name: tools.first?.function.name ?? "f", arguments: #"{"location":"SF"}"#)
            )
            return OpenAIChatHandler.Completion(
                content: "", toolCalls: [call], promptTokens: 6, completionTokens: 4
            )
        }
        let result = OpenAIChatHandler.handle(
            request: request, recordPreset: "quick", keyLabel: "ci",
            engine: engine, now: dateNow, id: "chatcmpl-tcplan"
        )
        let resp = result.response
        let base = result.auditFields
        let toolCalls = resp.choices.first?.message.toolCalls ?? []
        return OpenAIChatStream.Plan(
            head: OpenAIChatStream.head(),
            events: OpenAIChatStream.toolCallEvents(
                id: resp.id, created: resp.created, model: resp.model, toolCalls: toolCalls
            ),
            done: OpenAIChatStream.doneSentinel(),
            onFinish: { status in
                let fields = OpenAIAuditChain.AuditFields(
                    ts: base.ts, keyLabel: base.keyLabel, surface: base.surface,
                    modelLogged: base.modelLogged, presetUsed: base.presetUsed,
                    resolvedTier: base.resolvedTier,
                    promptTokenCount: base.promptTokenCount,
                    completionTokenCount: base.completionTokenCount,
                    status: status.auditStatus
                )
                chain.append(fields, bodies: nil)
            }
        )
    }
}
