import Foundation
import SQLite3

// MARK: - Split plan (Luminary P2-11, deferred)
//
// This file is the single façade for everything in the session SQLite DB:
// sessions, commands, FTS5, token_events, sandboxed_results,
// validation_results, hook_events, event_counters, migrations, retention.
// It passed the 2026-04 Luminary audit as "too large but not yet dangerous";
// the split was deferred until the conditions below are met, and this comment
// is the handoff for whoever picks it up.
//
// Gate (all three required before splitting):
//   1. Wave 2 migration system landed.               ✅ 2026-04-15
//   2. A second contributor needs to touch the DB layer.
//   3. Bounded contexts clarified by a concrete feature ask.
//
// Target carve-up (Evans / Kleppmann): each store owns its own transaction
// boundary and is reachable from Core only through this file.
//
//   CommandStore       — sessions, commands, commands_fts, recordCommand
//                        (the FTS5 sync already uses BEGIN IMMEDIATE — keep
//                        that transactional boundary in the carve-out).
//   TokenEventStore    — token_events, claude_session_cursors,
//                        tokenStats*, hotFiles, liveSessionMultiplier.
//   SandboxStore       — sandboxed_results + prune-on-start.
//   ValidationStore    — validation_results + AutoValidate integration.
//   HookEventStore     — hook_events (interception telemetry).
//
// What stays on `SessionDatabase`:
//   - The `Connection`/`DatabaseQueue` lifecycle.
//   - `MigrationRunner` invocation (flock + kill-switch).
//   - Cross-store aggregates that today exist as SQL JOINs
//     (`lifetimeStats`, `tokenStatsForProject` joining sessions ↔ events).
//     These become thin façade methods that call the stores and compose.
//
// What deliberately does NOT move (Torvalds):
//   - `event_counters` (`recordEvent`/`eventCounts`) — trivial table, moving
//     it would mean every defense site imports a new store just to bump a
//     counter. Keep on the façade.
//   - `schema_migrations` read/write — owned by the migration runner.
//
// When you do split, land it in three commits so reverts stay scoped:
//   1. Extract `CommandStore` (biggest, lowest cross-table coupling).
//   2. Extract `TokenEventStore` (depends on session id but not command id).
//   3. Extract the two 24-h prune stores together (they share the retention
//      scheduler cadence).
//
// Do not split in a feature branch that also changes schema. The migration
// system is the other half of the contract and must stay stable across the
// refactor; if you need new columns, land them first on a migration PR,
// then split, then use them.

/// Result row from full-text search across commands.
public struct CommandSearchResult: Identifiable, Sendable {
    public let id: Int
    public let sessionId: String
    public let timestamp: Date
    public let toolName: String
    public let command: String?
    public let rawBytes: Int
    public let compressedBytes: Int
    public let feature: String?
    public let outputPreview: String?
}

/// Lifetime stats across all sessions.
public struct LifetimeStats: Sendable {
    public let totalSessions: Int
    public let totalCommands: Int
    public let totalRawBytes: Int
    public let totalSavedBytes: Int
    public let totalCostSavedCents: Int

    public init(totalSessions: Int, totalCommands: Int, totalRawBytes: Int, totalSavedBytes: Int, totalCostSavedCents: Int) {
        self.totalSessions = totalSessions
        self.totalCommands = totalCommands
        self.totalRawBytes = totalRawBytes
        self.totalSavedBytes = totalSavedBytes
        self.totalCostSavedCents = totalCostSavedCents
    }
}

/// Aggregated token stats for a pane or project.
public struct PaneTokenStats: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int
    public let costCents: Int
    public let commandCount: Int

    public static let zero = PaneTokenStats(inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0, commandCount: 0)
}

/// Thread-safe SQLite+FTS5 session persistence layer.
/// Replaces the JSON-file approach with a proper database at
/// ~/Library/Application Support/Senkani/senkani.db
public final class SessionDatabase: @unchecked Sendable {
    public static let shared = SessionDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.senkani.sessiondb", qos: .utility)

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Senkani")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("senkani.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            print("[SessionDatabase] Failed to open: \(err)")
            db = nil
        }
        enableWAL()
        createTables()
        createTokenEventsTable()
        createSandboxedResultsTable()
        createValidationResultsTable()
        runMigrations(path: dbPath)
    }

    /// Testable initializer — opens a DB at a custom path (use a temp file).
    public init(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if sqlite3_open(path, &db) != SQLITE_OK {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            print("[SessionDatabase] Failed to open test DB: \(err)")
            db = nil
        }
        enableWAL()
        createTables()
        createTokenEventsTable()
        createSandboxedResultsTable()
        createValidationResultsTable()
        runMigrations(path: path)
    }

    // MARK: - Observability counters (migration v2)

    /// One row of the `event_counters` table — a running total of how many
    /// times a named event fired for a given project (or process-globally,
    /// with project_root == "").
    public struct EventCountRow: Sendable {
        public let projectRoot: String
        public let eventType: String
        public let count: Int
        public let firstSeenAt: Date
        public let lastSeenAt: Date
    }

    /// Increment a counter. Creates the row if missing. Event vocabulary is
    /// documented in `spec/roadmap.md` "Observability gaps" and in the
    /// Cavoukian/Schneier findings; the strings currently in use:
    ///   - `security.injection.detected`
    ///   - `security.ssrf.blocked`
    ///   - `security.socket.handshake.rejected`
    ///   - `security.command.redacted`
    ///   - `retention.pruned.token_events`
    ///   - `retention.pruned.sandboxed_results`
    ///   - `retention.pruned.validation_results`
    ///   - `schema.migration.applied`
    ///
    /// `projectRoot == nil` stores under the empty string — process-global
    /// events that aren't tied to a project.
    public func recordEvent(
        type: String,
        projectRoot: String? = nil,
        delta: Int = 1
    ) {
        guard delta != 0 else { return }
        let ts = Date().timeIntervalSince1970
        let root = projectRoot ?? ""
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            // UPSERT: insert new row at 1, or add delta to existing.
            // last_seen_at always updates; first_seen_at only on insert.
            let sql = """
                INSERT INTO event_counters (project_root, event_type, count, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(project_root, event_type) DO UPDATE SET
                    count = count + excluded.count,
                    last_seen_at = excluded.last_seen_at;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (root as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (type as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(delta))
            sqlite3_bind_double(stmt, 4, ts)
            sqlite3_bind_double(stmt, 5, ts)
            sqlite3_step(stmt)
        }
    }

    /// Query event counters. All filters are optional.
    ///   - `projectRoot` — if set, return rows for this project only.
    ///     Pass `""` for process-global events.
    ///   - `prefix` — match event_type on prefix (e.g. `"security."`).
    public func eventCounts(
        projectRoot: String? = nil,
        prefix: String? = nil
    ) -> [EventCountRow] {
        return queue.sync {
            guard let db = db else { return [] }
            var sql = "SELECT project_root, event_type, count, first_seen_at, last_seen_at FROM event_counters"
            var clauses: [String] = []
            if projectRoot != nil { clauses.append("project_root = ?") }
            if prefix != nil      { clauses.append("event_type LIKE ?") }
            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }
            sql += " ORDER BY event_type ASC;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            if let root = projectRoot {
                sqlite3_bind_text(stmt, idx, (root as NSString).utf8String, -1, nil); idx += 1
            }
            if let pfx = prefix {
                let like = pfx + "%"
                sqlite3_bind_text(stmt, idx, (like as NSString).utf8String, -1, nil); idx += 1
            }
            var out: [EventCountRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let root = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let type = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let count = Int(sqlite3_column_int64(stmt, 2))
                let first = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let last = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                out.append(EventCountRow(
                    projectRoot: root, eventType: type, count: count,
                    firstSeenAt: first, lastSeenAt: last
                ))
            }
            return out
        }
    }

    /// Current `PRAGMA user_version` — used by the senkani_version tool and diagnostics.
    /// Returns 0 if the DB is unavailable or pre-migration.
    public func currentSchemaVersion() -> Int {
        return queue.sync {
            guard let db = db else { return 0 }
            return MigrationRunner.currentVersion(db: db)
        }
    }

    /// Run schema migrations after table creation. On failure, log and continue —
    /// the kill-switch lockfile and MigrationError.description surface the issue.
    private func runMigrations(path: String) {
        guard let db = db else { return }
        var applied: [Int] = []
        queue.sync {
            do {
                let report = try MigrationRunner.run(db: db, dbPath: path)
                applied = report.appliedVersions
                if !applied.isEmpty {
                    print("[SessionDatabase] Applied migrations: \(applied)")
                }
            } catch let e as MigrationError {
                print("[SessionDatabase] Migration failed: \(e.description)")
            } catch {
                print("[SessionDatabase] Migration failed: \(error)")
            }
        }
        // Observability: count each migration that ran in this process. Only
        // versions >= 2 are recorded because event_counters itself is created
        // by v2 — v1 baseline stamping may precede the table existing. The
        // caller (this function) lives OUTSIDE MigrationRunner so we avoid
        // the queue-reentrancy trap.
        for v in applied where v >= 2 {
            recordEvent(type: "schema.migration.applied")
            _ = v  // silence unused-variable when no >= 2 applied
        }
    }

    deinit {
        // Ensure all queued work completes before closing.
        queue.sync {
            if let db = db { sqlite3_close(db) }
        }
    }

    /// Gracefully close the database. Call from applicationWillTerminate or
    /// similar shutdown path since deinit may never fire for a singleton.
    public func close() {
        queue.sync {
            if let db = db {
                sqlite3_close(db)
            }
            self.db = nil
        }
    }

    // MARK: - WAL Mode

    /// Enable WAL journal mode for better concurrent read performance.
    /// Called once during init, before createTables.
    private func enableWAL() {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Update query planner statistics for better index selection
        sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
    }

    // MARK: - Schema

    private func createTables() {
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

        // Schema migrations — add columns that may not exist yet.
        let migrations = [
            "ALTER TABLE commands ADD COLUMN budget_decision TEXT;",
            "ALTER TABLE sessions ADD COLUMN project_root TEXT;",
            // Migration 4: agent type tracking (AXI.3)
            "ALTER TABLE sessions ADD COLUMN agent_type TEXT;",
        ]
        queue.sync {
            for sql in stmts {
                exec(sql)
            }
            // Run migrations — ALTER TABLE will fail silently if column already exists
            for migration in migrations {
                execSilent(migration)
            }
        }
    }

    // MARK: - Token Events Table

    private func createTokenEventsTable() {
        queue.sync {
            exec("""
                CREATE TABLE IF NOT EXISTS token_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    session_id TEXT NOT NULL,
                    pane_id TEXT,
                    project_root TEXT,
                    source TEXT NOT NULL,
                    tool_name TEXT,
                    model TEXT,
                    input_tokens INTEGER DEFAULT 0,
                    output_tokens INTEGER DEFAULT 0,
                    saved_tokens INTEGER DEFAULT 0,
                    cost_cents INTEGER DEFAULT 0,
                    feature TEXT,
                    command TEXT
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_pane ON token_events(pane_id);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_project ON token_events(project_root);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_events(timestamp);")
            // Migration: add model_tier column for model routing tracking
            execSilent("ALTER TABLE token_events ADD COLUMN model_tier TEXT;")
            // Indexes for session continuity queries
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_session ON token_events(session_id);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_sessions_project_ended ON sessions(project_root, ended_at);")
            // Migration 5: session cursor table for ClaudeSessionReader (AXI.3 Tier 1)
            exec("""
                CREATE TABLE IF NOT EXISTS claude_session_cursors (
                    path TEXT PRIMARY KEY,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    turn_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
            """)
            // Index for per-agent analytics
            execSilent("CREATE INDEX IF NOT EXISTS idx_sessions_agent_type ON sessions(agent_type);")
            // Composite index for hotFiles() range scan
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_project_tool_time ON token_events(project_root, tool_name, timestamp);")
        }
    }

    // MARK: - Public API

    /// Create a new session and return its ID.
    @discardableResult
    public func createSession(paneCount: Int = 0, projectRoot: String? = nil, agentType: AgentType? = nil) -> String {
        let id = UUID().uuidString
        let normalizedRoot = Self.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        return queue.sync {
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
    /// P3-13: wrapped in BEGIN IMMEDIATE / COMMIT so the INSERT into `commands` (plus
    /// the FTS5 trigger sync) and the UPDATE of `sessions` aggregates are atomic.
    /// Before this: 3 separate sqlite syncs per call, and a crash between them could
    /// leave stats out-of-sync with the command history.
    public func recordCommand(
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
        // command string before persistence. `output_preview` is already
        // filtered (built post-pipeline), but the raw command text was
        // landing unredacted — a user running
        //   senkani_exec "curl -H 'Authorization: Bearer sk-ant-…' …"
        // previously left the literal API key in `commands.command`
        // forever. SecretDetector short-circuits on no-match so the
        // benign-case cost is negligible.
        let scanResult = command.map { SecretDetector.scan($0) }
        let redactedCommand = scanResult?.redacted
        let didRedact = !(scanResult?.patterns.isEmpty ?? true)
        let preview = outputPreview.map { String($0.prefix(500)) }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }

            // Open transaction. If anything in the block fails, rollback.
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }

            let sql = """
                INSERT INTO commands (session_id, timestamp, tool_name, command, raw_bytes, compressed_bytes, feature, output_preview)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
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
            let insertRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard insertRC == SQLITE_DONE else { return }

            // Update session aggregates
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
        // Emitted outside the recordCommand queue block so it enqueues its
        // own update — keeps the commands-insert transaction minimal.
        if didRedact {
            recordEvent(type: "security.command.redacted", projectRoot: nil)
        }
    }

    /// End a session, recording its end time and duration.
    public func endSession(sessionId: String) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
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
    public func loadSessions(limit: Int = 50) -> [SessionSummaryRow] {
        return queue.sync {
            guard let db = db else { return [] }
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
    public func search(query: String, limit: Int = 50) -> [CommandSearchResult] {
        let sanitized = Self.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }

        return queue.sync {
            guard let db = db else { return [] }
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

    /// Lifetime stats across all sessions.
    public func totalStats() -> LifetimeStats {
        return queue.sync {
            guard let db = db else {
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

    // MARK: - Project Stats (for GUI live polling)

    /// Aggregate stats for a specific project root. Used by the GUI to poll metrics.
    public func statsForProject(_ projectRoot: String) -> LifetimeStats {
        return queue.sync {
            guard let db = db else {
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

    /// Aggregate stats for ALL commands in the database (for per-pane MCP sessions
    /// that don't yet have project_root tagged). Falls back to lifetime stats.
    public func recentStats(since: Date) -> LifetimeStats {
        return queue.sync {
            guard let db = db else {
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

    // MARK: - Path Normalization

    /// Normalize a project root path for consistent DB storage and querying.
    /// Resolves symlinks, removes trailing slashes, expands tildes.
    public static func normalizePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardized.path
    }

    // MARK: - Token Events API

    /// Record a token event (from MCP tool call, hook intercept, or ClaudeSessionReader).
    public func recordTokenEvent(
        sessionId: String,
        paneId: String?,
        projectRoot: String?,
        source: String,
        toolName: String?,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        costCents: Int,
        feature: String?,
        command: String?,
        modelTier: String? = nil
    ) {
        let normalizedRoot = Self.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 3, paneId)
            Self.bindOptionalText(stmt, 4, normalizedRoot)
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 6, toolName)
            Self.bindOptionalText(stmt, 7, model)
            sqlite3_bind_int64(stmt, 8, Int64(inputTokens))
            sqlite3_bind_int64(stmt, 9, Int64(outputTokens))
            sqlite3_bind_int64(stmt, 10, Int64(savedTokens))
            sqlite3_bind_int64(stmt, 11, Int64(costCents))
            Self.bindOptionalText(stmt, 12, feature)
            Self.bindOptionalText(stmt, 13, command)
            Self.bindOptionalText(stmt, 14, modelTier)

            sqlite3_step(stmt)
        }
    }

    /// Aggregate stats for a project (sidebar display). Optionally scoped to a start date.
    public func tokenStatsForProject(_ projectRoot: String, since: Date? = nil) -> PaneTokenStats {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return .zero }
            let hasSince = since != nil
            let sql = """
                SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0), COALESCE(SUM(cost_cents),0), COUNT(*)
                FROM token_events WHERE project_root = ?\(hasSince ? " AND timestamp >= ?" : "")
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            if let since {
                sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return PaneTokenStats(
                    inputTokens: Int(sqlite3_column_int64(stmt, 0)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    savedTokens: Int(sqlite3_column_int64(stmt, 2)),
                    costCents: Int(sqlite3_column_int64(stmt, 3)),
                    commandCount: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return .zero
        }
    }

    /// Aggregate stats across ALL projects (for app-level status bar).
    /// Windowed to the last 90 days to prevent full-table scans on large DBs.
    public func tokenStatsAllProjects() -> PaneTokenStats {
        return queue.sync {
            guard let db = db else { return .zero }
            let cutoff = Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970
            let sql = """
                SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0), COALESCE(SUM(cost_cents),0), COUNT(*)
                FROM token_events
                WHERE timestamp >= ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return PaneTokenStats(
                    inputTokens: Int(sqlite3_column_int64(stmt, 0)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    savedTokens: Int(sqlite3_column_int64(stmt, 2)),
                    costCents: Int(sqlite3_column_int64(stmt, 3)),
                    commandCount: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return .zero
        }
    }

    // MARK: - Feature Savings Breakdown

    /// Per-feature token savings breakdown for a project.
    public struct FeatureSavings: Sendable, Equatable {
        public let feature: String
        public let savedTokens: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let eventCount: Int

        public init(feature: String, savedTokens: Int, inputTokens: Int, outputTokens: Int, eventCount: Int) {
            self.feature = feature
            self.savedTokens = savedTokens
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.eventCount = eventCount
        }
    }

    /// Per-feature token savings breakdown, sorted by savedTokens descending.
    public func tokenStatsByFeature(projectRoot: String, since: Date? = nil) -> [FeatureSavings] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            let hasSince = since != nil
            let sql = """
                SELECT COALESCE(feature, 'unknown'),
                       COALESCE(SUM(saved_tokens), 0),
                       COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0),
                       COUNT(*)
                FROM token_events
                WHERE project_root = ?\(hasSince ? " AND timestamp >= ?" : "")
                AND saved_tokens > 0
                GROUP BY feature
                ORDER BY SUM(saved_tokens) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            if let since {
                sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            }

            var results: [FeatureSavings] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let feature = String(cString: sqlite3_column_text(stmt, 0))
                let saved = Int(sqlite3_column_int64(stmt, 1))
                let input = Int(sqlite3_column_int64(stmt, 2))
                let output = Int(sqlite3_column_int64(stmt, 3))
                let count = Int(sqlite3_column_int64(stmt, 4))
                results.append(FeatureSavings(
                    feature: feature,
                    savedTokens: saved,
                    inputTokens: input,
                    outputTokens: output,
                    eventCount: count
                ))
            }
            return results
        }
    }

    /// Overall live-session compression multiplier for a project.
    /// Returns raw / compressed = (inputTokens + savedTokens) / inputTokens.
    /// Returns nil when no matching events exist.
    public func liveSessionMultiplier(projectRoot: String, since: Date? = nil) -> Double? {
        let stats = tokenStatsByFeature(projectRoot: projectRoot, since: since)
        let totalInput = stats.reduce(0) { $0 + $1.inputTokens }
        let totalSaved = stats.reduce(0) { $0 + $1.savedTokens }
        guard totalInput > 0 else { return nil }
        return Double(totalInput + totalSaved) / Double(totalInput)
    }

    // MARK: - Analytics (Chart Data)

    /// Time-series data for the savings-over-time chart.
    /// Returns (timestamp, cumulativeRawBytes, cumulativeSavedBytes) tuples sorted by time.
    /// Survives app restart because it reads from the persistent DB.
    public func savingsTimeSeries(projectRoot: String, since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            var sql = """
                SELECT timestamp, input_tokens, saved_tokens
                FROM token_events
                WHERE project_root = ?
            """
            if since != nil { sql += " AND timestamp >= ?" }
            sql += " ORDER BY timestamp ASC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            if let since { sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970) }

            var results: [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] = []
            var cumRaw = 0
            var cumSaved = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let input = Int(sqlite3_column_int64(stmt, 1))
                let saved = Int(sqlite3_column_int64(stmt, 2))
                // raw ≈ input tokens × 4 bytes/token; saved is already in tokens
                cumRaw += input * 4
                cumSaved += saved * 4
                results.append((timestamp: ts, cumulativeRaw: cumRaw, cumulativeSaved: cumSaved))
            }
            return results
        }
    }

    /// Per-command breakdown for bar charts. Groups by command family, sums raw + compressed bytes.
    /// Reads from the commands table. Survives app restart.
    public func commandBreakdown(projectRoot: String) -> [(command: String, rawBytes: Int, compressedBytes: Int)] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            // Join to get project_root filtering via the session
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

    // MARK: - Timeline Events

    /// A single token event row from the database, with fields the timeline pane needs to render.
    public struct TimelineEvent: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let timestamp: Date
        public let source: String
        public let toolName: String?
        public let feature: String?
        public let command: String?
        public let inputTokens: Int
        public let outputTokens: Int
        public let savedTokens: Int
        public let costCents: Int

        public init(id: Int64, timestamp: Date, source: String, toolName: String?,
                    feature: String?, command: String?, inputTokens: Int,
                    outputTokens: Int, savedTokens: Int, costCents: Int) {
            self.id = id
            self.timestamp = timestamp
            self.source = source
            self.toolName = toolName
            self.feature = feature
            self.command = command
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.savedTokens = savedTokens
            self.costCents = costCents
        }
    }

    /// Fetch the most recent token events for a project, newest first.
    /// Used by the Agent Timeline pane. The `limit` bounds memory; 100 is a reasonable default.
    public func recentTokenEvents(projectRoot: String, limit: Int = 100) -> [TimelineEvent] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT id, timestamp, source, tool_name, feature, command,
                       input_tokens, output_tokens, saved_tokens, cost_cents
                FROM token_events
                WHERE project_root = ?
                ORDER BY timestamp DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            return parseTimelineRows(stmt)
        }
    }

    /// Fetch the most recent token events across ALL projects.
    /// Used when the timeline pane has no associated project.
    public func recentTokenEventsAllProjects(limit: Int = 100) -> [TimelineEvent] {
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT id, timestamp, source, tool_name, feature, command,
                       input_tokens, output_tokens, saved_tokens, cost_cents
                FROM token_events
                ORDER BY timestamp DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            return parseTimelineRows(stmt)
        }
    }

    /// Shared row parser for timeline event queries.
    private func parseTimelineRows(_ stmt: OpaquePointer?) -> [TimelineEvent] {
        var results: [TimelineEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let source = String(cString: sqlite3_column_text(stmt, 2))
            let toolName: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 3))
            let feature: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 4))
            let command: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 5))
            let input = Int(sqlite3_column_int64(stmt, 6))
            let output = Int(sqlite3_column_int64(stmt, 7))
            let saved = Int(sqlite3_column_int64(stmt, 8))
            let cost = Int(sqlite3_column_int64(stmt, 9))

            results.append(TimelineEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                source: source,
                toolName: toolName,
                feature: feature,
                command: command,
                inputTokens: input,
                outputTokens: output,
                savedTokens: saved,
                costCents: cost
            ))
        }
        return results
    }

    // MARK: - Re-Read Suppression

    /// Return the timestamp of the most recent `senkani_read` of a specific file
    /// within a project. Returns nil if the file has never been read in this session.
    /// Used by HookRouter for re-read suppression (Phase I wedge).
    public func lastReadTimestamp(filePath: String, projectRoot: String) -> Date? {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return nil }
            let sql = """
                SELECT MAX(timestamp) FROM token_events
                WHERE project_root = ? AND tool_name = 'read' AND source = 'mcp_tool'
                AND command LIKE ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            let sanitized = filePath.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "\\_")
            let pathPattern = "%" + sanitized
            sqlite3_bind_text(stmt, 2, (pathPattern as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            let ts = sqlite3_column_double(stmt, 0)
            return Date(timeIntervalSince1970: ts)
        }
    }

    /// Return the timestamp and output preview of the most recent exec of a specific command.
    /// Queries token_events for timing (has project_root) and commands for output_preview.
    /// Used by HookRouter for command replay.
    public func lastExecResult(command: String, projectRoot: String) -> (timestamp: Date, outputPreview: String?)? {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return nil }

            // Get timestamp from token_events (has project_root filter)
            let tsSql = """
                SELECT MAX(timestamp) FROM token_events
                WHERE project_root = ? AND tool_name = 'exec' AND source = 'mcp_tool'
                AND command = ?;
            """
            var tsStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, tsSql, -1, &tsStmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(tsStmt) }
            sqlite3_bind_text(tsStmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_text(tsStmt, 2, (command as NSString).utf8String, -1, nil)
            guard sqlite3_step(tsStmt) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(tsStmt, 0) != SQLITE_NULL else { return nil }
            let ts = sqlite3_column_double(tsStmt, 0)
            let timestamp = Date(timeIntervalSince1970: ts)

            // Get output_preview from commands table (closest match by command + timestamp)
            let previewSql = """
                SELECT output_preview FROM commands
                WHERE tool_name = 'exec' AND command = ?
                AND ABS(timestamp - ?) < 2.0
                ORDER BY timestamp DESC LIMIT 1;
            """
            var prevStmt: OpaquePointer?
            var preview: String?
            if sqlite3_prepare_v2(db, previewSql, -1, &prevStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(prevStmt) }
                sqlite3_bind_text(prevStmt, 1, (command as NSString).utf8String, -1, nil)
                sqlite3_bind_double(prevStmt, 2, ts)
                if sqlite3_step(prevStmt) == SQLITE_ROW && sqlite3_column_type(prevStmt, 0) != SQLITE_NULL {
                    preview = String(cString: sqlite3_column_text(prevStmt, 0))
                }
            }

            return (timestamp, preview)
        }
    }

    // MARK: - Diagnostics

    /// Dump token_events summary to console for debugging.
    /// Shows per-project row counts and totals.
    #if DEBUG
    public func dumpTokenEvents() {
        queue.sync {
            guard let db = db else {
                print("📊 [DB-DUMP] Database not open")
                return
            }
            // Total row count
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM token_events", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    print("📊 [DB-DUMP] token_events total rows: \(sqlite3_column_int64(countStmt, 0))")
                }
            }
            sqlite3_finalize(countStmt)

            // Per-project breakdown
            let sql = """
                SELECT project_root, source, COUNT(*),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0)
                FROM token_events GROUP BY project_root, source ORDER BY COUNT(*) DESC LIMIT 20
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let root = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? "NULL" : String(cString: sqlite3_column_text(stmt, 0))
                let src = String(cString: sqlite3_column_text(stmt, 1))
                let count = sqlite3_column_int64(stmt, 2)
                let inTok = sqlite3_column_int64(stmt, 3)
                let outTok = sqlite3_column_int64(stmt, 4)
                let saved = sqlite3_column_int64(stmt, 5)
                print("📊 [DB-DUMP] root=\(root) src=\(src) rows=\(count) in=\(inTok) out=\(outTok) saved=\(saved)")
            }
        }
    }
    #endif

    /// Per-feature savings across ALL projects (no project filter).
    /// Used by the Dashboard pane for portfolio-level feature breakdown.
    public func tokenStatsByFeatureAllProjects(since: Date? = nil) -> [FeatureSavings] {
        return queue.sync {
            guard let db = db else { return [] }
            var sql = """
                SELECT feature, COALESCE(SUM(saved_tokens),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COUNT(*)
                FROM token_events
                WHERE feature IS NOT NULL AND feature != ''
            """
            if since != nil { sql += " AND timestamp >= ?" }
            sql += " GROUP BY feature ORDER BY SUM(saved_tokens) DESC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var results: [FeatureSavings] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FeatureSavings(
                    feature: String(cString: sqlite3_column_text(stmt, 0)),
                    savedTokens: Int(sqlite3_column_int64(stmt, 1)),
                    inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                    eventCount: Int(sqlite3_column_int64(stmt, 4))
                ))
            }
            return results
        }
    }

    /// Time-series data across ALL projects (no project filter).
    /// Used by the Dashboard pane for the cross-project savings chart.
    public func savingsTimeSeriesAllProjects(since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        return queue.sync {
            guard let db = db else { return [] }
            var sql = """
                SELECT timestamp, input_tokens, saved_tokens
                FROM token_events
                WHERE 1=1
            """
            if since != nil { sql += " AND timestamp >= ?" }
            sql += " ORDER BY timestamp ASC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var results: [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] = []
            var cumRaw = 0
            var cumSaved = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                cumRaw += Int(sqlite3_column_int64(stmt, 1)) * 4
                cumSaved += Int(sqlite3_column_int64(stmt, 2)) * 4
                results.append((timestamp: ts, cumulativeRaw: cumRaw, cumulativeSaved: cumSaved))
            }
            return results
        }
    }

    /// Top N most-accessed file paths for a project, ranked by frequency.
    /// Used for hot file pre-caching on session start.
    public func hotFiles(projectRoot: String, limit: Int = 50, sinceDaysAgo: Int = 7) -> [(path: String, freq: Int)] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        let cutoff = Date().addingTimeInterval(-Double(sinceDaysAgo) * 86400).timeIntervalSince1970
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT command, COUNT(*) as freq
                FROM token_events
                WHERE project_root = ?
                AND timestamp >= ?
                AND command IS NOT NULL AND command != ''
                AND (tool_name IN ('read', 'outline_read', 'senkani_read') OR feature IN ('cache', 'reread_suppression'))
                GROUP BY command
                ORDER BY freq DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, cutoff)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var results: [(path: String, freq: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { continue }
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let freq = Int(sqlite3_column_int(stmt, 1))
                results.append((path: path, freq: freq))
            }
            return results
        }
    }

    /// Per-session savings summary: total raw, total saved, multiplier.
    /// Returns one entry per session, sorted newest first.
    public struct SessionSummary: Sendable {
        public let sessionId: String
        public let startedAt: Date
        public let totalRawTokens: Int
        public let totalSavedTokens: Int
        public var multiplier: Double {
            let compressed = totalRawTokens - totalSavedTokens
            return compressed > 0 ? Double(totalRawTokens) / Double(compressed) : 1.0
        }
    }

    public func sessionSummaries(projectRoot: String, limit: Int = 20) -> [SessionSummary] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT te.session_id,
                       MIN(te.timestamp) as started,
                       SUM(te.input_tokens + te.output_tokens + te.saved_tokens) as raw_total,
                       SUM(te.saved_tokens) as saved_total
                FROM token_events te
                WHERE te.project_root = ?
                AND te.source IN ('mcp_tool', 'intercept')
                GROUP BY te.session_id
                HAVING raw_total > 0
                ORDER BY started DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [SessionSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = String(cString: sqlite3_column_text(stmt, 0))
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let raw = Int(sqlite3_column_int64(stmt, 2))
                let saved = Int(sqlite3_column_int64(stmt, 3))
                results.append(SessionSummary(sessionId: sid, startedAt: ts, totalRawTokens: raw, totalSavedTokens: saved))
            }
            return results
        }
    }

    // MARK: - Session Continuity

    /// Structured data about the most recently completed session for a project.
    public struct LastSessionActivity: Sendable {
        public let sessionId: String
        public let startedAt: Date
        public let endedAt: Date
        public let durationSeconds: TimeInterval
        public let commandCount: Int
        public let totalSavedTokens: Int
        public let totalRawTokens: Int
        public let lastCommand: String?
        public let recentSearchQueries: [String]
        public let topHotFiles: [String]
    }

    /// Return structured data about the most recently completed session for a project.
    /// "Completed" = ended_at IS NOT NULL (session shut down cleanly).
    /// Returns nil if no completed sessions exist.
    public func lastSessionActivity(projectRoot: String) -> LastSessionActivity? {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return nil }

            // Query 1: Get last completed session metadata
            let sessionSql = """
                SELECT id, started_at, ended_at, duration_seconds, command_count,
                       total_saved_bytes, total_raw_bytes
                FROM sessions
                WHERE project_root = ? AND ended_at IS NOT NULL
                ORDER BY ended_at DESC
                LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sessionSql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let sid = String(cString: sqlite3_column_text(stmt, 0))
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let endedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let cmdCount = Int(sqlite3_column_int64(stmt, 4))
            let savedBytes = Int(sqlite3_column_int64(stmt, 5))
            let rawBytes = Int(sqlite3_column_int64(stmt, 6))

            // Query 2: Get recent activity from token_events for that session
            let eventSql = """
                SELECT tool_name, command
                FROM token_events
                WHERE session_id = ? AND command IS NOT NULL AND command != ''
                ORDER BY timestamp DESC
                LIMIT 20;
            """
            var eventStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, eventSql, -1, &eventStmt, nil) == SQLITE_OK else {
                return LastSessionActivity(
                    sessionId: sid, startedAt: startedAt, endedAt: endedAt,
                    durationSeconds: duration, commandCount: cmdCount,
                    totalSavedTokens: savedBytes / 4, totalRawTokens: rawBytes / 4,
                    lastCommand: nil, recentSearchQueries: [], topHotFiles: []
                )
            }
            defer { sqlite3_finalize(eventStmt) }
            sqlite3_bind_text(eventStmt, 1, (sid as NSString).utf8String, -1, nil)

            var lastCommand: String?
            var searches: [String] = []
            var readFiles: [String] = []
            var seenFiles: Set<String> = []

            while sqlite3_step(eventStmt) == SQLITE_ROW {
                let toolName = sqlite3_column_type(eventStmt, 0) != SQLITE_NULL
                    ? String(cString: sqlite3_column_text(eventStmt, 0)) : nil
                let command = String(cString: sqlite3_column_text(eventStmt, 1))

                if lastCommand == nil { lastCommand = command }

                if toolName == "search" && searches.count < 3 {
                    searches.append(command)
                }

                if (toolName == "read" || toolName == "senkani_read" || toolName == "exec") {
                    let filename = (command as NSString).lastPathComponent
                    if !filename.isEmpty && !seenFiles.contains(filename) && readFiles.count < 5 {
                        seenFiles.insert(filename)
                        readFiles.append(command)
                    }
                }
            }

            return LastSessionActivity(
                sessionId: sid, startedAt: startedAt, endedAt: endedAt,
                durationSeconds: duration, commandCount: cmdCount,
                totalSavedTokens: savedBytes / 4, totalRawTokens: rawBytes / 4,
                lastCommand: lastCommand, recentSearchQueries: searches, topHotFiles: readFiles
            )
        }
    }

    // MARK: - Agent Analytics (AXI.3)

    /// Aggregated token stats broken down by agent type.
    /// Joins token_events → sessions on session_id.
    public struct AgentStats: Sendable {
        public let agentType: AgentType
        public let sessionCount: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let savedTokens: Int
        public let costCents: Int

        public init(agentType: AgentType, sessionCount: Int, inputTokens: Int,
                    outputTokens: Int, savedTokens: Int, costCents: Int) {
            self.agentType = agentType
            self.sessionCount = sessionCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.savedTokens = savedTokens
            self.costCents = costCents
        }
    }

    /// Per-agent token savings breakdown, sorted by savedTokens descending.
    public func tokenStatsByAgent(projectRoot: String? = nil, since: Date? = nil) -> [AgentStats] {
        return queue.sync {
            guard let db = db else { return [] }
            let normalized = projectRoot.flatMap { Self.normalizePath($0) }
            var conditions = ["s.agent_type IS NOT NULL"]
            if normalized != nil { conditions.append("te.project_root = ?") }
            if since != nil { conditions.append("te.timestamp >= ?") }
            let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            let sql = """
                SELECT s.agent_type,
                       COUNT(DISTINCT te.session_id),
                       COALESCE(SUM(te.input_tokens), 0),
                       COALESCE(SUM(te.output_tokens), 0),
                       COALESCE(SUM(te.saved_tokens), 0),
                       COALESCE(SUM(te.cost_cents), 0)
                FROM token_events te
                JOIN sessions s ON te.session_id = s.id
                \(where_)
                GROUP BY s.agent_type
                ORDER BY SUM(te.saved_tokens) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var bindIdx: Int32 = 1
            if let root = normalized {
                sqlite3_bind_text(stmt, bindIdx, (root as NSString).utf8String, -1, nil)
                bindIdx += 1
            }
            if let since {
                sqlite3_bind_double(stmt, bindIdx, since.timeIntervalSince1970)
            }

            var results: [AgentStats] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawType = String(cString: sqlite3_column_text(stmt, 0))
                let agentType = AgentType(rawValue: rawType) ?? .unknownMCP
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let input = Int(sqlite3_column_int64(stmt, 2))
                let output = Int(sqlite3_column_int64(stmt, 3))
                let saved = Int(sqlite3_column_int64(stmt, 4))
                let cost = Int(sqlite3_column_int64(stmt, 5))
                results.append(AgentStats(
                    agentType: agentType, sessionCount: sessions,
                    inputTokens: input, outputTokens: output,
                    savedTokens: saved, costCents: cost
                ))
            }
            return results
        }
    }

    // MARK: - Session Cursors (ClaudeSessionReader, AXI.3 Tier 1)

    /// Return the stored (byteOffset, turnIndex) for a JSONL file path, or (0, 0) if new.
    public func getSessionCursor(path: String) -> (byteOffset: Int, turnIndex: Int) {
        return queue.sync {
            guard let db = db else { return (0, 0) }
            let sql = "SELECT byte_offset, turn_index FROM claude_session_cursors WHERE path = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
            return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
    }

    /// Persist the cursor for a JSONL file after a successful read pass.
    public func setSessionCursor(path: String, byteOffset: Int, turnIndex: Int) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO claude_session_cursors (path, byte_offset, turn_index, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    byte_offset = excluded.byte_offset,
                    turn_index  = excluded.turn_index,
                    updated_at  = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, Int64(byteOffset))
            sqlite3_bind_int64(stmt, 3, Int64(turnIndex))
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Compound Learning

    /// Row returned by the waste-analysis query.
    public struct UnfilteredCommandRow: Sendable {
        public let command: String
        public let sessionCount: Int
        public let avgInputTokens: Int
        public let avgSavedPct: Double
    }

    /// Query token_events for recurring exec commands with poor filter savings.
    /// Used by WasteAnalyzer to detect candidates for new FilterRule proposals.
    public func unfilteredExecCommands(
        projectRoot: String,
        minSessions: Int = 2,
        minInputTokens: Int = 100
    ) -> [UnfilteredCommandRow] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT command,
                       COUNT(DISTINCT session_id) AS session_count,
                       CAST(AVG(input_tokens) AS INTEGER) AS avg_input,
                       AVG(CAST(saved_tokens AS REAL) * 100.0 / NULLIF(input_tokens, 0)) AS avg_saved_pct
                FROM token_events
                WHERE tool_name = 'exec'
                  AND project_root = ?
                  AND command IS NOT NULL
                  AND command != ''
                  AND input_tokens > ?
                GROUP BY command
                HAVING avg_saved_pct < 15.0
                   AND session_count >= ?
                ORDER BY avg_input DESC
                LIMIT 20;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(minInputTokens))
            sqlite3_bind_int(stmt, 3, Int32(minSessions))

            var rows: [UnfilteredCommandRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let avgInput = Int(sqlite3_column_int64(stmt, 2))
                let avgPct = sqlite3_column_double(stmt, 3)
                rows.append(UnfilteredCommandRow(
                    command: cmd,
                    sessionCount: sessions,
                    avgInputTokens: avgInput,
                    avgSavedPct: avgPct
                ))
            }
            return rows
        }
    }

    /// Return recent `commands.output_preview` rows where the command column
    /// matches `commandPrefix` exactly OR matches the canonical
    /// `<base> <sub> …` form as a LIKE-prefix.
    ///
    /// Powers the H+1 regression gate: feeds real observed output previews
    /// into `RegressionGate.check(proposed:samples:)` so a proposed rule is
    /// validated against data that actually triggered it, not a synthetic
    /// fixture. `limit` is the sample cap per call (default 20).
    public func outputPreviewsForCommand(
        projectRoot: String?,
        commandPrefix: String,
        limit: Int = 20
    ) -> [String] {
        let likePattern = commandPrefix + "%"
        return queue.sync {
            guard let db = db else { return [] }

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
                let normalized = Self.normalizePath(root) ?? root
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

    /// H+2b — recurring file-path mentions for context-signal generation.
    /// Returns commands (typically file paths) that appeared in reads/
    /// outlines/fetches across at least `minSessions` distinct sessions.
    /// Scoped to a project root; results sorted by session count desc.
    ///
    /// Rationale: when the same file shows up across ≥3 sessions, it's
    /// load-bearing enough that the agent should be primed on it at
    /// session start. `ContextSignalGenerator` turns each row into a
    /// priming `LearnedContextDoc`.
    public struct RecurringFileRow: Sendable {
        public let path: String
        public let sessionCount: Int
        public let mentionCount: Int
    }

    public func recurringFileMentions(
        projectRoot: String,
        minSessions: Int = 3,
        limit: Int = 20
    ) -> [RecurringFileRow] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            // Tool names that conventionally use `command` as a file path.
            // Exec commands are command strings (not paths) — explicitly
            // excluded so we don't treat `git status` as a file.
            let sql = """
                SELECT command,
                       COUNT(DISTINCT session_id) AS session_count,
                       COUNT(*) AS mention_count
                FROM token_events
                WHERE tool_name IN ('read', 'outline', 'fetch', 'parse', 'validate')
                  AND project_root = ?
                  AND command IS NOT NULL
                  AND command != ''
                GROUP BY command
                HAVING session_count >= ?
                ORDER BY session_count DESC, mention_count DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(minSessions))
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var rows: [RecurringFileRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let mentions = Int(sqlite3_column_int64(stmt, 2))
                rows.append(RecurringFileRow(
                    path: cmd,
                    sessionCount: sessions,
                    mentionCount: mentions
                ))
            }
            return rows
        }
    }

    /// H+2c — commands that retried within a single session.
    /// Returns (tool_name, command, retry_count) for tool/command pairs
    /// that fired ≥ minRetries times in at least `minSessions` distinct
    /// sessions. Retry-in-session is a proxy for "the agent didn't get
    /// what it wanted the first time" — an instruction hint on that tool
    /// could disambiguate usage.
    public struct InstructionRetryRow: Sendable {
        public let toolName: String
        public let command: String
        public let sessionCount: Int
        public let avgRetries: Double
    }

    public func instructionRetryPatterns(
        projectRoot: String,
        minRetries: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [InstructionRetryRow] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            // Inner: per-session (tool, command) retry count.
            // Outer: average across sessions and filter those that retried ≥ minRetries in ≥ minSessions.
            let sql = """
                SELECT tool_name, command,
                       COUNT(DISTINCT session_id) AS session_count,
                       AVG(retries) AS avg_retries
                FROM (
                    SELECT tool_name, command, session_id, COUNT(*) AS retries
                    FROM token_events
                    WHERE project_root = ?
                      AND tool_name IS NOT NULL
                      AND command IS NOT NULL
                      AND command != ''
                    GROUP BY tool_name, command, session_id
                    HAVING retries >= ?
                ) AS per_session
                GROUP BY tool_name, command
                HAVING session_count >= ?
                ORDER BY avg_retries DESC, session_count DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(minRetries))
            sqlite3_bind_int(stmt, 3, Int32(minSessions))
            sqlite3_bind_int(stmt, 4, Int32(limit))

            var rows: [InstructionRetryRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tn = String(cString: sqlite3_column_text(stmt, 0))
                let cmd = String(cString: sqlite3_column_text(stmt, 1))
                let sessions = Int(sqlite3_column_int64(stmt, 2))
                let avg = sqlite3_column_double(stmt, 3)
                rows.append(InstructionRetryRow(
                    toolName: tn, command: cmd,
                    sessionCount: sessions, avgRetries: avg))
            }
            return rows
        }
    }

    /// H+2c — ordered tool-call pairs (A, B) where B follows A within
    /// `windowSeconds` across ≥ minSessions distinct sessions, at least
    /// `minOccurrencesPerSession` times per session. Rough sequence
    /// mining — captures the two-step pattern every successful
    /// workflow starts with.
    public struct WorkflowPairRow: Sendable {
        public let firstTool: String
        public let secondTool: String
        public let sessionCount: Int
        public let totalOccurrences: Int
    }

    public func workflowPairPatterns(
        projectRoot: String,
        windowSeconds: Double = 60.0,
        minOccurrencesPerSession: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [WorkflowPairRow] {
        let normalized = Self.normalizePath(projectRoot) ?? projectRoot
        return queue.sync {
            guard let db = db else { return [] }
            // Self-join token_events within a timestamp window, per
            // session. Group by (A, B, session), count; outer groups
            // on (A, B) across sessions.
            let sql = """
                SELECT a.tool_name AS first_tool,
                       b.tool_name AS second_tool,
                       COUNT(DISTINCT a.session_id) AS session_count,
                       COUNT(*) AS total_occ
                FROM token_events a
                INNER JOIN token_events b
                    ON a.session_id = b.session_id
                   AND b.timestamp > a.timestamp
                   AND b.timestamp - a.timestamp <= ?
                WHERE a.project_root = ?
                  AND a.tool_name IS NOT NULL
                  AND b.tool_name IS NOT NULL
                  AND a.tool_name != b.tool_name
                GROUP BY first_tool, second_tool
                HAVING session_count >= ?
                ORDER BY total_occ DESC, session_count DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, windowSeconds)
            sqlite3_bind_text(stmt, 2, (normalized as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(minSessions))
            sqlite3_bind_int(stmt, 4, Int32(limit))

            var rows: [WorkflowPairRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let a = String(cString: sqlite3_column_text(stmt, 0))
                let b_ = String(cString: sqlite3_column_text(stmt, 1))
                let sessions = Int(sqlite3_column_int64(stmt, 2))
                let occ = Int(sqlite3_column_int64(stmt, 3))
                // Filter on per-session-occurrence in Swift since
                // SQLite HAVING on the grouped count aggregates all
                // sessions together; we approximate via total_occ /
                // session_count ≥ minOccurrencesPerSession.
                let perSession = Double(occ) / max(Double(sessions), 1)
                guard perSession >= Double(minOccurrencesPerSession) else { continue }
                rows.append(WorkflowPairRow(
                    firstTool: a, secondTool: b_,
                    sessionCount: sessions, totalOccurrences: occ))
            }
            return rows
        }
    }

    /// Execute a raw SQL statement (for testing only — e.g., backdating timestamps).
    public func executeRawSQL(_ sql: String) {
        queue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // MARK: - Budget Queries

    /// Total cost_saved_cents for sessions started today (UTC).
    public func costForToday() -> Int {
        return queue.sync {
            guard let db = db else { return 0 }
            // Sessions started on the current UTC date
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
    public func costForWeek() -> Int {
        return queue.sync {
            guard let db = db else { return 0 }
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
    /// Called after budget check to log allow/warn/block decisions.
    public func recordBudgetDecision(
        sessionId: String,
        toolName: String,
        decision: String,
        rawBytes: Int = 0,
        compressedBytes: Int = 0
    ) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO commands (session_id, timestamp, tool_name, raw_bytes, compressed_bytes, budget_decision)
                VALUES (?, ?, ?, ?, ?, ?);
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
            sqlite3_step(stmt)
        }
    }

    // MARK: - Hook Event Recording

    /// Record a hook event from the senkani-hook binary.
    /// Stores tool_name, event_type (PreToolUse/PostToolUse), and project_root.
    public func recordHookEvent(
        sessionId: String,
        toolName: String,
        eventType: String,
        projectRoot: String?
    ) {
        let normalizedRoot = Self.normalizePath(projectRoot)
        recordTokenEvent(
            sessionId: sessionId,
            paneId: nil,
            projectRoot: normalizedRoot,
            source: "hook",
            toolName: toolName,
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0,
            feature: eventType,
            command: nil
        )
    }

    // MARK: - Compliance Rate

    /// Calculate hook compliance rate: percentage of tool calls that went through
    /// senkani (either MCP tools or hook events) vs total tool calls.
    /// Returns a value between 0.0 and 1.0, or nil if no data.
    public func complianceRate(projectRoot: String? = nil, since: Date? = nil) -> Double? {
        return queue.sync {
            guard let db = db else { return nil }

            var conditions: [String] = []
            var bindValues: [(Int32, Any)] = []
            var bindIndex: Int32 = 1

            if let root = Self.normalizePath(projectRoot) {
                conditions.append("project_root = ?")
                bindValues.append((bindIndex, root))
                bindIndex += 1
            }
            if let since {
                conditions.append("timestamp >= ?")
                bindValues.append((bindIndex, since.timeIntervalSince1970))
                bindIndex += 1
            }

            let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")

            // Total events
            let totalSQL = "SELECT COUNT(*) FROM token_events" + whereClause
            var totalStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, totalSQL, -1, &totalStmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(totalStmt) }
            for (idx, val) in bindValues {
                if let s = val as? String {
                    sqlite3_bind_text(totalStmt, idx, (s as NSString).utf8String, -1, nil)
                } else if let d = val as? Double {
                    sqlite3_bind_double(totalStmt, idx, d)
                }
            }
            guard sqlite3_step(totalStmt) == SQLITE_ROW else { return nil }
            let total = sqlite3_column_int64(totalStmt, 0)
            guard total > 0 else { return nil }

            // Senkani events (source = 'mcp' or source = 'hook')
            let senkaniSQL = "SELECT COUNT(*) FROM token_events" + whereClause
                + (conditions.isEmpty ? " WHERE " : " AND ")
                + "(source = 'mcp' OR source = 'hook')"
            var senkaniStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, senkaniSQL, -1, &senkaniStmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(senkaniStmt) }
            for (idx, val) in bindValues {
                if let s = val as? String {
                    sqlite3_bind_text(senkaniStmt, idx, (s as NSString).utf8String, -1, nil)
                } else if let d = val as? Double {
                    sqlite3_bind_double(senkaniStmt, idx, d)
                }
            }
            guard sqlite3_step(senkaniStmt) == SQLITE_ROW else { return nil }
            let senkani = sqlite3_column_int64(senkaniStmt, 0)

            return Double(senkani) / Double(total)
        }
    }

    // MARK: - Sandboxed Results Table

    private func createSandboxedResultsTable() {
        queue.sync {
            exec("""
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
            execSilent("CREATE INDEX IF NOT EXISTS idx_sandboxed_results_session ON sandboxed_results(session_id);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_sandboxed_results_time ON sandboxed_results(created_at);")
        }
    }

    // MARK: - Sandboxed Results API

    /// Store a large command output and return a retrieve ID.
    /// The ID uses a `r_` prefix + 12-char UUID segment for compactness.
    public func storeSandboxedResult(sessionId: String, command: String, output: String) -> String {
        let resultId = "r_" + UUID().uuidString.prefix(12).lowercased()
        let now = Date().timeIntervalSince1970
        let lineCount = output.components(separatedBy: "\n").count
        let byteCount = output.utf8.count

        queue.sync {
            guard let db = db else { return }
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
    public func retrieveSandboxedResult(resultId: String) -> (command: String, output: String, lineCount: Int, byteCount: Int)? {
        return queue.sync {
            guard let db = db else { return nil }
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
    /// Call on session startup to prevent unbounded growth.
    @discardableResult
    public func pruneSandboxedResults(olderThan interval: TimeInterval = 86400) -> Int {
        let cutoff = Date().timeIntervalSince1970 - interval
        return queue.sync {
            guard let db = db else { return 0 }
            let sql = "DELETE FROM sandboxed_results WHERE created_at < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - FTS5 Query Sanitization

    /// SECURITY: Sanitize user input for FTS5 MATCH queries.
    /// Strips FTS5 operators (OR, AND, NOT, NEAR, column filters, prefix *)
    /// and wraps each term in double-quotes to prevent query injection.
    /// Empty or all-whitespace input returns empty string (caller should skip query).
    static func sanitizeFTS5Query(_ raw: String) -> String {
        // Strip characters that have special meaning in FTS5 query syntax
        let stripped = raw.unicodeScalars.filter { scalar in
            // Allow alphanumerics, spaces, and basic punctuation (dash, underscore, dot)
            // Reject: " * ^ ~ ( ) { } : + | \ and control chars
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == " " || scalar == "-" || scalar == "_" || scalar == "."
        }
        let cleaned = String(stripped)

        // Split into terms, remove FTS5 keywords, quote each term
        let ftsKeywords: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let terms = cleaned.split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty && !ftsKeywords.contains($0.uppercased()) }

        guard !terms.isEmpty else { return "" }

        // Each term wrapped in double-quotes prevents operator interpretation
        // Double-quotes inside terms are already stripped above
        return terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    // MARK: - Validation Results Table

    private func createValidationResultsTable() {
        queue.sync {
            exec("""
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
            execSilent("CREATE INDEX IF NOT EXISTS idx_validation_session_delivered ON validation_results(session_id, delivered);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_validation_file ON validation_results(file_path);")
        }
    }

    // MARK: - Validation Results API

    /// A stored validation result row.
    public struct ValidationResultRow: Sendable {
        public let id: Int64
        public let filePath: String
        public let validatorName: String
        public let category: String
        public let exitCode: Int32
        public let advisory: String
        public let durationMs: Int
        public let createdAt: Date
    }

    /// Store a validation result from auto-validate.
    public func insertValidationResult(
        sessionId: String,
        filePath: String,
        validatorName: String,
        category: String,
        exitCode: Int32,
        rawOutput: String?,
        advisory: String,
        durationMs: Int
    ) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO validation_results
                (session_id, file_path, validator_name, category, exit_code, raw_output, advisory, duration_ms, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
            sqlite3_step(stmt)
        }
    }

    /// Fetch undelivered validation results with errors for a session.
    /// Atomically marks them as delivered to prevent repeat advisories.
    public func fetchAndMarkDelivered(sessionId: String) -> [ValidationResultRow] {
        return queue.sync {
            guard let db = db else { return [] }

            // SELECT undelivered errors
            let selectSql = """
                SELECT id, file_path, validator_name, category, exit_code, advisory, duration_ms, created_at
                FROM validation_results
                WHERE session_id = ? AND delivered = 0 AND exit_code != 0
                ORDER BY created_at DESC
                LIMIT 10;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

            var results: [ValidationResultRow] = []
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                ids.append(id)
                results.append(ValidationResultRow(
                    id: id,
                    filePath: String(cString: sqlite3_column_text(stmt, 1)),
                    validatorName: String(cString: sqlite3_column_text(stmt, 2)),
                    category: String(cString: sqlite3_column_text(stmt, 3)),
                    exitCode: sqlite3_column_int(stmt, 4),
                    advisory: String(cString: sqlite3_column_text(stmt, 5)),
                    durationMs: Int(sqlite3_column_int(stmt, 6)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                ))
            }

            // Mark as delivered atomically (same queue.sync block)
            if !ids.isEmpty {
                let idList = ids.map(String.init).joined(separator: ",")
                exec("UPDATE validation_results SET delivered = 1 WHERE id IN (\(idList));")
            }

            return results
        }
    }

    /// Prune old validation results.
    @discardableResult
    public func pruneValidationResults(olderThanHours: Int = 24) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(olderThanHours) * 3600).timeIntervalSince1970
        return queue.sync {
            guard let db = db else { return 0 }
            let sql = "DELETE FROM validation_results WHERE created_at < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    /// Prune token_events older than N days (default: 90) to prevent unbounded growth.
    /// The index on (project_root, tool_name, timestamp) makes the WHERE clause efficient.
    @discardableResult
    public func pruneTokenEvents(olderThanDays: Int = 90) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400).timeIntervalSince1970
        return queue.sync {
            guard let db = db else { return 0 }
            let sql = "DELETE FROM token_events WHERE timestamp < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Helpers

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) {
        guard let db = db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            print("[SessionDatabase] SQL error: \(msg)")
            sqlite3_free(err)
        }
    }

    /// Execute SQL silently — used for migrations where failure (e.g. column already exists) is expected.
    private func execSilent(_ sql: String) {
        guard let db = db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}

/// Row type returned by loadSessions — mirrors SessionSummaryRecord's public shape.
public struct SessionSummaryRow: Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let totalRaw: Int
    public let totalSaved: Int
    public let commandCount: Int
    public let paneCount: Int
    public let costSavedCents: Int

    public var savingsPercent: Double {
        guard totalRaw > 0 else { return 0 }
        return Double(totalSaved) / Double(totalRaw) * 100
    }

    public var formattedSavings: String {
        if totalSaved >= 1_000_000 { return String(format: "%.1fM", Double(totalSaved) / 1_000_000) }
        if totalSaved >= 1_000 { return String(format: "%.1fK", Double(totalSaved) / 1_000) }
        return "\(totalSaved)B"
    }

    public var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    public var estimatedCostSaved: Double {
        ModelPricing.costSaved(bytes: totalSaved)
    }
}
