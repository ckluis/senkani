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

    /// Drop the chain cache after a `--repair-chain` motion.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Schema

    /// Residual DDL that has not yet been folded into a numbered migration.
    /// MigrationRegistry.all v3/v5 own `validation_results` and its
    /// outcome/anchor indexes; this method covers the two store-private
    /// query indexes (`idx_validation_session_delivered`,
    /// `idx_validation_file`). Called AFTER `runMigrations` so the
    /// underlying table already exists.
    func setupSchema() {
        parent.queue.sync {
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_validation_session_delivered ON validation_results(session_id, delivered);")
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_validation_file ON validation_results(file_path);")
        }
    }

    // MARK: - Public API (delegated from SessionDatabase)

    private let chain = ChainState(table: "validation_results")

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
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            // T.5 round 3: chain-aware insert.
            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":     .text(sessionId),
                "file_path":      .text(filePath),
                "validator_name": .text(validatorName),
                "category":       .text(category),
                "exit_code":      .integer(Int64(exitCode)),
                "raw_output":     rawOutput.map { .text($0) } ?? .null,
                "advisory":       .text(advisory),
                "duration_ms":    .integer(Int64(durationMs)),
                "created_at":     .real(now),
                // `delivered`, `outcome`, `reason`, `surfaced_at` are part of
                // the table's data shape after migrations 3+. They're hashed.
                "delivered":      .integer(0),
                "outcome":        .text(resolvedOutcome),
                "reason":         reason.map { .text($0) } ?? .null,
                "surfaced_at":    .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: "validation_results", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO validation_results
                (session_id, file_path, validator_name, category, exit_code, raw_output, advisory, duration_ms, created_at, outcome, reason,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            Self.bindOptionalText(stmt, 12, prevHash)
            sqlite3_bind_text(stmt, 13, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 14, anchorId)
            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            } else {
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

    /// U.2a-2b — insert a structured browser-validation row. Populates the
    /// v22 columns (`axes`, `target_url`, `plan_steps`, `result_status`,
    /// `screenshot_path`) so HookRouter's PreToolUse gate can read
    /// `result_status = 'fail'` for the session.
    ///
    /// Chain note: this writer hashes under the existing `fresh-install`
    /// anchor's canonical column shape (same set as
    /// `insertValidationResult`). The v22 columns are stored as opaque
    /// data and not yet part of the entry hash — opening a
    /// `migration-v22` anchor that includes them is deferred to a
    /// follow-up round so this round's scope stays bounded. Existing
    /// rows verify unchanged; new browser rows verify under the same
    /// shape as legacy auto-validate rows.
    func insertBrowserValidationResult(
        sessionId: String,
        targetURL: String,
        axes: [String],
        planStepsJSON: String,
        resultStatus: String,
        assertionsPassed: Int,
        assertionsFailed: Int,
        advisory: String,
        screenshotPath: String?
    ) {
        let now = Date().timeIntervalSince1970
        // Encode `axes` as a JSON array string — column shape from v22.
        let axesJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: axes, options: [.sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else { return "[]" }
            return str
        }()
        // Map result_status to outcome for legacy queries.
        let legacyOutcome = resultStatus == "fail" ? "blocking" : "advisory"
        let exitCode: Int32 = resultStatus == "pass" ? 0 : 1
        let durationMs = 0

        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            // Hash only the legacy column set so the chain stays intact
            // with pre-v22 fresh-install anchor rows.
            let columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":     .text(sessionId),
                "file_path":      .text(targetURL),
                "validator_name": .text("validate_browser"),
                "category":       .text("browser"),
                "exit_code":      .integer(Int64(exitCode)),
                "raw_output":     .null,
                "advisory":       .text(advisory),
                "duration_ms":    .integer(Int64(durationMs)),
                "created_at":     .real(now),
                "delivered":      .integer(0),
                "outcome":        .text(legacyOutcome),
                "reason":         .null,
                "surfaced_at":    .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: "validation_results", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO validation_results
                (session_id, file_path, validator_name, category, exit_code, raw_output, advisory, duration_ms, created_at, outcome, reason,
                 prev_hash, entry_hash, chain_anchor_id,
                 axes, target_url, plan_steps, result_status, screenshot_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (targetURL as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, "validate_browser", -1, nil)
            sqlite3_bind_text(stmt, 4, "browser", -1, nil)
            sqlite3_bind_int(stmt, 5, exitCode)
            sqlite3_bind_null(stmt, 6)
            sqlite3_bind_text(stmt, 7, (advisory as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 8, Int32(durationMs))
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_bind_text(stmt, 10, (legacyOutcome as NSString).utf8String, -1, nil)
            sqlite3_bind_null(stmt, 11)
            Self.bindOptionalText(stmt, 12, prevHash)
            sqlite3_bind_text(stmt, 13, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 14, anchorId)
            sqlite3_bind_text(stmt, 15, (axesJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 16, (targetURL as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 17, (planStepsJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 18, (resultStatus as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 19, screenshotPath)
            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.2a-2b — read the first failing browser-validation row for a
    /// session (used by HookRouter's PreToolUse hard-block gate). Returns
    /// the row's `target_url`, `axes`, and `advisory` so the refusal
    /// contract can populate `failing_axis` and `fixture_id` without
    /// leaking the assertion payload (Schneier side-channel guard).
    func firstFailingBrowserValidation(sessionId: String) -> SessionDatabase.BrowserValidationFailRow? {
        return parent.queue.sync { () -> SessionDatabase.BrowserValidationFailRow? in
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT id, target_url, axes, advisory, created_at
                FROM validation_results
                WHERE session_id = ?
                  AND result_status = 'fail'
                  AND delivered = 0
                ORDER BY created_at DESC
                LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let id = sqlite3_column_int64(stmt, 0)
            let url: String? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 1))
            let axes: String = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? "[]" : String(cString: sqlite3_column_text(stmt, 2))
            let advisory: String = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? "" : String(cString: sqlite3_column_text(stmt, 3))
            let created = sqlite3_column_double(stmt, 4)
            return SessionDatabase.BrowserValidationFailRow(
                id: id,
                targetURL: url,
                axesJSON: axes,
                advisory: advisory,
                createdAt: Date(timeIntervalSince1970: created)
            )
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
        dispatchPrecondition(condition: .onQueue(parent.queue))
        StoreExec.run(db: parent.db, sql: sql, scope: "validation")
    }

    private func execSilent(_ sql: String) {
        dispatchPrecondition(condition: .onQueue(parent.queue))
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}
