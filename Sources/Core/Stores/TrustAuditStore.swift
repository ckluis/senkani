import Foundation
import SQLite3

/// Owns the `trust_audits` table — Phase U.4a round 1.
///
/// Two row kinds in one append-only chained table:
///   - `kind = 'flag'` — emitted by `FragmentationDetector`. Each row
///     stores the reason, score, session/pane/tool keys, and a
///     `correlation_count`. `flag_id` is NULL.
///   - `kind = 'label'` — operator-confirmed FP/TP for an earlier
///     flag row. `flag_id` references the flag's rowid; `label`
///     carries `'fp'` or `'tp'`.
///
/// Append-only by design — a label is a NEW row, not an UPDATE on
/// the flag. This preserves the chain invariant (no row mutates
/// after insert) and gives the operator a complete history if they
/// re-label the same flag.
///
/// Chain wiring follows the same pattern as `ConfirmationStore` and
/// `TokenEventStore`: one `ChainState` instance, the canonical input
/// excludes the three chain columns, and the cache updates only on
/// successful insert. Migration v12 owns the canonical schema.
final class TrustAuditStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    private let chain = ChainState(table: "trust_audits")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Writes

    /// Insert one flag row for a `FragmentationDetector.Flag`. Returns
    /// the new rowid (the operator references this id when labelling
    /// FP/TP), or -1 on failure.
    @discardableResult
    func recordFlag(_ flag: FragmentationDetector.Flag, score: Int) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }

            // recordFlag does NOT lazy-open migration-v25 — flag rows
            // happen far more often than promotion/override, and they
            // carry no v25-column values. They chain under whatever
            // anchor is current with the matching canonical shape.
            let (anchorId, useV25Shape) = resolveWriteAnchorLocked(db: db, ensureV25: false)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns = Self.canonicalColumns(
                kind: "flag",
                createdAt: flag.createdAt,
                sessionId: flag.sessionId,
                paneId: flag.paneId,
                toolName: flag.toolName,
                reason: flag.reason.rawValue,
                score: Int64(score),
                correlationCount: Int64(flag.correlationCount),
                flagId: nil,
                label: nil,
                labeledBy: nil,
                observedRate: nil,
                observedSample: nil,
                callId: nil,
                useV25Shape: useV25Shape
            )
            let entryHash = ChainHasher.entryHash(
                table: "trust_audits", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO trust_audits
                    (kind, created_at, session_id, pane_id, tool_name,
                     reason, score, correlation_count,
                     flag_id, label, labeled_by,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ("flag" as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, flag.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (flag.sessionId as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 4, flag.paneId)
            sqlite3_bind_text(stmt, 5, (flag.toolName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (flag.reason.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 7, Int64(score))
            sqlite3_bind_int64(stmt, 8, Int64(flag.correlationCount))
            Self.bindOptionalText(stmt, 9, prevHash)
            sqlite3_bind_text(stmt, 10, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 11, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Insert a label row referring back to a flag's rowid. `label`
    /// must be `.fp` or `.tp`. Returns the new rowid or -1 on failure.
    @discardableResult
    func recordLabel(
        flagId: Int64,
        label: TrustLabel,
        labeledBy: String,
        at: Date = Date()
    ) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }

            let (anchorId, useV25Shape) = resolveWriteAnchorLocked(db: db, ensureV25: false)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns = Self.canonicalColumns(
                kind: "label",
                createdAt: at,
                sessionId: nil,
                paneId: nil,
                toolName: nil,
                reason: nil,
                score: nil,
                correlationCount: nil,
                flagId: flagId,
                label: label.rawValue,
                labeledBy: labeledBy,
                observedRate: nil,
                observedSample: nil,
                callId: nil,
                useV25Shape: useV25Shape
            )
            let entryHash = ChainHasher.entryHash(
                table: "trust_audits", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO trust_audits
                    (kind, created_at, session_id, pane_id, tool_name,
                     reason, score, correlation_count,
                     flag_id, label, labeled_by,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ("label" as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, at.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, flagId)
            sqlite3_bind_text(stmt, 4, (label.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (labeledBy as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 6, prevHash)
            sqlite3_bind_text(stmt, 7, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 8, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return sqlite3_last_insert_rowid(db)
        }
    }

    // MARK: - U.4b-1 writers (promotion + override)

    /// Insert one `promotion` row recording a `set-mode` flip. `from`
    /// and `to` are the prior and new modes (raw strings). `fpRateMax`
    /// and `minLabeledSample` may be nil only when the demotion path
    /// (`.blocking → .softFlag`) writes a row without thresholds —
    /// the gate doesn't apply to demotions.
    ///
    /// Chain shape note (v28): lazy-opens a `migration-v25` anchor on
    /// first call when the current anchor is `fresh-install-pre-v25`
    /// (existing install upgraded across the v28 rename). Under the
    /// v25 anchor, `observed_rate` + `observed_sample` (this writer)
    /// and `call_id` (recordOverride) participate in the canonical
    /// hash map. Post-v28 fresh installs land directly on a
    /// `fresh-install` anchor that already uses the v25 shape, no
    /// lazy-open needed.
    @discardableResult
    func recordPromotion(
        from: String,
        to: String,
        fpRateMax: Double?,
        minLabeledSample: Int?,
        observedRate: Double?,
        observedSample: Int,
        promotedBy: String,
        at: Date = Date()
    ) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }

            let (anchorId, useV25Shape) = resolveWriteAnchorLocked(db: db, ensureV25: true)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            // Encode the from→to plus configured thresholds into the
            // existing `reason` + `score` + `correlation_count` columns
            // so the canonical hash captures them under both legacy
            // and v25 shapes:
            //   reason = "from_<from>_to_<to>"
            //   score = (fp_rate_max * 1_000_000) as Int, or 0 if nil
            //   correlation_count = min_labeled_sample, or 0 if nil
            // Under v25 shape, observed_rate + observed_sample ALSO
            // hash. Under legacy shape, they're persisted as opaque
            // data (the pre-v28 behavior preserved for legacy rows).
            let reasonStr = "from_\(from)_to_\(to)"
            let scoreInt = Int64((fpRateMax ?? 0.0) * 1_000_000)
            let sampleInt = Int64(minLabeledSample ?? 0)

            let columns = Self.canonicalColumns(
                kind: "promotion",
                createdAt: at,
                sessionId: nil,
                paneId: nil,
                toolName: nil,
                reason: reasonStr,
                score: scoreInt,
                correlationCount: sampleInt,
                flagId: nil,
                label: nil,
                labeledBy: promotedBy,
                observedRate: observedRate,
                observedSample: Int64(observedSample),
                callId: nil,
                useV25Shape: useV25Shape
            )
            let entryHash = ChainHasher.entryHash(
                table: "trust_audits", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO trust_audits
                    (kind, created_at, session_id, pane_id, tool_name,
                     reason, score, correlation_count,
                     flag_id, label, labeled_by,
                     prev_hash, entry_hash, chain_anchor_id,
                     observed_rate, observed_sample)
                VALUES (?, ?, NULL, NULL, NULL, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ("promotion" as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, at.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (reasonStr as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 4, scoreInt)
            sqlite3_bind_int64(stmt, 5, sampleInt)
            sqlite3_bind_text(stmt, 6, (promotedBy as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 7, prevHash)
            sqlite3_bind_text(stmt, 8, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 9, anchorId)
            if let rate = observedRate {
                sqlite3_bind_double(stmt, 10, rate)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_int64(stmt, 11, Int64(observedSample))

            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Insert one `override` row re-allowing a denied call. `callId`
    /// identifies the HookRouter tool-call event the override
    /// addresses. `flagId` points at the `trust_audits` flag row that
    /// triggered the denial (may be nil for pre-emptive overrides
    /// that don't have a flag row yet). `justification` is operator-
    /// supplied free-text, optional.
    @discardableResult
    func recordOverride(
        callId: String,
        flagId: Int64?,
        operator opAlias: String,
        justification: String?,
        at: Date = Date()
    ) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }

            let (anchorId, useV25Shape) = resolveWriteAnchorLocked(db: db, ensureV25: true)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            // Encode justification into the `reason` column so it
            // participates in the canonical hash under both shapes.
            // Under v25 shape, callId ALSO hashes (so a SQL UPDATE on
            // the stored call_id is detected by ChainVerifier). Under
            // legacy shape, callId stays opaque per pre-v28 behavior.
            let reasonStr = justification ?? "no-justification"

            let columns = Self.canonicalColumns(
                kind: "override",
                createdAt: at,
                sessionId: nil,
                paneId: nil,
                toolName: nil,
                reason: reasonStr,
                score: nil,
                correlationCount: nil,
                flagId: flagId,
                label: nil,
                labeledBy: opAlias,
                observedRate: nil,
                observedSample: nil,
                callId: callId,
                useV25Shape: useV25Shape
            )
            let entryHash = ChainHasher.entryHash(
                table: "trust_audits", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO trust_audits
                    (kind, created_at, session_id, pane_id, tool_name,
                     reason, score, correlation_count,
                     flag_id, label, labeled_by,
                     prev_hash, entry_hash, chain_anchor_id,
                     call_id)
                VALUES (?, ?, NULL, NULL, NULL, ?, NULL, NULL, ?, NULL, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ("override" as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, at.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (reasonStr as NSString).utf8String, -1, nil)
            if let fid = flagId {
                sqlite3_bind_int64(stmt, 4, fid)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (opAlias as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 6, prevHash)
            sqlite3_bind_text(stmt, 7, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 8, anchorId)
            sqlite3_bind_text(stmt, 9, (callId as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// U.4b-1 — does an override row exist for the given callId? Used
    /// by the HookRouter denial path to check the per-call allowlist
    /// before refusing. Cheap indexed lookup.
    func overrideExists(callId: String) -> Bool {
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = "SELECT 1 FROM trust_audits WHERE kind = 'override' AND call_id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (callId as NSString).utf8String, -1, nil)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: - Reads

    /// Recent flag rows, newest first. UI list source.
    func recentFlags(limit: Int = 100, since: Date? = nil) -> [TrustFlagRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let hasSince = since != nil
            let sql = """
                SELECT id, created_at, session_id, pane_id, tool_name,
                       reason, score, correlation_count
                FROM trust_audits
                WHERE kind = 'flag'\(hasSince ? " AND created_at >= ?" : "")
                ORDER BY created_at DESC, id DESC
                LIMIT \(hasSince ? "?" : "?");
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since {
                sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 2, Int64(max(0, limit)))
            } else {
                sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))
            }

            var out: [TrustFlagRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let reasonRaw = String(cString: sqlite3_column_text(stmt, 5))
                guard let reason = FragmentationDetector.Reason(rawValue: reasonRaw) else { continue }
                let paneId: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(stmt, 3))
                out.append(TrustFlagRow(
                    id: sqlite3_column_int64(stmt, 0),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    sessionId: String(cString: sqlite3_column_text(stmt, 2)),
                    paneId: paneId,
                    toolName: String(cString: sqlite3_column_text(stmt, 4)),
                    reason: reason,
                    score: Int(sqlite3_column_int64(stmt, 6)),
                    correlationCount: Int(sqlite3_column_int64(stmt, 7))
                ))
            }
            return out
        }
    }

    /// All labels for a given flag id, newest first. UI shows the
    /// latest label inline; the full list is available for re-label
    /// audits.
    func labelsForFlag(_ flagId: Int64) -> [TrustLabelRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, created_at, flag_id, label, labeled_by
                FROM trust_audits
                WHERE kind = 'label' AND flag_id = ?
                ORDER BY created_at DESC, id DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, flagId)

            var out: [TrustLabelRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let labelRaw = String(cString: sqlite3_column_text(stmt, 3))
                guard let label = TrustLabel(rawValue: labelRaw) else { continue }
                out.append(TrustLabelRow(
                    id: sqlite3_column_int64(stmt, 0),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    flagId: sqlite3_column_int64(stmt, 2),
                    label: label,
                    labeledBy: String(cString: sqlite3_column_text(stmt, 4))
                ))
            }
            return out
        }
    }

    /// Aggregate FP/TP/total counts since a given date. `senkani
    /// doctor` reads the 30-day window. `confirmedFP` and
    /// `confirmedTP` count *latest* labels only — re-labelling a flag
    /// from FP→TP correctly moves the count from one bucket to the
    /// other.
    func stats(since: Date) -> TrustFlagStats {
        return parent.queue.sync {
            guard let db = parent.db else { return TrustFlagStats(softFlags: 0, confirmedFP: 0, confirmedTP: 0) }
            let cutoff = since.timeIntervalSince1970

            // Total soft flags in window.
            var totalStmt: OpaquePointer?
            let totalSQL = "SELECT COUNT(*) FROM trust_audits WHERE kind = 'flag' AND created_at >= ?;"
            var total = 0
            if sqlite3_prepare_v2(db, totalSQL, -1, &totalStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(totalStmt, 1, cutoff)
                if sqlite3_step(totalStmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int64(totalStmt, 0))
                }
            }
            sqlite3_finalize(totalStmt)

            // Latest label per flag, only flags inside the window.
            // Subquery picks each flag's max(id) label row.
            let labelSQL = """
                SELECT latest.label, COUNT(*)
                FROM trust_audits AS f
                LEFT JOIN (
                    SELECT l.flag_id, l.label
                    FROM trust_audits AS l
                    WHERE l.kind = 'label' AND l.id IN (
                        SELECT MAX(id) FROM trust_audits
                        WHERE kind = 'label' GROUP BY flag_id
                    )
                ) AS latest ON latest.flag_id = f.id
                WHERE f.kind = 'flag' AND f.created_at >= ?
                  AND latest.label IS NOT NULL
                GROUP BY latest.label;
            """
            var labelStmt: OpaquePointer?
            var fp = 0, tp = 0
            if sqlite3_prepare_v2(db, labelSQL, -1, &labelStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(labelStmt, 1, cutoff)
                while sqlite3_step(labelStmt) == SQLITE_ROW {
                    let lbl = String(cString: sqlite3_column_text(labelStmt, 0))
                    let count = Int(sqlite3_column_int64(labelStmt, 1))
                    if lbl == TrustLabel.fp.rawValue { fp = count }
                    if lbl == TrustLabel.tp.rawValue { tp = count }
                }
            }
            sqlite3_finalize(labelStmt)

            return TrustFlagStats(softFlags: total, confirmedFP: fp, confirmedTP: tp)
        }
    }

    // MARK: - Helpers

    /// Anchor name the v28 migration uses to mark legacy chain rows.
    /// Rows under this anchor were hashed under the 11-column shape
    /// (pre-v25). Rows under any other anchor reason for `trust_audits`
    /// use the 14-column v25 shape that includes `observed_rate`,
    /// `observed_sample`, `call_id`. See `Migrations.swift` v28 +
    /// `ChainVerifier.verifyAnchorTrustAudits`.
    static let legacyV25AnchorReason = "fresh-install-pre-v25"

    /// Anchor reason for the lazy-opened v25 anchor. Public so the
    /// verifier + tests reference the same literal.
    static let migrationV25AnchorReason = "migration-v25"

    /// Resolve the anchor a write should chain under, plus whether the
    /// writer should emit the v25 (14-column) canonical shape.
    ///
    /// - When `ensureV25 == true` (promotion + override writers) and
    ///   the current anchor is `fresh-install-pre-v25`, lazy-open a
    ///   `migration-v25` anchor at `MAX(id)` and return its id with
    ///   `useV25Shape = true`. Idempotent — second call returns the
    ///   existing migration-v25 anchor without inserting a duplicate.
    /// - When `ensureV25 == false` (flag + label writers), stay on
    ///   whatever anchor is current; only the canonical shape varies.
    ///
    /// Caller MUST be on `parent.queue`.
    private func resolveWriteAnchorLocked(db: OpaquePointer, ensureV25: Bool) -> (anchorId: Int64, useV25Shape: Bool) {
        let current = chain.resolveAnchorId(db: db)
        let reason = chain.anchorReason(db: db, anchorId: current) ?? ""
        if reason == Self.legacyV25AnchorReason {
            if ensureV25 {
                let newAnchorId = Self.openMigrationV25AnchorLocked(db: db)
                if newAnchorId > 0 {
                    chain.invalidate()
                    _ = chain.resolveAnchorId(db: db)  // repopulate cache with new MAX(id)
                    return (newAnchorId, true)
                }
                // Lazy-open failed — fall back to legacy anchor so the
                // write still succeeds. Loud failure here would block
                // every promotion/override write on an SQL-level error
                // the operator can't recover from inline.
                return (current, false)
            }
            return (current, false)
        }
        // fresh-install (post-v28), migration-v25, any future repair-*
        // anchor name → v25 canonical shape.
        return (current, true)
    }

    /// Lazy-opens the `migration-v25` anchor at `MAX(id)` for
    /// `trust_audits`. Idempotent — if a `migration-v25` anchor already
    /// exists for this table, returns its id without inserting a new
    /// one. Returns -1 on SQL error.
    private static func openMigrationV25AnchorLocked(db: OpaquePointer) -> Int64 {
        // Idempotency lookup first — operator may invoke
        // promotion/override repeatedly across process restarts.
        var lookupStmt: OpaquePointer?
        let lookupSQL = "SELECT id FROM chain_anchors WHERE table_name = 'trust_audits' AND reason = 'migration-v25' ORDER BY id ASC LIMIT 1;"
        if sqlite3_prepare_v2(db, lookupSQL, -1, &lookupStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(lookupStmt) }
            if sqlite3_step(lookupStmt) == SQLITE_ROW,
               sqlite3_column_type(lookupStmt, 0) != SQLITE_NULL {
                return sqlite3_column_int64(lookupStmt, 0)
            }
        }
        // MAX(id) of trust_audits — every row at this point or earlier
        // belongs to the legacy `fresh-install-pre-v25` segment.
        var maxStmt: OpaquePointer?
        var maxRowid: Int64 = 0
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM trust_audits;"
        if sqlite3_prepare_v2(db, maxSQL, -1, &maxStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(maxStmt) }
            if sqlite3_step(maxStmt) == SQLITE_ROW {
                maxRowid = sqlite3_column_int64(maxStmt, 0)
            }
        }
        var insertStmt: OpaquePointer?
        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('trust_audits', ?, ?, 'migration-v25', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(insertStmt) }
        sqlite3_bind_double(insertStmt, 1, now)
        sqlite3_bind_int64(insertStmt, 2, maxRowid)
        guard sqlite3_step(insertStmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Build the canonical column map for one trust_audits row.
    /// `useV25Shape` controls inclusion of the v25 columns
    /// (`observed_rate`, `observed_sample`, `call_id`). The same
    /// helper is called by every kind of writer so the column set is
    /// consistent for a given shape — if a writer were to drift the
    /// shape (e.g. forget a NULL slot), the verifier would surface a
    /// hash mismatch on the next chain walk.
    static func canonicalColumns(
        kind: String,
        createdAt: Date,
        sessionId: String?,
        paneId: String?,
        toolName: String?,
        reason: String?,
        score: Int64?,
        correlationCount: Int64?,
        flagId: Int64?,
        label: String?,
        labeledBy: String?,
        observedRate: Double?,
        observedSample: Int64?,
        callId: String?,
        useV25Shape: Bool
    ) -> [String: ChainHasher.CanonicalValue] {
        var cols: [String: ChainHasher.CanonicalValue] = [
            "kind":              .text(kind),
            "created_at":        .real(createdAt.timeIntervalSince1970),
            "session_id":        sessionId.map { .text($0) } ?? .null,
            "pane_id":           paneId.map { .text($0) } ?? .null,
            "tool_name":         toolName.map { .text($0) } ?? .null,
            "reason":            reason.map { .text($0) } ?? .null,
            "score":             score.map { .integer($0) } ?? .null,
            "correlation_count": correlationCount.map { .integer($0) } ?? .null,
            "flag_id":           flagId.map { .integer($0) } ?? .null,
            "label":             label.map { .text($0) } ?? .null,
            "labeled_by":        labeledBy.map { .text($0) } ?? .null,
        ]
        if useV25Shape {
            cols["observed_rate"]   = observedRate.map { .real($0) } ?? .null
            cols["observed_sample"] = observedSample.map { .integer($0) } ?? .null
            cols["call_id"]         = callId.map { .text($0) } ?? .null
        }
        return cols
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func execSilent(_ sql: String) {
        dispatchPrecondition(condition: .onQueue(parent.queue))
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}

// MARK: - Public model

/// FP = the operator confirmed the soft flag was wrong (false positive).
/// TP = the operator confirmed the soft flag was right (true positive).
public enum TrustLabel: String, Sendable, Codable, Equatable, CaseIterable {
    case fp
    case tp
}

public struct TrustFlagRow: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let createdAt: Date
    public let sessionId: String
    public let paneId: String?
    public let toolName: String
    public let reason: FragmentationDetector.Reason
    public let score: Int
    public let correlationCount: Int

    public init(
        id: Int64,
        createdAt: Date,
        sessionId: String,
        paneId: String?,
        toolName: String,
        reason: FragmentationDetector.Reason,
        score: Int,
        correlationCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.paneId = paneId
        self.toolName = toolName
        self.reason = reason
        self.score = score
        self.correlationCount = correlationCount
    }
}

public struct TrustLabelRow: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let createdAt: Date
    public let flagId: Int64
    public let label: TrustLabel
    public let labeledBy: String

    public init(
        id: Int64,
        createdAt: Date,
        flagId: Int64,
        label: TrustLabel,
        labeledBy: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.flagId = flagId
        self.label = label
        self.labeledBy = labeledBy
    }
}

/// FP-rate readout consumed by `senkani doctor`.
public struct TrustFlagStats: Sendable, Equatable {
    public let softFlags: Int
    public let confirmedFP: Int
    public let confirmedTP: Int

    public init(softFlags: Int, confirmedFP: Int, confirmedTP: Int) {
        self.softFlags = softFlags
        self.confirmedFP = confirmedFP
        self.confirmedTP = confirmedTP
    }

    /// Doctor-line format: `soft flags last 30d: N | confirmed FP: M | confirmed TP: K`.
    public var doctorLine: String {
        return "soft flags last 30d: \(softFlags) | confirmed FP: \(confirmedFP) | confirmed TP: \(confirmedTP)"
    }
}
