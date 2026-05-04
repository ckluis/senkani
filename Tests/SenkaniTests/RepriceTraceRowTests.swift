import Testing
import Foundation
@testable import Core

@Suite("SessionDatabase.repriceTraceRow")
struct RepriceTraceRowTests {

    private func makeRow(
        model: String? = "claude-sonnet-4",
        costCents: Int = 100,
        costLedgerVersion: Int? = CostLedger.currentVersion
    ) -> AgentTraceEvent {
        AgentTraceEvent(
            idempotencyKey: UUID().uuidString,
            model: model,
            result: "success",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            costCents: costCents,
            costLedgerVersion: costLedgerVersion
        )
    }

    @Test func sameVersionIsExactNoRebase() {
        let row = makeRow(costLedgerVersion: CostLedger.currentVersion)
        let r = SessionDatabase.repriceTraceRow(row)
        #expect(r.confidence == .exact)
        #expect(r.repricedCents == r.originalCents)
        #expect(r.didReprice == false)
        #expect(r.originalVersion == CostLedger.currentVersion)
        #expect(r.currentVersion == CostLedger.currentVersion)
    }

    @Test func nilVersionIsExactNoRebase() {
        // Pre-migration-v16 rows (NULL cost_ledger_version) must NOT be
        // silently rebased — they're priced under the historical static
        // constants which equal v1 by parity. Treat as exact.
        let row = makeRow(costLedgerVersion: nil)
        let r = SessionDatabase.repriceTraceRow(row)
        #expect(r.confidence == .exact)
        #expect(r.repricedCents == r.originalCents)
        #expect(r.originalVersion == nil)
    }

    @Test func unknownModelIsUnsupportedWhenVersionsDiffer() {
        let row = makeRow(model: "no-such-model-xyz",
                          costLedgerVersion: CostLedger.currentVersion + 1)
        let r = SessionDatabase.repriceTraceRow(row)
        #expect(r.confidence == .unsupported)
        #expect(r.repricedCents == r.originalCents)
    }

    @Test func nilModelIsUnsupportedWhenVersionsDiffer() {
        let row = makeRow(model: nil,
                          costLedgerVersion: CostLedger.currentVersion + 1)
        let r = SessionDatabase.repriceTraceRow(row)
        #expect(r.confidence == .unsupported)
    }

    @Test func differentVersionWithMissingHistoricalEntryIsUnsupported() {
        // v999 isn't in the ledger → can't compute the original rate →
        // unsupported. Better than fabricating a number.
        let row = makeRow(model: "claude-sonnet-4", costLedgerVersion: 999)
        let r = SessionDatabase.repriceTraceRow(row)
        #expect(r.confidence == .unsupported)
        #expect(r.repricedCents == r.originalCents)
    }

    @Test func tierRowOverloadComputesSameResultAsCanonicalRow() {
        let tierRow = AgentTraceTierRow(
            idempotencyKey: "k", pane: nil, project: nil,
            model: "claude-sonnet-4", tier: "balanced", ladderPosition: 0,
            feature: "x", result: "success",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            latencyMs: 0, tokensIn: 0, tokensOut: 0,
            costCents: 250, costLedgerVersion: CostLedger.currentVersion
        )
        let r = SessionDatabase.repriceTierRow(tierRow)
        #expect(r.confidence == .exact)
        #expect(r.originalCents == 250)
        #expect(r.repricedCents == 250)
    }
}
