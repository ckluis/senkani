import Foundation

// MARK: - LearnedRulesStore — façade
//
// Thin façade over the shared `learned-rules.json` cache + four
// per-artifact bounded contexts. The façade owns:
//
//   - `LearnedRuleStatus`     — the lifecycle enum every artifact uses
//   - `LearnedArtifact`       — discriminated union over artifact kinds
//   - `LearnedRulesFile`      — top-level JSON container + migrations
//   - `LearnedRulesStore`     — static persistence (load/save/cache,
//                               `withPath` test override, `reset`)
//
// Per-artifact lifecycle methods live in extensions under
// `Sources/Core/LearnedRules/`:
//
//   - `FilterRuleStore.swift`        — Phase H/H+1/H+2a (filter rules)
//   - `ContextDocStore.swift`        — Phase H+2b (context docs)
//   - `InstructionPatchStore.swift`  — Phase H+2c (instruction patches)
//   - `WorkflowPlaybookStore.swift`  — Phase H+2c (workflow playbooks)
//
// The split was shipped under
// `luminary-2026-04-24-6-learnedrulesstore-split` (2026-04-25). See
// `Sources/Core/Stores/INVARIANTS.md` "LearnedRulesStore invariants"
// for the rules every per-artifact extension must follow.

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

// MARK: - LearnedRulesStore — shared persistence
//
// Static enum holding the on-disk path + in-memory cache used by every
// per-artifact extension. See `Sources/Core/Stores/INVARIANTS.md`
// section "LearnedRulesStore invariants" for the rules.

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

    // MARK: - Singleton cache

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

    /// Delete all learned rules and reset the file.
    public static func reset() throws {
        let empty = LearnedRulesFile.empty
        try save(empty)
        shared = empty
    }
}
