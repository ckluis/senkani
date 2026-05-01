import Foundation
import SQLite3

/// Owns `token_events` + `claude_session_cursors` end-to-end — schema,
/// writes, analytics reads, cursor upserts, and the 90-day prune.
/// Extracted from `SessionDatabase` under
/// `sessiondb-split-3-tokeneventstore` (Luminary P2-11, round 3 of 5).
/// Shares the parent's connection + dispatch queue; never opens a
/// new SQLite handle.
///
/// Cross-store composition (JOIN across token_events ↔ sessions —
/// `tokenStatsByAgent`, `lastSessionActivity`, `lastExecResult`) and
/// `complianceRate` deliberately stay on the `SessionDatabase` façade
/// per the round's scope. Every other `token_events`-only method is
/// here and forwarded.
final class TokenEventStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    // T.5 round 2 — tamper-evident audit chain. ChainState owns the per-
    // table anchor lookup + last-hash cache; round 3 generalized it so all
    // four chain participants share the same primitive.
    private let chain = ChainState(table: "token_events")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller must
    /// be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Schema

    /// Create the `token_events` + `claude_session_cursors` tables, their
    /// indexes, and apply the one historical column migration
    /// (`token_events.model_tier`). Idempotent.
    func setupSchema() {
        parent.queue.sync {
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
            execSilent("ALTER TABLE token_events ADD COLUMN model_tier TEXT;")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_session ON token_events(session_id);")
            exec("""
                CREATE TABLE IF NOT EXISTS claude_session_cursors (
                    path TEXT PRIMARY KEY,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    turn_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_project_tool_time ON token_events(project_root, tool_name, timestamp);")
        }
    }

    // MARK: - Writes

    /// Record a token event (from MCP tool call, hook intercept, or ClaudeSessionReader).
    ///
    /// Redaction: `command` can carry agent-supplied text like
    /// `export API_KEY=sk_live_...` or a `curl -H "Authorization: Bearer …"`
    /// invocation. `PersistenceRedaction.redact` strips those before the row
    /// hits disk so a session-db export never contains a live key.
    func recordTokenEvent(
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
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        let redactedCommand = PersistenceRedaction.redactedString(command)
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            // T.5 round 2: resolve current chain anchor (lazy-create
            // 'fresh-install' if none exists for this table) and look up the
            // latest entry_hash for prev linkage.
            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            // Build the canonical-byte input from the to-be-bound values. The
            // three chain columns are excluded by `ChainHasher` — they cannot
            // appear in their own input.
            let columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(sessionId),
                "pane_id":        Self.canonical(paneId),
                "project_root":   Self.canonical(normalizedRoot),
                "source":         .text(source),
                "tool_name":      Self.canonical(toolName),
                "model":          Self.canonical(model),
                "input_tokens":   .integer(Int64(inputTokens)),
                "output_tokens":  .integer(Int64(outputTokens)),
                "saved_tokens":   .integer(Int64(savedTokens)),
                "cost_cents":     .integer(Int64(costCents)),
                "feature":        Self.canonical(feature),
                "command":        Self.canonical(redactedCommand),
                "model_tier":     Self.canonical(modelTier),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            Self.bindOptionalText(stmt, 13, redactedCommand)
            Self.bindOptionalText(stmt, 14, modelTier)
            Self.bindOptionalText(stmt, 15, prevHash)
            sqlite3_bind_text(stmt, 16, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 17, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                // Update cache only on successful insert. parent.queue
                // serialization means no other write can interleave between
                // the prev_hash read and this update.
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    // MARK: - T.5 chain helpers (round 2; generalised in round 3)

    /// Coerce an optional string to a `ChainHasher.CanonicalValue` — empty
    /// strings count as text per SQLite semantics; nil becomes NULL.
    private static func canonical(_ value: String?) -> ChainHasher.CanonicalValue {
        guard let value else { return .null }
        return .text(value)
    }

    /// Record a hook event from the senkani-hook binary. Rows land in
    /// `token_events` with `source='hook'` — there is no separate
    /// `hook_events` table. Delegates to `recordTokenEvent`.
    func recordHookEvent(
        sessionId: String,
        toolName: String,
        eventType: String,
        projectRoot: String?
    ) {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
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

    // MARK: - Stats

    /// Aggregate stats for a project (sidebar display). Optionally scoped to a start date.
    func tokenStatsForProject(_ projectRoot: String, since: Date? = nil) -> PaneTokenStats {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return .zero }
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
    func tokenStatsAllProjects() -> PaneTokenStats {
        return parent.queue.sync {
            guard let db = parent.db else { return .zero }
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

    /// Per-feature token savings breakdown, sorted by savedTokens descending.
    func tokenStatsByFeature(projectRoot: String, since: Date? = nil) -> [SessionDatabase.FeatureSavings] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var results: [SessionDatabase.FeatureSavings] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let feature = String(cString: sqlite3_column_text(stmt, 0))
                let saved = Int(sqlite3_column_int64(stmt, 1))
                let input = Int(sqlite3_column_int64(stmt, 2))
                let output = Int(sqlite3_column_int64(stmt, 3))
                let count = Int(sqlite3_column_int64(stmt, 4))
                results.append(SessionDatabase.FeatureSavings(
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

    /// Per-feature savings across ALL projects (no project filter).
    func tokenStatsByFeatureAllProjects(since: Date? = nil) -> [SessionDatabase.FeatureSavings] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var results: [SessionDatabase.FeatureSavings] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(SessionDatabase.FeatureSavings(
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

    /// Overall live-session compression multiplier for a project.
    /// Returns raw / compressed = (inputTokens + savedTokens) / inputTokens.
    /// Returns nil when no matching events exist.
    func liveSessionMultiplier(projectRoot: String, since: Date? = nil) -> Double? {
        let stats = tokenStatsByFeature(projectRoot: projectRoot, since: since)
        let totalInput = stats.reduce(0) { $0 + $1.inputTokens }
        let totalSaved = stats.reduce(0) { $0 + $1.savedTokens }
        guard totalInput > 0 else { return nil }
        return Double(totalInput + totalSaved) / Double(totalInput)
    }

    // MARK: - Analytics (chart + timeline)

    /// Time-series data for the savings-over-time chart.
    func savingsTimeSeries(projectRoot: String, since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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
                cumRaw += input * 4
                cumSaved += saved * 4
                results.append((timestamp: ts, cumulativeRaw: cumRaw, cumulativeSaved: cumSaved))
            }
            return results
        }
    }

    /// Time-series data across ALL projects (no project filter).
    func savingsTimeSeriesAllProjects(since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

    /// Fetch the most recent token events for a project, newest first.
    func recentTokenEvents(projectRoot: String, limit: Int = 100) -> [SessionDatabase.TimelineEvent] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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
            return Self.parseTimelineRows(stmt)
        }
    }

    /// Fetch the most recent token events across ALL projects.
    func recentTokenEventsAllProjects(limit: Int = 100) -> [SessionDatabase.TimelineEvent] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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
            return Self.parseTimelineRows(stmt)
        }
    }

    private static func parseTimelineRows(_ stmt: OpaquePointer?) -> [SessionDatabase.TimelineEvent] {
        var results: [SessionDatabase.TimelineEvent] = []
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

            results.append(SessionDatabase.TimelineEvent(
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

    // MARK: - Re-read suppression + hot files + session summaries

    /// Return the timestamp of the most recent `senkani_read` of a specific file
    /// within a project. Returns nil if the file has never been read in this session.
    func lastReadTimestamp(filePath: String, projectRoot: String) -> Date? {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
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

    /// Top N most-accessed file paths for a project, ranked by frequency.
    /// Backed by the composite `idx_token_events_project_tool_time` index.
    func hotFiles(projectRoot: String, limit: Int = 50, sinceDaysAgo: Int = 7) -> [(path: String, freq: Int)] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        let cutoff = Date().addingTimeInterval(-Double(sinceDaysAgo) * 86400).timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

    func sessionSummaries(projectRoot: String, limit: Int = 20) -> [SessionDatabase.SessionSummary] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var results: [SessionDatabase.SessionSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = String(cString: sqlite3_column_text(stmt, 0))
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let raw = Int(sqlite3_column_int64(stmt, 2))
                let saved = Int(sqlite3_column_int64(stmt, 3))
                results.append(SessionDatabase.SessionSummary(
                    sessionId: sid, startedAt: ts,
                    totalRawTokens: raw, totalSavedTokens: saved
                ))
            }
            return results
        }
    }

    // MARK: - Compound learning queries

    /// Query token_events for recurring exec commands with poor filter savings.
    func unfilteredExecCommands(
        projectRoot: String,
        minSessions: Int = 2,
        minInputTokens: Int = 100
    ) -> [SessionDatabase.UnfilteredCommandRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var rows: [SessionDatabase.UnfilteredCommandRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let avgInput = Int(sqlite3_column_int64(stmt, 2))
                let avgPct = sqlite3_column_double(stmt, 3)
                rows.append(SessionDatabase.UnfilteredCommandRow(
                    command: cmd,
                    sessionCount: sessions,
                    avgInputTokens: avgInput,
                    avgSavedPct: avgPct
                ))
            }
            return rows
        }
    }

    func recurringFileMentions(
        projectRoot: String,
        minSessions: Int = 3,
        limit: Int = 20
    ) -> [SessionDatabase.RecurringFileRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var rows: [SessionDatabase.RecurringFileRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let mentions = Int(sqlite3_column_int64(stmt, 2))
                rows.append(SessionDatabase.RecurringFileRow(
                    path: cmd,
                    sessionCount: sessions,
                    mentionCount: mentions
                ))
            }
            return rows
        }
    }

    func instructionRetryPatterns(
        projectRoot: String,
        minRetries: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [SessionDatabase.InstructionRetryRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var rows: [SessionDatabase.InstructionRetryRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tn = String(cString: sqlite3_column_text(stmt, 0))
                let cmd = String(cString: sqlite3_column_text(stmt, 1))
                let sessions = Int(sqlite3_column_int64(stmt, 2))
                let avg = sqlite3_column_double(stmt, 3)
                rows.append(SessionDatabase.InstructionRetryRow(
                    toolName: tn, command: cmd,
                    sessionCount: sessions, avgRetries: avg))
            }
            return rows
        }
    }

    func workflowPairPatterns(
        projectRoot: String,
        windowSeconds: Double = 60.0,
        minOccurrencesPerSession: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [SessionDatabase.WorkflowPairRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

            var rows: [SessionDatabase.WorkflowPairRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let a = String(cString: sqlite3_column_text(stmt, 0))
                let b_ = String(cString: sqlite3_column_text(stmt, 1))
                let sessions = Int(sqlite3_column_int64(stmt, 2))
                let occ = Int(sqlite3_column_int64(stmt, 3))
                let perSession = Double(occ) / max(Double(sessions), 1)
                guard perSession >= Double(minOccurrencesPerSession) else { continue }
                rows.append(SessionDatabase.WorkflowPairRow(
                    firstTool: a, secondTool: b_,
                    sessionCount: sessions, totalOccurrences: occ))
            }
            return rows
        }
    }

    // MARK: - Session cursors (ClaudeSessionReader, AXI.3 Tier 1)

    /// Return the stored (byteOffset, turnIndex) for a JSONL file path, or (0, 0) if new.
    func getSessionCursor(path: String) -> (byteOffset: Int, turnIndex: Int) {
        return parent.queue.sync {
            guard let db = parent.db else { return (0, 0) }
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
    func setSessionCursor(path: String, byteOffset: Int, turnIndex: Int) {
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
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

    // MARK: - Prune

    /// Prune token_events older than N days (default: 90) to prevent unbounded growth.
    /// The index on (project_root, tool_name, timestamp) makes the WHERE clause efficient.
    @discardableResult
    func pruneTokenEvents(olderThanDays: Int = 90) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400).timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = "DELETE FROM token_events WHERE timestamp < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// Dump token_events summary to console for debugging.
    func dumpTokenEvents() {
        parent.queue.sync {
            guard let db = parent.db else {
                print("📊 [DB-DUMP] Database not open")
                return
            }
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM token_events", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    print("📊 [DB-DUMP] token_events total rows: \(sqlite3_column_int64(countStmt, 0))")
                }
            }
            sqlite3_finalize(countStmt)

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

    // MARK: - Helpers

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
            Logger.log("token_event_store.sql_error", fields: ["error": .string(msg)])
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
