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
    ///
    /// V.18a-5 — `validationRunId` is recorded as a non-canonical TEXT
    /// column on the row. Deliberately excluded from `canonicalColumns`
    /// so the v22 chain shape verifier walk continues to match. The
    /// column powers the JOIN against `runtime_telemetry_span` for the
    /// trace-summary query.
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
        reason: String? = nil,
        validationRunId: String? = nil
    ) {
        let now = Date().timeIntervalSince1970
        let resolvedOutcome = outcome ?? (exitCode == 0 ? "clean" : "advisory")
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            // T.5 round 3: chain-aware insert.
            // v29 round (2026-05-21): auto-validate does NOT lazy-open
            // migration-v22 — it does not populate the v22 columns and
            // legacy auto-validate rows continue to chain under whatever
            // anchor is current. On `fresh-install-pre-v22` the canonical
            // shape stays pre-v22; on `migration-v22` / post-v29
            // `fresh-install` the canonical map includes the v22 columns
            // at their DDL defaults ('[]' / NULL / '[]' / NULL / NULL),
            // matching the row SQLite actually persists.
            let (anchorId, useV22Shape) = self.resolveWriteAnchorLocked(db: db, ensureV22: false)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            let columns = Self.canonicalColumns(
                sessionId: sessionId,
                filePath: filePath,
                validatorName: validatorName,
                category: category,
                exitCode: exitCode,
                rawOutput: rawOutput,
                advisory: advisory,
                durationMs: durationMs,
                createdAt: now,
                delivered: 0,
                outcome: resolvedOutcome,
                reason: reason,
                surfacedAt: nil,
                axesJSON: "[]",
                targetURL: nil,
                planStepsJSON: "[]",
                resultStatus: nil,
                screenshotPath: nil,
                useV22Shape: useV22Shape
            )
            let entryHash = ChainHasher.entryHash(
                table: "validation_results", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO validation_results
                (session_id, file_path, validator_name, category, exit_code, raw_output, advisory, duration_ms, created_at, outcome, reason,
                 prev_hash, entry_hash, chain_anchor_id, validation_run_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (filePath as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (validatorName as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 4, (category as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 5, exitCode)
            Self.bindOptionalText(stmt, 6, rawOutput)
            sqlite3_bind_text(stmt, 7, (advisory as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 8, Int32(durationMs))
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_bind_text(stmt, 10, (resolvedOutcome as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 11, reason)
            Self.bindOptionalText(stmt, 12, prevHash)
            sqlite3_bind_text(stmt, 13, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 14, anchorId)
            Self.bindOptionalText(stmt, 15, validationRunId)
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

    /// V.18a-5 — read a row's `validation_run_id` by row id. nil if the
    /// row is missing or the column is NULL. Tests use this to verify
    /// the writer round-trips the id; production callers go through the
    /// JOIN against `runtime_telemetry_span` instead.
    func validationRunId(forResultId id: Int64) -> String? {
        return parent.queue.sync { () -> String? in
            guard let db = parent.db else { return nil }
            let sql = "SELECT validation_run_id FROM validation_results WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    /// V.18a-5 — fetch the most recent `validation_results.id` for a
    /// session. Tests use this to find the row a writer just landed
    /// without depending on flush ordering.
    func mostRecentValidationResultId(sessionId: String) -> Int64? {
        return parent.queue.sync { () -> Int64? in
            guard let db = parent.db else { return nil }
            let sql = "SELECT id FROM validation_results WHERE session_id = ? ORDER BY created_at DESC, id DESC LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(stmt, 0)
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
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)

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
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let outcome {
                sqlite3_bind_text(stmt, 2, (outcome as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
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

    /// U.9b-3b — synchronous, idempotent delivery claim for the bus-side
    /// `validation` consumer (`ValidationStreamConsumer`). Marks ONE
    /// advisory row delivered+surfaced IFF it is still pending; returns
    /// `true` only when THIS call flipped the row. The guarded WHERE
    /// clause is the cross-leg arbiter: a replayed event or a row the
    /// in-process HookRouter leg already surfaced loses the claim, so at
    /// most one `auto_validate.delivered` is ever driven per row.
    ///
    /// Unlike `markValidationAdvisoriesSurfaced` (fire-and-forget async),
    /// this is `queue.sync` — the caller needs the claimed/lost result to
    /// decide whether to drive the delivered counter. Same UPDATE shape as
    /// the existing surfaced path (`delivered`, `surfaced_at` only).
    func claimValidationDelivery(resultId: Int64, at: Date = Date()) -> Bool {
        let ts = at.timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                UPDATE validation_results
                   SET delivered = 1, surfaced_at = ?
                 WHERE id = ?
                   AND outcome = 'advisory'
                   AND exit_code != 0
                   AND delivered = 0
                   AND surfaced_at IS NULL;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Logger.log("auto_validate.db_write.prepare_failed", fields: [
                    "table": .string("validation_results"),
                    "operation": .string("claim_delivery"),
                ])
                return false
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_int64(stmt, 2, resultId)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                Logger.log("auto_validate.db_write.step_failed", fields: [
                    "table": .string("validation_results"),
                    "operation": .string("claim_delivery"),
                ])
                return false
            }
            return sqlite3_changes(db) == 1
        }
    }

    /// U.2a-2b — insert a structured browser-validation row. Populates the
    /// v22 columns (`axes`, `target_url`, `plan_steps`, `result_status`,
    /// `screenshot_path`) so HookRouter's PreToolUse gate can read
    /// `result_status = 'fail'` for the session.
    ///
    /// Chain note (v29 round, 2026-05-21): this writer is the lazy-open
    /// trigger for the `migration-v22` anchor. When the current anchor
    /// is `fresh-install-pre-v22`, the first browser-validation write
    /// opens a `migration-v22` anchor at `MAX(id)` so that all
    /// subsequent rows — both browser and auto-validate — chain under
    /// the v22 canonical shape (which includes axes / target_url /
    /// plan_steps / result_status / screenshot_path in the hash). Rows
    /// already chained under `fresh-install-pre-v22` keep verifying
    /// under the pre-v22 shape. Post-v29 fresh installs land on a
    /// `fresh-install` anchor whose shape is v22 from row 1 — no rename
    /// + no migration-v22 needed.
    func insertBrowserValidationResult(
        sessionId: String,
        targetURL: String,
        axes: [String],
        planStepsJSON: String,
        resultStatus: String,
        assertionsPassed: Int,
        assertionsFailed: Int,
        advisory: String,
        screenshotPath: String?,
        validationRunId: String? = nil
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

            let (anchorId, useV22Shape) = self.resolveWriteAnchorLocked(db: db, ensureV22: true)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            let columns = Self.canonicalColumns(
                sessionId: sessionId,
                filePath: targetURL,
                validatorName: "validate_browser",
                category: "browser",
                exitCode: exitCode,
                rawOutput: nil,
                advisory: advisory,
                durationMs: durationMs,
                createdAt: now,
                delivered: 0,
                outcome: legacyOutcome,
                reason: nil,
                surfacedAt: nil,
                axesJSON: axesJSON,
                targetURL: targetURL,
                planStepsJSON: planStepsJSON,
                resultStatus: resultStatus,
                screenshotPath: screenshotPath,
                useV22Shape: useV22Shape
            )
            let entryHash = ChainHasher.entryHash(
                table: "validation_results", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO validation_results
                (session_id, file_path, validator_name, category, exit_code, raw_output, advisory, duration_ms, created_at, outcome, reason,
                 prev_hash, entry_hash, chain_anchor_id,
                 axes, target_url, plan_steps, result_status, screenshot_path,
                 validation_run_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            // SQLite TRANSIENT — make SQLite copy the bound bytes immediately.
            // Required for any binding whose backing storage is a transient
            // C-string bridge (Swift String → CChar pointer), because the
            // SQLITE_STATIC contract assumes the pointer is valid until
            // sqlite3_step, which Swift's bridge cannot guarantee for
            // expression-temporary `String as NSString`-derived pointers.
            // Latent corruption pre-v29 — never tripped because the v22
            // columns were not yet hashed; verifier reads of `category` /
            // `validator_name` could silently see other column bytes.
            let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, sessionId, -1, transient)
            sqlite3_bind_text(stmt, 2, targetURL, -1, transient)
            sqlite3_bind_text(stmt, 3, "validate_browser", -1, transient)
            sqlite3_bind_text(stmt, 4, "browser", -1, transient)
            sqlite3_bind_int(stmt, 5, exitCode)
            sqlite3_bind_null(stmt, 6)
            sqlite3_bind_text(stmt, 7, advisory, -1, transient)
            sqlite3_bind_int(stmt, 8, Int32(durationMs))
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_bind_text(stmt, 10, legacyOutcome, -1, transient)
            sqlite3_bind_null(stmt, 11)
            if let prevHash {
                sqlite3_bind_text(stmt, 12, prevHash, -1, transient)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            sqlite3_bind_text(stmt, 13, entryHash, -1, transient)
            sqlite3_bind_int64(stmt, 14, anchorId)
            sqlite3_bind_text(stmt, 15, axesJSON, -1, transient)
            sqlite3_bind_text(stmt, 16, targetURL, -1, transient)
            sqlite3_bind_text(stmt, 17, planStepsJSON, -1, transient)
            sqlite3_bind_text(stmt, 18, resultStatus, -1, transient)
            if let screenshotPath {
                sqlite3_bind_text(stmt, 19, screenshotPath, -1, transient)
            } else {
                sqlite3_bind_null(stmt, 19)
            }
            // V.18a-5 — validation_run_id is the JOIN key against
            // runtime_telemetry_span (validation_run_id index). Not in
            // canonicalColumns: the chain shape stays v22.
            if let validationRunId {
                sqlite3_bind_text(stmt, 20, validationRunId, -1, transient)
            } else {
                sqlite3_bind_null(stmt, 20)
            }
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
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
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

    /// U.11a-2 — resolve a batch of `validation_run_id` UUIDs against
    /// `validation_results`. Returns a structured `(resolved,
    /// unresolved)` partition so callers can act on missing evidence
    /// without throwing. Unresolved IDs are preserved verbatim;
    /// resolved rows carry the (run_id, row_id, outcome, exit_code)
    /// quadruple `ValidationAssertion.deriveState` needs.
    ///
    /// Matching is against `validation_run_id = uuid.uuidString` —
    /// the v22 column is a TEXT free-form id (declared `String?`),
    /// and the UUIDs an assertion carries are serialized as their
    /// canonical uuidString form when written by the producer.
    ///
    /// Duplicates inside `runIDs` collapse to a single resolution
    /// attempt (the result set will contain at most one entry per
    /// distinct ID). The first matching row wins if the producer
    /// landed multiple `validation_results` rows under the same
    /// `validation_run_id` — by-design for advisory/clean pairs.
    func resolveValidationRuns(_ runIDs: [UUID]) -> ValidationEvidenceResolution {
        guard !runIDs.isEmpty else {
            return ValidationEvidenceResolution(resolved: [], unresolved: [])
        }
        let distinct = Array(Set(runIDs))
        let idStrings = distinct.map { $0.uuidString }

        return parent.queue.sync {
            guard let db = parent.db else {
                return ValidationEvidenceResolution(resolved: [], unresolved: distinct)
            }
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT id, validation_run_id, outcome, exit_code
                FROM validation_results
                WHERE validation_run_id IN (\(placeholders))
                ORDER BY id ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return ValidationEvidenceResolution(resolved: [], unresolved: distinct)
            }
            defer { sqlite3_finalize(stmt) }
            for (i, s) in idStrings.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (s as NSString).utf8String,
                                  -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            // First-row-wins per run_id (input order from `distinct`).
            var byID: [UUID: ResolvedValidationEvidence] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                let runStr = String(cString: sqlite3_column_text(stmt, 1))
                guard let runUUID = UUID(uuidString: runStr) else { continue }
                if byID[runUUID] != nil { continue }
                let outcome = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? "" : String(cString: sqlite3_column_text(stmt, 2))
                let exitCode = sqlite3_column_int(stmt, 3)
                byID[runUUID] = ResolvedValidationEvidence(
                    runID: runUUID,
                    resultRowID: rowID,
                    outcome: outcome,
                    exitCode: exitCode
                )
            }
            var resolved: [ResolvedValidationEvidence] = []
            var unresolved: [UUID] = []
            for id in distinct {
                if let row = byID[id] {
                    resolved.append(row)
                } else {
                    unresolved.append(id)
                }
            }
            return ValidationEvidenceResolution(resolved: resolved, unresolved: unresolved)
        }
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

    // MARK: - v22 chain shape

    /// Anchor name the v29 migration uses to mark legacy chain rows.
    /// Rows under this anchor were hashed under the 13-column shape
    /// (pre-v22). Rows under any other anchor reason for
    /// `validation_results` use the 18-column v22 shape that includes
    /// `axes`, `target_url`, `plan_steps`, `result_status`,
    /// `screenshot_path`. See `Migrations.swift` v29 +
    /// `ChainVerifier.verifyAnchorValidationResults`.
    static let legacyV22AnchorReason = "fresh-install-pre-v22"

    /// Anchor reason for the lazy-opened v22 anchor. Public so the
    /// verifier + tests reference the same literal.
    static let migrationV22AnchorReason = "migration-v22"

    /// Resolve the anchor a write should chain under, plus whether the
    /// writer should emit the v22 (18-column) canonical shape.
    ///
    /// - When `ensureV22 == true` (browser-validation writer) and the
    ///   current anchor is `fresh-install-pre-v22`, lazy-open a
    ///   `migration-v22` anchor at `MAX(id)` and return its id with
    ///   `useV22Shape = true`. Idempotent — second call returns the
    ///   existing migration-v22 anchor without inserting a duplicate.
    /// - When `ensureV22 == false` (auto-validate writer), stay on
    ///   whatever anchor is current; only the canonical shape varies.
    ///
    /// Caller MUST be on `parent.queue`.
    private func resolveWriteAnchorLocked(db: OpaquePointer, ensureV22: Bool) -> (anchorId: Int64, useV22Shape: Bool) {
        let current = chain.resolveAnchorId(db: db)
        let reason = chain.anchorReason(db: db, anchorId: current) ?? ""
        if reason == Self.legacyV22AnchorReason {
            if ensureV22 {
                let newAnchorId = Self.openMigrationV22AnchorLocked(db: db)
                if newAnchorId > 0 {
                    chain.invalidate()
                    _ = chain.resolveAnchorId(db: db)  // repopulate cache with new MAX(id)
                    return (newAnchorId, true)
                }
                // Lazy-open failed — fall back to legacy anchor so the
                // write still succeeds. Loud failure here would block
                // every browser-validation write on an SQL-level error
                // the operator can't recover from inline.
                return (current, false)
            }
            return (current, false)
        }
        // fresh-install (post-v29), migration-v22, any future repair-*
        // anchor name → v22 canonical shape.
        return (current, true)
    }

    /// Lazy-opens the `migration-v22` anchor at `MAX(id)` for
    /// `validation_results`. Idempotent — if a `migration-v22` anchor
    /// already exists for this table, returns its id without inserting
    /// a new one. Returns -1 on SQL error.
    private static func openMigrationV22AnchorLocked(db: OpaquePointer) -> Int64 {
        // Idempotency lookup first — operator may invoke
        // browser-validation repeatedly across process restarts.
        var lookupStmt: OpaquePointer?
        let lookupSQL = "SELECT id FROM chain_anchors WHERE table_name = 'validation_results' AND reason = 'migration-v22' ORDER BY id ASC LIMIT 1;"
        if sqlite3_prepare_v2(db, lookupSQL, -1, &lookupStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(lookupStmt) }
            if sqlite3_step(lookupStmt) == SQLITE_ROW,
               sqlite3_column_type(lookupStmt, 0) != SQLITE_NULL {
                return sqlite3_column_int64(lookupStmt, 0)
            }
        }
        // MAX(id) of validation_results — every row at this point or
        // earlier belongs to the legacy `fresh-install-pre-v22` segment.
        var maxStmt: OpaquePointer?
        var maxRowid: Int64 = 0
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM validation_results;"
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
            VALUES ('validation_results', ?, ?, 'migration-v22', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(insertStmt) }
        sqlite3_bind_double(insertStmt, 1, now)
        sqlite3_bind_int64(insertStmt, 2, maxRowid)
        guard sqlite3_step(insertStmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Build the canonical column map for one validation_results row.
    /// `useV22Shape` controls inclusion of the v22 columns (`axes`,
    /// `target_url`, `plan_steps`, `result_status`, `screenshot_path`).
    /// Both writers feed this helper so the column set stays consistent
    /// for a given shape — if a writer drifted (e.g. forgot a default
    /// slot), the verifier would surface a hash mismatch on the next
    /// chain walk.
    static func canonicalColumns(
        sessionId: String,
        filePath: String,
        validatorName: String,
        category: String,
        exitCode: Int32,
        rawOutput: String?,
        advisory: String,
        durationMs: Int,
        createdAt: Double,
        delivered: Int,
        outcome: String,
        reason: String?,
        surfacedAt: Double?,
        axesJSON: String,
        targetURL: String?,
        planStepsJSON: String,
        resultStatus: String?,
        screenshotPath: String?,
        useV22Shape: Bool
    ) -> [String: ChainHasher.CanonicalValue] {
        var cols: [String: ChainHasher.CanonicalValue] = [
            "session_id":     .text(sessionId),
            "file_path":      .text(filePath),
            "validator_name": .text(validatorName),
            "category":       .text(category),
            "exit_code":      .integer(Int64(exitCode)),
            "raw_output":     rawOutput.map { .text($0) } ?? .null,
            "advisory":       .text(advisory),
            "duration_ms":    .integer(Int64(durationMs)),
            "created_at":     .real(createdAt),
            "delivered":      .integer(Int64(delivered)),
            "outcome":        .text(outcome),
            "reason":         reason.map { .text($0) } ?? .null,
            "surfaced_at":    surfacedAt.map { .real($0) } ?? .null,
        ]
        if useV22Shape {
            cols["axes"]            = .text(axesJSON)
            cols["target_url"]      = targetURL.map { .text($0) } ?? .null
            cols["plan_steps"]      = .text(planStepsJSON)
            cols["result_status"]   = resultStatus.map { .text($0) } ?? .null
            cols["screenshot_path"] = screenshotPath.map { .text($0) } ?? .null
        }
        return cols
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
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
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
