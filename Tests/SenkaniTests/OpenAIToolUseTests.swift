import Testing
import Foundation
@testable import Core

/// V.13d — tool-use / function-calling round-trip on
/// `POST /v1/chat/completions`. Covers the acceptance checklist from
/// `spec/autonomous/backlog/phase-v13d-tool-use.md`:
///
///   1. tools-input-honored
///   2. tool_calls-output-shape
///   3. arguments-json-string
///   4. role-tool-accepted
///   5. multi-turn-tool-context
///   6. MCPToolConfig-bridge-no-parallel-registry
///   7. no-tools-scope-403
///   8. with-tools-scope-success
///   9. audit-entry
///   10. malformed-tool-schema-rejected
@Suite("OpenAI tool-use / function-calling round-trip (V.13d)")
struct OpenAIToolUseTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// A `get_weather(location)` function tool with a JSON-Schema body.
    private static func weatherTool() -> ChatCompletionRequest.Tool {
        .init(type: "function", function: .init(
            name: "get_weather",
            description: "Get the current weather for a city",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object(["type": .string("string")])
                ]),
                "required": .array([.string("location")])
            ])
        ))
    }

    /// Mirrors `Serve.placeholderChatEngine`'s decision: call the first
    /// declared (bridged) tool until a `role: "tool"` result is in context,
    /// then answer with text. Proves the round-trip with no live LLM.
    private static func toolCallingEngine() -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { _, messages, tools in
            let hasToolResult = messages.contains { $0.role == "tool" }
            if let first = OpenAIToolBridge.bridge(tools).first, !hasToolResult {
                let call = OpenAIToolCall(
                    id: "call_abc123",
                    function: .init(name: first.name, arguments: "{\"location\":\"SF\"}")
                )
                return .init(content: "", toolCalls: [call], promptTokens: 8, completionTokens: 5)
            }
            return .init(content: "It is sunny in SF, 21°C.", promptTokens: 12, completionTokens: 7)
        }
    }

    private static func handle(
        _ request: ChatCompletionRequest,
        engine: OpenAIChatHandler.Engine = toolCallingEngine()
    ) -> OpenAIChatHandler.Result {
        OpenAIChatHandler.handle(
            request: request, recordPreset: "auto", keyLabel: "ci",
            engine: engine, now: Self.fixedNow, id: "chatcmpl-tooltest"
        )
    }

    // MARK: - 1. tools-input-honored

    @Test("input tools (type/function/name/parameters) decode and are honored")
    func toolsInputHonored() throws {
        let body = Data("""
        {"model":"gpt-4o","messages":[{"role":"user","content":"weather in SF?"}],
         "tools":[{"type":"function","function":{"name":"get_weather",
           "description":"Get the current weather for a city",
           "parameters":{"type":"object","properties":{"location":{"type":"string"}},
                         "required":["location"]}}}]}
        """.utf8)
        let request = try #require(OpenAIChatHandler.decodeRequest(body))
        #expect(OpenAIChatHandler.requestUsesTools(request))
        let tool = try #require(request.tools?.first)
        #expect(tool.type == "function")
        #expect(tool.function.name == "get_weather")
        // The JSON-Schema `parameters` round-trips verbatim.
        #expect(tool.function.parameters == JSONValue.object([
            "type": .string("object"),
            "properties": .object(["location": .object(["type": .string("string")])]),
            "required": .array([.string("location")])
        ]))
    }

    // MARK: - 2. tool_calls-output-shape

    @Test("when the model calls a tool, the choice carries tool_calls + null content + tool_calls finish_reason")
    func toolCallsOutputShape() throws {
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather in SF?")],
            tools: [Self.weatherTool()]
        )
        let r = Self.handle(request).response
        let choice = try #require(r.choices.first)
        #expect(choice.finishReason == "tool_calls")
        #expect(choice.message.content == nil)              // null content
        let calls = try #require(choice.message.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].type == "function")
        #expect(calls[0].function.name == "get_weather")
        #expect(!calls[0].id.isEmpty)
    }

    // MARK: - 3. arguments-json-string

    @Test("tool_calls[].function.arguments is a JSON-encoded STRING, not a nested object")
    func argumentsIsJSONString() throws {
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather in SF?")],
            tools: [Self.weatherTool()]
        )
        let framed = OpenAIChatHandler.encodeResponse(Self.handle(request).response)
        let body = try #require(Self.httpBody(framed))
        let top = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let choices = try #require(top["choices"] as? [[String: Any]])
        let message = try #require(choices[0]["message"] as? [String: Any])
        let toolCalls = try #require(message["tool_calls"] as? [[String: Any]])
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        // The wire value MUST be a String (NSString), not a dictionary.
        let arguments = try #require(function["arguments"] as? String)
        #expect((function["arguments"] as? [String: Any]) == nil)
        // …and that string itself parses back to the arguments object.
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        #expect(parsed["location"] as? String == "SF")
    }

    // MARK: - 4. role-tool-accepted

    @Test("a role:tool message (content + tool_call_id) decodes as normal context")
    func roleToolAccepted() throws {
        let body = Data("""
        {"model":"gpt-4o","messages":[
          {"role":"user","content":"weather?"},
          {"role":"tool","content":"{\\"temp\\":21}","tool_call_id":"call_abc123","name":"get_weather"}
        ]}
        """.utf8)
        let request = try #require(OpenAIChatHandler.decodeRequest(body))
        #expect(request.messages.count == 2)
        let toolMsg = request.messages[1]
        #expect(toolMsg.role == "tool")
        #expect(toolMsg.content == "{\"temp\":21}")
        #expect(toolMsg.toolCallId == "call_abc123")
        #expect(toolMsg.name == "get_weather")
    }

    // MARK: - 5. multi-turn-tool-context

    @Test("multi-turn context (assistant tool_calls + tool result) is accepted and resolves to a text answer")
    func multiTurnToolContext() throws {
        // The assistant turn carries content:null + tool_calls; the tool turn
        // carries the result. Both must decode, and the follow-up resolves to
        // a normal text completion (finish_reason stop).
        let body = Data("""
        {"model":"gpt-4o","tools":[{"type":"function","function":{"name":"get_weather"}}],
         "messages":[
          {"role":"user","content":"weather in SF?"},
          {"role":"assistant","content":null,"tool_calls":[
             {"id":"call_abc123","type":"function","function":{"name":"get_weather","arguments":"{\\"location\\":\\"SF\\"}"}}]},
          {"role":"tool","content":"{\\"temp\\":21}","tool_call_id":"call_abc123"}
        ]}
        """.utf8)
        let request = try #require(OpenAIChatHandler.decodeRequest(body))
        #expect(request.messages.count == 3)
        // The assistant turn's content:null decoded to "" and its tool_calls
        // are preserved — not silently dropped.
        #expect(request.messages[1].role == "assistant")
        #expect(request.messages[1].content == "")
        #expect(request.messages[1].toolCalls?.first?.function.name == "get_weather")

        let r = Self.handle(request).response
        let choice = try #require(r.choices.first)
        #expect(choice.finishReason == "stop")
        #expect(choice.message.toolCalls == nil)
        #expect(choice.message.content == "It is sunny in SF, 21°C.")
    }

    // MARK: - 6. MCPToolConfig-bridge-no-parallel-registry

    @Test("tool schema bridges through MCPToolConfig — no parallel registry")
    func mcpToolConfigBridge() {
        let tools = [
            Self.weatherTool(),
            .init(type: "function", function: .init(name: "search_web")),
            .init(type: "function", function: .init(name: "get_weather")),  // dup
        ]
        let bridged: [MCPToolConfig] = OpenAIToolBridge.bridge(tools)
        // The bridge yields the EXISTING catalog row type (MCPToolConfig),
        // deduped by name, ordered first-seen.
        #expect(bridged.map(\.name) == ["get_weather", "search_web"])
        // A function tool executes behavior → `.exec` → confirmation-worthy,
        // the same classification the catalog gives `senkani_exec`.
        for cfg in bridged {
            #expect(cfg.tags == Set([MCPToolTag.exec]))
            #expect(cfg.requiresConfirmation)
        }
        // Single-tool bridge maps name straight through.
        #expect(OpenAIToolBridge.mcpToolConfig(for: Self.weatherTool()).name == "get_weather")
    }

    // MARK: - 7. no-tools-scope-403

    @Test("a key without `tools` scope using tools → 403 insufficient_scope, even with valid tools")
    func noToolsScope403() throws {
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather?")],
            tools: [Self.weatherTool()]
        )
        let response = try #require(
            OpenAIChatHandler.toolsPreflightError(request: request, scope: ["chat", "embeddings"])
        )
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(text.contains("\"code\":\"insufficient_scope\""))
        #expect(text.contains("surface 'tools'"))
        // A request that declares no tools is not gated, regardless of scope.
        let noTools = ChatCompletionRequest(model: "gpt-4o", messages: [.init(role: "user", content: "hi")])
        #expect(OpenAIChatHandler.toolsPreflightError(request: noTools, scope: ["chat"]) == nil)
    }

    // MARK: - 8. with-tools-scope-success

    @Test("a key WITH `tools` scope passes pre-flight and gets the tool-call round-trip")
    func withToolsScopeSuccess() throws {
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather?")],
            tools: [Self.weatherTool()]
        )
        #expect(OpenAIChatHandler.toolsPreflightError(request: request, scope: ["chat", "tools"]) == nil)
        #expect(OpenAIChatHandler.scopeAllowsTools(["chat", "tools"]))
        #expect(!OpenAIChatHandler.scopeAllowsTools(["chat"]))
        // …and the handle path produces a tool_calls response.
        let r = Self.handle(request).response
        #expect(r.choices.first?.finishReason == "tool_calls")
    }

    // MARK: - 9. audit-entry

    @Test("a tool-use request lands exactly one audit-chain entry")
    func auditEntry() throws {
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "weather?")],
            tools: [Self.weatherTool()]
        )
        let result = Self.handle(request)
        let chain = OpenAIAuditChain()
        chain.append(result.auditFields, bodies: result.auditBodies)
        #expect(chain.count == 1)
        #expect(chain.verify() == .ok(count: 1))
        let entry = chain.entries[0]
        #expect(entry.fields.surface == "chat")
        #expect(entry.fields.status == "ok")
        // With bodies on, the audit names the called tool (no text content).
        #expect(entry.bodies?.responseBody == "tool_calls=[get_weather]")
        #expect(entry.bodies?.requestBody.contains("tools=1") == true)
    }

    // MARK: - 10. malformed-tool-schema-rejected

    @Test("malformed tool schemas are rejected (decode 400 + validation 400)")
    func malformedToolSchemaRejected() throws {
        // A tool missing `function.name` fails decode → nil → 400 upstream.
        let missingName = Data("""
        {"model":"gpt-4o","messages":[{"role":"user","content":"hi"}],
         "tools":[{"type":"function","function":{"description":"no name"}}]}
        """.utf8)
        #expect(OpenAIChatHandler.decodeRequest(missingName) == nil)

        // A non-`function` tool type passes decode but fails validation.
        let wrongType = ChatCompletionRequest(
            model: "gpt-4o", messages: [.init(role: "user", content: "hi")],
            tools: [.init(type: "retrieval", function: .init(name: "x"))]
        )
        #expect(OpenAIChatHandler.toolsValidationMessage(wrongType) != nil)
        let wrongTypeErr = try #require(
            OpenAIChatHandler.toolsPreflightError(request: wrongType, scope: ["chat", "tools"])
        )
        #expect(String(decoding: wrongTypeErr, as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request"))

        // An empty function name fails validation too.
        let emptyName = ChatCompletionRequest(
            model: "gpt-4o", messages: [.init(role: "user", content: "hi")],
            tools: [.init(type: "function", function: .init(name: ""))]
        )
        #expect(OpenAIChatHandler.toolsValidationMessage(emptyName) != nil)
        #expect(OpenAIChatHandler.toolsPreflightError(request: emptyName, scope: ["chat", "tools"]) != nil)

        // The content-parts array form is still a decode failure (v13a-3 400).
        let arrayContent = Data("""
        {"model":"gpt-4o","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
        """.utf8)
        #expect(OpenAIChatHandler.decodeRequest(arrayContent) == nil)
    }

    // MARK: - Helpers

    /// Extract the body bytes (past the `\r\n\r\n` head boundary) from a
    /// framed HTTP/1.1 response.
    private static func httpBody(_ framed: Data) -> Data? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = framed.range(of: sep) else { return nil }
        return framed.subdata(in: range.upperBound..<framed.endIndex)
    }
}
