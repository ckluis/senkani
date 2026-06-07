import Foundation

/// V.13a-3 / V.13d — OpenAI-compatible request/response shapes for
/// `POST /v1/chat/completions` (non-streaming) plus the V.13d tool-use
/// round-trip (`tools` input, `tool_calls` output, `role: "tool"`
/// follow-up context).
///
/// Only the fields senkani's routing + audit surface needs are modeled.
/// Unknown request fields are ignored on decode (lenient client posture);
/// the response is the strict OpenAI `chat.completion` object.
///
/// `content` is modeled as a `String` on the request (V.13a-3 supports the
/// string form and returns `400` for the array content-parts form). V.13d
/// makes request `content` tolerant of `null` (an assistant message that
/// returned `tool_calls` carries `content: null`) and of an absent key (a
/// `tool` follow-up may omit it) — both decode to "". A NON-string,
/// non-null `content` (e.g. the content-parts array) still throws, so the
/// v13a-3 `400` for the array form is preserved.
/// `stream: true` selects the SSE streaming path (v13b — see
/// `OpenAIChatStream`); `stream` absent/false uses the non-streaming path.

/// A faithful arbitrary-JSON value, used to round-trip a tool's
/// `parameters` JSON-Schema without flattening it. V.13d models the tool
/// schema but does not interpret it — the schema is carried verbatim so a
/// client's declaration survives the round-trip.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool BEFORE number: a JSON `true`/`false` must not be read as a
        // number, and a JSON number never decodes as Bool.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// V.13d — a tool call in the OpenAI shape, shared by the request (an
/// assistant turn carries prior `tool_calls`) and the response (the model
/// emits new `tool_calls`). `arguments` is a JSON-encoded STRING, not an
/// object — this matches OpenAI exactly and is what the client expects to
/// parse back into a dictionary.
public struct OpenAIToolCall: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public let name: String
        /// JSON-encoded arguments string (e.g. `{"location":"SF"}`).
        public let arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
    public let id: String
    public let type: String   // always "function"
    public let function: Function

    public init(id: String, type: String = "function", function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ChatCompletionRequest: Codable, Sendable, Equatable {
    public struct Message: Codable, Sendable, Equatable {
        public let role: String
        /// String content. `null` (assistant-with-tool_calls) and an absent
        /// key (a `tool` follow-up) decode to "". A non-string, non-null
        /// value (the content-parts array) throws → `400`.
        public let content: String
        /// Prior `tool_calls` carried on an assistant turn — preserved so
        /// the follow-up context is honest, not silently dropped.
        public let toolCalls: [OpenAIToolCall]?
        /// `tool_call_id` on a `role: "tool"` follow-up message.
        public let toolCallId: String?
        /// Optional `name` (tool/function name on a `tool` message).
        public let name: String?

        public init(
            role: String,
            content: String,
            toolCalls: [OpenAIToolCall]? = nil,
            toolCallId: String? = nil,
            name: String? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case role, content, name
            case toolCalls = "tool_calls"
            case toolCallId = "tool_call_id"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            // `decodeIfPresent(String)` returns nil for an absent key OR an
            // explicit `null`, and THROWS for a present-but-non-string value
            // (the content-parts array) — preserving the v13a-3 `400`.
            content = (try c.decodeIfPresent(String.self, forKey: .content)) ?? ""
            toolCalls = try c.decodeIfPresent([OpenAIToolCall].self, forKey: .toolCalls)
            toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
            name = try c.decodeIfPresent(String.self, forKey: .name)
        }
    }

    /// V.13d — a tool declaration in the OpenAI shape.
    public struct Tool: Codable, Sendable, Equatable {
        public struct Function: Codable, Sendable, Equatable {
            public let name: String
            public let description: String?
            /// JSON-Schema for the function's parameters, carried verbatim.
            public let parameters: JSONValue?
            public init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
                self.name = name
                self.description = description
                self.parameters = parameters
            }
        }
        public let type: String   // "function"
        public let function: Function
        public init(type: String = "function", function: Function) {
            self.type = type
            self.function = function
        }
    }

    /// The client-requested model (e.g. `gpt-4o`). Logged for telemetry
    /// only — the per-key preset WINS for routing (see `OpenAIChatHandler`).
    public let model: String
    public let messages: [Message]
    /// When `true`, the client asked for an SSE stream (v13b routes these
    /// to `OpenAIChatStream`); absent/false uses the non-streaming path.
    public let stream: Bool?
    /// V.13d — declared tools. A nil or empty array is NOT a tool-use
    /// request; a non-empty array gates on the key's `tools` scope.
    public let tools: [Tool]?

    /// V.13b prompt-caching A — OPT-IN flag for Anthropic prompt caching.
    /// Default-OFF (Schneier P1 privacy posture). When `.ephemeral` and the
    /// engine routes this request to the Anthropic arm, the request body
    /// wraps the system text in a typed `cache_control: ephemeral` block AND
    /// sets the `anthropic-beta: prompt-caching-2024-07-31` header. When
    /// nil, the engine emits the legacy bare-string `system` wire form
    /// (byte-identical with pre-prompt-caching wire) and OMITS the beta
    /// header. NO heuristic auto-injection — even multi-thousand-token
    /// system messages stay un-cached unless the operator opts in
    /// explicitly. Trade-off: caching at Anthropic's edge shifts the trust
    /// boundary (operator content becomes cache-resident for the TTL);
    /// opt-in lets operators make that decision with eyes open. Engines
    /// that don't model caching (MLX, OpenAI proxy) ignore this field.
    public let cacheControl: CacheControlMode?

    public init(
        model: String,
        messages: [Message],
        stream: Bool? = nil,
        tools: [Tool]? = nil,
        cacheControl: CacheControlMode? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.tools = tools
        self.cacheControl = cacheControl
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case cacheControl = "cache_control"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        messages = try c.decode([Message].self, forKey: .messages)
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
        tools = try c.decodeIfPresent([Tool].self, forKey: .tools)
        cacheControl = try c.decodeIfPresent(CacheControlMode.self, forKey: .cacheControl)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(stream, forKey: .stream)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

/// V.13b prompt-caching A — opt-in flag for Anthropic prompt caching.
///
/// `.ephemeral` opts the request into Anthropic's `cache_control:
/// {type: "ephemeral"}` beta. nil = NO caching (default; Schneier P1
/// default-OFF privacy posture). Currently only `.ephemeral` is modeled;
/// future Anthropic cache tiers (e.g. a hypothetical `.persistent`) would
/// extend this enum.
public enum CacheControlMode: String, Codable, Sendable, Equatable {
    case ephemeral
}

/// OpenAI `chat.completion` response object (non-streaming).
public struct ChatCompletionResponse: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public struct Message: Codable, Sendable, Equatable {
            public let role: String
            /// `null` when the assistant returned `tool_calls`, a string
            /// otherwise. Encoded as an explicit `null` (not omitted) so the
            /// OpenAI shape is exact.
            public let content: String?
            /// V.13d — emitted when the model calls a tool. Omitted (not
            /// null) when absent.
            public let toolCalls: [OpenAIToolCall]?

            public init(role: String, content: String?, toolCalls: [OpenAIToolCall]? = nil) {
                self.role = role
                self.content = content
                self.toolCalls = toolCalls
            }

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(role, forKey: .role)
                if let content {
                    try c.encode(content, forKey: .content)
                } else {
                    try c.encodeNil(forKey: .content)   // explicit null
                }
                try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
            }
        }
        public let index: Int
        public let message: Message
        public let finishReason: String

        public init(index: Int, message: Message, finishReason: String) {
            self.index = index
            self.message = message
            self.finishReason = finishReason
        }

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Codable, Sendable, Equatable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int

        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    public let id: String
    public let object: String     // always "chat.completion"
    public let created: Int       // unix seconds
    /// The ACTUAL model used (the resolved tier's model), NOT the
    /// client-requested `model`. Preserves senkani's invisible-
    /// optimization stance: the request asks for `gpt-4o`, the response
    /// reports what actually ran.
    public let model: String
    public let choices: [Choice]
    public let usage: Usage

    public init(
        id: String,
        object: String = "chat.completion",
        created: Int,
        model: String,
        choices: [Choice],
        usage: Usage
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}
