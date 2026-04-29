import Foundation

// MARK: - PromptArtifactRegressionGate
//
// Phase V.4 — pre-merge gate for *prompt-side artifacts* (skills,
// hook prompts, MCP tool descriptions, brief templates). Distinct
// from the Phase H+1 `RegressionGate`, which scores `FilterRule`
// savings deltas against `FilterEngine`. They share the
// "rejection-on-regression" intent and nothing else — a candidate
// here is a Markdown / prose body, scored against a labeled eval
// corpus instead of replayed against `FilterEngine`.
//
// Why a separate type:
//   FilterEngine takes a command + raw output and returns filtered
//   bytes. A skill / hook prompt has no comparable runtime — the
//   scoring is structural ("does this body satisfy the corpus
//   requirements?"). Folding both into one `RegressionGate` would
//   force a Sum-type API where every caller pattern-matches the
//   payload. Bach's audit: name and own them separately.
//
// Scoring shape:
//   - `EvalCorpus` = `[EvalCase]`. Each case carries a `Requirement`
//     the artifact body must satisfy.
//   - `Requirement` is the one stable extension surface. V.4 ships
//     three constructors (`mustContain` / `mustNotContain` /
//     `maxLength`); future LLM-driven evaluators (V.4-bis) add a
//     case rather than reshaping the gate.
//   - `Score = (passing, total)` is a binary pass-rate. Gelman's
//     audit: persist `total` so future rounds can compute uncertainty
//     instead of treating "3/3 pass" the same as "300/300 pass."
//   - `cost` = utf8 byte count of the artifact body. Karpathy's
//     audit: a defensible token-cost proxy without committing to a
//     tokenizer in V.4.
//
// Gate semantics:
//   - With no baseline (first-time scoring), accept and report the
//     score so callers can seed a Pareto frontier.
//   - With a baseline, accept iff `candidate.passing ≥ baseline.passing`.
//     Same passing count = accept (cost-only improvement is also
//     valid; the Pareto frontier filters dominated entries downstream).
//   - Empty corpus → accept. No basis to reject — same posture as the
//     filter-rule `RegressionGate`.

public enum PromptArtifactKind: String, Codable, Sendable, CaseIterable {
    /// `~/.claude/skills/<name>/SKILL.md` and project-scoped skills.
    case skill
    /// `senkani-hook` prompt prefixes registered via `HookRegistration`.
    case hookPrompt = "hook_prompt"
    /// MCP tool descriptions surfaced via `senkani-mcp` `tools/list`.
    case mcpDescription = "mcp_description"
    /// `SessionBriefGenerator` template fragments.
    case briefTemplate = "brief_template"
}

public struct PromptArtifact: Sendable, Equatable {
    public let kind: PromptArtifactKind
    public let id: String
    public let body: String

    public init(kind: PromptArtifactKind, id: String, body: String) {
        self.kind = kind
        self.id = id
        self.body = body
    }

    public var cost: Int { body.utf8.count }
}

public enum EvalRequirement: Sendable, Equatable, Codable {
    /// The artifact body must contain this substring (case-sensitive).
    case mustContain(String)
    /// The artifact body must NOT contain this substring.
    case mustNotContain(String)
    /// Total utf8 byte length of the body must be ≤ `bytes`.
    case maxLength(bytes: Int)
}

public struct EvalCase: Sendable, Equatable, Codable {
    public let id: String
    public let requirement: EvalRequirement

    public init(id: String, requirement: EvalRequirement) {
        self.id = id
        self.requirement = requirement
    }

    /// Deterministic, stateless. Returns true iff `body` satisfies the case.
    public func passes(body: String) -> Bool {
        switch requirement {
        case .mustContain(let needle):
            return body.contains(needle)
        case .mustNotContain(let needle):
            return !body.contains(needle)
        case .maxLength(let bytes):
            return body.utf8.count <= bytes
        }
    }
}

public struct EvalCorpus: Sendable, Equatable, Codable {
    public let kind: PromptArtifactKind
    public let cases: [EvalCase]

    public init(kind: PromptArtifactKind, cases: [EvalCase]) {
        self.kind = kind
        self.cases = cases
    }
}

public struct ArtifactScore: Sendable, Equatable, Codable {
    public let passing: Int
    public let total: Int
    public let cost: Int

    public init(passing: Int, total: Int, cost: Int) {
        self.passing = passing
        self.total = total
        self.cost = cost
    }

    /// Pass rate as a percentage (0–100). `total == 0` → 100 (vacuous truth).
    public var pct: Double {
        total == 0 ? 100.0 : Double(passing) / Double(total) * 100.0
    }
}

public enum PromptArtifactGateOutcome: Sendable, Equatable {
    case accepted(ArtifactScore)
    case rejectedRegressed(score: ArtifactScore, baseline: ArtifactScore)
}

public enum PromptArtifactRegressionGate {

    /// Score a single artifact against a corpus. Stateless; corpus must
    /// match `artifact.kind` (caller's responsibility — wrong-kind cases
    /// just fail their requirement and lower the score).
    public static func score(_ artifact: PromptArtifact, against corpus: EvalCorpus) -> ArtifactScore {
        let passing = corpus.cases.reduce(into: 0) { acc, c in
            if c.passes(body: artifact.body) { acc += 1 }
        }
        return ArtifactScore(passing: passing, total: corpus.cases.count, cost: artifact.cost)
    }

    /// Pre-merge gate: accept `candidate` iff its passing-case count is
    /// at least as high as `baseline`'s. `baseline == nil` always accepts
    /// (no prior reference point). Empty corpus accepts unconditionally.
    public static func check(
        candidate: PromptArtifact,
        baseline: PromptArtifact?,
        corpus: EvalCorpus
    ) -> PromptArtifactGateOutcome {
        let candidateScore = score(candidate, against: corpus)
        guard !corpus.cases.isEmpty else { return .accepted(candidateScore) }
        guard let baseline else { return .accepted(candidateScore) }
        let baselineScore = score(baseline, against: corpus)
        if candidateScore.passing < baselineScore.passing {
            return .rejectedRegressed(score: candidateScore, baseline: baselineScore)
        }
        return .accepted(candidateScore)
    }
}
