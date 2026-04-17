import Testing
import Foundation
@testable import Bundle

// MARK: - BundleEvalTests
//
// Karpathy Phase-6 placeholder: an LLM-driven eval harness for
// `senkani_bundle` output. Sits here as a documented TODO until
// Phase L+1 wires a real eval corpus.
//
// The shape of the eventual eval:
//   1. Fixture projects (real small OSS repos checked in).
//   2. A fixed question set per project — e.g.
//        "Where is authentication handled?"
//        "What database does this use?"
//        "Name the three largest public types."
//   3. For each question, feed BundleComposer's output to a frontier
//      model + the question, grade the answer against a human-labeled
//      reference with an LLM-as-judge or exact-match metric.
//   4. Record per-question pass/fail and overall recall — track
//      across commits so a composer regression shows up as a bundle
//      that answers fewer questions correctly.
//
// Why it's deferred (Jobs + Torvalds):
//   - Requires an LLM call path not present in the unit-test harness.
//   - Requires curated fixtures + labeled ground truth — human work
//     we don't have the bandwidth to do in the H+1 wedge round.
//   - Unit tests already cover determinism, budget, redaction,
//     section order — the mechanics. The eval covers the product
//     question: "does the bundle preserve enough to be useful?"
//
// This test is INTENTIONALLY a no-op — it exists so the file is
// tracked and the TODO surfaces in every `swift test` run.

@Suite("BundleEval (Phase L+1 placeholder)")
struct BundleEvalTests {

    @Test(.disabled("Phase L+1 — requires LLM eval harness + labeled fixture corpus"))
    func bundleAnswersCuratedQuestions() {
        // TODO: Phase L+1 —
        //   1. Load fixture projects from Tests/SenkaniTests/Fixtures/eval/<project>/
        //   2. For each, run `BundleComposer.compose` with budget=20k
        //   3. For each (project, question) pair in the eval set,
        //      call an LLM with bundle + question
        //   4. Grade answer against reference via LLM-as-judge
        //   5. Assert per-project recall ≥ threshold (calibrated from baseline)
        //
        // Until then this test is disabled. The file is here so
        // future contributors see the placeholder and don't re-litigate
        // the "should we add an eval?" question — the answer is yes,
        // later, with real fixtures.
    }

    // A minimal non-disabled test so the suite actually reports a
    // structural signal in CI — catches "did anyone break the
    // placeholder file entirely?"
    @Test func placeholderSuiteCompiles() {
        // Just assert the module imports. If BundleComposer ever moves
        // or rename-breaks Bundle, this fails.
        let _ = BundleComposer.provenanceMarker
    }
}
