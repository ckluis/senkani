import Testing
import Foundation
@testable import Bench
import Core

/// T.2 carve child A (`phase-t2-pii-bench-target-2026-06-09`) — pins
/// the headless `senkani bench pii` harness:
///   1. cold path runs ONCE (backend.load exactly one call, folded
///      into the cold timing window),
///   2. warm path REUSES the loaded backend (N samples, zero reloads),
///   3. output shape is stable + renders in the existing Bench format.
/// No MLX, no network, no weights — everything goes through the
/// injected `PIIBenchBackend` seam.
@Suite("PIIBenchRunner — headless pii bench harness")
struct PIIBenchRunnerTests {

    /// Thread-safe call counter so the @Sendable backend closures can
    /// record load/detect invocations.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var loadCount = 0
        private var detectCount = 0

        func bumpLoad() { lock.lock(); loadCount += 1; lock.unlock() }
        func bumpDetect() { lock.lock(); detectCount += 1; lock.unlock() }
        var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
        var detects: Int { lock.lock(); defer { lock.unlock() }; return detectCount }
    }

    /// Counting backend whose spans satisfy the shape sweep: one span
    /// covering the fixture's first token ("Contact", chars [0, 7)).
    private func countingBackend(_ counter: CallCounter) -> PIIBenchBackend {
        PIIBenchBackend(
            load: { counter.bumpLoad() },
            detectSpans: { text, _ in
                counter.bumpDetect()
                let prefix = String(text.prefix(7))
                return [PIISpan(
                    category: .privatePerson,
                    score: 0.99,
                    charStart: 0,
                    charEnd: 7,
                    text: prefix
                )]
            }
        )
    }

    // 1. Cold path runs once.
    @Test("cold path loads the backend exactly once; first call is folded into the cold window")
    func coldPathRunsOnce() throws {
        let counter = CallCounter()
        let measurement = try PIIBenchRunner.run(
            backend: countingBackend(counter),
            warmIterations: 5
        )
        #expect(counter.loads == 1)
        // 1 cold call + 5 warm calls — load is NOT re-invoked per call.
        #expect(counter.detects == 6)
        #expect(measurement.coldMs >= 0)
        #expect(measurement.shapeOK)
    }

    // 2. Warm path reuses the loaded backend.
    @Test("warm path reuses: N warm samples, zero additional loads, rows in bench format")
    func warmPathReusesLoadedBackend() throws {
        let counter = CallCounter()
        let measurement = try PIIBenchRunner.run(
            backend: countingBackend(counter),
            warmIterations: 8
        )
        #expect(counter.loads == 1)
        #expect(measurement.warmSamplesMs.count == 8)
        #expect(measurement.warmSamplesMs.allSatisfy { $0 >= 0 })
        #expect(measurement.warmMedianMs >= 0)

        // The report folds the measurement into the existing Bench row
        // shape: cold, warm, shape — all under the `pii` category with
        // the stub config column.
        let report = PIIBenchRunner.report(measurement: measurement)
        #expect(report.results.map(\.taskId) == [
            PIIBenchRunner.coldTaskId,
            PIIBenchRunner.warmTaskId,
            PIIBenchRunner.shapeTaskId,
        ])
        #expect(report.results.allSatisfy { $0.category == PIIBenchRunner.category })
        #expect(report.results.allSatisfy { $0.configName == PIIBenchRunner.stubConfigName })
        // Latency rows make no savings claim (raw == compressed) and
        // carry .estimated confidence — stub latency shape, not
        // real-model perf.
        #expect(report.results[0].savedBytes == 0)
        #expect(report.results[0].confidence == .estimated)
        #expect(report.results[2].confidence == .exact)
        #expect(report.confidence == .estimated)
    }

    // 3. Output shape stable.
    @Test("stub backend output shape is stable across runs and passes the shape gate")
    func outputShapeStable() throws {
        let first = try PIIBenchRunner.run(
            backend: PIIBenchRunner.stubBackend(),
            warmIterations: 4
        )
        let second = try PIIBenchRunner.run(
            backend: PIIBenchRunner.stubBackend(),
            warmIterations: 4
        )

        // Shape sweep green, and byte-identical spans across fresh
        // backend instances (determinism contract).
        #expect(first.shapeIssues.isEmpty)
        #expect(first.spans == second.spans)

        // The stub drives the REAL BIOES/Viterbi decoder: expect the
        // fixture's person + email spans, ascending, substring-exact.
        #expect(first.spans.map(\.category) == [.privatePerson, .privateEmail])
        #expect(first.spans.map(\.text) == ["Maria Rojas", "maria.rojas@example.net"])
        #expect(first.spans.allSatisfy { $0.score >= 0.85 && $0.score <= 1.0 })

        // Rendered through the EXISTING Bench reporter, the three pii
        // rows surface and the shape quality gate passes.
        let report = PIIBenchRunner.report(measurement: first)
        let text = BenchmarkReporter.textReport(report)
        #expect(text.contains("pii: pii_cold_start"))
        #expect(text.contains("pii: pii_warm_call"))
        #expect(text.contains("pii: pii_output_shape"))
        #expect(report.allGatesPassed)
        #expect(report.gates.map(\.name) == ["pii_output_shape"])

        // Negative arm: a malformed span trips the sweep (and a
        // non-deterministic backend would append a stability issue).
        let bad = PIIBenchRunner.shapeIssues(
            spans: [PIISpan(category: .secret, score: 1.5, charStart: 5, charEnd: 2, text: "x")],
            fixture: PIIBenchRunner.fixtureText
        )
        #expect(!bad.isEmpty)
    }
}
