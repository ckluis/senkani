import Foundation

/// V.13b-2 — Anthropic `/v1/messages` (non-stream) chat client conforming
/// to the `ChatEngine` seam. Hand-rolled URLSession POST; no third-party
/// SDK. Server-side accept-list, senkani-shortname → Anthropic-API-ID
/// translation, and Anthropic↔OpenAI shape mapping live here.
///
/// Scope carves (parent v13b-2 spec):
///   - Retry / backoff / 429 rate-limit translation → b-2b (separate item).
///   - EgressProxy routing (allowlist / connectionProxyDictionary /
///     direct-HTTPS-bypass) → b-4. Today's calls egress directly.
///   - Streaming `/v1/messages` (`stream:true`) → later sub-item.
///
/// Info-leak guard (Schneier): on Anthropic non-200, only the HTTP status
/// + the Anthropic `error.type` short identifier surface. The raw body —
/// which can echo prompt content or upstream guidance — is discarded.
/// On URLSession failure the thrown error carries only `URLError.Code`'s
/// raw value, never `String(describing: error)`, so undocumented userInfo
/// fields can't smuggle headers (including `x-api-key`) into logs.

/// V.13b-2 — accept-list of senkani-side model shortnames the engine will
/// route to Anthropic. These match `ModelTier.claudeModelValue` and are
/// what `OpenAIChatHandler.route` produces. The wire IDs sent to Anthropic
/// are translated via `ClaudeAPIChatEngine.wireModelID(for:)`.
public enum ClaudeAPIChatEngine_AcceptList {
    public static let models: Set<String> = ["claude-haiku-3.5", "claude-sonnet-4", "claude-opus-4"]
}

public enum ClaudeAPIChatEngineError: Error, Sendable, Equatable {
    /// The caller-supplied model is not in the senkani accept-list. No
    /// upstream HTTP call is made before this throws — so DNS/connect-side
    /// channels can't leak attacker-controlled model strings.
    case upstreamModelUnavailable(model: String)
    /// URLSession failed. Carries only `URLError.Code`'s raw value (a small
    /// integer) so undocumented userInfo can't smuggle headers into logs.
    case networkError(code: Int)
    /// The 200 response body could not be decoded as Anthropic Messages
    /// shape. Reason is a short fixed identifier; never raw bytes. Also
    /// surfaced as a LOCAL validation error before any wire egress (e.g.
    /// `role:"tool"` follow-up without a `tool_call_id`) so the caller
    /// sees the parse failure point clearly rather than an opaque
    /// upstream 400.
    case decodeError(reason: String)
    /// Anthropic returned a non-200. `type` is the short identifier from
    /// `error.type` if parseable (`authentication_error`,
    /// `overloaded_error`, `invalid_request_error`, …); nil when the body
    /// is missing, non-JSON, or malformed. The body itself is discarded.
    case upstreamError(status: Int, type: String?)
}

public final class ClaudeAPIChatEngine: ChatEngine {

    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let anthropicVersion: String
    /// Cap on `max_tokens` sent to Anthropic. 4096 is high enough that
    /// realistic chat completions don't truncate; if Anthropic returns
    /// `stop_reason: "max_tokens"` we APPEND a visible `[truncated:
    /// max_tokens reached]` sentinel to the returned content so the caller
    /// sees truncation in the response text (the `Completion` shape has no
    /// `finish_reason` field — `OpenAIChatHandler.handle` derives it
    /// itself from `toolCalls.isEmpty`, so a structural channel would mean
    /// a wider refactor; see follow-up filing).
    private let maxTokens: Int

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        anthropicVersion: String = "2023-06-01",
        maxTokens: Int = 4096
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.maxTokens = maxTokens
    }

    public func chat(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) async throws -> OpenAIChatHandler.Completion {
        // 1. Accept-list gate BEFORE any I/O. No DNS, no connect.
        guard ClaudeAPIChatEngine_AcceptList.models.contains(model) else {
            throw ClaudeAPIChatEngineError.upstreamModelUnavailable(model: model)
        }

        // 2. Build Anthropic request body.
        let wireModel = ClaudeAPIChatEngine.wireModelID(for: model)
        let (system, anthropicMessages) = try ClaudeAPIChatEngine.splitMessages(messages)
        let anthropicTools = tools.isEmpty ? nil : tools.map(ClaudeAPIChatEngine.mapTool(_:))

        let bodyData: Data
        do {
            let req = AnthropicMessagesRequest(
                model: wireModel,
                max_tokens: maxTokens,
                system: system,
                messages: anthropicMessages,
                tools: anthropicTools,
                stream: false
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bodyData = try encoder.encode(req)
        } catch {
            throw ClaudeAPIChatEngineError.decodeError(reason: "request-encode")
        }

        // 3. Wire request.
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        // 4. Fire. Narrow URLError to .code.rawValue only.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw ClaudeAPIChatEngineError.networkError(code: urlError.code.rawValue)
        } catch {
            // Any other Error is collapsed to a fixed sentinel — never
            // `String(describing:)` since that could echo userInfo.
            throw ClaudeAPIChatEngineError.networkError(code: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIChatEngineError.decodeError(reason: "non-http-response")
        }

        // 5. Non-200 → discard body, surface only status + parsed error.type.
        guard http.statusCode == 200 else {
            let parsedType: String? = ClaudeAPIChatEngine.extractAnthropicErrorType(from: data)
            throw ClaudeAPIChatEngineError.upstreamError(status: http.statusCode, type: parsedType)
        }

        // 6. Decode 200 body → Anthropic Messages response.
        let decoded: AnthropicMessagesResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        } catch {
            throw ClaudeAPIChatEngineError.decodeError(reason: "response-decode")
        }

        // 7. Map to OpenAI Completion shape.
        var textPieces: [String] = []
        var toolCalls: [OpenAIToolCall] = []
        for block in decoded.content {
            switch block {
            case .text(let s):
                textPieces.append(s)
            case .toolUse(let id, let name, let input):
                let argsString = ClaudeAPIChatEngine.encodeJSONValueAsString(input)
                toolCalls.append(OpenAIToolCall(
                    id: id,
                    type: "function",
                    function: .init(name: name, arguments: argsString)
                ))
            case .unknown:
                // Forward-compat: skip unknown block types so a new
                // Anthropic block (e.g. `thinking`) doesn't poison sibling
                // text/tool_use blocks already valid in this response.
                continue
            }
        }
        var content = textPieces.joined()
        // Truncation visibility: if Anthropic stopped because we hit
        // max_tokens, surface that in the content so an OpenAI-shaped
        // caller doesn't silently believe the model finished naturally.
        if decoded.stop_reason == "max_tokens" {
            content += "\n\n[truncated: max_tokens reached]"
        }

        // Heuristic counts (consistent with the existing MLX adapter
        // pattern: heuristic fallback + tokenizer-accurate real-* when
        // available). Prompt heuristic is over the joined user/assistant/
        // system content; response heuristic is over the returned text.
        let promptForHeuristic = messages.map(\.content).joined(separator: "\n")
        let heuristicPrompt = OpenAIChatHandler.estimateTokens(promptForHeuristic)
        let heuristicCompletion = OpenAIChatHandler.estimateTokens(content)

        return OpenAIChatHandler.Completion(
            content: content,
            toolCalls: toolCalls,
            promptTokens: heuristicPrompt,
            completionTokens: heuristicCompletion,
            realPromptTokens: decoded.usage?.input_tokens,
            realCompletionTokens: decoded.usage?.output_tokens
        )
    }

    // MARK: - Translation helpers

    /// Senkani-side shortname → canonical Anthropic API model ID. The
    /// shortnames in `ModelTier.claudeModelValue` (`claude-haiku-3.5`,
    /// `claude-sonnet-4`, `claude-opus-4`) are NOT valid Anthropic API
    /// IDs on the wire; Anthropic accepts dated identifiers (or `-latest`
    /// pointers). This map is the single source of truth.
    public static func wireModelID(for shortname: String) -> String {
        switch shortname {
        case "claude-haiku-3.5": return "claude-3-5-haiku-latest"
        case "claude-sonnet-4":  return "claude-sonnet-4-0"
        case "claude-opus-4":    return "claude-opus-4-0"
        default:                 return shortname
        }
    }

    /// Pull `role:"system"` messages out into a joined string; emit the
    /// rest as Anthropic `messages[]` preserving order. Multiple system
    /// turns concatenate with `"\n\n"`.
    ///
    /// Parallel tool-result coalescing (Kleppmann re-audit): consecutive
    /// `role:"tool"` follow-ups (the OpenAI shape for a multi-tool-call
    /// turn) are merged into a SINGLE Anthropic user message carrying
    /// multiple `tool_result` blocks — Anthropic's documented convention.
    /// Emitting them as separate user messages is technically accepted but
    /// fragile and can mis-pair `tool_use_id`s under parallel tool-use.
    ///
    /// Local validation (Kleppmann re-audit P3): a `role:"tool"` message
    /// without a `tool_call_id` throws `.decodeError(reason:
    /// "missing-tool-call-id")` BEFORE any wire egress, so the caller
    /// sees the failure point clearly rather than an opaque upstream 400.
    static func splitMessages(_ msgs: [ChatCompletionRequest.Message]) throws
        -> (system: String?, messages: [AnthropicMessage])
    {
        var systems: [String] = []
        var out: [AnthropicMessage] = []
        var pendingToolResults: [AnthropicContentBlock] = []

        func flushPendingToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            out.append(.init(role: "user", content: .blocks(pendingToolResults)))
            pendingToolResults.removeAll(keepingCapacity: false)
        }

        for m in msgs {
            // Any non-tool message ends a tool-result run.
            if m.role != "tool" { flushPendingToolResults() }

            if m.role == "system" {
                if !m.content.isEmpty { systems.append(m.content) }
                continue
            }
            if m.role == "tool" {
                guard let toolId = m.toolCallId, !toolId.isEmpty else {
                    throw ClaudeAPIChatEngineError.decodeError(reason: "missing-tool-call-id")
                }
                pendingToolResults.append(.toolResult(toolUseId: toolId, content: m.content))
                continue
            }
            if m.role == "assistant" {
                let priorToolCalls = m.toolCalls ?? []
                if !priorToolCalls.isEmpty {
                    var blocks: [AnthropicContentBlock] = []
                    // Mixed-block: assistant text BEFORE its tool_use
                    // blocks (the model's pre-tool reasoning context).
                    // Anthropic accepts heterogeneous content arrays.
                    if !m.content.isEmpty {
                        blocks.append(.text(m.content))
                    }
                    for tc in priorToolCalls {
                        let input = ClaudeAPIChatEngine.decodeJSONValueFromArgumentsString(tc.function.arguments)
                        blocks.append(.toolUse(id: tc.id, name: tc.function.name, input: input))
                    }
                    out.append(.init(role: "assistant", content: .blocks(blocks)))
                } else {
                    out.append(.init(role: "assistant", content: .text(m.content)))
                }
                continue
            }
            // user (and any other role we don't model specially)
            out.append(.init(role: m.role, content: .text(m.content)))
        }
        flushPendingToolResults()
        return (systems.isEmpty ? nil : systems.joined(separator: "\n\n"), out)
    }

    static func mapTool(_ tool: ChatCompletionRequest.Tool) -> AnthropicTool {
        AnthropicTool(
            name: tool.function.name,
            description: tool.function.description,
            input_schema: tool.function.parameters ?? .object([:])
        )
    }

    /// Encode a JSONValue as an OpenAI-style arguments STRING — a JSON
    /// document. Sorted keys for determinism in tests.
    static func encodeJSONValueAsString(_ v: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(v), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    /// Decode an OpenAI tool-call arguments string (a JSON document) back
    /// into a JSONValue for Anthropic's structured `input`. On malformed
    /// input we surface the original string wrapped as a JSON string so
    /// the upstream tool sees the literal bytes — caller history that's
    /// partial / streamed mid-tool-call survives the round-trip rather
    /// than throwing.
    static func decodeJSONValueFromArgumentsString(_ s: String) -> JSONValue {
        guard let data = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .string(s)
        }
        return v
    }

    /// Best-effort extraction of `error.type` from an Anthropic error
    /// envelope. On any parse failure (non-JSON body, wrong shape, missing
    /// field) returns nil — the body is never echoed.
    static func extractAnthropicErrorType(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let type: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.type
    }
}

// MARK: - Anthropic wire shapes (internal)

struct AnthropicMessagesRequest: Codable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let stream: Bool
}

struct AnthropicMessage: Codable {
    let role: String   // "user" | "assistant"
    let content: AnthropicMessageContent
}

/// Anthropic `content` accepts EITHER a bare string OR an array of typed
/// blocks. We encode as a string when there's a single text payload and
/// no tool blocks; otherwise an array.
enum AnthropicMessageContent: Codable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):       try c.encode(s)
        case .blocks(let parts): try c.encode(parts)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        let arr = try c.decode([AnthropicContentBlock].self)
        self = .blocks(arr)
    }
}

enum AnthropicContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case tool_use_id
        case content
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .tool_use_id)
            try c.encode(content, forKey: .content)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .tool_use_id),
                content: try c.decode(String.self, forKey: .content)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown Anthropic content block type \(type)"
            )
        }
    }
}

struct AnthropicTool: Codable {
    let name: String
    let description: String?
    let input_schema: JSONValue
}

struct AnthropicMessagesResponse: Codable {
    let id: String?
    let type: String?
    let role: String?
    let content: [AnthropicResponseBlock]
    let stop_reason: String?
    let usage: AnthropicUsage?
}

/// Forward-compat (Kleppmann re-audit): an unknown block `type`
/// (Anthropic may introduce `thinking`, `server_tool_use`, etc.) must
/// NOT abort decoding of the whole response — valid sibling blocks
/// would be lost. Unknown types decode to `.unknown` and are skipped
/// by the chat() consumer; encoding `.unknown` is unsupported (and
/// unnecessary — we never round-trip a response block back to the wire).
enum AnthropicResponseBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        default:
            self = .unknown(type: type)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

struct AnthropicUsage: Codable {
    let input_tokens: Int
    let output_tokens: Int
}
