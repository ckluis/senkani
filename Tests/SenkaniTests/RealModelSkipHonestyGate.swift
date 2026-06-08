import Foundation
@_spi(Experimental) import Testing

/// V.13e-4b — self-enforcing **skip-honesty** guard for the best-effort
/// real-model test family.
///
/// ## The placebo defect this closes
///
/// Every best-effort real-model case
/// (`OpenAIRealCompletionConformanceTests`, `OpenAIChatRealEngineTests`,
/// `OpenAIChatRealEngineSloTests`, `MLXProseCadenceCompilerRealModelTests`)
/// gates on its model's on-disk readiness FIRST and returns silently when
/// the model is absent:
///
/// ```swift
/// guard Self.anyGemmaReady else { return }   // skip — no model on disk
/// ... real #expect assertions ...
/// ```
///
/// In a model-absent run (CI, the autonomous worktree) every case
/// passes-as-skip. The phase-v13e-4b re-audit (2026-05-31, PASS_CLEAN)
/// flagged this as honest-by-CONVENTION but **not self-enforcing**:
/// nothing mechanically prevents a future refactor from greening a case
/// WITHOUT ever entering the model-present branch — silently eroding
/// real-model signal with no test-time alarm.
///
/// ## The invariant (operator decision 2026-06-08, panel D8)
///
/// > GENERALIZE a shared skip-honesty trait across the real-model family,
/// > with V.13e-4b as the reference impl. When the model/weights ARE
/// > present the guard must assert that **a real assertion actually
/// > fired** (NOT a bare entered-branch flag — Bach); when weights are
/// > ABSENT it must be a clean NO-OP (CI-safe, no failure).
///
/// So the guard enforces, per gated test:
///
/// * **weights present** → at least one *genuine* `#expect`/`#require`
///   path must have executed in the body. A bare `enteredBranch = true`
///   flag would NOT satisfy this — the only way to mark the sentinel is
///   to route the assertion through `RealModelGuard.expect(...)` /
///   `.require(...)`, which perform the real Swift Testing assertion AND
///   stamp the sentinel in one indivisible step. A model-present run that
///   enters the branch but fires no real assertion is flagged as a test
///   FAILURE.
/// * **weights absent** → clean NO-OP. The body's leading
///   `guard ... else { return }` returns before any assertion; the trait
///   sees `weightsPresent == false` and never records an issue. CI stays
///   green. This is the fail-safe posture (Allspaw): the guard can only
///   ever go red on a machine that actually has the weights.
///
/// ## Mechanism
///
/// `CustomExecutionTrait` wraps body execution but cannot read a
/// body-local variable. The sentinel is carried out of the body via a
/// task-local reference box (`RealModelGuard.$assertionSink`):
///
/// 1. `.realModelSkipHonesty(weightsPresent:)` binds a fresh sink around
///    the body run, evaluating the per-test `weightsPresent` closure
///    (e.g. `{ anyGemmaReady }` / `{ minilmReady }`).
/// 2. Inside the model-present branch the body asserts through
///    `RealModelGuard.expect(...)` / `.require(...)` — these forward to
///    the real `#expect` / `#require` and, only on that genuine path,
///    set `sink.fired = true`.
/// 3. After the body returns the trait checks: weights present + sink
///    never fired → `Issue.record` (a placebo skip is a real failure).
///    Weights absent → no-op.
///
/// This is the same `@_spi(Experimental) CustomExecutionTrait` shape as
/// `URLProtocolGateTrait` / `FSEventsGateTrait` / `LoggerSinkGateTrait`.
///
/// Migration note: `CustomExecutionTrait` is `@_spi(Experimental)` on
/// swift-testing 0.99.0; Swift Testing 6.0+ renames this to `TestScoping`
/// with a `provideScope` method. Update this file together with
/// `MockURLProtocolGate.swift`, `FSEventsGate.swift`, and
/// `LoggerSinkGate.swift` when the package pin moves.

/// Carries the "a real assertion fired" sentinel out of a test body and
/// up to the trait that wraps it. A reference type so the body and the
/// trait observe the same instance through the task-local binding.
final class RealModelAssertionSink: @unchecked Sendable {
    /// Set to `true` ONLY by `RealModelGuard.expect`/`.require` after a
    /// genuine Swift Testing assertion path has executed. A bare
    /// entered-branch flag cannot set this — there is no public setter
    /// other than the assertion wrappers.
    fileprivate(set) var fired = false

    /// Internal mark — only the guard's assertion wrappers call this, so
    /// the sentinel can never be stamped without an assertion firing.
    fileprivate func markFired() { fired = true }
}

/// Namespace for the skip-honesty guard's task-local sink + the assertion
/// wrappers a real-model body uses inside its model-present branch.
enum RealModelGuard {
    /// Task-local pointer to the active body's sink. Bound by
    /// `RealModelSkipHonestyTrait.execute` around the body run, so any
    /// `RealModelGuard.expect`/`.require` call inside the body resolves
    /// to the same sink the trait inspects afterwards. `nil` outside a
    /// guarded body (the wrappers then behave as plain `#expect`/`#require`).
    @TaskLocal static var assertionSink: RealModelAssertionSink?

    /// Real-model `#expect` — performs the genuine Swift Testing
    /// assertion AND stamps the skip-honesty sentinel. Use this (not a
    /// bare `#expect`) for the load-bearing assertions inside a
    /// model-present branch so the trait can prove a real assertion
    /// fired. Returns the evaluated condition so callers can branch on it.
    @discardableResult
    static func expect(
        _ condition: Bool,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        // Stamp FIRST so the sentinel reflects "this assertion path ran"
        // regardless of pass/fail — the invariant is "a real assertion
        // fired", not "a real assertion passed".
        assertionSink?.markFired()
        #expect(condition, comment, sourceLocation: sourceLocation)
        return condition
    }

    /// Real-model `#require` — performs the genuine unwrap-or-fail AND
    /// stamps the sentinel. Throws (like `#require`) when the value is
    /// nil, so the body's `try` propagates the failure.
    @discardableResult
    static func require<T>(
        _ optionalValue: T?,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> T {
        assertionSink?.markFired()
        return try #require(optionalValue, comment, sourceLocation: sourceLocation)
    }
}

/// `CustomExecutionTrait` that enforces real-model skip-honesty per the
/// V.13e-4b decision. Attach to each gated real-model `@Test` with the
/// per-test readiness predicate.
struct RealModelSkipHonestyTrait: TestTrait, CustomExecutionTrait {
    /// Per-test, not per-suite: each case has its own readiness gate and
    /// its own assertion sink. `isRecursive == false` keeps it from
    /// applying to a whole suite when attached to one test.
    var isRecursive: Bool { false }

    /// Evaluated at execution time (NOT at trait-construction time) so
    /// the readiness check reflects live on-disk model state. `@Sendable`
    /// because the trait body runs on the testing runner's executor.
    let weightsPresent: @Sendable () -> Bool

    @Sendable func execute(
        _ function: @escaping @Sendable () async throws -> Void,
        for test: Test,
        testCase: Test.Case?
    ) async throws {
        let sink = RealModelAssertionSink()
        // Bind the sink for the duration of the body so the body's
        // `RealModelGuard.expect`/`.require` calls reach this instance.
        try await RealModelGuard.$assertionSink.withValue(sink) {
            try await function()
        }

        // Decision is a PURE function (truth table below) so it can be
        // unit-tested without `Issue.record` side effects — see
        // `RealModelSkipHonestyTraitTests`.
        if let violation = Self.violationMessage(
            testName: test.name,
            weightsPresent: weightsPresent(),
            assertionFired: sink.fired
        ) {
            Issue.record(Comment(rawValue: violation))
        }
    }

    /// Pure skip-honesty truth table. Returns the violation text when the
    /// run is a placebo (weights present, no real assertion fired);
    /// returns `nil` (clean) otherwise. Extracted so the decision is
    /// unit-testable in isolation from `Issue.record`.
    ///
    /// | weightsPresent | assertionFired | result                  |
    /// |----------------|----------------|-------------------------|
    /// | false          | false          | nil (CI-safe no-op)     |
    /// | false          | true           | nil (no-op; absent)     |
    /// | true           | true           | nil (real assertion ran)|
    /// | true           | false          | VIOLATION (placebo)     |
    static func violationMessage(
        testName: String,
        weightsPresent: Bool,
        assertionFired: Bool
    ) -> String? {
        // The CI-safe NO-OP path: no weights on disk → the body returned
        // at its leading `guard` before any assertion → never red.
        guard weightsPresent else { return nil }
        // The self-enforcing path: weights ARE present, so the body MUST
        // have routed at least one genuine assertion through the guard.
        // A model-present run that greened without firing a real
        // assertion is exactly the placebo defect this item closes.
        guard !assertionFired else { return nil }
        return """
            real-model skip-honesty violation: '\(testName)' completed \
            with weights PRESENT but no real assertion fired through \
            RealModelGuard. A model-present run must exercise at least \
            one genuine #expect/#require path — a silent green here \
            means the model-present branch was skipped or stripped \
            (the placebo defect from the V.13e-4b re-audit). If this \
            case legitimately has no model-present assertion, remove \
            the .realModelSkipHonesty trait rather than letting it \
            green vacuously.
            """
    }
}

extension Trait where Self == RealModelSkipHonestyTrait {
    /// Self-enforcing skip-honesty guard for a best-effort real-model
    /// test. Pass the test's readiness predicate (e.g.
    /// `{ Self.anyGemmaReady }` / `{ Self.minilmReady }`). When the
    /// predicate is true at run time, the body must fire at least one
    /// `RealModelGuard.expect`/`.require`; when false, the trait is a
    /// clean no-op (CI stays green).
    static func realModelSkipHonesty(
        weightsPresent: @escaping @Sendable () -> Bool
    ) -> Self {
        RealModelSkipHonestyTrait(weightsPresent: weightsPresent)
    }
}
