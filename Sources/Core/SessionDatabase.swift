import Foundation
import SQLite3

// MARK: - Split history (Luminary P2-11, closed 2026-04-24)
//
// `SessionDatabase` is now the compatibility façade for the session SQLite DB.
// Table-owned behavior lives in focused stores that share this connection and
// queue; callers keep the stable `SessionDatabase.shared` API through extension
// files next to this one.
//
//   CommandStore       ✅ extracted 2026-04-20 (sessiondb-split-2)
//                        sessions + commands + commands_fts + FTS triggers.
//   TokenEventStore    ✅ extracted 2026-04-21 (sessiondb-split-3)
//                        token_events + claude_session_cursors.
//   SandboxStore       ✅ extracted 2026-04-21 (sessiondb-split-4)
//                        sandboxed_results lifecycle.
//   ValidationStore    ✅ extracted 2026-04-24 (sessiondb-split-5)
//                        validation_results lifecycle.
//
// What stays in this file:
//   - Connection / DatabaseQueue lifecycle.
//   - MigrationRunner invocation and schema-version diagnostics.
//   - `event_counters`, deliberately retained on the façade because every
//     defense site should not need a tiny extra store just to bump a counter.
//   - Cross-store composition SQL that joins or compares data owned by more
//     than one store (`lastExecResult`, `lastSessionActivity`,
//     `tokenStatsByAgent`) plus `complianceRate`, which remains the explicit
//     hook/MCP observability aggregate called out by the split plan.

/// Thread-safe SQLite+FTS5 session persistence layer.
/// Replaces the JSON-file approach with a proper database at
/// ~/Library/Application Support/Senkani/senkani.db
public final class SessionDatabase: @unchecked Sendable {
    public static let shared = SessionDatabase()

    // `internal` (not `private`) so that extracted stores living under
    // `Sources/Core/Stores/` can share the connection + queue without opening
    // a second handle. External callers still go through the public API —
    // Core is not a place to reach into the raw SQLite pointer.
    internal var db: OpaquePointer?
    internal let queue = DispatchQueue(label: "com.senkani.sessiondb", qos: .utility)

    // Extracted stores. Each owns its tables end-to-end and shares the
    // parent's connection/queue.
    internal var commandStore: CommandStore!
    internal var tokenEventStore: TokenEventStore!
    internal var sandboxStore: SandboxStore!
    internal var validationStore: ValidationStore!
    internal var paneRefreshStateStore: PaneRefreshStateStore!
    internal var agentTraceEventStore: AgentTraceEventStore!
    internal var annotationStore: AnnotationStore!
    internal var confirmationStore: ConfirmationStore!
    internal var trustAuditStore: TrustAuditStore!

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
            Logger.log("db.session.open_failed", fields: [
                "mode": .string("default"),
                "path": .path(dbPath),
                "error": .string(err),
                "outcome": .string("error"),
            ])
            db = nil
        }
        enableWAL()
        commandStore = CommandStore(parent: self)
        commandStore.setupSchema()
        tokenEventStore = TokenEventStore(parent: self)
        tokenEventStore.setupSchema()
        sandboxStore = SandboxStore(parent: self)
        sandboxStore.setupSchema()
        validationStore = ValidationStore(parent: self)
        validationStore.setupSchema()
        paneRefreshStateStore = PaneRefreshStateStore(parent: self)
        paneRefreshStateStore.setupSchema()
        agentTraceEventStore = AgentTraceEventStore(parent: self)
        agentTraceEventStore.setupSchema()
        annotationStore = AnnotationStore(parent: self)
        annotationStore.setupSchema()
        confirmationStore = ConfirmationStore(parent: self)
        confirmationStore.setupSchema()
        trustAuditStore = TrustAuditStore(parent: self)
        trustAuditStore.setupSchema()
        runMigrations(path: dbPath)
    }

    /// Testable initializer — opens a DB at a custom path (use a temp file).
    public init(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if sqlite3_open(path, &db) != SQLITE_OK {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            Logger.log("db.session.open_failed", fields: [
                "mode": .string("test"),
                "path": .path(path),
                "error": .string(err),
                "outcome": .string("error"),
            ])
            db = nil
        }
        enableWAL()
        commandStore = CommandStore(parent: self)
        commandStore.setupSchema()
        tokenEventStore = TokenEventStore(parent: self)
        tokenEventStore.setupSchema()
        sandboxStore = SandboxStore(parent: self)
        sandboxStore.setupSchema()
        validationStore = ValidationStore(parent: self)
        validationStore.setupSchema()
        paneRefreshStateStore = PaneRefreshStateStore(parent: self)
        paneRefreshStateStore.setupSchema()
        agentTraceEventStore = AgentTraceEventStore(parent: self)
        agentTraceEventStore.setupSchema()
        annotationStore = AnnotationStore(parent: self)
        annotationStore.setupSchema()
        confirmationStore = ConfirmationStore(parent: self)
        confirmationStore.setupSchema()
        trustAuditStore = TrustAuditStore(parent: self)
        trustAuditStore.setupSchema()
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
                    Logger.log("db.session.migrations_applied", fields: [
                        "versions": .string(applied.map(String.init).joined(separator: ",")),
                        "count": .int(applied.count),
                        "path": .path(path),
                        "outcome": .string("success"),
                    ])
                }
            } catch let e as MigrationError {
                Logger.log("db.session.migration_failed", fields: [
                    "error": .string(e.description),
                    "outcome": .string("error"),
                ])
            } catch {
                Logger.log("db.session.migration_failed", fields: [
                    "error": .string("\(error)"),
                    "outcome": .string("error"),
                ])
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

    // MARK: - Schema Ownership
    //
    // Store-owned schemas are created by CommandStore, TokenEventStore,
    // SandboxStore, and ValidationStore during init. This façade retains only
    // `event_counters` and migration/version orchestration.

    // MARK: - Path Normalization

    /// Normalize a project root path for consistent DB storage and querying.
    /// Removes trailing slashes, resolves dot components, expands tildes.
    ///
    /// Tilde expansion is done explicitly via `NSString.expandingTildeInPath`
    /// before URL standardization. Apple's docs warn against passing tilde
    /// paths to `URL(fileURLWithPath:)` directly — historical Foundation
    /// versions silently expanded `~`, but recent ones (Swift 6.3 on macOS 15
    /// observed 2026-04-26 in CI) treat it as a literal directory name.
    /// Explicit expansion keeps the result identical across OS / Swift versions.
    public static func normalizePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardized.path
    }

    // MARK: - Cross-Store Composition

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

    // MARK: - Test/Support Hooks

    /// Test/support seam: waits until all prior async DB writes on the serial
    /// queue have completed.
    public func flushWrites() {
        queue.sync { }
    }
}
