import Testing
import Foundation
@testable import Core

private func tempRoot(_ tag: String = "rlr") -> String {
    let p = "/tmp/senkani-\(tag)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}
private func cleanup(_ root: String) {
    try? FileManager.default.removeItem(atPath: root)
}

@Suite("ReflectiveLearningRun & ParetoFrontier (V.4 Karpathy/Gelman)", .serialized)
struct ReflectiveLearningRunTests {

    private func cheapCorpus() -> EvalCorpus {
        EvalCorpus(kind: .skill, cases: [
            EvalCase(id: "fits-1kb",
                     requirement: .maxLength(bytes: 1024)),
        ])
    }

    // 1. Strict dominance: equal passing AND lower cost = dominate.
    @Test func dominateOnLowerCostSamePassing() {
        var f = ParetoFrontier(kind: .skill)
        let high = ParetoEntry(
            kind: .skill, artifactId: "x", body: "a long body here",
            score: ArtifactScore(passing: 1, total: 1, cost: 200),
            mutatorId: nil)
        let low = ParetoEntry(
            kind: .skill, artifactId: "x", body: "short",
            score: ArtifactScore(passing: 1, total: 1, cost: 5),
            mutatorId: "tiny")
        f.consider(high)
        f.consider(low)
        // `high` is dominated by `low` and must be evicted.
        #expect(f.entries.count == 1)
        #expect(f.entries.first?.body == "short")
    }

    // 2. Non-dominated entries coexist (passing↑ vs cost↓ trade-off).
    @Test func nonDominatedCoexist() {
        var f = ParetoFrontier(kind: .skill)
        let cheap = ParetoEntry(
            kind: .skill, artifactId: "x", body: "a",
            score: ArtifactScore(passing: 1, total: 3, cost: 1),
            mutatorId: nil)
        let smart = ParetoEntry(
            kind: .skill, artifactId: "x", body: "longer body that passes more cases",
            score: ArtifactScore(passing: 3, total: 3, cost: 100),
            mutatorId: "expand")
        f.consider(cheap)
        f.consider(smart)
        #expect(f.entries.count == 2)
    }

    // 3. Ties: equal score + equal cost → second-arrival is rejected as
    //    a duplicate IF body matches; otherwise both retained (mutator
    //    diversity preserved).
    @Test func tiesAreDistinguishedByBody() {
        var f = ParetoFrontier(kind: .skill)
        let s = ArtifactScore(passing: 1, total: 1, cost: 5)
        let a = ParetoEntry(kind: .skill, artifactId: "x", body: "alpha",
                            score: s, mutatorId: "m1")
        let b = ParetoEntry(kind: .skill, artifactId: "x", body: "beta_",
                            score: s, mutatorId: "m2")
        let aDup = ParetoEntry(kind: .skill, artifactId: "x", body: "alpha",
                               score: s, mutatorId: "m3")
        f.consider(a)
        f.consider(b)
        f.consider(aDup)
        #expect(f.entries.count == 2)
        #expect(Set(f.entries.map(\.body)) == ["alpha", "beta_"])
    }

    // 4. Acceptance criterion 2 — Pareto frontier persists per artifact
    //    type and round-trips byte-stably.
    @Test func saveLoadRoundtripsExactly() throws {
        let root = tempRoot("pareto-rt"); defer { cleanup(root) }
        var f = ParetoFrontier(kind: .skill)
        let entry = ParetoEntry(
            kind: .skill, artifactId: "vault",
            body: "Purpose: x.",
            score: ArtifactScore(passing: 2, total: 3, cost: 11),
            mutatorId: "concise_prefix",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        f.consider(entry)
        try f.save(projectRoot: root)
        let loaded = ParetoFrontier.load(kind: .skill, projectRoot: root)
        #expect(loaded == f)
    }

    // 5. Per-artifact-type partition: two kinds saved + loaded
    //    independently.
    @Test func perKindPartition() throws {
        let root = tempRoot("pareto-kind"); defer { cleanup(root) }
        var skill = ParetoFrontier(kind: .skill)
        var hook = ParetoFrontier(kind: .hookPrompt)
        skill.consider(ParetoEntry(
            kind: .skill, artifactId: "s", body: "skill body",
            score: ArtifactScore(passing: 1, total: 1, cost: 10),
            mutatorId: nil))
        hook.consider(ParetoEntry(
            kind: .hookPrompt, artifactId: "h", body: "hook body",
            score: ArtifactScore(passing: 1, total: 1, cost: 9),
            mutatorId: nil))
        try skill.save(projectRoot: root)
        try hook.save(projectRoot: root)

        #expect(ParetoFrontier.load(kind: .skill, projectRoot: root).entries.count == 1)
        #expect(ParetoFrontier.load(kind: .hookPrompt, projectRoot: root).entries.count == 1)
        #expect(ParetoFrontier.load(kind: .skill, projectRoot: root)
            .entries.first?.body == "skill body")
    }

    // 6. Deterministic mutators are pure: same input → same output.
    @Test func deterministicMutatorsArePure() {
        let body = "Purpose: x.\n\nUsage: y."
        for m in DeterministicMutators.suite() {
            #expect(m.mutate(body) == m.mutate(body),
                "mutator \(m.id) must be pure")
        }
    }

    // 7. ReflectiveLearningRun.run includes the seed in the frontier.
    @Test func runIncludesSeed() {
        let seed = PromptArtifact(kind: .skill, id: "v1",
            body: "Purpose: tight body.")
        let f = ReflectiveLearningRun.run(
            seed: seed,
            corpus: cheapCorpus(),
            mutators: [])
        // No mutators → frontier is exactly {seed}.
        #expect(f.entries.count == 1)
        #expect(f.entries.first?.mutatorId == nil)
        #expect(f.entries.first?.body == seed.body)
    }

    // 8. ReflectiveLearningRun.run drops dominated mutations.
    //    `AppendSafetyFooterMutator` strictly grows the body — for a
    //    corpus where the seed already passes everything, the longer
    //    candidate is dominated and must not appear.
    @Test func runDropsDominatedMutations() {
        let seed = PromptArtifact(kind: .skill, id: "v1",
            body: "tight")  // 5 bytes; passes cheapCorpus
        let f = ReflectiveLearningRun.run(
            seed: seed,
            corpus: cheapCorpus(),
            mutators: [DeterministicMutators.AppendSafetyFooterMutator()])
        // Seed dominates the longer mutated candidate (same passing,
        // lower cost) → frontier holds only the seed.
        #expect(f.entries.count == 1)
        #expect(f.entries.first?.mutatorId == nil)
    }

    // 9. Acceptance criterion 3 — CompoundLearning Propose step calls
    //    ReflectiveLearningRun and persists the frontier.
    @Test func compoundLearningRunReflectiveLearningPersists() async throws {
        let root = tempRoot("cl-rl"); defer { cleanup(root) }
        let path = "\(root)/db/senkani.db"
        let db = SessionDatabase(path: path)
        defer { try? FileManager.default.removeItem(atPath: "\(root)/db") }

        let seed = PromptArtifact(kind: .skill, id: "demo",
            body: "Purpose: demo.")
        let corpus = EvalCorpus(kind: .skill, cases: [
            EvalCase(id: "purpose", requirement: .mustContain("Purpose:")),
        ])
        let frontier = try CompoundLearning.runReflectiveLearning(
            seed: seed, corpus: corpus, projectRoot: root,
            mutators: [], db: db)
        #expect(frontier.entries.count >= 1)

        // Frontier file landed on disk.
        let p = ParetoFrontier.path(for: .skill, projectRoot: root)
        #expect(FileManager.default.fileExists(atPath: p))

        // Drain the async event-counter writes.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let runCount = db.eventCounts(prefix: "compound_learning.prompt_artifact.run")
            .reduce(0) { $0 + $1.count }
        #expect(runCount >= 1)
    }

    // 10. Re-running with the same seed + corpus is idempotent — the
    //     frontier doesn't grow on subsequent runs.
    @Test func rerunIsIdempotent() throws {
        let root = tempRoot("cl-idem"); defer { cleanup(root) }
        let path = "\(root)/db/senkani.db"
        let db = SessionDatabase(path: path)
        defer { try? FileManager.default.removeItem(atPath: "\(root)/db") }

        let seed = PromptArtifact(kind: .skill, id: "demo",
            body: "Purpose: demo.")
        let corpus = EvalCorpus(kind: .skill, cases: [
            EvalCase(id: "purpose", requirement: .mustContain("Purpose:")),
        ])
        let f1 = try CompoundLearning.runReflectiveLearning(
            seed: seed, corpus: corpus, projectRoot: root,
            mutators: DeterministicMutators.suite(), db: db)
        let f2 = try CompoundLearning.runReflectiveLearning(
            seed: seed, corpus: corpus, projectRoot: root,
            mutators: DeterministicMutators.suite(), db: db)
        #expect(f1.entries.count == f2.entries.count,
            "second run on identical input must not grow the frontier")
    }

    // 11. ArtifactKind raw values are stable (the persistence path key).
    @Test func artifactKindRawValuesStable() {
        #expect(PromptArtifactKind.skill.rawValue == "skill")
        #expect(PromptArtifactKind.hookPrompt.rawValue == "hook_prompt")
        #expect(PromptArtifactKind.mcpDescription.rawValue == "mcp_description")
        #expect(PromptArtifactKind.briefTemplate.rawValue == "brief_template")
    }

    // 12. ParetoFrontier.path uses the documented layout.
    @Test func paretoFrontierPathLayout() {
        let p = ParetoFrontier.path(for: .briefTemplate, projectRoot: "/tmp/x")
        #expect(p == "/tmp/x/.senkani/learn/pareto/brief_template.json")
    }
}
