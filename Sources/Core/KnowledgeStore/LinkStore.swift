import Foundation
import SQLite3

/// Owns the `entity_links` table end-to-end — schema + indexes + link CRUD
/// + backlink lookup + the post-hoc `target_id` resolver. Extracted from
/// `KnowledgeStore` under `luminary-2026-04-24-5-knowledgestore-split`.
/// Shares the parent's connection + dispatch queue.
///
/// Note: `entity_links.source_id` and `entity_links.target_id` reference
/// `knowledge_entities(id)` (FK enforced by SQLite via `PRAGMA foreign_keys=ON`
/// at the connection layer). That is the one place where DDL crosses store
/// boundaries today — see INVARIANTS.md K2.
final class LinkStore: @unchecked Sendable {
    private unowned let parent: KnowledgeStore

    init(parent: KnowledgeStore) {
        self.parent = parent
    }

    // MARK: - Schema

    func setupSchema() {
        parent.queue.sync {
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
        }
    }

    // MARK: - Link CRUD

    /// Delete all outgoing links from an entity before re-parsing its markdown.
    func deleteLinks(forEntityId entityId: Int64) {
        parent.queue.sync {
            guard let db = parent.db else { return }
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
    func insertLink(_ link: EntityLink) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
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

    func links(fromEntityId entityId: Int64) -> [EntityLink] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

    func backlinks(toEntityName name: String) -> [EntityLink] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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
    func resolveLinks() {
        parent.queue.sync {
            guard let db = parent.db else { return }
            rawExec(db, """
                UPDATE entity_links
                SET target_id = (
                    SELECT id FROM knowledge_entities WHERE name = entity_links.target_name
                )
                WHERE target_id IS NULL;
            """)
        }
    }

    // MARK: - Private helpers

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

    private func bindInt64(_ stmt: OpaquePointer?, _ col: Int32, _ value: Int64?) {
        if let v = value { sqlite3_bind_int64(stmt, col, v) }
        else { sqlite3_bind_null(stmt, col) }
    }

    private func bindInt32(_ stmt: OpaquePointer?, _ col: Int32, _ value: Int32?) {
        if let v = value { sqlite3_bind_int(stmt, col, v) }
        else { sqlite3_bind_null(stmt, col) }
    }

    private func exec(_ sql: String) {
        guard let db = parent.db else { return }
        rawExec(db, sql)
    }
}

fileprivate func rawExec(_ db: OpaquePointer, _ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        fputs("[KnowledgeStore] SQL error: \(msg)\n", stderr)
        sqlite3_free(err)
    }
}
