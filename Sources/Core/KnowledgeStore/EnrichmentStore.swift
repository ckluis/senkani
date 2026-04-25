import Foundation
import SQLite3

/// Owns the `evidence_timeline` and `co_change_coupling` tables end-to-end.
///
/// The two tables share an aggregate identity — "what we've learned about
/// entities" — but have different lifecycles:
///   - `evidence_timeline` is session-derived (entity-keyed, ordered by
///     when learning happened, append-only).
///   - `co_change_coupling` is git-derived (computed from history, pair-keyed,
///     idempotent upsert).
///
/// They are merged into one store because both are downstream artifacts of
/// the enrichment pipeline (compound learning + coupling miner) and neither
/// is large enough to justify its own store. See INVARIANTS.md K3.
///
/// Extracted from `KnowledgeStore` under `luminary-2026-04-24-5-knowledgestore-split`.
/// Shares the parent's connection + dispatch queue.
final class EnrichmentStore: @unchecked Sendable {
    private unowned let parent: KnowledgeStore

    init(parent: KnowledgeStore) {
        self.parent = parent
    }

    // MARK: - Schema

    func setupSchema() {
        parent.queue.sync {
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

    // MARK: - Evidence Timeline

    @discardableResult
    func appendEvidence(_ entry: EvidenceEntry) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
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

    func timeline(forEntityId entityId: Int64) -> [EvidenceEntry] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

    // MARK: - Co-Change Coupling

    /// Upsert coupling pair. Pair is canonicalised (entity_a < entity_b) to avoid duplicates.
    func upsertCoupling(_ entry: CouplingEntry) {
        let a = min(entry.entityA, entry.entityB)
        let b = max(entry.entityA, entry.entityB)
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
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
            sqlite3_bind_text(stmt, 1, (a as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (b as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(entry.commitCount))
            sqlite3_bind_int64(stmt, 4, Int64(entry.totalCommits))
            sqlite3_bind_double(stmt, 5, entry.couplingScore)
            sqlite3_bind_double(stmt, 6, entry.lastComputed.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func couplings(forEntityName name: String, minScore: Double = 0.3) -> [CouplingEntry] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
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

    // MARK: - Private helpers

    private func cstr(_ s: String) -> UnsafePointer<CChar>? {
        (s as NSString).utf8String
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
}
