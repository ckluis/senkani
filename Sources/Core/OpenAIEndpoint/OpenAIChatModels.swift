import Foundation

/// V.13a-3 — OpenAI-compatible request/response shapes for
/// `POST /v1/chat/completions` (non-streaming).
///
/// Only the fields senkani's routing + audit surface needs are modeled.
/// Unknown request fields are ignored on decode (lenient client posture);
/// the response is the strict OpenAI `chat.completion` object.
///
/// `content` is modeled as a plain `String`. OpenAI also permits an array
/// of content parts; v13a-3 supports the string form and returns `400`
/// for the array form (documented in `OpenAIChatHandler.decodeRequest`).
/// Streaming (`stream: true`) is rejected with `400` — SSE is v13b.
public struct ChatCompletionRequest: Codable, Sendable, Equatable {
    public struct Message: Codable, Sendable, Equatable {
        public let role: String
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// The client-requested model (e.g. `gpt-4o`). Logged for telemetry
    /// only — the per-key preset WINS for routing (see `OpenAIChatHandler`).
    public let model: String
    public let messages: [Message]
    /// When `true`, the client asked for an SSE stream. v13a-3 is
    /// non-streaming only; the handler returns `400`.
    public let stream: Bool?

    public init(model: String, messages: [Message], stream: Bool? = nil) {
        self.model = model
        self.messages = messages
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
    }
}

/// OpenAI `chat.completion` response object (non-streaming).
public struct ChatCompletionResponse: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public struct Message: Codable, Sendable, Equatable {
            public let role: String
            public let content: String
            public init(role: String, content: String) {
                self.role = role
                self.content = content
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
