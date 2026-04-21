import Foundation
import Filter

// MARK: - LearnedRuleStatus
//
// Phase H+1 adds `.recurring` between `.staged` and the initial proposal:
//
//   recurring → staged → applied   (happy path, human-gated apply)
//   recurring → staged → rejected  (human rejects)
//
// Phase H-era code created rules directly in `.staged`; H+1 lands them
// first in `.recurring` and lets the daily sweep decide which ones have
// enough recurrence to warrant a human review. Legacy v1 rules load as
// their original status — no silent demotion.

public enum LearnedRuleStatus: String, Codable, Sendable, CaseIterable {
    /// New in H+1 — rule proposed at least once, awaiting daily-cadence promotion.
    case recurring
    /// Ready for human apply/reject.
    case staged
    /// Active in FilterPipeline.
    case applied
    /// Operator said no.
    case rejected
}

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

// MARK: - LearnedArtifact
//
// Phase H+2b: polymorphic sum type over every kind of learned
// signal. Round 1 ships `.filterRule` (Phase K) and `.contextDoc`
// (H+2b). Future rounds add `.instructionPatch` (H+2c) and
// `.workflowPlaybook` (H+2c).
//
// Celko discipline: discriminated union with explicit tag. Every
// case serializes as `{"type": "<tag>", "payload": {...}}` so on-disk
// JSON is unambiguous — no "decode every case, keep the one that
// works" nonsense.

public enum LearnedArtifact: Codable, Sendable {
    case filterRule(LearnedFilterRule)
    case contextDoc(LearnedContextDoc)
    case instructionPatch(LearnedInstructionPatch)   // H+2c
    case workflowPlaybook(LearnedWorkflowPlaybook)   // H+2c

    private enum CodingKeys: String, CodingKey { case type, payload }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .filterRule(let r):
            try c.encode("filterRule", forKey: .type)
            try c.encode(r, forKey: .payload)
        case .contextDoc(let d):
            try c.encode("contextDoc", forKey: .type)
            try c.encode(d, forKey: .payload)
        case .instructionPatch(let p):
            try c.encode("instructionPatch", forKey: .type)
            try c.encode(p, forKey: .payload)
        case .workflowPlaybook(let w):
            try c.encode("workflowPlaybook", forKey: .type)
            try c.encode(w, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "filterRule":
            self = .filterRule(try c.decode(LearnedFilterRule.self, forKey: .payload))
        case "contextDoc":
            self = .contextDoc(try c.decode(LearnedContextDoc.self, forKey: .payload))
        case "instructionPatch":
            self = .instructionPatch(try c.decode(LearnedInstructionPatch.self, forKey: .payload))
        case "workflowPlaybook":
            self = .workflowPlaybook(try c.decode(LearnedWorkflowPlaybook.self, forKey: .payload))
        default:
            // Unknown forward-compat tag → throw. Operators upgrade.
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown LearnedArtifact tag: '\(tag)'. Upgrade senkani."
            )
        }
    }

    public var id: String {
        switch self {
        case .filterRule(let r): return r.id
        case .contextDoc(let d): return d.id
        case .instructionPatch(let p): return p.id
        case .workflowPlaybook(let w): return w.id
        }
    }

    public var status: LearnedRuleStatus {
        switch self {
        case .filterRule(let r): return r.status
        case .contextDoc(let d): return d.status
        case .instructionPatch(let p): return p.status
        case .workflowPlaybook(let w): return w.status
        }
    }
}

// MARK: - LearnedRulesFile

/// Top-level JSON container. Version field enables future schema migration.
/// H+1 bumps current version 1 → 2; the custom `LearnedFilterRule` decoder
/// migrates field-by-field so explicit version bookkeeping isn't needed
/// for load — but `currentVersion` is always written on save so operators
/// can tell whether their on-disk file is fresh.
///
/// **H+2b: v3 → v4 polymorphic-artifact migration.** v3 stored a flat
/// `rules: [LearnedFilterRule]` array. v4 stores `artifacts: [LearnedArtifact]`.
/// On decode, if the file has `artifacts`, use it; otherwise wrap every
/// `rules` entry as `.filterRule(r)` and stamp the in-memory file as v4.
/// On save, we always emit v4 (`artifacts` only). `rules` is preserved
/// as a computed property for Phase K-era callers — it filters the
/// artifact set to filter-rule cases only.
public struct LearnedRulesFile: Codable {
    public var version: Int
    public var artifacts: [LearnedArtifact]

    /// v1 (Phase H) → v2 (H+1: recurrence, rationale, signalType) →
    /// v3 (H+2a: enrichedRationale) → v4 (H+2b: polymorphic artifacts) →
    /// v5 (H+2c: instructionPatch + workflowPlaybook cases).
    public static let currentVersion = 5

    public static var empty: LearnedRulesFile {
        LearnedRulesFile(version: currentVersion, artifacts: [])
    }

    /// Back-compat read: filter-rule-only view of the artifact set.
    /// Phase K-era callers (`LearnedRulesStore.observe`, etc.) see this.
    public var rules: [LearnedFilterRule] {
        get {
            artifacts.compactMap {
                if case .filterRule(let r) = $0 { return r } else { return nil }
            }
        }
        set {
            // Setter rebuilds the filter-rule slice in place — leaves
            // non-filter-rule artifacts (context docs, future cases)
            // untouched in their original relative positions.
            var out: [LearnedArtifact] = []
            var ruleQueue = newValue
            var usedIds = Set<String>()
            for artifact in artifacts {
                if case .filterRule(let old) = artifact {
                    if let replacement = ruleQueue.first(where: { $0.id == old.id }) {
                        out.append(.filterRule(replacement))
                        usedIds.insert(replacement.id)
                    }
                    // old rule absent from newValue → dropped.
                } else {
                    out.append(artifact)
                }
            }
            // Append any freshly-added rules (new IDs).
            for r in ruleQueue where !usedIds.contains(r.id) {
                out.append(.filterRule(r))
            }
            artifacts = out
        }
    }

    /// Context-doc-only view for future callers.
    public var contextDocs: [LearnedContextDoc] {
        artifacts.compactMap {
            if case .contextDoc(let d) = $0 { return d } else { return nil }
        }
    }

    /// Instruction-patch-only view (H+2c).
    public var instructionPatches: [LearnedInstructionPatch] {
        artifacts.compactMap {
            if case .instructionPatch(let p) = $0 { return p } else { return nil }
        }
    }

    /// Workflow-playbook-only view (H+2c).
    public var workflowPlaybooks: [LearnedWorkflowPlaybook] {
        artifacts.compactMap {
            if case .workflowPlaybook(let w) = $0 { return w } else { return nil }
        }
    }

    public init(version: Int, artifacts: [LearnedArtifact]) {
        self.version = version
        self.artifacts = artifacts
    }

    /// Back-compat initializer for Phase K tests that build a
    /// `LearnedRulesFile(version:rules:)` directly.
    public init(version: Int, rules: [LearnedFilterRule]) {
        self.version = version
        self.artifacts = rules.map { .filterRule($0) }
    }

    // MARK: - Codable (polymorphic migration)

    private enum CodingKeys: String, CodingKey { case version, artifacts, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        // v4 — modern path. If `artifacts` is present, it must decode
        // cleanly — do NOT silently fall back to `rules` when an
        // element throws (that would mask an unknown-tag forward-compat
        // error). `contains(.artifacts)` distinguishes "key absent"
        // from "key present but malformed."
        if c.contains(.artifacts) {
            self.artifacts = try c.decode([LearnedArtifact].self, forKey: .artifacts)
            return
        }
        // v1/v2/v3 — `artifacts` key absent → old filter-rule-only file.
        // Wrap each rule as `.filterRule(r)`.
        let oldRules = (try? c.decode([LearnedFilterRule].self, forKey: .rules)) ?? []
        self.artifacts = oldRules.map { .filterRule($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(artifacts, forKey: .artifacts)
    }
}

// MARK: - LearnedRulesStore

public enum LearnedRulesStore {

    /// Default on-disk location. Production reads/writes this path; tests
    /// can redirect to a temp file via `withPath(_:)` to avoid racing on
    /// the shared file under parallel execution.
    public static let defaultPath: String = NSHomeDirectory() + "/.senkani/learned-rules.json"

    nonisolated(unsafe) private static var _defaultPath: String = defaultPath
    nonisolated(unsafe) private static var _defaultShared: LearnedRulesFile = {
        let url = URL(fileURLWithPath: _defaultPath)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LearnedRulesFile.self, from: data)) ?? .empty
    }()

    /// Task-local scoped override for tests. A reference-type box lets each
    /// `withPath` body mutate its own (path, cache) pair without colliding
    /// with parallel suites — no NSLock, no cooperative-pool blocking.
    final class Scoped: @unchecked Sendable {
        var path: String
        var cache: LearnedRulesFile
        init(path: String, cache: LearnedRulesFile) {
            self.path = path
            self.cache = cache
        }
    }

    @TaskLocal static var scoped: Scoped?

    /// Current on-disk path. Inside a `withPath(_:)` scope this returns
    /// the scoped temp path; otherwise the production default.
    public static var path: String { Self.scoped?.path ?? _defaultPath }

    /// TEST ONLY: redirect persistence to `temp` for the duration of
    /// `body`. Scoping is per-task (via `@TaskLocal`), so concurrent
    /// parallel suites each get their own isolated (path, cache) box —
    /// no shared lock. Child tasks spawned under structured concurrency
    /// inherit the scope; `Task.detached` does not, by design.
    public static func withPath<T>(_ temp: String, _ body: () throws -> T) rethrows -> T {
        let box = Scoped(path: temp, cache: loadFrom(temp) ?? .empty)
        return try $scoped.withValue(box, operation: body)
    }

    private static func loadFrom(_ path: String) -> LearnedRulesFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LearnedRulesFile.self, from: data)
    }

    // MARK: - Singleton

    /// In-process cache. Inside a `withPath(_:)` scope this reads/writes the
    /// task-local box; otherwise the process-wide default. Tests should call
    /// `reload()` after writing to disk.
    public static var shared: LearnedRulesFile {
        get { Self.scoped?.cache ?? _defaultShared }
        set {
            if let box = Self.scoped {
                box.cache = newValue
            } else {
                _defaultShared = newValue
            }
        }
    }

    // MARK: - Persistence

    public static func load() -> LearnedRulesFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LearnedRulesFile.self, from: data)
    }

    public static func save(_ file: LearnedRulesFile) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Always stamp as currentVersion on save — migrated v1 files become
        // v2 on the first write back.
        var stamped = file
        stamped.version = LearnedRulesFile.currentVersion
        let data = try encoder.encode(stamped)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Reload singleton from disk. Used in tests after writing rules.
    public static func reload() {
        shared = load() ?? .empty
    }

    // MARK: - Mutations

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

    // MARK: - Context artifact mutations (H+2b)

    /// Phase H+2b analogue of `observe(_:)` for context docs. Merges by
    /// `title` (filesystem-safe slug), respects `.rejected` stickiness,
    /// appends a fresh `.recurring` doc when absent.
    public static func observeContextDoc(_ doc: LearnedContextDoc) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .contextDoc(var existing) = artifact else { continue }
            guard existing.title == doc.title else { continue }
            switch existing.status {
            case .rejected:
                return
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = doc.lastSeenAt
                for s in doc.sources where !existing.sources.contains(s) {
                    existing.sources.append(s)
                }
                existing.sessionCount = max(existing.sessionCount, doc.sessionCount)
                // Body update on re-observation lets the generator
                // accumulate more evidence over time. Re-sanitize.
                if !doc.body.isEmpty {
                    existing.body = LearnedContextDoc.sanitizeBody(doc.body)
                }
                file.artifacts[idx] = .contextDoc(existing)
                didMerge = true
            }
            break
        }
        if !didMerge {
            file.artifacts.append(.contextDoc(doc))
        }
        try save(file)
        shared = file
    }

    /// Promote a context doc from `.recurring` → `.staged`. No-op for
    /// other statuses / unknown ids.
    public static func promoteContextDocToStaged(id: String) throws {
        try mutateContextDoc(id: id) { doc in
            guard doc.status == .recurring else { return }
            doc.status = .staged
        }
    }

    /// Move a staged context doc to applied status.
    public static func applyContextDoc(id: String) throws {
        try mutateContextDoc(id: id) { doc in
            guard doc.status == .staged else { return }
            doc.status = .applied
        }
    }

    /// Move a context doc to rejected (from any non-terminal state).
    public static func rejectContextDoc(id: String) throws {
        try mutateContextDoc(id: id) { doc in
            doc.status = .rejected
        }
    }

    /// Read-only: context docs in a given status (sorted by lastSeenAt desc).
    public static func contextDocs(inStatus status: LearnedRuleStatus) -> [LearnedContextDoc] {
        (load() ?? .empty).contextDocs
            .filter { $0.status == status }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Read-only: applied context docs (sorted by lastSeenAt desc, most
    /// recent first). Used by the session-brief integration — the
    /// agent's context is fed by what's currently applied.
    public static func appliedContextDocs() -> [LearnedContextDoc] {
        contextDocs(inStatus: .applied)
    }

    // MARK: - Instruction patch mutations (H+2c)

    /// Merge-on-duplicate observation for instruction patches. Dedup
    /// key is `(toolName, hint)` — same hint for the same tool is the
    /// same observation. Respects `.rejected` stickiness.
    public static func observeInstructionPatch(_ patch: LearnedInstructionPatch) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .instructionPatch(var existing) = artifact else { continue }
            guard existing.toolName == patch.toolName,
                  existing.hint == patch.hint else { continue }
            switch existing.status {
            case .rejected: return
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = patch.lastSeenAt
                for s in patch.sources where !existing.sources.contains(s) {
                    existing.sources.append(s)
                }
                existing.sessionCount = max(existing.sessionCount, patch.sessionCount)
                file.artifacts[idx] = .instructionPatch(existing)
                didMerge = true
            }
            break
        }
        if !didMerge { file.artifacts.append(.instructionPatch(patch)) }
        try save(file)
        shared = file
    }

    public static func promoteInstructionPatchToStaged(id: String) throws {
        try mutateInstructionPatch(id: id) { p in
            guard p.status == .recurring else { return }
            p.status = .staged
        }
    }

    /// Apply ONLY fires when operator confirms — no auto-apply path
    /// anywhere. Schneier constraint enforced at the state machine.
    public static func applyInstructionPatch(id: String) throws {
        try mutateInstructionPatch(id: id) { p in
            guard p.status == .staged else { return }
            p.status = .applied
        }
    }

    public static func rejectInstructionPatch(id: String) throws {
        try mutateInstructionPatch(id: id) { p in p.status = .rejected }
    }

    public static func instructionPatches(inStatus status: LearnedRuleStatus) -> [LearnedInstructionPatch] {
        (load() ?? .empty).instructionPatches
            .filter { $0.status == status }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    public static func appliedInstructionPatches() -> [LearnedInstructionPatch] {
        instructionPatches(inStatus: .applied)
    }

    // MARK: - Workflow playbook mutations (H+2c)

    /// Dedup by `title` (same recipe shape produces same slug). Respects
    /// `.rejected` stickiness.
    public static func observeWorkflowPlaybook(_ playbook: LearnedWorkflowPlaybook) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .workflowPlaybook(var existing) = artifact else { continue }
            guard existing.title == playbook.title else { continue }
            switch existing.status {
            case .rejected: return
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = playbook.lastSeenAt
                for s in playbook.sources where !existing.sources.contains(s) {
                    existing.sources.append(s)
                }
                existing.sessionCount = max(existing.sessionCount, playbook.sessionCount)
                // Refresh steps/description on re-observation so a
                // refined generator pass can update them.
                if !playbook.description.isEmpty {
                    existing.description = LearnedWorkflowPlaybook.sanitizeDescription(playbook.description)
                }
                if !playbook.steps.isEmpty {
                    existing.steps = Array(playbook.steps.prefix(LearnedWorkflowPlaybook.maxSteps))
                }
                file.artifacts[idx] = .workflowPlaybook(existing)
                didMerge = true
            }
            break
        }
        if !didMerge { file.artifacts.append(.workflowPlaybook(playbook)) }
        try save(file)
        shared = file
    }

    public static func promoteWorkflowPlaybookToStaged(id: String) throws {
        try mutateWorkflowPlaybook(id: id) { w in
            guard w.status == .recurring else { return }
            w.status = .staged
        }
    }

    public static func applyWorkflowPlaybook(id: String) throws {
        try mutateWorkflowPlaybook(id: id) { w in
            guard w.status == .staged else { return }
            w.status = .applied
        }
    }

    public static func rejectWorkflowPlaybook(id: String) throws {
        try mutateWorkflowPlaybook(id: id) { w in w.status = .rejected }
    }

    public static func workflowPlaybooks(inStatus status: LearnedRuleStatus) -> [LearnedWorkflowPlaybook] {
        (load() ?? .empty).workflowPlaybooks
            .filter { $0.status == status }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    // MARK: - Private — shared mutation helpers

    private static func mutateContextDoc(
        id: String,
        _ mutate: (inout LearnedContextDoc) -> Void
    ) throws {
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .contextDoc(var doc) = artifact, doc.id == id else { continue }
            mutate(&doc)
            file.artifacts[idx] = .contextDoc(doc)
            try save(file)
            shared = file
            return
        }
    }

    private static func mutateInstructionPatch(
        id: String,
        _ mutate: (inout LearnedInstructionPatch) -> Void
    ) throws {
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .instructionPatch(var p) = artifact, p.id == id else { continue }
            mutate(&p)
            file.artifacts[idx] = .instructionPatch(p)
            try save(file)
            shared = file
            return
        }
    }

    private static func mutateWorkflowPlaybook(
        id: String,
        _ mutate: (inout LearnedWorkflowPlaybook) -> Void
    ) throws {
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .workflowPlaybook(var w) = artifact, w.id == id else { continue }
            mutate(&w)
            file.artifacts[idx] = .workflowPlaybook(w)
            try save(file)
            shared = file
            return
        }
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

    /// Delete all learned rules and reset the file.
    public static func reset() throws {
        let empty = LearnedRulesFile.empty
        try save(empty)
        shared = empty
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

    // MARK: - Queries

    /// Returns only rules currently in applied status as FilterRules.
    public static func loadApplied() -> [LearnedFilterRule] {
        (load() ?? .empty).rules.filter { $0.status == .applied }
    }

    /// Returns rules in `.recurring` status — candidates for the daily sweep.
    public static func loadRecurring() -> [LearnedFilterRule] {
        (load() ?? .empty).rules.filter { $0.status == .recurring }
    }
}
