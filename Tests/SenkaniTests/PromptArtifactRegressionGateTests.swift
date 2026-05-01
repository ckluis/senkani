import Testing
import Foundation
@testable import Core

@Suite("PromptArtifactRegressionGate (V.4 Bach)")
struct PromptArtifactRegressionGateTests {

    private func sampleCorpus() -> EvalCorpus {
        EvalCorpus(kind: .skill, cases: [
            EvalCase(id: "mentions-purpose",
                     requirement: .mustContain("Purpose:")),
            EvalCase(id: "no-todo-marker",
                     requirement: .mustNotContain("TODO")),
            EvalCase(id: "fits-in-2kb",
                     requirement: .maxLength(bytes: 2048)),
        ])
    }

    // 1. Score reports passing/total/cost faithfully.
    @Test func scoreReportsAllThreeFields() {
        let body = "Purpose: keep secrets safe.\nUsage: senkani audit."
        let art = PromptArtifact(kind: .skill, id: "vault", body: body)
        let s = PromptArtifactRegressionGate.score(art, against: sampleCorpus())
        #expect(s.passing == 3)
        #expect(s.total == 3)
        #expect(s.cost == body.utf8.count)
    }

    // 2. pct collapses to 100 when total == 0 (vacuous truth).
    @Test func pctVacuousOnEmptyCorpus() {
        let s = ArtifactScore(passing: 0, total: 0, cost: 0)
        #expect(s.pct == 100.0)
    }

    // 3. Equal-passing candidate is accepted (cost-only improvement is
    //    legal; the Pareto frontier filters dominated entries).
    @Test func equalPassingAccepted() {
        let corpus = sampleCorpus()
        let baseline = PromptArtifact(kind: .skill, id: "v1",
            body: "Purpose: x. clean body.")
        let candidate = PromptArtifact(kind: .skill, id: "v2",
            body: "Purpose: x.")
        let outcome = PromptArtifactRegressionGate.check(
            candidate: candidate, baseline: baseline, corpus: corpus)
        if case .accepted = outcome { } else {
            Issue.record("expected accepted, got \(outcome)")
        }
    }

    // 4. Strictly-better candidate is accepted.
    @Test func strictlyBetterAccepted() {
        let corpus = sampleCorpus()
        // baseline misses the "Purpose:" requirement.
        let baseline = PromptArtifact(kind: .skill, id: "v1",
            body: "Just a description without the marker.")
        let candidate = PromptArtifact(kind: .skill, id: "v2",
            body: "Purpose: documented now.")
        let outcome = PromptArtifactRegressionGate.check(
            candidate: candidate, baseline: baseline, corpus: corpus)
        guard case .accepted(let s) = outcome else {
            Issue.record("expected accepted, got \(outcome)"); return
        }
        #expect(s.passing == 3)
    }

    // 5. Acceptance criterion 1 — fixture-injected regression rejects.
    //    Baseline passes 3/3, candidate breaks the "no TODO" case → reject.
    @Test func fixtureInjectedRegressionRejected() {
        let corpus = sampleCorpus()
        let baseline = PromptArtifact(kind: .skill, id: "v1",
            body: "Purpose: keep secrets.")
        let candidate = PromptArtifact(kind: .skill, id: "v2",
            body: "Purpose: keep secrets. TODO: ship later.")
        let outcome = PromptArtifactRegressionGate.check(
            candidate: candidate, baseline: baseline, corpus: corpus)
        guard case .rejectedRegressed(let cs, let bs) = outcome else {
            Issue.record("expected rejectedRegressed, got \(outcome)"); return
        }
        #expect(cs.passing == 2)
        #expect(bs.passing == 3)
    }

    // 6. nil baseline always accepts (first-time seed scoring).
    @Test func nilBaselineAccepts() {
        let corpus = sampleCorpus()
        let candidate = PromptArtifact(kind: .skill, id: "seed",
            body: "no purpose marker, has TODO")
        let outcome = PromptArtifactRegressionGate.check(
            candidate: candidate, baseline: nil, corpus: corpus)
        guard case .accepted(let s) = outcome else {
            Issue.record("expected accepted, got \(outcome)"); return
        }
        // Score still reports the failing-cases count so callers can
        // seed a Pareto frontier honestly.
        #expect(s.passing == 1) // only maxLength passes
    }

    // 7. Empty corpus accepts unconditionally — same posture as the
    //    Phase H+1 RegressionGate.
    @Test func emptyCorpusAccepts() {
        let corpus = EvalCorpus(kind: .skill, cases: [])
        let baseline = PromptArtifact(kind: .skill, id: "b", body: "x")
        let candidate = PromptArtifact(kind: .skill, id: "c", body: "y")
        let outcome = PromptArtifactRegressionGate.check(
            candidate: candidate, baseline: baseline, corpus: corpus)
        if case .accepted = outcome { } else {
            Issue.record("expected accepted on empty corpus, got \(outcome)")
        }
    }

    // 8. Requirement.maxLength counts utf8 bytes (multi-byte chars).
    @Test func maxLengthUsesUtf8Bytes() {
        let req = EvalRequirement.maxLength(bytes: 4)
        let three = EvalCase(id: "x", requirement: req)
        // "abc" = 3 bytes → passes
        #expect(three.passes(body: "abc"))
        // "café" = 5 bytes utf8 → fails
        #expect(!three.passes(body: "café"))
    }
}
