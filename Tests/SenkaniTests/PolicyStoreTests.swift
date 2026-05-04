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
    modelId: String? = "claude-haiku-4-5",
    modelTier: String? = nil
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
        modelId: modelId,
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
        #expect(decoded?.modelId == "claude-haiku-4-5")
        #expect(decoded?.modelTier == nil)
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
            modelId: nil,
            modelTier: nil,
            agentType: nil,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let cfg2 = PolicyConfig(
            features: cfg1.features, budget: cfg1.budget,
            learnedRulesHash: cfg1.learnedRulesHash,
            modelId: cfg1.modelId, modelTier: cfg1.modelTier,
            agentType: cfg1.agentType,
            capturedAt: Date(timeIntervalSince1970: 999_999)
        )
        let h1 = try cfg1.policyHash()
        let h2 = try cfg2.policyHash()
        #expect(h1 == h2)
    }

    @Test func modelIdAndModelTierAreSeparateHashInputs() throws {
        // Two configs that differ only in which split field is populated
        // must produce different hashes — collapsing them to the same
        // hash is exactly the bug the split is fixing.
        let cfgWithModelId = makeConfig(modelId: "claude-sonnet-4", modelTier: nil)
        let cfgWithModelTier = makeConfig(modelId: nil, modelTier: "claude-sonnet-4")
        let h1 = try cfgWithModelId.policyHash()
        let h2 = try cfgWithModelTier.policyHash()
        #expect(h1 != h2)
    }

    @Test func modelTierTierVocabularyHashesDifferentlyFromModelId() throws {
        let cfgTier = makeConfig(modelId: nil, modelTier: "standard")
        let cfgId = makeConfig(modelId: "standard", modelTier: nil)
        #expect(try cfgTier.policyHash() != cfgId.policyHash())
    }
}

// MARK: - Legacy decode (pre-2026-05-04 conflated `modelTier` field)

@Suite("PolicyConfig legacy decode")
struct PolicyConfigLegacyDecodeTests {

    private static let legacyJSONPrefix = """
    {
      "agentType": "claude_code",
      "budget": {
        "perSessionLimitCents": null,
        "dailyLimitCents": null,
        "weeklyLimitCents": null,
        "softLimitPercent": 0.8
      },
      "capturedAt": "2023-11-14T22:13:20Z",
      "features": {
        "filter": true, "secrets": true, "indexer": true,
        "terse": false, "injectionGuard": true
      },
      "learnedRulesHash": "abc123"
    """

    private static func decode(_ json: String) throws -> PolicyConfig {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PolicyConfig.self, from: data)
    }

    @Test func legacyModelIdValueRoutesToModelId() throws {
        // Old single-field shape with a Claude model id value — the
        // typical case (operators set CLAUDE_MODEL almost always).
        let json = "\(Self.legacyJSONPrefix), \"modelTier\": \"claude-sonnet-4\" }"
        let cfg = try Self.decode(json)
        #expect(cfg.modelId == "claude-sonnet-4")
        #expect(cfg.modelTier == nil)
    }

    @Test func legacyTierVocabularyValueRoutesToModelTier() throws {
        // Old single-field shape but the value matches the U.1 tier
        // vocabulary — route to the new `modelTier` field instead.
        let json = "\(Self.legacyJSONPrefix), \"modelTier\": \"reasoning\" }"
        let cfg = try Self.decode(json)
        #expect(cfg.modelId == nil)
        #expect(cfg.modelTier == "reasoning")
    }

    @Test func legacyMissingValueRoutesToBothNil() throws {
        // Old shape with explicit null. Both new fields decode as nil.
        let json = "\(Self.legacyJSONPrefix), \"modelTier\": null }"
        let cfg = try Self.decode(json)
        #expect(cfg.modelId == nil)
        #expect(cfg.modelTier == nil)
    }

    @Test func legacyAbsentKeyRoutesToBothNil() throws {
        // Old shape with no `modelTier` key at all. Defensive: pre-split
        // code wrote the key with a string or null; absence shouldn't
        // happen in real DB rows but the decoder must tolerate it.
        let json = "\(Self.legacyJSONPrefix) }"
        let cfg = try Self.decode(json)
        #expect(cfg.modelId == nil)
        #expect(cfg.modelTier == nil)
    }

    @Test func newShapeRoundTripsIdAndTierIndependently() throws {
        // Encode in new shape, decode back, verify both fields land in
        // the right place.
        let original = PolicyConfig(
            features: PolicyFeatures(filter: true, secrets: true, indexer: true,
                                     terse: false, injectionGuard: true),
            budget: PolicyBudget(perSessionLimitCents: nil, dailyLimitCents: nil,
                                 weeklyLimitCents: nil, softLimitPercent: 0.8),
            learnedRulesHash: "abc123",
            modelId: "claude-opus-4-7",
            modelTier: "reasoning",
            agentType: "claude_code",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PolicyConfig.self, from: data)
        #expect(decoded.modelId == "claude-opus-4-7")
        #expect(decoded.modelTier == "reasoning")
    }

    @Test func newShapeWithBothNilStillCarriesDiscriminator() throws {
        // Encode a new-shape PolicyConfig with both modelId and
        // modelTier nil. The encoder MUST still emit `modelId` (as null)
        // so a re-decode treats it as new shape and doesn't run the
        // legacy classifier on a stray modelTier:null.
        let original = PolicyConfig(
            features: PolicyFeatures(filter: true, secrets: true, indexer: true,
                                     terse: false, injectionGuard: true),
            budget: PolicyBudget(perSessionLimitCents: nil, dailyLimitCents: nil,
                                 weeklyLimitCents: nil, softLimitPercent: 0.8),
            learnedRulesHash: "h",
            modelId: nil,
            modelTier: nil,
            agentType: nil,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"modelId\":null"))
        #expect(json.contains("\"modelTier\":null"))
    }
}

@Suite("LegacyModelTierClassifier")
struct LegacyModelTierClassifierTests {

    @Test func emptyOrNilIsEmpty() {
        #expect(LegacyModelTierClassifier.classify(nil) == .empty)
        #expect(LegacyModelTierClassifier.classify("") == .empty)
    }

    @Test func recognizedTierRoutesToModelTier() {
        for tier in ["simple", "standard", "complex", "reasoning"] {
            #expect(LegacyModelTierClassifier.classify(tier) == .modelTier(tier))
        }
    }

    @Test func unrecognizedValueRoutesToModelId() {
        #expect(LegacyModelTierClassifier.classify("claude-sonnet-4") == .modelId("claude-sonnet-4"))
        #expect(LegacyModelTierClassifier.classify("haiku") == .modelId("haiku"))
        #expect(LegacyModelTierClassifier.classify("custom-model-name") == .modelId("custom-model-name"))
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
        modelId: "claude-haiku-4-5",
        modelTier: nil,
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
