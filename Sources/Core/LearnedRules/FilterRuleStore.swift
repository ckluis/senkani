import Foundation
import Filter

// MARK: - Bounded context: Filter rules
//
// `LearnedFilterRule` is the Phase H/H+1/H+2a artifact that lives inside
// `learned-rules.json`. Every rule moves through the lifecycle:
//
//   recurring → staged → applied   (happy path, human-gated apply)
//   recurring → staged → rejected  (operator says no)
//
// Dedup key for re-observation: `(command, subcommand, ops)`. A
// previously rejected rule is sticky — re-observing it is a no-op so
// the operator is never re-nagged.
//
// This file owns the type AND the lifecycle. The shared persistence
// (load/save/cache, withPath) lives in `LearnedRulesStore.swift`.

// MARK: - LearnedFilterRule
//
// H+1 schema additions (all default-constructible so v1 files migrate cleanly):
//
//   - `rationale`       — deterministic, human-readable "why" (<=140 chars)
//   - `signalType`      — Garg taxonomy, defaults to `.failure` for filter rules
//   - `recurrenceCount` — number of times this pattern has been proposed
//   - `lastSeenAt`      — timestamp of most recent proposal observation
//   - `sources`         — all session ids that contributed; `source` kept for back-compat
//
// The rule continues to deserialize as a `FilterRule` at apply time via
// `asFilterRule`. `asFilterRule` only understands op strings the H-era
// parser recognized plus `stripMatching(<literal>)` (H+1 addition).

public struct LearnedFilterRule: Codable, Sendable {
    /// Stable UUID — used for apply/reject by ID.
    public let id: String
    /// Base command name, e.g. "docker"
    public let command: String
    /// Optional subcommand, e.g. "compose". nil matches any subcommand.
    public let subcommand: String?
    /// Serialized FilterOp descriptions, e.g. `["head(50)", "stripMatching(INFO)"]`.
    public let ops: [String]
    /// session_id of the session that first proposed this rule.
    public let source: String
    /// 0.0–1.0 Laplace-smoothed (H+1). 1.0 = strongest evidence of unfiltered.
    public let confidence: Double
    /// Lifecycle state.
    public var status: LearnedRuleStatus
    /// Number of distinct sessions where the triggering pattern appeared.
    public var sessionCount: Int
    /// When this rule was first proposed.
    public let createdAt: Date

    // MARK: H+1 additions (all optional in JSON for v1→v2 migration)

    /// Deterministic human-readable "why" line.
    public var rationale: String
    /// Garg-taxonomy signal category. Filter rules default to `.failure`.
    public var signalType: SignalType
    /// How many post-session runs have re-proposed this pattern.
    public var recurrenceCount: Int
    /// Most recent re-observation.
    public var lastSeenAt: Date
    /// All session ids that contributed to the observation aggregate.
    public var sources: [String]

    // MARK: H+2a additions

    /// LLM-generated natural-language rewrite of `rationale`. Populated
    /// asynchronously after a rule is promoted to `.staged` (see
    /// `GemmaRationaleRewriter`). `nil` until enrichment completes — CLI
    /// and callers MUST fall back to `rationale` when this is nil.
    ///
    /// Contained to this field: the LLM output never enters
    /// `FilterPipeline.engine.rules`. Karpathy's Phase K red-flag
    /// constraint holds through H+2a.
    public var enrichedRationale: String?

    public init(
        id: String,
        command: String,
        subcommand: String?,
        ops: [String],
        source: String,
        confidence: Double,
        status: LearnedRuleStatus,
        sessionCount: Int = 0,
        createdAt: Date,
        rationale: String = "",
        signalType: SignalType = .failure,
        recurrenceCount: Int = 1,
        lastSeenAt: Date? = nil,
        sources: [String]? = nil,
        enrichedRationale: String? = nil
    ) {
        self.id = id
        self.command = command
        self.subcommand = subcommand
        self.ops = ops
        self.source = source
        self.confidence = confidence
        self.status = status
        self.sessionCount = sessionCount
        self.createdAt = createdAt
        self.rationale = rationale
        self.signalType = signalType
        self.recurrenceCount = recurrenceCount
        self.lastSeenAt = lastSeenAt ?? createdAt
        self.sources = sources ?? [source]
        self.enrichedRationale = enrichedRationale
    }

    // Decodable with defaults for every H+1 addition. Uses a custom init
    // so v1 files decode without a separate migration pass — the fields
    // simply fall back to the v1-equivalent values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.command = try c.decode(String.self, forKey: .command)
        self.subcommand = try c.decodeIfPresent(String.self, forKey: .subcommand)
        self.ops = try c.decode([String].self, forKey: .ops)
        self.source = try c.decode(String.self, forKey: .source)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.status = try c.decode(LearnedRuleStatus.self, forKey: .status)
        self.sessionCount = (try? c.decode(Int.self, forKey: .sessionCount)) ?? 0
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.rationale = (try? c.decode(String.self, forKey: .rationale)) ?? ""
        self.signalType = (try? c.decode(SignalType.self, forKey: .signalType)) ?? .failure
        self.recurrenceCount = (try? c.decode(Int.self, forKey: .recurrenceCount)) ?? 1
        self.lastSeenAt = (try? c.decode(Date.self, forKey: .lastSeenAt)) ?? self.createdAt
        self.sources = (try? c.decode([String].self, forKey: .sources)) ?? [self.source]
        // v3 addition — optional on disk, default nil.
        self.enrichedRationale = try? c.decodeIfPresent(String.self, forKey: .enrichedRationale)
    }

    /// Convert serialized ops strings back into a `FilterRule`.
    /// Supported ops: `head(N)`, `tail(N)`, `truncateBytes(N)`,
    /// `dedupLines`, `stripANSI`, `stripMatching(<literal>)`.
    /// `stripMatching` accepts a substring literal (matches `LineOperations.stripMatching`
    /// which uses `String.contains`). No regex, so no ReDoS risk (Schneier).
    public var asFilterRule: FilterRule {
        let filterOps: [FilterOp] = ops.compactMap { op in
            if op.hasPrefix("head("), let n = parseIntArg(op) { return .head(n) }
            if op.hasPrefix("tail("), let n = parseIntArg(op) { return .tail(n) }
            if op.hasPrefix("truncateBytes("), let n = parseIntArg(op) { return .truncateBytes(n) }
            if op.hasPrefix("stripMatching("), let s = parseStringArg(op) { return .stripMatching(s) }
            if op == "dedupLines" { return .dedupLines }
            if op == "stripANSI" { return .stripANSI }
            return nil
        }
        return FilterRule(command: command, subcommand: subcommand, ops: filterOps)
    }

    private func parseIntArg(_ s: String) -> Int? {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")") else { return nil }
        return Int(s[s.index(after: open)..<close])
    }

    private func parseStringArg(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")"),
              close > open else { return nil }
        return String(s[s.index(after: open)..<close])
    }
}

// MARK: - Filter-rule lifecycle (extension on the façade)

extension LearnedRulesStore {

    /// H+1 contract: record a freshly-observed proposal. If an equivalent
    /// rule (same command+subcommand+ops) already exists in a non-terminal
    /// status (recurring/staged/applied), bump its `recurrenceCount`,
    /// `lastSeenAt`, and `sources` list. Otherwise append a new rule in
    /// `.recurring` status.
    ///
    /// This replaces Phase H's `stage` no-op-on-dup behavior with an
    /// aggregate counter — enabling the daily-cadence sweep.
    /// Terminal statuses (`.rejected`) are respected: a previously
    /// rejected rule is NOT re-proposed (prevents nagging).
    ///
    /// H+2b note: operates on the polymorphic artifact set directly —
    /// iterates `artifacts` in place so mutation stays O(N) instead of
    /// rebuilding the array via the `rules` computed setter.
    public static func observe(_ rule: LearnedFilterRule) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .filterRule(var existing) = artifact else { continue }
            guard existing.command == rule.command,
                  existing.subcommand == rule.subcommand,
                  existing.ops == rule.ops
            else { continue }
            switch existing.status {
            case .rejected:
                return   // respect operator's decision
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = rule.lastSeenAt
                if !existing.sources.contains(rule.source) {
                    existing.sources.append(rule.source)
                }
                existing.sessionCount = max(existing.sessionCount, rule.sessionCount)
                file.artifacts[idx] = .filterRule(existing)
                didMerge = true
            }
            break
        }
        if !didMerge {
            file.artifacts.append(.filterRule(rule))
        }
        try save(file)
        shared = file
    }

    /// Back-compat: Phase H callers that still use `stage(_:)` get the
    /// new `observe` behavior — non-breaking from the caller's side.
    @available(*, deprecated, renamed: "observe(_:)", message: "Use observe(_:) — it also handles deduplication + recurrence counting.")
    public static func stage(_ rule: LearnedFilterRule) throws {
        try observe(rule)
    }

    /// Promote a single rule from `.recurring` to `.staged`. Called by the
    /// daily-cadence sweep once a rule has recurred ≥N times with sufficient
    /// confidence. No-op for rules in terminal statuses or already staged.
    public static func promoteToStaged(id: String) throws {
        var file = load() ?? .empty
        guard let idx = file.rules.firstIndex(where: { $0.id == id }) else { return }
        guard file.rules[idx].status == .recurring else { return }
        file.rules[idx].status = .staged
        try save(file)
        shared = file
    }

    /// Move a staged rule to applied status.
    public static func apply(id: String) throws {
        var file = load() ?? .empty
        guard let idx = file.rules.firstIndex(where: { $0.id == id }) else { return }
        file.rules[idx].status = .applied
        try save(file)
        shared = file
    }

    /// Apply all staged rules at once.
    public static func applyAll() throws {
        var file = load() ?? .empty
        for idx in file.rules.indices where file.rules[idx].status == .staged {
            file.rules[idx].status = .applied
        }
        try save(file)
        shared = file
    }

    /// Move a staged rule to rejected status.
    public static func reject(id: String) throws {
        var file = load() ?? .empty
        guard let idx = file.rules.firstIndex(where: { $0.id == id }) else { return }
        file.rules[idx].status = .rejected
        try save(file)
        shared = file
    }

    /// Store an LLM-generated rewrite of the rule's rationale.
    /// Caller has already run safety passes (SecretDetector + length
    /// cap) on `enrichedRationale`; this method is persistence only.
    /// No-op when the rule id is unknown.
    public static func setEnrichedRationale(id: String, text: String?) throws {
        var file = load() ?? .empty
        guard let idx = file.rules.firstIndex(where: { $0.id == id }) else { return }
        file.rules[idx].enrichedRationale = text
        try save(file)
        shared = file
    }

    // MARK: - Filter-rule queries

    /// Returns only rules currently in applied status as FilterRules.
    public static func loadApplied() -> [LearnedFilterRule] {
        (load() ?? .empty).rules.filter { $0.status == .applied }
    }

    /// Returns rules in `.recurring` status — candidates for the daily sweep.
    public static func loadRecurring() -> [LearnedFilterRule] {
        (load() ?? .empty).rules.filter { $0.status == .recurring }
    }
}
