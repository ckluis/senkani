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
    ]

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
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
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
