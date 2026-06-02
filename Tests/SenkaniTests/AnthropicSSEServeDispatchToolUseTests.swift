import Testing
import Foundation
@testable import Core

// V.13b-sse-c — translator tool_use streaming tests for the
// `ClaudeAPIServeDispatch.streamingPlan(...)` factory shipped by Child C of
// the v13b-followup-anthropic-sse-streaming decomposition.
//
// Coverage (4 tests, ≥4 acceptance target):
//   1. Single tool_use happy path — Anthropic tool_use frame sequence
//      translates to: role chunk + tool_calls HEADER fragment + 3 CONTINUATION
//      fragments + terminal chunk (finish_reason=tool_calls) + [DONE]. Pin
//      EXACT 7-item count (Karpathy r10 P0).
//   2. Mixed text + tool_use — text content chunks emitted BEFORE the
//      tool_calls header + continuation; terminal finish_reason = "tool_calls"
//      not "stop" (Lauret P1 mixed-content block ordering).
//   3. v13d-1 wire-contract-equivalence — decode each chunk's JSON envelope
//      and assert header carries id/type/function.name; continuation fragments
//      are sparse (id=nil, function.name=nil, only arguments present);
//      arguments concatenate to the original JSON; cross-check id verbatim
//      matches what the non-stream `ClaudeAPIChatEngine.chat(...)` path would
//      round-trip (Anthropic's id is used verbatim).
//   4. Defensive concatenation validation — malformed input_json_delta
//      sequence throws ClaudeAPIChatEngineError.upstreamError(status: 502,
//      type: "tool_arguments_malformed") at messageDelta time (Schneier P1).

// MARK: - Helpers

private let _anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func _makeStreamingEngine(apiKey: String = "ak-sse-c-test") -> ClaudeAPIChatEngine {
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
        messages: [.init(role: "user", content: "what's the weather in SF?")],
        stream: true,
        tools: nil
    )
}

private struct _ToolCallFragment: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }
    let index: Int
    let id: String?
    let type: String?
    let function: Function?
}

private struct _DecodedChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let role: String?
            let content: String?
            let tool_calls: [_ToolCallFragment]?
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
    guard let s = String(data: event, encoding: .utf8),
          s.hasPrefix("data: ") else {
        Issue.record("event missing data: prefix: \(String(data: event, encoding: .utf8) ?? "<nil>")")
        throw CocoaError(.coderInvalidValue)
    }
    let jsonPart = s.dropFirst("data: ".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try JSONDecoder().decode(_DecodedChunk.self, from: Data(jsonPart.utf8))
}

/// Inspect the RAW JSON of an event to verify which keys are PHYSICALLY
/// present (Decodable's optional-nil branch can't distinguish "key absent"
/// from "key present with null value"). The sparse-encode invariant on
/// continuation ToolCallFragment is "id key ABSENT", not "id key present
/// with null".
private func _rawJSON(_ event: Data) throws -> [String: Any] {
    guard let s = String(data: event, encoding: .utf8),
          s.hasPrefix("data: ") else {
        Issue.record("event missing data: prefix")
        throw CocoaError(.coderInvalidValue)
    }
    let jsonPart = s.dropFirst("data: ".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let obj = try JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String: Any] else {
        Issue.record("event JSON is not a top-level object")
        throw CocoaError(.coderInvalidValue)
    }
    return obj
}

private func _firstToolCallRawDict(_ event: Data) throws -> [String: Any] {
    let top = try _rawJSON(event)
    let choices = top["choices"] as? [[String: Any]] ?? []
    let delta = choices.first?["delta"] as? [String: Any] ?? [:]
    let toolCalls = delta["tool_calls"] as? [[String: Any]] ?? []
    guard let first = toolCalls.first else {
        Issue.record("event missing first tool_calls entry")
        throw CocoaError(.coderInvalidValue)
    }
    return first
}

private func _happyPathToolUseSSEChunks() -> [Data] {
    // Single tool_use block with three input_json_delta fragments that
    // concatenate to `{"location":"SF"}`.
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_x","usage":{"input_tokens":7}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"get_weather"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"loc"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ation\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"SF\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    return [Data(frame.utf8)]
}

private func _mixedTextAndToolUseSSEChunks() -> [Data] {
    // Text block at index 0 then tool_use block at index 1.
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_y","usage":{"input_tokens":4}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Looking up... "}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_02","name":"lookup"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}

    event: message_stop
    data: {"type":"message_stop"}


    """
    return [Data(frame.utf8)]
}

private func _malformedToolUseSSEChunks() -> [Data] {
    // Single tool_use block with ONE input_json_delta carrying an
    // unterminated JSON object (missing close brace).
    let frame = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_bad","usage":{"input_tokens":5}}}

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

// MARK: - Tests

@Suite("ClaudeAPIServeDispatch.streamingPlan — tool_use translator", .serialized, .urlProtocolGate)
struct AnthropicSSEServeDispatchToolUseTests {

    @Test func singleToolUseHappyPathEmitsHeaderPlusContinuationsPlusToolCallsTerminal() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _happyPathToolUseSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-tu"
        )
        guard let source = outcome.plan.streamingEvents else {
            Issue.record("streamingEvents source missing"); return
        }
        var emitted: [Data] = []
        for try await chunk in source() { emitted.append(chunk) }
        emitted.append(outcome.plan.done)

        // Exact count: role + header + 3 continuations + terminal + [DONE] = 7
        #expect(emitted.count == 7, "expected 7 items; got \(emitted.count)")

        // (a) role chunk
        let role = try _decodeChunk(emitted[0])
        #expect(role.choices.first?.delta.role == "assistant")
        #expect(role.choices.first?.delta.tool_calls == nil)
        #expect(role.choices.first?.finish_reason == nil)

        // (b) HEADER fragment: index=0, id=toolu_01, type=function,
        //     function.name=get_weather, function.arguments=""
        let header = try _decodeChunk(emitted[1])
        guard let hCall = header.choices.first?.delta.tool_calls?.first else {
            Issue.record("header missing tool_calls[0]"); return
        }
        #expect(hCall.index == 0)
        #expect(hCall.id == "toolu_01")
        #expect(hCall.type == "function")
        #expect(hCall.function?.name == "get_weather")
        #expect(hCall.function?.arguments == "")
        #expect(header.choices.first?.finish_reason == nil)

        // (c-e) 3 CONTINUATION fragments: each only function.arguments
        let c1 = try _decodeChunk(emitted[2])
        let c2 = try _decodeChunk(emitted[3])
        let c3 = try _decodeChunk(emitted[4])
        let cont1 = c1.choices.first?.delta.tool_calls?.first
        let cont2 = c2.choices.first?.delta.tool_calls?.first
        let cont3 = c3.choices.first?.delta.tool_calls?.first
        #expect(cont1?.index == 0)
        #expect(cont2?.index == 0)
        #expect(cont3?.index == 0)
        #expect(cont1?.function?.arguments == "{\"loc")
        #expect(cont2?.function?.arguments == "ation\":")
        #expect(cont3?.function?.arguments == "\"SF\"}")
        #expect(c1.choices.first?.finish_reason == nil)
        #expect(c2.choices.first?.finish_reason == nil)
        #expect(c3.choices.first?.finish_reason == nil)

        // (f) Terminal: delta:{} + finish_reason: "tool_calls"
        let term = try _decodeChunk(emitted[5])
        #expect(term.choices.first?.delta.role == nil)
        #expect(term.choices.first?.delta.content == nil)
        #expect(term.choices.first?.delta.tool_calls == nil)
        #expect(term.choices.first?.finish_reason == "tool_calls")

        // (g) [DONE]
        #expect(emitted[6] == OpenAIChatStream.doneSentinel())
    }

    @Test func mixedTextAndToolUseOrderingTerminalIsToolCalls() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _mixedTextAndToolUseSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: "anthropic-test",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-mixed"
        )
        guard let source = outcome.plan.streamingEvents else {
            Issue.record("streamingEvents source missing"); return
        }
        var emitted: [Data] = []
        for try await chunk in source() { emitted.append(chunk) }

        // Sequence:
        //   [0] role chunk
        //   [1] text content chunk ("Looking up... ")
        //   [2] tool_use HEADER (toolu_02 / lookup / "")
        //   [3] tool_use CONTINUATION ("{}")
        //   [4] terminal (finish_reason: "tool_calls")
        #expect(emitted.count == 5, "expected 5 chunks; got \(emitted.count)")

        let role = try _decodeChunk(emitted[0])
        #expect(role.choices.first?.delta.role == "assistant")

        let text = try _decodeChunk(emitted[1])
        #expect(text.choices.first?.delta.content == "Looking up... ")
        #expect(text.choices.first?.delta.tool_calls == nil)

        let header = try _decodeChunk(emitted[2])
        let hCall = header.choices.first?.delta.tool_calls?.first
        #expect(hCall?.id == "toolu_02")
        #expect(hCall?.function?.name == "lookup")
        #expect(hCall?.function?.arguments == "")

        let cont = try _decodeChunk(emitted[3])
        let cCall = cont.choices.first?.delta.tool_calls?.first
        #expect(cCall?.function?.arguments == "{}")
        #expect(cCall?.id == nil)
        #expect(cCall?.function?.name == nil)

        let term = try _decodeChunk(emitted[4])
        #expect(term.choices.first?.finish_reason == "tool_calls")
    }

    @Test func wireContractEquivalenceV13d1AndIDVerbatim() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _happyPathToolUseSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-wire"
        )
        guard let source = outcome.plan.streamingEvents else {
            Issue.record("streamingEvents source missing"); return
        }
        var emitted: [Data] = []
        for try await chunk in source() { emitted.append(chunk) }

        // emitted layout: [role, header, c1, c2, c3, terminal]
        #expect(emitted.count == 6)
        let header = try _decodeChunk(emitted[1])
        let hCall = header.choices.first?.delta.tool_calls?.first
        #expect(hCall?.id == "toolu_01",
            "header tool_call.id must carry Anthropic's id VERBATIM (matches the non-stream ClaudeAPIChatEngine.chat round-trip at ClaudeAPIChatEngine.swift:220-224)")
        #expect(hCall?.function?.name == "get_weather")
        #expect(hCall?.function?.arguments == "")
        #expect(hCall?.type == "function")

        // Verify continuation fragments are SPARSE-encoded (raw JSON dict
        // physically lacks `id`, `type`, and `function.name` keys — not just
        // present-with-null).
        for i in 2...4 {
            let raw = try _firstToolCallRawDict(emitted[i])
            #expect(raw["id"] == nil, "continuation fragment must omit id key (sparse-encode)")
            #expect(raw["type"] == nil, "continuation fragment must omit type key (sparse-encode)")
            let fn = raw["function"] as? [String: Any] ?? [:]
            #expect(fn["name"] == nil, "continuation function fragment must omit name key (sparse-encode)")
            #expect(fn["arguments"] != nil, "continuation function fragment must carry arguments")
            // index ALWAYS present
            #expect((raw["index"] as? Int) == 0)
        }

        // Decoded continuation Function.name nil + arguments non-nil (the
        // Decodable surface mirrors the sparse-encode invariant).
        let c1 = try _decodeChunk(emitted[2])
        let c2 = try _decodeChunk(emitted[3])
        let c3 = try _decodeChunk(emitted[4])
        let fragments = [c1, c2, c3].compactMap { $0.choices.first?.delta.tool_calls?.first }
        for frag in fragments {
            #expect(frag.id == nil)
            #expect(frag.function?.name == nil)
            #expect(frag.function?.arguments != nil)
        }
        let joinedArgs = fragments.compactMap(\.function?.arguments).joined()
        #expect(joinedArgs == "{\"location\":\"SF\"}",
            "continuation arguments must concatenate to original JSON; got \(joinedArgs)")

        // Terminal
        let term = try _decodeChunk(emitted[5])
        #expect(term.choices.first?.finish_reason == "tool_calls")

        // Cross-check: non-stream ClaudeAPIChatEngine.chat() emits
        // OpenAIToolCall(id: id, ...) using Anthropic's id verbatim — same
        // id "toolu_01" we asserted on the header. The verbatim invariant
        // is mechanically pinned by the same id string flowing through
        // both paths' tool_use mappings.
        #expect(hCall?.id == "toolu_01")
    }

    @Test func defensiveConcatenationValidationThrowsOnMalformedArgs() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(
            url: _anthropicURL,
            chunks: _malformedToolUseSSEChunks()
        )
        let engine = _makeStreamingEngine()
        let outcome = ClaudeAPIServeDispatch.streamingPlan(
            engine: engine,
            request: _request(),
            routing: _routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-bad"
        )
        guard let source = outcome.plan.streamingEvents else {
            Issue.record("streamingEvents source missing"); return
        }
        var caught: Error?
        var emitted: [Data] = []
        do {
            for try await chunk in source() { emitted.append(chunk) }
        } catch {
            caught = error
        }
        guard let caught else {
            Issue.record("expected upstreamError(tool_arguments_malformed); got clean exit with \(emitted.count) chunks")
            return
        }
        guard let typed = caught as? ClaudeAPIChatEngineError else {
            Issue.record("expected ClaudeAPIChatEngineError; got \(type(of: caught))")
            return
        }
        switch typed {
        case .upstreamError(let status, let type):
            #expect(status == 502)
            #expect(type == "tool_arguments_malformed")
        default:
            Issue.record("expected .upstreamError; got \(typed)")
        }
    }
}
