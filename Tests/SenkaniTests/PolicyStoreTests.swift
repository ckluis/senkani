import Testing
import Foundation
@testable import Core

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-policy-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
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

    @Test func capturesAndReadsBack() throws {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg = makeConfig()

        let inserted = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        #expect(inserted == true)

        let row = db.latestPolicySnapshot(sessionId: sid)
        #expect(row != nil)
        let expectedHash = try cfg.policyHash()
        #expect(row?.policyHash == expectedHash)
        let decoded = row?.decoded()
        #expect(decoded?.features.filter == true)
        #expect(decoded?.modelTier == "claude-haiku-4-5")
        #expect(decoded?.learnedRulesHash == "abc123")
    }

    @Test func dedupsIdenticalCaptures() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg = makeConfig()

        let first = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        let second = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        #expect(first == true)
        #expect(second == false)

        let all = db.allPolicySnapshots(sessionId: sid)
        #expect(all.count == 1)
    }

    @Test func differentConfigsMakeDifferentRows() throws {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg1 = makeConfig(filter: true)
        let cfg2 = makeConfig(filter: false)
        let h1 = try cfg1.policyHash()
        let h2 = try cfg2.policyHash()
        #expect(h1 != h2)

        db.recordPolicySnapshot(sessionId: sid, config: cfg1)
        db.recordPolicySnapshot(sessionId: sid, config: cfg2)

        let all = db.allPolicySnapshots(sessionId: sid)
        #expect(all.count == 2)
    }

    @Test func policyHashIsStableAcrossInstances() throws {
        let cfg1 = makeConfig()
        let cfg2 = makeConfig()
        let h1 = try cfg1.policyHash()
        let h2 = try cfg2.policyHash()
        #expect(h1 == h2)
    }

    @Test func capturedAtIsExcludedFromHash() throws {
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
        let h1 = try cfg1.policyHash()
        let h2 = try cfg2.policyHash()
        #expect(h1 == h2)
    }
}

// MARK: - Hash failure paths (policy-hash-no-silent-empty)

/// Builds a `PolicyConfig` whose `softLimitPercent` is `.nan`. The
/// default `JSONEncoder` rejects non-finite floating-point values,
/// which gives us a deterministic encoder failure to drive the
/// `policyHash() throws` and `PolicyStore.capture` refusal paths.
private func makeConfigWithUnencodableBudget() -> PolicyConfig {
    PolicyConfig(
        features: PolicyFeatures(
            filter: true, secrets: true, indexer: true,
            terse: false, injectionGuard: true
        ),
        budget: PolicyBudget(
            perSessionLimitCents: nil,
            dailyLimitCents: nil,
            weeklyLimitCents: nil,
            softLimitPercent: .nan
        ),
        learnedRulesHash: "abc123",
        modelTier: "claude-haiku-4-5",
        agentType: "claude_code",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Suite("PolicyConfig hash failure handling")
struct PolicyHashFailureTests {

    @Test func policyHashThrowsOnEncoderFailure() {
        let cfg = makeConfigWithUnencodableBudget()
        #expect(throws: PolicyHashError.self) {
            _ = try cfg.policyHash()
        }
    }

    @Test func captureRefusesInsertAndBumpsCounterOnHashFailure() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfg = makeConfigWithUnencodableBudget()

        let inserted = db.recordPolicySnapshot(sessionId: sid, config: cfg)
        #expect(inserted == false)

        // recordEvent is async-fire-and-forget — drain the SessionDatabase
        // serial queue before reading.
        db.queue.sync { } // drain async recordEvent

        let counts = db.eventCounts(prefix: "security.policy.")
        let hashFailed = counts.first { $0.eventType == "security.policy.hash_failed" }
        #expect(hashFailed != nil)
        #expect((hashFailed?.count ?? 0) >= 1)

        // No row landed.
        let all = db.allPolicySnapshots(sessionId: sid)
        #expect(all.isEmpty)
    }

    @Test func twoBrokenConfigsDoNotSilentlyCollideOnEmptyHash() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfgA = makeConfigWithUnencodableBudget()
        let cfgB = makeConfigWithUnencodableBudget()

        // Both fail. Pre-fix, both would have produced policy_hash = "" and
        // the second insert would silently no-op via the UNIQUE constraint;
        // the operator would see one row that "represents" two distinct
        // broken states. Post-fix, neither insert lands, both bump the
        // counter, and the audit baseline stays empty rather than corrupt.
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfgA) == false)
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfgB) == false)

        db.queue.sync { } // drain async recordEvent

        #expect(db.allPolicySnapshots(sessionId: sid).isEmpty)
        let counts = db.eventCounts(prefix: "security.policy.")
        let hashFailed = counts.first { $0.eventType == "security.policy.hash_failed" }
        #expect((hashFailed?.count ?? 0) >= 2)
    }
}

@Suite("LearnedRulesHasher")
struct LearnedRulesHasherTests {

    @Test func returnsAbsentSentinelWhenFileMissing() throws {
        let tmp = "/tmp/senkani-learned-rules-missing-\(UUID().uuidString).json"
        // File path is not created — guarantees fileExists == false.
        let hash = try LearnedRulesStore.withPath(tmp) {
            try LearnedRulesHasher.currentHash()
        }
        #expect(hash == LearnedRulesHasher.absentSentinel)
        #expect(hash == "none")
    }

    @Test func throwsFileUnreadableWhenFilePresentButCorrupt() {
        let tmp = "/tmp/senkani-learned-rules-corrupt-\(UUID().uuidString).json"
        // Write garbage that decodes-as-LearnedRulesFile fails.
        let dir = (tmp as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        try? Data("not-valid-json{{{".utf8).write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        LearnedRulesStore.withPath(tmp) {
            #expect(throws: LearnedRulesHashError.self) {
                _ = try LearnedRulesHasher.currentHash()
            }
        }
    }

    @Test func captureBumpsLearnedRulesCounterOnCorruptFile() {
        let (db, dbPath) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: dbPath) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)

        let tmp = "/tmp/senkani-learned-rules-corrupt-cap-\(UUID().uuidString).json"
        let dir = (tmp as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        try? Data("garbage".utf8).write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let inserted = LearnedRulesStore.withPath(tmp) {
            db.capturePolicySnapshot(sessionId: sid, projectRoot: "/tmp/proj")
        }
        #expect(inserted == false)

        db.queue.sync { } // drain async recordEvent

        let counts = db.eventCounts(prefix: "security.policy.")
        let learnedFailed = counts.first { $0.eventType == "security.policy.learned_rules_hash_failed" }
        #expect(learnedFailed != nil)
        #expect((learnedFailed?.count ?? 0) >= 1)

        // No snapshot row written.
        #expect(db.allPolicySnapshots(sessionId: sid).isEmpty)
    }
}
