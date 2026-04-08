import Foundation
import SQLite3

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
public struct PaneTokenStats: Sendable {
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
        }
    }

    // MARK: - Public API

    /// Create a new session and return its ID.
    @discardableResult
    public func createSession(paneCount: Int = 0, projectRoot: String? = nil) -> String {
        let id = UUID().uuidString
        let normalizedRoot = Self.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        return queue.sync {
            let sql = "INSERT INTO sessions (id, started_at, pane_count, project_root) VALUES (?, ?, ?, ?);"
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
            sqlite3_step(stmt)
            return id
        }
    }

    /// Record a single command within a session.
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
        let preview = outputPreview.map { String($0.prefix(500)) }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }

            let sql = """
                INSERT INTO commands (session_id, timestamp, tool_name, command, raw_bytes, compressed_bytes, feature, output_preview)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, (toolName as NSString).utf8String, -1, nil)
            if let cmd = command {
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
            sqlite3_step(stmt)

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
            defer { sqlite3_finalize(updateStmt) }
            let saved = rawBytes - compressedBytes
            let costCents = ModelPricing.costSavedCents(bytes: saved)
            sqlite3_bind_int64(updateStmt, 1, Int64(rawBytes))
            sqlite3_bind_int64(updateStmt, 2, Int64(saved))
            sqlite3_bind_int(updateStmt, 3, Int32(costCents))
            sqlite3_bind_text(updateStmt, 4, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(updateStmt)
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

    /// Record a token event (from MCP tool call or Claude session watcher).
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
        command: String?
    ) {
        let normalizedRoot = Self.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

            sqlite3_step(stmt)
        }
    }

    /// Aggregate stats for a single pane (footer display).
    public func statsForPane(_ paneId: String) -> PaneTokenStats {
        return queue.sync {
            guard let db = db else { return .zero }
            let sql = """
                SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0), COALESCE(SUM(cost_cents),0), COUNT(*)
                FROM token_events WHERE pane_id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (paneId as NSString).utf8String, -1, nil)

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
    public func tokenStatsAllProjects() -> PaneTokenStats {
        return queue.sync {
            guard let db = db else { return .zero }
            let sql = """
                SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0), COALESCE(SUM(cost_cents),0), COUNT(*)
                FROM token_events
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            defer { sqlite3_finalize(stmt) }

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
