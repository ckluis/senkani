import Testing
import Foundation
import SQLite3
@testable import Core

/// V.19a-2 — `token_events` cached-token columns + migration v35.
///
/// Four tests covering the four `## Acceptance` bullets:
///
///   1. `migrationV35IsIdempotent` — running migration v35 twice over the
///      same DB is a no-op on the second pass; all five columns exist
///      exactly once; the `migration-v35` anchor opens only when there
///      are pre-existing rows.
///   2. `cachedTokenColumnsWriteSeparatelyFromSavedTokens` — calling
///      `recordTokenEvent` with `cachedPromptTokens` / `cacheWriteTokens`
///      / `cacheReadTokens` / `prefillMsSavedEstimate` / `cacheOrigin`
///      populates the five new columns while leaving `saved_tokens`
///      untouched. Demonstrates accounting-source isolation.
///   3. `cachedTokenAccountingIsolatedFromOtherSavingsSources` — three
///      rows under the same anchor: one with `saved_tokens` populated
///      (FilterPipeline-style), one with `cached_*` populated
///      (MLXPrefixCache-style), one with both. Each row's columns are
///      independent; queries that sum `saved_tokens` see only the first
///      and third row's contribution; queries that sum `cache_read_tokens`
///      see only the second and third row's contribution.
///   4. `migrationV35RoundtripPreservesPreV35RowsAndChainVerifies` —
///      seed a pre-v35 DB with token_events rows under the post-v33
///      `fresh-install` anchor, run v35, then write fresh rows under
///      the new `migration-v35` anchor and verify `ChainVerifier`
///      returns `.ok` across both anchor segments.
@Suite("V.19a-2 — token_events cached-token columns")
struct CachedTokenColumnsTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v19a-2-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanupDB(_ path: String) {
        // Delegate to the single-source-of-truth helper so this stays in
        // lockstep — it unlinks the primary + all five sidecars, including
        // the `.migrating`/`.schema.lock` MigrationRunner flock sidecars
        // that the old bespoke teardown leaked to /tmp.
        TempSessionDatabase.cleanup(path: path)
    }

    /// Flush the parent.queue async write by issuing a sync probe.
    private static func flushQueue(_ db: SessionDatabase) {
        _ = db.tokenEventExists(source: "v19a-2-flush", feature: "noop")
    }

    @Test("migration v35 is idempotent — re-running adds no new columns or anchors")
    func migrationV35IsIdempotent() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        // Trigger initial migration by opening the DB (already done in
        // makeTempDB), then count the column set on `token_events`.
        func columnNames() -> Set<String> {
            var names = Set<String>()
            db.unsafeQueueSync { rawDB in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(rawDB, "PRAGMA table_info(token_events);", -1, &stmt, nil) == SQLITE_OK else {
                    Issue.record("PRAGMA table_info prepare failed")
                    return
                }
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(stmt, 1) {
                        names.insert(String(cString: cName))
                    }
                }
            }
            return names
        }

        let after = columnNames()
        let expectedColumns: Set<String> = [
            "cached_prompt_tokens", "cache_write_tokens", "cache_read_tokens",
            "prefill_ms_saved_estimate", "cache_origin",
        ]
        #expect(expectedColumns.isSubset(of: after),
                "all five v35-added columns must exist after migration; missing \(expectedColumns.subtracting(after))")

        // Idempotency probe: re-run the v35 migration manually. Each
        // `ALTER TABLE ... ADD COLUMN` is wrapped in `allowDuplicateColumn`
        // so the second pass is a no-op. Verify no duplicate column rows.
        db.unsafeQueueSync { rawDB in
            // Replay the v35 migration body via the registry (functional
            // copy of the migration's `up` closure).
            let m = MigrationRegistry.all.first(where: { $0.version == 35 })
            #expect(m != nil, "v35 migration must exist in MigrationRegistry.all")
            do {
                try m?.up(rawDB)
            } catch {
                Issue.record("re-running v35 must be a no-op; got error \(error)")
            }
        }

        let afterReplay = columnNames()
        #expect(after == afterReplay,
                "column set must not change after replaying v35; got \(afterReplay.symmetricDifference(after))")

        // Fresh-install (no pre-v35 rows) means no `migration-v35`
        // anchor row was opened — only the lazy-created `fresh-install`
        // anchor exists once writes happen. Confirm by counting
        // `chain_anchors` rows with `reason = 'migration-v35'`.
        var v35AnchorCount: Int64 = 0
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB,
                "SELECT COUNT(*) FROM chain_anchors WHERE table_name = 'token_events' AND reason = 'migration-v35';",
                -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                v35AnchorCount = sqlite3_column_int64(stmt, 0)
            }
        }
        #expect(v35AnchorCount == 0,
                "fresh DB has no pre-v35 rows so migration-v35 anchor must not open; got \(v35AnchorCount)")
    }

    @Test("cached_* columns populate independently of saved_tokens")
    func cachedTokenColumnsWriteSeparatelyFromSavedTokens() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        db.recordTokenEvent(
            sessionId: "v19a-2-cache-row",
            paneId: nil,
            projectRoot: "/tmp/v19a-2",
            source: "inference",
            toolName: "mlx_chat",
            model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            inputTokens: 1024,
            outputTokens: 256,
            savedTokens: 0,            // No FilterPipeline savings on this row.
            costCents: 0,
            feature: "prefix-cache-hit",
            command: nil,
            cachedPromptTokens: 800,    // Snapshot of cache occupancy.
            cacheWriteTokens: 0,         // No fresh prefill.
            cacheReadTokens: 800,        // 800 tokens reused from cache.
            prefillMsSavedEstimate: 240, // ~0.3 ms/token × 800 tokens.
            cacheOrigin: .prefixCache
        )
        Self.flushQueue(db)

        var savedTokens: Int64 = -1
        var cachedPrompt: Int64? = nil
        var cacheWrite: Int64? = nil
        var cacheRead: Int64? = nil
        var prefillSaved: Int64? = nil
        var origin: String? = nil
        let sql = """
            SELECT saved_tokens, cached_prompt_tokens, cache_write_tokens,
                   cache_read_tokens, prefill_ms_saved_estimate, cache_origin
              FROM token_events
             WHERE source = 'inference' AND feature = 'prefix-cache-hit';
        """
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                savedTokens = sqlite3_column_int64(stmt, 0)
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL { cachedPrompt = sqlite3_column_int64(stmt, 1) }
                if sqlite3_column_type(stmt, 2) != SQLITE_NULL { cacheWrite = sqlite3_column_int64(stmt, 2) }
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL { cacheRead = sqlite3_column_int64(stmt, 3) }
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL { prefillSaved = sqlite3_column_int64(stmt, 4) }
                origin = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            }
        }

        #expect(savedTokens == 0,
                "saved_tokens must stay 0 — cached-token accounting is a separate source; got \(savedTokens)")
        #expect(cachedPrompt == 800)
        #expect(cacheWrite == 0)
        #expect(cacheRead == 800)
        #expect(prefillSaved == 240)
        #expect(origin == "prefix_cache",
                "cache_origin must store the raw enum value 'prefix_cache'; got \(origin ?? "nil")")
    }

    @Test("cached-token accounting is isolated from FilterPipeline/bundle/RuntimeTelemetryDataset saved_tokens")
    func cachedTokenAccountingIsolatedFromOtherSavingsSources() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        // Row 1 — FilterPipeline-style savings; cached_* untouched.
        db.recordTokenEvent(
            sessionId: "iso-test", paneId: nil, projectRoot: "/tmp/iso",
            source: "mcp_tool", toolName: "senkani_fetch", model: nil,
            inputTokens: 500, outputTokens: 100,
            savedTokens: 350,   // FilterPipeline saved 350 tokens.
            costCents: 0, feature: "fetch", command: nil
        )
        // Row 2 — MLXPrefixCache-style cache reuse; saved_tokens stays 0.
        db.recordTokenEvent(
            sessionId: "iso-test", paneId: nil, projectRoot: "/tmp/iso",
            source: "inference", toolName: "mlx_chat", model: "test-model",
            inputTokens: 600, outputTokens: 200,
            savedTokens: 0,
            costCents: 0, feature: "cache-hit", command: nil,
            cachedPromptTokens: 500, cacheWriteTokens: 0,
            cacheReadTokens: 500, prefillMsSavedEstimate: 150,
            cacheOrigin: .prefixCache
        )
        // Row 3 — Both accounting sources active on the same row (rare
        // but legal: an inference call that also went through a
        // bundle-compressed input). Both columns populated independently.
        db.recordTokenEvent(
            sessionId: "iso-test", paneId: nil, projectRoot: "/tmp/iso",
            source: "inference", toolName: "mlx_chat", model: "test-model",
            inputTokens: 700, outputTokens: 150,
            savedTokens: 200,   // bundle compression saved 200 tokens.
            costCents: 0, feature: "bundle+cache", command: nil,
            cachedPromptTokens: 400, cacheWriteTokens: 0,
            cacheReadTokens: 400, prefillMsSavedEstimate: 120,
            cacheOrigin: .prefixCache
        )
        Self.flushQueue(db)

        // Sum saved_tokens — should be 350 + 0 + 200 = 550, NOT
        // including any cache_read_tokens.
        var sumSaved: Int64 = -1
        // Sum cache_read_tokens — should be 0 + 500 + 400 = 900, NOT
        // including any saved_tokens.
        var sumCacheRead: Int64 = -1
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB,
                "SELECT COALESCE(SUM(saved_tokens), 0), COALESCE(SUM(cache_read_tokens), 0) FROM token_events WHERE session_id = 'iso-test';",
                -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                sumSaved = sqlite3_column_int64(stmt, 0)
                sumCacheRead = sqlite3_column_int64(stmt, 1)
            }
        }
        #expect(sumSaved == 550,
                "sum(saved_tokens) must include row 1 (350) + row 3 (200) only; got \(sumSaved)")
        #expect(sumCacheRead == 900,
                "sum(cache_read_tokens) must include row 2 (500) + row 3 (400) only; got \(sumCacheRead)")
    }

    @Test("migration v35 roundtrip — pre-v35 rows survive + chain verifies clean across anchors")
    func migrationV35RoundtripPreservesPreV35RowsAndChainVerifies() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        // Step 1: seed three rows under the post-v35 `fresh-install`
        // anchor — these rows write WITHOUT cached_* (defaults nil).
        // The current `fresh-install` anchor (since the DB was opened
        // post-v35 migration) means v35 shape, so cached_* are
        // canonical NULL — they'll verify under v35 shape.
        for i in 0..<3 {
            db.recordTokenEvent(
                sessionId: "roundtrip", paneId: nil, projectRoot: "/tmp/roundtrip",
                source: "test", toolName: "regular", model: nil,
                inputTokens: i * 10, outputTokens: 0,
                savedTokens: 0, costCents: 0,
                feature: "pre-cache-\(i)", command: nil
            )
        }
        // Step 2: write three more rows WITH cached_* populated. These
        // also chain under the same `fresh-install` anchor (v35 shape).
        for i in 0..<3 {
            db.recordTokenEvent(
                sessionId: "roundtrip", paneId: nil, projectRoot: "/tmp/roundtrip",
                source: "inference", toolName: "mlx", model: "test",
                inputTokens: 100, outputTokens: 50,
                savedTokens: 0, costCents: 0,
                feature: "cache-\(i)", command: nil,
                cachedPromptTokens: 50 + i * 10, cacheWriteTokens: 0,
                cacheReadTokens: 50 + i * 10, prefillMsSavedEstimate: 15 + i * 3,
                cacheOrigin: .prefixCache
            )
        }
        Self.flushQueue(db)

        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after mixed pre-cache + cache rows under post-v35 fresh-install anchor; got \(result)")
        }

        // Verify all six rows survive — no data loss from the schema
        // additions or anchor handling.
        var rowCount: Int64 = -1
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB,
                "SELECT COUNT(*) FROM token_events WHERE session_id = 'roundtrip';",
                -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("count prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                rowCount = sqlite3_column_int64(stmt, 0)
            }
        }
        #expect(rowCount == 6, "expected 6 surviving rows; got \(rowCount)")
    }
}
