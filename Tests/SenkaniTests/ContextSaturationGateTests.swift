import Testing
import Foundation
@testable import Core

@Suite("ContextSaturationGate — W.4 saturation decision")
struct ContextSaturationGateTests {

    private func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-saturation-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("ok decision below warn threshold")
    func okBelowWarn() {
        let d = ContextSaturationGate.evaluate(
            currentTokens: 50_000,
            threshold: .default
        )
        #expect(d == .ok(percent: 0.25))
    }

    @Test("warn decision between warn and block thresholds")
    func warnBand() {
        // 70 % usage at the default 200 000 budget (0.65 ≤ 0.70 < 0.80).
        let d = ContextSaturationGate.evaluate(
            currentTokens: 140_000,
            threshold: .default
        )
        if case .warn(let p) = d {
            #expect(abs(p - 0.7) < 0.0001)
        } else {
            Issue.record("expected .warn, got \(d)")
        }
    }

    @Test("block decision at and above the block threshold, with reason text")
    func blockAtThreshold() {
        let d = ContextSaturationGate.evaluate(
            currentTokens: 160_000,
            threshold: .default
        )
        guard case .block(let p, let reason) = d else {
            Issue.record("expected .block, got \(d)"); return
        }
        #expect(abs(p - 0.8) < 0.0001)
        #expect(reason.contains("80%"))
        #expect(reason.contains("handoff"))
        #expect(d.isBlocking)
    }

    @Test("custom thresholds override the defaults")
    func customThresholds() {
        let custom = ContextSaturationGate.Threshold(warnAt: 0.5, blockAt: 0.6, budgetTokens: 1_000)
        #expect(ContextSaturationGate.evaluate(currentTokens: 400, threshold: custom) == .ok(percent: 0.4))
        if case .warn = ContextSaturationGate.evaluate(currentTokens: 550, threshold: custom) {
        } else { Issue.record("expected warn at 55%") }
        if case .block = ContextSaturationGate.evaluate(currentTokens: 700, threshold: custom) {
        } else { Issue.record("expected block at 70%") }
    }

    @Test("zero / negative budget falls back to ok rather than escalating")
    func malformedBudget() {
        let zero = ContextSaturationGate.Threshold(warnAt: 0.5, blockAt: 0.8, budgetTokens: 0)
        #expect(ContextSaturationGate.evaluate(currentTokens: 99_999, threshold: zero) == .ok(percent: 0))

        let neg = ContextSaturationGate.Threshold(warnAt: 0.5, blockAt: 0.8, budgetTokens: -1)
        #expect(ContextSaturationGate.evaluate(currentTokens: 99_999, threshold: neg) == .ok(percent: 0))
    }

    @Test("DB-backed evaluate sums tokens_in + tokens_out for the pane window")
    func dbBackedDerivation() {
        let (db, path) = tempDB()
        defer { cleanup(path) }

        // Three rows in pane "kb" — total tokens 100+50 + 200+100 + 50+25 = 525.
        // One row in pane "shell" should NOT be summed.
        let now = Date()
        db.recordAgentTraceEvent(.init(
            idempotencyKey: "k1", pane: "kb", project: "/p", model: "m",
            tier: nil, feature: "f", result: "success",
            startedAt: now, completedAt: now,
            latencyMs: 1, tokensIn: 100, tokensOut: 50
        ))
        db.recordAgentTraceEvent(.init(
            idempotencyKey: "k2", pane: "kb", project: "/p", model: "m",
            tier: nil, feature: "f", result: "success",
            startedAt: now, completedAt: now,
            latencyMs: 1, tokensIn: 200, tokensOut: 100
        ))
        db.recordAgentTraceEvent(.init(
            idempotencyKey: "k3", pane: "kb", project: "/p", model: "m",
            tier: nil, feature: "f", result: "success",
            startedAt: now, completedAt: now,
            latencyMs: 1, tokensIn: 50, tokensOut: 25
        ))
        db.recordAgentTraceEvent(.init(
            idempotencyKey: "k4", pane: "shell", project: "/p", model: "m",
            tier: nil, feature: "f", result: "success",
            startedAt: now, completedAt: now,
            latencyMs: 1, tokensIn: 9_999, tokensOut: 9_999
        ))

        // Tiny budget so 525 tokens pushes us into the warn band.
        let threshold = ContextSaturationGate.Threshold(warnAt: 0.4, blockAt: 0.9, budgetTokens: 1_000)
        let d = ContextSaturationGate.evaluate(database: db, pane: "kb", threshold: threshold)
        guard case .warn(let p) = d else {
            Issue.record("expected warn for 525/1000, got \(d)"); return
        }
        #expect(abs(p - 0.525) < 0.0001)
    }
}
