import Foundation
import SQLite3

/// A single schema migration. Future migrations APPEND to `MigrationRegistry.all`
/// with incrementing `version`. Never modify a migration that has shipped — migrations
/// are idempotent by transaction wrapping, not by rewriting history.
public struct Migration: Sendable {
    public let version: Int
    public let description: String
    public let up: @Sendable (OpaquePointer) throws -> Void

    public init(
        version: Int,
        description: String,
        up: @escaping @Sendable (OpaquePointer) throws -> Void
    ) {
        self.version = version
        self.description = description
        self.up = up
    }
}

/// Registry of schema migrations in version order.
///
/// Version 1 is the historical "baseline" — the schema shape that existed immediately
/// before `schema_migrations` was introduced. Fresh DBs reach version 1 via
/// `SessionDatabase.createTables()` + `execSilent` ALTERs; existing DBs are already
/// at version 1 and are stamped by the baselining pass.
///
/// Future migrations add entries here with version 2, 3, ....
public enum MigrationRegistry {
    public static let all: [Migration] = [
        Migration(version: 1, description: "initial schema baseline") { _ in
            // No-op: for fresh DBs, createTables() + execSilent ALTERs already
            // produced the version-1 shape. For pre-existing DBs, the baselining
            // pass stamps this as applied without re-running `up`.
        },
        Migration(version: 2, description: "event_counters for security + observability") { db in
            // Observability wave: incrementing counters for every defense
            // site (injection detections, SSRF blocks, retention pruning,
            // migrations applied, socket handshake rejections, command
            // redactions). Queryable via SessionDatabase.eventCounts and
            // surfaced through senkani_session stats + senkani stats
            // --security. project_root is "" for process-global events
            // that aren't tied to a project (e.g. socket handshake).
            let sql = """
                CREATE TABLE IF NOT EXISTS event_counters (
                    project_root TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    count INTEGER NOT NULL DEFAULT 0,
                    first_seen_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    PRIMARY KEY (project_root, event_type)
                );
                CREATE INDEX IF NOT EXISTS idx_event_counters_type
                    ON event_counters(event_type);
                """
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err = err { sqlite3_free(err) }
            guard rc == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "v2", detail: msg)
            }
        },
        Migration(version: 3, description: "validation delivery outcome metadata") { db in
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v3", detail: msg)
            }

            // Migration tests exercise the runner directly against historical
            // partial schemas, so this migration must be self-contained rather
            // than assuming SessionDatabase.createValidationResultsTable ran.
            try exec("""
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
            try exec("ALTER TABLE validation_results ADD COLUMN outcome TEXT NOT NULL DEFAULT 'advisory';", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN reason TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN surfaced_at REAL;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_validation_session_outcome_surface ON validation_results(session_id, outcome, surfaced_at);")
        },
        Migration(version: 4, description: "tamper-evident audit chain (Phase T.5 round 1, token_events)") { db in
            // Round 1 of Phase T.5 — the tamper-evident audit chain. See
            // `spec/architecture.md` → "Tamper-Evident Audit Chain (Phase T.5)"
            // for the full design + multi-round rollout.
            //
            // Round 1 ships the additive schema + a fresh anchor for existing
            // rows. The write path is NOT yet patched — the three new columns
            // are nullable and default to NULL. Existing rows get a single
            // anchor row in `chain_anchors` (reason='migration-v4') and a
            // `chain_anchor_id` pointing at it; their `prev_hash` and
            // `entry_hash` stay NULL because we deliberately do not fabricate
            // hashes for history we cannot verify (anchor-from-now). Round 2
            // (write-path integration) starts producing real hashes for new
            // inserts; verification walks rows from the anchor's first
            // hashed row forward, so the anchor itself doesn't have to verify.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v4", detail: msg)
            }

            // chain_anchors — one row per chain segment. Reason values:
            //   'fresh-install'   — DB created on a v4+ codebase, no prior history
            //   'migration-v4'    — pre-T.5 rows folded under a single anchor at upgrade time
            //   'repair-<rowid>'  — `senkani doctor --repair-chain` opened a new segment (round 4)
            try exec("""
                CREATE TABLE IF NOT EXISTS chain_anchors (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    table_name TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    started_at_rowid INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    operator_note TEXT
                );
                """)
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_chain_anchors_table
                    ON chain_anchors(table_name, id);
                """)

            // Migration tests exercise the runner directly against historical
            // partial schemas, so this migration must be self-contained rather
            // than assuming `TokenEventStore.setupSchema` ran. Same pattern as
            // v3 for `validation_results`.
            try exec("""
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

            // Schema additions on token_events. ALTERs are guarded so a
            // partially-applied migration on a manually-recovered DB doesn't
            // hard-fail — same convention as v3.
            try exec("ALTER TABLE token_events ADD COLUMN prev_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN entry_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN chain_anchor_id INTEGER;", allowDuplicateColumn: true)
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_token_events_anchor
                    ON token_events(chain_anchor_id, id);
                """)

            // Open the migration anchor — only if `token_events` has any
            // existing rows (a fresh DB will get its 'fresh-install' anchor
            // lazily when the first row is written in round 2). The MAX(id)
            // is used as `started_at_rowid` so verification round 2+ knows
            // "rows up to here predate the chain; rows after this rowid must
            // verify."
            var stmt: OpaquePointer?
            let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
            guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "v4 count", detail: String(cString: sqlite3_errmsg(db)))
            }
            var rowCount: Int64 = 0
            var maxRowid: Int64 = 0
            if sqlite3_step(stmt) == SQLITE_ROW {
                rowCount = sqlite3_column_int64(stmt, 0)
                maxRowid = sqlite3_column_int64(stmt, 1)
            }
            sqlite3_finalize(stmt)

            if rowCount > 0 {
                let now = Date().timeIntervalSince1970
                let insertSQL = """
                    INSERT INTO chain_anchors
                        (table_name, started_at, started_at_rowid, reason, operator_note)
                    VALUES ('token_events', ?, ?, 'migration-v4', NULL);
                """
                guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                    throw MigrationError.sqlFailed(stage: "v4 anchor insert", detail: String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_bind_double(stmt, 1, now)
                sqlite3_bind_int64(stmt, 2, maxRowid)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    sqlite3_finalize(stmt)
                    throw MigrationError.sqlFailed(stage: "v4 anchor step", detail: String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_finalize(stmt)

                let anchorId = sqlite3_last_insert_rowid(db)
                // Backfill: every existing token_events row gets `chain_anchor_id`
                // pointing at the migration-v4 anchor; `prev_hash` and
                // `entry_hash` stay NULL by design.
                let backfillSQL = """
                    UPDATE token_events
                       SET chain_anchor_id = \(anchorId)
                     WHERE chain_anchor_id IS NULL;
                """
                try exec(backfillSQL)
            }
        },
        Migration(version: 5, description: "tamper-evident audit chain (Phase T.5 round 3, three remaining tables)") { db in
            // Round 3 of Phase T.5 — extends the chain to validation_results,
            // sandboxed_results, and commands. Same anchor-from-now strategy
            // as v4 (per-table 'migration-v5' anchors for backfilled history;
            // round 3+ writes get real hashes and verify against the same
            // anchor with rowid > started_at_rowid).
            //
            // Identical idempotency guarantees as v4: ALTERs allow duplicate
            // columns, table CREATEs are guarded, anchor inserts only fire
            // when there's history to anchor.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v5", detail: msg)
            }

            // For each table: ensure schema exists (self-contained per the
            // v3/v4 pattern), add three chain columns, add index, anchor
            // existing rows under a per-table 'migration-v5' anchor.
            //
            // We also accept that the per-table primary-key column may not be
            // 'id' — sandboxed_results uses a TEXT PRIMARY KEY. The chain
            // mechanics don't need a numeric id; what matters is that
            // started_at_rowid bounds verification, and for sandboxed_results
            // we use the anchor row id itself as the boundary marker instead
            // of the table's PK.

            // ----- validation_results -----
            try exec("""
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
            try exec("ALTER TABLE validation_results ADD COLUMN prev_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN entry_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN chain_anchor_id INTEGER;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_validation_results_anchor ON validation_results(chain_anchor_id, id);")

            // ----- sandboxed_results -----
            try exec("""
                CREATE TABLE IF NOT EXISTS sandboxed_results (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    command TEXT NOT NULL,
                    full_output TEXT NOT NULL,
                    line_count INTEGER NOT NULL,
                    byte_count INTEGER NOT NULL
                );
            """)
            try exec("ALTER TABLE sandboxed_results ADD COLUMN prev_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE sandboxed_results ADD COLUMN entry_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE sandboxed_results ADD COLUMN chain_anchor_id INTEGER;", allowDuplicateColumn: true)
            // sandboxed_results.id is TEXT — we index on (chain_anchor_id, created_at)
            // which is monotonic-enough for verification ordering.
            try exec("CREATE INDEX IF NOT EXISTS idx_sandboxed_results_anchor ON sandboxed_results(chain_anchor_id, created_at);")

            // ----- commands -----
            // The full commands table has more columns added by historical
            // ALTERs (budget_decision); the CREATE TABLE here matches the
            // baseline shape, then the chain ALTERs add three more.
            try exec("""
                CREATE TABLE IF NOT EXISTS commands (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    timestamp REAL NOT NULL,
                    tool_name TEXT NOT NULL,
                    command TEXT,
                    raw_bytes INTEGER NOT NULL,
                    compressed_bytes INTEGER NOT NULL,
                    feature TEXT,
                    output_preview TEXT
                );
            """)
            try exec("ALTER TABLE commands ADD COLUMN prev_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE commands ADD COLUMN entry_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE commands ADD COLUMN chain_anchor_id INTEGER;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_commands_anchor ON commands(chain_anchor_id, id);")

            // Backfill anchors for each table that has rows.
            try anchorBackfill(db: db, table: "validation_results", rowidColumn: "id")
            try anchorBackfillSandboxedResults(db: db)
            try anchorBackfill(db: db, table: "commands", rowidColumn: "id")
        },
        Migration(version: 6, description: "pane_refresh_state for V.1 round 2 (Dashboard tile persistence)") { db in
            // V.1 round 2 — persist `PaneRefreshState` per (project_root, tile_id)
            // so Dashboard tiles survive app restart. Append-only by design: each
            // `applyOutcome` writes a new row; rehydration takes the row with
            // MAX(id) per tile. Append-only is also what the chain primitives
            // need — no UPDATEs that would invalidate `entry_hash`.
            //
            // Schema includes the three chain columns (`prev_hash`, `entry_hash`,
            // `chain_anchor_id`) so writes go through the same `ChainHasher` /
            // `ChainState` path as `token_events`. Idempotency: ALTERs allow
            // duplicate columns; the CREATE TABLE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v6", detail: msg)
            }

            try exec("""
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
            // Latest-per-tile lookup is the rehydration hot path; index covers it.
            try exec("CREATE INDEX IF NOT EXISTS idx_pane_refresh_state_latest ON pane_refresh_state(project_root, tile_id, id DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_pane_refresh_state_anchor ON pane_refresh_state(chain_anchor_id, id);")

            // No backfill — table is brand new this migration.
        },
        Migration(version: 7, description: "authorship column on knowledge_entities (Phase V.5 round 1)") { db in
            // Phase V.5 round 1 — see `spec/roadmap.md` row "V.5 —
            // `AuthorshipTracker`" and Gebru's red flag in the synthesis.
            // Adds an explicit provenance column to KB entity rows. NULL
            // is the legacy/never-written state; new inserts always
            // carry one of the four `AuthorshipTag` rawValues
            // (`ai-authored`, `human-authored`, `mixed`, `unset`).
            //
            // NULL is NOT silently equivalent to any tag value. The
            // V.5b UI surface checks for `.unset` (explicit) and for
            // NULL (legacy) and prompts the operator in both cases —
            // the round 1 contract is purely additive schema + write-
            // path plumbing.
            //
            // Idempotency: the ALTER guards on duplicate-column the
            // same way as v3/v4/v5, so a partially-applied migration
            // recovers cleanly. No backfill — existing rows stay
            // NULL until V.5c lands the bulk-tag CLI.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v7", detail: msg)
            }

            // Self-contained CREATE matches the v3/v4/v5 convention:
            // migration tests exercise the runner against historical
            // partial schemas, so we cannot assume EntityStore.setupSchema
            // ran first. Column shape mirrors EntityStore.swift.
            try exec("""
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
            try exec("ALTER TABLE knowledge_entities ADD COLUMN authorship TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_knowledge_entities_authorship ON knowledge_entities(authorship);")
        },
        Migration(version: 8, description: "agent_trace_event canonical row + idempotency keys (Phase V.2)") { db in
            // Phase V.2 — Stripe-style accumulator. Every tool call writes
            // exactly one wide row at completion time, carrying every
            // dimension a query would otherwise stitch from raw `token_events`.
            //
            // `idempotency_key` is UNIQUE; the write path uses
            // `INSERT ... ON CONFLICT(idempotency_key) DO NOTHING`, so a
            // safe retry from the call site lands one row, not two.
            //
            // The canonical row is *derived* from inputs that are themselves
            // chain-anchored (token_events). It is not chain-anchored itself
            // — accepted risk. Tampering the canonical row is detectable by
            // re-deriving from the chain-anchored sources.
            //
            // Conformed dimensions (documented in `spec/architecture.md`
            // → "Canonical Trace Rows"):
            //   pane, project, model, tier, feature, result
            // The `tier` column is populated by U.1 (TierScorer) once that
            // round lands; until then it is NULL.
            //
            // Idempotency: ALTERs guard duplicate column the same way as
            // v3/v4/v5/v7. The CREATE TABLE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v8", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS agent_trace_event (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    idempotency_key       TEXT NOT NULL UNIQUE,
                    pane                  TEXT,
                    project               TEXT,
                    model                 TEXT,
                    tier                  TEXT,
                    feature               TEXT,
                    result                TEXT NOT NULL,
                    started_at            REAL NOT NULL,
                    completed_at          REAL NOT NULL,
                    latency_ms            INTEGER NOT NULL DEFAULT 0,
                    tokens_in             INTEGER NOT NULL DEFAULT 0,
                    tokens_out            INTEGER NOT NULL DEFAULT 0,
                    cost_cents            INTEGER NOT NULL DEFAULT 0,
                    redaction_count       INTEGER NOT NULL DEFAULT 0,
                    validation_status     TEXT,
                    confirmation_required INTEGER NOT NULL DEFAULT 0,
                    egress_decisions      INTEGER NOT NULL DEFAULT 0
                );
            """)
            // Pivots run by (project, started_at), (pane, started_at),
            // (feature, started_at). Indexes match the three pivot helpers.
            try exec("CREATE INDEX IF NOT EXISTS idx_agent_trace_project_started ON agent_trace_event(project, started_at);")
            try exec("CREATE INDEX IF NOT EXISTS idx_agent_trace_pane_started ON agent_trace_event(pane, started_at);")
            try exec("CREATE INDEX IF NOT EXISTS idx_agent_trace_feature_started ON agent_trace_event(feature, started_at);")
        },
        Migration(version: 9, description: "annotations table for V.6 round 1 (operator-tagged verdict rows)") { db in
            // Phase V.6 round 1 — `AnnotationStore`. One row per
            // operator-tagged segment of a skill or KB entity, with
            // verdict (works/fails/note), range, optional notes, and
            // V.5 authorship. See `spec/roadmap.md` row "V.6 —
            // `AnnotationSystem`" and the round-1 audit synthesis.
            //
            // Schema includes the three chain columns nullable + the
            // `_anchor` index so V.6 round 2 can integrate the audit
            // chain without a second migration. Round 1 leaves them
            // NULL — same accepted-risk pattern as V.2's
            // `agent_trace_event` (operator-attestation rows are
            // detectably tampered downstream by re-deriving from the
            // operator's evidence).
            //
            // Idempotency: ALTERs guard duplicate-column the same way
            // as v3/v4/v5/v7/v8; the CREATE TABLE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v9", detail: msg)
            }

            try exec("""
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
            try exec("CREATE INDEX IF NOT EXISTS idx_annotations_target ON annotations(target_kind, target_id, created_at DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_annotations_verdict ON annotations(verdict, created_at DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_annotations_authorship ON annotations(authorship);")
            try exec("CREATE INDEX IF NOT EXISTS idx_annotations_anchor ON annotations(chain_anchor_id, id);")
        },
        Migration(version: 10, description: "ladder_position on agent_trace_event (Phase U.1b)") { db in
            // Phase U.1b — pair the existing `tier` column with
            // `ladder_position` so the U.1c analytics chart can split
            // "primary rung used" from "first fallback used" from
            // "synthesized fallback". Forward-only: pre-migration rows
            // get NULL and stay NULL — historical traces predate the
            // FallbackLadder concept and have no defensible value to
            // backfill.
            //
            // Idempotency: ALTER guards duplicate column the same way
            // as v3/v4/v5/v7/v8/v9.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v10", detail: msg)
            }
            try exec("ALTER TABLE agent_trace_event ADD COLUMN ladder_position INTEGER;",
                     allowDuplicateColumn: true)
        },
        Migration(version: 11, description: "confirmations table for T.6a ConfirmationGate") { db in
            // Phase T.6a round 1 — append-only confirmations log. Every
            // write/exec-tagged tool call walks ConfirmationGate, which
            // writes one row here describing the decision (`approve` /
            // `deny` / `auto`) and who decided it (`operator` /
            // `policy` / `auto`). Chained via the T.5 audit chain so
            // post-hoc tampering with the decision log is detectable.
            //
            // Idempotency: ALTER guards duplicate column the same way
            // as v3/v4/v5/v7/v8/v9/v10. The CREATE TABLE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v11", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS confirmations (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    tool_name       TEXT NOT NULL,
                    requested_at    REAL NOT NULL,
                    decided_at      REAL NOT NULL,
                    decision        TEXT NOT NULL,
                    decided_by      TEXT NOT NULL,
                    reason          TEXT,
                    prev_hash       TEXT,
                    entry_hash      TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_confirmations_tool ON confirmations(tool_name, requested_at DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_confirmations_decision ON confirmations(decision, requested_at DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_confirmations_anchor ON confirmations(chain_anchor_id, id);")

            // No backfill — table is brand new this migration.
        },
        Migration(version: 12, description: "trust_audits table for U.4a soft-flag scaffolding") { db in
            // Phase U.4a round 1 — append-only log of FragmentationDetector
            // soft flags + operator FP/TP labels. Two row kinds:
            //   - kind='flag' rows are emitted by the detector. flag_id NULL.
            //   - kind='label' rows reference a flag's rowid via flag_id and
            //     carry 'fp' or 'tp' in label.
            // Chained via T.5 the same way confirmations is — tampering with
            // a label row is detectable. Append-only: re-labelling writes a
            // NEW row, never mutates an existing one.
            //
            // Idempotency: CREATE TABLE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v12", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS trust_audits (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind              TEXT NOT NULL,
                    created_at        REAL NOT NULL,
                    session_id        TEXT,
                    pane_id           TEXT,
                    tool_name         TEXT,
                    reason            TEXT,
                    score             INTEGER,
                    correlation_count INTEGER,
                    flag_id           INTEGER,
                    label             TEXT,
                    labeled_by        TEXT,
                    prev_hash         TEXT,
                    entry_hash        TEXT,
                    chain_anchor_id   INTEGER
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_trust_audits_kind_time ON trust_audits(kind, created_at DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_trust_audits_flag ON trust_audits(flag_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_trust_audits_session ON trust_audits(session_id, created_at DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_trust_audits_anchor ON trust_audits(chain_anchor_id, id);")

            // No backfill — table is brand new this migration.
        },
        Migration(version: 13, description: "annotation_rate_cap_log for V.12b severity rate cap") { db in
            // Phase V.12b — rate-cap log for must-fix annotation floods
            // emitted by HookRouter. One row per closed window in which
            // at least one annotation was suppressed. Not chain-hashed:
            // the row is a derived flood marker, not load-bearing
            // evidence — the source denials are already recorded in
            // hook_events / token_events / commands.
            //
            // Idempotent: CREATE TABLE is guarded.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                throw MigrationError.sqlFailed(stage: "v13", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS annotation_rate_cap_log (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    window_start     REAL NOT NULL,
                    window_end       REAL NOT NULL,
                    severity         TEXT NOT NULL,
                    suppressed_count INTEGER NOT NULL,
                    threshold        INTEGER NOT NULL,
                    created_at       REAL NOT NULL
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_annotation_rate_cap_window ON annotation_rate_cap_log(window_start DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_annotation_rate_cap_severity ON annotation_rate_cap_log(severity, created_at DESC);")
        },
        Migration(version: 14, description: "context_plans table + agent_trace_event.plan_id (Phase U.6a)") { db in
            // Phase U.6a — first slice of the context-orchestration split.
            // Introduces `context_plans` (one row per combinator-emitted
            // plan) and a nullable `plan_id` foreign-key column on
            // `agent_trace_event` so plan and actual are paired.
            //
            // Forward-only and purely additive: pre-migration trace rows
            // get NULL `plan_id` and stay NULL — non-combinator paths in
            // U.6b will also write NULL. The FK is declared via
            // `REFERENCES context_plans(id)` for documented intent
            // (matches the `commands.session_id REFERENCES sessions(id)`
            // convention); SQLite `PRAGMA foreign_keys` stays at its
            // default (off) so this migration cannot regress unrelated
            // tables. Tampering is detectable downstream by re-deriving
            // from the chain-anchored sources.
            //
            // Idempotency: ALTERs guard duplicate column the same way as
            // v3/v4/v5/v7/v8/v9/v10. The CREATE TABLE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v14", detail: msg)
            }

            // Migration tests exercise the runner directly against historical
            // partial schemas, so this migration must be self-contained
            // rather than assuming `ContextPlanStore.setupSchema` ran. Same
            // pattern as v3 for `validation_results` and v8 for
            // `agent_trace_event`.
            try exec("""
                CREATE TABLE IF NOT EXISTS context_plans (
                    id              TEXT PRIMARY KEY,
                    session_id      TEXT NOT NULL,
                    planned_fanout  INTEGER NOT NULL,
                    leaf_size       INTEGER NOT NULL,
                    reducer_choice  TEXT NOT NULL,
                    estimated_cost  INTEGER NOT NULL,
                    created_at      REAL NOT NULL
                );
            """)
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_context_plans_session
                    ON context_plans(session_id, created_at DESC);
            """)

            // Self-contained CREATE for `agent_trace_event` matches the
            // v8 baseline shape so v14 can run against a DB that was
            // dropped in at any post-v8 state. The plan_id ALTER below
            // adds the column on the existing or freshly-created table.
            try exec("""
                CREATE TABLE IF NOT EXISTS agent_trace_event (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    idempotency_key       TEXT NOT NULL UNIQUE,
                    pane                  TEXT,
                    project               TEXT,
                    model                 TEXT,
                    tier                  TEXT,
                    feature               TEXT,
                    result                TEXT NOT NULL,
                    started_at            REAL NOT NULL,
                    completed_at          REAL NOT NULL,
                    latency_ms            INTEGER NOT NULL DEFAULT 0,
                    tokens_in             INTEGER NOT NULL DEFAULT 0,
                    tokens_out            INTEGER NOT NULL DEFAULT 0,
                    cost_cents            INTEGER NOT NULL DEFAULT 0,
                    redaction_count       INTEGER NOT NULL DEFAULT 0,
                    validation_status     TEXT,
                    confirmation_required INTEGER NOT NULL DEFAULT 0,
                    egress_decisions      INTEGER NOT NULL DEFAULT 0
                );
            """)
            try exec("ALTER TABLE agent_trace_event ADD COLUMN plan_id TEXT REFERENCES context_plans(id);",
                     allowDuplicateColumn: true)
        },
        Migration(version: 15, description: "policy_snapshots table (per-session PolicyConfig capture)") { db in
            // Policy-snapshot prerequisite for counterfactual replay.
            // One row per (session, distinct policy) pair, captured at
            // session start. The (session_id, policy_hash) UNIQUE
            // constraint dedups re-captures of the same configuration
            // within a session so chatty bootstrap paths don't bloat
            // the table.
            //
            // Forward-only and additive. Pre-migration sessions get no
            // snapshot row; reads fall back to "policy unknown" rather
            // than fabricating one.
            //
            // Idempotency: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF
            // NOT EXISTS — no ALTERs.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                throw MigrationError.sqlFailed(stage: "v15", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS policy_snapshots (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id   TEXT NOT NULL REFERENCES sessions(id),
                    captured_at  REAL NOT NULL,
                    policy_hash  TEXT NOT NULL,
                    policy_json  TEXT NOT NULL,
                    UNIQUE(session_id, policy_hash)
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_policy_snapshots_session ON policy_snapshots(session_id, captured_at DESC);")
        },
        Migration(version: 16, description: "cost_ledger_version on agent_trace_event (versioned cost lookup)") { db in
            // Stamps every new agent_trace_event row with the cost-
            // ledger version it was priced under. Without this, future
            // rate changes silently rebase historical cost numbers
            // because pricing today is computed at display time from
            // ModelPricing.swift constants. Pre-migration rows get NULL
            // — readers fall back to the current ledger and tag the
            // resulting cost as `estimated` per the confidence-tier
            // discipline.
            //
            // Idempotency: ALTER TABLE ... ADD COLUMN guarded the same
            // way as v3/v4/v5/v7/v8/v9/v10/v14.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v16", detail: msg)
            }

            // Self-contained CREATE for agent_trace_event matches the
            // post-v8 / v10 / v14 baseline so v16 can run against a DB
            // dropped in at any later state.
            try exec("""
                CREATE TABLE IF NOT EXISTS agent_trace_event (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    idempotency_key       TEXT NOT NULL UNIQUE,
                    pane                  TEXT,
                    project               TEXT,
                    model                 TEXT,
                    tier                  TEXT,
                    feature               TEXT,
                    result                TEXT NOT NULL,
                    started_at            REAL NOT NULL,
                    completed_at          REAL NOT NULL,
                    latency_ms            INTEGER NOT NULL DEFAULT 0,
                    tokens_in             INTEGER NOT NULL DEFAULT 0,
                    tokens_out            INTEGER NOT NULL DEFAULT 0,
                    cost_cents            INTEGER NOT NULL DEFAULT 0,
                    redaction_count       INTEGER NOT NULL DEFAULT 0,
                    validation_status     TEXT,
                    confirmation_required INTEGER NOT NULL DEFAULT 0,
                    egress_decisions      INTEGER NOT NULL DEFAULT 0
                );
            """)
            try exec("ALTER TABLE agent_trace_event ADD COLUMN cost_ledger_version INTEGER;",
                     allowDuplicateColumn: true)
        },
        Migration(version: 17, description: "policy_snapshots chain-anchoring (Phase T.5 extension)") { db in
            // policy_snapshots is the load-bearing record of "what
            // configuration was active when this session ran."
            // Counterfactual replay reports cite it as the audit
            // baseline. Without chain anchoring, a write-capable
            // attacker can rewrite a snapshot row post-hoc and the
            // replay surface silently lies about the baseline.
            //
            // v17 adds the same three chain columns the rest of the
            // chain participants carry (`prev_hash`, `entry_hash`,
            // `chain_anchor_id`), opens a `migration-v17` anchor
            // covering existing rows (anchor-from-now — predecessor
            // rows keep NULL hashes), and indexes the anchor. New
            // writes go through ChainHasher / ChainState in the same
            // shape as ConfirmationStore.
            //
            // Idempotency: ALTER guards on duplicate column the same
            // way as v3/v4/v5/v7/v8/v9/v10/v14/v16. CREATE is guarded.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v17", detail: msg)
            }

            // Self-contained CREATE matches the v3/v4/v5/v15 convention
            // so v17 can run against a DB dropped in at any later state.
            try exec("""
                CREATE TABLE IF NOT EXISTS policy_snapshots (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id   TEXT NOT NULL REFERENCES sessions(id),
                    captured_at  REAL NOT NULL,
                    policy_hash  TEXT NOT NULL,
                    policy_json  TEXT NOT NULL,
                    UNIQUE(session_id, policy_hash)
                );
            """)
            try exec("ALTER TABLE policy_snapshots ADD COLUMN prev_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE policy_snapshots ADD COLUMN entry_hash TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE policy_snapshots ADD COLUMN chain_anchor_id INTEGER;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_policy_snapshots_anchor ON policy_snapshots(chain_anchor_id, id);")

            // Anchor existing rows under a 'migration-v17' anchor so
            // post-migration writes verify cleanly while pre-migration
            // rows stay anchor-from-now (NULL hashes). Inlined rather
            // than reusing `anchorBackfill` because that helper hard-
            // codes `reason='migration-v5'`.
            var stmt: OpaquePointer?
            let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM policy_snapshots;"
            guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "v17 count", detail: String(cString: sqlite3_errmsg(db)))
            }
            var rowCount: Int64 = 0
            var maxRowid: Int64 = 0
            if sqlite3_step(stmt) == SQLITE_ROW {
                rowCount = sqlite3_column_int64(stmt, 0)
                maxRowid = sqlite3_column_int64(stmt, 1)
            }
            sqlite3_finalize(stmt)

            if rowCount > 0 {
                let now = Date().timeIntervalSince1970
                let insertSQL = """
                    INSERT INTO chain_anchors
                        (table_name, started_at, started_at_rowid, reason, operator_note)
                    VALUES ('policy_snapshots', ?, ?, 'migration-v17', NULL);
                """
                guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                    throw MigrationError.sqlFailed(stage: "v17 anchor insert", detail: String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_bind_double(stmt, 1, now)
                sqlite3_bind_int64(stmt, 2, maxRowid)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    sqlite3_finalize(stmt)
                    throw MigrationError.sqlFailed(stage: "v17 anchor step", detail: String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_finalize(stmt)
                let anchorId = sqlite3_last_insert_rowid(db)

                let backfillSQL = """
                    UPDATE policy_snapshots
                       SET chain_anchor_id = \(anchorId)
                     WHERE chain_anchor_id IS NULL;
                """
                try exec(backfillSQL)
            }
        },
        Migration(version: 18, description: "connection_id on commands + token_events (Phase B-ii multi-project session)") { db in
            // Phase B-ii — per-connection identity threaded through DB rows.
            // The MCP daemon mints a UUID at socket accept; that UUID rides
            // the dispatch path via `MCPSession.currentConnectionId` and now
            // lands on every `commands` and `token_events` row so per-
            // connection vs aggregate views are both reconstructible.
            //
            // Chain-hash compatibility: chain-era rows under the migration-
            // v5 (`commands`) and migration-v4 (`token_events`) anchors were
            // written WITHOUT `connection_id` in their canonical column map.
            // Adding it to the canonical shape across the board would break
            // their entry_hash verification. Instead we open a NEW anchor
            // (`migration-v18`) for each table with `started_at_rowid =
            // MAX(id)`. New writes register `connection_id` in the canonical
            // map and chain under the v18 anchor; legacy rows keep their
            // v5/v4 anchor + old canonical shape. `ChainVerifier` switches
            // canonical shape per-anchor via the anchor's `reason` field.
            //
            // Idempotency: ALTERs guard duplicate column the same way as
            // v3/v4/v5/v7/v8/v9/v10/v14/v16/v17. Anchor inserts only fire
            // when there's history to anchor.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v18", detail: msg)
            }

            // Self-contained CREATEs match the v3/v4/v5/v15 convention so
            // v18 can run against a DB dropped in at any later state.
            try exec("""
                CREATE TABLE IF NOT EXISTS commands (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    timestamp REAL NOT NULL,
                    tool_name TEXT NOT NULL,
                    command TEXT,
                    raw_bytes INTEGER NOT NULL,
                    compressed_bytes INTEGER NOT NULL,
                    feature TEXT,
                    output_preview TEXT
                );
            """)
            try exec("ALTER TABLE commands ADD COLUMN connection_id TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_commands_connection ON commands(connection_id);")

            try exec("""
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
            try exec("ALTER TABLE token_events ADD COLUMN connection_id TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_token_events_connection ON token_events(connection_id);")

            // Existing 'fresh-install' anchors for commands / token_events
            // were opened on a pre-v18 codebase; their rows were hashed
            // WITHOUT `connection_id` in the canonical column map. Rename
            // those to 'fresh-install-pre-v18' so writers and the verifier
            // can switch shapes per anchor. Post-v18 fresh installs (a
            // brand-new DB upgraded straight to this migration) get a fresh
            // 'fresh-install' anchor on first write, which uses the NEW
            // canonical (with connection_id) — that's the desired forward
            // behavior.
            try exec("""
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v18'
                 WHERE table_name IN ('commands', 'token_events')
                   AND reason = 'fresh-install';
            """)

            // Open per-table 'migration-v18' anchors so new writes use the
            // expanded canonical map without invalidating legacy chain-era
            // rows. The anchor opens only when the table has rows — fresh
            // DBs continue to lazy-create a 'fresh-install' anchor on first
            // write under the new canonical shape.
            try openConnectionIdAnchor(db: db, table: "commands")
            try openConnectionIdAnchor(db: db, table: "token_events")
        },
        Migration(version: 19, description: "egress_decisions chained table (Phase T.1a EgressProxy)") { db in
            // Phase T.1a — EgressProxy decision audit. Every allow/deny
            // emitted by the rule engine writes a chained row here so an
            // operator can inspect the policy timeline post-hoc and
            // `senkani doctor --verify-chain` proves no row was redacted.
            //
            // Design notes:
            //   - Self-contained CREATE so the migration runs against any
            //     legal historical state (matches v3/v4/v5/v17/v18).
            //   - `host` is the post-normalization host string the rule
            //     engine evaluated (not the raw CONNECT bytes), so the
            //     audit log is independently meaningful.
            //   - `decision` is one of `'allow' | 'deny'`. `rule_id` is
            //     stable string the rule producer guarantees; for the
            //     deny-on-miss default the writer emits `'default-deny'`.
            //   - `latency_us` is total time from the first byte the
            //     daemon read on this connection to the decision being
            //     emitted (the listener round T.1a.2 is what populates
            //     it; T.1a writes 0 for synthetic decisions emitted by
            //     unit tests, which is honest).
            //   - Chain columns mirror token_events (round 2): nullable
            //     prev_hash, entry_hash, chain_anchor_id; first write
            //     opens a 'fresh-install' anchor (no migration anchor
            //     here because the table is created empty by this
            //     migration — there is no history to anchor).
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v19", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS egress_decisions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    host TEXT NOT NULL,
                    method TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    rule_id TEXT NOT NULL,
                    latency_us INTEGER NOT NULL DEFAULT 0,
                    pane_id TEXT,
                    project_root TEXT,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_egress_decisions_anchor ON egress_decisions(chain_anchor_id, id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_egress_decisions_host ON egress_decisions(host);")
            try exec("CREATE INDEX IF NOT EXISTS idx_egress_decisions_time ON egress_decisions(timestamp);")
        },
        Migration(version: 20, description: "pack_audits chained table (Phase V.11a SkillPack)") { db in
            // Phase V.11a — SkillPack install/uninstall provenance. Every
            // `senkani pack install`, `pack uninstall`, and `--force`
            // override writes a chained row so the operator can replay
            // the install timeline post-hoc and `senkani doctor
            // verify-chain` proves no row was redacted.
            //
            // Same shape as v19 (egress_decisions): self-contained CREATE,
            // no migration anchor (table is created empty — first write
            // opens a 'fresh-install' anchor lazily via ChainState).
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v20", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS pack_audits (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pack_name TEXT NOT NULL,
                    pack_version TEXT NOT NULL,
                    event TEXT NOT NULL,
                    at REAL NOT NULL,
                    source_path TEXT NOT NULL,
                    sha256 TEXT,
                    applied_skills TEXT NOT NULL,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_pack_audits_anchor ON pack_audits(chain_anchor_id, id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_pack_audits_pack ON pack_audits(pack_name, id);")
        },
        Migration(version: 21, description: "claude_session_cursors PRIMARY KEY (path, reader) for two-reader split (claude-session-cursor-turn-index-ownership-conflict-2026-05-15)") { db in
            // Co-ownership fix per the 2026-05-15 scope-groom round. Two
            // readers write distinct turn_index semantics into the same
            // (path)-keyed row of `claude_session_cursors`:
            //   - ClaudeSessionTail (realtime watcher) writes turn_index=0
            //     because the watcher has no concept of turns.
            //   - ClaudeSessionReader.readNew writes turn_index
            //     incrementally per assistant turn.
            // Today readNew is exercised only by AgentTrackingTests; the
            // hazard ships the moment readNew is wired into a production
            // service. The structural fix is a composite PK so each writer
            // scopes to its own row. Migration 21 rebuilds the existing
            // table (SQLite cannot ALTER a PK in place); TokenEventStore.
            // setupSchema creates the new shape for fresh installs.
            //
            // The migration is idempotent: it no-ops on fresh installs
            // (table not yet created by setupSchema, which runs after
            // migrations) and on already-migrated DBs (reader column
            // already present). All existing rows backfill to
            // reader='watcher' — readNew is test-only today, and test
            // databases are torn down per case, so no live row belongs to
            // readNew yet.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                throw MigrationError.sqlFailed(stage: "v21", detail: msg)
            }

            // Probe: does the legacy table exist? Fresh installs haven't
            // created it yet (setupSchema runs after migrations); no-op.
            var probeStmt: OpaquePointer?
            let probeSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='claude_session_cursors' LIMIT 1;"
            guard sqlite3_prepare_v2(db, probeSQL, -1, &probeStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "v21 probe", detail: String(cString: sqlite3_errmsg(db)))
            }
            let tableExists = sqlite3_step(probeStmt) == SQLITE_ROW
            sqlite3_finalize(probeStmt)
            guard tableExists else { return }

            // Idempotency: if `reader` column is already present, the
            // rebuild already ran. Bail.
            var infoStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(claude_session_cursors);", -1, &infoStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(stage: "v21 table_info", detail: String(cString: sqlite3_errmsg(db)))
            }
            var hasReader = false
            while sqlite3_step(infoStmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(infoStmt, 1),
                   String(cString: c) == "reader" {
                    hasReader = true
                }
            }
            sqlite3_finalize(infoStmt)
            guard !hasReader else { return }

            // Standard SQLite recipe for ALTER-PRIMARY-KEY: create the
            // new-shape table under a temporary name, INSERT … SELECT
            // with reader='watcher' backfilled, DROP the old, RENAME the
            // new into place. No additional indexes exist on this table
            // (verified 2026-05-15), so the dance is short.
            try exec("""
                CREATE TABLE claude_session_cursors_v21 (
                    path TEXT NOT NULL,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    turn_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    reader TEXT NOT NULL DEFAULT 'watcher',
                    PRIMARY KEY (path, reader)
                );
            """)
            try exec("""
                INSERT INTO claude_session_cursors_v21 (path, byte_offset, turn_index, updated_at, reader)
                SELECT path, byte_offset, turn_index, updated_at, 'watcher' FROM claude_session_cursors;
            """)
            try exec("DROP TABLE claude_session_cursors;")
            try exec("ALTER TABLE claude_session_cursors_v21 RENAME TO claude_session_cursors;")
        },
        Migration(version: 22, description: "validation_results: U.2a-1 axes vocabulary + planner/runner result columns") { db in
            // U.2a-1 ships the durable runtime contract for ValidationAxes.
            // Five new columns extend `validation_results` so U.2a-2's
            // dispatch surface (MCP tool + CLI + axis assertion libraries)
            // can write structured browser-validation outcomes without
            // another migration. The columns:
            //
            //   axes             TEXT  NOT NULL DEFAULT '[]'  -- JSON array of ValidationAxes rawValues
            //   target_url       TEXT                          -- URL the plan ran against
            //   plan_steps       TEXT  NOT NULL DEFAULT '[]'  -- JSON array of ValidationStep records
            //   result_status    TEXT                          -- 'pass' | 'fail' | 'partial' (backfilled from outcome)
            //   screenshot_path  TEXT                          -- absolute path to captured screenshot
            //
            // The write-path (`ValidationStore.insertValidationResult`)
            // stays unchanged this round — these columns sit at their
            // defaults for new auto-validate rows until U.2a-2 wires the
            // structured-result writer. Chain hashing therefore stays on
            // the v3+v5 column set; no chain anchor needs to open here.
            // U.2a-2 will introduce a `migration-v22` anchor at MAX(id) so
            // post-v22 writes that DO include axes/target_url/plan_steps/
            // result_status/screenshot_path can hash under the new shape
            // while legacy rows verify under the old.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v22", detail: msg)
            }

            // SQLite cannot add NOT NULL columns without a DEFAULT to a
            // populated table; the two JSON-array columns default to '[]'.
            try exec("ALTER TABLE validation_results ADD COLUMN axes TEXT NOT NULL DEFAULT '[]';", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN target_url TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN plan_steps TEXT NOT NULL DEFAULT '[]';", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN result_status TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE validation_results ADD COLUMN screenshot_path TEXT;", allowDuplicateColumn: true)

            // Backfill `result_status` from the legacy `outcome` so
            // existing rows have a non-NULL value once U.2a-2's reader
            // surfaces start querying by status.
            //   advisory  -> 'pass'    (non-blocking finding)
            //   blocking  -> 'fail'    (refusal-class finding)
            //   clean     -> 'pass'    (no finding at all)
            //   anything else -> 'pass' (conservative fallback)
            try exec("""
                UPDATE validation_results
                   SET result_status = CASE
                       WHEN outcome = 'blocking' THEN 'fail'
                       ELSE 'pass'
                   END
                 WHERE result_status IS NULL;
            """)
        },
        Migration(version: 23, description: "egress_decisions: T.1b judge_rationale + pane_mode columns") { db in
            // T.1b ships the Gemma judge fallback + per-pane policy.
            // Two new columns extend `egress_decisions` so the post-hoc
            // audit row carries both the judge's rationale (when
            // dispatched) and the resolved pane mode that framed the
            // decision:
            //
            //   judge_rationale TEXT  -- nil for static-rule decisions
            //   pane_mode       TEXT  -- 'research'|'write'|'redteam'|'general'|nil
            //
            // Chain-hash compatibility: chain-era rows under the v19
            // 'fresh-install' anchor were hashed WITHOUT these columns
            // in their canonical column map. Adding them to the
            // canonical shape across the board would break their
            // entry_hash verification. Mirrors the v18 pattern:
            //   1. ALTER columns idempotently.
            //   2. Rename the existing 'fresh-install' anchor to
            //      'fresh-install-pre-v23' so the writer + verifier
            //      can switch shapes per anchor.
            //   3. Open a 'migration-v23' anchor at MAX(id) — only
            //      when the table has rows — so new writes that
            //      include judge_rationale / pane_mode chain under
            //      the new canonical shape.
            //
            // Backfill: existing pre-v23 rows leave both new columns
            // NULL (they predate T.1b dispatch). The verifier reads
            // them as `.null` only on the v23+ anchor segment; on the
            // 'fresh-install-pre-v23' segment they're absent from the
            // canonical map entirely.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v23", detail: msg)
            }

            try exec("ALTER TABLE egress_decisions ADD COLUMN judge_rationale TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE egress_decisions ADD COLUMN pane_mode TEXT;", allowDuplicateColumn: true)

            // Rename the existing 'fresh-install' anchor so the writer
            // + verifier can branch on it. Mirrors the v18 pattern.
            try exec("""
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v23'
                 WHERE table_name = 'egress_decisions'
                   AND reason = 'fresh-install';
            """)

            try openPaneModeAnchor(db: db, table: "egress_decisions")
        },
        Migration(version: 24, description: "eval_results chained table (Phase T.2b-1 PIIClassifier Layer 3 audit)") { db in
            // T.2b-1 — `eval_results` is the durable observability surface
            // for PIIClassifier model-quality drift across releases. T.2b-2
            // (eval harness) writes the first rows once the
            // pii-masking-300k-eval dataset is pulled; this migration
            // ships the table + chain shape so the writer (EvalResultsStore)
            // can land in the same round without a second migration when
            // T.2b-2 closes.
            //
            // Same shape as v19 (egress_decisions) / v20 (pack_audits):
            // self-contained CREATE, no migration anchor (table is created
            // empty — first write opens a 'fresh-install' anchor lazily
            // via ChainState).
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v24", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS eval_results (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    model_id TEXT NOT NULL,
                    fixture_id TEXT NOT NULL,
                    precision REAL NOT NULL,
                    recall REAL NOT NULL,
                    f1 REAL NOT NULL,
                    duration_ms INTEGER NOT NULL DEFAULT 0,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_eval_results_anchor ON eval_results(chain_anchor_id, id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_eval_results_model ON eval_results(model_id, id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_eval_results_time ON eval_results(timestamp);")
        },
        Migration(version: 25, description: "trust_audits: U.4b-1 promotion + override row kinds (observed_rate, observed_sample, call_id columns)") { db in
            // U.4b-1 — `FragmentationDetector` mode flip (`softFlag` →
            // `blocking`) writes a chained `promotion` row carrying
            // (fp_rate_max, min_labeled_sample, observed_rate,
            // observed_sample, promoted_by, from→to). Per-call
            // override writes a chained `override` row carrying
            // (call_id, flag_id, operator, justification). Both kinds
            // share the existing `trust_audits` chain.
            //
            // Three new nullable columns:
            //   observed_rate     REAL   -- promotion rows only
            //   observed_sample   INTEGER-- promotion rows only
            //   call_id           TEXT   -- override rows only
            //
            // Chain shape: the new columns are persisted but NOT in
            // the canonical hash map this round — same pattern v22
            // used for validation_results' axes/target_url/plan_steps
            // (U.2a-2b shipped that scope-cut and filed a follow-up
            // for the migration anchor work). Opening a `migration-
            // v25` anchor that includes the new columns in the
            // canonical map is tracked under
            // `process-gap-trust-audits-migration-v25-anchor-pending-
            // 2026-05-20`. Existing rows verify unchanged; new
            // promotion/override rows verify under the same shape as
            // legacy flag/label rows with the new columns stored as
            // opaque data.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v25", detail: msg)
            }
            try exec("ALTER TABLE trust_audits ADD COLUMN observed_rate REAL;", allowDuplicateColumn: true)
            try exec("ALTER TABLE trust_audits ADD COLUMN observed_sample INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE trust_audits ADD COLUMN call_id TEXT;", allowDuplicateColumn: true)
        },
        Migration(version: 26, description: "session_work_queue + session_event_stream + session_event_stream_offsets (Phase U.9a substrate)") { db in
            // U.9a substrate — three new tables in `senkani.db`:
            //   session_work_queue          — durable queue rows with
            //                                 lease/heartbeat/retry/DLQ
            //                                 lifecycle. Honker's
            //                                 transactional-outbox shape:
            //                                 enqueue is part of the
            //                                 caller's write transaction.
            //   session_event_stream        — append-only mirror of
            //                                 canonical events
            //                                 (`token_events`,
            //                                 `agent_trace_event`,
            //                                 `validation_results`) for
            //                                 independent-consumer offset
            //                                 tracking.
            //   session_event_stream_offsets — per-consumer offset
            //                                 (consumer_id PK,
            //                                 last_processed_event_id).
            //                                 Seeded with four rows on
            //                                 first migration: validation
            //                                 / agent_timeline /
            //                                 notifications /
            //                                 compound_learning_analytics.
            //
            // No chain anchor — these tables are operational state
            // (queue + stream), not audit ledger. T.5 chain participants
            // remain unchanged. The outbox helper invokes both the
            // canonical row write AND the stream append AND the queue
            // enqueue in the same SessionDatabase.queue.sync block so
            // rollback semantics are atomic at the queue boundary.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v26", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS session_work_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '',
                    state TEXT NOT NULL DEFAULT 'pending',
                    lease_owner TEXT,
                    lease_expires_at REAL,
                    heartbeat_at REAL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    retry_reason TEXT,
                    result_summary TEXT,
                    next_wakeup_at REAL NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    project_root TEXT
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_swq_state_wakeup ON session_work_queue(state, next_wakeup_at);")
            try exec("CREATE INDEX IF NOT EXISTS idx_swq_kind_state ON session_work_queue(kind, state);")
            try exec("CREATE INDEX IF NOT EXISTS idx_swq_lease_expires ON session_work_queue(lease_expires_at);")
            try exec("""
                CREATE TABLE IF NOT EXISTS session_event_stream (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_table TEXT NOT NULL,
                    source_id INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    project_root TEXT,
                    created_at REAL NOT NULL
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_ses_id ON session_event_stream(id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_ses_source ON session_event_stream(source_table, source_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_ses_kind ON session_event_stream(kind);")
            try exec("""
                CREATE TABLE IF NOT EXISTS session_event_stream_offsets (
                    consumer_id TEXT PRIMARY KEY,
                    last_processed_event_id INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
            """)
            // Seed four consumer rows on first migration. Idempotent via
            // INSERT OR IGNORE — re-running the migration keeps any
            // operator-advanced offsets intact.
            let now = Date().timeIntervalSince1970
            for consumer in ["validation", "agent_timeline", "notifications", "compound_learning_analytics"] {
                try exec("""
                    INSERT OR IGNORE INTO session_event_stream_offsets
                        (consumer_id, last_processed_event_id, updated_at)
                    VALUES ('\(consumer)', 0, \(now));
                """)
            }
        },
        Migration(version: 27, description: "surrogate_writes chained table (Phase T.2c-2 AnonymizationProxy)") { db in
            // T.2c-2 — one row per surrogate ALLOCATION (NOT per reuse).
            // Chain rows do NOT include `original_value` — encryption at
            // rest in `SurrogateVault` is the privacy boundary; this row
            // is the integrity boundary. The chain proves "the engagement
            // allocated surrogate X for category Y at time T" without
            // exposing the underlying original.
            //
            // Schema columns participate in the canonical row hash
            // (alphabetically sorted): `at`, `category`, `engagement_id`,
            // `surrogate_id`. `prev_hash`, `entry_hash`, `chain_anchor_id`
            // are excluded per `ChainHasher.excludedColumns`.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v27", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS surrogate_writes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    engagement_id TEXT NOT NULL,
                    surrogate_id TEXT NOT NULL,
                    category TEXT NOT NULL,
                    at REAL NOT NULL,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER NOT NULL DEFAULT 0
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_surrogate_writes_engagement ON surrogate_writes(engagement_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_surrogate_writes_anchor ON surrogate_writes(chain_anchor_id);")
        },
        Migration(version: 28, description: "trust_audits: rename existing fresh-install anchor to fresh-install-pre-v25 (v25 column-shape evolution)") { db in
            // v25 added observed_rate / observed_sample / call_id columns
            // but kept them OUT of the canonical hash map — opaque data.
            // v28 closes that gap so an attacker who flips a stored
            // observed_rate via SQL UPDATE is caught by ChainVerifier.
            //
            // Mirrors the v18 (commands/token_events) + v23 (egress_decisions)
            // rename pattern. The migration-v25 anchor itself is lazy-opened
            // on first promotion/override write (TrustAuditStore.
            // openMigrationV25AnchorIfNeeded), NOT here — promotion/override
            // are rare; flag/label keep writing under the renamed legacy
            // anchor until a promotion/override actually happens.
            //
            // Post-v28 fresh installs lazy-create a 'fresh-install' anchor on
            // first write that already uses the v25 canonical shape (no
            // rename + no migration-v25 needed because nothing predates it).
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v28", detail: msg)
                }
            }
            try exec("""
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v25'
                 WHERE table_name = 'trust_audits'
                   AND reason = 'fresh-install';
            """)
        },
        Migration(version: 29, description: "validation_results: rename existing fresh-install anchor to fresh-install-pre-v22 (v22 column-shape evolution for browser dispatch)") { db in
            // v22 added axes / target_url / plan_steps / result_status /
            // screenshot_path columns but kept them OUT of the canonical
            // hash map — opaque data. v29 closes that gap so an attacker
            // who flips a stored `result_status` (e.g. 'fail' → 'pass')
            // via SQL UPDATE is caught by ChainVerifier.
            //
            // Mirrors the v18 (commands/token_events) + v23 (egress_decisions)
            // + v28 (trust_audits) rename pattern. The migration-v22 anchor
            // itself is lazy-opened on first browser-validation write
            // (ValidationStore.openMigrationV22AnchorLocked), NOT here —
            // until the first browser dispatch lands, every write stays
            // on the renamed legacy anchor under the pre-v22 shape.
            //
            // Post-v29 fresh installs lazy-create a 'fresh-install' anchor
            // on first write that already uses the v22 canonical shape
            // (no rename + no migration-v22 needed because nothing
            // predates it).
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v29", detail: msg)
                }
            }
            try exec("""
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v22'
                 WHERE table_name = 'validation_results'
                   AND reason = 'fresh-install';
            """)
        },
        Migration(version: 30, description: "runtime_telemetry_{dataset,span,log} for V.18a-1 RuntimeTelemetryDataset") { db in
            // V.18a-1 — first of nine V.18 sub-items per the 2026-05-22
            // operator-approved decomposition. Adds three new tables co-
            // located in the existing session DB so cross-cutting JOINs
            // (`agent_trace_event ↔ runtime_telemetry_span` on session_id
            // + tool_call_id) work natively without ATTACH overhead.
            //
            // Schema mirrors the V.18 parent's `## Scope` section
            // verbatim. Tufte audit (2026-05-22) added FK CASCADE on
            // dataset_id so V.18a-2's prune can rely on parent-child
            // semantics; SQLite enforces these only when
            // `PRAGMA foreign_keys = ON` is set on the connection (the
            // session DB doesn't currently enable foreign_keys globally
            // — callers must enable per-connection when they need
            // cascade behavior). The DECLARATIONS are still
            // forward-compatible whether enforcement is on or off.
            //
            // page_size = 8192 and auto_vacuum = INCREMENTAL are
            // database-wide settings (SQLite has no per-table
            // auto_vacuum). They are tuned OUTSIDE this transaction by
            // SessionDatabase.tuneTelemetryPragmas() — VACUUM cannot
            // run inside a BEGIN IMMEDIATE block.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v30", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS runtime_telemetry_dataset (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    project_id TEXT NOT NULL,
                    workstream_id TEXT,
                    created_at INTEGER NOT NULL,
                    bytes_used INTEGER NOT NULL DEFAULT 0,
                    span_count INTEGER NOT NULL DEFAULT 0,
                    log_count INTEGER NOT NULL DEFAULT 0
                );
            """)
            try exec("""
                CREATE TABLE IF NOT EXISTS runtime_telemetry_span (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    dataset_id INTEGER NOT NULL REFERENCES runtime_telemetry_dataset(id) ON DELETE CASCADE,
                    trace_id TEXT NOT NULL,
                    span_id TEXT NOT NULL,
                    parent_span_id TEXT,
                    name TEXT NOT NULL,
                    start_unix_ns INTEGER NOT NULL,
                    end_unix_ns INTEGER NOT NULL,
                    attributes_json TEXT,
                    status_code INTEGER,
                    session_id TEXT,
                    tool_call_id TEXT,
                    validation_run_id TEXT
                );
            """)
            try exec("""
                CREATE TABLE IF NOT EXISTS runtime_telemetry_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    dataset_id INTEGER NOT NULL REFERENCES runtime_telemetry_dataset(id) ON DELETE CASCADE,
                    unix_ns INTEGER NOT NULL,
                    severity_text TEXT,
                    body_text TEXT,
                    attributes_json TEXT,
                    trace_id TEXT,
                    span_id TEXT,
                    session_id TEXT
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_runtime_telemetry_span_dataset_start ON runtime_telemetry_span(dataset_id, start_unix_ns DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_runtime_telemetry_span_trace ON runtime_telemetry_span(trace_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_runtime_telemetry_span_session_tool ON runtime_telemetry_span(session_id, tool_call_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_runtime_telemetry_span_validation_run ON runtime_telemetry_span(validation_run_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_runtime_telemetry_log_dataset_unix ON runtime_telemetry_log(dataset_id, unix_ns DESC);")
            try exec("CREATE INDEX IF NOT EXISTS idx_runtime_telemetry_log_trace_span ON runtime_telemetry_log(trace_id, span_id);")
        },
    ]

    /// Open a 'migration-v23' anchor for `egress_decisions` at MAX(id)
    /// so post-T.1b writes that include judge_rationale + pane_mode in
    /// the canonical map chain under the new shape while legacy rows
    /// verify under 'fresh-install-pre-v23'. No-op on empty tables —
    /// fresh installs land on a 'fresh-install' anchor that uses the
    /// new canonical shape from the start.
    private static func openPaneModeAnchor(db: OpaquePointer, table: String) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM \(table);"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v23 count(\(table))",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var rowCount: Int64 = 0
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            rowCount = sqlite3_column_int64(stmt, 0)
            maxRowid = sqlite3_column_int64(stmt, 1)
        }
        sqlite3_finalize(stmt)
        guard rowCount > 0 else { return }

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES (?, ?, ?, 'migration-v23', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v23 anchor insert(\(table))",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v23 anchor step(\(table))",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// Open a 'migration-v18' anchor for a table at MAX(id) so that new
    /// post-migration writes chain under the new canonical shape (which
    /// includes `connection_id`) while legacy rows verify under the old
    /// shape. No-op on an empty table — `ChainState` lazy-creates a
    /// 'fresh-install' anchor on first write under the new shape.
    private static func openConnectionIdAnchor(db: OpaquePointer, table: String) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM \(table);"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v18 count(\(table))",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var rowCount: Int64 = 0
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            rowCount = sqlite3_column_int64(stmt, 0)
            maxRowid = sqlite3_column_int64(stmt, 1)
        }
        sqlite3_finalize(stmt)
        guard rowCount > 0 else { return }

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES (?, ?, ?, 'migration-v18', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v18 anchor insert(\(table))",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v18 anchor step(\(table))",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - v5 helpers

    /// Open a 'migration-v5' anchor for a table that has existing rows and
    /// backfill `chain_anchor_id` on every row. No-ops on empty tables.
    private static func anchorBackfill(db: OpaquePointer, table: String, rowidColumn: String) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(\(rowidColumn)), 0) FROM \(table);"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(stage: "v5 count(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        var rowCount: Int64 = 0
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            rowCount = sqlite3_column_int64(stmt, 0)
            maxRowid = sqlite3_column_int64(stmt, 1)
        }
        sqlite3_finalize(stmt)
        guard rowCount > 0 else { return }

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES (?, ?, ?, 'migration-v5', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(stage: "v5 anchor insert(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(stage: "v5 anchor step(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
        let anchorId = sqlite3_last_insert_rowid(db)

        var err: UnsafeMutablePointer<CChar>?
        let backfillSQL = """
            UPDATE \(table)
               SET chain_anchor_id = \(anchorId)
             WHERE chain_anchor_id IS NULL;
        """
        if sqlite3_exec(db, backfillSQL, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw MigrationError.sqlFailed(stage: "v5 backfill(\(table))", detail: msg)
        }
    }

    /// `sandboxed_results.id` is TEXT, so we order by `created_at` (monotonic
    /// at write time) instead of an integer rowid for the started_at_rowid
    /// bound. The verifier walks rows with `created_at` greater than the
    /// stored bound (we encode the timestamp as a Double round-tripped
    /// through Int64-bit-pattern below — but in v5 we accept that the
    /// 'migration-v5' segment of sandboxed_results has zero rows that can
    /// chain-verify because there's no clean ordering on TEXT id; we record
    /// `started_at_rowid = 0` and the verifier instead uses `id NOT IN
    /// (existing TEXT ids)` for that segment. Round 4 cleans this up if the
    /// tradeoff matters in practice.).
    private static func anchorBackfillSandboxedResults(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*) FROM sandboxed_results;"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(stage: "v5 count(sandboxed_results)", detail: String(cString: sqlite3_errmsg(db)))
        }
        var rowCount: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            rowCount = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)
        guard rowCount > 0 else { return }

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('sandboxed_results', ?, 0, 'migration-v5',
                'TEXT-id table; verifier walks rows whose created_at > anchor.started_at');
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(stage: "v5 anchor insert(sandboxed_results)", detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(stage: "v5 anchor step(sandboxed_results)", detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
        let anchorId = sqlite3_last_insert_rowid(db)

        var err: UnsafeMutablePointer<CChar>?
        let backfillSQL = """
            UPDATE sandboxed_results
               SET chain_anchor_id = \(anchorId)
             WHERE chain_anchor_id IS NULL;
        """
        if sqlite3_exec(db, backfillSQL, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw MigrationError.sqlFailed(stage: "v5 backfill(sandboxed_results)", detail: msg)
        }
    }
}
