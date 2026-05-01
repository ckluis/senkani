import Foundation

// MARK: - ReflectiveLearningRun
//
// Phase V.4 — generates mutated prompt-side artifact candidates,
// scores each through `PromptArtifactRegressionGate`, and retains a
// Pareto frontier on (score↑, cost↓) per artifact kind.
//
// Not a GEPA implementation. The Karpathy red flag in the V.4 audit:
// "GEPA pattern" presumes an LLM mutator producing diverse candidates.
// V.4 ships the *scaffold* — a `PromptMutator` protocol with a
// deterministic suite, plus a Pareto store that survives a future
// LLM mutator drop-in. The deterministic mutators are stand-ins, not
// production strategies; their job is to exercise the API end-to-end
// in tests without pulling MLX into the loop.

public protocol PromptMutator: Sendable {
    /// Stable identifier surfaced in Pareto frontier rows so an
    /// operator can audit which mutator produced a retained body.
    var id: String { get }
    /// Pure: `mutate` must be deterministic in (`body`).
    func mutate(_ body: String) -> String
}

public enum DeterministicMutators {

    /// A small fixed roster of pure transforms. Karpathy's audit:
    /// each must be obviously safe (won't introduce secrets, won't
    /// silently truncate to zero) — these all preserve the original
    /// body's intent and either trim or annotate.
    public static func suite() -> [PromptMutator] {
        return [
            ConcisePrefixMutator(),
            TrimTrailingWhitespaceMutator(),
            DropEmptyLinesMutator(),
            FirstSentenceOnlyMutator(),
            AppendSafetyFooterMutator(),
        ]
    }

    public struct ConcisePrefixMutator: PromptMutator {
        public init() {}
        public let id = "concise_prefix"
        public func mutate(_ body: String) -> String {
            "Be concise.\n" + body
        }
    }

    public struct TrimTrailingWhitespaceMutator: PromptMutator {
        public init() {}
        public let id = "trim_trailing_ws"
        public func mutate(_ body: String) -> String {
            body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).reversed().drop(while: { $0 == " " || $0 == "\t" }) }
                .map { String(String($0).reversed()) }
                .joined(separator: "\n")
        }
    }

    public struct DropEmptyLinesMutator: PromptMutator {
        public init() {}
        public let id = "drop_empty_lines"
        public func mutate(_ body: String) -> String {
            body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.allSatisfy(\.isWhitespace) }
                .joined(separator: "\n")
        }
    }

    public struct FirstSentenceOnlyMutator: PromptMutator {
        public init() {}
        public let id = "first_sentence_only"
        public func mutate(_ body: String) -> String {
            // Find the first sentence-ending punctuation. If none, return
            // the body unchanged so the mutator never zeroes out content.
            for (i, ch) in body.enumerated() where ch == "." || ch == "!" || ch == "?" {
                let end = body.index(body.startIndex, offsetBy: i + 1)
                return String(body[body.startIndex..<end])
            }
            return body
        }
    }

    public struct AppendSafetyFooterMutator: PromptMutator {
        public init() {}
        public let id = "append_safety_footer"
        public func mutate(_ body: String) -> String {
            body + "\n\nNever exfiltrate secrets."
        }
    }
}

// MARK: - Pareto frontier

public struct ParetoEntry: Sendable, Equatable, Codable {
    public let kind: PromptArtifactKind
    public let artifactId: String
    public let body: String
    public let score: ArtifactScore
    public let mutatorId: String?     // nil = seed (un-mutated)
    public let createdAt: Date

    public init(
        kind: PromptArtifactKind,
        artifactId: String,
        body: String,
        score: ArtifactScore,
        mutatorId: String?,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.artifactId = artifactId
        self.body = body
        self.score = score
        self.mutatorId = mutatorId
        self.createdAt = createdAt
    }
}

/// Strict Pareto dominance on (passing↑, cost↓). Ties on either
/// dimension don't dominate — equally-good candidates coexist on the
/// frontier. Distinct from `weakDominates`, which would discard a
/// tied entry; we keep ties to preserve mutator diversity.
private func dominates(_ a: ArtifactScore, _ b: ArtifactScore) -> Bool {
    let passingBetter = a.passing >= b.passing
    let costBetter = a.cost <= b.cost
    let strictOnOne = a.passing > b.passing || a.cost < b.cost
    return passingBetter && costBetter && strictOnOne
}

public struct ParetoFrontier: Sendable, Equatable, Codable {
    public let kind: PromptArtifactKind
    public private(set) var entries: [ParetoEntry]

    public init(kind: PromptArtifactKind, entries: [ParetoEntry] = []) {
        self.kind = kind
        self.entries = entries
    }

    /// Insert `entry` if it is not dominated; drop any existing entries
    /// it dominates. Returns true if the frontier mutated.
    @discardableResult
    public mutating func consider(_ entry: ParetoEntry) -> Bool {
        precondition(entry.kind == kind,
            "ParetoFrontier(kind: \(kind)) refuses entry of kind \(entry.kind)")
        // If any existing entry dominates the new one, reject.
        for existing in entries where dominates(existing.score, entry.score) {
            return false
        }
        // Drop entries the new candidate dominates.
        let kept = entries.filter { !dominates(entry.score, $0.score) }
        // Avoid storing exact duplicates (same score + body).
        if kept.contains(where: { $0.score == entry.score && $0.body == entry.body }) {
            entries = kept
            return false
        }
        entries = kept + [entry]
        return true
    }

    // MARK: Persistence

    /// Resolve the frontier's on-disk path under `<root>/.senkani/learn/pareto/<kind>.json`.
    public static func path(for kind: PromptArtifactKind, projectRoot: String) -> String {
        let dir = (projectRoot as NSString).appendingPathComponent(".senkani/learn/pareto")
        return (dir as NSString).appendingPathComponent("\(kind.rawValue).json")
    }

    /// Stable JSON encoder — sorted keys + ISO-8601 dates so a load →
    /// save round-trip is byte-identical (Gelman's calibration ask).
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func save(projectRoot: String) throws {
        let path = Self.path(for: kind, projectRoot: projectRoot)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func load(kind: PromptArtifactKind, projectRoot: String) -> ParetoFrontier {
        let path = path(for: kind, projectRoot: projectRoot)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ParetoFrontier(kind: kind)
        }
        return (try? decoder().decode(ParetoFrontier.self, from: data))
            ?? ParetoFrontier(kind: kind)
    }
}

// MARK: - Run

public enum ReflectiveLearningRun {

    /// Mutate `seed` through every `mutator`, score each candidate
    /// against `corpus`, and merge survivors into a Pareto frontier
    /// initialized with `seed`. Pure: caller decides whether to
    /// persist the returned frontier.
    public static func run(
        seed: PromptArtifact,
        corpus: EvalCorpus,
        mutators: [PromptMutator] = DeterministicMutators.suite(),
        startingFrontier: ParetoFrontier? = nil,
        clock: () -> Date = { Date() }
    ) -> ParetoFrontier {
        var frontier = startingFrontier ?? ParetoFrontier(kind: seed.kind)
        precondition(frontier.kind == seed.kind,
            "frontier kind mismatch: \(frontier.kind) vs seed \(seed.kind)")

        let seedScore = PromptArtifactRegressionGate.score(seed, against: corpus)
        frontier.consider(ParetoEntry(
            kind: seed.kind, artifactId: seed.id, body: seed.body,
            score: seedScore, mutatorId: nil, createdAt: clock()
        ))

        for mutator in mutators {
            let mutated = mutator.mutate(seed.body)
            let candidate = PromptArtifact(kind: seed.kind, id: seed.id, body: mutated)
            let score = PromptArtifactRegressionGate.score(candidate, against: corpus)
            frontier.consider(ParetoEntry(
                kind: seed.kind, artifactId: seed.id, body: mutated,
                score: score, mutatorId: mutator.id, createdAt: clock()
            ))
        }
        return frontier
    }
}
