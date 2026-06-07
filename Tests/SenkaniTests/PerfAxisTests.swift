import Testing
import Foundation
@testable import Core

/// U.2a-2a contract tests for `PerfAxis.evaluate`. Pure evaluator over a
/// `PerfMeasurement` payload; one test exercises default-threshold pass,
/// over-threshold fail, missing-LCP fail, missing-INP soft-pass, and
/// `PerfExpected` override paths — all branches of the function in one
/// test to keep the U.2a-2a 4-test budget intact.
@Suite("PerfAxis — U.2a-2a evaluator")
struct PerfAxisTests {

    @Test("evaluate covers default thresholds, override, missing-INP soft-pass, missing-LCP hard-fail")
    func evaluateBranches() throws {
        // Branch 1 — both measurements under default thresholds → both pass, no advisory.
        do {
            let m = PerfMeasurement(inpMs: 150, lcpMs: 2000)
            let r = PerfAxis.evaluate(measurement: m)
            #expect(r.count == 2)
            let inp = r.first { $0.assertionId == "perf.inp" }
            let lcp = r.first { $0.assertionId == "perf.lcp" }
            #expect(inp?.passed == true)
            #expect(inp?.measured == 150)
            #expect(inp?.threshold == 200)
            #expect(inp?.advisory == nil)
            #expect(lcp?.passed == true)
            #expect(lcp?.measured == 2000)
            #expect(lcp?.threshold == 2500)
            #expect(lcp?.advisory == nil)
        }

        // Branch 2 — INP over default threshold → fail with structured advisory.
        do {
            let m = PerfMeasurement(inpMs: 300, lcpMs: 2000)
            let r = PerfAxis.evaluate(measurement: m)
            let inp = r.first { $0.assertionId == "perf.inp" }!
            #expect(inp.passed == false)
            #expect(inp.measured == 300)
            #expect(inp.threshold == 200)
            #expect(inp.advisory != nil)
            #expect(inp.advisory!.contains("300ms") && inp.advisory!.contains("200ms"))
        }

        // Branch 3 — `PerfExpected` override raises the threshold so a 300ms INP passes.
        do {
            let m = PerfMeasurement(inpMs: 300, lcpMs: 2000)
            let expected = PerfExpected(inpMs: 500)
            let r = PerfAxis.evaluate(measurement: m, expected: expected)
            let inp = r.first { $0.assertionId == "perf.inp" }!
            #expect(inp.passed == true)
            #expect(inp.threshold == 500)
            #expect(inp.advisory == nil)
        }

        // Branch 4 — INP nil (no qualifying interaction events) → soft-pass with advisory.
        do {
            let m = PerfMeasurement(inpMs: nil, lcpMs: 2400)
            let r = PerfAxis.evaluate(measurement: m)
            let inp = r.first { $0.assertionId == "perf.inp" }!
            #expect(inp.passed == true,
                    "headless runs without interactions must NOT fail INP — only flag with advisory")
            #expect(inp.measured == nil)
            #expect(inp.advisory != nil)
            #expect(inp.advisory!.lowercased().contains("not measured"))
        }

        // Branch 5 — LCP nil → hard-fail (page rendered nothing contentful).
        do {
            let m = PerfMeasurement(inpMs: 100, lcpMs: nil)
            let r = PerfAxis.evaluate(measurement: m)
            let lcp = r.first { $0.assertionId == "perf.lcp" }!
            #expect(lcp.passed == false,
                    "missing LCP is a real regression — must hard-fail, not soft-pass")
            #expect(lcp.measured == nil)
            #expect(lcp.advisory != nil)
            #expect(lcp.advisory!.lowercased().contains("not measured"))
        }
    }
}
