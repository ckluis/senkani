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
            ]
        }
    }

    public static func verifyEgressDecisions(_ database: SessionDatabase) -> Result {
        return database.queue.sync {
            guard let db = database.db else { return .noChain }
            return verifyTable(db: db, table: "egress_decisions", verify: verifyAnchorEgressDecisions)
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
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)

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
    /// other anchors include it. Mirrors the writer-side switch in
    /// `TokenEventStore.recordTokenEvent`.
    private static func verifyAnchorTokenEvents(db: OpaquePointer, anchor: Anchor) -> Result? {
        let includeConnectionId = !(anchor.reason == "migration-v4" || anchor.reason == "fresh-install-pre-v18")
        let sql = """
            SELECT id, timestamp, session_id, pane_id, project_root, source,
                   tool_name, model, input_tokens, output_tokens, saved_tokens,
                   cost_cents, feature, command, model_tier, connection_id,
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
            let prev = optionalText(stmt, 16)
            let stored = sqlite3_column_text(stmt, 17).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `validation_results` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorValidationResults(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, session_id, file_path, validator_name, category, exit_code,
                   raw_output, advisory, duration_ms, created_at, delivered,
                   outcome, reason, surfaced_at,
                   prev_hash, entry_hash
              FROM validation_results
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "validation_results", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
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
            let prev = optionalText(stmt, 14)
            let stored = sqlite3_column_text(stmt, 15).map { String(cString: $0) } ?? ""
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

    /// Walk `trust_audits` rows for one anchor. The store writes both flag
    /// rows and label rows through the same canonical-input shape — every
    /// non-chain column appears in the dictionary, with NULLs in the
    /// kind-specific slots. Verification reads the same eleven columns
    /// regardless of `kind`.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorTrustAudits(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, kind, created_at, session_id, pane_id, tool_name,
                   reason, score, correlation_count, flag_id, label, labeled_by,
                   prev_hash, entry_hash
              FROM trust_audits
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "trust_audits", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
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
            let prev = optionalText(stmt, 12)
            let stored = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
    }

    /// Walk `egress_decisions` rows for one anchor.
    /// `entry_hash IS NOT NULL` filter — see `verifyAnchorTokenEvents` notes.
    private static func verifyAnchorEgressDecisions(db: OpaquePointer, anchor: Anchor) -> Result? {
        let sql = """
            SELECT id, timestamp, host, method, decision, rule_id, latency_us,
                   pane_id, project_root,
                   prev_hash, entry_hash
              FROM egress_decisions
             WHERE chain_anchor_id = ? AND id > ? AND entry_hash IS NOT NULL
             ORDER BY id ASC;
        """
        return walkTable(db: db, table: "egress_decisions", anchor: anchor, sql: sql) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":     .real(sqlite3_column_double(stmt, 1)),
                "host":          textValue(stmt, 2),
                "method":        textValue(stmt, 3),
                "decision":      textValue(stmt, 4),
                "rule_id":       textValue(stmt, 5),
                "latency_us":    .integer(sqlite3_column_int64(stmt, 6)),
                "pane_id":       textOrNull(stmt, 7),
                "project_root":  textOrNull(stmt, 8),
            ]
            let prev = optionalText(stmt, 9)
            let stored = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
            return (rowid, columns, prev, stored)
        }
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
