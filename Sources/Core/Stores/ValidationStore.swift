import Foundation
import SQLite3

/// Owns the `validation_results` table end-to-end: schema, indexes, writes,
/// advisory delivery reads, surfaced marking, and prune cadence.
/// Extracted from `SessionDatabase` under `sessiondb-split-5-validationstore`
/// (Luminary P2-11, round 4 of 5). Shares the parent's connection + queue;
/// never opens a new SQLite handle.
///
/// Public API is forwarded from `SessionDatabase` so AutoValidate, HookRouter,
/// and tests keep using `SessionDatabase.shared.insertValidationResult(...)`,
/// `pendingValidationAdvisories(...)`, etc. No callsite outside this file and
/// `SessionDatabase.swift` should reference `ValidationStore` directly.
final class ValidationStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Create the historical baseline table + indexes. Delivery metadata
    /// (`outcome`, `reason`, `surfaced_at`) is added by migration v3, so this
    /// remains compatible with both fresh DB bootstrap and historical DBs.
    func setupSchema() {
        parent.queue.sync {
            self.exec("""
                CREATE TABLE IF NOT EXISTS validation_results (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    validator_name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    exit_code INTEGER NOT NULL,
                    raw_output TEXT,
                    advisory TEXT NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    delivered INTEGER DEFAULT 0
                );
            """)
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_validation_session_delivered ON validation_results(session_id, delivered);")
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_validation_file ON validation_results(file_path);")
        }
    }

    // MARK: - Public API (delegated from SessionDatabase)

    /// Store a validation attempt from auto-validate.
    func insertValidationResult(
        sessionId: String,
        filePath: String,
        validatorName: String,
        category: String,
        exitCode: Int32,
        rawOutput: String?,
        advisory: String,
        durationMs: Int,
        outcome: String? = nil,
        reason: String? = nil
    ) {
        let now = Date().timeIntervalSince1970
        let resolvedOutcome = outcome ?? (exitCode == 0 ? "clean" : "advisory")
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            let sql = """
                INSERT INTO validation_results
                (session_id, file_path, validator_name, category, exit_code, raw_output, advisory, duration_ms, created_at, outcome, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Logger.log("auto_validate.db_write.prepare_failed", fields: [
                    "table": .string("validation_results"),
                    "operation": .string("insert"),
                ])
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (filePath as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (validatorName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (category as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 5, exitCode)
            Self.bindOptionalText(stmt, 6, rawOutput)
            sqlite3_bind_text(stmt, 7, (advisory as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 8, Int32(durationMs))
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_bind_text(stmt, 10, (resolvedOutcome as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 11, reason)
            if sqlite3_step(stmt) != SQLITE_DONE {
                Logger.log("auto_validate.db_write.step_failed", fields: [
                    "table": .string("validation_results"),
                    "operation": .string("insert"),
                ])
            }
        }
    }

    /// Fetch pending advisory rows for a session without mutating delivery
    /// state. HookRouter marks rows surfaced only after appending them to a
    /// response the agent can see.
    func pendingValidationAdvisories(sessionId: String) -> [SessionDatabase.ValidationResultRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }

            let selectSql = """
                SELECT id, file_path, validator_name, category, exit_code, advisory, duration_ms, created_at, outcome, reason, surfaced_at
                FROM validation_results
                WHERE session_id = ?
                  AND outcome = 'advisory'
                  AND surfaced_at IS NULL
                  AND delivered = 0
                  AND exit_code != 0
                ORDER BY created_at DESC
                LIMIT 10;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

            var results: [SessionDatabase.ValidationResultRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readValidationResultRow(stmt))
            }
            return results
        }
    }

    /// Fetch validation rows for inspection/diagnostics. Unlike
    /// pendingValidationAdvisories this includes clean/dropped outcomes and
    /// already-surfaced rows.
    func validationResults(sessionId: String, outcome: String? = nil) -> [SessionDatabase.ValidationResultRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT id, file_path, validator_name, category, exit_code, advisory, duration_ms, created_at, outcome, reason, surfaced_at
                FROM validation_results
                WHERE session_id = ?
                """
            if outcome != nil {
                sql += " AND outcome = ?"
            }
            sql += " ORDER BY created_at DESC;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if let outcome {
                sqlite3_bind_text(stmt, 2, (outcome as NSString).utf8String, -1, nil)
            }

            var results: [SessionDatabase.ValidationResultRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readValidationResultRow(stmt))
            }
            return results
        }
    }

    /// Mark advisory rows as surfaced after their text was placed into a hook
    /// response. `delivered` remains updated for compatibility with older UI
    /// queries, but `surfaced_at` is the source of truth.
    func markValidationAdvisoriesSurfaced(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let ts = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            let idList = ids.map(String.init).joined(separator: ",")
            let sql = "UPDATE validation_results SET delivered = 1, surfaced_at = ? WHERE id IN (\(idList));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Logger.log("auto_validate.db_write.prepare_failed", fields: [
                    "table": .string("validation_results"),
                    "operation": .string("mark_surfaced"),
                ])
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            if sqlite3_step(stmt) != SQLITE_DONE {
                Logger.log("auto_validate.db_write.step_failed", fields: [
                    "table": .string("validation_results"),
                    "operation": .string("mark_surfaced"),
                ])
            }
        }
    }

    /// Legacy compatibility helper for callers/tests that explicitly want the
    /// old destructive read.
    func fetchAndMarkDelivered(sessionId: String) -> [SessionDatabase.ValidationResultRow] {
        let rows = pendingValidationAdvisories(sessionId: sessionId)
        markValidationAdvisoriesSurfaced(ids: rows.map(\.id))
        parent.flushWrites()
        return rows
    }

    /// Prune validation results older than a given interval.
    @discardableResult
    func pruneValidationResults(olderThanHours: Int = 24) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(olderThanHours) * 3600).timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = "DELETE FROM validation_results WHERE created_at < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Helpers

    private func readValidationResultRow(_ stmt: OpaquePointer?) -> SessionDatabase.ValidationResultRow {
        let surfacedAt: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let reason: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(stmt, 9))
        return SessionDatabase.ValidationResultRow(
            id: sqlite3_column_int64(stmt, 0),
            filePath: String(cString: sqlite3_column_text(stmt, 1)),
            validatorName: String(cString: sqlite3_column_text(stmt, 2)),
            category: String(cString: sqlite3_column_text(stmt, 3)),
            exitCode: sqlite3_column_int(stmt, 4),
            advisory: String(cString: sqlite3_column_text(stmt, 5)),
            durationMs: Int(sqlite3_column_int(stmt, 6)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            outcome: String(cString: sqlite3_column_text(stmt, 8)),
            reason: reason,
            surfacedAt: surfacedAt
        )
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            print("[ValidationStore] SQL error: \(msg)")
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
