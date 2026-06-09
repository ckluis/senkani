import Testing
import Foundation
@_spi(Experimental) @testable import Testing
@testable import Core

/// V.13e-4b — unit tests for the self-enforcing real-model skip-honesty
/// guard (`RealModelSkipHonestyTrait` + `RealModelGuard`).
///
/// These tests prove the guard is *capable of failing* (James Bach: a
/// test that can never go red proves nothing) while staying a clean
/// no-op in the CI reality (no weights on disk — Allspaw's fail-safe).
/// They run with NO model present, so they exercise the same code path
/// CI hits.
///
/// The decision logic is tested through the PURE
/// `RealModelSkipHonestyTrait.violationMessage(...)` truth table rather
/// than by letting the trait call `Issue.record` (which would fail the
/// host test). The sentinel-marking mechanics are tested by binding the
/// task-local sink directly and observing that ONLY a genuine
/// `RealModelGuard.expect`/`.require` path stamps it.
@Suite("RealModel skip-honesty guard (V.13e-4b)")
struct RealModelSkipHonestyTraitTests {

    // MARK: - 1. Truth table — the guard's decision

    /// CI reality: weights ABSENT → always a clean no-op, whether or not
    /// any assertion fired. This is the path every CI / autonomous-
    /// worktree run takes, and it must NEVER be red (Allspaw).
    @Test("weights absent is a clean no-op regardless of assertions (CI-safe)")
    func weightsAbsentIsNoOp() {
        #expect(
            RealModelSkipHonestyTrait.violationMessage(
                testName: "any", weightsPresent: false, assertionFired: false
            ) == nil
        )
        #expect(
            RealModelSkipHonestyTrait.violationMessage(
                testName: "any", weightsPresent: false, assertionFired: true
            ) == nil
        )
    }

    /// Weights PRESENT + a real assertion fired → clean (the happy
    /// model-present path on operator hardware).
    @Test("weights present with a real assertion fired is clean")
    func weightsPresentWithAssertionIsClean() {
        #expect(
            RealModelSkipHonestyTrait.violationMessage(
                testName: "any", weightsPresent: true, assertionFired: true
            ) == nil
        )
    }

    /// THE load-bearing case (Bach): weights PRESENT but NO real
    /// assertion fired → the guard MUST flag a violation. This is the
    /// placebo defect the item closes — a model-present run that greened
    /// without proving anything. If this returned nil the guard would be
    /// incapable of failing and thus worthless.
    @Test("weights present without a real assertion is flagged as a violation")
    func weightsPresentWithoutAssertionIsViolation() {
        let msg = RealModelSkipHonestyTrait.violationMessage(
            testName: "placeboTest", weightsPresent: true, assertionFired: false
        )
        let unwrapped = try! #require(msg)
        #expect(unwrapped.contains("skip-honesty violation"))
        #expect(unwrapped.contains("placeboTest"))
        #expect(unwrapped.contains("no real assertion fired"))
    }

    // MARK: - 2. Sentinel mechanics — only a genuine assertion stamps it

    /// A bare entered-branch flag CANNOT mark the sink — there is no
    /// public setter on `RealModelAssertionSink` other than the assertion
    /// wrappers. A fresh sink starts unfired.
    @Test("a fresh sink is unfired; there is no bare-flag setter")
    func freshSinkIsUnfired() {
        let sink = RealModelAssertionSink()
        #expect(sink.fired == false)
    }

    /// `RealModelGuard.expect` stamps the bound sink — and only the bound
    /// sink — when it runs a genuine #expect path.
    @Test("RealModelGuard.expect marks the bound sink on a genuine assertion path")
    func guardExpectMarksSink() async {
        let sink = RealModelAssertionSink()
        #expect(sink.fired == false)
        await RealModelGuard.$assertionSink.withValue(sink) {
            RealModelGuard.expect(1 + 1 == 2, "trivially true so the host test stays green")
        }
        #expect(sink.fired == true, "a genuine RealModelGuard.expect path must stamp the sink")
    }

    /// `RealModelGuard.require` stamps the bound sink when it unwraps a
    /// non-nil value (the genuine #require path).
    @Test("RealModelGuard.require marks the bound sink when it unwraps")
    func guardRequireMarksSink() async throws {
        let sink = RealModelAssertionSink()
        try await RealModelGuard.$assertionSink.withValue(sink) {
            let value: Int? = 42
            let unwrapped = try RealModelGuard.require(value)
            #expect(unwrapped == 42)
        }
        #expect(sink.fired == true, "a genuine RealModelGuard.require path must stamp the sink")
    }

    /// Outside a bound sink (no task-local), the wrappers behave as plain
    /// `#expect`/`#require` and simply no-op the stamp — they never crash
    /// on a nil sink. (Defends against accidental use outside the trait.)
    @Test("RealModelGuard wrappers no-op the stamp when no sink is bound")
    func guardWrappersTolerateNoBoundSink() throws {
        // No withValue → assertionSink is nil here.
        RealModelGuard.expect(true)
        let unwrapped = try RealModelGuard.require(Optional<Int>.some(7))
        #expect(unwrapped == 7)
    }

    // MARK: - 3. End-to-end through the real Issue.record machinery

    /// Drives the ACTUAL `RealModelSkipHonestyTrait.execute` against a
    /// simulated model-present run whose body fires NO real assertion, and
    /// asserts — via Swift Testing's own `recordIssue` capture
    /// (`withKnownIssue` would mask it; we instead count issues through a
    /// nested configuration) — that the trait records an issue. This is
    /// the integration proof that the wired trait WOULD turn a placebo
    /// model-present run red.
    ///
    /// We can't let the recorded issue fail THIS test, so we run the
    /// trait body inside `withKnownIssue` and assert the known issue was
    /// matched (i.e. an issue WAS recorded). A clean run (no issue) makes
    /// `withKnownIssue` itself fail, which is exactly the negative signal
    /// we want to detect a broken guard.
    @Test("execute records an issue for a simulated model-present run that fires no assertion")
    func executeFlagsSimulatedPlaceboRun() async throws {
        let trait = RealModelSkipHonestyTrait(weightsPresent: { true })  // simulate model present
        await withKnownIssue("trait must flag a model-present run that fires no real assertion") {
            try await trait.execute(
                {
                    // Body enters the "model-present branch" but fires NO
                    // RealModelGuard assertion — the placebo defect.
                    _ = 1 + 1
                },
                for: try #require(Test.current),
                testCase: Test.Case.current
            )
        }
    }

    /// The mirror image: a simulated model-present run that DOES fire a
    /// real assertion records NO skip-honesty issue. (The body's own
    /// `RealModelGuard.expect(true)` is a passing assertion, so the only
    /// way this test goes red is if the trait spuriously records a
    /// violation — proving no false-positive.)
    @Test("execute records no skip-honesty issue when a real assertion fired")
    func executeCleanWhenAssertionFired() async throws {
        let trait = RealModelSkipHonestyTrait(weightsPresent: { true })
        // No withKnownIssue: if the trait spuriously recorded a violation
        // here, THIS test would fail.
        try await trait.execute(
            {
                RealModelGuard.expect(true, "genuine model-present assertion")
            },
            for: try #require(Test.current),
            testCase: Test.Case.current
        )
    }

    /// And the CI path end-to-end: weights ABSENT + no assertion → the
    /// trait records nothing. This is the exact full-suite condition.
    @Test("execute is a clean no-op end-to-end when weights are absent")
    func executeNoOpWhenWeightsAbsent() async throws {
        let trait = RealModelSkipHonestyTrait(weightsPresent: { false })
        try await trait.execute(
            {
                // Mirrors a gated body returning at its leading guard.
            },
            for: try #require(Test.current),
            testCase: Test.Case.current
        )
    }
}
