import Foundation
import SQLite3

/// Owns the `annotation_rate_cap_log` table — V.12b round 1.
///
/// One row per closed window in which the must-fix annotation
/// threshold fired. Not chain-hashed: the row is a derived flood
/// marker. The source denials are already recorded via
/// `hook_events`, `token_events`, and `commands`; tampering with
/// the rate-cap log is detectable by re-deriving from those.
final class AnnotationRateCapStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Idempotent — Migration v13 owns the canonical schema.
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS annotation_rate_cap_log (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    window_start     REAL NOT NULL,
                    window_end       REAL NOT NULL,
                    severity         TEXT NOT NULL,
                    suppressed_count INTEGER NOT NULL,
                    threshold        INTEGER NOT NULL,
                    created_at       REAL NOT NULL
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_annotation_rate_cap_window ON annotation_rate_cap_log(window_start DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_annotation_rate_cap_severity ON annotation_rate_cap_log(severity, created_at DESC);")
        }
    }

    /// Insert one rate-cap log row. Returns the rowid or -1 on failure.
    @discardableResult
    func record(_ row: AnnotationRateCapLogRow, now: Date = Date()) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }
            let sql = """
                INSERT INTO annotation_rate_cap_log
                    (window_start, window_end, severity,
                     suppressed_count, threshold, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, row.windowStart.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, row.windowEnd.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (row.severity as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 4, Int64(row.suppressedCount))
            sqlite3_bind_int64(stmt, 5, Int64(row.threshold))
            sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Recent rows, newest first. Used by tests + the dashboard.
    func recent(limit: Int = 100) -> [AnnotationRateCapLogRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT window_start, window_end, severity,
                       suppressed_count, threshold
                FROM annotation_rate_cap_log
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))

            var out: [AnnotationRateCapLogRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AnnotationRateCapLogRow(
                    windowStart: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    windowEnd: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    severity: String(cString: sqlite3_column_text(stmt, 2)),
                    suppressedCount: Int(sqlite3_column_int64(stmt, 3)),
                    threshold: Int(sqlite3_column_int64(stmt, 4))
                ))
            }
            return out
        }
    }

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}
