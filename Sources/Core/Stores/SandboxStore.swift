import Foundation
import SQLite3

/// Owns the `sandboxed_results` table end-to-end — schema + indexes +
/// store/retrieve/prune API. Extracted from `SessionDatabase` under
/// `sessiondb-split-4-sandboxstore` (Luminary P2-11, round 3 of 5).
/// Shares the parent's connection + dispatch queue; never opens a new
/// SQLite handle.
///
/// The table stages large command outputs (stdout/stderr over the
/// auto-sandbox line threshold) under a short `r_<12-char-uuid>` ID so
/// the MCP tool stream can return a terse summary + retrieval pointer
/// instead of megabytes of text. Retention is a 24-h prune driven by
/// `RetentionScheduler` (hourly tick, configurable via
/// `~/.senkani/config.json → retention.sandbox_results_hours`).
///
/// Public API is forwarded from `SessionDatabase` — callers keep using
/// `SessionDatabase.shared.storeSandboxedResult(…)` etc. and the façade
/// delegates here. No callsite outside this file and `SessionDatabase.swift`
/// should reference `SandboxStore` directly.
final class SandboxStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Create the `sandboxed_results` table + its two indexes. Idempotent —
    /// safe to call on every open.
    func setupSchema() {
        parent.queue.sync {
            self.exec("""
                CREATE TABLE IF NOT EXISTS sandboxed_results (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    command TEXT NOT NULL,
                    full_output TEXT NOT NULL,
                    line_count INTEGER NOT NULL,
                    byte_count INTEGER NOT NULL
                );
            """)
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_sandboxed_results_session ON sandboxed_results(session_id);")
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_sandboxed_results_time ON sandboxed_results(created_at);")
        }
    }

    // MARK: - Public API (delegated from SessionDatabase)

    /// Store a large command output and return a retrieve ID.
    /// The ID uses a `r_` prefix + 12-char UUID segment for compactness.
    func storeSandboxedResult(sessionId: String, command: String, output: String) -> String {
        let resultId = "r_" + UUID().uuidString.prefix(12).lowercased()
        let now = Date().timeIntervalSince1970
        let lineCount = output.components(separatedBy: "\n").count
        let byteCount = output.utf8.count

        parent.queue.sync {
            guard let db = parent.db else { return }
            let sql = """
                INSERT INTO sandboxed_results (id, session_id, created_at, command, full_output, line_count, byte_count)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (resultId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, now)
            sqlite3_bind_text(stmt, 4, (command as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (output as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, Int64(lineCount))
            sqlite3_bind_int64(stmt, 7, Int64(byteCount))
            sqlite3_step(stmt)
        }

        return resultId
    }

    /// Retrieve a sandboxed result by its ID.
    /// Returns nil if not found (expired or invalid ID).
    func retrieveSandboxedResult(resultId: String) -> (command: String, output: String, lineCount: Int, byteCount: Int)? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = "SELECT command, full_output, line_count, byte_count FROM sandboxed_results WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (resultId as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let command = String(cString: sqlite3_column_text(stmt, 0))
            let output = String(cString: sqlite3_column_text(stmt, 1))
            let lineCount = Int(sqlite3_column_int64(stmt, 2))
            let byteCount = Int(sqlite3_column_int64(stmt, 3))
            return (command, output, lineCount, byteCount)
        }
    }

    /// Delete sandboxed results older than a given interval (default: 24 hours).
    /// Invoked by `RetentionScheduler` on an hourly tick and by
    /// `MCPSession` on session startup for a best-effort catch-up prune.
    @discardableResult
    func pruneSandboxedResults(olderThan interval: TimeInterval = 86400) -> Int {
        let cutoff = Date().timeIntervalSince1970 - interval
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = "DELETE FROM sandboxed_results WHERE created_at < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            print("[SandboxStore] SQL error: \(msg)")
            sqlite3_free(err)
        }
    }

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}
