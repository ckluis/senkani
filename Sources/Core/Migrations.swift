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
        Migration(version: 31, description: "runtime_telemetry_dataset per-table byte counters for V.18a-2 store + prune") { db in
            // V.18a-2 — per-table 500 MB cap requires per-table byte
            // tracking. V.18a-1's `bytes_used` is the dataset total;
            // split it into `span_bytes` + `log_bytes` so the
            // `RuntimeTelemetryStore.recordBytes` write-path can decide
            // which table needs eviction without an aggregate scan on
            // every insert. `bytes_used` stays as a denormalized total
            // for cheap dataset-level reads (CLI + future
            // `senkani_telemetry_list`). The store keeps all three in
            // sync inside a single UPDATE on every write/prune.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v31", detail: msg)
                }
            }
            try exec("ALTER TABLE runtime_telemetry_dataset ADD COLUMN span_bytes INTEGER NOT NULL DEFAULT 0;")
            try exec("ALTER TABLE runtime_telemetry_dataset ADD COLUMN log_bytes INTEGER NOT NULL DEFAULT 0;")
        },
        Migration(version: 32, description: "validation-source JOIN columns for V.18a-5 (agent_trace_event session_id+tool_call_id, validation_results validation_run_id)") { db in
            // V.18a-5 — wires the validation-source half of V.18's runtime
            // telemetry pipeline. The scope-groom Q4 decision (2026-05-07)
            // locked in the cross-cutting JOIN
            // `agent_trace_event ↔ runtime_telemetry_span ON (session_id,
            // tool_call_id)` as the load-bearing observability story for
            // V.18 — but the existing `agent_trace_event` schema (v8/v10/
            // v14/v16) never carried those columns. Adding them now closes
            // the gap so the JOIN test in V.18a-5's acceptance can land
            // against a real schema.
            //
            // Chain note: `agent_trace_event` is NOT a chain participant
            // (AgentTraceEventStore docstring: "this store does NOT
            // participate in the chain"). New columns are free — no
            // anchor work needed.
            //
            // `validation_results` DOES participate in the chain via the
            // v22 (18-column) canonical shape — but `validation_run_id`
            // is a derived link/index field, not a primary fact. It is
            // deliberately omitted from `ValidationStore.canonicalColumns`
            // so the chain hash for new rows still matches the v22 shape
            // verifier walk. The column is added here so non-canonical
            // tagging (and the new index for JOINs by run id) works.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v32", detail: msg)
            }
            // Self-contained CREATE for agent_trace_event matches the
            // post-v8 / v10 / v14 / v16 baseline so v32 can run against
            // a DB dropped in at any later state (e.g. the
            // v21-baseline migration ledger test that seeds
            // schema_migrations directly without running v1-v21).
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
            try exec("ALTER TABLE agent_trace_event ADD COLUMN session_id TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE agent_trace_event ADD COLUMN tool_call_id TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_agent_trace_session_tool ON agent_trace_event(session_id, tool_call_id);")
            try exec("ALTER TABLE validation_results ADD COLUMN validation_run_id TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_validation_results_run ON validation_results(validation_run_id);")
        },
        Migration(version: 33, description: "wasm_kill chained-row columns on token_events for T.3a-4 (wasm_reason, wasm_duration_us, wasm_budget_delta_us, wasm_tool_id)") { db in
            // T.3a-4 — `wasm_kill` event rows ride the existing `token_events`
            // chain with four new columns. Chain-hash compatibility mirrors
            // the v18 connection_id pattern: pre-v33 rows under
            // `fresh-install`, `migration-v4`, `migration-v18`, or
            // `fresh-install-pre-v18` were hashed WITHOUT the wasm_* columns
            // in their canonical map. Adding the columns to the canonical
            // shape across the board would break their entry_hash. Instead
            // we open a NEW anchor (`migration-v33`) with `started_at_rowid
            // = MAX(id)`. New writes register the wasm_* columns in the
            // canonical map (NULL for non-wasm_kill rows, populated for
            // wasm_kill rows) and chain under the v33 anchor; legacy rows
            // keep their existing anchor + old canonical shape.
            // `ChainVerifier` switches canonical shape per-anchor via the
            // anchor's `reason` field.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v33", detail: msg)
            }

            // Self-contained CREATE matches the v18 / v32 baseline so v33
            // can run against a DB dropped in at any later state.
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
            try exec("ALTER TABLE token_events ADD COLUMN wasm_reason TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN wasm_duration_us INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN wasm_budget_delta_us INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN wasm_tool_id TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_token_events_wasm_reason ON token_events(wasm_reason) WHERE wasm_reason IS NOT NULL;")

            // Rename existing 'fresh-install' anchor for token_events to
            // 'fresh-install-pre-v33' so writes + verifier can switch
            // canonical shapes per anchor. (Earlier renames may have
            // already produced 'fresh-install-pre-v18'; that name stays.)
            try exec("""
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v33'
                 WHERE table_name = 'token_events'
                   AND reason = 'fresh-install';
            """)

            // Open a 'migration-v33' anchor at MAX(id) so post-v33 writes
            // chain under the new canonical shape. No-op on empty tables —
            // fresh installs lazy-create a 'fresh-install' anchor on
            // first write that uses the v33 canonical shape from the
            // start.
            try openWasmKillAnchor(db: db)
        },
        Migration(version: 34, description: "sprint_review_snapshots auxiliary table (V.9a follow-up sub-2 lineage recording for .sprintReview source pane)") { db in
            // V.9a follow-up sub-2 — SprintReviewViewModel records one
            // snapshot batch per pane-open event into this table; the
            // SprintReviewArtifactProvider walks it for the lineage
            // chain. NOT a chained table — no entry_hash / prev_hash /
            // chain_anchor_id; ChainVerifier needs no extension. The
            // captured_at INTEGER carries unix milliseconds so the
            // 30-day retention DELETE matches the PaneDiaryStore
            // sibling's semantic at SQL scale.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v34", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS sprint_review_snapshots (
                    snapshot_id BLOB PRIMARY KEY,
                    captured_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    subtitle TEXT NOT NULL,
                    recurrence_count INTEGER NOT NULL,
                    confidence REAL NOT NULL,
                    last_seen_at INTEGER NOT NULL,
                    window_days INTEGER NOT NULL
                );
            """)
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_sprint_review_snapshots_kind_row
                    ON sprint_review_snapshots(kind, row_id, captured_at DESC);
            """)
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_sprint_review_snapshots_captured_at
                    ON sprint_review_snapshots(captured_at);
            """)
        },
        Migration(version: 35, description: "cached-token accounting columns on token_events for V.19a-2 (cached_prompt_tokens, cache_write_tokens, cache_read_tokens, prefill_ms_saved_estimate, cache_origin)") { db in
            // V.19a-2 — wire the V.19a-1 MLXPrefixCache wrap's accounting
            // probes through the existing `token_events` chain with five new
            // columns. Chain-hash compatibility mirrors the v33 wasm_kill
            // pattern: pre-v35 rows under `migration-v4`,
            // `fresh-install-pre-v18`, `migration-v18`, `migration-v33`, or
            // the previous post-v33 `fresh-install` anchor were hashed
            // WITHOUT the cached-token columns. Adding the columns to
            // those anchors' canonical maps would break their entry_hash.
            // Instead we open a NEW anchor (`migration-v35`) with
            // `started_at_rowid = MAX(id)` and rename the existing
            // post-v33 `fresh-install` anchor to `fresh-install-pre-v35`
            // so the verifier can switch shapes per anchor. Post-v35
            // writes register the five cached-token columns in the
            // canonical map (NULL for non-inference rows, populated for
            // inference rows carrying cache observations) and chain
            // under the v35 anchor; legacy rows keep their existing
            // anchor + old canonical shape. Cached-token accounting MUST
            // stay isolated from `FilterPipeline`-driven `saved_tokens`,
            // `senkani_bundle` compression savings, and V.18
            // `RuntimeTelemetryDataset` privacy-redaction savings — each
            // accounting source writes to its own column; the dashboard
            // distinguishes them by column, not by inference.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v35", detail: msg)
            }

            // Self-contained CREATE matches the v18 / v32 / v33 baseline
            // so v35 can run against a DB dropped in at any later state.
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
            try exec("ALTER TABLE token_events ADD COLUMN cached_prompt_tokens INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN cache_write_tokens INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN cache_read_tokens INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN prefill_ms_saved_estimate INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE token_events ADD COLUMN cache_origin TEXT;", allowDuplicateColumn: true)
            try exec("CREATE INDEX IF NOT EXISTS idx_token_events_cache_origin ON token_events(cache_origin) WHERE cache_origin IS NOT NULL;")

            // Rename the post-v33 `fresh-install` anchor for token_events
            // to `fresh-install-pre-v35` so writes + verifier can switch
            // canonical shapes per anchor. Earlier renames produced
            // `fresh-install-pre-v18` (v18) and `fresh-install-pre-v33`
            // (v33); those names stay. After this rename, the rolling
            // `fresh-install` anchor (lazy-created post-v35 by
            // `ChainState`) means "v35 canonical shape" — includes
            // wasm_* AND cached_* columns.
            try exec("""
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v35'
                 WHERE table_name = 'token_events'
                   AND reason = 'fresh-install';
            """)

            // Open a `migration-v35` anchor at MAX(id) so post-v35 writes
            // chain under the new canonical shape. No-op on empty tables
            // — fresh installs lazy-create a `fresh-install` anchor on
            // first write that uses the v35 canonical shape from the
            // start.
            try openCachedTokenAnchor(db: db)
        },
        Migration(version: 36, description: "provider_runtime_event canonical spine for V.17a-1 (ProviderRuntimeEvent + projection scaffold)") { db in
            // V.17a-1 — first of six V.17a sub-items per the
            // 2026-05-23 operator-approved decomposition. Lands the
            // shared spine: the canonical 10-case event row, conformed
            // dimensions matching V.2's `agent_trace_event` vocabulary,
            // `raw_payload_hash UNIQUE` for at-source idempotency, and
            // a projection-query covering index. Adapters in v17a-2..5
            // write rows here; the V.17b dashboard reads them.
            //
            // Chain note: `provider_runtime_event` is NOT in the T.5
            // audit chain. Accepted-risk per V.2 precedent: V.2's
            // `agent_trace_event` doesn't participate either (it is
            // derived from the chain-anchored `token_events`). V.17a's
            // table is one further tier of derivation. Tampering is
            // detectable by re-deriving from the underlying CLI
            // session logs the adapter ingested. See
            // `Sources/Core/ProviderRuntime/ProviderRuntimeEvent.swift`
            // class-doc + `Sources/Core/Stores/ProviderRuntimeEventStore.swift`
            // class-doc for the audit-chain rationale.
            //
            // Projection-status enum lives in
            // `ProviderRuntimeEvent.ProjectionStatus`; the SQL column
            // stores the rawValue strings (`ineligible` / `pending` /
            // `projected` / `dedup`). The covering index
            // `(provider_id, session_id, observed_at)` powers the
            // V.17b "events for a session, in time order, by provider"
            // primary query without a sort.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v36", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS provider_runtime_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    raw_payload_hash TEXT NOT NULL UNIQUE,
                    provider_id TEXT NOT NULL,
                    session_id TEXT,
                    thread_id TEXT,
                    turn_id TEXT,
                    pane TEXT,
                    event_type TEXT NOT NULL,
                    observed_at REAL NOT NULL,
                    prompt_tokens INTEGER,
                    completion_tokens INTEGER,
                    cached_tokens INTEGER,
                    tool_call_id TEXT,
                    tool_name TEXT,
                    tool_result TEXT,
                    approval_id TEXT,
                    warnings_json TEXT,
                    projection_status TEXT NOT NULL DEFAULT 'ineligible'
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_provider_runtime_event_provider_session_time ON provider_runtime_event(provider_id, session_id, observed_at);")
            try exec("CREATE INDEX IF NOT EXISTS idx_provider_runtime_event_tool_call ON provider_runtime_event(tool_call_id) WHERE tool_call_id IS NOT NULL;")
            try exec("CREATE INDEX IF NOT EXISTS idx_provider_runtime_event_projection ON provider_runtime_event(projection_status) WHERE projection_status != 'ineligible';")
        },
        Migration(version: 37, description: "workstreams lifecycle table for U.11-pre a-1 (WorkstreamLifecycle foundation)") { db in
            // U.11-pre a-1 — first of three U.11-pre sub-items per the
            // 2026-05-25 operator-approved decomposition. Lands the
            // workstream lifecycle table: UUID-keyed identity, UNIQUE
            // slug for CLI/log/audit-chain lookups, and a TEXT state
            // column whose values come from `WorkstreamState`'s
            // RawRepresentable string cases. The `PaneSessionDriver`
            // actor (a-2) reads/writes this table; the four
            // `workstream.<event>` chained rows (a-3) reference rows
            // here by `id`.
            //
            // Chain note: `workstreams` itself is NOT in the T.5
            // audit chain — it stores current state only. The
            // chained-event audit trail lives in `token_events`
            // (a-3 writes those rows under a v38 anchor; the
            // ChainVerifier extension lands there too).
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v37", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS workstreams (
                    id BLOB PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    state TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
            """)
            try exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_workstreams_slug ON workstreams(slug);")
            try exec("CREATE INDEX IF NOT EXISTS idx_workstreams_state ON workstreams(state);")
        },
        Migration(version: 38, description: "workstream.* chained-row anchor on token_events for U.11-pre a-3 (PaneSessionDriver audit trail)") { db in
            // U.11-pre a-3 — third of three U.11-pre sub-items per the
            // 2026-05-25 operator-approved decomposition. Opens a new
            // `migration-v38` anchor on `token_events` so the four
            // `workstream.<event>` chained-row writers (`workstream.start`,
            // `.pause`, `.resume`, `.archive`) shipped alongside this
            // migration chain under a stable boundary. No column changes:
            // workstream rows reuse the existing v35 canonical shape
            // (wasm_* + cached_* as .null), distinguishing themselves only
            // by `source` and storing identity in `tool_name` (UUID
            // string) + `feature` (slug). The anchor exists to demarcate
            // the workstream-events release boundary and to keep future
            // workstream-specific column additions cleanly scoped.
            //
            // Chain-shape note: the `ChainVerifier.verifyAnchorTokenEvents`
            // `useV33Shape` and `useV35Shape` sets gain `migration-v38`;
            // writer-side switches in `TokenEventStore.recordTokenEvent` /
            // `recordWasmKill` mirror that. The rolling `fresh-install`
            // anchor is NOT renamed (canonical shape is unchanged, so the
            // v33/v35 rename precedent does not apply).
            try openWorkstreamRowsAnchor(db: db)
        },
        Migration(version: 39, description: "workstream_contracts table + migration-v39 anchor on token_events for U.11a-1 (WorkstreamTaskContract foundation)") { db in
            // U.11a-1 — first of four U.11 children per the 2026-05-25
            // operator-confirmed decomposition. Lands the
            // `workstream_contracts` SQLite table (11 columns: 9 simple
            // + `budget`/list fields as JSON TEXT) and opens a new
            // `migration-v39` anchor on `token_events` so the two new
            // `contract.<event>` chained-row writers (`contract.attach`,
            // `contract.advance`) shipped alongside this migration chain
            // under a stable boundary.
            //
            // FK note: the `workstream_id REFERENCES workstreams(id)`
            // clause is declarative — this codebase does not enable
            // `PRAGMA foreign_keys = ON`, so SQLite won't enforce at
            // INSERT time. The clause stays for schema documentation +
            // for any future caller that opts into FK enforcement.
            //
            // Chain-shape note: v39 introduces no new `token_events`
            // columns — `contract.<event>` rows reuse the v35 canonical
            // shape (wasm_* + cached_* as .null), distinguished only by
            // `source`. So `ChainVerifier.verifyAnchorTokenEvents`
            // adds `migration-v39` to both the `useV33Shape` and
            // `useV35Shape` sets; writer-side switches in
            // `TokenEventStore.recordContractEvent` /
            // `recordWorkstreamEvent` / `recordTokenEvent` /
            // `recordWasmKill` mirror that. The rolling `fresh-install`
            // anchor is NOT renamed (canonical shape is unchanged, so
            // the v33/v35 rename precedent does not apply).
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v39", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS workstream_contracts (
                    id BLOB PRIMARY KEY,
                    workstream_id BLOB NOT NULL REFERENCES workstreams(id),
                    objective TEXT NOT NULL,
                    file_scope TEXT NOT NULL DEFAULT '[]',
                    allowed_tools TEXT NOT NULL DEFAULT '[]',
                    dependencies TEXT NOT NULL DEFAULT '[]',
                    stale_spec_at REAL,
                    budget TEXT NOT NULL,
                    commands TEXT NOT NULL DEFAULT '[]',
                    acceptance TEXT NOT NULL DEFAULT '[]',
                    review_level TEXT NOT NULL
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_workstream_contracts_workstream_id ON workstream_contracts(workstream_id);")
            try openContractsAnchor(db: db)
        },
        Migration(version: 40, description: "workstream_handoffs table + migration-v40 anchor on token_events for U.11a-4 (BlockedHandoff persistence + handoff.* row kinds)") { db in
            // U.11a-4 — fourth of four U.11 children per the 2026-05-25
            // operator-confirmed decomposition. Lands the dedicated
            // `workstream_handoffs` SQLite table (own T.5 chained table)
            // and opens a new `migration-v40` anchor on `token_events`
            // so the two new `handoff.<event>` row kinds (`handoff.open`,
            // `handoff.close`) shipped alongside this migration chain
            // under a stable boundary.
            //
            // FK note: declarative only — this codebase does not enable
            // `PRAGMA foreign_keys = ON`, matching the v39 posture.
            // `workstream_id` references `workstreams.id`; `contract_id`
            // references `workstream_contracts.id`.
            //
            // BLOB-UUID chain shape: the new table stores identity as
            // BLOB columns but the chain canonical-hash payload uses
            // each UUID's RFC-4122 string form (textValue path in the
            // verifier). This keeps the hash bytes ASCII + matches the
            // writer's convention of constructing UUID strings before
            // SQLite bind.
            //
            // Chain-shape note: v40 introduces no new `token_events`
            // columns — `handoff.<event>` rows reuse the v35 canonical
            // shape (wasm_* + cached_* as .null), distinguished only
            // by `source`. So `ChainVerifier.verifyAnchorTokenEvents`
            // adds `migration-v40` to both the `useV33Shape` and
            // `useV35Shape` sets; writer-side switches in
            // `TokenEventStore.recordHandoffEvent` /
            // `recordBlockedHandoff` / earlier writers mirror that.
            // The rolling `fresh-install` anchor is NOT renamed (no
            // canonical-shape change), so the v33/v35 rename
            // precedent does not apply.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v40", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS workstream_handoffs (
                    id BLOB PRIMARY KEY,
                    workstream_id BLOB NOT NULL REFERENCES workstreams(id),
                    contract_id BLOB NOT NULL REFERENCES workstream_contracts(id),
                    gate_id BLOB NOT NULL,
                    blocker_reason TEXT NOT NULL,
                    owner TEXT NOT NULL,
                    next_action TEXT NOT NULL,
                    evidence_bundle TEXT NOT NULL DEFAULT '[]',
                    created_at INTEGER NOT NULL,
                    prev_hash TEXT,
                    entry_hash TEXT NOT NULL,
                    chain_anchor_id INTEGER NOT NULL
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_workstream_handoffs_workstream_id ON workstream_handoffs(workstream_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_workstream_handoffs_contract_id ON workstream_handoffs(contract_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_workstream_handoffs_gate_id ON workstream_handoffs(gate_id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_workstream_handoffs_anchor ON workstream_handoffs(chain_anchor_id, id);")
            try openHandoffsAnchorTokenEvents(db: db)
        },
        Migration(version: 41, description: "openai_request_log chained table (Phase V.13e-1 DB-backed OpenAI request log)") { db in
            // Phase V.13e-1 — DB-backed persistent request log for the
            // OpenAI-compatible endpoint, replacing the in-memory
            // `OpenAIAuditChain` for cross-process telemetry. The in-memory
            // chain (Sources/Core/OpenAIEndpoint/OpenAIAuditChain.swift)
            // dies with the process; this table persists one row per served
            // request so v13e-2's doctor check and v13e-5's burst test can
            // query trailing-24h request count + 429-rate cross-process.
            //
            // Privacy: the raw API key is NEVER persisted — only `key_label`
            // (the provisioned key's label). There is no request/response
            // body column here: this telemetry log is metadata-only by
            // design (count/rate observability), distinct from the
            // in-memory chain's opt-in `--audit-bodies` shape.
            //
            // Same shape as v19 (egress_decisions) / v24 (eval_results):
            // self-contained CREATE, no migration anchor (table is created
            // empty — first write opens a 'fresh-install' anchor lazily via
            // ChainState). `status` is the HTTP status int; `surface` is one
            // of 'chat' | 'chat_stream' | 'embeddings' | 'tool_use'.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v41", detail: msg)
            }

            try exec("""
                CREATE TABLE IF NOT EXISTS openai_request_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    surface TEXT NOT NULL,
                    status INTEGER NOT NULL,
                    key_label TEXT,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_openai_request_log_anchor ON openai_request_log(chain_anchor_id, id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_openai_request_log_ts ON openai_request_log(ts);")
            try exec("CREATE INDEX IF NOT EXISTS idx_openai_request_log_status ON openai_request_log(status);")
        },
        Migration(version: 42, description: "openai_request_log producer-metadata columns (model_logged + resolved_tier + input_tokens + output_tokens) for V.13e-7 GUI consumer enablement") { db in
            // V.13e-7 — extend the v41 metadata-only request log with the
            // producer-side metadata the in-memory `OpenAIAuditChain` already
            // carries (`modelLogged`, `resolvedTier`, `promptTokenCount`,
            // `completionTokenCount`). v41 sized the persisted log for the
            // doctor `429-rate` check; the GUI consumer
            // (`phase-v13-gui-agent-timeline-consumer-2026-05-28`) needs the
            // richer per-request metadata so the agent-timeline pane can
            // surface what the client asked for, which tier we routed to,
            // and how many tokens flowed. Schneier: persist at the producer
            // once, every downstream consumer (doctor + GUI + future trend
            // dashboards) reads from the same row.
            //
            // Chain-hash compatibility mirrors the v23 egress / v25 trust-
            // audits / v33 wasm-kill / v35 cached-token pattern: pre-v42
            // rows under `fresh-install` (the v41 lazy anchor) were hashed
            // WITHOUT the four new columns. Adding the columns to that
            // anchor's canonical map would break its entry_hash. Instead we
            // rename the existing `fresh-install` anchor to
            // `fresh-install-pre-v42` so the verifier can switch shapes per
            // anchor; new writes register the four producer-metadata
            // columns in the canonical map (NULL → `.null`, populated →
            // typed) and chain under the v42 anchor (or a post-v42
            // lazy-created `fresh-install`). Legacy rows keep their old
            // anchor + old canonical shape.
            //
            // `presetUsed` (the routing-internal preset name) is
            // deliberately NOT persisted here — the audit chain carries it
            // for forensic replay; operator GUIs don't need it. Adding it
            // later is a one-column ALTER under a `migration-v43` anchor.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v42", detail: msg)
            }

            // Self-contained CREATE matches v41's baseline so v42 can run
            // against a DB landed at any later state.
            try exec("""
                CREATE TABLE IF NOT EXISTS openai_request_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    surface TEXT NOT NULL,
                    status INTEGER NOT NULL,
                    key_label TEXT,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("ALTER TABLE openai_request_log ADD COLUMN model_logged TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE openai_request_log ADD COLUMN resolved_tier TEXT;", allowDuplicateColumn: true)
            try exec("ALTER TABLE openai_request_log ADD COLUMN input_tokens INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE openai_request_log ADD COLUMN output_tokens INTEGER;", allowDuplicateColumn: true)

            // Idempotency guard: a prior successful or partial application
            // of v42 leaves either `fresh-install-pre-v42` (the renamed
            // legacy lazy anchor) or `migration-v42` (the new anchor at
            // first-run MAX(id)) in chain_anchors. If either is already
            // present, skip the rename + anchor-open — re-running them
            // would mis-classify post-v42 lazy `fresh-install` anchors
            // (created by writes after v42 first applied) as pre-v42,
            // breaking entry_hash verification for those rows.
            var probeStmt: OpaquePointer?
            let probeSQL = """
                SELECT EXISTS(SELECT 1 FROM chain_anchors
                               WHERE table_name = 'openai_request_log'
                                 AND reason IN ('migration-v42', 'fresh-install-pre-v42'));
            """
            guard sqlite3_prepare_v2(db, probeSQL, -1, &probeStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(
                    stage: "v42 marker probe",
                    detail: String(cString: sqlite3_errmsg(db)))
            }
            var alreadyApplied = false
            if sqlite3_step(probeStmt) == SQLITE_ROW {
                alreadyApplied = sqlite3_column_int(probeStmt, 0) == 1
            }
            sqlite3_finalize(probeStmt)

            if !alreadyApplied {
                // Rename the existing post-v41 `fresh-install` anchor for
                // openai_request_log to `fresh-install-pre-v42` so writes
                // + verifier can switch canonical shapes per anchor. After
                // this rename, any rolling `fresh-install` anchor (lazy-
                // created post-v42 by `ChainState`) means "v42 canonical
                // shape" — includes the four producer-metadata columns.
                // Safely no-ops when no `fresh-install` row exists (table
                // was never written to under v41).
                try exec("""
                    UPDATE chain_anchors
                       SET reason = 'fresh-install-pre-v42'
                     WHERE table_name = 'openai_request_log'
                       AND reason = 'fresh-install';
                """)

                // Open a `migration-v42` anchor at MAX(id) so post-v42
                // writes chain under the new shape, while pre-v42 rows
                // verify under `fresh-install-pre-v42`. No-op on empty
                // tables — fresh installs lazy-create a `fresh-install`
                // anchor on first write that uses the v42 canonical shape
                // from the start.
                try openOpenAIRequestLogV42Anchor(db: db)
            }
        },
        Migration(version: 43, description: "thread_handoff_event chained table (Phase V.17c thread-handoff guardrails: provider-event handoff predicate audit rows)") { db in
            // Phase V.17c — the most invasive V.17 sub-feature. When the
            // operator imports a provider thread from one adapter into
            // another, `ThreadHandoffGuard` (over `provider_runtime_event`)
            // decides whether the thread is importable (last event is
            // `turn_completed`) or blocked (pending approval / input / tool
            // call / aborted / no completed turn). Every ACCEPTED handoff
            // writes one T.5-chained row capturing the pre/post event counts
            // so the import is forensically reconstructable.
            //
            // Dedicated chained table (NOT a `token_events` extension):
            // mirrors the `workstream_handoffs` precedent (migration v40)
            // — its own `ChainState` on `TokenEventStore`, its own
            // `ChainVerifier.verifyThreadHandoffs`, and clean typed columns.
            // Unlike `workstream_handoffs` (BLOB-UUID PK), this table uses an
            // INTEGER AUTOINCREMENT PK like `openai_request_log` (v41), so
            // the verifier reuses the generic integer-keyed `walkTable`
            // path. There is no per-anchor shape switch: v43 is the table's
            // birthday so every row hashes the same canonical shape.
            //
            // `override_reason` is NULLABLE: a normal (non-override)
            // accepted handoff stores NULL; an operator force-import past a
            // BLOCKED predicate MUST supply a free-text justification, which
            // lands here (a force-import without a reason is rejected by the
            // writer and never lands a row).
            //
            // No migration anchor opener: the table is brand-new and empty,
            // so its anchor opens lazily on first write via
            // `ChainState.resolveAnchorId` (reason `fresh-install`,
            // started_at_rowid 0), exactly like v41's `openai_request_log`.
            // The lazy anchor pattern means a fresh install and an upgrade
            // both verify identically — there are no pre-v43 rows to
            // backfill.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v43", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS thread_handoff_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    from_provider TEXT NOT NULL,
                    to_provider TEXT NOT NULL,
                    thread_id TEXT NOT NULL,
                    accepted_by TEXT NOT NULL,
                    pre_handoff_event_count INTEGER NOT NULL,
                    post_handoff_event_count INTEGER NOT NULL,
                    override_reason TEXT,
                    prev_hash TEXT,
                    entry_hash TEXT NOT NULL,
                    chain_anchor_id INTEGER NOT NULL
                );
            """)
            // Dedup index: one accepted handoff row per (thread_id,
            // to_provider). A re-import of the same thread into the same
            // target adapter is idempotent — the writer probes this before
            // inserting and returns `.idempotencyHit` without a second row.
            try exec("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_thread_handoff_event_dedup
                    ON thread_handoff_event(thread_id, to_provider);
            """)
            try exec("CREATE INDEX IF NOT EXISTS idx_thread_handoff_event_anchor ON thread_handoff_event(chain_anchor_id, id);")
            try exec("CREATE INDEX IF NOT EXISTS idx_thread_handoff_event_thread ON thread_handoff_event(thread_id);")
        },
        Migration(version: 44, description: "openai_request_log.upstream_response_id column (Phase V.13b-3 Anthropic upstream-response-id audit anchor)") { db in
            // V.13b-3 — add `upstream_response_id` to the openai_request_log
            // chained table so the Anthropic serve arm (v13b-2/b-4) can record
            // the upstream `Anthropic-Request-Id` response header per row;
            // local-arm (OpenAI-compatible) rows write NULL.
            //
            // RE-PIN: the parent spec stale-pinned this to Migration(version:43),
            // but v43 ALREADY SHIPPED as `thread_handoff_event` (Phase V.17c,
            // landed after the 2026-05-28 scope-groom). A second v43 is a hard
            // duplicate-version fault. The genuinely-next-free slot is v44.
            //
            // Chain-hash compatibility — THIRD canonical-shape tier, mirroring the
            // v42 producer-metadata precedent exactly:
            //   • pre-v42 rows  (`fresh-install-pre-v42`): no producer cols, no upstream.
            //   • v42..pre-v44  (`migration-v42`, `fresh-install-pre-v44`): 4 producer
            //     cols, NO upstream.
            //   • v44+          (`migration-v44`, post-v44 `fresh-install`): + upstream.
            // Adding the column to an existing anchor's canonical map would break
            // its entry_hash, so we rename the rolling post-v42 `fresh-install`
            // anchor to `fresh-install-pre-v44` (any later bare `fresh-install`
            // means "v44 shape") and open a `migration-v44` anchor at MAX(id) for
            // post-v44 writes. The `migration-v42`/`fresh-install-pre-v42` anchors
            // are left untouched — their rows keep their no-upstream shape.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v44", detail: msg)
            }

            // Self-contained CREATE matches the v41/v42 baseline so v44 can run
            // against a DB landed at any prior state.
            try exec("""
                CREATE TABLE IF NOT EXISTS openai_request_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    surface TEXT NOT NULL,
                    status INTEGER NOT NULL,
                    key_label TEXT,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("ALTER TABLE openai_request_log ADD COLUMN upstream_response_id TEXT;", allowDuplicateColumn: true)

            // Idempotency guard (mirrors v42): a prior full/partial v44 leaves
            // either `migration-v44` or `fresh-install-pre-v44` in chain_anchors.
            // If either is present, skip the rename + anchor-open — re-running
            // them would mis-classify post-v44 lazy `fresh-install` anchors as
            // pre-v44, breaking entry_hash verification for those rows.
            var probeStmt: OpaquePointer?
            let probeSQL = """
                SELECT EXISTS(SELECT 1 FROM chain_anchors
                               WHERE table_name = 'openai_request_log'
                                 AND reason IN ('migration-v44', 'fresh-install-pre-v44'));
            """
            guard sqlite3_prepare_v2(db, probeSQL, -1, &probeStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(
                    stage: "v44 marker probe",
                    detail: String(cString: sqlite3_errmsg(db)))
            }
            var alreadyApplied = false
            if sqlite3_step(probeStmt) == SQLITE_ROW {
                alreadyApplied = sqlite3_column_int(probeStmt, 0) == 1
            }
            sqlite3_finalize(probeStmt)

            if !alreadyApplied {
                // Rename the rolling post-v42 `fresh-install` anchor to
                // `fresh-install-pre-v44`. After this, any lazily-created
                // `fresh-install` (post-v44) means "v44 canonical shape" —
                // includes upstream_response_id. No-op when no `fresh-install`
                // row exists (fresh install: first post-v44 write lazy-creates a
                // `fresh-install` that uses the v44 shape from the start).
                try exec("""
                    UPDATE chain_anchors
                       SET reason = 'fresh-install-pre-v44'
                     WHERE table_name = 'openai_request_log'
                       AND reason = 'fresh-install';
                """)

                // Open a `migration-v44` anchor at MAX(id) so post-v44 writes
                // chain under the new shape; pre-v44 rows verify under their
                // existing anchors. Like the v42 opener this inserts the anchor
                // UNCONDITIONALLY (even on an empty table at MAX(id)=0) — so a
                // fresh DB's first write lands on `migration-v44`, NOT a lazy
                // `fresh-install`. Both are useV44Shape=true, so either way the
                // first row hashes with `upstream_response_id`.
                try openOpenAIRequestLogV44Anchor(db: db)
            }
        },
        Migration(version: 45, description: "openai_request_log.cache_creation_input_tokens + cache_read_input_tokens columns (Phase V.13b prompt-caching B — audit-side widening)") { db in
            // V.13b prompt-caching B — add `cache_creation_input_tokens` and
            // `cache_read_input_tokens` to the openai_request_log chained
            // table so the Anthropic serve arm (Child A) can record per-row
            // cache token counts decoded from the Anthropic upstream usage
            // block; local-arm (OpenAI-compatible) rows and any non-cache
            // Anthropic request write NULL.
            //
            // Chain-hash compatibility — FOURTH canonical-shape tier, mirroring
            // the v42/v44 producer-metadata precedents exactly:
            //   • pre-v42 rows  (`fresh-install-pre-v42`): no producer cols,
            //     no upstream, no cache cols.
            //   • v42..pre-v44  (`migration-v42`, `fresh-install-pre-v44`): 4
            //     producer cols, NO upstream, NO cache cols.
            //   • v44..pre-v45  (`migration-v44`, `fresh-install-pre-v45`):
            //     + upstream, NO cache cols. (Schneier P0 — these rows stay v44
            //     shape FOREVER; their entry_hash bytes were computed without
            //     the cache columns and can never be retroactively widened.)
            //   • v45+          (`migration-v45`, post-v45 `fresh-install`):
            //     + cache_creation_input_tokens, cache_read_input_tokens.
            // Adding the columns to an existing anchor's canonical map would
            // break its entry_hash, so we rename the rolling post-v44
            // `fresh-install` anchor to `fresh-install-pre-v45` (any later
            // bare `fresh-install` means "v45 shape") and open a
            // `migration-v45` anchor at MAX(id) for post-v45 writes.
            //
            // REVIEWER CHECKLIST — copy-paste hazard from v42→v44→v45:
            //   - grep the v45 probe SQL for any literal v44 string — must be
            //     zero matches (the probe MUST look for `migration-v45` and
            //     `fresh-install-pre-v45`, NEVER `migration-v44`; leaving a
            //     v44 literal silently makes v45's rename+open run twice on a
            //     re-migration).
            //   - the exclusion list in ChainVerifier MUST include
            //     `migration-v44` (the v44-shape rows stay v44 forever).
            //   - the writer NULL-normalizes `.some(0) → nil` for cache token
            //     fields before SQLite bind AND before canonical-map insertion
            //     so a semantically-identical "no warm" cache miss hashes the
            //     same regardless of whether Anthropic emits the field as 0
            //     or omits it.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v45", detail: msg)
            }

            // Self-contained CREATE matches the v41/v42/v44 baseline so v45
            // can run against a DB landed at any prior state.
            try exec("""
                CREATE TABLE IF NOT EXISTS openai_request_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    surface TEXT NOT NULL,
                    status INTEGER NOT NULL,
                    key_label TEXT,
                    prev_hash TEXT,
                    entry_hash TEXT,
                    chain_anchor_id INTEGER
                );
            """)
            try exec("ALTER TABLE openai_request_log ADD COLUMN cache_creation_input_tokens INTEGER;", allowDuplicateColumn: true)
            try exec("ALTER TABLE openai_request_log ADD COLUMN cache_read_input_tokens INTEGER;", allowDuplicateColumn: true)

            // Idempotency guard (mirrors v42/v44): a prior full/partial v45
            // leaves either `migration-v45` or `fresh-install-pre-v45` in
            // chain_anchors. If either is present, skip the rename + anchor-
            // open — re-running them would mis-classify post-v45 lazy
            // `fresh-install` anchors as pre-v45, breaking entry_hash
            // verification for those rows.
            //
            // REVIEWER PIN: this probe MUST reference `migration-v45` and
            // `fresh-install-pre-v45` ONLY. A literal `v44` here is the
            // copy-paste hazard called out in the header doc-comment.
            var probeStmt: OpaquePointer?
            let probeSQL = """
                SELECT EXISTS(SELECT 1 FROM chain_anchors
                               WHERE table_name = 'openai_request_log'
                                 AND reason IN ('migration-v45', 'fresh-install-pre-v45'));
            """
            guard sqlite3_prepare_v2(db, probeSQL, -1, &probeStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(
                    stage: "v45 marker probe",
                    detail: String(cString: sqlite3_errmsg(db)))
            }
            var alreadyApplied = false
            if sqlite3_step(probeStmt) == SQLITE_ROW {
                alreadyApplied = sqlite3_column_int(probeStmt, 0) == 1
            }
            sqlite3_finalize(probeStmt)

            if !alreadyApplied {
                // Rename the rolling post-v44 `fresh-install` anchor to
                // `fresh-install-pre-v45`. After this, any lazily-created
                // `fresh-install` (post-v45) means "v45 canonical shape" —
                // includes the two cache token columns. No-op when no
                // `fresh-install` row exists (fresh install: first post-v45
                // write lazy-creates a `fresh-install` that uses the v45
                // shape from the start).
                try exec("""
                    UPDATE chain_anchors
                       SET reason = 'fresh-install-pre-v45'
                     WHERE table_name = 'openai_request_log'
                       AND reason = 'fresh-install';
                """)

                // Open a `migration-v45` anchor at MAX(id) so post-v45 writes
                // chain under the new shape; pre-v45 rows verify under their
                // existing anchors. Like the v42/v44 openers this inserts
                // the anchor UNCONDITIONALLY (even on an empty table at
                // MAX(id)=0) — so a fresh DB's first write lands on
                // `migration-v45`, NOT a lazy `fresh-install`. Both are
                // useV45Shape=true, so either way the first row hashes with
                // the cache token columns.
                try openOpenAIRequestLogV45Anchor(db: db)
            }
        },
        Migration(version: 46, description: "egress_decisions.body_excerpt column (Phase T.1d-4 body-aware judge + T.5 body-excerpt persistence)") { db in
            // T.1d-4 — add `body_excerpt BLOB` to the `egress_decisions`
            // chained table so MITM-terminate paths can persist the
            // (truncate-then-redact) request-body excerpt that the judge
            // saw. The on-disk excerpt is post-SecretDetector redaction
            // AND ≤4 KB truncated (Schneier P1: a malicious body cannot
            // poison chain integrity because secrets are scrubbed BEFORE
            // entering the canonical-map insertion).
            //
            // Chain-hash compatibility — THIRD canonical-shape tier for
            // `egress_decisions`, mirroring the v23 precedent + the v44/
            // v45 openai_request_log precedents exactly:
            //   • pre-v23 rows (`fresh-install-pre-v23`): no judge_rationale
            //     / pane_mode, no body_excerpt.
            //   • v23..pre-v46 rows (`migration-v23`,
            //     `fresh-install-pre-v46`): judge_rationale + pane_mode,
            //     NO body_excerpt. (Schneier P0 — these rows stay on the
            //     v23 column-shape FOREVER; their entry_hash bytes were
            //     computed without the body_excerpt column and can never
            //     be retroactively widened.)
            //   • v46+ rows (`migration-v46`, post-v46 `fresh-install`,
            //     future `repair-*`): + body_excerpt.
            // Adding the column to an existing anchor's canonical map
            // would break its entry_hash, so we rename the rolling
            // post-v23 `fresh-install` anchor to `fresh-install-pre-v46`
            // (any later bare `fresh-install` means "v46 shape") and
            // open a `migration-v46` anchor at MAX(id) for post-v46
            // writes.
            //
            // REVIEWER CHECKLIST — copy-paste hazard from v23→v45→v46:
            //   - grep the v46 probe SQL for any literal v45 string — must
            //     be zero matches (the probe MUST look for `migration-v46`
            //     and `fresh-install-pre-v46`, NEVER `migration-v45` and
            //     NEVER `migration-v23`; leaving a v45/v23 literal silently
            //     makes v46's rename+open run twice on a re-migration).
            //   - the exclusion list in
            //     `ChainVerifier.verifyAnchorEgressDecisions` MUST include
            //     ALL prior `egress_decisions` anchor reasons
            //     (`fresh-install-pre-v23`, `migration-v23`,
            //     `fresh-install-pre-v46`) — the v23-shape rows stay
            //     v23-shape forever, the pre-v23 rows stay pre-v23-shape
            //     forever.
            //   - the writer truncate-then-redact ORDER is load-bearing:
            //     truncate to ≤4 KB FIRST, redact via SecretDetector
            //     SECOND. Redacting first wastes cycles on bytes that get
            //     dropped; truncating first means a 4 KB cap on
            //     post-redaction bytes regardless of input size.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v46", detail: msg)
            }

            try exec("ALTER TABLE egress_decisions ADD COLUMN body_excerpt BLOB;", allowDuplicateColumn: true)

            // Idempotency guard (mirrors v44/v45): a prior full/partial
            // v46 leaves either `migration-v46` or `fresh-install-pre-v46`
            // in chain_anchors. If either is present, skip the rename +
            // anchor-open — re-running them would mis-classify post-v46
            // lazy `fresh-install` anchors as pre-v46, breaking
            // entry_hash verification for those rows.
            //
            // REVIEWER PIN: this probe MUST reference `migration-v46` and
            // `fresh-install-pre-v46` ONLY. A literal `v45` or `v23` here
            // is the copy-paste hazard called out in the header doc-
            // comment.
            var probeStmt: OpaquePointer?
            let probeSQL = """
                SELECT EXISTS(SELECT 1 FROM chain_anchors
                               WHERE table_name = 'egress_decisions'
                                 AND reason IN ('migration-v46', 'fresh-install-pre-v46'));
            """
            guard sqlite3_prepare_v2(db, probeSQL, -1, &probeStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(
                    stage: "v46 marker probe",
                    detail: String(cString: sqlite3_errmsg(db)))
            }
            var alreadyApplied = false
            if sqlite3_step(probeStmt) == SQLITE_ROW {
                alreadyApplied = sqlite3_column_int(probeStmt, 0) == 1
            }
            sqlite3_finalize(probeStmt)

            if !alreadyApplied {
                // Rename the rolling post-v23 `fresh-install` anchor to
                // `fresh-install-pre-v46`. After this, any lazily-created
                // `fresh-install` (post-v46) means "v46 canonical shape" —
                // includes the body_excerpt column. No-op when no
                // `fresh-install` row exists.
                try exec("""
                    UPDATE chain_anchors
                       SET reason = 'fresh-install-pre-v46'
                     WHERE table_name = 'egress_decisions'
                       AND reason = 'fresh-install';
                """)

                // Open a `migration-v46` anchor at MAX(id) so post-v46
                // writes chain under the new shape; pre-v46 rows verify
                // under their existing anchors. Like the v44/v45 openers
                // this inserts the anchor UNCONDITIONALLY (even on an
                // empty table at MAX(id)=0) — so a fresh DB's first write
                // lands on `migration-v46`, NOT a lazy `fresh-install`.
                // Both are useV46Shape=true, so either way the first row
                // hashes with the body_excerpt column.
                try openEgressDecisionsV46Anchor(db: db)
            }
        },
        Migration(version: 47, description: "egress_decisions.body_excerpt_capture_state column (Phase T.1d-5 r52 Allspaw P2 — capture-state annotation: empty / overflowed / extraction_failed / captured)") { db in
            // T.1d-5 r52 Allspaw P2 — add `body_excerpt_capture_state TEXT`
            // to `egress_decisions` so an audit row's nil body_excerpt is no
            // longer ambiguous. The column stores the EgressBodyCaptureState
            // rawValue (`empty` / `overflowed` / `extraction_failed` /
            // `captured`), letting doctor `--check-egress` surface per-state
            // counters so an operator can spot a spike in `.overflowed`
            // (16 KB peek window undersized for their traffic).
            //
            // Chain-hash compatibility — FOURTH canonical-shape tier for
            // `egress_decisions`, mirroring the v46 precedent exactly:
            //   • pre-v23 rows (`fresh-install-pre-v23`): no judge_rationale
            //     / pane_mode, no body_excerpt, no capture_state.
            //   • v23..pre-v46 rows (`migration-v23`,
            //     `fresh-install-pre-v46`): judge_rationale + pane_mode,
            //     NO body_excerpt, NO capture_state.
            //   • v46..pre-v47 rows (`migration-v46`,
            //     `fresh-install-pre-v47`): + body_excerpt, NO capture_state.
            //     (Schneier P0 — these rows stay on the v46 column-shape
            //     FOREVER; their entry_hash bytes were computed without the
            //     capture_state column and can never be retroactively
            //     widened.)
            //   • v47+ rows (`migration-v47`, post-v47 `fresh-install`,
            //     future `repair-*`): + body_excerpt_capture_state.
            // Adding the column to an existing anchor's canonical map would
            // break its entry_hash, so we rename the rolling post-v46
            // `fresh-install` anchor to `fresh-install-pre-v47` (any later
            // bare `fresh-install` means "v47 shape") and open a
            // `migration-v47` anchor at MAX(id) for post-v47 writes.
            //
            // REVIEWER CHECKLIST — copy-paste hazard from v46→v47:
            //   - grep the v47 probe SQL for any literal v46/v45/v23 string —
            //     must be zero matches (the probe MUST look for
            //     `migration-v47` and `fresh-install-pre-v47`, NEVER a prior
            //     version; leaving a prior literal silently makes v47's
            //     rename+open run twice on a re-migration).
            //   - the exclusion list in
            //     `ChainVerifier.verifyAnchorEgressDecisions` (and the writer
            //     `useV47Shape` predicate in the egress decision store's
            //     `record(...)`) MUST include
            //     ALL prior `egress_decisions` anchor reasons
            //     (`fresh-install-pre-v23`, `migration-v23`,
            //     `fresh-install-pre-v46`, `migration-v46`,
            //     `fresh-install-pre-v47`) — the v46-shape rows stay
            //     v46-shape forever.
            func exec(_ sql: String, allowDuplicateColumn: Bool = false) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc == SQLITE_OK { return }
                if allowDuplicateColumn && msg.contains("duplicate column name") { return }
                throw MigrationError.sqlFailed(stage: "v47", detail: msg)
            }

            try exec("ALTER TABLE egress_decisions ADD COLUMN body_excerpt_capture_state TEXT;", allowDuplicateColumn: true)

            // Idempotency guard (mirrors v46): a prior full/partial v47
            // leaves either `migration-v47` or `fresh-install-pre-v47` in
            // chain_anchors. If either is present, skip the rename +
            // anchor-open — re-running them would mis-classify post-v47 lazy
            // `fresh-install` anchors as pre-v47, breaking entry_hash
            // verification for those rows.
            //
            // REVIEWER PIN: this probe MUST reference `migration-v47` and
            // `fresh-install-pre-v47` ONLY. A literal `v46`/`v45`/`v23` here
            // is the copy-paste hazard called out in the header doc-comment.
            var probeStmt: OpaquePointer?
            let probeSQL = """
                SELECT EXISTS(SELECT 1 FROM chain_anchors
                               WHERE table_name = 'egress_decisions'
                                 AND reason IN ('migration-v47', 'fresh-install-pre-v47'));
            """
            guard sqlite3_prepare_v2(db, probeSQL, -1, &probeStmt, nil) == SQLITE_OK else {
                throw MigrationError.sqlFailed(
                    stage: "v47 marker probe",
                    detail: String(cString: sqlite3_errmsg(db)))
            }
            var alreadyApplied = false
            if sqlite3_step(probeStmt) == SQLITE_ROW {
                alreadyApplied = sqlite3_column_int(probeStmt, 0) == 1
            }
            sqlite3_finalize(probeStmt)

            if !alreadyApplied {
                // Rename the rolling post-v46 `fresh-install` anchor to
                // `fresh-install-pre-v47`. After this, any lazily-created
                // `fresh-install` (post-v47) means "v47 canonical shape" —
                // includes the body_excerpt_capture_state column. No-op when
                // no `fresh-install` row exists.
                try exec("""
                    UPDATE chain_anchors
                       SET reason = 'fresh-install-pre-v47'
                     WHERE table_name = 'egress_decisions'
                       AND reason = 'fresh-install';
                """)

                // Open a `migration-v47` anchor at MAX(id) so post-v47 writes
                // chain under the new shape; pre-v47 rows verify under their
                // existing anchors. Like v46 this inserts the anchor
                // UNCONDITIONALLY (even on an empty table at MAX(id)=0) — so a
                // fresh DB's first write lands on `migration-v47`, NOT a lazy
                // `fresh-install`. Both are useV47Shape=true, so either way
                // the first row hashes with the capture_state column.
                try openEgressDecisionsV47Anchor(db: db)
            }
        },
        Migration(version: 48, description: "provider_health_snapshot table for V.17b-1 (ProviderHealthSnapshot core — per-provider health row, event/CLI refresh, no-network)") { db in
            // V.17b-1 — the headless data spine for the provider-health
            // dashboard. One row per provider_id, upserted by
            // `senkani provider refresh` (local --version probe, NO
            // network) and flipped forward by `turn_completed`
            // provider_runtime_event refresh. The SwiftUI Dashboard pane
            // row that renders stale=yellow/error=red is the carved-off
            // Cowork sibling (phase-v17b-2) — this migration ships only
            // the table the pane reads.
            //
            // Chain note: like provider_runtime_event (v36), this table
            // is NOT in the T.5 audit chain. It is a derived/cache
            // projection of local CLI probes; tampering is detectable by
            // re-running `provider refresh`. The snapshot carries no
            // entry_hash and no chain_anchors row.
            //
            // staleness (.fresh/.stale/.error) is a PURE function of
            // (last_refresh, now, ttl) computed in Swift — it is NOT a
            // stored column, so a snapshot row never goes stale on disk;
            // it goes stale only relative to read-time `now`. ttl_stale_s
            // / ttl_error_s persist the per-provider thresholds (spec'd
            // defaults 86400 / 604800) so the GUI sibling reads them back.
            func exec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_exec(db, sql, nil, nil, &err)
                let msg = err.map { String(cString: $0) } ?? "unknown"
                if let err { sqlite3_free(err) }
                if rc != SQLITE_OK {
                    throw MigrationError.sqlFailed(stage: "v48", detail: msg)
                }
            }
            try exec("""
                CREATE TABLE IF NOT EXISTS provider_health_snapshot (
                    provider_id TEXT PRIMARY KEY,
                    cli_installed INTEGER NOT NULL,
                    version TEXT,
                    auth_state TEXT NOT NULL DEFAULT 'unknown',
                    selected_model TEXT,
                    subscription_state TEXT,
                    last_refresh REAL NOT NULL,
                    ttl_stale_s REAL NOT NULL,
                    ttl_error_s REAL NOT NULL,
                    remediation_hint TEXT
                );
            """)
            // Covering read for "all snapshots, oldest-refresh first" —
            // the GUI sibling's primary query (render every provider,
            // most-stale at the top).
            try exec("CREATE INDEX IF NOT EXISTS idx_provider_health_snapshot_refresh ON provider_health_snapshot(last_refresh);")
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
    /// Open a 'migration-v33' anchor for `token_events` at MAX(id) so
    /// post-v33 writes that include the wasm_* columns in the canonical
    /// map chain under the new shape, while pre-v33 rows verify under
    /// 'fresh-install'/'fresh-install-pre-v33'/'migration-v18'. No-op on
    /// empty tables — fresh installs lazy-create a 'fresh-install'
    /// anchor on first write that uses the v33 canonical shape from
    /// the start.
    private static func openWasmKillAnchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v33 count(token_events)",
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
            VALUES ('token_events', ?, ?, 'migration-v33', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v33 anchor insert(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v33 anchor step(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// Open a `migration-v35` anchor for `token_events` at MAX(id) so
    /// post-v35 writes that include the cached-token columns
    /// (`cached_prompt_tokens`, `cache_write_tokens`, `cache_read_tokens`,
    /// `prefill_ms_saved_estimate`, `cache_origin`) in the canonical map
    /// chain under the new shape, while pre-v35 rows verify under
    /// `fresh-install-pre-v35` / `migration-v33` / `migration-v18` /
    /// `fresh-install-pre-v18` / `migration-v4`. No-op on empty tables —
    /// fresh installs lazy-create a `fresh-install` anchor on first
    /// write that uses the v35 canonical shape from the start.
    private static func openCachedTokenAnchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v35 count(token_events)",
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
            VALUES ('token_events', ?, ?, 'migration-v35', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v35 anchor insert(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v35 anchor step(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// Open a `migration-v38` anchor for `token_events` at MAX(id) so
    /// post-v38 `workstream.<event>` writes (and any other writers
    /// running after the v38 migration) chain under a stable boundary.
    /// No-op on empty tables — fresh installs lazy-create a
    /// `fresh-install` anchor on first write that uses the same v35
    /// canonical shape (workstream rows store identity in `tool_name` +
    /// `feature` and leave wasm_* + cached_* as .null). No `fresh-
    /// install` rename: canonical shape is unchanged, so the v33/v35
    /// rename precedent does not apply.
    /// Open a `migration-v39` anchor for `token_events` at MAX(id) so
    /// post-v39 `contract.<event>` writes (and any other writers
    /// running after the v39 migration) chain under a stable boundary.
    /// No-op on empty tables — fresh installs lazy-create a
    /// `fresh-install` anchor on first write that uses the same v35
    /// canonical shape. No `fresh-install` rename: canonical shape is
    /// unchanged (v39 ships no new columns), so the v33/v35 rename
    /// precedent does not apply.
    private static func openContractsAnchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v39 count(token_events)",
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
            VALUES ('token_events', ?, ?, 'migration-v39', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v39 anchor insert(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v39 anchor step(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// Open a `migration-v40` anchor for `token_events` at MAX(id) so
    /// post-v40 `handoff.<event>` writes (and any other writers
    /// running after the v40 migration) chain under a stable boundary.
    /// No-op on empty tables — fresh installs lazy-create a
    /// `fresh-install` anchor on first write that uses the same v35
    /// canonical shape. No `fresh-install` rename: canonical shape is
    /// unchanged (v40 ships no new token_events columns), so the
    /// v33/v35 rename precedent does not apply.
    ///
    /// The dedicated `workstream_handoffs` chained table is BRAND NEW
    /// in v40 — it has no pre-existing rows to anchor, so its anchor
    /// opens lazily on first write via `ChainState.resolveAnchorId`
    /// (reason `fresh-install`, started_at_rowid 0).
    private static func openHandoffsAnchorTokenEvents(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v40 count(token_events)",
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
            VALUES ('token_events', ?, ?, 'migration-v40', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v40 anchor insert(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v40 anchor step(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// Open a `migration-v42` anchor for `openai_request_log` at MAX(id)
    /// so post-v42 writes that include the four producer-metadata columns
    /// (`model_logged`, `resolved_tier`, `input_tokens`, `output_tokens`)
    /// in the canonical map chain under the new shape, while pre-v42 rows
    /// verify under `fresh-install-pre-v42` (renamed by the v42 migration
    /// body).
    ///
    /// Unlike the v23/v25/v33/v35 anchor openers, this one runs even on
    /// an empty table. The marker matters for idempotency: by always
    /// laying down `migration-v42`, the migration body's marker-guard
    /// can reliably distinguish first-run from replay, AND
    /// `ChainState.resolveAnchorId` finds it on the first post-v42 write
    /// (no ambiguous lazy `fresh-install` anchor whose timing relative
    /// to the v42 application is unrecoverable).
    private static func openOpenAIRequestLogV42Anchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM openai_request_log;"
        guard sqlite3_prepare_v2(db, maxSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v42 maxid(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            maxRowid = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('openai_request_log', ?, ?, 'migration-v42', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v42 anchor insert(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v42 anchor step(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// V.13b-3 — open a `migration-v44` anchor at the current MAX(id) of
    /// `openai_request_log` so post-v44 writes (which carry the new
    /// `upstream_response_id` column in their canonical hash) chain under the
    /// v44 shape, while pre-v44 rows verify under their existing anchors.
    /// Mirrors `openOpenAIRequestLogV42Anchor`. No-op semantics on empty tables
    /// (MAX(id)→0); fresh installs lazy-create a post-v44 `fresh-install` anchor
    /// that uses the v44 shape from the start.
    private static func openOpenAIRequestLogV44Anchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM openai_request_log;"
        guard sqlite3_prepare_v2(db, maxSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v44 maxid(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            maxRowid = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('openai_request_log', ?, ?, 'migration-v44', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v44 anchor insert(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v44 anchor step(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// T.1d-4 — open a `migration-v46` anchor at the current MAX(id) of
    /// `egress_decisions` so post-v46 writes (which carry the new
    /// `body_excerpt` column in their canonical hash) chain under the
    /// v46 shape, while pre-v46 rows verify under their existing anchors
    /// (`migration-v23`, `fresh-install-pre-v23`, `fresh-install-pre-v46`).
    /// Mirrors `openOpenAIRequestLogV45Anchor`. No-op semantics on empty
    /// tables (MAX(id)→0); fresh installs lazy-create a post-v46
    /// `fresh-install` anchor that uses the v46 shape from the start.
    private static func openEgressDecisionsV46Anchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM egress_decisions;"
        guard sqlite3_prepare_v2(db, maxSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v46 maxid(egress_decisions)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            maxRowid = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('egress_decisions', ?, ?, 'migration-v46', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v46 anchor insert(egress_decisions)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v46 anchor step(egress_decisions)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// T.1d-5 r52 Allspaw P2 — open a `migration-v47` anchor at the current
    /// MAX(id) of `egress_decisions` so post-v47 writes (which carry the new
    /// `body_excerpt_capture_state` column in their canonical hash) chain
    /// under the v47 shape, while pre-v47 rows verify under their existing
    /// anchors (`migration-v46`, `fresh-install-pre-v47`, and the earlier
    /// pre-v46 reasons). Mirrors `openEgressDecisionsV46Anchor`. No-op
    /// semantics on empty tables (MAX(id)→0); fresh installs lazy-create a
    /// post-v47 `fresh-install` anchor that uses the v47 shape from the start.
    private static func openEgressDecisionsV47Anchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM egress_decisions;"
        guard sqlite3_prepare_v2(db, maxSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v47 maxid(egress_decisions)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            maxRowid = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('egress_decisions', ?, ?, 'migration-v47', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v47 anchor insert(egress_decisions)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v47 anchor step(egress_decisions)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    /// V.13b prompt-caching B — open a `migration-v45` anchor at the current
    /// MAX(id) of `openai_request_log` so post-v45 writes (which carry the
    /// new `cache_creation_input_tokens` + `cache_read_input_tokens` columns
    /// in their canonical hash) chain under the v45 shape, while pre-v45
    /// rows verify under their existing anchors (`migration-v44`,
    /// `fresh-install-pre-v44`, `migration-v42`, `fresh-install-pre-v42`).
    /// Mirrors `openOpenAIRequestLogV44Anchor`. No-op semantics on empty
    /// tables (MAX(id)→0); fresh installs lazy-create a post-v45
    /// `fresh-install` anchor that uses the v45 shape from the start.
    private static func openOpenAIRequestLogV45Anchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let maxSQL = "SELECT COALESCE(MAX(id), 0) FROM openai_request_log;"
        guard sqlite3_prepare_v2(db, maxSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v45 maxid(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        var maxRowid: Int64 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            maxRowid = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        let now = Date().timeIntervalSince1970
        let insertSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('openai_request_log', ?, ?, 'migration-v45', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v45 anchor insert(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v45 anchor step(openai_request_log)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

    private static func openWorkstreamRowsAnchor(db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let countSQL = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM token_events;"
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v38 count(token_events)",
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
            VALUES ('token_events', ?, ?, 'migration-v38', NULL);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.sqlFailed(
                stage: "v38 anchor insert(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, maxRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw MigrationError.sqlFailed(
                stage: "v38 anchor step(token_events)",
                detail: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(stmt)
    }

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
