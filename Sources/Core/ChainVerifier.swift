import Foundation
import SQLite3

/// Walks the tamper-evident audit chain and reports the first broken row
/// (or `.ok` if the chain verifies). Round 2 of Phase T.5 — see
/// `spec/architecture.md` → "Tamper-Evident Audit Chain (Phase T.5)" for
/// the full design.
///
/// Round 2 covers `token_events` only. Round 3 (`phase-t5-audit-chain-other-tables`)
/// extends `ChainVerifier` to the three remaining tables.
///
/// Verification model:
///   - Walk anchors for the table in id order.
///   - For each anchor, walk rows with `id > anchor.started_at_rowid`
///     (pre-anchor rows are anchor-from-now and have NULL hashes by design).
///   - For each row, recompute `SHA-256(prev_hash || canonicalRowBytes)`
///     over the bound column values and compare against the stored
///     `entry_hash`.
///   - First mismatch wins.
public enum ChainVerifier {

    public enum Result: Equatable, Sendable {
        /// All rows verify. `latestAnchorStartedAt` is the oldest active
        /// anchor's start timestamp — surfaced in the `senkani doctor`
        /// summary line. `repairs` counts `chain_anchors.reason LIKE
        /// 'repair-%'` rows (round 4 wires this; today it's always 0).
        case ok(latestAnchorStartedAt: Date?, repairs: Int)

        /// First broken row encountered. `expected` is what the verifier
        /// recomputed; `actual` is what the row stored. The `(table, rowid)`
        /// pair is the operator's repair coordinate.
        case brokenAt(table: String, rowid: Int64, expected: String, actual: String)

        /// No anchors exist for this table — fresh DB before any writes.
        case noChain
    }

    /// Verify the `token_events` chain on a SessionDatabase. Reads happen
    /// inside `parent.queue.sync` so writes can't interleave during the walk.
    public static func verifyTokenEvents(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTokenEvents(rawDB: db)
        }
    }

    /// Direct-to-handle variant for tests + CI tools that already have a
    /// raw SQLite pointer in hand. Caller is responsible for serialization.
    public static func verifyTokenEvents(rawDB db: OpaquePointer) -> Result {
        verifyTable(db: db, table: "token_events", verify: verifyAnchorTokenEvents)
    }

    // MARK: - T.5 round 3: extend to three more tables

    /// Verify all four chain participants and return the *first* failure
    /// across them. `senkani doctor --verify-chain` calls this and surfaces
    /// the per-table breakdown. Returns `.ok` only when every table either
    /// verifies cleanly or has no chain yet.
    public static func verifyAll(_ database: SessionDatabase) -> [String: Result] {
        return database.queue.sync {
            guard let db = database.db else {
                return ["token_events": .noChain]
            }
            return [
                "token_events":       verifyTable(db: db, table: "token_events",       verify: verifyAnchorTokenEvents),
                "validation_results": verifyTable(db: db, table: "validation_results", verify: verifyAnchorValidationResults),
                "sandboxed_results":  verifyTable(db: db, table: "sandboxed_results",  verify: verifyAnchorSandboxedResults),
                "commands":           verifyTable(db: db, table: "commands",           verify: verifyAnchorCommands),
                "pane_refresh_state": verifyTable(db: db, table: "pane_refresh_state", verify: verifyAnchorPaneRefreshState),
                "policy_snapshots":   verifyTable(db: db, table: "policy_snapshots",   verify: verifyAnchorPolicySnapshots),
                "confirmations":      verifyTable(db: db, table: "confirmations",      verify: verifyAnchorConfirmations),
                "trust_audits":       verifyTable(db: db, table: "trust_audits",       verify: verifyAnchorTrustAudits),
                "egress_decisions":   verifyTable(db: db, table: "egress_decisions",   verify: verifyAnchorEgressDecisions),
                "pack_audits":        verifyTable(db: db, table: "pack_audits",        verify: verifyAnchorPackAudits),
                "eval_results":       verifyTable(db: db, table: "eval_results",       verify: verifyAnchorEvalResults),
                "surrogate_writes":   verifyTable(db: db, table: "surrogate_writes",   verify: verifyAnchorSurrogateWrites),
                "workstream_handoffs": verifyTable(db: db, table: "workstream_handoffs", verify: verifyAnchorWorkstreamHandoffs),
                "openai_request_log": verifyTable(db: db, table: "openai_request_log", verify: verifyAnchorOpenAIRequestLog),
                "thread_handoff_event": verifyTable(db: db, table: "thread_handoff_event", verify: verifyAnchorThreadHandoffEvent),
            ]
        }
    }

    /// V.17c — `thread_handoff_event` chained-table verifier. Standalone
    /// accessor for callers (and the burst-integrity guard) that want the
    /// single-table verdict.
    public static func verifyThreadHandoffs(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "thread_handoff_event", verify: verifyAnchorThreadHandoffEvent)
        }
    }

    /// U.11a-4 — `workstream_handoffs` chained-table verifier.
    public static func verifyWorkstreamHandoffs(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "workstream_handoffs", verify: verifyAnchorWorkstreamHandoffs)
        }
    }

    public static func verifySurrogateWrites(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "surrogate_writes", verify: verifyAnchorSurrogateWrites)
        }
    }

    public static func verifyEvalResults(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "eval_results", verify: verifyAnchorEvalResults)
        }
    }

    public static func verifyEgressDecisions(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "egress_decisions", verify: verifyAnchorEgressDecisions)
        }
    }

    public static func verifyPackAudits(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "pack_audits", verify: verifyAnchorPackAudits)
        }
    }

    public static func verifyValidationResults(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "validation_results", verify: verifyAnchorValidationResults)
        }
    }

    public static func verifySandboxedResults(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "sandboxed_results", verify: verifyAnchorSandboxedResults)
        }
    }

    public static func verifyCommands(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "commands", verify: verifyAnchorCommands)
        }
    }

    public static func verifyPaneRefreshState(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "pane_refresh_state", verify: verifyAnchorPaneRefreshState)
        }
    }

    public static func verifyPolicySnapshots(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "policy_snapshots", verify: verifyAnchorPolicySnapshots)
        }
    }

    public static func verifyConfirmations(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "confirmations", verify: verifyAnchorConfirmations)
        }
    }

    public static func verifyTrustAudits(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "trust_audits", verify: verifyAnchorTrustAudits)
        }
    }

    /// V.13e-5 — `openai_request_log` chained-table verifier. The DB-backed
    /// OpenAI request log (migration v41 / `OpenAIRequestLogStore`) chains
    /// one metadata row per served request; this recomputes each row's
    /// `entry_hash` from the persisted columns and confirms `prev_hash`
    /// linkage, exactly as `ChainVerifier` does for the other participants.
    ///
    /// Cross-process by construction: it reads the table off a raw handle,
    /// so a fresh process at the same DB path verifies the chain the
    /// previous process wrote (the v13e-5 100-request burst-integrity guard).
    ///
    /// Wired into `verifyAll` (keyed `"openai_request_log"`) and the
    /// `senkani doctor --verify-chain` sweep as of
    /// `chain-verify-openai-request-log-not-in-verifyall-2026-05-27`; this
    /// standalone accessor remains for callers that want the single-table
    /// verdict (e.g. the V.13e-5 burst-integrity guard's cross-process check).
    public static func verifyOpenAIRequestLog(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "openai_request_log", verify: verifyAnchorOpenAIRequestLog)
        }
    }

    /// Generic table walker shared by all four participants.
    private static func verifyTable(
        db: OpaquePointer,
        table: String,
        verify: (OpaquePointer, Anchor) -> Result?
    ) -> Result {
        let anchors = readAnchors(db: db, table: table)
        guard !anchors.isEmpty else { return .noChain }

        let repairs = anchors.filter { $0.reason.hasPrefix("repair-") }.count

        for anchor in anchors {
            if let broken = verify(db, anchor) {
                return broken
            }
        }

        return .ok(
            latestAnchorStartedAt: anchors.first.map { Date(timeIntervalSince1970: $0.startedAt) },
            repairs: repairs
        )
    }

    // MARK: - Internals

    private struct Anchor {
        let id: Int64
        let table: String
        let startedAt: Double
        let startedAtRowid: Int64
        let reason: String
    }

    private static func readAnchors(db: OpaquePointer, table: String) -> [Anchor] {
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, table_name, started_at, started_at_rowid, reason
              FROM chain_anchors
             WHERE table_name = ?
             ORDER BY id ASC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var out: [Anchor] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let tname = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let startedAt = sqlite3_column_double(stmt, 2)
            let startedRowid = sqlite3_column_int64(stmt, 3)
            let reason = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            out.append(Anchor(
                id: id,
                table: tname,
                startedAt: startedAt,
                startedAtRowid: startedRowid,
                reason: reason
            ))
        }
        return out
    }

    /// Walk `token_events` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter skips both anchor-from-now backfilled
    /// rows (round 1 / round 3 migrations) and round-4 repair-rebound rows
    /// whose hashes were wiped to NULL when the new repair anchor opened.
    ///
    /// Phase B-ii: rows under legacy anchors (`migration-v4`,
    /// `fresh-install-pre-v18`) were hashed without `connection_id`; all
    /// other anchors include it. T.3a-4 (v33): rows under post-v33
    /// anchors (`migration-v33`, `fresh-install-pre-v35`,
    /// `migration-v35`, post-v35 `fresh-install`) include the four
    /// wasm_* columns (`.null` for regular token_events, populated for
    /// `source='wasm_kill'` rows). Pre-v33 anchors hash without the
    /// wasm_* columns. V.19a-2 (v35): rows under v35 anchors
    /// (`migration-v35`, post-v35 `fresh-install`) additionally include
    /// the five cached-token columns (`.null` for rows without cache
    /// observations, populated for inference rows carrying cache
    /// observations). Pre-v35 anchors hash without the cached-token
    /// columns. Mirrors the writer-side switch in
    /// `TokenEventStore.recordTokenEvent` + `recordWasmKill`.
    private static func verifyAnchorTokenEvents(db: OpaquePointer, anchor: Anchor) -> Result? {
        let includeConnectionId = !(anchor.reason == "migration-v4" || anchor.reason == "fresh-install-pre-v18")
        // U.11-pre a-3 (v38): `migration-v38` joins the post-v33 + v35
        // shape sets. v38 introduces no new columns — the
        // `workstream.<event>` rows shipped under v38 reuse the v35
        // canonical shape (wasm_* + cached_* as .null), distinguished
        // only by `source`. The rolling `fresh-install` anchor is NOT
        // renamed by v38, so it continues to mean "post-most-recent-
        // column-migration shape" (today: v35).
        //
        // U.11a-1 (v39): `migration-v39` likewise joins both shape sets.
        // v39 ships no new `token_events` columns — `contract.<event>`
        // rows reuse the v35 canonical shape, distinguished only by
        // `source`. Same `fresh-install`-not-renamed posture as v38.
        //
        // U.11a-4 (v40): `migration-v40` joins both shape sets — v40
        // ships no new `token_events` columns. `handoff.<event>` rows
        // shipped under v40 reuse the v35 canonical shape,
        // distinguished only by `source`. Same `fresh-install`-not-
        // renamed posture as v38/v39.
        let includeWasmKill = (
            anchor.reason == "migration-v33" ||
            anchor.reason == "fresh-install-pre-v35" ||
            anchor.reason == "migration-v35" ||
            anchor.reason == "fresh-install" ||
            anchor.reason == "migration-v38" ||
            anchor.reason == "migration-v39" ||
            anchor.reason == "migration-v40"
        )
        let includeCachedTokens = (
            anchor.reason == "migration-v35" ||
            anchor.reason == "fresh-install" ||
            anchor.reason == "migration-v38" ||
            anchor.reason == "migration-v39" ||
            anchor.reason == "migration-v40"
        )
        let sql = """
            SELECT id, timestamp, session_id, pane_id, project_root, source,
                   tool_name, model, input_tokens, output_tokens, saved_tokens,
                   cost_cents, feature, command, model_tier, connection_id,
                   wasm_reason, wasm_duration_us, wasm_budget_delta_us, wasm_tool_id,
                   cached_prompt_tokens, cache_write_tokens, cache_read_tokens,
                   prefill_ms_saved_estimate, cache_origin,
                   prev_hash, entry_hash
              FROM token_events
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "token_events", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":     .real(sqlite3_column_double(stmt, 1)),
                "session_id":    textValue(stmt, 2),
                "pane_id":       textOrNull(stmt, 3),
                "project_root":  textOrNull(stmt, 4),
                "source":        textValue(stmt, 5),
                "tool_name":     textOrNull(stmt, 6),
                "model":         textOrNull(stmt, 7),
                "input_tokens":  .integer(sqlite3_column_int64(stmt, 8)),
                "output_tokens": .integer(sqlite3_column_int64(stmt, 9)),
                "saved_tokens":  .integer(sqlite3_column_int64(stmt, 10)),
                "cost_cents":    .integer(sqlite3_column_int64(stmt, 11)),
                "feature":       textOrNull(stmt, 12),
                "command":       textOrNull(stmt, 13),
                "model_tier":    textOrNull(stmt, 14),
            ]
            if includeConnectionId {
                columns["connection_id"] = textOrNull(stmt, 15)
            }
            if includeWasmKill {
                columns["wasm_reason"]          = textOrNull(stmt, 16)
                columns["wasm_duration_us"]     = sqlite3_column_type(stmt, 17) == SQLITE_NULL
                                                    ? .null
                                                    : .integer(sqlite3_column_int64(stmt, 17))
                columns["wasm_budget_delta_us"] = sqlite3_column_type(stmt, 18) == SQLITE_NULL
                                                    ? .null
                                                    : .integer(sqlite3_column_int64(stmt, 18))
                columns["wasm_tool_id"]         = textOrNull(stmt, 19)
            }
            if includeCachedTokens {
                columns["cached_prompt_tokens"]      = sqlite3_column_type(stmt, 20) == SQLITE_NULL
                                                        ? .null
                                                        : .integer(sqlite3_column_int64(stmt, 20))
                columns["cache_write_tokens"]        = sqlite3_column_type(stmt, 21) == SQLITE_NULL
                                                        ? .null
                                                        : .integer(sqlite3_column_int64(stmt, 21))
                columns["cache_read_tokens"]         = sqlite3_column_type(stmt, 22) == SQLITE_NULL
                                                        ? .null
                                                        : .integer(sqlite3_column_int64(stmt, 22))
                columns["prefill_ms_saved_estimate"] = sqlite3_column_type(stmt, 23) == SQLITE_NULL
                                                        ? .null
                                                        : .integer(sqlite3_column_int64(stmt, 23))
                columns["cache_origin"]              = textOrNull(stmt, 24)
            }
            let prev = optionalText(stmt, 25)
            let stored = sqlite3_column_text(stmt, 26).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `validation_results` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    ///
    /// Anchor-aware canonical shape (v29): rows under
    /// `fresh-install-pre-v22` were hashed without the five v22-added
    /// columns (`axes`, `target_url`, `plan_steps`, `result_status`,
    /// `screenshot_path`); rows under any other anchor (`fresh-install`
    /// post-v29, `migration-v22`, future `repair-*`) include those
    /// columns. Mirrors the writer-side switch in
    /// `ValidationStore.resolveWriteAnchorLocked` / `canonicalColumns`.
    private static func verifyAnchorValidationResults(db: OpaquePointer, anchor: Anchor) -> Result? {
        let useV22Shape = (anchor.reason != "fresh-install-pre-v22")
        let sql = """
            SELECT id, session_id, file_path, validator_name, category, exit_code,
                   raw_output, advisory, duration_ms, created_at, delivered,
                   outcome, reason, surfaced_at,
                   axes, target_url, plan_steps, result_status, screenshot_path,
                   prev_hash, entry_hash
              FROM validation_results
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "validation_results", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            var columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":     textValue(stmt, 1),
                "file_path":      textValue(stmt, 2),
                "validator_name": textValue(stmt, 3),
                "category":       textValue(stmt, 4),
                "exit_code":      .integer(sqlite3_column_int64(stmt, 5)),
                "raw_output":     textOrNull(stmt, 6),
                "advisory":       textValue(stmt, 7),
                "duration_ms":    .integer(sqlite3_column_int64(stmt, 8)),
                "created_at":     .real(sqlite3_column_double(stmt, 9)),
                "delivered":      .integer(sqlite3_column_int64(stmt, 10)),
                "outcome":        textValue(stmt, 11),
                "reason":         textOrNull(stmt, 12),
                "surfaced_at":    sqlite3_column_type(stmt, 13) == SQLITE_NULL
                                    ? .null
                                    : .real(sqlite3_column_double(stmt, 13)),
            ]
            if useV22Shape {
                columns["axes"]            = textValue(stmt, 14)
                columns["target_url"]      = textOrNull(stmt, 15)
                columns["plan_steps"]      = textValue(stmt, 16)
                columns["result_status"]   = textOrNull(stmt, 17)
                columns["screenshot_path"] = textOrNull(stmt, 18)
            }
            let prev = optionalText(stmt, 19)
            let stored = sqlite3_column_text(stmt, 20).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `sandboxed_results` rows for one anchor. The table's PK is TEXT
    /// (`r_<uuid>`), so the verifier walks rows ordered by `created_at` and
    /// uses the *anchor row id* as the started_at_rowid bound (the migration
    /// recorded started_at_rowid = 0 for sandboxed_results because TEXT ids
    /// don't sort numerically). Rows whose `created_at < anchor.startedAt`
    /// are pre-anchor and skipped — they predate hashing.
    private static func verifyAnchorSandboxedResults(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, session_id, created_at, command, full_output,
                   line_count, byte_count,
                   prev_hash, entry_hash
              FROM sandboxed_results
             WHERE chain_anchor_id = ? AND created_at >= ? AND entry_hash IS NOT NULL
             ORDER BY created_at ASC, id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchor.id)
        sqlite3_bind_double(stmt, 2, anchor.startedAt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            // sandboxed_results.id is TEXT — surface its rowid index for the
            // operator. We re-read the OID via SQLite's implicit `oid` column
            // by issuing a small SELECT. For simplicity we just pass 0 as
            // a sentinel rowid; the (table, id-text) pair is what matters
            // and we can extend the brokenAt enum in round 4 if needed.
            let columns: [String: ChainHasher.CanonicalValue] = [
                "id":          textValue(stmt, 0),
                "session_id":  textValue(stmt, 1),
                "created_at":  .real(sqlite3_column_double(stmt, 2)),
                "command":     textValue(stmt, 3),
                "full_output": textValue(stmt, 4),
                "line_count":  .integer(sqlite3_column_int64(stmt, 5)),
                "byte_count":  .integer(sqlite3_column_int64(stmt, 6)),
            ]
            let prev = optionalText(stmt, 7)
            let stored = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            let expected = ChainHasher.entryHash(
                table: "sandboxed_results", columns: columns, prev: prev
            )
            if expected != stored {
                return .brokenAt(
                    table: "sandboxed_results",
                    rowid: 0,
                    expected: expected,
                    actual: stored
                )
            }
        }
        return nil
    }

    /// Walk `commands` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    ///
    /// Phase B-ii: rows under legacy anchors (`migration-v5`,
    /// `fresh-install-pre-v18`) were hashed without `connection_id`; all
    /// other anchors include it. Mirrors the writer-side switch in
    /// `CommandStore.recordCommand` / `recordBudgetDecision`.
    private static func verifyAnchorCommands(db: OpaquePointer, anchor: Anchor) -> Result? {
        let includeConnectionId = !(anchor.reason == "migration-v5" || anchor.reason == "fresh-install-pre-v18")
        let sql = """
            SELECT id, session_id, timestamp, tool_name, command,
                   raw_bytes, compressed_bytes, feature, output_preview,
                   budget_decision, connection_id,
                   prev_hash, entry_hash
              FROM commands
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "commands", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            var columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":       textValue(stmt, 1),
                "timestamp":        .real(sqlite3_column_double(stmt, 2)),
                "tool_name":        textValue(stmt, 3),
                "command":          textOrNull(stmt, 4),
                "raw_bytes":        .integer(sqlite3_column_int64(stmt, 5)),
                "compressed_bytes": .integer(sqlite3_column_int64(stmt, 6)),
                "feature":          textOrNull(stmt, 7),
                "output_preview":   textOrNull(stmt, 8),
                "budget_decision":  textOrNull(stmt, 9),
            ]
            if includeConnectionId {
                columns["connection_id"] = textOrNull(stmt, 10)
            }
            let prev = optionalText(stmt, 11)
            let stored = sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `policy_snapshots` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    /// Canonical input is the four data columns (the chain columns are
    /// excluded by `ChainHasher.excludedColumns` contract).
    private static func verifyAnchorPolicySnapshots(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, session_id, captured_at, policy_hash, policy_json,
                   prev_hash, entry_hash
              FROM policy_snapshots
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "policy_snapshots", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":  textValue(stmt, 1),
                "captured_at": .real(sqlite3_column_double(stmt, 2)),
                "policy_hash": textValue(stmt, 3),
                "policy_json": textValue(stmt, 4),
            ]
            let prev = optionalText(stmt, 5)
            let stored = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `pane_refresh_state` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorPaneRefreshState(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, project_root, tile_id, cache_type, cache_duration,
                   next_update, retry_count, last_error, notice, content_available,
                   written_at, prev_hash, entry_hash
              FROM pane_refresh_state
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "pane_refresh_state", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "project_root":      textValue(stmt, 1),
                "tile_id":           textValue(stmt, 2),
                "cache_type":        textValue(stmt, 3),
                "cache_duration":    .real(sqlite3_column_double(stmt, 4)),
                "next_update":       .real(sqlite3_column_double(stmt, 5)),
                "retry_count":       .integer(sqlite3_column_int64(stmt, 6)),
                "last_error":        textOrNull(stmt, 7),
                "notice":            textOrNull(stmt, 8),
                "content_available": .integer(sqlite3_column_int64(stmt, 9)),
                "written_at":        .real(sqlite3_column_double(stmt, 10)),
            ]
            let prev = optionalText(stmt, 11)
            let stored = sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `confirmations` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    /// Canonical input is the six non-chain columns of `ConfirmationStore.record`.
    private static func verifyAnchorConfirmations(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, tool_name, requested_at, decided_at, decision,
                   decided_by, reason,
                   prev_hash, entry_hash
              FROM confirmations
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "confirmations", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "tool_name":    textValue(stmt, 1),
                "requested_at": .real(sqlite3_column_double(stmt, 2)),
                "decided_at":   .real(sqlite3_column_double(stmt, 3)),
                "decision":     textValue(stmt, 4),
                "decided_by":   textValue(stmt, 5),
                "reason":       textOrNull(stmt, 6),
            ]
            let prev = optionalText(stmt, 7)
            let stored = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `trust_audits` rows for one anchor. The store writes flag,
    /// label, promotion, and override rows through the same canonical-
    /// input builder — every non-chain column appears in the dictionary,
    /// with NULLs in the kind-specific slots.
    ///
    /// Anchor-aware canonical shape (v28): rows under
    /// `fresh-install-pre-v25` were hashed without the three v25-added
    /// columns (`observed_rate`, `observed_sample`, `call_id`); rows
    /// under any other anchor (`fresh-install` post-v28, `migration-v25`,
    /// future `repair-*`) include those columns. Mirrors the writer-side
    /// switch in `TrustAuditStore.resolveWriteAnchorLocked` /
    /// `canonicalColumns`.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorTrustAudits(db: OpaquePointer, anchor: Anchor) -> Result? {
        let useV25Shape = (anchor.reason != "fresh-install-pre-v25")
        let sql = """
            SELECT id, kind, created_at, session_id, pane_id, tool_name,
                   reason, score, correlation_count, flag_id, label, labeled_by,
                   observed_rate, observed_sample, call_id,
                   prev_hash, entry_hash
              FROM trust_audits
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "trust_audits", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            var columns: [String: ChainHasher.CanonicalValue] = [
                "kind":              textValue(stmt, 1),
                "created_at":        .real(sqlite3_column_double(stmt, 2)),
                "session_id":        textOrNull(stmt, 3),
                "pane_id":           textOrNull(stmt, 4),
                "tool_name":         textOrNull(stmt, 5),
                "reason":            textOrNull(stmt, 6),
                "score":             sqlite3_column_type(stmt, 7) == SQLITE_NULL
                                        ? .null
                                        : .integer(sqlite3_column_int64(stmt, 7)),
                "correlation_count": sqlite3_column_type(stmt, 8) == SQLITE_NULL
                                        ? .null
                                        : .integer(sqlite3_column_int64(stmt, 8)),
                "flag_id":           sqlite3_column_type(stmt, 9) == SQLITE_NULL
                                        ? .null
                                        : .integer(sqlite3_column_int64(stmt, 9)),
                "label":             textOrNull(stmt, 10),
                "labeled_by":        textOrNull(stmt, 11),
            ]
            if useV25Shape {
                columns["observed_rate"]   = sqlite3_column_type(stmt, 12) == SQLITE_NULL
                                                ? .null
                                                : .real(sqlite3_column_double(stmt, 12))
                columns["observed_sample"] = sqlite3_column_type(stmt, 13) == SQLITE_NULL
                                                ? .null
                                                : .integer(sqlite3_column_int64(stmt, 13))
                columns["call_id"]         = textOrNull(stmt, 14)
            }
            let prev = optionalText(stmt, 15)
            let stored = sqlite3_column_text(stmt, 16).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `egress_decisions` rows for one anchor. T.1b switches the
    /// canonical shape per anchor: pre-v23 anchors (`fresh-install-pre-v23`)
    /// hashed without `judge_rationale` / `pane_mode`; all other anchors —
    /// `migration-v23`, post-v23 `fresh-install`, future `repair-*`
    /// rebinds — include both in the canonical map. Mirrored on the
    /// writer side in `EgressDecisionStore.record`.
    ///
    /// T.1d-4 (v46): rows under a v46+ anchor carry `body_excerpt` in their
    /// canonical hash. EXCLUSION-form (not an allowlist) so a future
    /// `repair-*` rebind inherits the current (v46) shape. The THREE
    /// pre-v46 anchor reasons omit the column — crucially `migration-v23`
    /// is here (Schneier P0): those rows were hashed under the v23 shape
    /// and stay v23 forever.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorEgressDecisions(db: OpaquePointer, anchor: Anchor) -> Result? {
        let useLegacyShape = (anchor.reason == "fresh-install-pre-v23")
        let useV46Shape = ![
            "fresh-install-pre-v23", "migration-v23", "fresh-install-pre-v46",
        ].contains(anchor.reason)
        // T.1d-5 r52 Allspaw P2 (v47): rows under a v47+ anchor carry
        // `body_excerpt_capture_state` in their canonical hash. EXCLUSION-form
        // mirrors the v46 predicate. The FOUR pre-v47 anchor reasons — the
        // three pre-v46 reasons PLUS `migration-v46` — omit the column.
        // Crucially `migration-v46` is here (Schneier P0): those rows were
        // hashed under the v46 shape (body_excerpt but NO capture_state) and
        // stay v46-shape forever. Mirrors the writer-side `useV47Shape` in
        // `EgressDecisionStore.record`.
        let useV47Shape = ![
            "fresh-install-pre-v23", "migration-v23", "fresh-install-pre-v46",
            "migration-v46", "fresh-install-pre-v47",
        ].contains(anchor.reason)
        let sql = """
            SELECT id, timestamp, host, method, decision, rule_id, latency_us,
                   pane_id, project_root,
                   judge_rationale, pane_mode,
                   body_excerpt,
                   body_excerpt_capture_state,
                   prev_hash, entry_hash
              FROM egress_decisions
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "egress_decisions", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":     .real(sqlite3_column_double(stmt, 1)),
                "host":          textValue(stmt, 2),
                "method":        textValue(stmt, 3),
                "decision":      textValue(stmt, 4),
                "rule_id":       textValue(stmt, 5),
                "latency_us":    .integer(sqlite3_column_int64(stmt, 6)),
                "pane_id":       textOrNull(stmt, 7),
                "project_root":  textOrNull(stmt, 8),
            ]
            if !useLegacyShape {
                columns["judge_rationale"] = textOrNull(stmt, 9)
                columns["pane_mode"] = textOrNull(stmt, 10)
            }
            if useV46Shape {
                // T.1d-4: body_excerpt rides the v46 shape. The persisted
                // bytes are already truncate-then-redacted by the writer
                // (Schneier P1). NULL → .null in canonical map.
                if sqlite3_column_type(stmt, 11) == SQLITE_NULL {
                    columns["body_excerpt"] = .null
                } else if let bytes = sqlite3_column_blob(stmt, 11) {
                    let len = Int(sqlite3_column_bytes(stmt, 11))
                    let data = Data(bytes: bytes, count: len)
                    columns["body_excerpt"] = .blob(data)
                } else {
                    columns["body_excerpt"] = .blob(Data())
                }
            }
            if useV47Shape {
                // v47: body_excerpt_capture_state rides the v47 shape as
                // TEXT (the EgressBodyCaptureState rawValue) or NULL. Read
                // it back exactly as the writer bound it so the entry_hash
                // re-derives byte-identically.
                columns["body_excerpt_capture_state"] = textOrNull(stmt, 12)
            }
            let prev = optionalText(stmt, 13)
            let stored = sqlite3_column_text(stmt, 14).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `openai_request_log` rows for one anchor.
    ///
    /// Anchor-aware canonical shape (v42): rows under
    /// `fresh-install-pre-v42` (the renamed v41 lazy anchor) were hashed
    /// without the four V.13e-7 producer-metadata columns
    /// (`model_logged`, `resolved_tier`, `input_tokens`, `output_tokens`);
    /// rows under any other anchor — `migration-v42`, post-v42
    /// `fresh-install` (lazy-created after the v42 rename), future
    /// `repair-*` rebinds — include those columns. Mirrors the writer-
    /// side single-shape post-v42 in `OpenAIRequestLogStore.record`.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorOpenAIRequestLog(db: OpaquePointer, anchor: Anchor) -> Result? {
        let useV42Shape = (anchor.reason != "fresh-install-pre-v42")
        // V.13b-3 — rows under a v44+ anchor carry `upstream_response_id` in
        // their canonical hash. EXCLUSION-form (not an allowlist) so a future
        // `repair-*` rebind inherits the current (v44) shape, matching the v42
        // predicate's philosophy and the writer (single-shape post-v44). The
        // three pre-v44 anchor reasons omit the column. (If `openai_request_log`
        // is ever added to `ChainRepairer.supportedTables`, this exclusion-form
        // already classifies its `repair-*` rows as v44-shape — no change needed.)
        let useV44Shape = ![
            "fresh-install-pre-v42", "migration-v42", "fresh-install-pre-v44",
        ].contains(anchor.reason)
        // V.13b prompt-caching B — rows under a v45+ anchor carry
        // `cache_creation_input_tokens` + `cache_read_input_tokens` in their
        // canonical hash. EXCLUSION-form mirrors the v44 predicate. The FIVE
        // pre-v45 anchor reasons omit the columns — crucially `migration-v44`
        // is here (Schneier P0): those rows were hashed under the v44 shape
        // and stay v44 forever. A future `repair-*` rebind inherits v45.
        let useV45Shape = ![
            "fresh-install-pre-v42", "migration-v42", "fresh-install-pre-v44",
            "migration-v44", "fresh-install-pre-v45",
        ].contains(anchor.reason)
        let sql = """
            SELECT id, ts, surface, status, key_label,
                   model_logged, resolved_tier, input_tokens, output_tokens,
                   upstream_response_id,
                   cache_creation_input_tokens, cache_read_input_tokens,
                   prev_hash, entry_hash
              FROM openai_request_log
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "openai_request_log", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            var columns: [String: ChainHasher.CanonicalValue] = [
                "ts":        .real(sqlite3_column_double(stmt, 1)),
                "surface":   textValue(stmt, 2),
                "status":    .integer(sqlite3_column_int64(stmt, 3)),
                "key_label": textOrNull(stmt, 4),
            ]
            if useV42Shape {
                columns["model_logged"]  = textOrNull(stmt, 5)
                columns["resolved_tier"] = textOrNull(stmt, 6)
                columns["input_tokens"]  = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                                              ? .null : .integer(sqlite3_column_int64(stmt, 7))
                columns["output_tokens"] = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                                              ? .null : .integer(sqlite3_column_int64(stmt, 8))
            }
            if useV44Shape {
                columns["upstream_response_id"] = textOrNull(stmt, 9)
            }
            if useV45Shape {
                columns["cache_creation_input_tokens"] =
                    sqlite3_column_type(stmt, 10) == SQLITE_NULL
                        ? .null : .integer(sqlite3_column_int64(stmt, 10))
                columns["cache_read_input_tokens"] =
                    sqlite3_column_type(stmt, 11) == SQLITE_NULL
                        ? .null : .integer(sqlite3_column_int64(stmt, 11))
            }
            let prev = optionalText(stmt, 12)
            let stored = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `eval_results` rows for one anchor. T.2b-1 ships the table
    /// + writer; canonical column shape mirrors the writer in
    /// `EvalResultsStore.record`.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorEvalResults(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, timestamp, model_id, fixture_id,
                   precision, recall, f1, duration_ms,
                   prev_hash, entry_hash
              FROM eval_results
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "eval_results", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":   .real(sqlite3_column_double(stmt, 1)),
                "model_id":    textValue(stmt, 2),
                "fixture_id":  textValue(stmt, 3),
                "precision":   .real(sqlite3_column_double(stmt, 4)),
                "recall":      .real(sqlite3_column_double(stmt, 5)),
                "f1":          .real(sqlite3_column_double(stmt, 6)),
                "duration_ms": .integer(sqlite3_column_int64(stmt, 7)),
            ]
            let prev = optionalText(stmt, 8)
            let stored = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `surrogate_writes` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    /// T.2c-2 — chain rows carry `(engagement_id, surrogate_id, category, at)`;
    /// `original_value` is intentionally absent (privacy boundary lives in
    /// the encrypted `SurrogateVault`, not in this audit chain).
    private static func verifyAnchorSurrogateWrites(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, engagement_id, surrogate_id, category, at,
                   prev_hash, entry_hash
              FROM surrogate_writes
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "surrogate_writes", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "engagement_id": textValue(stmt, 1),
                "surrogate_id":  textValue(stmt, 2),
                "category":      textValue(stmt, 3),
                "at":            .real(sqlite3_column_double(stmt, 4)),
            ]
            let prev = optionalText(stmt, 5)
            let stored = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `pack_audits` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorPackAudits(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, pack_name, pack_version, event, at, source_path, sha256,
                   applied_skills,
                   prev_hash, entry_hash
              FROM pack_audits
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "pack_audits", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "pack_name":      textValue(stmt, 1),
                "pack_version":   textValue(stmt, 2),
                "event":          textValue(stmt, 3),
                "at":             .real(sqlite3_column_double(stmt, 4)),
                "source_path":    textValue(stmt, 5),
                "sha256":         textOrNull(stmt, 6),
                "applied_skills": textValue(stmt, 7),
            ]
            let prev = optionalText(stmt, 8)
            let stored = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `workstream_handoffs` rows for one anchor. U.11a-4 (v40):
    /// columns hashed are the eight non-chain payload columns plus
    /// the row's `id` (BLOB UUID → text uuidString — see the writer
    /// in `TokenEventStore.recordBlockedHandoff` for the same
    /// convention). Anchor reason is not shape-switched: v40 is the
    /// table's birthday so every row has the same canonical shape.
    /// `entry_hash IS NOT NULL` filter — see
    /// `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorWorkstreamHandoffs(db: OpaquePointer, anchor: Anchor) -> Result? {
        // BLOB primary key — the chain anchor's `started_at_rowid`
        // refers to SQLite's implicit ROWID, not to `id` (which is a
        // 16-byte BLOB). Walk via `rowid > ?` and order by rowid so
        // insertion order matches the writer's chain order.
        let sql = """
            SELECT rowid, id, workstream_id, contract_id, gate_id,
                   blocker_reason, owner, next_action, evidence_bundle,
                   created_at, prev_hash, entry_hash
              FROM workstream_handoffs
             WHERE chain_anchor_id = ? AND rowid > ? AND entry_hash IS NOT NULL
             ORDER BY rowid ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchor.id)
        sqlite3_bind_int64(stmt, 2, anchor.startedAtRowid)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            // Re-derive UUID-as-text for each BLOB id column to match
            // the writer's canonical-hash payload convention.
            let idText      = uuidBlobText(stmt, 1) ?? ""
            let wsText      = uuidBlobText(stmt, 2) ?? ""
            let contractTxt = uuidBlobText(stmt, 3) ?? ""
            let gateText    = uuidBlobText(stmt, 4) ?? ""
            let reasonText  = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let ownerText   = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let nextText    = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let evidenceTxt = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            let createdAt   = sqlite3_column_int64(stmt, 9)
            let prev        = optionalText(stmt, 10)
            let stored      = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""

            let columns: [String: ChainHasher.CanonicalValue] = [
                "id":              .text(idText),
                "workstream_id":   .text(wsText),
                "contract_id":     .text(contractTxt),
                "gate_id":         .text(gateText),
                "blocker_reason":  .text(reasonText),
                "owner":           .text(ownerText),
                "next_action":     .text(nextText),
                "evidence_bundle": .text(evidenceTxt),
                "created_at":      .integer(createdAt),
            ]
            let expected = ChainHasher.entryHash(
                table: "workstream_handoffs", columns: columns, prev: prev
            )
            if expected != stored {
                return .brokenAt(
                    table: "workstream_handoffs",
                    rowid: rowid,
                    expected: expected,
                    actual: stored)
            }
        }
        return nil
    }

    /// Walk `thread_handoff_event` rows for one anchor. V.17c (v43):
    /// columns hashed are the eight non-chain payload columns. The PK is
    /// an INTEGER AUTOINCREMENT id (like `openai_request_log`), so the
    /// generic integer-keyed `walkTable` path applies. No per-anchor
    /// shape switch: v43 is the table's birthday, so every row hashes
    /// the same canonical shape. The canonical map MUST match the
    /// writer in `TokenEventStore.recordThreadHandoff` exactly —
    /// `override_reason` is NULL for a normal handoff and TEXT for an
    /// operator override.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorThreadHandoffEvent(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, created_at, from_provider, to_provider, thread_id,
                   accepted_by, pre_handoff_event_count, post_handoff_event_count,
                   override_reason,
                   prev_hash, entry_hash
              FROM thread_handoff_event
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "thread_handoff_event", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "created_at":               .real(sqlite3_column_double(stmt, 1)),
                "from_provider":            textValue(stmt, 2),
                "to_provider":              textValue(stmt, 3),
                "thread_id":                textValue(stmt, 4),
                "accepted_by":              textValue(stmt, 5),
                "pre_handoff_event_count":  .integer(sqlite3_column_int64(stmt, 6)),
                "post_handoff_event_count": .integer(sqlite3_column_int64(stmt, 7)),
                "override_reason":          textOrNull(stmt, 8),
            ]
            let prev = optionalText(stmt, 9)
            let stored = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Decode a 16-byte BLOB UUID column into its RFC-4122 string
    /// form. Returns nil for NULL columns or wrong-length blobs.
    /// Mirrors the writer's `UUID.uuidString` payload convention so
    /// the canonical-hash bytes match across writer + verifier.
    private static func uuidBlobText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) == SQLITE_BLOB else { return nil }
        let len = sqlite3_column_bytes(stmt, index)
        guard len == 16,
              let raw = sqlite3_column_blob(stmt, index) else { return nil }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let uuid = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid).uuidString
    }

    // MARK: - Generic helpers

    /// Walks an integer-keyed table; calls `decode` for each row.
    private static func walkTable(
        db: OpaquePointer,
        table: String,
        anchor: Anchor,
        sql: String,
        decode: (OpaquePointer?) -> (Int64, [String: ChainHasher.CanonicalValue], String?, String)
    ) -> Result? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchor.id)
        sqlite3_bind_int64(stmt, 2, anchor.startedAtRowid)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let (rowid, columns, prev, stored) = decode(stmt)
            let expected = ChainHasher.entryHash(table: table, columns: columns, prev: prev)
            if expected != stored {
                return .brokenAt(table: table, rowid: rowid, expected: expected, actual: stored)
            }
        }
        return nil
    }

    private static func optionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private static func textValue(_ stmt: OpaquePointer?, _ index: Int32) -> ChainHasher.CanonicalValue {
        if let cstr = sqlite3_column_text(stmt, index) {
            return .text(String(cString: cstr))
        }
        return .text("")
    }

    private static func textOrNull(_ stmt: OpaquePointer?, _ index: Int32) -> ChainHasher.CanonicalValue {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return .null }
        if let cstr = sqlite3_column_text(stmt, index) {
            return .text(String(cString: cstr))
        }
        return .null
    }
}
