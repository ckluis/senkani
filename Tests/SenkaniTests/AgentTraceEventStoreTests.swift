import Testing
import Foundation
import SQLite3
@testable import Core

// MARK: - Test helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-agenttrace-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeRow(
    key: String = UUID().uuidString,
    pane: String? = "kb",
    project: String? = "/tmp/proj",
    model: String? = "claude-haiku-4-5",
    tier: String? = nil,
    feature: String? = "search",
    result: String = "success",
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    completedAt: Date = Date(timeIntervalSince1970: 1_700_000_001),
    latencyMs: Int = 42,
    tokensIn: Int = 100,
    tokensOut: Int = 50,
    costCents: Int = 3,
    redactionCount: Int = 0,
    validationStatus: String? = "pass",
    confirmationRequired: Bool = false,
    egressDecisions: Int = 0
) -> AgentTraceEvent {
    AgentTraceEvent(
        idempotencyKey: key,
        pane: pane, project: project, model: model, tier: tier, feature: feature,
        result: result, startedAt: startedAt, completedAt: completedAt,
        latencyMs: latencyMs, tokensIn: tokensIn, tokensOut: tokensOut,
        costCents: costCents, redactionCount: redactionCount,
        validationStatus: validationStatus,
        confirmationRequired: confirmationRequired,
        egressDecisions: egressDecisions
    )
}

@Suite("AgentTraceEventStore — V.2 canonical row + idempotency")
struct AgentTraceEventStoreTests {

    // MARK: - Schema + migration

    @Test("Migration v8 creates agent_trace_event with the expected columns")
    func schemaShape() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        // schema_migrations should be at v8 or later.
        #expect(db.currentSchemaVersion() >= 8)

        // Read PRAGMA table_info to verify all conformed dimensions + measures.
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
        let expected: Set<String> = [
            "id", "idempotency_key", "pane", "project", "model", "tier",
            "ladder_position", "feature", "result", "started_at", "completed_at",
            "latency_ms", "tokens_in", "tokens_out", "cost_cents", "redaction_count",
            "validation_status", "confirmation_required", "egress_decisions",
            "plan_id", "cost_ledger_version",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")
    }

    @Test("idempotency_key has a UNIQUE constraint at the DB layer")
    func uniqueConstraintEnforced() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        // Bypass the store's ON CONFLICT DO NOTHING and try a raw INSERT
        // that should hit a UNIQUE constraint failure.
        let key = "raw-unique-test"
        let r1 = db.recordAgentTraceEvent(makeRow(key: key))
        #expect(r1)

        let rc = db.queue.sync { () -> Int32 in
            guard let h = db.db else { return -1 }
            let sql = """
                INSERT INTO agent_trace_event
                    (idempotency_key, result, started_at, completed_at)
                VALUES (?, 'success', 0, 0);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            return sqlite3_step(stmt)
        }
        // SQLITE_CONSTRAINT == 19
        #expect(rc == SQLITE_CONSTRAINT, "expected UNIQUE constraint failure, got rc=\(rc)")
    }

    // MARK: - Idempotency dedup

    @Test("100 retries of the same idempotency_key land exactly 1 row")
    func idempotencyDedup100() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let key = "fixture-tool-call-7f3a"
        for _ in 0..<100 {
            db.recordAgentTraceEvent(makeRow(key: key, latencyMs: 42, tokensIn: 100))
        }
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.agentTraceEventStore.rowsWithIdempotencyKey(key) == 1)
    }

    @Test("First insert returns true; subsequent retries return false")
    func recordReturnsInsertedFlag() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let key = "first-vs-retry"
        let firstInserted = db.recordAgentTraceEvent(makeRow(key: key))
        let secondInserted = db.recordAgentTraceEvent(makeRow(key: key))
        let thirdInserted = db.recordAgentTraceEvent(makeRow(key: key, latencyMs: 999))

        #expect(firstInserted)
        #expect(!secondInserted)
        #expect(!thirdInserted)
    }

    @Test("Different idempotency_keys land separate rows")
    func differentKeysLandSeparateRows() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        for i in 0..<25 {
            db.recordAgentTraceEvent(makeRow(key: "call-\(i)"))
        }
        #expect(db.agentTraceEventCount() == 25)
    }

    // MARK: - Conformed dimensions + measures (round-trip)

    @Test("Roundtrip preserves all conformed dimensions and measures")
    func roundtripDimensions() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let row = makeRow(
            key: "rtdim-1", pane: "timeline", project: "/tmp/p1",
            model: "gemma-4-nano", tier: "simple", feature: "outline",
            result: "success",
            latencyMs: 17, tokensIn: 80, tokensOut: 25, costCents: 1,
            redactionCount: 2, validationStatus: "warn",
            confirmationRequired: true, egressDecisions: 3
        )
        db.recordAgentTraceEvent(row)

        let probe = db.queue.sync { () -> [String: String] in
            guard let h = db.db else { return [:] }
            var stmt: OpaquePointer?
            let sql = """
                SELECT pane, project, model, tier, feature, result,
                       latency_ms, tokens_in, tokens_out, cost_cents,
                       redaction_count, validation_status,
                       confirmation_required, egress_decisions
                FROM agent_trace_event WHERE idempotency_key = 'rtdim-1';
            """
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return [:] }
            return [
                "pane": String(cString: sqlite3_column_text(stmt, 0)),
                "project": String(cString: sqlite3_column_text(stmt, 1)),
                "model": String(cString: sqlite3_column_text(stmt, 2)),
                "tier": String(cString: sqlite3_column_text(stmt, 3)),
                "feature": String(cString: sqlite3_column_text(stmt, 4)),
                "result": String(cString: sqlite3_column_text(stmt, 5)),
                "latency_ms": String(sqlite3_column_int64(stmt, 6)),
                "tokens_in": String(sqlite3_column_int64(stmt, 7)),
                "tokens_out": String(sqlite3_column_int64(stmt, 8)),
                "cost_cents": String(sqlite3_column_int64(stmt, 9)),
                "redaction_count": String(sqlite3_column_int64(stmt, 10)),
                "validation_status": String(cString: sqlite3_column_text(stmt, 11)),
                "confirmation_required": String(sqlite3_column_int64(stmt, 12)),
                "egress_decisions": String(sqlite3_column_int64(stmt, 13)),
            ]
        }
        #expect(probe["pane"] == "timeline")
        #expect(probe["project"] == "/tmp/p1")
        #expect(probe["model"] == "gemma-4-nano")
        #expect(probe["tier"] == "simple")
        #expect(probe["feature"] == "outline")
        #expect(probe["result"] == "success")
        #expect(probe["latency_ms"] == "17")
        #expect(probe["tokens_in"] == "80")
        #expect(probe["tokens_out"] == "25")
        #expect(probe["cost_cents"] == "1")
        #expect(probe["redaction_count"] == "2")
        #expect(probe["validation_status"] == "warn")
        #expect(probe["confirmation_required"] == "1")
        #expect(probe["egress_decisions"] == "3")
    }

    @Test("tier column is NULL until U.1 lands the TierScorer")
    func tierIsNullByDefault() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAgentTraceEvent(makeRow(key: "no-tier", tier: nil))

        let tierIsNull = db.queue.sync { () -> Bool in
            guard let h = db.db else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT tier FROM agent_trace_event WHERE idempotency_key = 'no-tier';", -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_type(stmt, 0) == SQLITE_NULL
        }
        #expect(tierIsNull)
    }

    // MARK: - Pivot 1: by project

    @Test("Pivot by project rolls up cost + tokens + mean latency")
    func pivotByProject() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAgentTraceEvent(makeRow(key: "pp-1", project: "/proj/a", latencyMs: 10, tokensIn: 100, tokensOut: 30, costCents: 2))
        db.recordAgentTraceEvent(makeRow(key: "pp-2", project: "/proj/a", latencyMs: 30, tokensIn: 200, tokensOut: 70, costCents: 4))
        db.recordAgentTraceEvent(makeRow(key: "pp-3", project: "/proj/b", latencyMs: 20, tokensIn: 50,  tokensOut: 10, costCents: 7))

        let rollups = db.agentTracePivotByProject()
        #expect(rollups.count == 2)

        let a = rollups.first { $0.project == "/proj/a" }
        #expect(a?.eventCount == 2)
        #expect(a?.totalCostCents == 6)
        #expect(a?.totalTokensIn == 300)
        #expect(a?.totalTokensOut == 100)
        #expect(a?.meanLatencyMs == 20.0)

        let b = rollups.first { $0.project == "/proj/b" }
        #expect(b?.eventCount == 1)
        #expect(b?.totalCostCents == 7)
    }

    // MARK: - Pivot 2: by feature with success/failure split

    @Test("Pivot by feature splits success from failure")
    func pivotByFeatureSuccessSplit() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAgentTraceEvent(makeRow(key: "pf-1", feature: "search", result: "success", tokensIn: 100, tokensOut: 30))
        db.recordAgentTraceEvent(makeRow(key: "pf-2", feature: "search", result: "success", tokensIn: 100, tokensOut: 30))
        db.recordAgentTraceEvent(makeRow(key: "pf-3", feature: "search", result: "error",   tokensIn: 100, tokensOut: 0))
        db.recordAgentTraceEvent(makeRow(key: "pf-4", feature: "fetch",  result: "timeout", tokensIn: 50,  tokensOut: 0))

        let rollups = db.agentTracePivotByFeature()
        #expect(rollups.count == 2)

        let search = rollups.first { $0.feature == "search" }
        #expect(search?.eventCount == 3)
        #expect(search?.successCount == 2)
        #expect(search?.failureCount == 1)
        #expect(search?.totalTokensIn == 300)

        let fetch = rollups.first { $0.feature == "fetch" }
        #expect(fetch?.eventCount == 1)
        #expect(fetch?.successCount == 0)
        #expect(fetch?.failureCount == 1)
    }

    // MARK: - Pivot 3: by result

    @Test("Pivot by result distribution buckets each outcome")
    func pivotByResult() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        for i in 0..<5 { db.recordAgentTraceEvent(makeRow(key: "ok-\(i)", result: "success", latencyMs: 10, costCents: 1)) }
        for i in 0..<3 { db.recordAgentTraceEvent(makeRow(key: "err-\(i)", result: "error", latencyMs: 50, costCents: 0)) }
        db.recordAgentTraceEvent(makeRow(key: "to-1", result: "timeout", latencyMs: 100, costCents: 0))

        let rollups = db.agentTracePivotByResult()
        #expect(rollups.count == 3)

        let success = rollups.first { $0.result == "success" }
        #expect(success?.eventCount == 5)
        #expect(success?.meanLatencyMs == 10.0)
        #expect(success?.totalCostCents == 5)

        let err = rollups.first { $0.result == "error" }
        #expect(err?.eventCount == 3)
        #expect(err?.meanLatencyMs == 50.0)

        let timeout = rollups.first { $0.result == "timeout" }
        #expect(timeout?.eventCount == 1)
    }

    // MARK: - `since` filter

    @Test("Pivots respect the `since` filter")
    func sinceFilter() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        let newDate = Date(timeIntervalSince1970: 2_000_000)

        db.recordAgentTraceEvent(makeRow(key: "old-1", project: "/x", startedAt: oldDate, completedAt: oldDate))
        db.recordAgentTraceEvent(makeRow(key: "new-1", project: "/x", startedAt: newDate, completedAt: newDate))

        let cutoff = Date(timeIntervalSince1970: 1_500_000)
        let rollups = db.agentTracePivotByProject(since: cutoff)
        let x = rollups.first { $0.project == "/x" }
        #expect(x?.eventCount == 1, "since-filter should drop the old row")
    }

    // MARK: - Existing analytics still pass (regression smoke)

    @Test("Existing token_events analytics still work alongside agent_trace_event")
    func existingAnalyticsRegression() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        // Write to BOTH stores — confirm they coexist without contention.
        db.recordTokenEvent(
            sessionId: "s1", paneId: "kb", projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "search", model: "haiku",
            inputTokens: 100, outputTokens: 30, savedTokens: 50, costCents: 2,
            feature: "search", command: "k=foo"
        )
        db.recordAgentTraceEvent(makeRow(key: "coex-1", project: "/tmp/proj"))

        // Existing token_events stat path stays green.
        let stats = db.tokenStatsForProject("/tmp/proj")
        #expect(stats.commandCount == 1)
        #expect(stats.inputTokens == 100)

        // Canonical row count is independent.
        #expect(db.agentTraceEventCount() == 1)
    }

    // MARK: - Indexes (Bach: query plans hit the indexes we built)

    @Test("Pivot rolls NULL project under empty-string bucket without dropping rows")
    func pivotByProjectHandlesNull() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAgentTraceEvent(makeRow(key: "np-1", project: nil))
        db.recordAgentTraceEvent(makeRow(key: "np-2", project: nil))
        db.recordAgentTraceEvent(makeRow(key: "np-3", project: "/x"))

        let rollups = db.agentTracePivotByProject()
        #expect(rollups.count == 2)
        let nullBucket = rollups.first { $0.project == "" }
        #expect(nullBucket?.eventCount == 2)
    }

    @Test("Pivot query plans use the (project, started_at) index")
    func pivotQueryUsesProjectIndex() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAgentTraceEvent(makeRow(key: "ix-1", project: "/p"))

        let plan = db.queue.sync { () -> String in
            guard let h = db.db else { return "" }
            var stmt: OpaquePointer?
            let sql = "EXPLAIN QUERY PLAN SELECT project, COUNT(*) FROM agent_trace_event WHERE started_at >= 0 GROUP BY project;"
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
            defer { sqlite3_finalize(stmt) }
            var out = ""
            while sqlite3_step(stmt) == SQLITE_ROW {
                out += String(cString: sqlite3_column_text(stmt, 3)) + "\n"
            }
            return out
        }
        #expect(
            plan.contains("idx_agent_trace_project_started"),
            "expected query plan to use idx_agent_trace_project_started; got:\n\(plan)"
        )
    }
}
