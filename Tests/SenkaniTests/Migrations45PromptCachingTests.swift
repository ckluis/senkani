import Testing
import Foundation
import SQLite3
@testable import Core

/// V.13b prompt-caching B — Migration v45 + ChainVerifier 4th canonical-shape
/// tier + audit-side widening (Schneier+Lauret r15 spec).
///
/// Schneier P0 — `migration-v44` rows stay v44-shape FOREVER; the exclusion
/// list in `ChainVerifier.verifyAnchorOpenAIRequestLog` keeps them out of the
/// v45-shape tier so their entry_hash bytes (computed without the cache
/// columns) remain re-derivable.
///
/// Schneier P1 — the writer NULL-normalizes `.some(0) → nil` for the cache
/// token fields before SQLite bind AND before canonical-map insertion. A
/// semantically-identical "no warm" cache miss MUST hash identically
/// regardless of whether Anthropic emits `cache_read_input_tokens: 0` or
/// omits the field. Test 3 below pins this contract via the test-only
/// `recordChainedAllowingZeroForTesting` bypass that skips the normalizer.
///
/// Schneier P3 — the v45 idempotency probe MUST reference `migration-v45` and
/// `fresh-install-pre-v45` only. A literal `v44` in that probe silently makes
/// v45's rename + open run twice on a re-migration. The header doc-comment
/// of the v45 migration block includes the reviewer-checklist line.
///
/// Tests are `.serialized` because they each construct a temp SessionDatabase
/// that runs the full migration array (which mutates shared on-disk state at
/// fixed paths under /tmp). Parallel execution leaked the migration coord
/// flock against itself in prior rounds (see RuntimeTelemetryMigrationTests).
@Suite("Migrations v45 — openai_request_log prompt-caching audit columns", .serialized)
struct Migrations45PromptCachingTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v13b-prompt-caching-b-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "openai-request-log-v45-\(UUID().uuidString).db"
    }

    /// Count `chain_anchors` rows for `openai_request_log` matching `reason`.
    private static func anchorCount(path: String, reason: String) -> Int {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return -1 }
        defer { sqlite3_close(handle) }
        let sql = """
            SELECT COUNT(*) FROM chain_anchors
             WHERE table_name = 'openai_request_log' AND reason = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (reason as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Read raw `(prev_hash, entry_hash, chain_anchor_id)` for a row by id.
    private static func rawChainBytes(path: String, id: Int64) -> (prev: String?, hash: String, anchorId: Int64)? {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return nil }
        defer { sqlite3_close(handle) }
        let sql = "SELECT prev_hash, entry_hash, chain_anchor_id FROM openai_request_log WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let prev = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        let hash = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let anchorId = sqlite3_column_int64(stmt, 2)
        return (prev, hash, anchorId)
    }

    /// Look up the `reason` of a chain_anchors row by rowid.
    private static func anchorReason(path: String, anchorId: Int64) -> String? {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return nil }
        defer { sqlite3_close(handle) }
        let sql = "SELECT reason FROM chain_anchors WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchorId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// Confirm the v45 ADD COLUMNs landed.
    private static func columnNames(path: String) -> [String] {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return [] }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(openai_request_log);", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) {
                out.append(String(cString: c))
            }
        }
        return out
    }

    // MARK: - 1. v45 idempotent re-run

    /// Acceptance test #1 — opening a SessionDatabase twice against the same
    /// path runs the migration array twice. The second pass must observe the
    /// existing `migration-v45` anchor via the probe and skip the rename +
    /// anchor-open, so `migration-v45` anchor count stays at exactly 1 and
    /// the table's column-set is unchanged (the v45 ALTERs use
    /// `allowDuplicateColumn: true`).
    @Test("v45 idempotent re-run: opening + re-opening keeps migration-v45 anchor count == 1")
    func v45IdempotentReRun() {
        let path = Self.tempDBPath()

        // First open — runs migrations through v45.
        let db1 = SessionDatabase(path: path)
        defer { TempSessionDatabase.cleanup(path: path) }
        #expect(db1.openAIRequestLogCount() == 0)
        db1.close()

        // Sanity: the two ADD COLUMNs landed.
        let cols = Self.columnNames(path: path)
        #expect(cols.contains("cache_creation_input_tokens"),
                "v45 ALTER for cache_creation_input_tokens did not land")
        #expect(cols.contains("cache_read_input_tokens"),
                "v45 ALTER for cache_read_input_tokens did not land")

        // Sanity: one migration-v45 anchor opened.
        #expect(Self.anchorCount(path: path, reason: "migration-v45") == 1,
                "first open must open exactly one migration-v45 anchor")

        // Second open — migration array runs again. The probe must short-
        // circuit the rename + anchor-open. No second migration-v45 anchor.
        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        #expect(Self.anchorCount(path: path, reason: "migration-v45") == 1,
                "re-open must NOT open a second migration-v45 anchor")
        #expect(Self.anchorCount(path: path, reason: "fresh-install-pre-v45") == 0,
                "re-open must NOT re-rename anything (no fresh-install to rename)")
    }

    // MARK: - 2. Mixed-tier verify GREEN

    /// Acceptance test #2 — seed an `openai_request_log` table with rows
    /// under four DISTINCT anchor reasons (`fresh-install-pre-v42`,
    /// `migration-v42`, `migration-v44`, `migration-v45`). Each tier's writer
    /// branch must produce hashes the verifier's matching tier re-derives;
    /// `ChainVerifier.verifyOpenAIRequestLog` returns `.ok` across the
    /// whole table.
    @Test("Mixed-tier verify GREEN: rows under 4 distinct anchor reasons all verify .ok")
    func mixedTierVerifyGreen() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // The post-v45 default anchor is `migration-v45` (the migration
        // opens it unconditionally at MAX(id)=0). Insert the first chained
        // row under that anchor by writing through the canonical path —
        // includes the cache columns in its hash (Child A would populate;
        // Child B always passes nil).
        let now = Date(timeIntervalSince1970: 1_900_100_000)
        #expect(db.recordOpenAIRequest(
            ts: now, surface: .chat, status: 200,
            keyLabel: "v45-key", modelLogged: "claude-opus-4", resolvedTier: "cloud",
            inputTokens: 11, outputTokens: 22, upstreamResponseId: "req_v45_abc",
            cacheCreationInputTokens: 9, cacheReadInputTokens: 17))

        // Now seed rows under the three OTHER tiers via secondary-handle
        // writes that mirror each tier's writer-shape. We open the
        // additional anchors manually + insert rows whose entry_hash is
        // computed with the matching column-set, exactly as
        // ChainVerifier.verifyAnchorOpenAIRequestLog re-derives.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle"); return
        }
        defer { sqlite3_close(handle) }

        // Open three more anchors at high started_at_rowid so the post-v45
        // row stays attributable to migration-v45.
        func openAnchor(_ reason: String, startedAtRowid: Int64) -> Int64 {
            let sql = """
                INSERT INTO chain_anchors
                    (table_name, started_at, started_at_rowid, reason, operator_note)
                VALUES ('openai_request_log', ?, ?, ?, NULL);
            """
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, startedAtRowid)
            sqlite3_bind_text(stmt, 3, (reason as NSString).utf8String, -1, nil)
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
            return sqlite3_last_insert_rowid(handle)
        }

        // Tiers are distinguished by their column-set in canonicalColumns;
        // each row's anchor (above its id-range floor) selects the tier
        // the writer used. The seed inserts here are ABOVE the current
        // MAX(id) the anchors are opened at, so each row belongs to its
        // intended tier.
        let preV42Anchor   = openAnchor("fresh-install-pre-v42", startedAtRowid: 100)
        let v42Anchor      = openAnchor("migration-v42",         startedAtRowid: 200)
        let v44Anchor      = openAnchor("migration-v44",         startedAtRowid: 300)

        // Helper to compute the canonical hash for a tier-specific column
        // set + insert the row. Mirrors the writer's tier branching in
        // OpenAIRequestLogStore.record + ChainVerifier.verifyAnchorOpenAIRequestLog.
        func seedRow(
            anchorId: Int64,
            id: Int64,
            tier: String, // "pre-v42", "v42", "v44", "v45"
            ts: Double,
            cacheCreation: Int?,
            cacheRead: Int?
        ) {
            // Canonical-map by tier (mirrors the verifier's anchor-aware shape).
            var columns: [String: ChainHasher.CanonicalValue] = [
                "ts":        .real(ts),
                "surface":   .text("chat"),
                "status":    .integer(Int64(200)),
                "key_label": .text("seed-\(tier)"),
            ]
            if tier != "pre-v42" {
                columns["model_logged"]  = .text("seed-model")
                columns["resolved_tier"] = .text("cloud")
                columns["input_tokens"]  = .integer(5)
                columns["output_tokens"] = .integer(7)
            }
            if tier == "v44" || tier == "v45" {
                columns["upstream_response_id"] = .text("req_seed_\(tier)")
            }
            if tier == "v45" {
                columns["cache_creation_input_tokens"] = cacheCreation.map { .integer(Int64($0)) } ?? .null
                columns["cache_read_input_tokens"]     = cacheRead.map { .integer(Int64($0)) } ?? .null
            }
            // No prev_hash for these seed rows (first row in each anchor).
            let hash = ChainHasher.entryHash(
                table: "openai_request_log", columns: columns, prev: nil)

            let upstreamBind: String? = (tier == "v44" || tier == "v45") ? "req_seed_\(tier)" : nil
            let cacheCreateBind: Int? = (tier == "v45") ? cacheCreation : nil
            let cacheReadBind: Int? = (tier == "v45") ? cacheRead : nil
            let modelBind: String? = (tier != "pre-v42") ? "seed-model" : nil
            let tierBind: String? = (tier != "pre-v42") ? "cloud" : nil
            let inBind: Int? = (tier != "pre-v42") ? 5 : nil
            let outBind: Int? = (tier != "pre-v42") ? 7 : nil

            let sql = """
                INSERT INTO openai_request_log
                    (id, ts, surface, status, key_label,
                     model_logged, resolved_tier, input_tokens, output_tokens,
                     upstream_response_id,
                     cache_creation_input_tokens, cache_read_input_tokens,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, 'chat', 200, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?);
            """
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_bind_double(stmt, 2, ts)
            sqlite3_bind_text(stmt, 3, ("seed-\(tier)" as NSString).utf8String, -1, nil)
            if let modelBind {
                sqlite3_bind_text(stmt, 4, (modelBind as NSString).utf8String, -1, nil)
            } else { sqlite3_bind_null(stmt, 4) }
            if let tierBind {
                sqlite3_bind_text(stmt, 5, (tierBind as NSString).utf8String, -1, nil)
            } else { sqlite3_bind_null(stmt, 5) }
            if let inBind { sqlite3_bind_int64(stmt, 6, Int64(inBind)) }
            else { sqlite3_bind_null(stmt, 6) }
            if let outBind { sqlite3_bind_int64(stmt, 7, Int64(outBind)) }
            else { sqlite3_bind_null(stmt, 7) }
            if let upstreamBind {
                sqlite3_bind_text(stmt, 8, (upstreamBind as NSString).utf8String, -1, nil)
            } else { sqlite3_bind_null(stmt, 8) }
            if let cacheCreateBind { sqlite3_bind_int64(stmt, 9, Int64(cacheCreateBind)) }
            else { sqlite3_bind_null(stmt, 9) }
            if let cacheReadBind { sqlite3_bind_int64(stmt, 10, Int64(cacheReadBind)) }
            else { sqlite3_bind_null(stmt, 10) }
            sqlite3_bind_text(stmt, 11, (hash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 12, anchorId)
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }

        // Each seed row's id MUST be greater than its anchor's
        // started_at_rowid (verifier filter: `id > anchor.started_at_rowid`).
        seedRow(anchorId: preV42Anchor, id: 101, tier: "pre-v42", ts: 1_900_000_100,
                cacheCreation: nil, cacheRead: nil)
        seedRow(anchorId: v42Anchor,    id: 201, tier: "v42",     ts: 1_900_000_200,
                cacheCreation: nil, cacheRead: nil)
        seedRow(anchorId: v44Anchor,    id: 301, tier: "v44",     ts: 1_900_000_300,
                cacheCreation: nil, cacheRead: nil)
        // The earlier db.recordOpenAIRequest landed under migration-v45 as
        // the post-v45 chained write (id ~= 1, anchor's started_at_rowid=0).

        // Verify the whole table — must be GREEN across all four tiers.
        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        switch ChainVerifier.verifyOpenAIRequestLog(db2) {
        case .ok:
            break
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("expected .ok, got brokenAt \(table):\(rowid) expected=\(exp) actual=\(act)")
        case .noChain:
            Issue.record("expected .ok, got .noChain")
        }
    }

    // MARK: - 3. NULL-vs-zero canonical hash distinction (Schneier P1)

    /// Acceptance test #3 — write a row with `cacheReadInputTokens: 0` (the
    /// writer normalizes to nil) AND a row with explicit `.some(0)` via the
    /// test-only bypass that skips the normalizer. Their `entry_hash` values
    /// must DIFFER, proving NULL and 0 are distinct in the canonical map.
    /// This pins the Schneier P1 contract so a future writer change can't
    /// accidentally let `.some(0)` flow through.
    @Test("NULL-vs-zero canonical hash distinction: explicit .some(0) hashes DIFFERENTLY than normalized nil")
    func nullVsZeroCanonicalHashDistinction() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        let now = Date(timeIntervalSince1970: 1_900_200_000)

        // Row 1 — record(...) WITH the normalizer. cacheReadInputTokens: 0
        // collapses to nil before hashing/binding.
        #expect(db.recordOpenAIRequest(
            ts: now, surface: .chat, status: 200,
            keyLabel: "k", modelLogged: "m", resolvedTier: "cloud",
            inputTokens: 1, outputTokens: 1, upstreamResponseId: nil,
            cacheCreationInputTokens: nil, cacheReadInputTokens: 0))

        // Row 2 — bypass the normalizer. Same wall-clock ts/inputs as row 1
        // EXCEPT for cacheReadInputTokens, which is explicit .some(0). The
        // prev_hash differs (row 2 chains off row 1's entry_hash), but the
        // canonical column-set for row 2 includes
        // cache_read_input_tokens = .integer(0) where row 1's includes
        // cache_read_input_tokens = .null. Their hashes diverge — proving
        // the canonical map distinguishes NULL from 0.
        #expect(db.openAIRequestLogStore.recordChainedAllowingZeroForTesting(
            ts: now.addingTimeInterval(1), surface: .chat, status: 200,
            keyLabel: "k", modelLogged: "m", resolvedTier: "cloud",
            inputTokens: 1, outputTokens: 1, upstreamResponseId: nil,
            cacheCreationInputTokens: nil, cacheReadInputTokens: 0))

        // To make the policy contract precise, recompute both rows' hashes
        // from their (matching) inputs differing only in NULL vs 0 for
        // cache_read, and assert they differ. This is a pure-function
        // assertion independent of the prev_hash chain.
        let prev: String? = nil
        let baseColumns: [String: ChainHasher.CanonicalValue] = [
            "ts":            .real(now.timeIntervalSince1970),
            "surface":       .text("chat"),
            "status":        .integer(200),
            "key_label":     .text("k"),
            "model_logged":  .text("m"),
            "resolved_tier": .text("cloud"),
            "input_tokens":  .integer(1),
            "output_tokens": .integer(1),
            "upstream_response_id": .null,
            "cache_creation_input_tokens": .null,
        ]
        var withNull = baseColumns
        withNull["cache_read_input_tokens"] = .null
        var withZero = baseColumns
        withZero["cache_read_input_tokens"] = .integer(0)

        let hashNull = ChainHasher.entryHash(
            table: "openai_request_log", columns: withNull, prev: prev)
        let hashZero = ChainHasher.entryHash(
            table: "openai_request_log", columns: withZero, prev: prev)

        #expect(hashNull != hashZero,
                "NULL and 0 must produce DIFFERENT entry_hash bytes in the canonical map — pins Schneier P1 normalize-at-writer policy")

        // The persisted-row hashes also differ — they share the prev_hash
        // off row 1 / off the chain start, but rows 1 and 2 disagree on
        // cache_read. Read them back through the public store.
        let rows = db.recentOpenAIRequests(limit: 2)
        #expect(rows.count == 2)
        // Row written via record(...) normalizes to nil.
        #expect(rows.first(where: { $0.cacheReadInputTokens == nil }) != nil,
                "normalized-row's cache_read_input_tokens must read back nil")

        // And — the chain verifies (both rows hash correctly under their
        // anchor's tier).
        if case .ok = ChainVerifier.verifyOpenAIRequestLog(db) {} else {
            Issue.record("verify must be .ok across NULL-cache + zero-cache rows")
        }
    }

    // MARK: - 4. Fresh-install lazy-anchor on v45 shape

    /// Acceptance test #4 — on a fresh DB, the v45 migration opens
    /// `migration-v45` UNCONDITIONALLY at MAX(id)=0 (mirroring the v44
    /// opener). The first row written lands under `migration-v45` and its
    /// entry_hash INCLUDES the cache columns in the canonical map — even
    /// when they are nil (the v45-tier writer hashes `.null` for them).
    /// Any later flip of the column from NULL to a value diverges from
    /// the stored hash.
    @Test("Fresh-install lazy-anchor lands on v45 shape: first row hashes with cache columns in the canonical map")
    func freshInstallLazyAnchorLandsOnV45Shape() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        #expect(db.recordOpenAIRequest(
            ts: Date(timeIntervalSince1970: 1_900_300_000),
            surface: .chat, status: 200,
            keyLabel: "k", modelLogged: "m", resolvedTier: "cloud",
            inputTokens: 2, outputTokens: 3, upstreamResponseId: nil,
            cacheCreationInputTokens: nil, cacheReadInputTokens: nil))

        guard let raw = Self.rawChainBytes(path: path, id: 1) else {
            Issue.record("could not read row id=1"); return
        }
        let reason = Self.anchorReason(path: path, anchorId: raw.anchorId)
        #expect(reason == "migration-v45",
                "first row must land on migration-v45 (the v45 migration opens it unconditionally at MAX(id)=0); got \(reason ?? "<nil>")")

        // Tamper the cache_creation_input_tokens from NULL to a value: the
        // entry_hash was computed with `.null` for that column (v45 shape
        // includes it), so a flip diverges from the stored hash and
        // ChainVerifier catches it. This is what we PROVE by the .brokenAt
        // result: cache columns are part of the canonical row.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle"); return
        }
        defer { sqlite3_close(handle) }
        var err: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(handle,
            "UPDATE openai_request_log SET cache_creation_input_tokens = 99 WHERE id = 1;",
            nil, nil, &err) == SQLITE_OK)
        if let err { sqlite3_free(err) }

        // Fresh handle so ChainState cache doesn't mask the tamper.
        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        switch ChainVerifier.verifyOpenAIRequestLog(db2) {
        case .brokenAt:
            break  // expected — cache_creation_input_tokens rides the v45 canonical map
        default:
            Issue.record("expected .brokenAt after flipping cache_creation_input_tokens on a v45-shape row; this means the cache columns are NOT in the v45 canonical map (regression)")
        }
    }

    // MARK: - 5. migration-v44 row in a v45 DB stays v44-shape (Schneier P0)

    /// Acceptance test #5 — a row written under `migration-v44` BEFORE v45
    /// landed has an entry_hash computed over the v44 column-set (WITHOUT
    /// the two cache columns). After v45 runs (adds the columns + opens
    /// `migration-v45`), the `migration-v44` row's hash MUST re-derive
    /// identical to its stored value — proving the exclusion list keeps
    /// the row's canonical shape stable across the migration.
    ///
    /// This is the load-bearing Schneier P0 contract: if v45 mis-classifies
    /// migration-v44 rows as v45-shape, every legacy row breaks verification.
    @Test("migration-v44 row in a v45 DB: entry_hash recomputes identical — stays v44-shape (Schneier P0)")
    func migrationV44RowStaysV44ShapeInV45DB() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        // Boot the DB (runs migrations through v45).
        let db = SessionDatabase(path: path)

        // Open a `migration-v44`-reason anchor at started_at_rowid = 1000.
        // Then insert a row at id > 1000 attributable to that anchor. The
        // row's entry_hash is computed over the v44 column-set (WITHOUT
        // the two cache columns) — even though the table now has the
        // columns (post-v45 ALTER) and the row simply writes NULL to them.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle"); return
        }
        defer { sqlite3_close(handle) }

        var anchorStmt: OpaquePointer?
        let anchorSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('openai_request_log', ?, 1000, 'migration-v44', NULL);
        """
        #expect(sqlite3_prepare_v2(handle, anchorSQL, -1, &anchorStmt, nil) == SQLITE_OK)
        sqlite3_bind_double(anchorStmt, 1, Date().timeIntervalSince1970)
        #expect(sqlite3_step(anchorStmt) == SQLITE_DONE)
        let anchorId = sqlite3_last_insert_rowid(handle)
        sqlite3_finalize(anchorStmt)

        // Pre-migration v44-shape canonical hash. The cache columns DO NOT
        // appear in this map — exactly as a writer running pre-v45 would
        // have produced.
        let ts = 1_900_400_000.0
        let v44Columns: [String: ChainHasher.CanonicalValue] = [
            "ts":            .real(ts),
            "surface":       .text("chat"),
            "status":        .integer(200),
            "key_label":     .text("legacy-v44"),
            "model_logged":  .text("legacy-model"),
            "resolved_tier": .text("cloud"),
            "input_tokens":  .integer(8),
            "output_tokens": .integer(9),
            "upstream_response_id": .text("req_legacy_v44"),
        ]
        let v44Hash = ChainHasher.entryHash(
            table: "openai_request_log", columns: v44Columns, prev: nil)

        // Insert the row with that pre-v45 hash. cache_* columns persist
        // NULL — the columns exist now (post-v45 ALTER) but the row's
        // hash was computed without them.
        var rowStmt: OpaquePointer?
        let rowSQL = """
            INSERT INTO openai_request_log
                (id, ts, surface, status, key_label,
                 model_logged, resolved_tier, input_tokens, output_tokens,
                 upstream_response_id,
                 cache_creation_input_tokens, cache_read_input_tokens,
                 prev_hash, entry_hash, chain_anchor_id)
            VALUES (1001, ?, 'chat', 200, 'legacy-v44',
                    'legacy-model', 'cloud', 8, 9,
                    'req_legacy_v44',
                    NULL, NULL,
                    NULL, ?, ?);
        """
        #expect(sqlite3_prepare_v2(handle, rowSQL, -1, &rowStmt, nil) == SQLITE_OK)
        sqlite3_bind_double(rowStmt, 1, ts)
        sqlite3_bind_text(rowStmt, 2, (v44Hash as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(rowStmt, 3, anchorId)
        #expect(sqlite3_step(rowStmt) == SQLITE_DONE)
        sqlite3_finalize(rowStmt)

        // Read back what we stored so the test asserts re-derivation
        // matches the row's stored bytes (the Schneier P0 contract).
        guard let stored = Self.rawChainBytes(path: path, id: 1001) else {
            Issue.record("could not read seeded v44 row"); return
        }
        #expect(stored.hash == v44Hash,
                "pre-condition: seeded v44 row's stored entry_hash must match what we computed")

        // The whole table must verify — proving the v44-shape row
        // re-derives identically under the verifier's exclusion-list
        // branch (which keeps `migration-v44` out of useV45Shape).
        db.close()
        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        switch ChainVerifier.verifyOpenAIRequestLog(db2) {
        case .ok:
            break  // expected — Schneier P0: migration-v44 rows stay v44-shape forever
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("Schneier P0 regression: migration-v44 row \(table):\(rowid) was re-classified as v45-shape; expected=\(exp) actual=\(act)")
        case .noChain:
            Issue.record("expected .ok, got .noChain")
        }
    }
}

