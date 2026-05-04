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
///   - `modelTier` — the session's default model tier (env-resolved)
///   - `agentType` — the detected agent harness (claude_code, etc.)
///   - `capturedAt` — wall clock at capture
///
/// Stable serialization: encodes deterministically with sorted keys so the
/// `policyHash()` is byte-identical across processes given the same input.
public struct PolicyConfig: Codable, Sendable, Hashable {
    public let features: PolicyFeatures
    public let budget: PolicyBudget
    public let learnedRulesHash: String
    public let modelTier: String?
    public let agentType: String?
    public let capturedAt: Date

    public init(
        features: PolicyFeatures,
        budget: PolicyBudget,
        learnedRulesHash: String,
        modelTier: String?,
        agentType: String?,
        capturedAt: Date = Date()
    ) {
        self.features = features
        self.budget = budget
        self.learnedRulesHash = learnedRulesHash
        self.modelTier = modelTier
        self.agentType = agentType
        self.capturedAt = capturedAt
    }

    /// Capture the live policy state at this moment. Reads from
    /// `FeatureConfig.resolve(...)`, `BudgetConfig.load()`,
    /// `LearnedRulesStore.load()`, and `ProcessInfo.processInfo.environment`.
    public static func capture(projectRoot: String? = nil) -> PolicyConfig {
        let features = FeatureConfig.resolve(projectRoot: projectRoot)
        let budget = BudgetConfig.load()
        let env = ProcessInfo.processInfo.environment
        let modelTier = env["CLAUDE_MODEL"] ?? env["SENKANI_MODEL_TIER"]
        let agentType = env["SENKANI_AGENT"]

        return PolicyConfig(
            features: PolicyFeatures(from: features),
            budget: PolicyBudget(from: budget),
            learnedRulesHash: LearnedRulesHasher.currentHash(),
            modelTier: modelTier,
            agentType: agentType
        )
    }

    /// Deterministic JSON-derived hash. Two captures of identical state
    /// produce the same string regardless of process or wall-clock —
    /// `capturedAt` is excluded from the hash so two snapshots of the
    /// same configuration deduplicate via `policy_hash` UNIQUE.
    public func policyHash() -> String {
        let view = HashableView(
            features: features,
            budget: budget,
            learnedRulesHash: learnedRulesHash,
            modelTier: modelTier,
            agentType: agentType
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(view) else { return "" }
        return SHA256Hasher.hex(of: data)
    }

    /// Encode to indented sorted-keys JSON for human-readable CLI output.
    public func prettyJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private struct HashableView: Codable {
        let features: PolicyFeatures
        let budget: PolicyBudget
        let learnedRulesHash: String
        let modelTier: String?
        let agentType: String?
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

/// Hashes the live learned-rules file. Returns `""` (treated as "no
/// rules loaded") when the file is missing or unreadable so a fresh DB
/// without learned state still gets a deterministic, comparable hash.
public enum LearnedRulesHasher {
    public static func currentHash() -> String {
        guard let file = LearnedRulesStore.load() else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return "" }
        return SHA256Hasher.hex(of: data)
    }
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
