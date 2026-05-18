import Testing
import Foundation
import SQLite3
@testable import Core

// Phase V.5c — `senkani authorship backfill` SQL + runner contract.
//
// Locks the V.5c invariants:
//   1. Backfill matches `created_at >= since AND authorship IS NULL`.
//      Rows before the cutoff and rows already tagged are left alone.
//   2. The in-band `.unset` sentinel is NOT overwritten — it represents
//      an explicit operator deferral, distinct from the legacy NULL
//      state that backfill is here to heal.
//   3. Idempotent: a second pass with the same args writes 0 rows.
//   4. Each non-empty batch records a chain-participating row in
//      `commands` (Phase T.5 round 3) — the "audit-chain row" required
//      by the V.5c acceptance.
//
// Tests use raw SQL to seed legacy NULL rows because the public
// `upsertEntity` path always writes through `AuthorshipTracker.encode`
// (never producing NULL). The legacy state only arises from migration
// v7 over a pre-V.5 DB, which the test recreates explicitly.

private func makeKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-v5c-kb-\(UUID().uuidString).sqlite"
    return (KnowledgeStore(path: path), path)
}

private func makeAuditDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-v5c-audit-\(UUID().uuidString).sqlite"
    return (SessionDatabase(path: path), path)
}

/// Insert a row directly with `authorship = NULL` to simulate the
/// pre-V.5 legacy state. The public `upsertEntity` path can't produce
/// this state; it always encodes a tag (even `.unset`).
private func seedLegacyNullRow(
    _ store: KnowledgeStore,
    name: String,
    createdAt: Date
) {
    store.queue.sync {
        guard let db = store.db else { return }
        let sql = """
            INSERT INTO knowledge_entities
                (name, entity_type, source_path, markdown_path, content_hash, content,
                 last_enriched, mention_count, session_mentions, staleness_score,
                 created_at, modified_at, authorship)
            VALUES (?, 'class', NULL, ?, '', '', NULL, 0, 0, 0.0, ?, ?, NULL);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (".senkani/knowledge/\(name).md" as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }
}

/// Read back the authorship column directly — bypasses
/// `AuthorshipTracker.decode` so the test can distinguish NULL from
/// `.unset`.
private func rawAuthorship(_ store: KnowledgeStore, name: String) -> String? {
    return store.queue.sync {
        guard let db = store.db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT authorship FROM knowledge_entities WHERE name=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }
}

// MARK: - SQL behavior

@Suite("Authorship backfill — SQL behavior")
struct AuthorshipBackfillSQLTests {

    @Test("Counts and updates only NULL rows whose created_at >= since")
    func backfillRespectsSinceCutoffAndNullPredicate() {
        let (store, path) = makeKB()
        defer { TempKnowledgeStore.close(store, path: path) }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let before = cutoff.addingTimeInterval(-86_400)
        let after = cutoff.addingTimeInterval(86_400)

        seedLegacyNullRow(store, name: "OldNull", createdAt: before)
        seedLegacyNullRow(store, name: "NewNullA", createdAt: after)
        seedLegacyNullRow(store, name: "NewNullB", createdAt: after)

        #expect(store.countNullAuthorship(since: cutoff) == 2,
                "Counts only the two NULL rows past the cutoff")

        let updated = store.backfillNullAuthorship(since: cutoff, tag: .humanAuthored)
        #expect(updated == 2, "UPDATE writes exactly the two qualifying rows")

        #expect(rawAuthorship(store, name: "OldNull") == nil,
                "Pre-cutoff legacy row stays NULL")
        #expect(rawAuthorship(store, name: "NewNullA") == "human-authored")
        #expect(rawAuthorship(store, name: "NewNullB") == "human-authored")
    }

    @Test("Second pass with same args writes 0 rows (idempotent)")
    func backfillIsIdempotent() {
        let (store, path) = makeKB()
        defer { TempKnowledgeStore.close(store, path: path) }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        seedLegacyNullRow(store, name: "Once", createdAt: cutoff.addingTimeInterval(60))
        seedLegacyNullRow(store, name: "Twice", createdAt: cutoff.addingTimeInterval(120))

        let first = store.backfillNullAuthorship(since: cutoff, tag: .aiAuthored)
        #expect(first == 2, "First pass tags both rows")

        let second = store.backfillNullAuthorship(since: cutoff, tag: .aiAuthored)
        #expect(second == 0, "Second pass is a no-op — predicate no longer matches")

        #expect(store.countNullAuthorship(since: cutoff) == 0,
                "Preview surface agrees: nothing left to backfill")
    }

    @Test("Does NOT overwrite the in-band `.unset` sentinel")
    func backfillPreservesUnsetSentinel() {
        // `.unset` is an explicit operator deferral — distinct from the
        // legacy NULL state. Backfill must leave it alone so the prompt
        // path (V.5b) gets to heal it on the next save.
        let (store, path) = makeKB()
        defer { TempKnowledgeStore.close(store, path: path) }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let after = cutoff.addingTimeInterval(60)

        // Public path lands `.unset` (raw "unset" in the column).
        _ = store.upsertEntity(
            KnowledgeEntity(
                name: "DeferredByOperator",
                markdownPath: ".senkani/knowledge/DeferredByOperator.md",
                createdAt: after
            ),
            authorship: .unset
        )
        // Sanity: the seed actually wrote "unset", not NULL.
        #expect(rawAuthorship(store, name: "DeferredByOperator") == "unset")

        let updated = store.backfillNullAuthorship(since: cutoff, tag: .aiAuthored)
        #expect(updated == 0, "No rows match (column is `.unset`, not NULL)")
        #expect(rawAuthorship(store, name: "DeferredByOperator") == "unset",
                "Operator's deferral choice is preserved")
    }

    @Test("Does NOT overwrite already-tagged rows")
    func backfillPreservesExplicitTags() {
        let (store, path) = makeKB()
        defer { TempKnowledgeStore.close(store, path: path) }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let after = cutoff.addingTimeInterval(60)

        for (name, tag) in [
            ("AlreadyAI", AuthorshipTag.aiAuthored),
            ("AlreadyHuman", .humanAuthored),
            ("AlreadyMixed", .mixed),
        ] {
            _ = store.upsertEntity(
                KnowledgeEntity(
                    name: name,
                    markdownPath: ".senkani/knowledge/\(name).md",
                    createdAt: after
                ),
                authorship: tag
            )
        }

        let updated = store.backfillNullAuthorship(since: cutoff, tag: .humanAuthored)
        #expect(updated == 0, "Explicit tags are not NULL — predicate doesn't match")

        #expect(store.entity(named: "AlreadyAI")?.authorship == .aiAuthored)
        #expect(store.entity(named: "AlreadyHuman")?.authorship == .humanAuthored)
        #expect(store.entity(named: "AlreadyMixed")?.authorship == .mixed)
    }

    @Test("Each of the three explicit tags writes its raw value")
    func backfillWritesAllThreeExplicitTags() {
        for tag in [AuthorshipTag.aiAuthored, .humanAuthored, .mixed] {
            let (store, path) = makeKB()
            defer { TempKnowledgeStore.close(store, path: path) }

            let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
            seedLegacyNullRow(store, name: "Row", createdAt: cutoff.addingTimeInterval(1))

            let updated = store.backfillNullAuthorship(since: cutoff, tag: tag)
            #expect(updated == 1, "Single legacy row gets tagged for \(tag.rawValue)")
            #expect(rawAuthorship(store, name: "Row") == tag.rawValue,
                    "Stored raw value matches the chosen tag")
        }
    }
}

// MARK: - Runner / audit-chain integration

@Suite("Authorship backfill — runner records audit-chain row")
struct AuthorshipBackfillRunnerTests {

    /// Read the count of `commands` rows whose `tool_name` matches the
    /// given filter. Drains the async commandStore writer first by
    /// running an empty `queue.sync` block (the same trick
    /// CommandStoreTests uses).
    private static func auditRowCount(_ db: SessionDatabase, toolName: String) -> Int {
        db.queue.sync { /* drain any pending recordCommand async closures */ }
        return db.queue.sync {
            guard let raw = db.db else { return 0 }
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM commands WHERE tool_name = ?;"
            guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (toolName as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Verify the audit row's `entry_hash` is non-empty (chain-participating
    /// inserts always write a hash; the `commands` table requires it).
    private static func latestEntryHash(_ db: SessionDatabase, toolName: String) -> String? {
        db.queue.sync { }
        return db.queue.sync {
            guard let raw = db.db else { return nil }
            var stmt: OpaquePointer?
            let sql = "SELECT entry_hash FROM commands WHERE tool_name = ? ORDER BY id DESC LIMIT 1;"
            guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (toolName as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    @Test("Runner writes one chain-participating commands row per non-empty batch")
    func runnerLogsAuditChainRow() {
        let (kb, kbPath) = makeKB()
        let (audit, auditPath) = makeAuditDB()
        defer {
            TempKnowledgeStore.close(kb, path: kbPath)
            TempSessionDatabase.close(audit, path: auditPath)
        }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        seedLegacyNullRow(kb, name: "BatchA", createdAt: cutoff.addingTimeInterval(60))
        seedLegacyNullRow(kb, name: "BatchB", createdAt: cutoff.addingTimeInterval(120))

        let result = AuthorshipBackfillRunner.run(
            store: kb,
            sessionDatabase: audit,
            since: cutoff,
            sinceLabel: "2023-11-14",
            tag: .mixed
        )

        #expect(result.updated == 2, "Two legacy rows tagged")
        #expect(result.auditSessionId != nil, "Non-empty batch opens an audit session")

        let count = Self.auditRowCount(audit, toolName: "authorship.backfill")
        #expect(count == 1, "Exactly one audit row for the batch")

        let hash = Self.latestEntryHash(audit, toolName: "authorship.backfill")
        #expect(hash != nil && !hash!.isEmpty,
                "Audit row carries a chain entry_hash (Phase T.5 round 3)")
        #expect(hash?.count == 64,
                "SHA-256 hex digest is 64 chars — chain integration is real")
    }

    @Test("Runner writes no audit row on idempotent re-run (0 rows updated)")
    func runnerSkipsAuditOnEmptyBatch() {
        let (kb, kbPath) = makeKB()
        let (audit, auditPath) = makeAuditDB()
        defer {
            TempKnowledgeStore.close(kb, path: kbPath)
            TempSessionDatabase.close(audit, path: auditPath)
        }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        // No legacy NULL rows seeded — the backfill matches nothing.

        let result = AuthorshipBackfillRunner.run(
            store: kb,
            sessionDatabase: audit,
            since: cutoff,
            sinceLabel: "2023-11-14",
            tag: .humanAuthored
        )

        #expect(result.updated == 0)
        #expect(result.auditSessionId == nil,
                "Empty batch does not open a session — keeps the audit log clean")
        #expect(result.auditRowVerified == nil,
                "Empty batch reports nil verification (no write attempted, none to verify)")
        #expect(Self.auditRowCount(audit, toolName: "authorship.backfill") == 0,
                "No audit row written when no rows updated")
    }

    /// Regression-watch for `authorship-backfill-audit-row-not-durable-2026-05-17` (P0).
    ///
    /// Pre-2026-05-18, `CommandStore.recordCommand` and `endSession`
    /// were `parent.queue.async`, so a short-lived CLI process that
    /// called the runner and immediately returned lost both writes to
    /// queue-teardown before the dispatched blocks ran. The runner's
    /// `auditSessionId` was set (createSession is `queue.sync` and
    /// committed synchronously), but the corresponding `commands` row
    /// + the `sessions.ended_at` update silently never landed.
    ///
    /// The fix (2026-05-18): change those two writes to `queue.sync`
    /// to match every other queue access in `CommandStore.swift`, and
    /// add an explicit verify-after-write SELECT inside the runner so
    /// the CLI's `"Audit-chain row recorded"` claim becomes load-
    /// bearing instead of structurally false. This test pins the
    /// post-fix contract — if anyone reverts the writes to `async`,
    /// `result.auditRowVerified` flips to `false` and / or
    /// `sessions.ended_at` reverts to NULL the moment the runner
    /// returns, and this test fails.
    @Test("Runner's audit-chain row + endSession are durable post-CLI-exit (regression watch for 2026-05-18 fix)")
    func runnerAuditRowAndEndSessionDurablePostExit() {
        let (kb, kbPath) = makeKB()
        let (audit, auditPath) = makeAuditDB()
        defer {
            TempKnowledgeStore.close(kb, path: kbPath)
            TempSessionDatabase.close(audit, path: auditPath)
        }

        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        seedLegacyNullRow(kb, name: "Regression-Pre-V5-A", createdAt: Date(timeIntervalSince1970: 1_710_000_000))
        seedLegacyNullRow(kb, name: "Regression-Pre-V5-B", createdAt: Date(timeIntervalSince1970: 1_720_000_000))

        let result = AuthorshipBackfillRunner.run(
            store: kb,
            sessionDatabase: audit,
            since: cutoff,
            sinceLabel: "2023-11-14",
            tag: .mixed,
            projectRoot: "/tmp/regression-watch"
        )

        #expect(result.updated == 2, "Two seeded NULL rows tagged")
        #expect(result.auditSessionId != nil, "Non-empty batch opens a session")
        #expect(result.auditRowVerified == true,
                "Verify-after-write SELECT confirms the audit-chain row landed before the runner returned. If this fails, recordCommand has likely been flipped back to queue.async — see the comment in CommandStore.swift dated 2026-05-18.")

        guard let sid = result.auditSessionId else { return }

        // Direct SQL verification — the runner's auditRowVerified is the
        // primary contract; the test triple-checks via the actual table
        // rows to defend against a future refactor that might satisfy
        // auditRowVerified through some other code path.
        let cmdCount = audit.commandCount(sessionId: sid)
        #expect(cmdCount == 1,
                "Exactly one audit-chain row in `commands` for the session (got \(cmdCount))")

        // `sessions.ended_at` durability — the other half of the same
        // bug class. Pre-fix this stayed NULL on every backfill because
        // endSession was also queue.async.
        let endedAt = Self.sessionEndedAt(audit, sessionId: sid)
        #expect(endedAt != nil,
                "sessions.ended_at is non-NULL post-runner-return. If NULL: endSession has likely been flipped back to queue.async — same bug class.")
    }

    /// Direct SQL read of `sessions.ended_at` for the regression test.
    /// Returns `nil` when the column is NULL (the pre-fix failure mode)
    /// OR when the row is missing.
    private static func sessionEndedAt(_ db: SessionDatabase, sessionId: String) -> Double? {
        return db.queue.sync {
            guard let raw = db.db else { return nil }
            var stmt: OpaquePointer?
            let sql = "SELECT ended_at FROM sessions WHERE id = ?;"
            guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, 0)
        }
    }
}
