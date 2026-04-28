import Foundation
import SQLite3

/// Owns `knowledge_entities` + `knowledge_fts` (FTS5 virtual + 3 sync triggers)
/// end-to-end — schema + entity CRUD + mention-count writes + FTS5 search.
/// Extracted from `KnowledgeStore` under `luminary-2026-04-24-5-knowledgestore-split`
/// (mirroring the SessionDatabase P2-11 pattern). Shares the parent's connection
/// + dispatch queue; never opens a new SQLite handle.
///
/// Public API is forwarded from `KnowledgeStore` — callers stay on
/// `KnowledgeStore.upsertEntity(...)` etc. and the façade delegates here.
final class EntityStore: @unchecked Sendable {
    private unowned let parent: KnowledgeStore

    init(parent: KnowledgeStore) {
        self.parent = parent
    }

    // MARK: - Schema

    func setupSchema() {
        parent.queue.sync {
            exec("""
                CREATE TABLE IF NOT EXISTS knowledge_entities (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    name             TEXT NOT NULL UNIQUE,
                    entity_type      TEXT NOT NULL DEFAULT 'class',
                    source_path      TEXT,
                    markdown_path    TEXT NOT NULL,
                    content_hash     TEXT NOT NULL DEFAULT '',
                    content          TEXT NOT NULL DEFAULT '',
                    last_enriched    REAL,
                    mention_count    INTEGER NOT NULL DEFAULT 0,
                    session_mentions INTEGER NOT NULL DEFAULT 0,
                    staleness_score  REAL NOT NULL DEFAULT 0.0,
                    created_at       REAL NOT NULL,
                    modified_at      REAL NOT NULL
                );
            """)
            // Phase V.5 round 1 — additive `authorship` column. Nullable
            // by design: NULL = pre-V.5 row that has not yet been backfilled.
            // The migration runner (v7) lands the same column on existing
            // DBs; this guard keeps fresh-install schema in sync. Idempotent
            // because `execSilent` swallows duplicate-column errors.
            execSilent("ALTER TABLE knowledge_entities ADD COLUMN authorship TEXT;")
            exec("CREATE INDEX IF NOT EXISTS idx_knowledge_entities_authorship ON knowledge_entities(authorship);")

            // FTS5 with porter stemmer — content= means FTS reads from knowledge_entities.
            // snippet() and highlight() read live content from the backing table.
            exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
                    name,
                    content,
                    content='knowledge_entities',
                    content_rowid='id',
                    tokenize='porter unicode61'
                );
            """)

            // Triggers keep FTS index in sync with knowledge_entities.
            exec("""
                CREATE TRIGGER IF NOT EXISTS knowledge_fts_ai
                AFTER INSERT ON knowledge_entities BEGIN
                    INSERT INTO knowledge_fts(rowid, name, content)
                    VALUES (new.id, new.name, new.content);
                END;
            """)
            exec("""
                CREATE TRIGGER IF NOT EXISTS knowledge_fts_ad
                AFTER DELETE ON knowledge_entities BEGIN
                    INSERT INTO knowledge_fts(knowledge_fts, rowid, name, content)
                    VALUES ('delete', old.id, old.name, old.content);
                END;
            """)
            exec("""
                CREATE TRIGGER IF NOT EXISTS knowledge_fts_au
                AFTER UPDATE ON knowledge_entities BEGIN
                    INSERT INTO knowledge_fts(knowledge_fts, rowid, name, content)
                    VALUES ('delete', old.id, old.name, old.content);
                    INSERT INTO knowledge_fts(rowid, name, content)
                    VALUES (new.id, new.name, new.content);
                END;
            """)
        }
    }

    // MARK: - Entity CRUD

    /// Upsert a `KnowledgeEntity` with an **explicit** `AuthorshipTag`.
    /// Phase V.5 round 1 — the tag parameter is non-optional so the
    /// caller cannot silently inherit a previous row's authorship or
    /// land a NULL through the write path. Callers that don't yet
    /// know the tag pass `AuthorshipTracker.tagForUnknownProvenance()`
    /// (returns `.unset`) so the prompt path (V.5b) can resolve it.
    @discardableResult
    func upsertEntity(_ entity: KnowledgeEntity, authorship: AuthorshipTag) -> Int64 {
        let now = Date().timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = """
                INSERT INTO knowledge_entities
                    (name, entity_type, source_path, markdown_path, content_hash, content,
                     last_enriched, mention_count, session_mentions, staleness_score,
                     created_at, modified_at, authorship)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(name) DO UPDATE SET
                    entity_type      = excluded.entity_type,
                    source_path      = excluded.source_path,
                    markdown_path    = excluded.markdown_path,
                    content_hash     = excluded.content_hash,
                    content          = excluded.content,
                    last_enriched    = excluded.last_enriched,
                    mention_count    = excluded.mention_count,
                    session_mentions = excluded.session_mentions,
                    staleness_score  = excluded.staleness_score,
                    modified_at      = excluded.modified_at,
                    authorship       = excluded.authorship;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1,  cstr(entity.name), -1, nil)
            sqlite3_bind_text(stmt, 2,  cstr(entity.entityType), -1, nil)
            bindText(stmt, 3, entity.sourcePath)
            sqlite3_bind_text(stmt, 4,  cstr(entity.markdownPath), -1, nil)
            sqlite3_bind_text(stmt, 5,  cstr(entity.contentHash), -1, nil)
            sqlite3_bind_text(stmt, 6,  cstr(entity.compiledUnderstanding), -1, nil)
            bindDouble(stmt, 7, entity.lastEnriched?.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 8,  Int64(entity.mentionCount))
            sqlite3_bind_int64(stmt, 9,  Int64(entity.sessionMentions))
            sqlite3_bind_double(stmt, 10, entity.stalenessScore)
            sqlite3_bind_double(stmt, 11, entity.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 12, now)
            sqlite3_bind_text(stmt, 13, cstr(AuthorshipTracker.encode(authorship)), -1, nil)
            sqlite3_step(stmt)

            // last_insert_rowid is unreliable for UPSERT update path — query explicitly.
            var idStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id FROM knowledge_entities WHERE name=?;",
                                     -1, &idStmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(idStmt) }
            sqlite3_bind_text(idStmt, 1, cstr(entity.name), -1, nil)
            guard sqlite3_step(idStmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(idStmt, 0)
        }
    }

    func entity(named name: String) -> KnowledgeEntity? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = "SELECT \(entityCols) FROM knowledge_entities WHERE name=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cstr(name), -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToEntity(stmt)
        }
    }

    func entity(id: Int64) -> KnowledgeEntity? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = "SELECT \(entityCols) FROM knowledge_entities WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToEntity(stmt)
        }
    }

    func allEntities(sortedBy sort: EntitySort = .mentionCountDesc) -> [KnowledgeEntity] {
        let order: String
        switch sort {
        case .mentionCountDesc:  order = "mention_count DESC, name ASC"
        case .nameAsc:           order = "name ASC"
        case .stalenessDesc:     order = "staleness_score DESC, name ASC"
        case .lastEnrichedDesc:  order = "last_enriched DESC NULLS LAST, name ASC"
        }
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = "SELECT \(entityCols) FROM knowledge_entities ORDER BY \(order);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [KnowledgeEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToEntity(stmt)) }
            return out
        }
    }

    func deleteEntity(named name: String) {
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM knowledge_entities WHERE name=?;",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Increment mention counts. Use queue.async — fire-and-forget, non-blocking.
    func updateMentionCounts(name: String, sessionDelta: Int, lifetimeDelta: Int = 0) {
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            let sql = """
                UPDATE knowledge_entities SET
                    session_mentions = session_mentions + ?,
                    mention_count    = mention_count + ?,
                    modified_at      = ?
                WHERE name = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(sessionDelta))
            sqlite3_bind_int64(stmt, 2, Int64(lifetimeDelta))
            sqlite3_bind_double(stmt, 3, now)
            sqlite3_bind_text(stmt, 4, (name as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Increment session_mentions and mention_count for multiple entities in one transaction.
    /// Prepare-once / step-N pattern: one BEGIN/COMMIT for all rows — same fsync cost as one row.
    func batchIncrementMentions(_ deltas: [String: Int]) {
        guard !deltas.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            rawExec(db, "BEGIN;")
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }  // sqlite3_finalize(nil) is a no-op per spec
            let sql = """
                UPDATE knowledge_entities
                SET session_mentions = session_mentions + ?,
                    mention_count    = mention_count + ?,
                    modified_at      = ?
                WHERE name = ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                rawExec(db, "ROLLBACK;"); return
            }
            for (name, delta) in deltas where delta > 0 {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(delta))
                sqlite3_bind_int64(stmt, 2, Int64(delta))
                sqlite3_bind_double(stmt, 3, now)
                sqlite3_bind_text(stmt, 4, (name as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            rawExec(db, "COMMIT;")
        }
    }

    /// Reset session_mentions to 0 for all entities. Call on session open.
    func resetSessionMentions() {
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            rawExec(db, "UPDATE knowledge_entities SET session_mentions = 0;")
        }
    }

    func updateStaleness(name: String, score: Double) {
        let clamped = max(0.0, min(1.0, score))
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "UPDATE knowledge_entities SET staleness_score=?, modified_at=? WHERE name=?;",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, clamped)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, (name as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Staleness ramps 0→1 over 7 days as source file ages past last enrichment.
    func computeStaleness(name: String, sourceFileModifiedAt: Date) -> Double {
        guard let e = entity(named: name) else { return 0.0 }
        guard let lastEnriched = e.lastEnriched else { return 1.0 }
        let delta = sourceFileModifiedAt.timeIntervalSince(lastEnriched)
        guard delta > 0 else { return 0.0 }
        return min(1.0, delta / (7.0 * 86_400.0))
    }

    // MARK: - FTS5 Search

    /// Full-text search across name and compiled understanding.
    /// Query is sanitized before use. Results ordered best-first (lowest BM25 rank).
    /// SECURITY: All user input is sanitized — FTS5 operators stripped.
    func search(query: String, limit: Int = 10) -> [KnowledgeSearchResult] {
        let sanitized = SessionDatabase.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }
        let cap = max(1, min(limit, 50))

        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            // Fully qualify ke.name and ke.content to avoid ambiguous column names —
            // knowledge_fts has virtual columns 'name' and 'content' with the same names.
            // snippet() col index 1 = content column («»… markers, 16 tokens).
            let sql = """
                SELECT ke.id, ke.name, ke.entity_type, ke.source_path, ke.markdown_path,
                       ke.content_hash, ke.content, ke.last_enriched, ke.mention_count,
                       ke.session_mentions, ke.staleness_score, ke.created_at, ke.modified_at,
                       ke.authorship,
                       snippet(knowledge_fts, 1, '\u{AB}', '\u{BB}', '\u{2026}', 16) AS snip,
                       knowledge_fts.rank AS bm25_rank
                FROM knowledge_fts
                JOIN knowledge_entities ke ON ke.id = knowledge_fts.rowid
                WHERE knowledge_fts MATCH ?
                ORDER BY knowledge_fts.rank
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cstr(sanitized), -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(cap))

            var out: [KnowledgeSearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                // rowToEntity reads cols 0–13 (entity + authorship);
                // snippet sits at 14, rank at 15. Phase V.5 round 1
                // shifted the snippet/rank indices by one.
                let entity = rowToEntity(stmt)
                let snip = colText(stmt, 14) ?? ""
                let rank = sqlite3_column_double(stmt, 15)
                out.append(KnowledgeSearchResult(entity: entity, snippet: snip, bm25Rank: rank))
            }
            return out
        }
    }

    // MARK: - Private helpers

    private let entityCols = """
        id, name, entity_type, source_path, markdown_path, content_hash,
        content, last_enriched, mention_count, session_mentions,
        staleness_score, created_at, modified_at, authorship
    """

    private func rowToEntity(_ stmt: OpaquePointer?) -> KnowledgeEntity {
        // Phase V.5 round 1 — read the authorship column. NULL maps to
        // `nil` (legacy / pre-migration row); a non-NULL string routes
        // through `AuthorshipTracker.decode` for parse + sentinel-empty
        // handling. An unknown rawValue (corrupt row) yields `nil` —
        // round 1 chooses to surface that as "untagged" rather than
        // crash, since the prompt path (V.5b) will heal it on next save.
        let rawAuthorship = colText(stmt, 13)
        let authorship: AuthorshipTag? = rawAuthorship.flatMap { AuthorshipTracker.decode($0) }
        return KnowledgeEntity(
            id:                   sqlite3_column_int64(stmt, 0),
            name:                 String(cString: sqlite3_column_text(stmt, 1)),
            entityType:           String(cString: sqlite3_column_text(stmt, 2)),
            sourcePath:           colText(stmt, 3),
            markdownPath:         String(cString: sqlite3_column_text(stmt, 4)),
            contentHash:          String(cString: sqlite3_column_text(stmt, 5)),
            compiledUnderstanding: String(cString: sqlite3_column_text(stmt, 6)),
            lastEnriched:         sqlite3_column_type(stmt, 7) != SQLITE_NULL
                                      ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                                      : nil,
            mentionCount:         Int(sqlite3_column_int64(stmt, 8)),
            sessionMentions:      Int(sqlite3_column_int64(stmt, 9)),
            stalenessScore:       sqlite3_column_double(stmt, 10),
            createdAt:            Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
            modifiedAt:           Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
            authorship:           authorship
        )
    }

    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    private func cstr(_ s: String) -> UnsafePointer<CChar>? {
        (s as NSString).utf8String
    }

    private func bindText(_ stmt: OpaquePointer?, _ col: Int32, _ value: String?) {
        if let v = value { sqlite3_bind_text(stmt, col, cstr(v), -1, nil) }
        else { sqlite3_bind_null(stmt, col) }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ col: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, col, v) }
        else { sqlite3_bind_null(stmt, col) }
    }

    private func exec(_ sql: String) {
        guard let db = parent.db else { return }
        rawExec(db, sql)
    }

    /// Run `sql` and swallow `duplicate column name` errors. Used for
    /// idempotent ALTERs that re-run on every fresh-install setup
    /// without breaking when migration v7 already landed the column.
    /// All other errors print to stderr (same channel as `rawExec`).
    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc == SQLITE_OK {
            if let err { sqlite3_free(err) }
            return
        }
        let msg = err.map { String(cString: $0) } ?? "unknown"
        if let err { sqlite3_free(err) }
        if msg.contains("duplicate column name") { return }
        fputs("[KnowledgeStore] SQL error: \(msg)\n", stderr)
    }
}

// File-scope helper: executable from inside `queue.async` closures that
// captured `[weak parent]` — no `self` available. Kept fileprivate so each
// store file can declare its own copy without symbol clashes (mirroring
// the per-store private `exec` pattern in `Sources/Core/Stores/`).
fileprivate func rawExec(_ db: OpaquePointer, _ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        fputs("[KnowledgeStore] SQL error: \(msg)\n", stderr)
        sqlite3_free(err)
    }
}
