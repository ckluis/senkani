import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase U.6a — `ContextPlan` struct + `context_plans` table +
/// `agent_trace_event.plan_id` FK round-trip. Tests cover migration
/// shape, insert / fetchById / fetchBySession round-trip, plan_id
/// round-trip on `agent_trace_event`, and the v14 migration's
/// backward-compat behavior on a pre-v14 DB.
@Suite("ContextPlanStore — U.6a schema + round-trip")
struct ContextPlanStoreTests {

    // MARK: - Helpers

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-contextplan-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    private func samplePlan(
        id: String = UUID().uuidString,
        sessionId: String = "sess-1",
        plannedFanout: Int = 4,
        leafSize: Int = 2_000,
        reducer: ReducerChoice = .merge,
        estimatedCost: Int = 12,
        createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> ContextPlan {
        ContextPlan(
            id: id,
            sessionId: sessionId,
            plannedFanout: plannedFanout,
            leafSize: leafSize,
            reducerChoice: reducer,
            estimatedCost: estimatedCost,
            createdAt: createdAt
        )
    }

    // MARK: - Schema shape

    @Test("Migration v14 creates context_plans with the expected columns")
    func schemaShape() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        #expect(db.currentSchemaVersion() >= 14)

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(context_plans);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        let expected: Set<String> = [
            "id", "session_id", "planned_fanout", "leaf_size",
            "reducer_choice", "estimated_cost", "created_at",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")
    }

    @Test("Migration v14 adds plan_id to agent_trace_event")
    func agentTraceHasPlanId() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }
        #expect(db.currentSchemaVersion() >= 14)

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
        #expect(cols.contains("plan_id"),
                "v14 must add plan_id; saw \(cols.sorted())")
    }

    // MARK: - Round-trip

    @Test("ContextPlan round-trips through fetchById")
    func roundTripFetchById() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let plan = samplePlan(reducer: .summarize, estimatedCost: 73)
        #expect(db.recordContextPlan(plan))

        let fetched = db.contextPlan(id: plan.id)
        #expect(fetched == plan,
                "round-trip plan must match: got \(String(describing: fetched)), expected \(plan)")
    }

    @Test("All ReducerChoice cases round-trip")
    func reducerChoiceRoundTrip() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        for reducer in ReducerChoice.allCases {
            let plan = samplePlan(reducer: reducer)
            #expect(db.recordContextPlan(plan))
            let fetched = db.contextPlan(id: plan.id)
            #expect(fetched?.reducerChoice == reducer,
                    "reducer \(reducer) failed to round-trip; got \(String(describing: fetched?.reducerChoice))")
        }
    }

    @Test("fetchBySession returns plans newest-first, scoped to session")
    func fetchBySessionOrdering() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let session = "sess-ordering"
        let p1 = samplePlan(sessionId: session, createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        let p2 = samplePlan(sessionId: session, createdAt: Date(timeIntervalSince1970: 1_750_000_100))
        let p3 = samplePlan(sessionId: session, createdAt: Date(timeIntervalSince1970: 1_750_000_050))
        let other = samplePlan(sessionId: "sess-other", createdAt: Date(timeIntervalSince1970: 1_750_000_200))

        for p in [p1, p2, p3, other] { #expect(db.recordContextPlan(p)) }

        let rows = db.contextPlans(forSession: session)
        #expect(rows.map(\.id) == [p2.id, p3.id, p1.id],
                "expected newest-first within session, got \(rows.map(\.id))")
        #expect(!rows.contains(where: { $0.id == other.id }),
                "fetchBySession must scope to session; saw cross-session row")
    }

    @Test("Duplicate id is a DO NOTHING no-op (returns false)")
    func duplicateIdDedups() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let plan = samplePlan(estimatedCost: 1)
        #expect(db.recordContextPlan(plan))
        // Same id, different content. The DO NOTHING path keeps the
        // first row; the second insert returns false to signal no
        // write.
        let dupe = ContextPlan(
            id: plan.id, sessionId: plan.sessionId,
            plannedFanout: plan.plannedFanout, leafSize: plan.leafSize,
            reducerChoice: plan.reducerChoice, estimatedCost: 999,
            createdAt: plan.createdAt
        )
        #expect(!db.recordContextPlan(dupe))
        #expect(db.contextPlan(id: plan.id)?.estimatedCost == 1,
                "first-write-wins on duplicate id")
        #expect(db.contextPlanCount() == 1)
    }

    // MARK: - plan_id round-trip on agent_trace_event

    @Test("AgentTraceEvent round-trips plan_id through the store")
    func planIdRoundTrip() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let plan = samplePlan()
        #expect(db.recordContextPlan(plan))

        let row = AgentTraceEvent(
            idempotencyKey: "u6a-rt-\(UUID().uuidString)",
            result: "success",
            startedAt: Date(timeIntervalSince1970: 1_750_000_010),
            completedAt: Date(timeIntervalSince1970: 1_750_000_011),
            planId: plan.id
        )
        #expect(db.recordAgentTraceEvent(row))

        let read = db.agentTraceEvent(idempotencyKey: row.idempotencyKey)
        #expect(read?.planId == plan.id,
                "plan_id round-trip failed; got \(String(describing: read?.planId))")
    }

    @Test("AgentTraceEvent without planId persists plan_id = NULL")
    func planIdNilStaysNil() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        let row = AgentTraceEvent(
            idempotencyKey: "u6a-nil-\(UUID().uuidString)",
            result: "success",
            startedAt: Date(timeIntervalSince1970: 1_750_000_020),
            completedAt: Date(timeIntervalSince1970: 1_750_000_021)
        )
        #expect(db.recordAgentTraceEvent(row))

        let read = db.agentTraceEvent(idempotencyKey: row.idempotencyKey)
        #expect(read?.planId == nil,
                "non-combinator path must persist plan_id = NULL; got \(String(describing: read?.planId))")
    }

    // MARK: - Backward compat — v14 upgrades a v13 DB cleanly

    @Test("v14 upgrades a pre-existing v13 DB without data loss")
    func v14UpgradesV13DB() throws {
        // Build a DB pinned at v13 by running only migrations <= 13,
        // seed both `agent_trace_event` and an unrelated table, then
        // reopen against the full registry and verify that:
        //   1) v14 lands without error
        //   2) the seeded agent_trace_event row is still present
        //   3) the seeded row's `plan_id` reads as NULL (additive ALTER)
        //   4) `context_plans` exists and is empty
        let path = "/tmp/senkani-u6a-upgrade-\(UUID().uuidString).sqlite"
        defer { cleanup(path) }

        // Stage 1: run with a v<=13 registry, then poke a row in.
        let truncatedRegistry = MigrationRegistry.all.filter { $0.version <= 13 }
        var stagingDB: OpaquePointer?
        #expect(sqlite3_open(path, &stagingDB) == SQLITE_OK)
        _ = try MigrationRunner.run(db: stagingDB!, dbPath: path, registry: truncatedRegistry)

        // Pre-flight assertion: the staged DB is at v13, no plan_id.
        #expect(MigrationRunner.currentVersion(db: stagingDB!) == 13)

        // Seed a row directly via SQL (the agent_trace_event table is
        // created by v8 and already has its UNIQUE on idempotency_key).
        let seedKey = "pre-v14-row"
        var stmt: OpaquePointer?
        let insertSQL = """
            INSERT INTO agent_trace_event
                (idempotency_key, result, started_at, completed_at)
            VALUES (?, 'success', 1, 2);
        """
        #expect(sqlite3_prepare_v2(stagingDB!, insertSQL, -1, &stmt, nil) == SQLITE_OK)
        sqlite3_bind_text(stmt, 1, (seedKey as NSString).utf8String, -1, nil)
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(stagingDB!)

        // Stage 2: open via SessionDatabase which runs the full registry,
        // landing v14 on top of the v13 DB.
        let db = SessionDatabase(path: path)
        #expect(db.currentSchemaVersion() == MigrationRegistry.all.map(\.version).max())

        // The seeded row survived and reads plan_id = NULL.
        let read = db.agentTraceEvent(idempotencyKey: seedKey)
        #expect(read != nil, "seeded row must survive v14 upgrade")
        #expect(read?.planId == nil, "v14 ALTER adds plan_id NULL by default")

        // context_plans is present and starts empty.
        #expect(db.contextPlanCount() == 0)
    }
}
