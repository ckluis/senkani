import Testing
import Foundation
@testable import Core

// V.13b-2 — URLProtocol-stubbed tests for `ClaudeAPIChatEngine`. Reuses
// `MockURLProtocol` from `RemoteRepoClientTests.swift` (internal to the
// test target). Every suite carries `.urlProtocolGate + .serialized` so
// the process-global stub registry doesn't race across suites — see
// `Tests/SenkaniTests/MockURLProtocolGate.swift`.

private func makeEngine(apiKey: String = "test-anthropic-key-XYZ") -> (ClaudeAPIChatEngine, URLSession) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    // V.13b-2b: inject an instant no-op sleeper so any 429/529 path (which
    // now retries) stays fast in the suite; non-retryable tests never sleep.
    let engine = ClaudeAPIChatEngine(apiKey: apiKey, session: session, endpoint: url, sleeper: { _ in })
    return (engine, session)
}

private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

/// URLSession copies `httpBody` to `httpBodyStream` before handing the
/// request off to a `URLProtocol`. So on the recording side
/// (`MockURLProtocol.lastRequest`) `httpBody` is nil and the bytes live
/// behind `httpBodyStream`. This helper drains either path.
private func recordedBody() -> String {
    guard let req = MockURLProtocol.lastRequest else { return "" }
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
}

@Suite("ClaudeAPIChatEngine — accept-list + wire client", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineWireTests {

    @Test func acceptListRejectsUnknownModelWithoutAnyNetworkCall() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let (engine, _) = makeEngine()
        var caught: Error?
        do {
            _ = try await engine.chat(model: "claude-fake-1", messages: [
                .init(role: "user", content: "hi")
            ], tools: [])
            Issue.record("expected upstreamModelUnavailable")
        } catch {
            caught = error
        }
        // The pre-network gate must throw before any URLSession traffic.
        #expect(MockURLProtocol.lastRequest == nil, "accept-list miss must not hit the wire")
        #expect((caught as? ClaudeAPIChatEngineError) == .upstreamModelUnavailable(model: "claude-fake-1"))
    }

    @Test func quickTierRoundTripMapsAnthropicToCompletion() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"hello from haiku"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":5}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))

        let (engine, _) = makeEngine(apiKey: "ak-haiku")
        let completion = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "ping")],
            tools: []
        )

        #expect(completion.content == "hello from haiku")
        #expect(completion.toolCalls.isEmpty)
        #expect(completion.realPromptTokens == 12)
        #expect(completion.realCompletionTokens == 5)

        // Headers + body envelope assertions
        let req = MockURLProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "x-api-key") == "ak-haiku")
        #expect(req?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req?.value(forHTTPHeaderField: "content-type") == "application/json")
        let asString = recordedBody()
        #expect(asString.contains("\"stream\":false"))
        // Wire-ID translation: senkani shortname → canonical Anthropic ID.
        #expect(asString.contains("\"model\":\"claude-3-5-haiku-latest\""))
    }

    @Test func balancedTierConcatenatesMultiBlockText() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"A"},{"type":"text","text":"B"}],"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":2}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))
        let (engine, _) = makeEngine()
        let completion = try await engine.chat(
            model: "claude-sonnet-4",
            messages: [.init(role: "user", content: "two")],
            tools: []
        )
        #expect(completion.content == "AB")

        let asString = recordedBody()
        #expect(asString.contains("\"model\":\"claude-sonnet-4-0\""))
    }

    @Test func frontierUpstreamErrorOmitsBody() async throws {
        // V.13b-2b: 529 is now RETRYABLE (exhausts to `.rateLimited`), so
        // the single-shot info-leak guard moved to a NON-retryable 400 —
        // `.upstreamError` still carries a parsed `type` AND a discarded
        // body, keeping the meaningful "body must not leak" assertion on a
        // status that fires exactly once. The 529→exhaustion no-leak path
        // is covered separately in `ClaudeAPIChatEngineRetryTests`.
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"type":"error","error":{"type":"invalid_request_error","message":"DETAILED ANTHROPIC MESSAGE WITH PROMPT BLEED"}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 400, body: Data(body.utf8))
        let (engine, _) = makeEngine()

        var caught: ClaudeAPIChatEngineError?
        do {
            _ = try await engine.chat(
                model: "claude-opus-4",
                messages: [.init(role: "user", content: "x")],
                tools: []
            )
            Issue.record("expected upstreamError")
        } catch let e as ClaudeAPIChatEngineError {
            caught = e
        }
        #expect(caught == .upstreamError(status: 400, type: "invalid_request_error"))

        // Info-leak guard: the error's debug rendering must NOT carry the
        // upstream message body. We render the error via String(describing:)
        // — the worst-case API consumer rendering — and assert the leaked
        // string is absent.
        let rendered = String(describing: caught!)
        #expect(!rendered.contains("DETAILED ANTHROPIC MESSAGE"), "upstream body must not leak via error description")
        #expect(!rendered.contains("PROMPT BLEED"))

        // Wire-ID translation for opus tier.
        #expect(recordedBody().contains("\"model\":\"claude-opus-4-0\""))
    }

    @Test func upstreamErrorWithUnparseableBodySurfacesNilType() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(url: anthropicURL, status: 500, body: Data("totally not json".utf8))
        let (engine, _) = makeEngine()
        do {
            _ = try await engine.chat(
                model: "claude-opus-4",
                messages: [.init(role: "user", content: "x")],
                tools: []
            )
            Issue.record("expected upstreamError")
        } catch let e as ClaudeAPIChatEngineError {
            #expect(e == .upstreamError(status: 500, type: nil))
        }
    }

    @Test func maxTokensTruncationAppendsVisibleSentinel() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"msg_03","type":"message","role":"assistant","content":[{"type":"text","text":"partial output here..."}],"stop_reason":"max_tokens","usage":{"input_tokens":3,"output_tokens":4096}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))
        let (engine, _) = makeEngine()
        let completion = try await engine.chat(
            model: "claude-sonnet-4",
            messages: [.init(role: "user", content: "long")],
            tools: []
        )
        #expect(completion.content == "partial output here...\n\n[truncated: max_tokens reached]")
    }

}

@Suite("ClaudeAPIChatEngine — request shape mapping", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineMappingTests {

    @Test func systemMessageSplitOutAndJoined() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))

        let (engine, _) = makeEngine()
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "be concise"),
                .init(role: "system", content: "be honest"),
                .init(role: "user",   content: "hi"),
            ],
            tools: []
        )
        let asString = recordedBody()
        #expect(asString.contains("\"system\":\"be concise\\n\\nbe honest\""))
        // role:"system" entries must NOT appear in messages[].
        #expect(!asString.contains("\"role\":\"system\""))
    }

    @Test func toolUseResponseMapsToOpenAIToolCalls() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SF"}}],"stop_reason":"tool_use","usage":{"input_tokens":4,"output_tokens":7}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))
        let (engine, _) = makeEngine()
        let completion = try await engine.chat(
            model: "claude-sonnet-4",
            messages: [.init(role: "user", content: "weather?")],
            tools: []
        )
        #expect(completion.content == "")
        #expect(completion.toolCalls.count == 1)
        #expect(completion.toolCalls[0].id == "toolu_1")
        #expect(completion.toolCalls[0].function.name == "get_weather")
        // arguments is a JSON-encoded string with sorted keys.
        #expect(completion.toolCalls[0].function.arguments == "{\"city\":\"SF\"}")
    }

    @Test func assistantMixedContentAndToolCallsPreservesText() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))

        // Simulate an OpenAI follow-up turn where the assistant's PRIOR
        // turn carried BOTH content text AND a tool_call. Both must
        // survive to Anthropic's `content:` array (text block + tool_use
        // block) — dropping the text would corrupt multi-turn fidelity.
        let priorToolCall = OpenAIToolCall(
            id: "toolu_prev",
            type: "function",
            function: .init(name: "get_time", arguments: "{\"tz\":\"UTC\"}")
        )
        let messages: [ChatCompletionRequest.Message] = [
            .init(role: "user", content: "what time is it?"),
            .init(role: "assistant", content: "Let me check.", toolCalls: [priorToolCall]),
            .init(role: "tool", content: "12:00", toolCallId: "toolu_prev"),
        ]
        let (engine, _) = makeEngine()
        _ = try await engine.chat(model: "claude-opus-4", messages: messages, tools: [])

        let asString = recordedBody()
        // Assistant block array contains BOTH the text and the tool_use.
        #expect(asString.contains("\"text\":\"Let me check.\""))
        #expect(asString.contains("\"type\":\"tool_use\""))
        #expect(asString.contains("\"name\":\"get_time\""))
        // Tool follow-up encoded as a user message carrying tool_result.
        #expect(asString.contains("\"type\":\"tool_result\""))
        #expect(asString.contains("\"tool_use_id\":\"toolu_prev\""))
    }

    @Test func toolsDeclarationMappedToAnthropicInputSchema() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))

        let tool = ChatCompletionRequest.Tool(
            function: .init(
                name: "lookup",
                description: "lookup a value",
                parameters: .object(["type": .string("object")])
            )
        )
        let (engine, _) = makeEngine()
        _ = try await engine.chat(
            model: "claude-sonnet-4",
            messages: [.init(role: "user", content: "go")],
            tools: [tool]
        )
        let asString = recordedBody()
        // The Anthropic shape uses `input_schema`, not `parameters`.
        #expect(asString.contains("\"input_schema\":{\"type\":\"object\"}"))
        #expect(asString.contains("\"name\":\"lookup\""))
        // The OpenAI `function` wrapper key must NOT appear in the wire body.
        #expect(!asString.contains("\"function\":{\"name\":\"lookup\""))
    }
}

@Suite("ClaudeAPIChatEngine — re-audit fixes (Kleppmann)", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineReauditFixesTests {

    @Test func unknownResponseBlockTypeIsSkippedNotFailed() async throws {
        // Forward-compat: Anthropic adds a new block type the client
        // doesn't know about (e.g. `thinking`, `server_tool_use`). The
        // valid sibling `text` block must still flow through; the unknown
        // block is skipped, not a decode-throw.
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"hidden cot"},{"type":"text","text":"visible answer"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))
        let (engine, _) = makeEngine()
        let completion = try await engine.chat(
            model: "claude-sonnet-4",
            messages: [.init(role: "user", content: "hi")],
            tools: []
        )
        #expect(completion.content == "visible answer")
        #expect(completion.toolCalls.isEmpty)
    }

    @Test func consecutiveToolFollowUpsCoalesceIntoOneUserMessage() async throws {
        // Parallel tool-use convention: when the assistant emitted two
        // tool_use blocks in one turn, the OpenAI follow-up is two
        // role:"tool" messages — Anthropic expects those collapsed into
        // ONE user message with two tool_result blocks.
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))

        let priorCallA = OpenAIToolCall(id: "toolu_a", type: "function",
                                        function: .init(name: "f", arguments: "{}"))
        let priorCallB = OpenAIToolCall(id: "toolu_b", type: "function",
                                        function: .init(name: "g", arguments: "{}"))
        let messages: [ChatCompletionRequest.Message] = [
            .init(role: "user", content: "do two things"),
            .init(role: "assistant", content: "", toolCalls: [priorCallA, priorCallB]),
            .init(role: "tool", content: "result-A", toolCallId: "toolu_a"),
            .init(role: "tool", content: "result-B", toolCallId: "toolu_b"),
        ]
        let (engine, _) = makeEngine()
        _ = try await engine.chat(model: "claude-opus-4", messages: messages, tools: [])

        let asString = recordedBody()
        // Decode the body and assert the tool_result follow-ups landed in
        // a SINGLE user message containing TWO tool_result blocks.
        struct Req: Decodable {
            struct Msg: Decodable { let role: String; let content: JSONValue }
            let messages: [Msg]
        }
        let decoded = try JSONDecoder().decode(Req.self, from: Data(asString.utf8))
        // Locate the final messages: [..., assistant(tool_use), user(tool_results)]
        let userToolMsgs = decoded.messages.filter { $0.role == "user" }
        // First user message is the original prompt; the LAST user message
        // is the coalesced tool_result carrier.
        guard let lastUser = userToolMsgs.last, case .array(let blocks) = lastUser.content else {
            Issue.record("expected coalesced last user message with block array"); return
        }
        #expect(blocks.count == 2, "two tool_result blocks should coalesce into ONE user message")
        for block in blocks {
            guard case .object(let kv) = block, case .string(let t) = kv["type"] ?? .null else {
                Issue.record("expected each block to be object with type field"); continue
            }
            #expect(t == "tool_result")
        }
    }

    @Test func toolFollowUpMissingToolCallIdThrowsLocalDecodeError() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let (engine, _) = makeEngine()
        do {
            _ = try await engine.chat(
                model: "claude-haiku-3.5",
                messages: [
                    .init(role: "user", content: "hi"),
                    .init(role: "tool", content: "result", toolCallId: nil),
                ],
                tools: []
            )
            Issue.record("expected decodeError missing-tool-call-id")
        } catch let e as ClaudeAPIChatEngineError {
            #expect(e == .decodeError(reason: "missing-tool-call-id"))
        }
        // Local-throw must happen BEFORE any wire egress.
        #expect(MockURLProtocol.lastRequest == nil)
    }

    @Test func toolFollowUpEmptyToolCallIdAlsoRejectsLocally() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let (engine, _) = makeEngine()
        do {
            _ = try await engine.chat(
                model: "claude-haiku-3.5",
                messages: [
                    .init(role: "user", content: "hi"),
                    .init(role: "tool", content: "result", toolCallId: ""),
                ],
                tools: []
            )
            Issue.record("expected decodeError missing-tool-call-id")
        } catch let e as ClaudeAPIChatEngineError {
            #expect(e == .decodeError(reason: "missing-tool-call-id"))
        }
        #expect(MockURLProtocol.lastRequest == nil)
    }
}

@Suite("ClaudeAPIChatEngine — network error narrowing", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineNetworkErrorTests {

    /// A URLProtocol stub that fails the load with a chosen URLError.
    final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var failureCode: URLError.Code = .notConnectedToInternet
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(Self.failureCode))
        }
        override func stopLoading() {}
    }

    @Test func urlSessionFailureMapsToNetworkErrorCarryingOnlyCode() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak",
            session: session,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!
        )
        FailingURLProtocol.failureCode = .notConnectedToInternet

        do {
            _ = try await engine.chat(
                model: "claude-haiku-3.5",
                messages: [.init(role: "user", content: "hi")],
                tools: []
            )
            Issue.record("expected networkError")
        } catch let e as ClaudeAPIChatEngineError {
            #expect(e == .networkError(code: URLError.notConnectedToInternet.rawValue))
            // Defensive: the rendered error must NOT carry "Authorization"
            // / "x-api-key" / the api key value via undocumented userInfo.
            let rendered = String(describing: e)
            #expect(!rendered.contains("x-api-key"))
            #expect(!rendered.contains("api.anthropic.com"))
        }
    }
}

// MARK: - V.13b-2b — retry / backoff / rate-limit translation

/// Records each backoff `Duration` the engine asks to sleep. Thread-safe:
/// the sleeper closure runs in the engine's async context (may hop threads)
/// while assertions read `delays`/`total` after `chat()` returns.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []
    func record(_ d: Duration) { lock.lock(); storage.append(d); lock.unlock() }
    var delays: [Duration] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { delays.count }
    var total: Duration { delays.reduce(.zero, +) }
}

/// Thread-safe holder so a sleeper closure can cancel its own hosting task.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Error>?
    var task: Task<Void, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set { lock.lock(); _task = newValue; lock.unlock() }
    }
}

/// A `URLProtocol` that returns a SCRIPTED sequence of responses (the
/// `MockURLProtocol` returns one stub per URL — no sequencing). The last
/// frame repeats for any request beyond the script, so "429 indefinitely"
/// is a single 429 frame. All shared state is `NSLock`-guarded because
/// `startLoading` runs on URLSession's loader thread while the test thread
/// reads `requestCount`; assertions read it only AFTER `chat()` returns
/// (the `await` is a full barrier for the loader work).
final class RateLimitSequenceProtocol: URLProtocol, @unchecked Sendable {
    struct Frame: Sendable { let status: Int; let headers: [String: String]; let body: Data }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [Frame] = []
    nonisolated(unsafe) private static var index = 0
    nonisolated(unsafe) private static var requestCountStorage = 0

    static func configure(_ frames: [Frame]) {
        lock.lock(); defer { lock.unlock() }
        script = frames; index = 0; requestCountStorage = 0
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        script = []; index = 0; requestCountStorage = 0
    }
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCountStorage
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let frame: Frame = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.requestCountStorage += 1
            guard !Self.script.isEmpty else {
                return Frame(status: 500, headers: [:], body: Data())
            }
            let i = min(Self.index, Self.script.count - 1)
            Self.index += 1
            return Self.script[i]
        }()
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: frame.status,
            httpVersion: "HTTP/1.1", headerFields: frame.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: frame.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeSeqEngine(
    policy: ClaudeAPIChatEngine.RetryPolicy = .default,
    sleeper: @escaping @Sendable (Duration) async throws -> Void
) -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RateLimitSequenceProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: "ak", session: session, endpoint: anthropicURL,
        retryPolicy: policy, sleeper: sleeper)
}

@Suite("ClaudeAPIChatEngine — retry / backoff (V.13b-2b)", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineRetryTests {

    // Acceptance Test A: 429 + Retry-After:1 twice, then 200 → succeeds.
    @Test func rateLimit429TwiceThenSucceedsAfterBackoff() async throws {
        RateLimitSequenceProtocol.reset(); defer { RateLimitSequenceProtocol.reset() }
        let ok = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"recovered"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        RateLimitSequenceProtocol.configure([
            .init(status: 429, headers: ["Retry-After": "1"], body: Data("{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}".utf8)),
            .init(status: 429, headers: ["Retry-After": "1"], body: Data()),
            .init(status: 200, headers: [:], body: Data(ok.utf8)),
        ])
        let rec = SleepRecorder()
        let engine = makeSeqEngine(sleeper: { rec.record($0) })
        let completion = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "hi")],
            tools: [])
        #expect(completion.content == "recovered")
        #expect(RateLimitSequenceProtocol.requestCount == 3)   // 1 initial + 2 retries
        #expect(rec.count == 2)                                 // 2 backoff sleeps
        #expect(rec.delays == [.seconds(1), .seconds(1)])       // honored Retry-After:1
    }

    // Acceptance Test B: 429 indefinitely → exhaustion. Asserts retry count,
    // total-wait cap, OpenAI-shaped translation, and the info-leak guard.
    @Test func rateLimitExhaustionThrowsRateLimitedWithCountCapAndNoLeak() async throws {
        RateLimitSequenceProtocol.reset(); defer { RateLimitSequenceProtocol.reset() }
        // Body carries a sentinel that must NOT surface via the error.
        let body = Data("{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"PROMPT BLEED SECRET\"}}".utf8)
        RateLimitSequenceProtocol.configure([.init(status: 429, headers: ["Retry-After": "2"], body: body)])
        let rec = SleepRecorder()
        let engine = makeSeqEngine(sleeper: { rec.record($0) })

        var caught: ClaudeAPIChatEngineError?
        do {
            _ = try await engine.chat(model: "claude-opus-4", messages: [.init(role: "user", content: "x")], tools: [])
            Issue.record("expected rateLimited")
        } catch let e as ClaudeAPIChatEngineError { caught = e }

        guard case .rateLimited(let ra) = caught else { Issue.record("expected .rateLimited, got \(String(describing: caught))"); return }
        #expect(ra == 2)
        #expect(RateLimitSequenceProtocol.requestCount == 4)   // 1 initial + 3 retries
        #expect(rec.count == 3)                                 // 3 sleeps
        #expect(rec.total <= .seconds(30))                      // wall-clock cap honored
        #expect(rec.total == .seconds(6))                       // 2+2+2

        // Info-leak guard on the exhaustion path: no upstream body echo.
        let rendered = String(describing: caught!)
        #expect(!rendered.contains("PROMPT BLEED"))

        // OpenAI-shaped rate_limit translation.
        let resp = String(data: ClaudeAPIChatEngine.openAIRateLimitResponse(retryAfter: ra), encoding: .utf8)!
        #expect(resp.hasPrefix("HTTP/1.1 429 Too Many Requests"))
        #expect(resp.contains("\"type\":\"rate_limit_error\""))
        #expect(resp.contains("\"code\":\"rate_limit_exceeded\""))
        #expect(resp.contains("Retry-After: 2"))
    }

    // Schneier: a hostile huge Retry-After is clamped to the wall budget and
    // exhausts via the budget branch (not just the retry-count branch).
    @Test func hostileRetryAfterClampedToCapExhaustsBudget() async throws {
        RateLimitSequenceProtocol.reset(); defer { RateLimitSequenceProtocol.reset() }
        RateLimitSequenceProtocol.configure([.init(status: 429, headers: ["Retry-After": "100000"], body: Data())])
        let rec = SleepRecorder()
        let engine = makeSeqEngine(policy: .default, sleeper: { rec.record($0) })

        var caught: ClaudeAPIChatEngineError?
        do { _ = try await engine.chat(model: "claude-sonnet-4", messages: [.init(role: "user", content: "x")], tools: []) }
        catch let e as ClaudeAPIChatEngineError { caught = e }

        guard case .rateLimited(let ra) = caught else { Issue.record("expected .rateLimited, got \(String(describing: caught))"); return }
        #expect(ra == 30)                                       // clamped to the 30s cap
        #expect(RateLimitSequenceProtocol.requestCount == 2)    // 1 fire, 30s sleep, 1 fire, budget=0 → throw
        #expect(rec.count == 1)                                 // single clamped sleep
        #expect(rec.total == .seconds(30))                      // exactly the cap, never over
    }

    // 529 (overloaded) is retryable; no Retry-After → full-jittered
    // exponential under the serveSafe 8s cap. Upper-bound assertions
    // tolerate the jitter (which only ever reduces the delay).
    @Test func overloaded529JitteredExponentialUnderServeSafeCap() async throws {
        RateLimitSequenceProtocol.reset(); defer { RateLimitSequenceProtocol.reset() }
        RateLimitSequenceProtocol.configure([.init(status: 529, headers: [:],
            body: Data("{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}".utf8))])
        let rec = SleepRecorder()
        let engine = makeSeqEngine(policy: .serveSafe, sleeper: { rec.record($0) })

        var caught: ClaudeAPIChatEngineError?
        do { _ = try await engine.chat(model: "claude-opus-4", messages: [.init(role: "user", content: "x")], tools: []) }
        catch let e as ClaudeAPIChatEngineError { caught = e }

        guard case .rateLimited(let ra) = caught else { Issue.record("expected .rateLimited, got \(String(describing: caught))"); return }
        #expect(ra == nil)                                      // no Retry-After present
        #expect(RateLimitSequenceProtocol.requestCount == 4)    // 1 initial + 3 retries
        #expect(rec.count == 3)
        #expect(rec.total <= .seconds(8))                       // jittered 1+2+4 ladder under cap
        for d in rec.delays { #expect(d >= .zero) }
    }

    // Cancellation mid-backoff propagates CancellationError (NOT a
    // ClaudeAPIChatEngineError) and fires no further upstream request —
    // sleeper-throws entry point.
    @Test func cancelledDuringBackoffStopsWithoutAnotherRequest() async throws {
        RateLimitSequenceProtocol.reset(); defer { RateLimitSequenceProtocol.reset() }
        RateLimitSequenceProtocol.configure([.init(status: 429, headers: ["Retry-After": "1"], body: Data())])
        let engine = makeSeqEngine(sleeper: { _ in throw CancellationError() })

        var cancelled = false
        do {
            _ = try await engine.chat(model: "claude-haiku-3.5", messages: [.init(role: "user", content: "x")], tools: [])
            Issue.record("expected cancellation")
        } catch is CancellationError {
            cancelled = true
        } catch let e as ClaudeAPIChatEngineError {
            Issue.record("cancellation must NOT surface as ClaudeAPIChatEngineError: \(e)")
        }
        #expect(cancelled)
        #expect(RateLimitSequenceProtocol.requestCount == 1)    // only the initial fire
    }

    // Exercises the REAL `Task.checkCancellation()` guard at the loop top
    // (distinct from the sleeper-throws path): the sleeper returns NORMALLY
    // but cancels the hosting task, so the NEXT iteration's checkCancellation
    // fires before another upstream request.
    @Test func cancelledViaCheckCancellationGuardStopsLoop() async {
        RateLimitSequenceProtocol.reset(); defer { RateLimitSequenceProtocol.reset() }
        RateLimitSequenceProtocol.configure([.init(status: 429, headers: ["Retry-After": "1"], body: Data())])
        let box = TaskBox()
        let engine = makeSeqEngine(sleeper: { _ in box.task?.cancel() })   // returns normally; cancels host
        box.task = Task {
            _ = try await engine.chat(model: "claude-haiku-3.5", messages: [.init(role: "user", content: "x")], tools: [])
        }
        var cancelled = false
        do { try await box.task!.value }
        catch is CancellationError { cancelled = true }
        catch { Issue.record("expected CancellationError, got \(error)") }
        #expect(cancelled)
        #expect(RateLimitSequenceProtocol.requestCount == 1)    // checkCancellation fired before fire #2
    }

    // Direct translator shape + header, decoupled from chat().
    @Test func openAIRateLimitResponseShapeAndHeader() {
        let withHint = String(data: ClaudeAPIChatEngine.openAIRateLimitResponse(retryAfter: 5), encoding: .utf8)!
        #expect(withHint.hasPrefix("HTTP/1.1 429 Too Many Requests"))
        #expect(withHint.contains("\"type\":\"rate_limit_error\""))
        #expect(withHint.contains("\"code\":\"rate_limit_exceeded\""))
        #expect(withHint.contains("Retry-After: 5"))
        let noHint = String(data: ClaudeAPIChatEngine.openAIRateLimitResponse(retryAfter: nil), encoding: .utf8)!
        #expect(!noHint.contains("Retry-After:"))
        #expect(noHint.contains("\"code\":\"rate_limit_exceeded\""))
    }

    // Retry-After parse hardening matrix (Schneier/Karpathy): only a
    // non-negative integer of delta-seconds is honored; everything else
    // (negative, float, garbage, HTTP-date, absent) → nil; values clamp to
    // [0, cap].
    @Test func retryAfterParsingHardening() {
        func http(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: anthropicURL, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let cap = 30
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "5"]), capSeconds: cap) == 5)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "  7  "]), capSeconds: cap) == 7)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "100000"]), capSeconds: cap) == 30)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "0"]), capSeconds: cap) == 0)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "-5"]), capSeconds: cap) == nil)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "1.5"]), capSeconds: cap) == nil)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "soon"]), capSeconds: cap) == nil)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http(["Retry-After": "Wed, 21 Oct 2025 07:28:00 GMT"]), capSeconds: cap) == nil)
        #expect(ClaudeAPIChatEngine.parseRetryAfterSeconds(http([:]), capSeconds: cap) == nil)
    }
}
