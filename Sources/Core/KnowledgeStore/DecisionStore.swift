import Foundation
import SQLite3

/// Owns the `decision_records` table end-to-end — schema + indexes + insert/read.
/// Extracted from `KnowledgeStore` under `luminary-2026-04-24-5-knowledgestore-split`.
/// Shares the parent's connection + dispatch queue.
///
/// The `idx_decisions_commit` partial unique index dedups git_commit-sourced
/// decisions on (entity_name, commit_hash); other sources can repeat freely.
final class DecisionStore: @unchecked Sendable {
    private unowned let parent: KnowledgeStore

    init(parent: KnowledgeStore) {
        self.parent = parent
    }

    // MARK: - Schema

    func setupSchema() {
        parent.queue.sync {
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
            // Dedup: one record per (entity_name, commit_hash) for git_commit source.
            // execSilent because the partial-index syntax can vary between SQLite builds —
            // failure to create is non-fatal (callers tolerate duplicate git_commit rows).
            execSilent("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_decisions_commit
                ON decision_records(entity_name, commit_hash)
                WHERE source = 'git_commit' AND commit_hash IS NOT NULL;
            """)
        }
    }

    // MARK: - Decision CRUD

    @discardableResult
    func insertDecision(_ record: DecisionRecord) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
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

    func decisions(forEntityName name: String) -> [DecisionRecord] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

    // MARK: - Private helpers

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

    private func bindInt64(_ stmt: OpaquePointer?, _ col: Int32, _ value: Int64?) {
        if let v = value { sqlite3_bind_int64(stmt, col, v) }
        else { sqlite3_bind_null(stmt, col) }
    }

    private func exec(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            fputs("[KnowledgeStore] SQL error: \(msg)\n", stderr)
            sqlite3_free(err)
        }
    }

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
    }
}
