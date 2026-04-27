import Foundation
import SQLite3

/// Owns the `sessions`, `commands`, and `commands_fts` tables end-to-end —
/// schema + triggers + per-call query path. Extracted from `SessionDatabase`
/// under `sessiondb-split-2-commandstore` as the first real split of the
/// façade (Luminary P2-11). Shares the parent's connection + dispatch queue;
/// never opens a new SQLite handle.
///
/// Public API is forwarded from `SessionDatabase` — callers keep using
/// `SessionDatabase.shared.createSession(…)` etc. and the façade delegates
/// here. No callsite outside this file and `SessionDatabase.swift` should
/// reference `CommandStore` directly today.
final class CommandStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    // T.5 round 3 — chain state for the `commands` table. Both
    // `recordCommand` and `recordBudgetDecision` write through this state.
    private let chain = ChainState(table: "commands")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Schema

    /// Create the sessions / commands / commands_fts surface. Idempotent —
    /// safe to call on every open. The FTS5 triggers keep the virtual table
    /// in sync with `commands`; the `recordCommand` path wraps those writes
    /// in a BEGIN IMMEDIATE transaction (see below).
    func setupSchema() {
        let stmts = [
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                duration_seconds REAL,
                total_raw_bytes INTEGER DEFAULT 0,
                total_saved_bytes INTEGER DEFAULT 0,
                command_count INTEGER DEFAULT 0,
                pane_count INTEGER DEFAULT 0,
                cost_saved_cents INTEGER DEFAULT 0
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS commands (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                timestamp REAL NOT NULL,
                tool_name TEXT NOT NULL,
                command TEXT,
                raw_bytes INTEGER NOT NULL,
                compressed_bytes INTEGER NOT NULL,
                feature TEXT,
                output_preview TEXT
            );
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS commands_fts USING fts5(
                tool_name, command, output_preview,
                content=commands, content_rowid=id
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS commands_ai AFTER INSERT ON commands BEGIN
                INSERT INTO commands_fts(rowid, tool_name, command, output_preview)
                VALUES (new.id, new.tool_name, new.command, new.output_preview);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS commands_ad AFTER DELETE ON commands BEGIN
                INSERT INTO commands_fts(commands_fts, rowid, tool_name, command, output_preview)
                VALUES ('delete', old.id, old.tool_name, old.command, old.output_preview);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS commands_au AFTER UPDATE ON commands BEGIN
                INSERT INTO commands_fts(commands_fts, rowid, tool_name, command, output_preview)
                VALUES ('delete', old.id, old.tool_name, old.command, old.output_preview);
                INSERT INTO commands_fts(rowid, tool_name, command, output_preview)
                VALUES (new.id, new.tool_name, new.command, new.output_preview);
            END;
            """,
        ]

        // Column migrations — ALTER TABLE fails silently when a column
        // already exists. Index migrations are IF NOT EXISTS, so also idempotent.
        let migrations = [
            "ALTER TABLE commands ADD COLUMN budget_decision TEXT;",
            "ALTER TABLE sessions ADD COLUMN project_root TEXT;",
            "ALTER TABLE sessions ADD COLUMN agent_type TEXT;",
            "CREATE INDEX IF NOT EXISTS idx_sessions_project_ended ON sessions(project_root, ended_at);",
            "CREATE INDEX IF NOT EXISTS idx_sessions_agent_type ON sessions(agent_type);",
        ]

        parent.queue.sync {
            for sql in stmts { self.exec(sql) }
            for sql in migrations { self.execSilent(sql) }
        }
    }

    // MARK: - Public API (delegated from SessionDatabase)

    /// Create a new session and return its ID.
    @discardableResult
    func createSession(paneCount: Int = 0, projectRoot: String? = nil, agentType: AgentType? = nil) -> String {
        let id = UUID().uuidString
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return id }
            let sql = "INSERT INTO sessions (id, started_at, pane_count, project_root, agent_type) VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_int(stmt, 3, Int32(paneCount))
            if let root = normalizedRoot {
                sqlite3_bind_text(stmt, 4, (root as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let agent = agentType {
                sqlite3_bind_text(stmt, 5, (agent.rawValue as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_step(stmt)
            return id
        }
    }

    /// Record a single command within a session.
    ///
    /// P3-13: wrapped in BEGIN IMMEDIATE / COMMIT so the INSERT into `commands`
    /// (plus the FTS5 trigger sync) and the UPDATE of `sessions` aggregates are
    /// atomic. The transaction boundary is the load-bearing contract that makes
    /// search results consistent under concurrent writes.
    func recordCommand(
        sessionId: String,
        toolName: String,
        command: String?,
        rawBytes: Int,
        compressedBytes: Int,
        feature: String? = nil,
        outputPreview: String? = nil
    ) {
        let now = Date().timeIntervalSince1970
        // C1 (Cavoukian privacy pass 2026-04-16): redact secrets from the
        // command string before persistence. Routed through the shared
        // PersistenceRedaction helper so this store, TokenEventStore, and
        // SandboxStore all follow the same policy.
        let cmdRedaction = PersistenceRedaction.redact(command)
        let redactedCommand = cmdRedaction.redacted
        let didRedact = cmdRedaction.patternsMatched > 0
        // Output preview also gets redacted — it's capped at 500 chars but
        // a single `Authorization: Bearer ey...` line fits inside that cap.
        let previewRedaction = PersistenceRedaction.redact(outputPreview.map { String($0.prefix(500)) })
        let preview = previewRedaction.redacted
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }

            // T.5 round 3: chain-aware insert. Canonical bytes include every
            // data column (NULL for unbound legacy ones) so the verifier can
            // re-derive the hash from a SELECT *.
            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":       .text(sessionId),
                "timestamp":        .real(now),
                "tool_name":        .text(toolName),
                "command":          redactedCommand.map { .text($0) } ?? .null,
                "raw_bytes":        .integer(Int64(rawBytes)),
                "compressed_bytes": .integer(Int64(compressedBytes)),
                "feature":          feature.map { .text($0) } ?? .null,
                "output_preview":   preview.map { .text($0) } ?? .null,
                "budget_decision":  .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: "commands", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO commands (session_id, timestamp, tool_name, command, raw_bytes, compressed_bytes, feature, output_preview,
                                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, (toolName as NSString).utf8String, -1, nil)
            if let cmd = redactedCommand {
                sqlite3_bind_text(stmt, 4, (cmd as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int64(stmt, 5, Int64(rawBytes))
            sqlite3_bind_int64(stmt, 6, Int64(compressedBytes))
            if let feat = feature {
                sqlite3_bind_text(stmt, 7, (feat as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let prev = preview {
                sqlite3_bind_text(stmt, 8, (prev as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let prevH = prevHash {
                sqlite3_bind_text(stmt, 9, (prevH as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_text(stmt, 10, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 11, anchorId)
            let insertRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard insertRC == SQLITE_DONE else { return }
            // Cache update fires only on commit (committed=true after the
            // sessions UPDATE succeeds). Wire through the existing commit
            // flow rather than this early return.
            self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)

            let updateSQL = """
                UPDATE sessions SET
                    total_raw_bytes = total_raw_bytes + ?,
                    total_saved_bytes = total_saved_bytes + ?,
                    command_count = command_count + 1,
                    cost_saved_cents = cost_saved_cents + ?
                WHERE id = ?;
                """
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
            let saved = rawBytes - compressedBytes
            let costCents = ModelPricing.costSavedCents(bytes: saved)
            sqlite3_bind_int64(updateStmt, 1, Int64(rawBytes))
            sqlite3_bind_int64(updateStmt, 2, Int64(saved))
            sqlite3_bind_int(updateStmt, 3, Int32(costCents))
            sqlite3_bind_text(updateStmt, 4, (sessionId as NSString).utf8String, -1, nil)
            let updateRC = sqlite3_step(updateStmt)
            sqlite3_finalize(updateStmt)
            guard updateRC == SQLITE_DONE else { return }

            if sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK {
                committed = true
            }
        }
        // Observability: count redactions as a privacy-health signal.
        // Emitted outside the queue block so it enqueues its own update —
        // keeps the commands-insert transaction minimal.
        if didRedact {
            parent.recordEvent(type: "security.command.redacted", projectRoot: nil)
        }
    }

    /// End a session, recording its end time and duration.
    func endSession(sessionId: String) {
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            let sql = """
                UPDATE sessions SET
                    ended_at = ?,
                    duration_seconds = ? - started_at
                WHERE id = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Load recent session summaries.
    /// SECURITY: Limit parameter is capped at 500 to prevent resource exhaustion.
    func loadSessions(limit: Int = 50) -> [SessionSummaryRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, started_at, duration_seconds, total_raw_bytes, total_saved_bytes,
                       command_count, pane_count, cost_saved_cents
                FROM sessions
                ORDER BY started_at DESC
                LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(min(limit, 500)))

            var rows: [SessionSummaryRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let startedAt = sqlite3_column_double(stmt, 1)
                let duration = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 2)
                let rawBytes = Int(sqlite3_column_int64(stmt, 3))
                let savedBytes = Int(sqlite3_column_int64(stmt, 4))
                let cmdCount = Int(sqlite3_column_int(stmt, 5))
                let paneCount = Int(sqlite3_column_int(stmt, 6))
                let costCents = Int(sqlite3_column_int(stmt, 7))

                rows.append(SessionSummaryRow(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: startedAt),
                    duration: duration,
                    totalRaw: rawBytes,
                    totalSaved: savedBytes,
                    commandCount: cmdCount,
                    paneCount: paneCount,
                    costSavedCents: costCents
                ))
            }
            return rows
        }
    }

    /// Full-text search across commands.
    /// SECURITY: The query is sanitized for FTS5 — special operators are stripped
    /// and terms are quoted to prevent FTS5 query injection (e.g., column filters,
    /// NEAR/OR/NOT abuse, or DoS via complex expressions).
    func search(query: String, limit: Int = 50) -> [CommandSearchResult] {
        let sanitized = Self.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }

        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT c.id, c.session_id, c.timestamp, c.tool_name, c.command,
                       c.raw_bytes, c.compressed_bytes, c.feature, c.output_preview
                FROM commands c
                JOIN commands_fts f ON c.id = f.rowid
                WHERE commands_fts MATCH ?
                ORDER BY c.timestamp DESC
                LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sanitized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(min(limit, 200)))

            var results: [CommandSearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowId = Int(sqlite3_column_int64(stmt, 0))
                let sessionId = String(cString: sqlite3_column_text(stmt, 1))
                let ts = sqlite3_column_double(stmt, 2)
                let toolName = String(cString: sqlite3_column_text(stmt, 3))
                let cmd = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
                let raw = Int(sqlite3_column_int64(stmt, 5))
                let compressed = Int(sqlite3_column_int64(stmt, 6))
                let feat = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 7))
                let preview = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 8))

                results.append(CommandSearchResult(
                    id: rowId,
                    sessionId: sessionId,
                    timestamp: Date(timeIntervalSince1970: ts),
                    toolName: toolName,
                    command: cmd,
                    rawBytes: raw,
                    compressedBytes: compressed,
                    feature: feat,
                    outputPreview: preview
                ))
            }
            return results
        }
    }

    // MARK: - Stats + analytics

    /// Lifetime stats across all sessions.
    func totalStats() -> LifetimeStats {
        return parent.queue.sync {
            guard let db = parent.db else {
                return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
            }
            let sql = """
                SELECT COUNT(*), COALESCE(SUM(command_count),0), COALESCE(SUM(total_raw_bytes),0),
                       COALESCE(SUM(total_saved_bytes),0), COALESCE(SUM(cost_saved_cents),0)
                FROM sessions;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
            }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return LifetimeStats(
                    totalSessions: Int(sqlite3_column_int(stmt, 0)),
                    totalCommands: Int(sqlite3_column_int64(stmt, 1)),
                    totalRawBytes: Int(sqlite3_column_int64(stmt, 2)),
                    totalSavedBytes: Int(sqlite3_column_int64(stmt, 3)),
                    totalCostSavedCents: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
        }
    }

    /// Aggregate stats for a specific project root. Used by the GUI to poll metrics.
    func statsForProject(_ projectRoot: String) -> LifetimeStats {
        return parent.queue.sync {
            guard let db = parent.db else {
                return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
            }
            let sql = """
                SELECT COUNT(*), COALESCE(SUM(command_count),0), COALESCE(SUM(total_raw_bytes),0),
                       COALESCE(SUM(total_saved_bytes),0), COALESCE(SUM(cost_saved_cents),0)
                FROM sessions WHERE project_root = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (projectRoot as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return LifetimeStats(
                    totalSessions: Int(sqlite3_column_int(stmt, 0)),
                    totalCommands: Int(sqlite3_column_int64(stmt, 1)),
                    totalRawBytes: Int(sqlite3_column_int64(stmt, 2)),
                    totalSavedBytes: Int(sqlite3_column_int64(stmt, 3)),
                    totalCostSavedCents: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
        }
    }

    /// Aggregate stats for commands in the database since a timestamp.
    func recentStats(since: Date) -> LifetimeStats {
        return parent.queue.sync {
            guard let db = parent.db else {
                return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
            }
            let sql = """
                SELECT COUNT(*), COALESCE(SUM(command_count),0), COALESCE(SUM(total_raw_bytes),0),
                       COALESCE(SUM(total_saved_bytes),0), COALESCE(SUM(cost_saved_cents),0)
                FROM sessions WHERE started_at >= ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return LifetimeStats(
                    totalSessions: Int(sqlite3_column_int(stmt, 0)),
                    totalCommands: Int(sqlite3_column_int64(stmt, 1)),
                    totalRawBytes: Int(sqlite3_column_int64(stmt, 2)),
                    totalSavedBytes: Int(sqlite3_column_int64(stmt, 3)),
                    totalCostSavedCents: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return LifetimeStats(totalSessions: 0, totalCommands: 0, totalRawBytes: 0, totalSavedBytes: 0, totalCostSavedCents: 0)
        }
    }

    /// Per-command breakdown for bar charts.
    func commandBreakdown(projectRoot: String) -> [(command: String, rawBytes: Int, compressedBytes: Int)] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT c.command, SUM(c.raw_bytes), SUM(c.compressed_bytes)
                FROM commands c
                JOIN sessions s ON c.session_id = s.id
                WHERE s.project_root = ?
                AND c.command IS NOT NULL AND c.command != ''
                GROUP BY c.command
                ORDER BY SUM(c.raw_bytes) - SUM(c.compressed_bytes) DESC
                LIMIT 20;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)

            var results: [(command: String, rawBytes: Int, compressedBytes: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { continue }
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let raw = Int(sqlite3_column_int64(stmt, 1))
                let compressed = Int(sqlite3_column_int64(stmt, 2))
                results.append((command: cmd, rawBytes: raw, compressedBytes: compressed))
            }
            return results
        }
    }

    /// Return recent `commands.output_preview` rows for regression-gate sampling.
    func outputPreviewsForCommand(
        projectRoot: String?,
        commandPrefix: String,
        limit: Int = 20
    ) -> [String] {
        let likePattern = commandPrefix + "%"
        return parent.queue.sync {
            guard let db = parent.db else { return [] }

            let sql: String
            if projectRoot != nil {
                sql = """
                    SELECT c.output_preview
                    FROM commands c
                    JOIN sessions s ON s.id = c.session_id
                    WHERE c.tool_name = 'exec'
                      AND c.output_preview IS NOT NULL
                      AND c.output_preview != ''
                      AND (c.command = ? OR c.command LIKE ?)
                      AND s.project_root = ?
                    ORDER BY c.timestamp DESC
                    LIMIT ?;
                """
            } else {
                sql = """
                    SELECT output_preview
                    FROM commands
                    WHERE tool_name = 'exec'
                      AND output_preview IS NOT NULL
                      AND output_preview != ''
                      AND (command = ? OR command LIKE ?)
                    ORDER BY timestamp DESC
                    LIMIT ?;
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (commandPrefix as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (likePattern as NSString).utf8String, -1, nil)
            var nextBind: Int32 = 3
            if let root = projectRoot {
                let normalized = SessionDatabase.normalizePath(root) ?? root
                sqlite3_bind_text(stmt, nextBind, (normalized as NSString).utf8String, -1, nil)
                nextBind += 1
            }
            sqlite3_bind_int(stmt, nextBind, Int32(limit))

            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: ptr))
                }
            }
            return rows
        }
    }

    // MARK: - Budget queries

    /// Total cost_saved_cents for sessions started today (UTC).
    func costForToday() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = """
                SELECT COALESCE(SUM(cost_saved_cents), 0)
                FROM sessions
                WHERE date(started_at, 'unixepoch') = date('now');
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
    }

    /// Total cost_saved_cents for sessions started in the last 7 days (UTC).
    func costForWeek() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = """
                SELECT COALESCE(SUM(cost_saved_cents), 0)
                FROM sessions
                WHERE started_at >= strftime('%s', 'now', '-7 days');
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
    }

    /// Record a budget decision for a command.
    func recordBudgetDecision(
        sessionId: String,
        toolName: String,
        decision: String,
        rawBytes: Int = 0,
        compressedBytes: Int = 0
    ) {
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            // T.5 round 3: chain-aware budget-decision insert. Canonical
            // bytes match the SELECT-* shape — all eight data columns plus
            // budget_decision; unbound columns are NULL.
            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            let columns: [String: ChainHasher.CanonicalValue] = [
                "session_id":       .text(sessionId),
                "timestamp":        .real(now),
                "tool_name":        .text(toolName),
                "command":          .null,
                "raw_bytes":        .integer(Int64(rawBytes)),
                "compressed_bytes": .integer(Int64(compressedBytes)),
                "feature":          .null,
                "output_preview":   .null,
                "budget_decision":  .text(decision),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "commands", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO commands (session_id, timestamp, tool_name, raw_bytes, compressed_bytes, budget_decision,
                                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, (toolName as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 4, Int64(rawBytes))
            sqlite3_bind_int64(stmt, 5, Int64(compressedBytes))
            sqlite3_bind_text(stmt, 6, (decision as NSString).utf8String, -1, nil)
            if let prevH = prevHash {
                sqlite3_bind_text(stmt, 7, (prevH as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_bind_text(stmt, 8, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 9, anchorId)
            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// Execute a raw SQL statement (for tests that backdate or shape fixtures).
    func executeRawSQL(_ sql: String) {
        parent.queue.sync {
            guard let db = parent.db else { return }
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // MARK: - FTS5 sanitizer

    /// SECURITY: Sanitize user input for FTS5 MATCH queries.
    /// Strips FTS5 operators (OR, AND, NOT, NEAR, column filters, prefix *)
    /// and wraps each term in double-quotes to prevent query injection.
    /// Empty or all-whitespace input returns empty string (caller should skip query).
    static func sanitizeFTS5Query(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == " " || scalar == "-" || scalar == "_" || scalar == "."
        }
        let cleaned = String(stripped)

        let ftsKeywords: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let terms = cleaned.split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty && !ftsKeywords.contains($0.uppercased()) }

        guard !terms.isEmpty else { return "" }

        return terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            Logger.log("db.command.sql_error", fields: [
                "error": .string(msg),
                "outcome": .string("error"),
            ])
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
