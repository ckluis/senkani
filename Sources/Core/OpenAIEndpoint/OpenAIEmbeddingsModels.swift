import Foundation

/// V.13c — OpenAI-compatible request/response shapes for
/// `POST /v1/embeddings`.
///
/// Only the fields senkani's embeddings surface needs are modeled. Unknown
/// request fields are ignored on decode (lenient client posture); the
/// response is the strict OpenAI `list`-of-`embedding` object.
///
/// `input` is a union in the OpenAI spec: a single string, an array of
/// strings, an array of token ids, or an array of token-id arrays. v13c
/// supports the two TEXT forms (string + `[String]`) and returns `400` for
/// the token-id forms (documented in
/// `OpenAIEmbeddingsHandler.decodeRequest` — mirrors the chat surface's
/// array-`content` rejection). Decode normalizes the string form to a
/// one-element array so the handler always sees `[String]`.
public struct EmbeddingsRequest: Sendable, Equatable {
    /// The client-requested model (e.g. `text-embedding-3-small`). Logged
    /// for telemetry only — senkani serves the single on-device embedding
    /// model sourced from `ModelManager` (see `OpenAIEmbeddingsHandler`).
    public let model: String
    /// Normalized inputs — always an array (the string form is wrapped).
    public let input: [String]

    public init(model: String, input: [String]) {
        self.model = model
        self.input = input
    }
}

extension EmbeddingsRequest: Decodable {
    enum CodingKeys: String, CodingKey {
        case model, input
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        // `input` is a union. Accept a single string or an array of strings;
        // anything else (token ids, array of arrays, object) is unsupported
        // → throw, which `decodeRequest` maps to a 400.
        if let single = try? container.decode(String.self, forKey: .input) {
            self.input = [single]
        } else {
            self.input = try container.decode([String].self, forKey: .input)
        }
    }
}

/// OpenAI `list`-of-`embedding` response object.
public struct EmbeddingsResponse: Codable, Sendable, Equatable {
    public struct Datum: Codable, Sendable, Equatable {
        public let object: String      // always "embedding"
        public let index: Int
        public let embedding: [Float]

        public init(object: String = "embedding", index: Int, embedding: [Float]) {
            self.object = object
            self.index = index
            self.embedding = embedding
        }
    }

    /// Embeddings `usage` has no `completion_tokens` — only `prompt_tokens`
    /// and `total_tokens` (which equal each other; there is no generation).
    public struct Usage: Codable, Sendable, Equatable {
        public let promptTokens: Int
        public let totalTokens: Int

        public init(promptTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.totalTokens = totalTokens
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case totalTokens = "total_tokens"
        }
    }

    public let object: String          // always "list"
    public let data: [Datum]
    /// The ACTUAL model used (the on-device embedding model sourced from
    /// `ModelManager`), NOT the client-requested `model` — preserves
    /// senkani's invisible-optimization stance, matching the chat surface.
    public let model: String
    public let usage: Usage

    public init(
        object: String = "list",
        data: [Datum],
        model: String,
        usage: Usage
    ) {
        self.object = object
        self.data = data
        self.model = model
        self.usage = usage
    }
}
