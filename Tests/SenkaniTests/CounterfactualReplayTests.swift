import Testing
import Foundation
import Bench
@testable import Core

private func makeTrace(
    key: String = UUID().uuidString,
    feature: String? = "read",
    result: String = "success",
    tokensIn: Int = 100,
    tokensOut: Int = 1000,
    costCents: Int = 5,
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> AgentTraceEvent {
    AgentTraceEvent(
        idempotencyKey: key,
        feature: feature,
        result: result,
        startedAt: startedAt,
        completedAt: startedAt.addingTimeInterval(0.1),
        tokensIn: tokensIn,
        tokensOut: tokensOut,
        costCents: costCents
    )
}

@Suite("CounterfactualReplay — outline-first-strict")
struct OutlineFirstStrictTests {

    @Test func emptyTraceReportsUnsupported() {
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: [], preset: .outlineFirstStrict
        )
        #expect(report.confidence == .unsupported)
        #expect(report.affectedRowCount == 0)
        #expect(report.savedTokens == 0)
    }

    @Test func reducesReadAndFetchOutputBy90Percent() {
        let rows = [
            makeTrace(feature: "read", tokensOut: 1000, costCents: 10),
            makeTrace(feature: "fetch", tokensOut: 500, costCents: 5),
            makeTrace(feature: "search", tokensOut: 200, costCents: 2),
        ]
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .outlineFirstStrict
        )
        // baseline tokens_out: 1000 + 500 + 200 = 1700
        // counterfactual: 100 (10% of 1000) + 50 (10% of 500) + 200 = 350
        #expect(report.baseline.totalTokensOut == 1700)
        #expect(report.counterfactual.totalTokensOut == 350)
        #expect(report.affectedRowCount == 2)
        #expect(report.confidence == .estimated)
    }

    @Test func skipsCachedRows() {
        let rows = [
            makeTrace(feature: "read", result: "cached", tokensOut: 1000),
            makeTrace(feature: "read", result: "success", tokensOut: 1000),
        ]
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .outlineFirstStrict
        )
        // Only the success row is affected.
        #expect(report.affectedRowCount == 1)
        // Cached: 1000 unchanged. Success: 1000 → 100. Total: 1100.
        #expect(report.counterfactual.totalTokensOut == 1100)
    }

    @Test func deterministicOnRepeatedRuns() {
        let rows = [
            makeTrace(feature: "read", tokensOut: 500),
            makeTrace(feature: "fetch", tokensOut: 300),
        ]
        let r1 = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .outlineFirstStrict,
            now: Date(timeIntervalSince1970: 0)
        )
        let r2 = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .outlineFirstStrict,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(r1 == r2)
    }
}

@Suite("CounterfactualReplay — budget-tight")
struct BudgetTightTests {

    @Test func unsupportedWithoutCap() {
        let rows = [makeTrace(costCents: 10)]
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .budgetTight,
            budgetCapCents: nil
        )
        #expect(report.confidence == .unsupported)
    }

    @Test func underCapReportsExact() {
        let rows = [
            makeTrace(costCents: 10),
            makeTrace(costCents: 20),
        ]
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .budgetTight,
            budgetCapCents: 100
        )
        #expect(report.confidence == .exact)
        #expect(report.affectedRowCount == 0)
        #expect(report.counterfactual.rowCount == 2)
    }

    @Test func cutsAtFirstRowExceedingCap() {
        let rows = [
            makeTrace(costCents: 30),
            makeTrace(costCents: 30),
            makeTrace(costCents: 50),
            makeTrace(costCents: 100),
        ]
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .budgetTight,
            budgetCapCents: 100
        )
        // cumulative: 30, 60, 110 (>100, blocked at idx 2), 210
        // preserved: rows 0..<2 (2 rows, total 60c)
        // affected: 4 - 2 = 2 blocked
        #expect(report.affectedRowCount == 2)
        #expect(report.counterfactual.rowCount == 2)
        #expect(report.counterfactual.totalCostCents == 60)
        #expect(report.confidence == .needsValidation)
    }

    @Test func savedCostsAreNonNegative() {
        let rows = [makeTrace(costCents: 200)]
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .budgetTight,
            budgetCapCents: 50
        )
        #expect(report.savedCostCents >= 0)
        #expect(report.counterfactual.totalCostCents <= report.baseline.totalCostCents)
    }
}

@Suite("ReplayReport — JSON envelope")
struct ReplayReportJSONTests {

    @Test func encodesAndDecodesRoundTrip() throws {
        let rows = [makeTrace(feature: "read", tokensOut: 500)]
        let original = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: rows, preset: .outlineFirstStrict,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReplayReport.self, from: data)
        #expect(decoded == original)
    }

    @Test func emitsKnownConfidenceTierString() throws {
        let report = CounterfactualReplay.evaluate(
            sessionId: "s1", rows: [], preset: .outlineFirstStrict
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"unsupported\""))
    }
}
