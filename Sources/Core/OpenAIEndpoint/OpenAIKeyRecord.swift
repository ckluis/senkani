import Foundation

/// V.13a-2 — vault record for a provisioned OpenAI-endpoint API key.
///
/// The plaintext key (`sk-senkani-…`) is shown to the operator ONCE at
/// provisioning time and is NEVER persisted. Only `keyHash` (hex
/// SHA-256 of the plaintext) is stored, so a leaked vault file does not
/// hand an attacker a usable key — they would still need to invert the
/// hash. The record is the verifier, not the secret.
///
/// Persisted as JSON under the `openai-endpoint` scope (see
/// `OpenAIKeyProvisioner`). Field names use snake_case on disk to match
/// the V.13 decomposition's documented shape
/// (`{ key_hash, preset, scope, rate_limit, created_at, expires_at?,
/// label }`).
public struct OpenAIKeyRecord: Codable, Sendable, Equatable {
    /// Default requests-per-minute when the operator does not override.
    public static let defaultRateLimit = 60

    /// Hex SHA-256 of the plaintext key. The verifier — never the secret.
    public let keyHash: String
    /// Provider preset the key routes to (e.g. `openai`, `anthropic`).
    public let preset: String
    /// Surfaces this key may hit (e.g. `["chat", "embeddings"]`). A key
    /// without `tools` in scope cannot use tool-use even if the request
    /// asks (the `tools` surface is enforced in v13d; the contract is
    /// defined here).
    public let scope: [String]
    /// Per-key rate limit in requests-per-minute.
    public let rateLimit: Int
    /// Provisioning timestamp.
    public let createdAt: Date
    /// Optional expiry. A request after this instant is `401`.
    public let expiresAt: Date?
    /// Optional operator-facing label.
    public let label: String?

    public init(
        keyHash: String,
        preset: String,
        scope: [String],
        rateLimit: Int,
        createdAt: Date,
        expiresAt: Date? = nil,
        label: String? = nil
    ) {
        self.keyHash = keyHash
        self.preset = preset
        self.scope = scope
        self.rateLimit = rateLimit > 0 ? rateLimit : OpenAIKeyRecord.defaultRateLimit
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case keyHash = "key_hash"
        case preset
        case scope
        case rateLimit = "rate_limit"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case label
    }
}
