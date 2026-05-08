import Foundation

/// A snapshot of every operator-controlled knob that affects a session's
/// optimization behavior, captured at session start. Replay, audit, and
/// "what was active when this ran?" surfaces all read from this single
/// type rather than re-resolving config sources after the fact.
///
/// Composition:
///   - `features` — the resolved `FeatureConfig` toggle set
///   - `budget`   — the resolved `BudgetConfig` thresholds
///   - `learnedRulesHash` — stable hash of the active learned-rules file
///   - `modelId` — concrete model id from `CLAUDE_MODEL` (e.g.
///     `claude-sonnet-4`)
///   - `modelTier` — operator-named tier from `SENKANI_MODEL_TIER` (e.g.
///     `standard`, `reasoning`); future first-class router presets
///   - `agentType` — the detected agent harness (claude_code, etc.)
///   - `capturedAt` — wall clock at capture
///
/// Pre-2026-05-04 the two env vars (`CLAUDE_MODEL` and
/// `SENKANI_MODEL_TIER`) collapsed into a single `modelTier` field —
/// downstream replay diffs and `senkani policy show` could not tell
/// which vocabulary they were inspecting. Splitting fixes that.
/// Backward-compat decoding migrates legacy single-field rows via
/// `LegacyModelTierClassifier`; see `init(from:)` below.
///
/// Stable serialization: encodes deterministically with sorted keys so the
/// `policyHash()` is byte-identical across processes given the same input.
public struct PolicyConfig: Sendable, Hashable {
    public let features: PolicyFeatures
    public let budget: PolicyBudget
    public let learnedRulesHash: String
    public let modelId: String?
    public let modelTier: String?
    public let agentType: String?
    public let capturedAt: Date

    public init(
        features: PolicyFeatures,
        budget: PolicyBudget,
        learnedRulesHash: String,
        modelId: String?,
        modelTier: String?,
        agentType: String?,
        capturedAt: Date = Date()
    ) {
        self.features = features
        self.budget = budget
        self.learnedRulesHash = learnedRulesHash
        self.modelId = modelId
        self.modelTier = modelTier
        self.agentType = agentType
        self.capturedAt = capturedAt
    }

    /// Capture the live policy state at this moment. Reads from
    /// `FeatureConfig.resolve(...)`, `BudgetConfig.load()`,
    /// `LearnedRulesStore.load()`, and `ProcessInfo.processInfo.environment`.
    ///
    /// Throws `LearnedRulesHashError` when the rules file is present but
    /// unreadable / unencodable — silent fall-through to an empty hash
    /// would let two distinct broken states collapse to the same audit
    /// row via `UNIQUE(session_id, policy_hash)`. The insert path
    /// (`SessionDatabase.capturePolicySnapshot`) catches and turns the
    /// failure into a refused write + an `event_counters` bump.
    public static func capture(projectRoot: String? = nil) throws -> PolicyConfig {
        let features = FeatureConfig.resolve(projectRoot: projectRoot)
        let budget = BudgetConfig.load()
        let env = ProcessInfo.processInfo.environment
        let modelId = env["CLAUDE_MODEL"]
        let modelTier = env["SENKANI_MODEL_TIER"]
        let agentType = env["SENKANI_AGENT"]

        return PolicyConfig(
            features: PolicyFeatures(from: features),
            budget: PolicyBudget(from: budget),
            learnedRulesHash: try LearnedRulesHasher.currentHash(),
            modelId: modelId,
            modelTier: modelTier,
            agentType: agentType
        )
    }

    /// Deterministic JSON-derived hash. Two captures of identical state
    /// produce the same string regardless of process or wall-clock —
    /// `capturedAt` is excluded from the hash so two snapshots of the
    /// same configuration deduplicate via `policy_hash` UNIQUE.
    ///
    /// Throws `PolicyHashError.encodeFailed` rather than returning `""`
    /// on encoder failure — collapsing two distinct broken configs to
    /// the same empty hash would silently drop the second insert via
    /// `ON CONFLICT(session_id, policy_hash) DO NOTHING`, hiding the
    /// integrity breach the snapshot table is supposed to expose.
    public func policyHash() throws -> String {
        let view = HashableView(
            features: features,
            budget: budget,
            learnedRulesHash: learnedRulesHash,
            modelId: modelId,
            modelTier: modelTier,
            agentType: agentType
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(view)
            return SHA256Hasher.hex(of: data)
        } catch {
            throw PolicyHashError.encodeFailed(underlying: String(describing: error))
        }
    }

    /// Encode to indented sorted-keys JSON for human-readable CLI output.
    public func prettyJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private struct HashableView: Encodable {
        let features: PolicyFeatures
        let budget: PolicyBudget
        let learnedRulesHash: String
        let modelId: String?
        let modelTier: String?
        let agentType: String?

        enum CodingKeys: String, CodingKey {
            case features, budget, learnedRulesHash
            case modelId, modelTier, agentType
        }

        // Always emit `modelId` and `modelTier` keys (null when nil) so
        // the wire-format discriminator the decoder relies on is durable
        // across encode/decode round-trips. See
        // `PolicyConfig.init(from:)` for the matching legacy-shape
        // detection.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(features, forKey: .features)
            try c.encode(budget, forKey: .budget)
            try c.encode(learnedRulesHash, forKey: .learnedRulesHash)
            try c.encode(modelId, forKey: .modelId)
            try c.encode(modelTier, forKey: .modelTier)
            try c.encodeIfPresent(agentType, forKey: .agentType)
        }
    }
}

extension PolicyConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case features, budget, learnedRulesHash
        case modelId, modelTier, agentType, capturedAt
    }

    /// Decode supporting two wire formats:
    ///
    /// **New shape (post 2026-05-04 split)** — `modelId` key is present
    /// (possibly with a `null` value). `modelTier` carries operator-tier
    /// vocabulary only.
    ///
    /// **Legacy shape (pre-split)** — `modelId` key absent. The
    /// `modelTier` value is the conflated single field; route it via
    /// `LegacyModelTierClassifier` so a recognized tier name ends up in
    /// `modelTier` and anything else (typically a Claude model id from
    /// `CLAUDE_MODEL`) ends up in `modelId`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.features = try c.decode(PolicyFeatures.self, forKey: .features)
        self.budget = try c.decode(PolicyBudget.self, forKey: .budget)
        self.learnedRulesHash = try c.decode(String.self, forKey: .learnedRulesHash)
        self.agentType = try c.decodeIfPresent(String.self, forKey: .agentType)
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)

        if c.contains(.modelId) {
            self.modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
            self.modelTier = try c.decodeIfPresent(String.self, forKey: .modelTier)
        } else {
            let legacy = try c.decodeIfPresent(String.self, forKey: .modelTier)
            switch LegacyModelTierClassifier.classify(legacy) {
            case .empty:
                self.modelId = nil
                self.modelTier = nil
            case .modelId(let id):
                self.modelId = id
                self.modelTier = nil
            case .modelTier(let tier):
                self.modelId = nil
                self.modelTier = tier
            }
        }
    }

    /// Encode in the new (post-split) shape. Both `modelId` and
    /// `modelTier` are always written (null when nil) so the
    /// discriminator the decoder uses to tell new from legacy is
    /// durable. `agentType` keeps its `encodeIfPresent` semantics —
    /// it predates the split and its absence is already meaningful.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(features, forKey: .features)
        try c.encode(budget, forKey: .budget)
        try c.encode(learnedRulesHash, forKey: .learnedRulesHash)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(modelTier, forKey: .modelTier)
        try c.encodeIfPresent(agentType, forKey: .agentType)
        try c.encode(capturedAt, forKey: .capturedAt)
    }
}

/// Classifies a legacy single `modelTier` value so policy snapshots
/// captured before the 2026-05-04 split decode into the right post-split
/// field.
///
/// The pre-split code resolved `modelTier = env["CLAUDE_MODEL"] ??
/// env["SENKANI_MODEL_TIER"]`. `CLAUDE_MODEL` is a model id like
/// `claude-sonnet-4`; `SENKANI_MODEL_TIER` is one of a small fixed tier
/// vocabulary. The classifier inspects the value:
///
/// - matches a known tier name → routed to `modelTier` (new
///   semantics)
/// - everything else (typical case: a Claude model id) → routed to
///   `modelId`
///
/// The known-tier set is the U.1 TierScorer / `AgentType.swift`
/// vocabulary. Adding a tier here is a wire-format change — if a future
/// tier name happens to also be a substring of a model id, the
/// classifier needs a sharper signal (e.g. an explicit `policyVersion`
/// field).
public enum LegacyModelTierClassifier: Sendable {
    /// The names that historically appeared in `SENKANI_MODEL_TIER`. A
    /// value matching one of these is a tier name; anything else is
    /// treated as a model id.
    public static let knownTiers: Set<String> = [
        "simple", "standard", "complex", "reasoning",
    ]

    public enum Routed: Sendable, Equatable {
        case empty
        case modelId(String)
        case modelTier(String)
    }

    public static func classify(_ value: String?) -> Routed {
        guard let v = value, !v.isEmpty else { return .empty }
        if knownTiers.contains(v) { return .modelTier(v) }
        return .modelId(v)
    }
}

/// Plain-data mirror of `FeatureConfig` so the snapshot stays decoupled
/// from changes to `FeatureConfig`'s resolution machinery.
public struct PolicyFeatures: Codable, Sendable, Hashable {
    public let filter: Bool
    public let secrets: Bool
    public let indexer: Bool
    public let terse: Bool
    public let injectionGuard: Bool

    public init(filter: Bool, secrets: Bool, indexer: Bool, terse: Bool, injectionGuard: Bool) {
        self.filter = filter
        self.secrets = secrets
        self.indexer = indexer
        self.terse = terse
        self.injectionGuard = injectionGuard
    }

    public init(from config: FeatureConfig) {
        self.filter = config.filter
        self.secrets = config.secrets
        self.indexer = config.indexer
        self.terse = config.terse
        self.injectionGuard = config.injectionGuard
    }
}

/// Plain-data mirror of `BudgetConfig`. Captures only the fields that
/// influence enforcement decisions; cache state is intentionally
/// excluded.
public struct PolicyBudget: Codable, Sendable, Hashable {
    public let perSessionLimitCents: Int?
    public let dailyLimitCents: Int?
    public let weeklyLimitCents: Int?
    public let softLimitPercent: Double

    public init(
        perSessionLimitCents: Int?,
        dailyLimitCents: Int?,
        weeklyLimitCents: Int?,
        softLimitPercent: Double
    ) {
        self.perSessionLimitCents = perSessionLimitCents
        self.dailyLimitCents = dailyLimitCents
        self.weeklyLimitCents = weeklyLimitCents
        self.softLimitPercent = softLimitPercent
    }

    public init(from config: BudgetConfig) {
        self.perSessionLimitCents = config.perSessionLimitCents
        self.dailyLimitCents = config.dailyLimitCents
        self.weeklyLimitCents = config.weeklyLimitCents
        self.softLimitPercent = config.softLimitPercent
    }
}

/// Hashes the live learned-rules file.
///
/// Three outcomes — never the same empty string for two of them:
///   - **No rules file on disk** → returns `absentSentinel` (`"none"`).
///     Distinguishable from every real hash and from the failure paths.
///   - **Rules file present but unreadable / undecodable** → throws
///     `LearnedRulesHashError.fileUnreadable`. The caller MUST treat
///     this as fatal-for-this-write; silently substituting a sentinel
///     would hide a corrupt audit baseline.
///   - **Rules file present and decodes, but JSON re-encoding throws**
///     → throws `LearnedRulesHashError.encodeFailed`. Same caller
///     contract.
public enum LearnedRulesHasher {
    /// Stable sentinel returned when no learned-rules file exists on
    /// disk. Matches `^[a-z]+$` so it can never collide with a SHA-256
    /// hex digest. Stored alongside real hashes in
    /// `policy_snapshots.policy_hash` and re-derivable on read.
    public static let absentSentinel: String = "none"

    public static func currentHash() throws -> String {
        let filePath = LearnedRulesStore.path
        guard FileManager.default.fileExists(atPath: filePath) else {
            return absentSentinel
        }
        guard let file = LearnedRulesStore.load() else {
            throw LearnedRulesHashError.fileUnreadable(path: filePath)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(file)
            return SHA256Hasher.hex(of: data)
        } catch {
            throw LearnedRulesHashError.encodeFailed(underlying: String(describing: error))
        }
    }
}

/// Errors thrown by `PolicyConfig.policyHash()`. Stable, Sendable, and
/// String-wrapped so the failure can be attached to the
/// `event_counters` row without leaking a concrete EncodingError graph
/// across module boundaries.
public enum PolicyHashError: Error, Sendable, Equatable {
    case encodeFailed(underlying: String)
}

/// Errors thrown by `LearnedRulesHasher.currentHash()`. The caller
/// (`PolicyStore.capture` / `SessionDatabase.capturePolicySnapshot`)
/// converts each variant into a refused insert + an
/// `event_counters` bump.
public enum LearnedRulesHashError: Error, Sendable, Equatable {
    case fileUnreadable(path: String)
    case encodeFailed(underlying: String)
}

/// Tiny SHA-256 hex shim. Centralized so the policy and audit-chain
/// layers don't drift on hash format. Uses CryptoKit on Apple platforms.
public enum SHA256Hasher {
    public static func hex(of data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = CryptoSHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}

#if canImport(CryptoKit)
import CryptoKit
private typealias CryptoSHA256 = SHA256
#endif
