import Foundation
import SQLite3

// MARK: - Public Types

public struct KnowledgeEntity: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let entityType: String           // class|struct|func|file|concept
    public let sourcePath: String?          // relative to project root
    public let markdownPath: String         // .senkani/knowledge/<Name>.md
    public let contentHash: String          // SHA-256 of markdown file
    public let compiledUnderstanding: String
    public let lastEnriched: Date?
    public let mentionCount: Int
    public let sessionMentions: Int
    public let stalenessScore: Double       // 0.0 (fresh) → 1.0 (stale)
    public let createdAt: Date
    public let modifiedAt: Date

    public init(
        id: Int64 = 0,
        name: String,
        entityType: String = "class",
        sourcePath: String? = nil,
        markdownPath: String,
        contentHash: String = "",
        compiledUnderstanding: String = "",
        lastEnriched: Date? = nil,
        mentionCount: Int = 0,
        sessionMentions: Int = 0,
        stalenessScore: Double = 0.0,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.entityType = entityType
        self.sourcePath = sourcePath; self.markdownPath = markdownPath
        self.contentHash = contentHash; self.compiledUnderstanding = compiledUnderstanding
        self.lastEnriched = lastEnriched; self.mentionCount = mentionCount
        self.sessionMentions = sessionMentions; self.stalenessScore = stalenessScore
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public enum EntitySort: Sendable {
    case mentionCountDesc, nameAsc, stalenessDesc, lastEnrichedDesc
}

public struct KnowledgeSearchResult: Sendable {
    public let entity: KnowledgeEntity
    public let snippet: String      // excerpt with «match» markers
    public let bm25Rank: Double     // lower = better
}

public struct EntityLink: Sendable, Equatable {
    public let id: Int64
    public let sourceId: Int64
    public let targetName: String
    public let targetId: Int64?
    public let relation: String?    // depends_on|used_by|co_changes_with|concept
    public let confidence: Double
    public let lineNumber: Int?
    public let createdAt: Date

    public init(
        id: Int64 = 0, sourceId: Int64, targetName: String,
        targetId: Int64? = nil, relation: String? = nil,
        confidence: Double = 1.0, lineNumber: Int? = nil, createdAt: Date = Date()
    ) {
        self.id = id; self.sourceId = sourceId; self.targetName = targetName
        self.targetId = targetId; self.relation = relation
        self.confidence = confidence; self.lineNumber = lineNumber; self.createdAt = createdAt
    }
}

public struct DecisionRecord: Sendable {
    public let id: Int64
    public let entityId: Int64?
    public let entityName: String
    public let decision: String
    public let rationale: String
    public let source: String       // git_commit|annotation|cli|agent
    public let commitHash: String?
    public let createdAt: Date
    public let validUntil: Date?

    public init(
        id: Int64 = 0, entityId: Int64? = nil, entityName: String,
        decision: String, rationale: String, source: String,
        commitHash: String? = nil, createdAt: Date = Date(), validUntil: Date? = nil
    ) {
        self.id = id; self.entityId = entityId; self.entityName = entityName
        self.decision = decision; self.rationale = rationale; self.source = source
        self.commitHash = commitHash; self.createdAt = createdAt; self.validUntil = validUntil
    }
}

public struct EvidenceEntry: Sendable {
    public let id: Int64
    public let entityId: Int64
    public let sessionId: String
    public let whatWasLearned: String
    public let source: String       // enrichment|git_archaeology|annotation|cli
    public let createdAt: Date

    public init(
        id: Int64 = 0, entityId: Int64, sessionId: String,
        whatWasLearned: String, source: String, createdAt: Date = Date()
    ) {
        self.id = id; self.entityId = entityId; self.sessionId = sessionId
        self.whatWasLearned = whatWasLearned; self.source = source; self.createdAt = createdAt
    }
}

public struct CouplingEntry: Sendable {
    public let id: Int64
    public let entityA: String
    public let entityB: String
    public let commitCount: Int
    public let totalCommits: Int
    public let couplingScore: Double
    public let lastComputed: Date

    public init(
        id: Int64 = 0, entityA: String, entityB: String,
        commitCount: Int, totalCommits: Int, couplingScore: Double, lastComputed: Date = Date()
    ) {
        self.id = id; self.entityA = entityA; self.entityB = entityB
        self.commitCount = commitCount; self.totalCommits = totalCommits
        self.couplingScore = couplingScore; self.lastComputed = lastComputed
    }
}

// MARK: - KnowledgeStore

/// Project-scoped SQLite+FTS5 knowledge base.
/// Opens <projectRoot>/.senkani/vault.db — isolated from SessionDatabase.
/// All DB access is serialized through `queue` (NSLock-free, dispatch-based).
public final class KnowledgeStore: @unchecked Sendable {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.senkani.knowledgestore", qos: .utility)

    // MARK: Init

    public init(projectRoot: String) {
        let dir = projectRoot + "/.senkani"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        openDB(path: dir + "/vault.db")
    }

    /// Testable init — pass a /tmp/... path.
    public init(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        openDB(path: path)
    }

    private func openDB(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            fputs("[KnowledgeStore] Failed to open \(path): \(err)\n", stderr)
            db = nil
        }
        enableWAL()
        setupSchema()
    }

    deinit {
        queue.sync { if let db { sqlite3_close(db) } }
    }

    public func close() {
        queue.sync { if let db { sqlite3_close(db) }; self.db = nil }
    }

    // MARK: WAL

    private func enableWAL() {
        guard let db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Enable foreign key enforcement
        var fkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA foreign_keys=ON;", -1, &fkStmt, nil) == SQLITE_OK {
            sqlite3_step(fkStmt)
        }
        sqlite3_finalize(fkStmt)
    }

    // MARK: Schema

    private func setupSchema() {
        queue.sync {
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

            exec("""
                CREATE TABLE IF NOT EXISTS entity_links (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id   INTEGER NOT NULL REFERENCES knowledge_entities(id) ON DELETE CASCADE,
                    target_name TEXT NOT NULL,
                    target_id   INTEGER REFERENCES knowledge_entities(id) ON DELETE SET NULL,
                    relation    TEXT,
                    confidence  REAL NOT NULL DEFAULT 1.0,
                    line_number INTEGER,
                    created_at  REAL NOT NULL,
                    UNIQUE(source_id, target_name, relation)
                );
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_klinks_source ON entity_links(source_id);")
            exec("CREATE INDEX IF NOT EXISTS idx_klinks_tname  ON entity_links(target_name);")
            exec("CREATE INDEX IF NOT EXISTS idx_klinks_tid    ON entity_links(target_id);")

            exec("""
                CREATE TABLE IF NOT EXISTS decision_records (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_id   INTEGER REFERENCES knowledge_entities(id) ON DELETE CASCADE,
                    entity_name TEXT NOT NULL,
                    decision    TEXT NOT NULL,
                    rationale   TEXT NOT NULL,
                    source      TEXT NOT NULL,
                    commit_hash TEXT,
                    created_at  REAL NOT NULL,
                    valid_until REAL
                );
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_decisions_ename ON decision_records(entity_name);")
            // Dedup: one record per (entity_name, commit_hash) for git_commit source
            execSilent("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_decisions_commit
                ON decision_records(entity_name, commit_hash)
                WHERE source = 'git_commit' AND commit_hash IS NOT NULL;
            """)

            exec("""
                CREATE TABLE IF NOT EXISTS evidence_timeline (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_id        INTEGER NOT NULL REFERENCES knowledge_entities(id) ON DELETE CASCADE,
                    session_id       TEXT NOT NULL,
                    what_was_learned TEXT NOT NULL,
                    source           TEXT NOT NULL,
                    created_at       REAL NOT NULL
                );
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_evidence_eid ON evidence_timeline(entity_id);")

            exec("""
                CREATE TABLE IF NOT EXISTS co_change_coupling (
                    id             INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_a       TEXT NOT NULL,
                    entity_b       TEXT NOT NULL,
                    commit_count   INTEGER NOT NULL DEFAULT 0,
                    total_commits  INTEGER NOT NULL DEFAULT 0,
                    coupling_score REAL NOT NULL DEFAULT 0.0,
                    last_computed  REAL NOT NULL,
                    UNIQUE(entity_a, entity_b)
                );
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_coupling_a ON co_change_coupling(entity_a);")
            exec("CREATE INDEX IF NOT EXISTS idx_coupling_b ON co_change_coupling(entity_b);")
        }
    }

    // MARK: Entity CRUD

    /// Upsert entity by name. Returns row id (stable across updates).
    @discardableResult
    public func upsertEntity(_ entity: KnowledgeEntity) -> Int64 {
        let now = Date().timeIntervalSince1970
        return queue.sync {
            guard let db else { return 0 }
            let sql = """
                INSERT INTO knowledge_entities
                    (name, entity_type, source_path, markdown_path, content_hash, content,
                     last_enriched, mention_count, session_mentions, staleness_score,
                     created_at, modified_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
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
                    modified_at      = excluded.modified_at;
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

    public func entity(named name: String) -> KnowledgeEntity? {
        return queue.sync {
            guard let db else { return nil }
            let sql = "SELECT \(entityCols) FROM knowledge_entities WHERE name=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cstr(name), -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToEntity(stmt)
        }
    }

    public func entity(id: Int64) -> KnowledgeEntity? {
        return queue.sync {
            guard let db else { return nil }
            let sql = "SELECT \(entityCols) FROM knowledge_entities WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToEntity(stmt)
        }
    }

    public func allEntities(sortedBy sort: EntitySort = .mentionCountDesc) -> [KnowledgeEntity] {
        let order: String
        switch sort {
        case .mentionCountDesc:  order = "mention_count DESC, name ASC"
        case .nameAsc:           order = "name ASC"
        case .stalenessDesc:     order = "staleness_score DESC, name ASC"
        case .lastEnrichedDesc:  order = "last_enriched DESC NULLS LAST, name ASC"
        }
        return queue.sync {
            guard let db else { return [] }
            let sql = "SELECT \(entityCols) FROM knowledge_entities ORDER BY \(order);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [KnowledgeEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToEntity(stmt)) }
            return out
        }
    }

    public func deleteEntity(named name: String) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM knowledge_entities WHERE name=?;",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, self.cstr(name), -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Increment mention counts. Use queue.async — fire-and-forget, non-blocking.
    public func updateMentionCounts(name: String, sessionDelta: Int, lifetimeDelta: Int = 0) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
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
            sqlite3_bind_text(stmt, 4, self.cstr(name), -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Increment session_mentions and mention_count for multiple entities in one transaction.
    /// Prepare-once / step-N pattern: one BEGIN/COMMIT for all rows — same fsync cost as one row.
    public func batchIncrementMentions(_ deltas: [String: Int]) {
        guard !deltas.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
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
                sqlite3_bind_text(stmt, 4, cstr(name), -1, nil)
                sqlite3_step(stmt)
            }
            rawExec(db, "COMMIT;")
        }
    }

    /// Reset session_mentions to 0 for all entities. Call on session open.
    public func resetSessionMentions() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            self.rawExec(db, "UPDATE knowledge_entities SET session_mentions = 0;")
        }
    }

    public func updateStaleness(name: String, score: Double) {
        let clamped = max(0.0, min(1.0, score))
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "UPDATE knowledge_entities SET staleness_score=?, modified_at=? WHERE name=?;",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, clamped)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, self.cstr(name), -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Staleness ramps 0→1 over 7 days as source file ages past last enrichment.
    public func computeStaleness(name: String, sourceFileModifiedAt: Date) -> Double {
        guard let e = entity(named: name) else { return 0.0 }
        guard let lastEnriched = e.lastEnriched else { return 1.0 }
        let delta = sourceFileModifiedAt.timeIntervalSince(lastEnriched)
        guard delta > 0 else { return 0.0 }
        return min(1.0, delta / (7.0 * 86_400.0))
    }

    // MARK: FTS5 Search

    /// Full-text search across name and compiled understanding.
    /// Query is sanitized before use. Results ordered best-first (lowest BM25 rank).
    /// SECURITY: All user input is sanitized — FTS5 operators stripped.
    public func search(query: String, limit: Int = 10) -> [KnowledgeSearchResult] {
        let sanitized = SessionDatabase.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }
        let cap = max(1, min(limit, 50))

        return queue.sync {
            guard let db else { return [] }
            // Fully qualify ke.name and ke.content to avoid ambiguous column names —
            // knowledge_fts has virtual columns 'name' and 'content' with the same names.
            // snippet() col index 1 = content column («»… markers, 16 tokens).
            let sql = """
                SELECT ke.id, ke.name, ke.entity_type, ke.source_path, ke.markdown_path,
                       ke.content_hash, ke.content, ke.last_enriched, ke.mention_count,
                       ke.session_mentions, ke.staleness_score, ke.created_at, ke.modified_at,
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
                let entity = rowToEntity(stmt)           // cols 0–12
                let snip = colText(stmt, 13) ?? ""
                let rank = sqlite3_column_double(stmt, 14)
                out.append(KnowledgeSearchResult(entity: entity, snippet: snip, bm25Rank: rank))
            }
            return out
        }
    }

    // MARK: Links

    /// Delete all outgoing links from an entity before re-parsing its markdown.
    public func deleteLinks(forEntityId entityId: Int64) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM entity_links WHERE source_id=?;",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entityId)
            sqlite3_step(stmt)
        }
    }

    /// Insert a link. Ignores exact duplicates (same source_id/target_name/relation).
    @discardableResult
    public func insertLink(_ link: EntityLink) -> Int64 {
        return queue.sync {
            guard let db else { return 0 }
            let sql = """
                INSERT OR IGNORE INTO entity_links
                    (source_id, target_name, target_id, relation, confidence, line_number, created_at)
                VALUES (?,?,?,?,?,?,?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, link.sourceId)
            sqlite3_bind_text(stmt, 2, cstr(link.targetName), -1, nil)
            bindInt64(stmt, 3, link.targetId)
            bindText(stmt, 4, link.relation)
            sqlite3_bind_double(stmt, 5, link.confidence)
            bindInt32(stmt, 6, link.lineNumber.map { Int32($0) })
            sqlite3_bind_double(stmt, 7, link.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func links(fromEntityId entityId: Int64) -> [EntityLink] {
        return queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT id, source_id, target_name, target_id, relation, confidence, line_number, created_at
                FROM entity_links WHERE source_id=? ORDER BY created_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entityId)
            return linkRows(stmt)
        }
    }

    public func backlinks(toEntityName name: String) -> [EntityLink] {
        return queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT id, source_id, target_name, target_id, relation, confidence, line_number, created_at
                FROM entity_links WHERE target_name=? ORDER BY created_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cstr(name), -1, nil)
            return linkRows(stmt)
        }
    }

    /// Populate target_id for all links whose target_name matches a known entity.
    public func resolveLinks() {
        queue.sync {
            guard let db else { return }
            rawExec(db, """
                UPDATE entity_links
                SET target_id = (
                    SELECT id FROM knowledge_entities WHERE name = entity_links.target_name
                )
                WHERE target_id IS NULL;
            """)
        }
    }

    // MARK: Decision Records

    @discardableResult
    public func insertDecision(_ record: DecisionRecord) -> Int64 {
        return queue.sync {
            guard let db else { return 0 }
            let sql = """
                INSERT OR IGNORE INTO decision_records
                    (entity_id, entity_name, decision, rationale, source, commit_hash, created_at, valid_until)
                VALUES (?,?,?,?,?,?,?,?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bindInt64(stmt, 1, record.entityId)
            sqlite3_bind_text(stmt, 2, cstr(record.entityName), -1, nil)
            sqlite3_bind_text(stmt, 3, cstr(record.decision), -1, nil)
            sqlite3_bind_text(stmt, 4, cstr(record.rationale), -1, nil)
            sqlite3_bind_text(stmt, 5, cstr(record.source), -1, nil)
            bindText(stmt, 6, record.commitHash)
            sqlite3_bind_double(stmt, 7, record.createdAt.timeIntervalSince1970)
            bindDouble(stmt, 8, record.validUntil?.timeIntervalSince1970)
            sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func decisions(forEntityName name: String) -> [DecisionRecord] {
        return queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT id, entity_id, entity_name, decision, rationale, source,
                       commit_hash, created_at, valid_until
                FROM decision_records WHERE entity_name=? ORDER BY created_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cstr(name), -1, nil)
            return decisionRows(stmt)
        }
    }

    // MARK: Evidence Timeline

    @discardableResult
    public func appendEvidence(_ entry: EvidenceEntry) -> Int64 {
        return queue.sync {
            guard let db else { return 0 }
            let sql = """
                INSERT INTO evidence_timeline
                    (entity_id, session_id, what_was_learned, source, created_at)
                VALUES (?,?,?,?,?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entry.entityId)
            sqlite3_bind_text(stmt, 2, cstr(entry.sessionId), -1, nil)
            sqlite3_bind_text(stmt, 3, cstr(entry.whatWasLearned), -1, nil)
            sqlite3_bind_text(stmt, 4, cstr(entry.source), -1, nil)
            sqlite3_bind_double(stmt, 5, entry.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func timeline(forEntityId entityId: Int64) -> [EvidenceEntry] {
        return queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT id, entity_id, session_id, what_was_learned, source, created_at
                FROM evidence_timeline WHERE entity_id=? ORDER BY created_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entityId)
            var out: [EvidenceEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(EvidenceEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    entityId: sqlite3_column_int64(stmt, 1),
                    sessionId: String(cString: sqlite3_column_text(stmt, 2)),
                    whatWasLearned: String(cString: sqlite3_column_text(stmt, 3)),
                    source: String(cString: sqlite3_column_text(stmt, 4)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                ))
            }
            return out
        }
    }

    // MARK: Co-Change Coupling

    /// Upsert coupling pair. Pair is canonicalised (entity_a < entity_b) to avoid duplicates.
    public func upsertCoupling(_ entry: CouplingEntry) {
        let a = min(entry.entityA, entry.entityB)
        let b = max(entry.entityA, entry.entityB)
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO co_change_coupling
                    (entity_a, entity_b, commit_count, total_commits, coupling_score, last_computed)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(entity_a, entity_b) DO UPDATE SET
                    commit_count   = excluded.commit_count,
                    total_commits  = excluded.total_commits,
                    coupling_score = excluded.coupling_score,
                    last_computed  = excluded.last_computed;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, self.cstr(a), -1, nil)
            sqlite3_bind_text(stmt, 2, self.cstr(b), -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(entry.commitCount))
            sqlite3_bind_int64(stmt, 4, Int64(entry.totalCommits))
            sqlite3_bind_double(stmt, 5, entry.couplingScore)
            sqlite3_bind_double(stmt, 6, entry.lastComputed.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func couplings(forEntityName name: String, minScore: Double = 0.3) -> [CouplingEntry] {
        return queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT id, entity_a, entity_b, commit_count, total_commits, coupling_score, last_computed
                FROM co_change_coupling
                WHERE (entity_a=? OR entity_b=?) AND coupling_score>=?
                ORDER BY coupling_score DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cstr(name), -1, nil)
            sqlite3_bind_text(stmt, 2, cstr(name), -1, nil)
            sqlite3_bind_double(stmt, 3, minScore)
            var out: [CouplingEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(CouplingEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    entityA: String(cString: sqlite3_column_text(stmt, 1)),
                    entityB: String(cString: sqlite3_column_text(stmt, 2)),
                    commitCount: Int(sqlite3_column_int64(stmt, 3)),
                    totalCommits: Int(sqlite3_column_int64(stmt, 4)),
                    couplingScore: sqlite3_column_double(stmt, 5),
                    lastComputed: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                ))
            }
            return out
        }
    }

    // MARK: Private Helpers

    private let entityCols = """
        id, name, entity_type, source_path, markdown_path, content_hash,
        content, last_enriched, mention_count, session_mentions,
        staleness_score, created_at, modified_at
    """

    // Maps a statement row to KnowledgeEntity. Column order must match entityCols.
    private func rowToEntity(_ stmt: OpaquePointer?) -> KnowledgeEntity {
        KnowledgeEntity(
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
            modifiedAt:           Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        )
    }

    private func linkRows(_ stmt: OpaquePointer?) -> [EntityLink] {
        var out: [EntityLink] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(EntityLink(
                id:         sqlite3_column_int64(stmt, 0),
                sourceId:   sqlite3_column_int64(stmt, 1),
                targetName: String(cString: sqlite3_column_text(stmt, 2)),
                targetId:   sqlite3_column_type(stmt, 3) != SQLITE_NULL
                                ? sqlite3_column_int64(stmt, 3) : nil,
                relation:   colText(stmt, 4),
                confidence: sqlite3_column_double(stmt, 5),
                lineNumber: sqlite3_column_type(stmt, 6) != SQLITE_NULL
                                ? Int(sqlite3_column_int(stmt, 6)) : nil,
                createdAt:  Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            ))
        }
        return out
    }

    private func decisionRows(_ stmt: OpaquePointer?) -> [DecisionRecord] {
        var out: [DecisionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DecisionRecord(
                id:         sqlite3_column_int64(stmt, 0),
                entityId:   sqlite3_column_type(stmt, 1) != SQLITE_NULL
                                ? sqlite3_column_int64(stmt, 1) : nil,
                entityName: String(cString: sqlite3_column_text(stmt, 2)),
                decision:   String(cString: sqlite3_column_text(stmt, 3)),
                rationale:  String(cString: sqlite3_column_text(stmt, 4)),
                source:     String(cString: sqlite3_column_text(stmt, 5)),
                commitHash: colText(stmt, 6),
                createdAt:  Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                validUntil: sqlite3_column_type(stmt, 8) != SQLITE_NULL
                                ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
            ))
        }
        return out
    }

    // Returns nil for SQLITE_NULL columns, otherwise UTF-8 string.
    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    /// Execute SQL — logs errors. Must be called from within queue.
    private func exec(_ sql: String) {
        guard let db else { return }
        rawExec(db, sql)
    }

    /// Execute SQL silently (used for migrations where failure is expected).
    private func execSilent(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
    }

    private func rawExec(_ db: OpaquePointer, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            fputs("[KnowledgeStore] SQL error: \(msg)\n", stderr)
            sqlite3_free(err)
        }
    }

    /// Safe C-string for SQLite binding. NSString keeps the backing buffer alive
    /// for the duration of the calling function's stack frame — safe with SQLITE_STATIC.
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

    private func bindInt64(_ stmt: OpaquePointer?, _ col: Int32, _ value: Int64?) {
        if let v = value { sqlite3_bind_int64(stmt, col, v) }
        else { sqlite3_bind_null(stmt, col) }
    }

    private func bindInt32(_ stmt: OpaquePointer?, _ col: Int32, _ value: Int32?) {
        if let v = value { sqlite3_bind_int(stmt, col, v) }
        else { sqlite3_bind_null(stmt, col) }
    }
}
