import Foundation
import Testing

/// Shared perf-gate decision for the micro-benchmark suites.
///
/// PASS iff the least-contended (minimum) sample is under budget. The
/// minimum is the true performance floor: under parallel-runner CPU/IO
/// contention any single sample can spike past budget (`.serialized` only
/// serializes within-suite, not against peer suites), but a genuine
/// regression slows EVERY sample so the minimum still trips the gate
/// (pinned by `PerfGateTests.everySampleOverBudgetFails`). An empty sample
/// set is treated as failure so a gate can never be silently disabled by a
/// missing measurement.
///
/// This replaced the prior median-of-3 pattern: the median of three
/// contended samples can itself blow budget on a healthy machine. The flake
/// was fixed for the whole-tree build gate by
/// `dependency-graph-perf-gate-flake-under-build-load-2026-05-27` and swept
/// across the 19 sibling micro-benchmark gates by
/// `perf-gate-min-of-n-robustness-sweep-remaining-gates-2026-05-27`.
/// `DependencyGraphPerfGateTests` is the canonical caller.
///
/// Generic over `Comparable` so it serves both `[Double]` / `[TimeInterval]`
/// (millisecond / second budgets) and `[Duration]` (`.milliseconds(N)`)
/// sample sets unchanged.
enum PerfGate {
    static func passes<T: Comparable>(samples: [T], budget: T) -> Bool {
        guard let fastest = samples.min() else { return false }
        return fastest < budget
    }
}

@Suite("PerfGate — shared min-of-N decision")
struct PerfGateTests {

    @Test("Least-contended sample under budget passes")
    func minimumUnderBudgetPasses() {
        // One contended sample among fast ones must PASS — the minimum
        // reflects the true floor. This is exactly the flake the min-of-N
        // sweep fixes (a median of these three would blow budget). Covers
        // both type families the 19 gates use.
        #expect(PerfGate.passes(samples: [8.0, 0.2, 0.3], budget: 5.0))
        #expect(PerfGate.passes(
            samples: [Duration.seconds(8), .milliseconds(200), .milliseconds(300)],
            budget: .seconds(5)
        ))
    }

    @Test("Every sample over budget fails")
    func everySampleOverBudgetFails() {
        // A genuine O(N²)-class regression slows EVERY sample, so even the
        // minimum exceeds budget — the gate MUST still fail. Guards against
        // the robustness change silently disabling any gate.
        #expect(!PerfGate.passes(samples: [6.0, 7.0, 8.0], budget: 5.0))
        #expect(!PerfGate.passes(
            samples: [Duration.seconds(6), .seconds(7), .seconds(8)],
            budget: .seconds(5)
        ))
    }

    @Test("Empty sample set fails")
    func emptySampleSetFails() {
        // No measurement can never silently disable a gate — both families.
        #expect(!PerfGate.passes(samples: [Double](), budget: 5.0))
        #expect(!PerfGate.passes(samples: [Duration](), budget: .seconds(5)))
    }
}
