import Foundation
import SQLite3

/// Owns the `annotations` table — V.6 round 1 backend foundation.
///
/// One row per operator-tagged segment of a target artifact (a skill
/// or KB entity). The row carries the verdict (`works` | `fails` |
/// `note`), the byte/character range it covers, an optional free-text
/// note, and the `AuthorshipTag` of the operator who tagged it
/// (Gebru's V.5 invariant: provenance is explicit, never inferred).
///
/// Append-only by design — operators don't mutate prior verdicts; a
/// new annotation supersedes by being more recent. `renameTarget`
/// rewrites `target_id` for survival across artifact rename / move /
/// fork without losing the annotation lineage (Torres acceptance:
/// "Annotations survive a fixture artifact rename").
///
/// Audit chain note: schema includes `prev_hash`, `entry_hash`,
/// `chain_anchor_id` for forward compatibility with Phase T.5, but
/// round 1 leaves them NULL. Same accepted-risk pattern as V.2's
/// `agent_trace_event` (derived/operator-attestation rows are
/// detectably tampered by re-deriving from upstream sources). Round
/// 2 of V.6 will integrate the chain hashes once T.5's contract is
/// extended to operator-authored evidence rows.
final class AnnotationStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Idempotent — Migration v9 owns the canonical schema. This method
    /// stays so the store init pattern matches the other stores (every
    /// store calls `setupSchema()` after construction).
    func setupSchema() {
        parent.queue.sync {
            execSilent("""
                CREATE TABLE IF NOT EXISTS annotations (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    target_kind     TEXT NOT NULL,
                    target_id       TEXT NOT NULL,
                    range_start     INTEGER NOT NULL,
                    range_end       INTEGER NOT NULL,
                    verdict         TEXT NOT NULL,
                    notes           TEXT,
                    authored_by     TEXT NOT NULL,
                    authorship      TEXT NOT NULL,
                    created_at      REAL NOT NULL,
                    prev_hash       TEXT,
                    entry_hash      TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_annotations_target ON annotations(target_kind, target_id, created_at DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_annotations_verdict ON annotations(verdict, created_at DESC);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_annotations_authorship ON annotations(authorship);")
        }
    }

    // MARK: - Writes

    /// Insert one annotation row. Returns the new rowid, or -1 on
    /// failure. Range invariant: `range_end >= range_start`. Caller-
    /// validated; the store records the row as given (Karpathy: stay
    /// dumb at the storage layer).
    @discardableResult
    func record(_ annotation: Annotation) -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return -1 }
            let sql = """
                INSERT INTO annotations
                    (target_kind, target_id, range_start, range_end,
                     verdict, notes, authored_by, authorship, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (annotation.targetKind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (annotation.targetId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(annotation.rangeStart))
            sqlite3_bind_int64(stmt, 4, Int64(annotation.rangeEnd))
            sqlite3_bind_text(stmt, 5, (annotation.verdict.rawValue as NSString).utf8String, -1, nil)
            Self.bindOptionalText(stmt, 6, annotation.notes)
            sqlite3_bind_text(stmt, 7, (annotation.authoredBy as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 8, (annotation.authorship.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 9, annotation.createdAt.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Move every annotation pointing at `(kind, fromId)` to
    /// `(kind, toId)`. Returns the number of rows updated. The
    /// operator wires this into their rename / fork flow so the
    /// annotation lineage survives the artifact moving.
    @discardableResult
    func renameTarget(kind: AnnotationTargetKind, fromId: String, toId: String) -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = """
                UPDATE annotations
                   SET target_id = ?
                 WHERE target_kind = ? AND target_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (toId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (kind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (fromId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Reads

    func count() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM annotations;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// All annotations on a given target, newest first.
    func byTarget(kind: AnnotationTargetKind, id: String) -> [Annotation] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, target_kind, target_id, range_start, range_end,
                       verdict, notes, authored_by, authorship, created_at
                FROM annotations
                WHERE target_kind = ? AND target_id = ?
                ORDER BY created_at DESC, id DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (kind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            return Self.collect(stmt)
        }
    }

    /// Most recent N annotations across all targets.
    func recent(limit: Int = 50) -> [Annotation] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, target_kind, target_id, range_start, range_end,
                       verdict, notes, authored_by, authorship, created_at
                FROM annotations
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, limit)))
            return Self.collect(stmt)
        }
    }

    /// Per-(kind, target) verdict rollup. Round 1's analytic primitive
    /// — CompoundLearning Analyze surfaces these so a skill / KB entry
    /// with N `fails` annotations bubbles up.
    func verdictRollup(targetKind: AnnotationTargetKind? = nil) -> [AnnotationVerdictRollup] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT target_kind, target_id,
                       SUM(CASE WHEN verdict = 'works' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN verdict = 'fails' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN verdict = 'note'  THEN 1 ELSE 0 END),
                       MAX(created_at)
                FROM annotations
                """
            if targetKind != nil { sql += " WHERE target_kind = ?" }
            sql += " GROUP BY target_kind, target_id ORDER BY 4 DESC, 5 DESC, 6 DESC;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let kind = targetKind {
                sqlite3_bind_text(stmt, 1, (kind.rawValue as NSString).utf8String, -1, nil)
            }

            var out: [AnnotationVerdictRollup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let kindRaw = String(cString: sqlite3_column_text(stmt, 0))
                guard let kind = AnnotationTargetKind(rawValue: kindRaw) else { continue }
                out.append(AnnotationVerdictRollup(
                    targetKind: kind,
                    targetId: String(cString: sqlite3_column_text(stmt, 1)),
                    worksCount: Int(sqlite3_column_int64(stmt, 2)),
                    failsCount: Int(sqlite3_column_int64(stmt, 3)),
                    noteCount: Int(sqlite3_column_int64(stmt, 4)),
                    lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                ))
            }
            return out
        }
    }

    // MARK: - Helpers

    private static func collect(_ stmt: OpaquePointer?) -> [Annotation] {
        var out: [Annotation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kindRaw = String(cString: sqlite3_column_text(stmt, 1))
            let verdictRaw = String(cString: sqlite3_column_text(stmt, 5))
            let authorshipRaw = String(cString: sqlite3_column_text(stmt, 8))
            guard
                let kind = AnnotationTargetKind(rawValue: kindRaw),
                let verdict = AnnotationVerdict(rawValue: verdictRaw),
                let authorship = AuthorshipTag(rawValue: authorshipRaw)
            else { continue }
            let notes: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 6))
            out.append(Annotation(
                id: sqlite3_column_int64(stmt, 0),
                targetKind: kind,
                targetId: String(cString: sqlite3_column_text(stmt, 2)),
                rangeStart: Int(sqlite3_column_int64(stmt, 3)),
                rangeEnd: Int(sqlite3_column_int64(stmt, 4)),
                verdict: verdict,
                notes: notes,
                authoredBy: String(cString: sqlite3_column_text(stmt, 7)),
                authorship: authorship,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
            ))
        }
        return out
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func execSilent(_ sql: String) {
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}

// MARK: - Public model

/// The kind of artifact an annotation targets. Persisted by rawValue;
/// renaming a case is a schema break (older rows decode-fail and are
/// skipped by `byTarget` / `recent`).
public enum AnnotationTargetKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// A skill manifest (HandManifest fixture id, skill_md path, etc.).
    case skill
    /// A `knowledge_entities` row (target_id is the entity name).
    case kbEntity = "kb-entity"
}

/// What the operator is asserting about the targeted range. Append-
/// only — a new annotation supersedes by recency, never by mutation.
public enum AnnotationVerdict: String, Sendable, Codable, Equatable, CaseIterable {
    /// This range is doing what the operator wants.
    case works
    /// This range is broken / incorrect / harmful.
    case fails
    /// Free-form observation, not a pass/fail call.
    case note
}

/// One row of the `annotations` table.
public struct Annotation: Sendable, Equatable {
    /// Database rowid; -1 before insert.
    public let id: Int64
    public let targetKind: AnnotationTargetKind
    public let targetId: String
    /// Inclusive byte/character offset into the target's serialized form.
    public let rangeStart: Int
    /// Inclusive end offset. `rangeEnd >= rangeStart` is a caller
    /// invariant; the store records whatever it gets.
    public let rangeEnd: Int
    public let verdict: AnnotationVerdict
    /// Optional free-text note. May be NULL on disk.
    public let notes: String?
    /// Free-text identifier of who tagged the row (operator handle,
    /// "agent:senkani", etc.). The `authorship` tag is the policy
    /// dimension; `authoredBy` is the human-readable label.
    public let authoredBy: String
    /// V.5 provenance tag — explicit by construction. `.unset` is the
    /// "must tag before policy reads it" state; the V.5 prompt
    /// resolver fills it before write at the UI layer.
    public let authorship: AuthorshipTag
    public let createdAt: Date

    public init(
        id: Int64 = -1,
        targetKind: AnnotationTargetKind,
        targetId: String,
        rangeStart: Int,
        rangeEnd: Int,
        verdict: AnnotationVerdict,
        notes: String? = nil,
        authoredBy: String,
        authorship: AuthorshipTag,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetKind = targetKind
        self.targetId = targetId
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.verdict = verdict
        self.notes = notes
        self.authoredBy = authoredBy
        self.authorship = authorship
        self.createdAt = createdAt
    }
}

/// Aggregated counts for the (kind, target) tuple — the read shape
/// CompoundLearning Analyze consumes.
public struct AnnotationVerdictRollup: Sendable, Equatable {
    public let targetKind: AnnotationTargetKind
    public let targetId: String
    public let worksCount: Int
    public let failsCount: Int
    public let noteCount: Int
    public let lastSeenAt: Date

    public var totalCount: Int { worksCount + failsCount + noteCount }
}
