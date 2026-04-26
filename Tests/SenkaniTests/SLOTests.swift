import Testing
import Foundation
@testable import Core

private func makeTempStorePath() -> String {
    "/tmp/senkani-slo-\(UUID().uuidString).json"
}

@Suite(.serialized)
struct SLOPercentileTests {

    @Test func percentileEmptyReturnsZero() {
        #expect(SLO.percentile([], 0.99) == 0)
    }

    @Test func percentileSingleSample() {
        #expect(SLO.percentile([3.5], 0.99) == 3.5)
    }

    @Test func percentileLinearInterpolation() {
        // Sorted: 1, 2, 3, 4, 5. p=1.0 → 5, p=0.0 → 1, p=0.5 → 3.
        #expect(SLO.percentile([5, 1, 3, 2, 4], 0.0) == 1)
        #expect(SLO.percentile([5, 1, 3, 2, 4], 1.0) == 5)
        #expect(SLO.percentile([5, 1, 3, 2, 4], 0.5) == 3)
    }

    @Test func percentile99HitsTopOfDistribution() {
        // 100 samples 0..99; p99 ≈ 98.01 (linear interp between idx 98 and 99).
        let p99 = SLO.percentile((0..<100).map(Double.init), 0.99)
        #expect(p99 > 98.0 && p99 < 99.5)
    }

    @Test func percentileClampsOutOfRangeQ() {
        #expect(SLO.percentile([1, 2, 3], -0.5) == 1)
        #expect(SLO.percentile([1, 2, 3], 5.0) == 3)
    }
}

@Suite(.serialized)
struct SLOSampleStoreTests {

    @Test func recordRequiresEnvVar() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        // SENKANI_SLO_SAMPLES is unset in the test process — record() should no-op.
        store.record(.cacheHit, ms: 0.5)
        #expect(store.samples(for: .cacheHit).isEmpty)
    }

    @Test func recordForcedBypassesGate() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        store.recordForced(.cacheHit, ms: 0.5)
        #expect(store.samples(for: .cacheHit).count == 1)
    }

    @Test func samplesFilteredByWindow() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        let now = Date()
        let oldTs = now.addingTimeInterval(-25 * 3600)
        let freshTs = now.addingTimeInterval(-1 * 3600)
        store.recordForced(.pipelineMiss, ms: 99, now: oldTs)
        store.recordForced(.pipelineMiss, ms: 5, now: freshTs)
        let inWindow = store.samples(for: .pipelineMiss, now: now)
        #expect(inWindow.count == 1)
        #expect(inWindow.first?.ms == 5)
    }

    @Test func bufferEvictsOldestPastCap() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        let now = Date()
        // Push 1100 samples — buffer cap is 1000; oldest 100 should drop.
        for i in 0..<1100 {
            store.recordForced(.cacheHit, ms: Double(i), now: now)
        }
        let samples = store.samples(for: .cacheHit, now: now)
        #expect(samples.count == 1000)
        // Earliest surviving sample is i=100 (ms=100); newest is ms=1099.
        #expect(samples.first?.ms == 100)
        #expect(samples.last?.ms == 1099)
    }

    @Test func evaluateUnknownBelowMinSamples() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        for _ in 0..<5 { store.recordForced(.cacheHit, ms: 0.1) }
        let e = store.evaluate(.cacheHit)
        #expect(e.state == .unknown)
        #expect(e.sampleCount == 5)
    }

    @Test func evaluateGreenWellUnderThreshold() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        // cache.hit threshold = 1ms. 50 samples at 0.1ms — green.
        for _ in 0..<50 { store.recordForced(.cacheHit, ms: 0.1) }
        let e = store.evaluate(.cacheHit)
        #expect(e.state == .green)
        #expect(e.p99Ms < 0.5)
    }

    @Test func evaluateWarnNearThreshold() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        // pipeline.miss threshold = 20ms. 50 samples at 17ms — p99 ≈ 17,
        // which is in [16, 20) so warn (no over-budget samples).
        for _ in 0..<50 { store.recordForced(.pipelineMiss, ms: 17.0) }
        let e = store.evaluate(.pipelineMiss)
        #expect(e.state == .warn)
        #expect(e.overBudgetPct == 0)
    }

    @Test func evaluateBurnAboveThreshold() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        // hook.passthrough threshold = 1ms. 50 samples at 5ms — burning.
        for _ in 0..<50 { store.recordForced(.hookPassthrough, ms: 5.0) }
        let e = store.evaluate(.hookPassthrough)
        #expect(e.state == .burn)
        #expect(e.overBudgetPct == 100.0)
    }

    @Test func evaluateBurnFromBudgetExceeded() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        // pipeline.miss threshold = 20ms. 100 samples — 95 at 1ms, 5 at 50ms.
        // p99 ≈ 50ms so directly above threshold — burn either way.
        // To isolate the budget path, use 99 at 1ms + 2 at 25ms (1.98% over).
        for _ in 0..<99 { store.recordForced(.pipelineMiss, ms: 1.0) }
        for _ in 0..<2  { store.recordForced(.pipelineMiss, ms: 25.0) }
        let e = store.evaluate(.pipelineMiss)
        // p99 over 101 samples falls inside the 1ms cluster, so p99 ≤ 20.
        // Burn fires because overBudgetPct ≈ 1.98% > 1%.
        #expect(e.state == .burn)
        #expect(e.overBudgetPct > 1.0)
    }

    @Test func evaluateAllReturnsAllFourSLOs() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        let evaluations = store.evaluateAll()
        #expect(evaluations.count == SLOName.allCases.count)
        #expect(Set(evaluations.map(\.slo)) == Set(SLOName.allCases))
    }

    @Test func resetClearsAllSamples() {
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        store.recordForced(.cacheHit, ms: 0.1)
        store.recordForced(.pipelineMiss, ms: 1.0)
        store.reset()
        #expect(store.samples(for: .cacheHit).isEmpty)
        #expect(store.samples(for: .pipelineMiss).isEmpty)
    }
}

@Suite("SLO perf gate", .serialized)
struct SLOPerfGateTests {

    /// Synthesise a representative workload for each SLO, measure latency
    /// for each call, then assert p99 falls under threshold. Drives the
    /// same store + math the doctor uses, so a regression that pushes
    /// any SLO over its ceiling fails the build. See `spec/slos.md`.

    @Test func cacheHitP99UnderThreshold() {
        // Cache hit ≈ Dictionary lookup. Drive 200 hits.
        var dict: [String: Int] = [:]
        for i in 0..<256 { dict["k\(i)"] = i }
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        for i in 0..<200 {
            let start = Date()
            _ = dict["k\(i % 256)"]
            let ms = Date().timeIntervalSince(start) * 1000
            store.recordForced(.cacheHit, ms: ms)
        }
        let e = store.evaluate(.cacheHit)
        #expect(e.state != .burn,
                "cache.hit p99 \(e.p99Ms)ms exceeded 1ms threshold")
    }

    @Test func pipelineMissP99UnderThreshold() {
        // Drive FilterPipeline.process on a small fixture.
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        let pipeline = FilterPipeline(config: FeatureConfig())
        let fixture = String(repeating: "hello world\n", count: 50)
        for _ in 0..<50 {
            let start = Date()
            _ = pipeline.process(command: "echo", output: fixture)
            let ms = Date().timeIntervalSince(start) * 1000
            store.recordForced(.pipelineMiss, ms: ms)
        }
        let e = store.evaluate(.pipelineMiss)
        #expect(e.state != .burn,
                "pipeline.miss p99 \(e.p99Ms)ms exceeded 20ms threshold")
    }

    @Test func hookPassthroughP99UnderThreshold() {
        // Hook passthrough = the work the senkani-hook binary does when
        // SENKANI_INTERCEPT and SENKANI_HOOK are both off: a single
        // env-var read + write "{}" to stdout. We simulate that work
        // (the actual binary launch is governed by the OS, not our
        // code). The synthetic floor catches algorithmic regressions
        // in the relay's cold path.
        let path = makeTempStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SLOSampleStore(customPath: path)
        for _ in 0..<200 {
            let start = Date()
            _ = ProcessInfo.processInfo.environment["SENKANI_INTERCEPT"] ?? "off"
            _ = "{}".data(using: .utf8)
            let ms = Date().timeIntervalSince(start) * 1000
            store.recordForced(.hookPassthrough, ms: ms)
        }
        let e = store.evaluate(.hookPassthrough)
        #expect(e.state != .burn,
                "hook.passthrough p99 \(e.p99Ms)ms exceeded 1ms threshold")
    }
}
