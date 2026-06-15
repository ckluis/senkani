import Foundation

/// U.3 (LEG 3) — `TaskClass`: the class-gate vocabulary behind
/// `senkani autorun --allow-classes <comma-list>`.
///
/// Leg 3 lets the operator restrict an unattended run to tasks whose
/// INFERRED class is on an allow-list (e.g. `--allow-classes test-fix,docs`).
/// A task whose class is NOT on a non-empty list pauses for an operator y/n
/// regardless of `--supervise-first`; an out-of-list task in an unattended
/// (no-TTY) run aborts via the fail-safe stdin reader. (NOTE: today the CLI
/// still refuses ANY unattended run up front at the leg-1 Pushover-seed
/// precondition — `pushoverSeededForReal == false` — so the unattended class
/// gate is exercised at the driver layer and becomes reachable through the
/// CLI only once a later leg wires the real Pushover transport.)
///
/// ## JSON-envelope-only (no DB column — deferred)
///
/// `taskClass` lives in the `WorkstreamTaskContract` struct + the
/// `contracts.json` envelope ONLY. The autorun loop persists exclusively to
/// `contracts.json` via `AutorunContractStore` — it never writes the v39
/// `workstream_contracts` SQL table — so leg 3 ships ZERO schema migration.
/// Adding a `task_class` SQL column is deferred to whenever the contract is
/// actually persisted to the table.
///
/// Raw values are stable strings (persisted in `contracts.json` and matched
/// against the `--allow-classes` CSV tokens).
public enum TaskClass: String, Codable, CaseIterable, Sendable {
    case testFix = "test-fix"
    case bugFix = "bug-fix"
    case feature
    case docs
    case refactor
    case chore
    case unknown

    /// Infer a class from a free-form task objective. Pure, lowercased,
    /// FIRST-MATCH-WINS in the precedence order below. The order is
    /// load-bearing — earlier cases shadow later ones:
    ///
    ///   1. test-fix — "flake"/"flaky"/"test". BEFORE bug-fix so "fix flaky
    ///      test" classifies as a test fix, not a bug fix.
    ///   2. docs — "doc"/"docs"/"readme". BEFORE bug-fix so "fix the docs"
    ///      stays docs.
    ///   3. refactor — "refactor". BEFORE bug-fix so a refactor isn't
    ///      shadowed by an incidental "fix".
    ///   4. chore — "chore"/"bump"/"deps". BEFORE bug-fix so "chore: bump
    ///      deps to fix CVE" stays chore.
    ///   5. bug-fix — "fix"/"bug".
    ///   6. feature — "add"/"feature"/"implement".
    ///   7. unknown — no keyword matched (fail-safe default; a nil/unknown
    ///      class under a NON-empty allow-list is NOT allowed).
    ///
    /// Matching is WHOLE-WORD, not substring. The objective is tokenized on
    /// non-alphanumerics and each trigger must equal a whole token. This is
    /// deliberate for a GUARDRAIL: substring matching would WIDEN the
    /// unattended surface past operator intent (the one direction that
    /// matters) — e.g. "doc" inside "dockerfile", "bug" inside "debug", "add"
    /// inside "address", "fix" inside "prefix" would mis-classify a task INTO
    /// an allowed class. An unmatched objective falls through to `.unknown`,
    /// which a non-empty allow-list treats as NOT allowed (it pauses for ack)
    /// — so a missed keyword is a SAFE failure, an over-match is not.
    public static func infer(from objective: String) -> TaskClass {
        let words = Set(
            objective.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        func any(_ triggers: Set<String>) -> Bool { !words.isDisjoint(with: triggers) }

        if any(Self.testFixWords) { return .testFix }
        if any(Self.docsWords) { return .docs }
        if any(Self.refactorWords) { return .refactor }
        if any(Self.choreWords) { return .chore }
        if any(Self.bugFixWords) { return .bugFix }
        if any(Self.featureWords) { return .feature }
        return .unknown
    }

    // Whole-word trigger sets (incl. common plural/inflected forms) for
    // `infer`. Curated to avoid substring over-matches that would widen the
    // unattended surface (see `infer`'s doc). Order of consultation is the
    // precedence order; the sets themselves are disjoint by intent.
    private static let testFixWords: Set<String> = ["flake", "flakes", "flaky", "test", "tests", "testing", "retest"]
    private static let docsWords: Set<String> = ["doc", "docs", "document", "documents", "documentation", "documenting", "readme"]
    private static let refactorWords: Set<String> = ["refactor", "refactors", "refactoring", "refactored"]
    private static let choreWords: Set<String> = ["chore", "chores", "bump", "bumps", "bumping", "bumped", "deps", "dependency", "dependencies"]
    private static let bugFixWords: Set<String> = ["fix", "fixes", "fixing", "fixed", "bug", "bugs"]
    private static let featureWords: Set<String> = ["add", "adds", "adding", "added", "feature", "features", "implement", "implements", "implementing", "implemented"]

    /// Parse a `--allow-classes` CSV into a list of `TaskClass`. Splits on
    /// comma, trims whitespace, maps each token by raw value, and DROPS
    /// unrecognized tokens (forward-compat: a newer file/CLI naming a class
    /// an older binary doesn't know won't choke the parse). Empty/whitespace
    /// input → `[]` (allow-all).
    public static func parseAllowList(_ csv: String) -> [TaskClass] {
        csv
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { TaskClass(rawValue: $0) }
    }
}
