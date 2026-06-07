import Foundation

/// V.13a-3 — in-memory tamper-evident audit chain for the OpenAI
/// endpoint's per-request log. Each served request appends exactly ONE
/// entry; entries are chained with `ChainHasher.entryHash` exactly as the
/// SQLite-backed `ChainVerifier` chains its tables:
/// `entry_hash = SHA-256(prev_hash || canonicalRowBytes)`.
///
/// Why a dedicated in-memory chain rather than calling `ChainVerifier`
/// directly: `ChainVerifier` walks `chain_anchors` + table rows on a
/// `SessionDatabase` handle. The serve endpoint has no DB in its request
/// hot path, so this type reuses the same primitive (`ChainHasher`) and
/// mirrors `ChainVerifier`'s verification model ("recompute and compare;
/// first mismatch wins") over an in-process entry list. The 100-request
/// burst-integrity test + any DB-backed persistence is v13e.
///
/// **Body privacy.** The audit fields never include prompt or completion
/// text. Bodies are stored ONLY when the caller passes a non-nil
/// `AuditBodies` (the `--audit-bodies` opt-in, default off). When bodies
/// are off, the canonical row has no `request_body`/`response_body`
/// columns at all — so a chain built without bodies and one built with
/// bodies are distinguishable by their hashes, and verification uses each
/// entry's own stored column set.
public final class OpenAIAuditChain: @unchecked Sendable {

    /// Canonical SQLite-style "table" name fed to `ChainHasher` so the
    /// hash domain is namespaced to this surface.
    public static let table = "openai_requests"

    /// The documented per-request audit shape. No prompt/response text —
    /// see `AuditBodies` for the opt-in body columns.
    ///
    /// V.13b prompt-caching B — `cacheCreationInputTokens` and
    /// `cacheReadInputTokens` ride INSIDE `AuditFields` (Lauret P2 — the sink
    /// signature `OpenAIServedRequestSink.record(...)` stays unchanged; the
    /// new values get added to the persisted store via `AuditFields`, not via
    /// new positional args, so every caller continues compiling without
    /// churn). Always `nil` in Child B; Child A wires them through `Completion`
    /// when an opt-in request actually invokes prompt caching.
    public struct AuditFields: Sendable, Equatable {
        public let ts: Date
        public let keyLabel: String?
        public let surface: String
        public let modelLogged: String
        public let presetUsed: String
        public let resolvedTier: String
        public let promptTokenCount: Int
        public let completionTokenCount: Int
        public let status: String
        /// Anthropic cache_creation_input_tokens decoded from the upstream
        /// usage block (Child A) — audit-only; NEVER surfaces on the
        /// `ChatCompletionResponse.Usage` wire (Lauret P2 wire-stability
        /// invariant).
        public let cacheCreationInputTokens: Int?
        /// Anthropic cache_read_input_tokens decoded from the upstream
        /// usage block (Child A) — audit-only; NEVER surfaces on the
        /// `ChatCompletionResponse.Usage` wire (Lauret P2 wire-stability
        /// invariant).
        public let cacheReadInputTokens: Int?

        public init(
            ts: Date,
            keyLabel: String?,
            surface: String,
            modelLogged: String,
            presetUsed: String,
            resolvedTier: String,
            promptTokenCount: Int,
            completionTokenCount: Int,
            status: String,
            cacheCreationInputTokens: Int? = nil,
            cacheReadInputTokens: Int? = nil
        ) {
            self.ts = ts
            self.keyLabel = keyLabel
            self.surface = surface
            self.modelLogged = modelLogged
            self.presetUsed = presetUsed
            self.resolvedTier = resolvedTier
            self.promptTokenCount = promptTokenCount
            self.completionTokenCount = completionTokenCount
            self.status = status
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }
    }

    /// Opt-in request/response bodies (`--audit-bodies`). Default-off:
    /// pass `nil` to `append` to omit these columns entirely.
    public struct AuditBodies: Sendable, Equatable {
        public let requestBody: String
        public let responseBody: String
        public init(requestBody: String, responseBody: String) {
            self.requestBody = requestBody
            self.responseBody = responseBody
        }
    }

    /// One chained entry. Stores the source fields + optional bodies so
    /// verification can re-derive the canonical bytes deterministically.
    public struct Entry: Sendable, Equatable {
        public let fields: AuditFields
        public let bodies: AuditBodies?
        public let prev: String?
        public let entryHash: String
    }

    public enum VerifyResult: Sendable, Equatable {
        /// All entries verify and link cleanly.
        case ok(count: Int)
        /// First broken entry: `index` is its position; `expected` is the
        /// recomputed hash, `actual` is what the entry stored.
        case brokenAt(index: Int, expected: String, actual: String)
        /// `prev` linkage broke: entry `index`'s `prev` does not equal the
        /// previous entry's `entryHash` (or the first entry's `prev` is
        /// non-nil).
        case linkBrokenAt(index: Int)
        /// No entries appended yet.
        case empty
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []

    public init() {}

    /// Build the canonical column map for an entry. Pure + deterministic —
    /// the writer (here) and the verifier (`verify`) share it so the bytes
    /// always match. Body columns appear ONLY when `bodies` is non-nil.
    public static func canonicalColumns(
        fields: AuditFields,
        bodies: AuditBodies?
    ) -> [String: ChainHasher.CanonicalValue] {
        var columns: [String: ChainHasher.CanonicalValue] = [
            "ts":                     .real(fields.ts.timeIntervalSince1970),
            "key_label":              fields.keyLabel.map { .text($0) } ?? .null,
            "surface":                .text(fields.surface),
            "model_logged":           .text(fields.modelLogged),
            "preset_used":            .text(fields.presetUsed),
            "resolved_tier":          .text(fields.resolvedTier),
            "prompt_token_count":     .integer(Int64(fields.promptTokenCount)),
            "completion_token_count": .integer(Int64(fields.completionTokenCount)),
            "status":                 .text(fields.status),
        ]
        if let bodies {
            columns["request_body"] = .text(bodies.requestBody)
            columns["response_body"] = .text(bodies.responseBody)
        }
        // V.13b prompt-caching B — cache token columns appear in the in-memory
        // canonical map ONLY when present. This preserves the existing chain
        // hash for every entry where the engine does not populate cache
        // counts (Child B's universe), so the v13e-5 burst test + the legacy
        // OpenAIAuditChain tests continue to produce identical bytes. When
        // Child A wires non-nil values for opt-in cache requests, those
        // entries will be tamper-evident over the cache token counts too.
        if let v = fields.cacheCreationInputTokens {
            columns["cache_creation_input_tokens"] = .integer(Int64(v))
        }
        if let v = fields.cacheReadInputTokens {
            columns["cache_read_input_tokens"] = .integer(Int64(v))
        }
        return columns
    }

    /// Append one entry, chaining off the current tail. Returns the new
    /// entry. Thread-safe — the `NWConnection` accept callbacks share one
    /// chain.
    @discardableResult
    public func append(_ fields: AuditFields, bodies: AuditBodies?) -> Entry {
        lock.lock(); defer { lock.unlock() }
        let prev = _entries.last?.entryHash
        let columns = OpenAIAuditChain.canonicalColumns(fields: fields, bodies: bodies)
        let hash = ChainHasher.entryHash(table: OpenAIAuditChain.table, columns: columns, prev: prev)
        let entry = Entry(fields: fields, bodies: bodies, prev: prev, entryHash: hash)
        _entries.append(entry)
        return entry
    }

    /// Snapshot of the chain.
    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _entries.count
    }

    /// Verify the live chain.
    public func verify() -> VerifyResult {
        lock.lock(); defer { lock.unlock() }
        return OpenAIAuditChain.verify(entries: _entries)
    }

    /// Pure verification over an entry list — mirrors `ChainVerifier`:
    /// recompute `SHA-256(prev || canonical)` per entry, compare to the
    /// stored hash, and confirm each entry's `prev` equals the prior
    /// entry's hash. First mismatch wins.
    public static func verify(entries: [Entry]) -> VerifyResult {
        guard !entries.isEmpty else { return .empty }
        var expectedPrev: String? = nil
        for (index, entry) in entries.enumerated() {
            if entry.prev != expectedPrev {
                return .linkBrokenAt(index: index)
            }
            let columns = canonicalColumns(fields: entry.fields, bodies: entry.bodies)
            let recomputed = ChainHasher.entryHash(
                table: table, columns: columns, prev: entry.prev
            )
            if recomputed != entry.entryHash {
                return .brokenAt(index: index, expected: recomputed, actual: entry.entryHash)
            }
            expectedPrev = entry.entryHash
        }
        return .ok(count: entries.count)
    }
}
