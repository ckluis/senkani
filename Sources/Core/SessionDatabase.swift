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
        queue.sync {
            for sql in stmts {
                exec(sql)
            }
        }
    }

    // MARK: - Public API

    /// Create a new session and return its ID.
    @discardableResult
    public func createSession(paneCount: Int = 0) -> String {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        return queue.sync {
            let sql = "INSERT INTO sessions (id, started_at, pane_count) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_int(stmt, 3, Int32(paneCount))
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
            let costCents = Int(Double(saved) / 4.0 / 1_000_000 * 300)  // cents at $3/M tokens
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

    private func exec(_ sql: String) {
        guard let db = db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            print("[SessionDatabase] SQL error: \(msg)")
            sqlite3_free(err)
        }
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
        let tokens = Double(totalSaved) / 4.0
        return (tokens / 1_000_000) * 3.0
    }
}
