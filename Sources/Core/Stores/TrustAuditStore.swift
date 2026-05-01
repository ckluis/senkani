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

    // MARK: - Schema

    /// Idempotent — Migration v12 is canonical.
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS trust_audits (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind              TEXT NOT NULL,
                    created_at        REAL NOT NULL,
                    session_id        TEXT,
                    pane_id           TEXT,
                    tool_name         TEXT,
                    reason            TEXT,
                    score             INTEGER,
                    correlation_count INTEGER,
                    flag_id           INTEGER,
                    label             TEXT,
                    labeled_by        TEXT,
                    prev_hash         TEXT,
                    entry_hash        TEXT,
                    chain_anchor_id   INTEGER
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_trust_audits_kind_time ON trust_audits(kind, created_at DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_trust_audits_flag ON trust_audits(flag_id);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_trust_audits_session ON trust_audits(session_id, created_at DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_trust_audits_anchor ON trust_audits(chain_anchor_id, id);")
        }
    }

    // MARK: - Writes

    /// Insert one flag row for a `FragmentationDetector.Flag`. Returns
    /// the new rowid (the operator references this id when labelling
    /// FP/TP), or -1 on failure.
    @discardableResult
    func recordFlag(_ flag: FragmentationDetector.Flag, score: Int) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }

            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "kind":              .text("flag"),
                "created_at":        .real(flag.createdAt.timeIntervalSince1970),
                "session_id":        .text(flag.sessionId),
                "pane_id":           Self.canonical(flag.paneId),
                "tool_name":         .text(flag.toolName),
                "reason":            .text(flag.reason.rawValue),
                "score":             .integer(Int64(score)),
                "correlation_count": .integer(Int64(flag.correlationCount)),
                "flag_id":           .null,
                "label":             .null,
                "labeled_by":        .null,
            ]
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

            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "kind":              .text("label"),
                "created_at":        .real(at.timeIntervalSince1970),
                "session_id":        .null,
                "pane_id":           .null,
                "tool_name":         .null,
                "reason":            .null,
                "score":             .null,
                "correlation_count": .null,
                "flag_id":           .integer(flagId),
                "label":             .text(label.rawValue),
                "labeled_by":        .text(labeledBy),
            ]
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

    private static func canonical(_ value: String?) -> ChainHasher.CanonicalValue {
        guard let value else { return .null }
        return .text(value)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func execSilent(_ sql: String) {
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
