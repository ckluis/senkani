import Foundation
import SQLite3

/// Persists `PaneRefreshState` per (project_root, tile_id) for V.1 round 2
/// (Dashboard tile refresh contract). Append-only: every `applyOutcome` writes
/// a fresh row; rehydration reads the row with `MAX(id)` per tile via the
/// `idx_pane_refresh_state_latest` index.
///
/// Append-only is what the chain needs — UPDATEs would invalidate stored
/// `entry_hash` values. The only growth control is the (small) row footprint
/// and a future prune (round-3 territory).
///
/// Concurrency: shares `SessionDatabase.queue`; never opens a second handle.
/// `ChainState` holds the per-table anchor + last-hash cache for the hot path.
public final class PaneRefreshStateStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "pane_refresh_state")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller must
    /// already be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    // MARK: - Schema

    /// Idempotent — safe to call on every open. The migration v6 path is the
    /// canonical creator; this mirror exists so a fresh DB on the v6 codebase
    /// gets the table even before `runMigrations` baselines.
    func setupSchema() {
        parent.queue.sync {
            self.exec("""
                CREATE TABLE IF NOT EXISTS pane_refresh_state (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    project_root TEXT NOT NULL,
                    tile_id TEXT NOT NULL,
                    cache_type TEXT NOT NULL,
                    cache_duration REAL NOT NULL,
                    next_update REAL NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    notice TEXT,
                    content_available INTEGER NOT NULL DEFAULT 0,
                    written_at REAL NOT NULL,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_pane_refresh_state_latest ON pane_refresh_state(project_root, tile_id, id DESC);")
            self.execSilent("CREATE INDEX IF NOT EXISTS idx_pane_refresh_state_anchor ON pane_refresh_state(chain_anchor_id, id);")
        }
    }

    // MARK: - Writes

    /// Append a state row for a tile. The chain primitive populates
    /// `prev_hash`, `entry_hash`, and `chain_anchor_id`.
    public func recordOutcome(projectRoot: String, tileId: String, state: PaneRefreshState) {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        let writtenAt = Date().timeIntervalSince1970
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "project_root":      .text(normalizedRoot),
                "tile_id":           .text(tileId),
                "cache_type":        .text(state.cacheType.rawValue),
                "cache_duration":    .real(state.cacheDuration),
                "next_update":       .real(state.nextUpdate.timeIntervalSince1970),
                "retry_count":       .integer(Int64(state.retryCount)),
                "last_error":        Self.canonical(state.lastError),
                "notice":            Self.canonical(state.notice),
                "content_available": .integer(state.contentAvailable ? 1 : 0),
                "written_at":        .real(writtenAt),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "pane_refresh_state", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO pane_refresh_state
                (project_root, tile_id, cache_type, cache_duration, next_update,
                 retry_count, last_error, notice, content_available, written_at,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalizedRoot as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (tileId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (state.cacheType.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, state.cacheDuration)
            sqlite3_bind_double(stmt, 5, state.nextUpdate.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 6, Int64(state.retryCount))
            Self.bindOptionalText(stmt, 7, state.lastError)
            Self.bindOptionalText(stmt, 8, state.notice)
            sqlite3_bind_int64(stmt, 9, state.contentAvailable ? 1 : 0)
            sqlite3_bind_double(stmt, 10, writtenAt)
            Self.bindOptionalText(stmt, 11, prevHash)
            sqlite3_bind_text(stmt, 12, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 13, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
                parent.recordEvent(
                    type: "pane_refresh.persisted",
                    projectRoot: normalizedRoot
                )
            }
        }
    }

    // MARK: - Reads

    /// Latest persisted state for a single tile, or nil if none recorded yet.
    public func latestState(projectRoot: String, tileId: String) -> PaneRefreshState? {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT cache_type, cache_duration, next_update, retry_count,
                       last_error, notice, content_available
                  FROM pane_refresh_state
                 WHERE project_root = ? AND tile_id = ?
                 ORDER BY id DESC LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalizedRoot as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (tileId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.decode(stmt)
        }
    }

    /// All latest-per-tile states for a project, keyed by tile_id. Used by the
    /// coordinator on app start to rehydrate every tile in one query.
    public func latestStates(projectRoot: String) -> [String: PaneRefreshState] {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [:] }
            // Sub-select: latest id per (project_root, tile_id). Index
            // `idx_pane_refresh_state_latest` covers both the GROUP BY and the
            // outer join.
            let sql = """
                SELECT p.tile_id, p.cache_type, p.cache_duration, p.next_update,
                       p.retry_count, p.last_error, p.notice, p.content_available
                  FROM pane_refresh_state p
                 INNER JOIN (
                       SELECT tile_id, MAX(id) AS max_id
                         FROM pane_refresh_state
                        WHERE project_root = ?
                        GROUP BY tile_id
                 ) latest ON p.tile_id = latest.tile_id AND p.id = latest.max_id
                 WHERE p.project_root = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalizedRoot as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (normalizedRoot as NSString).utf8String, -1, nil)
            var out: [String: PaneRefreshState] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tileId = String(cString: sqlite3_column_text(stmt, 0))
                if let state = Self.decode(stmt, offset: 1) {
                    out[tileId] = state
                }
            }
            return out
        }
    }

    /// Convenience for `recordOutcome` followed by an immediate flush. Tests
    /// use this to avoid the async write race.
    public func recordOutcomeSync(projectRoot: String, tileId: String, state: PaneRefreshState) {
        recordOutcome(projectRoot: projectRoot, tileId: tileId, state: state)
        parent.flushWrites()
    }

    // MARK: - Helpers

    /// Decode a state row from a prepared statement positioned at SQLITE_ROW.
    /// Default `offset = 0` reads from column 0 (the `latestState` shape);
    /// `latestStates` uses offset 1 because column 0 is `tile_id`.
    private static func decode(_ stmt: OpaquePointer?, offset: Int32 = 0) -> PaneRefreshState? {
        let cacheTypeRaw = sqlite3_column_text(stmt, offset).map { String(cString: $0) } ?? ""
        guard let cacheType = PaneCacheType(rawValue: cacheTypeRaw) else { return nil }
        let cacheDuration = sqlite3_column_double(stmt, offset + 1)
        let nextUpdate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, offset + 2))
        let retryCount = Int(sqlite3_column_int64(stmt, offset + 3))
        let lastError: String? = sqlite3_column_type(stmt, offset + 4) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, offset + 4))
        let notice: String? = sqlite3_column_type(stmt, offset + 5) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, offset + 5))
        let contentAvailable = sqlite3_column_int64(stmt, offset + 6) != 0
        return PaneRefreshState(
            cacheType: cacheType,
            cacheDuration: cacheDuration,
            nextUpdate: nextUpdate,
            retryCount: retryCount,
            lastError: lastError,
            notice: notice,
            contentAvailable: contentAvailable
        )
    }

    private static func canonical(_ value: String?) -> ChainHasher.CanonicalValue {
        guard let value else { return .null }
        return .text(value)
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
            Logger.log("pane_refresh_state_store.sql_error", fields: ["error": .string(msg)])
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
