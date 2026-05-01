import Testing
import Foundation
import SQLite3
@testable import Core

// MARK: - Corpus loader

private struct CorpusItem: Codable, Sendable {
    let prompt: String
    let expected_tier: String
}

private struct Corpus: Codable, Sendable {
    let items: [CorpusItem]
}

private func loadCorpus() -> Corpus? {
    guard let url = Bundle.module.url(forResource: "routing-corpus", withExtension: "json"),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Corpus.self, from: data)
}

private func parseTier(_ raw: String) -> TaskTier? {
    TaskTier(rawValue: raw)
}

// MARK: - U.1b corpus + accuracy gate

@Suite("ModelRouter — U.1b routing corpus + accuracy gate")
struct RoutingCorpusTests {

    @Test("Corpus loads and has at least 50 items")
    func corpusLoadsAtLeast50Items() throws {
        let corpus = try #require(loadCorpus(), "routing-corpus.json must be bundled with the test target")
        #expect(corpus.items.count >= 50,
                "Corpus must have at least 50 items, got \(corpus.items.count)")
    }

    @Test("Each TaskTier has at least 10 corpus rows")
    func corpusHasTenPerTier() throws {
        let corpus = try #require(loadCorpus())
        var counts: [TaskTier: Int] = [:]
        for item in corpus.items {
            guard let tier = parseTier(item.expected_tier) else {
                Issue.record("Unknown tier label '\(item.expected_tier)' in prompt: \(item.prompt)")
                continue
            }
            counts[tier, default: 0] += 1
        }
        for tier in TaskTier.allCases {
            #expect((counts[tier] ?? 0) >= 10,
                    "\(tier.rawValue) tier needs >=10 corpus rows, got \(counts[tier] ?? 0)")
        }
    }

    @Test("All corpus labels parse as valid TaskTier values")
    func corpusLabelsParse() throws {
        let corpus = try #require(loadCorpus())
        for item in corpus.items {
            #expect(parseTier(item.expected_tier) != nil,
                    "Bad tier label '\(item.expected_tier)' on prompt: \(item.prompt)")
        }
    }

    /// The headline gate. Loose at 0.85 by design — flakiness is more
    /// expensive than a tight bar that catches nothing. Per U.1b spec
    /// note: "If accuracy comes in much higher naturally, do not tighten
    /// the gate in this round."
    @Test("ModelRouter.classify achieves >=0.85 accuracy on the corpus")
    func classifyMeetsAccuracyGate() throws {
        let corpus = try #require(loadCorpus())
        var hits = 0
        var total = 0
        var misses: [(prompt: String, expected: String, got: String)] = []
        for item in corpus.items {
            guard let expected = parseTier(item.expected_tier) else { continue }
            let got = ModelRouter.classify(prompt: item.prompt)
            total += 1
            if got == expected {
                hits += 1
            } else {
                misses.append((item.prompt, expected.rawValue, got.rawValue))
            }
        }
        let accuracy = Double(hits) / Double(total)
        let missDetail = misses
            .map { "  '\($0.prompt)': expected \($0.expected), got \($0.got)" }
            .joined(separator: "\n")
        #expect(accuracy >= 0.85,
                "Routing accuracy \(accuracy) below 0.85 gate. Misses (\(misses.count)/\(total)):\n\(missDetail)")
    }
}

// MARK: - U.1b ladder_position propagation through Decision

@Suite("ModelRouter — U.1b Decision carries TaskTier + ladderPosition")
struct DecisionTaskTierFieldsTests {

    @Test("resolve(taskTier:) on primary rung records ladderPosition=0")
    func primaryRungZero() {
        let unlimited = BudgetConfig()
        let result = ModelRouter.resolve(
            taskTier: .standard,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: true
        )
        #expect(result.taskTier == .standard)
        #expect(result.ladderPosition == 0)
    }

    @Test("resolve(taskTier:) walking past local records ladderPosition=1")
    func walkedRungOne() {
        let unlimited = BudgetConfig()
        let result = ModelRouter.resolve(
            taskTier: .simple,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: false
        )
        // Simple ladder = [.local, .quick]; local unavailable → walks to .quick.
        #expect(result.tier == .quick)
        #expect(result.taskTier == .simple)
        #expect(result.ladderPosition == 1)
    }

    @Test("resolve(taskTier:) under tight budget records the clamped TaskTier")
    func clampedTaskTierRecorded() {
        let tight = BudgetConfig(dailyLimitCents: 50)  // $0.50/day → simple ceiling
        let result = ModelRouter.resolve(
            taskTier: .reasoning,
            budget: tight,
            availableRAMGB: 16,
            gemma4Downloaded: true
        )
        // Clamped from reasoning to simple; primary rung of simple = .local.
        #expect(result.tier == .local)
        #expect(result.taskTier == .simple,
                "Decision.taskTier should record the *clamped* tier (the work that actually ran)")
        #expect(result.ladderPosition == 0)
    }

    @Test("Synthesized fallback for one-rung-local ladder records ladderPosition=1")
    func synthesizedFallbackPositionOne() {
        let unlimited = BudgetConfig()
        let oneRung = FallbackLadder(entries: [.local])
        let result = ModelRouter.resolve(
            taskTier: .simple,
            budget: unlimited,
            availableRAMGB: 16,
            gemma4Downloaded: false,
            ladder: oneRung
        )
        #expect(result.tier == .quick)
        #expect(result.taskTier == .simple)
        #expect(result.ladderPosition == 1,
                "Synthesized fallback should be reported at position 1, not 0")
    }
}

// MARK: - U.1b agent_trace_event ladder_position migration + write

@Suite("ModelRouter — U.1b ladder_position migration + write-through")
struct LadderPositionMigrationTests {

    @Test("Migration v10 adds ladder_position to agent_trace_event")
    func schemaHasLadderPosition() {
        let path = "/tmp/senkani-u1b-schema-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        let db = SessionDatabase(path: path)
        #expect(db.currentSchemaVersion() >= 10)

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(agent_trace_event);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        #expect(cols.contains("ladder_position"),
                "Migration v10 must add ladder_position; saw \(cols.sorted())")
    }

    @Test("AgentTraceEvent round-trips ladder_position through the store")
    func ladderPositionRoundTrip() {
        let path = "/tmp/senkani-u1b-rt-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        let db = SessionDatabase(path: path)

        let row = AgentTraceEvent(
            idempotencyKey: "u1b-rt-1",
            tier: "complex",
            ladderPosition: 1,
            result: "success",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        #expect(db.recordAgentTraceEvent(row))

        let probe = db.queue.sync { () -> (tier: String?, pos: Int?) in
            guard let h = db.db else { return (nil, nil) }
            var stmt: OpaquePointer?
            let sql = "SELECT tier, ladder_position FROM agent_trace_event WHERE idempotency_key = 'u1b-rt-1';"
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return (nil, nil) }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil) }
            let tier = sqlite3_column_type(stmt, 0) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 0))
            let pos = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(stmt, 1))
            return (tier, pos)
        }
        #expect(probe.tier == "complex")
        #expect(probe.pos == 1)
    }

    @Test("ladder_position is NULL when AgentTraceEvent omits it")
    func ladderPositionNullByDefault() {
        let path = "/tmp/senkani-u1b-null-\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        let db = SessionDatabase(path: path)

        let row = AgentTraceEvent(
            idempotencyKey: "u1b-null-1",
            result: "success",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        #expect(db.recordAgentTraceEvent(row))

        let isNull = db.queue.sync { () -> Bool in
            guard let h = db.db else { return false }
            var stmt: OpaquePointer?
            let sql = "SELECT ladder_position FROM agent_trace_event WHERE idempotency_key = 'u1b-null-1';"
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_type(stmt, 0) == SQLITE_NULL
        }
        #expect(isNull)
    }
}
