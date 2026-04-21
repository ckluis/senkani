import Foundation
import SQLite3

// MARK: - Split plan (Luminary P2-11, in progress)
//
// This file is the single façade for everything in the session SQLite DB.
// Real tables (as of 2026-04-20): sessions, commands, commands_fts (FTS5),
// token_events, claude_session_cursors, sandboxed_results, validation_results,
// event_counters, schema_migrations.
//
// NOTE: a prior version of this comment listed `hook_events` as a seventh
// table. That was wrong — `recordHookEvent` writes into `token_events` with
// `source='hook'`; there is no separate table. Corrected 2026-04-20 under
// sessiondb-split-1-hookeventstore (skipped; see that item's notes).
//
// Gate (all three required before splitting):
//   1. Wave 2 migration system landed.               ✅ 2026-04-15
//   2. A second contributor needs to touch the DB layer. (gate lifted
//      2026-04-20 by operator — split rounds now run autonomously.)
//   3. Bounded contexts clarified by a concrete feature ask.
//
// Target carve-up (Evans / Kleppmann): each store owns its own transaction
// boundary and is reachable from Core only through this file.
//
//   CommandStore       ✅ extracted 2026-04-20 (sessiondb-split-2).
//                        Lives at Sources/Core/Stores/CommandStore.swift.
//                        Owns sessions + commands + commands_fts + triggers
//                        + the BEGIN IMMEDIATE transaction boundary around
//                        the FTS5 sync. Extraction validates the pattern
//                        for the remaining three stores (token events,
//                        sandbox, validation).
//   TokenEventStore    ✅ extracted 2026-04-21 (sessiondb-split-3).
//                        Lives at Sources/Core/Stores/TokenEventStore.swift.
//                        Owns token_events + claude_session_cursors +
//                        tokenStats*/savingsTimeSeries*/recentTokenEvents*
//                        /hotFiles/liveSessionMultiplier, the
//                        recordTokenEvent + recordHookEvent write sites
//                        (hook rows live in token_events with source='hook',
//                        not a separate table), the cursor get/set pair,
//                        and the 90-day `pruneTokenEvents` cadence.
//                        Cross-store JOINs across token_events ↔ sessions
//                        (`tokenStatsByAgent`, `lastSessionActivity`,
//                        `lastExecResult`) and `complianceRate` stay on
//                        this façade as composition per the split's scope.
//   SandboxStore       ✅ extracted 2026-04-21 (sessiondb-split-4).
//                        Lives at Sources/Core/Stores/SandboxStore.swift.
//                        Owns sandboxed_results (schema + two indexes) and
//                        the store/retrieve/prune API. 24-h prune cadence
//                        is driven by RetentionScheduler (same helper that
//                        owns the 90-day token_events cadence and will
//                        shortly own the 24-h validation_results cadence).
//   ValidationStore    — validation_results + AutoValidate integration.
//
// What stays on `SessionDatabase`:
//   - The `Connection`/`DatabaseQueue` lifecycle.
//   - `MigrationRunner` invocation (flock + kill-switch).
//   - Cross-store aggregates that today exist as SQL JOINs
//     (`lifetimeStats`, `tokenStatsForProject` joining sessions ↔ events,
//     `complianceRate` counting `source IN ('mcp','hook')` against total).
//     These become thin façade methods that call the stores and compose.
//
// What deliberately does NOT move (Torvalds):
//   - `event_counters` (`recordEvent`/`eventCounts`) — trivial table, moving
//     it would mean every defense site imports a new store just to bump a
//     counter. Keep on the façade.
//   - `schema_migrations` read/write — owned by the migration runner.
//
// When you do split, land it in four commits so reverts stay scoped:
//   1. Extract `CommandStore` (biggest, lowest cross-table coupling).
//   2. Extract `TokenEventStore` (depends on session id but not command id;
//      owns recordHookEvent because hook rows live in token_events).
//   3. Extract `SandboxStore`.
//   4. Extract `ValidationStore` (can share a RetentionScheduler with
//      SandboxStore if one falls out naturally).
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

    // `internal` (not `private`) so that extracted stores living under
    // `Sources/Core/Stores/` can share the connection + queue without opening
    // a second handle. External callers still go through the public API —
    // Core is not a place to reach into the raw SQLite pointer.
    internal var db: OpaquePointer?
    internal let queue = DispatchQueue(label: "com.senkani.sessiondb", qos: .utility)

    // Extracted stores. Each owns its tables end-to-end and shares the
    // parent's connection/queue.
    private var commandStore: CommandStore!
    private var tokenEventStore: TokenEventStore!
    private var sandboxStore: SandboxStore!

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
        commandStore = CommandStore(parent: self)
        commandStore.setupSchema()
        tokenEventStore = TokenEventStore(parent: self)
        tokenEventStore.setupSchema()
        sandboxStore = SandboxStore(parent: self)
        sandboxStore.setupSchema()
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
        commandStore = CommandStore(parent: self)
        commandStore.setupSchema()
        tokenEventStore = TokenEventStore(parent: self)
        tokenEventStore.setupSchema()
        sandboxStore = SandboxStore(parent: self)
        sandboxStore.setupSchema()
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
    //
    // Sessions / commands / commands_fts schema lives in CommandStore.setupSchema()
    // — called from init after the connection is open. See
    // Sources/Core/Stores/CommandStore.swift.

    // Token Events + claude_session_cursors schema lives in
    // TokenEventStore.setupSchema() — called from init. See
    // Sources/Core/Stores/TokenEventStore.swift.

    // MARK: - Public API (delegated to CommandStore)

    /// Create a new session and return its ID.
    @discardableResult
    public func createSession(paneCount: Int = 0, projectRoot: String? = nil, agentType: AgentType? = nil) -> String {
        return commandStore.createSession(paneCount: paneCount, projectRoot: projectRoot, agentType: agentType)
    }

    /// Record a single command within a session.
    ///
    /// P3-13: wrapped in BEGIN IMMEDIATE / COMMIT inside CommandStore so the INSERT
    /// into `commands` (plus the FTS5 trigger sync) and the UPDATE of `sessions`
    /// aggregates are atomic.
    public func recordCommand(
        sessionId: String,
        toolName: String,
        command: String?,
        rawBytes: Int,
        compressedBytes: Int,
        feature: String? = nil,
        outputPreview: String? = nil
    ) {
        commandStore.recordCommand(
            sessionId: sessionId,
            toolName: toolName,
            command: command,
            rawBytes: rawBytes,
            compressedBytes: compressedBytes,
            feature: feature,
            outputPreview: outputPreview
        )
    }

    /// End a session, recording its end time and duration.
    public func endSession(sessionId: String) {
        commandStore.endSession(sessionId: sessionId)
    }

    /// Load recent session summaries.
    /// SECURITY: Limit parameter is capped at 500 to prevent resource exhaustion.
    public func loadSessions(limit: Int = 50) -> [SessionSummaryRow] {
        return commandStore.loadSessions(limit: limit)
    }

    /// Full-text search across commands.
    /// SECURITY: The query is sanitized for FTS5 — special operators are stripped
    /// and terms are quoted to prevent FTS5 query injection.
    public func search(query: String, limit: Int = 50) -> [CommandSearchResult] {
        return commandStore.search(query: query, limit: limit)
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

    // MARK: - Token Events API (delegated to TokenEventStore)

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
        tokenEventStore.recordTokenEvent(
            sessionId: sessionId, paneId: paneId, projectRoot: projectRoot,
            source: source, toolName: toolName, model: model,
            inputTokens: inputTokens, outputTokens: outputTokens,
            savedTokens: savedTokens, costCents: costCents,
            feature: feature, command: command, modelTier: modelTier
        )
    }

    /// Aggregate stats for a project (sidebar display). Optionally scoped to a start date.
    public func tokenStatsForProject(_ projectRoot: String, since: Date? = nil) -> PaneTokenStats {
        return tokenEventStore.tokenStatsForProject(projectRoot, since: since)
    }

    /// Aggregate stats across ALL projects (for app-level status bar).
    /// Windowed to the last 90 days to prevent full-table scans on large DBs.
    public func tokenStatsAllProjects() -> PaneTokenStats {
        return tokenEventStore.tokenStatsAllProjects()
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
        return tokenEventStore.tokenStatsByFeature(projectRoot: projectRoot, since: since)
    }

    /// Overall live-session compression multiplier for a project.
    /// Returns raw / compressed = (inputTokens + savedTokens) / inputTokens.
    /// Returns nil when no matching events exist.
    public func liveSessionMultiplier(projectRoot: String, since: Date? = nil) -> Double? {
        return tokenEventStore.liveSessionMultiplier(projectRoot: projectRoot, since: since)
    }

    // MARK: - Analytics (Chart Data)

    /// Time-series data for the savings-over-time chart.
    /// Returns (timestamp, cumulativeRawBytes, cumulativeSavedBytes) tuples sorted by time.
    public func savingsTimeSeries(projectRoot: String, since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        return tokenEventStore.savingsTimeSeries(projectRoot: projectRoot, since: since)
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
        return tokenEventStore.recentTokenEvents(projectRoot: projectRoot, limit: limit)
    }

    /// Fetch the most recent token events across ALL projects.
    /// Used when the timeline pane has no associated project.
    public func recentTokenEventsAllProjects(limit: Int = 100) -> [TimelineEvent] {
        return tokenEventStore.recentTokenEventsAllProjects(limit: limit)
    }

    // MARK: - Re-Read Suppression

    /// Return the timestamp of the most recent `senkani_read` of a specific file
    /// within a project. Returns nil if the file has never been read in this session.
    /// Used by HookRouter for re-read suppression (Phase I wedge).
    public func lastReadTimestamp(filePath: String, projectRoot: String) -> Date? {
        return tokenEventStore.lastReadTimestamp(filePath: filePath, projectRoot: projectRoot)
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

    #if DEBUG
    /// Dump token_events summary to console for debugging.
    public func dumpTokenEvents() {
        tokenEventStore.dumpTokenEvents()
    }
    #endif

    /// Per-feature savings across ALL projects (no project filter).
    /// Used by the Dashboard pane for portfolio-level feature breakdown.
    public func tokenStatsByFeatureAllProjects(since: Date? = nil) -> [FeatureSavings] {
        return tokenEventStore.tokenStatsByFeatureAllProjects(since: since)
    }

    /// Time-series data across ALL projects (no project filter).
    /// Used by the Dashboard pane for the cross-project savings chart.
    public func savingsTimeSeriesAllProjects(since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        return tokenEventStore.savingsTimeSeriesAllProjects(since: since)
    }

    /// Top N most-accessed file paths for a project, ranked by frequency.
    /// Used for hot file pre-caching on session start.
    public func hotFiles(projectRoot: String, limit: Int = 50, sinceDaysAgo: Int = 7) -> [(path: String, freq: Int)] {
        return tokenEventStore.hotFiles(projectRoot: projectRoot, limit: limit, sinceDaysAgo: sinceDaysAgo)
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
        return tokenEventStore.sessionSummaries(projectRoot: projectRoot, limit: limit)
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
        return tokenEventStore.getSessionCursor(path: path)
    }

    /// Persist the cursor for a JSONL file after a successful read pass.
    public func setSessionCursor(path: String, byteOffset: Int, turnIndex: Int) {
        tokenEventStore.setSessionCursor(path: path, byteOffset: byteOffset, turnIndex: turnIndex)
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
        return tokenEventStore.unfilteredExecCommands(
            projectRoot: projectRoot,
            minSessions: minSessions,
            minInputTokens: minInputTokens
        )
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
        return tokenEventStore.recurringFileMentions(
            projectRoot: projectRoot,
            minSessions: minSessions,
            limit: limit
        )
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
        return tokenEventStore.instructionRetryPatterns(
            projectRoot: projectRoot,
            minRetries: minRetries,
            minSessions: minSessions,
            limit: limit
        )
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
        return tokenEventStore.workflowPairPatterns(
            projectRoot: projectRoot,
            windowSeconds: windowSeconds,
            minOccurrencesPerSession: minOccurrencesPerSession,
            minSessions: minSessions,
            limit: limit
        )
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
        tokenEventStore.recordHookEvent(
            sessionId: sessionId,
            toolName: toolName,
            eventType: eventType,
            projectRoot: projectRoot
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

    // Sandboxed Results schema lives in SandboxStore.setupSchema() — called
    // from init. See Sources/Core/Stores/SandboxStore.swift.

    // MARK: - Sandboxed Results API (delegated to SandboxStore)

    /// Store a large command output and return a retrieve ID.
    /// The ID uses a `r_` prefix + 12-char UUID segment for compactness.
    public func storeSandboxedResult(sessionId: String, command: String, output: String) -> String {
        return sandboxStore.storeSandboxedResult(sessionId: sessionId, command: command, output: output)
    }

    /// Retrieve a sandboxed result by its ID.
    /// Returns nil if not found (expired or invalid ID).
    public func retrieveSandboxedResult(resultId: String) -> (command: String, output: String, lineCount: Int, byteCount: Int)? {
        return sandboxStore.retrieveSandboxedResult(resultId: resultId)
    }

    /// Delete sandboxed results older than a given interval (default: 24 hours).
    /// Called from `RetentionScheduler.tick` and from session startup.
    @discardableResult
    public func pruneSandboxedResults(olderThan interval: TimeInterval = 86400) -> Int {
        return sandboxStore.pruneSandboxedResults(olderThan: interval)
    }

    // MARK: - FTS5 Query Sanitization

    /// SECURITY: Sanitize user input for FTS5 MATCH queries. Implementation
    /// lives in CommandStore (owner of the commands_fts surface); kept here as
    /// a static for the SearchSecurity / KnowledgeStore callsites that already
    /// reference `SessionDatabase.sanitizeFTS5Query`.
    static func sanitizeFTS5Query(_ raw: String) -> String {
        return CommandStore.sanitizeFTS5Query(raw)
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
    @discardableResult
    public func pruneTokenEvents(olderThanDays: Int = 90) -> Int {
        return tokenEventStore.pruneTokenEvents(olderThanDays: olderThanDays)
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
