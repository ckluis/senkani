import Testing
import Foundation
@testable import Core

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-policy-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeConfig(
    filter: Bool = true,
    indexer: Bool = true,
    perSessionLimitCents: Int? = nil,
    modelTier: String? = "claude-haiku-4-5"
) -> PolicyConfig {
    PolicyConfig(
        features: PolicyFeatures(
            filter: filter, secrets: true, indexer: indexer,
            terse: false, injectionGuard: true
        ),
        budget: PolicyBudget(
            perSessionLimitCents: perSessionLimitCents,
            dailyLimitCents: nil,
            weeklyLimitCents: nil,
            softLimitPercent: 0.8
        ),
        learnedRulesHash: "abc123",
        modelTier: modelTier,
        agentType: "claude_code",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Suite("PolicyStore round-trip")
struct PolicyStoreTests {

    @Test func capturesAndReadsBack() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg = makeConfig()

        let inserted = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        #expect(inserted == true)

        let row = db.latestPolicySnapshot(sessionId: sid)
        #expect(row != nil)
        #expect(row?.policyHash == cfg.policyHash())
        let decoded = row?.decoded()
        #expect(decoded?.features.filter == true)
        #expect(decoded?.modelTier == "claude-haiku-4-5")
        #expect(decoded?.learnedRulesHash == "abc123")
    }

    @Test func dedupsIdenticalCaptures() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg = makeConfig()

        let first = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        let second = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        #expect(first == true)
        #expect(second == false)

        let all = db.allPolicySnapshots(sessionId: sid)
        #expect(all.count == 1)
    }

    @Test func differentConfigsMakeDifferentRows() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg1 = makeConfig(filter: true)
        let cfg2 = makeConfig(filter: false)
        #expect(cfg1.policyHash() != cfg2.policyHash())

        db.recordPolicySnapshot(sessionId: sid, config: cfg1)
        db.recordPolicySnapshot(sessionId: sid, config: cfg2)

        let all = db.allPolicySnapshots(sessionId: sid)
        #expect(all.count == 2)
    }

    @Test func policyHashIsStableAcrossInstances() {
        let cfg1 = makeConfig()
        let cfg2 = makeConfig()
        #expect(cfg1.policyHash() == cfg2.policyHash())
    }

    @Test func capturedAtIsExcludedFromHash() {
        let cfg1 = PolicyConfig(
            features: PolicyFeatures(filter: true, secrets: true, indexer: true,
                                     terse: false, injectionGuard: true),
            budget: PolicyBudget(perSessionLimitCents: 100, dailyLimitCents: nil,
                                 weeklyLimitCents: nil, softLimitPercent: 0.8),
            learnedRulesHash: "h",
            modelTier: nil,
            agentType: nil,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let cfg2 = PolicyConfig(
            features: cfg1.features, budget: cfg1.budget,
            learnedRulesHash: cfg1.learnedRulesHash,
            modelTier: cfg1.modelTier, agentType: cfg1.agentType,
            capturedAt: Date(timeIntervalSince1970: 999_999)
        )
        #expect(cfg1.policyHash() == cfg2.policyHash())
    }
}
