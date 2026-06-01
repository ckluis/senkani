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
    let engine = ClaudeAPIChatEngine(apiKey: apiKey, session: session, endpoint: url)
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
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"type":"error","error":{"type":"overloaded_error","message":"DETAILED ANTHROPIC MESSAGE WITH PROMPT BLEED"}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 529, body: Data(body.utf8))
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
        #expect(caught == .upstreamError(status: 529, type: "overloaded_error"))

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
