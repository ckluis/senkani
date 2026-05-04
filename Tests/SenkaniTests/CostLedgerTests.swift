import Testing
import Foundation
@testable import Core

@Suite("CostLedger lookup + versioning")
struct CostLedgerTests {

    @Test func currentVersionIsNonZero() {
        #expect(CostLedger.currentVersion >= 1)
    }

    @Test func returnsNilForUnknownModel() {
        let entry = CostLedger.rate(model: "no-such-model-xyz")
        #expect(entry == nil)
    }

    @Test func findsClaudeSonnet4ByExactMatch() {
        let entry = CostLedger.rate(model: "claude-sonnet-4")
        #expect(entry != nil)
        #expect(entry?.inputPerMillion == 3.0)
        #expect(entry?.outputPerMillion == 15.0)
        #expect(entry?.version == 1)
    }

    @Test func findsByCaseInsensitiveSubstring() {
        let entry = CostLedger.rate(model: "claude-haiku-3.5-20241022")
        #expect(entry != nil)
        #expect(entry?.modelId == "claude-haiku-3.5")
    }

    @Test func everyV1EntryIsCurrentlyActive() {
        for entry in CostLedger.entries(forVersion: 1) {
            let active = CostLedger.rate(model: entry.modelId)
            #expect(active?.modelId == entry.modelId)
            #expect(active?.version == 1)
        }
    }
}

private func makeAgentTraceEvent(
    key: String = UUID().uuidString,
    costLedgerVersion: Int? = nil
) -> AgentTraceEvent {
    AgentTraceEvent(
        idempotencyKey: key,
        result: "success",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date(timeIntervalSince1970: 1_700_000_001),
        costLedgerVersion: costLedgerVersion
    )
}

@Suite("agent_trace_event cost_ledger_version round-trip")
struct AgentTraceCostVersionTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-cost-version-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    @Test func defaultsToCurrentLedgerVersionOnWrite() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let event = makeAgentTraceEvent(costLedgerVersion: nil)
        let inserted = db.recordAgentTraceEvent(event)
        #expect(inserted == true)

        let fetched = db.agentTraceEvent(idempotencyKey: event.idempotencyKey)
        #expect(fetched != nil)
        #expect(fetched?.costLedgerVersion == CostLedger.currentVersion)
    }

    @Test func preservesExplicitVersion() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let event = makeAgentTraceEvent(costLedgerVersion: 1)
        db.recordAgentTraceEvent(event)
        let fetched = db.agentTraceEvent(idempotencyKey: event.idempotencyKey)
        #expect(fetched?.costLedgerVersion == 1)
    }
}
