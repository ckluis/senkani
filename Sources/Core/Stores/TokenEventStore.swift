import Foundation
import SQLite3

/// Owns `token_events` + `claude_session_cursors` end-to-end — schema,
/// writes, analytics reads, cursor upserts, and the 90-day prune.
/// Extracted from `SessionDatabase` under
/// `sessiondb-split-3-tokeneventstore` (Luminary P2-11, round 3 of 5).
/// Shares the parent's connection + dispatch queue; never opens a
/// new SQLite handle.
///
/// Cross-store composition (JOIN across token_events ↔ sessions —
/// `tokenStatsByAgent`, `lastSessionActivity`, `lastExecResult`) and
/// `complianceRate` deliberately stay on the `SessionDatabase` façade
/// per the round's scope. Every other `token_events`-only method is
/// here and forwarded.
final class TokenEventStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    // T.5 round 2 — tamper-evident audit chain. ChainState owns the per-
    // table anchor lookup + last-hash cache; round 3 generalized it so all
    // four chain participants share the same primitive.
    private let chain = ChainState(table: "token_events")

    // U.11a-4 — `workstream_handoffs` is its own T.5-chained table
    // (migration v40). Owns a separate `ChainState` so anchor lookup
    // and last-hash cache are independent from `token_events`.
    private let handoffChain = ChainState(table: "workstream_handoffs")

    // V.17c — `thread_handoff_event` is its own T.5-chained table
    // (migration v43). Owns a separate `ChainState` so its anchor
    // lookup + last-hash cache are independent from both `token_events`
    // and `workstream_handoffs`.
    private let threadHandoffChain = ChainState(table: "thread_handoff_event")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller must
    /// be on `parent.queue`.
    func invalidateChainCache() {
        chain.invalidate()
        handoffChain.invalidate()
        threadHandoffChain.invalidate()
    }

    // MARK: - Schema

    /// Residual DDL that has not yet been folded into a numbered migration.
    /// MigrationRegistry.all v4 owns `token_events`; this method covers the
    /// five `token_events` indexes, the `model_tier` ALTER, and the
    /// `claude_session_cursors` table. Called AFTER `runMigrations` so the
    /// underlying `token_events` table already exists; CREATE … IF NOT
    /// EXISTS / ALTER guards keep the call idempotent.
    func setupSchema() {
        parent.queue.sync {
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_pane ON token_events(pane_id);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_project ON token_events(project_root);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_events(timestamp);")
            execSilent("ALTER TABLE token_events ADD COLUMN model_tier TEXT;")
            // Phase B-ii: connection_id is also covered by `MigrationRegistry.all v18`,
            // which additionally opens a `migration-v18` chain anchor; this
            // ALTER is the runtime-residual mirror so a hand-recovered DB
            // keeps the column even if the operator skipped the v18 step.
            execSilent("ALTER TABLE token_events ADD COLUMN connection_id TEXT;")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_session ON token_events(session_id);")
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_connection ON token_events(connection_id);")
            // Schema shape: PRIMARY KEY (path, reader) — Migration 21
            // (claude-session-cursor-turn-index-ownership-conflict-2026-05-15)
            // split the table so the realtime watcher and the cursor-driven
            // reader scope to their own rows. Fresh installs land here
            // directly; migration 21 rebuilds legacy installs. The two
            // writer identities (`watcher` | `reader`) are documented in
            // INVARIANTS.md.
            exec("""
                CREATE TABLE IF NOT EXISTS claude_session_cursors (
                    path TEXT NOT NULL,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    turn_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    reader TEXT NOT NULL DEFAULT 'watcher',
                    PRIMARY KEY (path, reader)
                );
            """)
            execSilent("CREATE INDEX IF NOT EXISTS idx_token_events_project_tool_time ON token_events(project_root, tool_name, timestamp);")
        }
    }

    // MARK: - Writes

    /// Record a token event (from MCP tool call, hook intercept, or ClaudeSessionReader).
    ///
    /// Redaction: `command` can carry agent-supplied text like
    /// `export API_KEY=sk_live_...` or a `curl -H "Authorization: Bearer …"`
    /// invocation. `PersistenceRedaction.redact` strips those before the row
    /// hits disk so a session-db export never contains a live key.
    func recordTokenEvent(
        sessionId: String,
        paneId: String?,
        projectRoot: String?,
        source: String,
        toolName: String?,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        costCents: Int,
        feature: String?,
        command: String?,
        modelTier: String? = nil,
        connectionId: String? = nil,
        // V.19a-2 — cached-token accounting. Defaults preserve current
        // call sites that pre-date cache integration. Callers wiring the
        // V.19a-1 MLXPrefixCache hooks supply non-nil values per
        // inference call. Each accounting source writes to its own
        // column so cached-token reporting stays isolated from
        // `saved_tokens` (FilterPipeline / senkani_bundle /
        // RuntimeTelemetryDataset privacy-redaction).
        //
        // `cachedPromptTokens` — total cached prompt occupancy observed
        // at call time (snapshot of cache state).
        // `cacheWriteTokens` — tokens written to the cache by this
        // inference call (prefill that populates the prefix).
        // `cacheReadTokens` — tokens reused FROM the cache by this
        // inference call (prefix shared with prior sessions/turns).
        // `prefillMsSavedEstimate` — derived (per-token prefill cost ×
        // cacheReadTokens); caller computes.
        // `cacheOrigin` — discriminator for the cache subsystem; raw
        // value of `CacheOrigin` enum. V.19a-2 ships only
        // `prefix_cache`.
        cachedPromptTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        prefillMsSavedEstimate: Int? = nil,
        cacheOrigin: CacheOrigin? = nil
    ) {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        let redactedCommand = PersistenceRedaction.redactedString(command)
        let cacheOriginRaw = cacheOrigin?.rawValue
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            // T.5 round 2: resolve current chain anchor (lazy-create
            // 'fresh-install' if none exists for this table) and look up the
            // latest entry_hash for prev linkage.
            let anchorId = self.chain.resolveAnchorId(db: db)
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)
            // Phase B-ii: include `connection_id` in the canonical column
            // map for all anchors EXCEPT the legacy pre-v18 ones whose
            // existing rows were hashed without it. The legacy set is
            // `migration-v4` (pre-T.5 backfill anchor) and
            // `fresh-install-pre-v18` (renamed by the v18 migration so
            // legacy fresh-install rows keep verifying under the old
            // shape). Mirrored on the verifier side in
            // `ChainVerifier.verifyAnchorTokenEvents`.
            //
            // T.3a-4 (v33): include the four wasm_* columns in the
            // canonical map for anchors `migration-v33`, the post-v33
            // pre-v35 `fresh-install-pre-v35` anchor, the v35 anchor,
            // AND the post-v35 `fresh-install` anchor. Pre-v33 anchors
            // hash without the wasm_* columns. Non-wasm_kill rows under
            // these anchors carry the columns as `.null`, which hashes
            // deterministically — `recordTokenEvent` always writes them
            // as null.
            //
            // V.19a-2 (v35): include the five cached-token columns in
            // the canonical map for anchors `migration-v35` and the
            // post-v35 `fresh-install` (lazy-created after v35 runs).
            // Pre-v35 anchors hash without the cached-token columns.
            // Rows without cache observations carry the columns as
            // `.null` under v35 shape, which hashes deterministically.
            let reason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            let useLegacyShape = (reason == "migration-v4" || reason == "fresh-install-pre-v18")
            // U.11-pre a-3 (v38): `migration-v38` joins the post-v33
            // shape set (no column changes — canonical shape still
            // includes wasm_* + cached_*). Workstream rows route through
            // `recordWorkstreamEvent`; this method's gate stays per-anchor.
            //
            // U.11a-1 (v39): `migration-v39` likewise joins the post-v33
            // + v35 shape sets. Contract rows route through
            // `recordContractEvent`; this method's gate stays per-anchor.
            let useV33Shape = (
                reason == "migration-v33" ||
                reason == "fresh-install-pre-v35" ||
                reason == "migration-v35" ||
                reason == "fresh-install" ||
                reason == "migration-v38" ||
                reason == "migration-v39" ||
                reason == "migration-v40"
            )
            let useV35Shape = (
                reason == "migration-v35" ||
                reason == "fresh-install" ||
                reason == "migration-v38" ||
                reason == "migration-v39" ||
                reason == "migration-v40"
            )

            // Build the canonical-byte input from the to-be-bound values. The
            // three chain columns are excluded by `ChainHasher` — they cannot
            // appear in their own input.
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(sessionId),
                "pane_id":        Self.canonical(paneId),
                "project_root":   Self.canonical(normalizedRoot),
                "source":         .text(source),
                "tool_name":      Self.canonical(toolName),
                "model":          Self.canonical(model),
                "input_tokens":   .integer(Int64(inputTokens)),
                "output_tokens":  .integer(Int64(outputTokens)),
                "saved_tokens":   .integer(Int64(savedTokens)),
                "cost_cents":     .integer(Int64(costCents)),
                "feature":        Self.canonical(feature),
                "command":        Self.canonical(redactedCommand),
                "model_tier":     Self.canonical(modelTier),
            ]
            if !useLegacyShape {
                columns["connection_id"] = Self.canonical(connectionId)
            }
            if useV33Shape {
                // Non-wasm_kill rows under v33+ anchors hash with the
                // wasm_* columns as `.null`. Wasm_kill rows go through
                // `recordWasmKill` which populates the same four keys
                // with non-null values so the canonical shape stays
                // uniform per-anchor.
                columns["wasm_reason"] = .null
                columns["wasm_duration_us"] = .null
                columns["wasm_budget_delta_us"] = .null
                columns["wasm_tool_id"] = .null
            }
            if useV35Shape {
                columns["cached_prompt_tokens"]      = Self.canonicalInt(cachedPromptTokens)
                columns["cache_write_tokens"]        = Self.canonicalInt(cacheWriteTokens)
                columns["cache_read_tokens"]         = Self.canonicalInt(cacheReadTokens)
                columns["prefill_ms_saved_estimate"] = Self.canonicalInt(prefillMsSavedEstimate)
                columns["cache_origin"]              = Self.canonical(cacheOriginRaw)
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 cached_prompt_tokens, cache_write_tokens, cache_read_tokens,
                 prefill_ms_saved_estimate, cache_origin,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 3, paneId)
            Self.bindOptionalText(stmt, 4, normalizedRoot)
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 6, toolName)
            Self.bindOptionalText(stmt, 7, model)
            sqlite3_bind_int64(stmt, 8, Int64(inputTokens))
            sqlite3_bind_int64(stmt, 9, Int64(outputTokens))
            sqlite3_bind_int64(stmt, 10, Int64(savedTokens))
            sqlite3_bind_int64(stmt, 11, Int64(costCents))
            Self.bindOptionalText(stmt, 12, feature)
            Self.bindOptionalText(stmt, 13, redactedCommand)
            Self.bindOptionalText(stmt, 14, modelTier)
            Self.bindOptionalText(stmt, 15, connectionId)
            Self.bindOptionalInt(stmt, 16, cachedPromptTokens)
            Self.bindOptionalInt(stmt, 17, cacheWriteTokens)
            Self.bindOptionalInt(stmt, 18, cacheReadTokens)
            Self.bindOptionalInt(stmt, 19, prefillMsSavedEstimate)
            Self.bindOptionalText(stmt, 20, cacheOriginRaw)
            Self.bindOptionalText(stmt, 21, prevHash)
            sqlite3_bind_text(stmt, 22, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 23, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                // Update cache only on successful insert. parent.queue
                // serialization means no other write can interleave between
                // the prev_hash read and this update.
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// T.3a-4 — record a `wasm_kill` audit row under the existing
    /// `token_events` chain. The row uses `source='wasm_kill'` and
    /// populates the four wasm_* columns added in migration v33. Pre-v33
    /// anchors (`migration-v4`, `migration-v18`, `fresh-install-pre-*`)
    /// refuse the write — wasm_kill rows can only chain under v33+
    /// anchors so their canonical map matches the verifier's. If the
    /// table is still anchored to a pre-v33 anchor (operator hand-
    /// migrated, or schema_version stamped without running migrations),
    /// the row is dropped silently — the watchdog's terminate-kill path
    /// must not throw.
    func recordWasmKill(
        sessionId: String,
        reason: WasmKillReason,
        durationUs: Int64,
        budgetDeltaUs: Int64,
        toolId: String?,
        projectRoot: String? = nil,
        paneId: String? = nil
    ) {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let anchorReason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            // V.19a-2 (v35): expanded post-v33 anchor set. After v35
            // migration, the previous post-v33 `fresh-install` was
            // renamed to `fresh-install-pre-v35`; the rolling
            // `fresh-install` now means v35 shape (includes wasm_* AND
            // cached_*). wasm_kill rows under v35 anchors carry cached_*
            // as `.null` so the canonical shape stays uniform per-anchor.
            //
            // U.11a-1 (v39): `migration-v39` joins both post-v33 + v35
            // shape sets — v39 ships no new `token_events` columns.
            let useV33Shape = (
                anchorReason == "migration-v33" ||
                anchorReason == "fresh-install-pre-v35" ||
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            let useV35Shape = (
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            // Pre-v33 anchors don't carry the wasm_* canonical shape;
            // drop the row rather than write under a hash the verifier
            // cannot reproduce.
            guard useV33Shape else {
                Logger.log("wasm_kill.drop", fields: [
                    "reason": .string("pre_v33_anchor"),
                    "anchor_reason": .string(anchorReason),
                ])
                return
            }
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(sessionId),
                "pane_id":        Self.canonical(paneId),
                "project_root":   Self.canonical(normalizedRoot),
                "source":         .text("wasm_kill"),
                "tool_name":      Self.canonical(toolId),
                "model":          .null,
                "input_tokens":   .integer(0),
                "output_tokens":  .integer(0),
                "saved_tokens":   .integer(0),
                "cost_cents":     .integer(0),
                "feature":        .text(reason.rawValue),
                "command":        .null,
                "model_tier":     .null,
                "connection_id":  .null,
                "wasm_reason":    .text(reason.rawValue),
                "wasm_duration_us": .integer(durationUs),
                "wasm_budget_delta_us": .integer(budgetDeltaUs),
                "wasm_tool_id":   Self.canonical(toolId),
            ]
            if useV35Shape {
                columns["cached_prompt_tokens"]      = .null
                columns["cache_write_tokens"]        = .null
                columns["cache_read_tokens"]         = .null
                columns["prefill_ms_saved_estimate"] = .null
                columns["cache_origin"]              = .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 wasm_reason, wasm_duration_us, wasm_budget_delta_us, wasm_tool_id,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 3, paneId)
            Self.bindOptionalText(stmt, 4, normalizedRoot)
            sqlite3_bind_text(stmt, 5, ("wasm_kill" as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 6, toolId)
            sqlite3_bind_null(stmt, 7)  // model
            sqlite3_bind_int64(stmt, 8, 0)
            sqlite3_bind_int64(stmt, 9, 0)
            sqlite3_bind_int64(stmt, 10, 0)
            sqlite3_bind_int64(stmt, 11, 0)
            sqlite3_bind_text(stmt, 12, (reason.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)  // feature
            sqlite3_bind_null(stmt, 13)  // command
            sqlite3_bind_null(stmt, 14)  // model_tier
            sqlite3_bind_null(stmt, 15)  // connection_id
            sqlite3_bind_text(stmt, 16, (reason.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)  // wasm_reason
            sqlite3_bind_int64(stmt, 17, durationUs)
            sqlite3_bind_int64(stmt, 18, budgetDeltaUs)
            Self.bindOptionalText(stmt, 19, toolId)  // wasm_tool_id
            Self.bindOptionalText(stmt, 20, prevHash)
            sqlite3_bind_text(stmt, 21, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 22, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.11-pre a-3 — record a `workstream.<event>` chained audit row
    /// under the existing `token_events` chain. The row uses
    /// `source = "workstream.<event>"`, stores the workstream UUID
    /// string in `tool_name`, and stores the slug in `feature`. Reuses
    /// the v35 canonical shape (wasm_* + cached_* are .null), so no
    /// new columns are needed.
    ///
    /// Pre-v33 anchors refuse the write — workstream rows can only
    /// chain under post-v33 anchors so their canonical map matches
    /// the verifier's. If the table is still anchored to a pre-v33
    /// anchor (operator hand-migrated, or schema_version stamped
    /// without running migrations), the row is dropped silently so
    /// the driver's lifecycle path stays non-throwing.
    func recordWorkstreamEvent(
        workstreamID: UUID,
        slug: String,
        event: WorkstreamChainEvent
    ) {
        let now = Date().timeIntervalSince1970
        let uuidString = workstreamID.uuidString
        let source = event.rawValue
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let anchorReason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            // U.11a-1 (v39): `migration-v39` joins both shape sets —
            // v39 ships no new `token_events` columns. Workstream
            // rows recorded after the v39 migration anchor still
            // verify cleanly under the v35 canonical shape.
            let useV33Shape = (
                anchorReason == "migration-v33" ||
                anchorReason == "fresh-install-pre-v35" ||
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            let useV35Shape = (
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            guard useV33Shape else {
                Logger.log("workstream_event.drop", fields: [
                    "reason": .string("pre_v33_anchor"),
                    "anchor_reason": .string(anchorReason),
                    "source": .string(source),
                    "workstream_id": .string(uuidString),
                ])
                return
            }
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            // Workstream rows carry identity in `tool_name` (UUID
            // string) and `feature` (slug). All token-accounting
            // columns are zero; model/command/connection_id/pane_id/
            // project_root/model_tier are NULL; wasm_* and cached_*
            // are .null under whichever post-v33 shape applies.
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(uuidString),
                "pane_id":        .null,
                "project_root":   .null,
                "source":         .text(source),
                "tool_name":      .text(uuidString),
                "model":          .null,
                "input_tokens":   .integer(0),
                "output_tokens":  .integer(0),
                "saved_tokens":   .integer(0),
                "cost_cents":     .integer(0),
                "feature":        .text(slug),
                "command":        .null,
                "model_tier":     .null,
                "connection_id":  .null,
                "wasm_reason":    .null,
                "wasm_duration_us": .null,
                "wasm_budget_delta_us": .null,
                "wasm_tool_id":   .null,
            ]
            if useV35Shape {
                columns["cached_prompt_tokens"]      = .null
                columns["cache_write_tokens"]        = .null
                columns["cache_read_tokens"]         = .null
                columns["prefill_ms_saved_estimate"] = .null
                columns["cache_origin"]              = .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 3)   // pane_id
            sqlite3_bind_null(stmt, 4)   // project_root
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 6, (uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 7)   // model
            sqlite3_bind_int64(stmt, 8, 0)
            sqlite3_bind_int64(stmt, 9, 0)
            sqlite3_bind_int64(stmt, 10, 0)
            sqlite3_bind_int64(stmt, 11, 0)
            sqlite3_bind_text(stmt, 12, (slug as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)  // feature
            sqlite3_bind_null(stmt, 13)  // command
            sqlite3_bind_null(stmt, 14)  // model_tier
            sqlite3_bind_null(stmt, 15)  // connection_id
            Self.bindOptionalText(stmt, 16, prevHash)
            sqlite3_bind_text(stmt, 17, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 18, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.11a-1 — record a `contract.<event>` chained audit row under
    /// the existing `token_events` chain. The row uses
    /// `source = "contract.<event>"`, stores the contract UUID string
    /// in `tool_name`, the workstream UUID string in `feature`, and
    /// the contract UUID string in `session_id` (matches the
    /// `recordWorkstreamEvent` identity-packing convention so chain
    /// queries on `tool_name` find both kinds of rows).
    ///
    /// Reuses the v35 canonical shape (wasm_* + cached_* are .null),
    /// so v39 ships no new columns.
    ///
    /// Pre-v33 anchors refuse the write — contract rows can only
    /// chain under post-v33 anchors so their canonical map matches
    /// the verifier's. If the table is still anchored to a pre-v33
    /// anchor (operator hand-migrated, or schema_version stamped
    /// without running migrations), the row is dropped silently so
    /// the contract attach/advance path stays non-throwing.
    func recordContractEvent(
        contractID: UUID,
        workstreamID: UUID,
        event: ContractChainEvent
    ) {
        let now = Date().timeIntervalSince1970
        let contractIDString = contractID.uuidString
        let workstreamIDString = workstreamID.uuidString
        let source = event.rawValue
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let anchorReason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            let useV33Shape = (
                anchorReason == "migration-v33" ||
                anchorReason == "fresh-install-pre-v35" ||
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            let useV35Shape = (
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            guard useV33Shape else {
                Logger.log("contract_event.drop", fields: [
                    "reason": .string("pre_v33_anchor"),
                    "anchor_reason": .string(anchorReason),
                    "source": .string(source),
                    "contract_id": .string(contractIDString),
                    "workstream_id": .string(workstreamIDString),
                ])
                return
            }
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            // Contract rows pack identity in `tool_name` (contract UUID
            // string), the cross-reference in `feature` (workstream
            // UUID string), and a stable `session_id` (contract UUID
            // string) so chain queries that group by session find each
            // contract's full attach/advance history. All token-
            // accounting columns are zero; model/command/connection_id/
            // pane_id/project_root/model_tier are NULL; wasm_* and
            // cached_* are .null under whichever post-v33 shape applies.
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(contractIDString),
                "pane_id":        .null,
                "project_root":   .null,
                "source":         .text(source),
                "tool_name":      .text(contractIDString),
                "model":          .null,
                "input_tokens":   .integer(0),
                "output_tokens":  .integer(0),
                "saved_tokens":   .integer(0),
                "cost_cents":     .integer(0),
                "feature":        .text(workstreamIDString),
                "command":        .null,
                "model_tier":     .null,
                "connection_id":  .null,
                "wasm_reason":    .null,
                "wasm_duration_us": .null,
                "wasm_budget_delta_us": .null,
                "wasm_tool_id":   .null,
            ]
            if useV35Shape {
                columns["cached_prompt_tokens"]      = .null
                columns["cache_write_tokens"]        = .null
                columns["cache_read_tokens"]         = .null
                columns["prefill_ms_saved_estimate"] = .null
                columns["cache_origin"]              = .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (contractIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 3)   // pane_id
            sqlite3_bind_null(stmt, 4)   // project_root
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 6, (contractIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 7)   // model
            sqlite3_bind_int64(stmt, 8, 0)
            sqlite3_bind_int64(stmt, 9, 0)
            sqlite3_bind_int64(stmt, 10, 0)
            sqlite3_bind_int64(stmt, 11, 0)
            sqlite3_bind_text(stmt, 12, (workstreamIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)  // feature
            sqlite3_bind_null(stmt, 13)  // command
            sqlite3_bind_null(stmt, 14)  // model_tier
            sqlite3_bind_null(stmt, 15)  // connection_id
            Self.bindOptionalText(stmt, 16, prevHash)
            sqlite3_bind_text(stmt, 17, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 18, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.11a-2 — record an `assertion.record` chained audit row for a
    /// `ValidationAssertion` evidence write. Sibling of
    /// `recordContractEvent` — same identity-packing convention,
    /// same v35 canonical shape (wasm_* + cached_* are `.null`), same
    /// pre-v33 anchor refusal. v39 ships no new columns, so this
    /// writer carries no extra ledger bookkeeping.
    ///
    /// Identity layout:
    ///   - `source`       = `"assertion.record"`
    ///   - `session_id`   = assertion UUID string (chain-group key)
    ///   - `tool_name`    = assertion UUID string (identity)
    ///   - `feature`      = contract UUID string (cross-reference)
    ///   - `command`      = state raw value (`"pass"` / `"fail"` /
    ///                      `"partial"`) — the only non-null `command`
    ///                      among the U.11 chain-row writers; the
    ///                      column was already in the canonical map
    ///                      so this is a value change, not a shape
    ///                      change.
    ///
    /// Pre-v33 anchors silently drop with a `assertion_event.drop`
    /// Logger emission carrying `anchor_reason` / `source` /
    /// `assertion_id` / `contract_id`.
    func recordAssertionEvent(
        assertionID: UUID,
        contractID: UUID,
        state: AssertionState
    ) {
        let now = Date().timeIntervalSince1970
        let assertionIDString = assertionID.uuidString
        let contractIDString = contractID.uuidString
        let source = AssertionChainEvent.record.rawValue
        let stateString = state.rawValue
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let anchorReason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            let useV33Shape = (
                anchorReason == "migration-v33" ||
                anchorReason == "fresh-install-pre-v35" ||
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            let useV35Shape = (
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            guard useV33Shape else {
                Logger.log("assertion_event.drop", fields: [
                    "reason": .string("pre_v33_anchor"),
                    "anchor_reason": .string(anchorReason),
                    "source": .string(source),
                    "assertion_id": .string(assertionIDString),
                    "contract_id": .string(contractIDString),
                ])
                return
            }
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            // Identity layout — see method docstring. `command` carries
            // the assertion state; all other non-identity columns
            // either null or zero, matching the v35 canonical shape.
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(assertionIDString),
                "pane_id":        .null,
                "project_root":   .null,
                "source":         .text(source),
                "tool_name":      .text(assertionIDString),
                "model":          .null,
                "input_tokens":   .integer(0),
                "output_tokens":  .integer(0),
                "saved_tokens":   .integer(0),
                "cost_cents":     .integer(0),
                "feature":        .text(contractIDString),
                "command":        .text(stateString),
                "model_tier":     .null,
                "connection_id":  .null,
                "wasm_reason":    .null,
                "wasm_duration_us": .null,
                "wasm_budget_delta_us": .null,
                "wasm_tool_id":   .null,
            ]
            if useV35Shape {
                columns["cached_prompt_tokens"]      = .null
                columns["cache_write_tokens"]        = .null
                columns["cache_read_tokens"]         = .null
                columns["prefill_ms_saved_estimate"] = .null
                columns["cache_origin"]              = .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (assertionIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 3)   // pane_id
            sqlite3_bind_null(stmt, 4)   // project_root
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 6, (assertionIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 7)   // model
            sqlite3_bind_int64(stmt, 8, 0)
            sqlite3_bind_int64(stmt, 9, 0)
            sqlite3_bind_int64(stmt, 10, 0)
            sqlite3_bind_int64(stmt, 11, 0)
            sqlite3_bind_text(stmt, 12, (contractIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)  // feature
            sqlite3_bind_text(stmt, 13, (stateString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)        // command
            sqlite3_bind_null(stmt, 14)  // model_tier
            sqlite3_bind_null(stmt, 15)  // connection_id
            Self.bindOptionalText(stmt, 16, prevHash)
            sqlite3_bind_text(stmt, 17, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 18, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.11a-3 — record a `gate.evaluate` chained audit row for a
    /// `WorkflowGate` consult. Sibling of `recordAssertionEvent` —
    /// same identity-packing convention, same v35 canonical shape
    /// (wasm_* + cached_* are `.null`), same pre-v33 anchor refusal.
    /// v39 ships no new columns, so this writer carries no extra
    /// ledger bookkeeping.
    ///
    /// Identity layout:
    ///   - `source`       = `"gate.evaluate"`
    ///   - `session_id`   = gate UUID string (chain-group key)
    ///   - `tool_name`    = gate UUID string (identity)
    ///   - `feature`      = contract UUID string (cross-reference)
    ///   - `command`      = outcome raw identifier (`"blocked"` /
    ///                      `"warned"` / `"advisory"`) — same column
    ///                      reuse as a-2's `recordAssertionEvent`
    ///                      (value change, not shape change).
    ///
    /// Pre-v33 anchors silently drop with a `gate.evaluate.drop`
    /// Logger emission carrying `anchor_reason` / `source` /
    /// `gate_id` / `contract_id`.
    func recordGateEvent(
        gateID: UUID,
        contractID: UUID,
        outcome: GateOutcome
    ) {
        let now = Date().timeIntervalSince1970
        let gateIDString = gateID.uuidString
        let contractIDString = contractID.uuidString
        let source = GateChainEvent.evaluate.rawValue
        let outcomeString = outcome.rawIdentifier
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let anchorReason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            let useV33Shape = (
                anchorReason == "migration-v33" ||
                anchorReason == "fresh-install-pre-v35" ||
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            let useV35Shape = (
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            guard useV33Shape else {
                Logger.log("gate.evaluate.drop", fields: [
                    "reason": .string("pre_v33_anchor"),
                    "anchor_reason": .string(anchorReason),
                    "source": .string(source),
                    "gate_id": .string(gateIDString),
                    "contract_id": .string(contractIDString),
                ])
                return
            }
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            // Identity layout — see method docstring. `command` carries
            // the gate outcome raw identifier; all other non-identity
            // columns either null or zero, matching the v35 canonical
            // shape.
            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(gateIDString),
                "pane_id":        .null,
                "project_root":   .null,
                "source":         .text(source),
                "tool_name":      .text(gateIDString),
                "model":          .null,
                "input_tokens":   .integer(0),
                "output_tokens":  .integer(0),
                "saved_tokens":   .integer(0),
                "cost_cents":     .integer(0),
                "feature":        .text(contractIDString),
                "command":        .text(outcomeString),
                "model_tier":     .null,
                "connection_id":  .null,
                "wasm_reason":    .null,
                "wasm_duration_us": .null,
                "wasm_budget_delta_us": .null,
                "wasm_tool_id":   .null,
            ]
            if useV35Shape {
                columns["cached_prompt_tokens"]      = .null
                columns["cache_write_tokens"]        = .null
                columns["cache_read_tokens"]         = .null
                columns["prefill_ms_saved_estimate"] = .null
                columns["cache_origin"]              = .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (gateIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 3)   // pane_id
            sqlite3_bind_null(stmt, 4)   // project_root
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 6, (gateIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 7)   // model
            sqlite3_bind_int64(stmt, 8, 0)
            sqlite3_bind_int64(stmt, 9, 0)
            sqlite3_bind_int64(stmt, 10, 0)
            sqlite3_bind_int64(stmt, 11, 0)
            sqlite3_bind_text(stmt, 12, (contractIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)  // feature
            sqlite3_bind_text(stmt, 13, (outcomeString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)      // command
            sqlite3_bind_null(stmt, 14)  // model_tier
            sqlite3_bind_null(stmt, 15)  // connection_id
            Self.bindOptionalText(stmt, 16, prevHash)
            sqlite3_bind_text(stmt, 17, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 18, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.11a-4 — record a `handoff.open` or `handoff.close` chained
    /// audit row for a `BlockedHandoff` lifecycle event. Sibling of
    /// `recordGateEvent` — same identity-packing convention, same v35
    /// canonical shape (wasm_* + cached_* are `.null`), same pre-v33
    /// anchor refusal. v40 ships no new `token_events` columns, so
    /// this writer carries no extra ledger bookkeeping.
    ///
    /// Identity layout:
    ///   - `source`       = `"handoff.open"` / `"handoff.close"`
    ///   - `session_id`   = handoff UUID string (chain-group key)
    ///   - `tool_name`    = handoff UUID string (identity)
    ///   - `feature`      = contract UUID string (cross-reference;
    ///                      mirrors gate.evaluate's contract pointer)
    ///   - `command`      = gate UUID string — audit pointer back to
    ///                      the refusing gate. Both `.open` and
    ///                      `.close` carry the same gate id so a
    ///                      query for "all handoff rows for gate X"
    ///                      is a single source-LIKE + command match.
    ///
    /// Pre-v33 anchors silently drop with a `handoff_event.drop`
    /// Logger emission carrying `anchor_reason` / `source` /
    /// `handoff_id` / `contract_id`.
    func recordHandoffEvent(
        handoffID: UUID,
        workstreamID: UUID,
        contractID: UUID,
        gateID: UUID,
        event: HandoffChainEvent
    ) {
        let now = Date().timeIntervalSince1970
        let handoffIDString = handoffID.uuidString
        let contractIDString = contractID.uuidString
        let gateIDString = gateID.uuidString
        let workstreamIDString = workstreamID.uuidString
        let source = event.rawValue
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.chain.resolveAnchorId(db: db)
            let anchorReason = self.chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            let useV33Shape = (
                anchorReason == "migration-v33" ||
                anchorReason == "fresh-install-pre-v35" ||
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            let useV35Shape = (
                anchorReason == "migration-v35" ||
                anchorReason == "fresh-install" ||
                anchorReason == "migration-v38" ||
                anchorReason == "migration-v39" ||
                anchorReason == "migration-v40"
            )
            guard useV33Shape else {
                Logger.log("handoff_event.drop", fields: [
                    "reason": .string("pre_v33_anchor"),
                    "anchor_reason": .string(anchorReason),
                    "source": .string(source),
                    "handoff_id": .string(handoffIDString),
                    "contract_id": .string(contractIDString),
                    "workstream_id": .string(workstreamIDString),
                ])
                return
            }
            let prevHash = self.chain.latestEntryHash(db: db, anchorId: anchorId)

            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":      .real(now),
                "session_id":     .text(handoffIDString),
                "pane_id":        .null,
                "project_root":   .null,
                "source":         .text(source),
                "tool_name":      .text(handoffIDString),
                "model":          .null,
                "input_tokens":   .integer(0),
                "output_tokens":  .integer(0),
                "saved_tokens":   .integer(0),
                "cost_cents":     .integer(0),
                "feature":        .text(contractIDString),
                "command":        .text(gateIDString),
                "model_tier":     .null,
                "connection_id":  .null,
                "wasm_reason":    .null,
                "wasm_duration_us": .null,
                "wasm_budget_delta_us": .null,
                "wasm_tool_id":   .null,
            ]
            if useV35Shape {
                columns["cached_prompt_tokens"]      = .null
                columns["cache_write_tokens"]        = .null
                columns["cache_read_tokens"]         = .null
                columns["prefill_ms_saved_estimate"] = .null
                columns["cache_origin"]              = .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "token_events", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO token_events
                (timestamp, session_id, pane_id, project_root, source, tool_name, model,
                 input_tokens, output_tokens, saved_tokens, cost_cents, feature, command, model_tier,
                 connection_id,
                 prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (handoffIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 3)
            sqlite3_bind_null(stmt, 4)
            sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 6, (handoffIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 7)
            sqlite3_bind_int64(stmt, 8, 0)
            sqlite3_bind_int64(stmt, 9, 0)
            sqlite3_bind_int64(stmt, 10, 0)
            sqlite3_bind_int64(stmt, 11, 0)
            sqlite3_bind_text(stmt, 12, (contractIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 13, (gateIDString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_null(stmt, 14)
            sqlite3_bind_null(stmt, 15)
            Self.bindOptionalText(stmt, 16, prevHash)
            sqlite3_bind_text(stmt, 17, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 18, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// U.11a-4 — persist a `BlockedHandoff` to the dedicated
    /// `workstream_handoffs` chained table. The table is its OWN T.5
    /// chain (sibling to `token_events` / `trust_audits` /
    /// `validation_results`), so chain state is tracked on
    /// `handoffChain` — independent from this writer's `token_events`
    /// anchor.
    ///
    /// The canonical-hash column map encodes each BLOB UUID as the
    /// UUID's RFC-4122 string form so the verifier can re-derive the
    /// same payload from `sqlite3_column_blob` → UUID(uuid:) →
    /// uuid.uuidString. INTEGER `created_at` is bound as seconds-
    /// since-epoch (consistent with `workstreams.created_at`).
    ///
    /// `contract_id` is required (NOT NULL + FK to
    /// `workstream_contracts.id`) and is passed separately because
    /// `BlockedHandoff` itself only carries `workstreamID` + `gateID`
    /// — the driver holds the contract reference via
    /// `attachedContract` and threads it through to the writer.
    ///
    /// `evidenceBundle` serializes to a JSON array TEXT — the
    /// canonical hash treats it as `.text(jsonString)` so the
    /// verifier can re-encode the same string deterministically.
    func recordBlockedHandoff(
        handoff: BlockedHandoff,
        contractID: UUID
    ) {
        let now = Date().timeIntervalSince1970
        let createdAt = Int64(now)
        let handoffIDString = handoff.id.uuidString
        let workstreamIDString = handoff.workstreamID.uuidString
        let contractIDString = contractID.uuidString
        let gateIDString = handoff.gateID.uuidString
        let ownerString = handoff.owner.rawValue
        let reason = handoff.blockerReason
        let nextAction = handoff.nextAction
        // Stable, sorted-key JSON would be overkill — Swift's default
        // JSONEncoder preserves the array order we hand in, which is
        // what we want. Failures fall back to '[]' (matches the column
        // default). Encoding only string arrays so a failure here is
        // an out-of-memory event, not a malformed-input event.
        let evidenceJSON: String = {
            do {
                let data = try JSONEncoder().encode(handoff.evidenceBundle)
                return String(data: data, encoding: .utf8) ?? "[]"
            } catch {
                return "[]"
            }
        }()
        parent.queue.async { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return }

            let anchorId = self.handoffChain.resolveAnchorId(db: db)
            let prevHash = self.handoffChain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "id":              .text(handoffIDString),
                "workstream_id":   .text(workstreamIDString),
                "contract_id":     .text(contractIDString),
                "gate_id":         .text(gateIDString),
                "blocker_reason":  .text(reason),
                "owner":           .text(ownerString),
                "next_action":     .text(nextAction),
                "evidence_bundle": .text(evidenceJSON),
                "created_at":      .integer(createdAt),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "workstream_handoffs", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO workstream_handoffs
                    (id, workstream_id, contract_id, gate_id,
                     blocker_reason, owner, next_action, evidence_bundle,
                     created_at, prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            Self.bindUUIDBlob(stmt, 1, handoff.id)
            Self.bindUUIDBlob(stmt, 2, handoff.workstreamID)
            Self.bindUUIDBlob(stmt, 3, contractID)
            Self.bindUUIDBlob(stmt, 4, handoff.gateID)
            sqlite3_bind_text(stmt, 5, (reason as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 6, (ownerString as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 7, (nextAction as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 8, (evidenceJSON as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 9, createdAt)
            Self.bindOptionalText(stmt, 10, prevHash)
            sqlite3_bind_text(stmt, 11, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 12, anchorId)

            if sqlite3_step(stmt) == SQLITE_DONE {
                self.handoffChain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            }
        }
    }

    /// V.17c — persist an accepted thread handoff to the dedicated
    /// `thread_handoff_event` chained table. Synchronous so the accept
    /// path gets a typed outcome (recorded / dedup / rejected) and the
    /// caller can act on it without a `sqlite3_changes` re-read.
    ///
    /// Override discipline (acceptance §4): a force-import past a BLOCKED
    /// predicate MUST carry a non-empty `overrideReason`. The writer
    /// rejects a whitespace-only / empty override reason and returns
    /// `.rejectedMissingOverrideReason` WITHOUT writing — overrides
    /// never silently land. A normal (non-override) accepted handoff
    /// passes `overrideReason == nil`, stored as a NULL column.
    ///
    /// Dedup (acceptance §"double-handoff"): a UNIQUE index on
    /// `(thread_id, to_provider)` makes a re-import of the same thread
    /// into the same target provider idempotent — the second call
    /// returns `.idempotencyHit` and no second row lands. The chain is
    /// not advanced on a dedup hit (no `recordWrite`), so its integrity
    /// is unaffected.
    @discardableResult
    func recordThreadHandoff(_ handoff: ThreadHandoff) -> ThreadHandoffOutcome {
        // Override-without-justification is rejected at the door —
        // before any DB work — so the rejection is total: no anchor is
        // opened, no row is attempted.
        if let reason = handoff.overrideReason,
           reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejectedMissingOverrideReason
        }

        let now = Date().timeIntervalSince1970
        return parent.queue.sync { [weak parent, weak self] in
            guard let parent, let self, let db = parent.db else { return .idempotencyHit }

            let anchorId = self.threadHandoffChain.resolveAnchorId(db: db)
            let prevHash = self.threadHandoffChain.latestEntryHash(db: db, anchorId: anchorId)

            // Canonical-hash column map mirrors the verifier's
            // `verifyAnchorThreadHandoffEvent` exactly. `override_reason`
            // is `.null` for a normal handoff, `.text` for an override.
            let columns: [String: ChainHasher.CanonicalValue] = [
                "created_at":               .real(now),
                "from_provider":            .text(handoff.fromProvider),
                "to_provider":              .text(handoff.toProvider),
                "thread_id":                .text(handoff.threadID),
                "accepted_by":              .text(handoff.acceptedBy),
                "pre_handoff_event_count":  .integer(Int64(handoff.preHandoffEventCount)),
                "post_handoff_event_count": .integer(Int64(handoff.postHandoffEventCount)),
                "override_reason":          handoff.overrideReason.map { .text($0) } ?? .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: "thread_handoff_event", columns: columns, prev: prevHash
            )

            // `INSERT OR IGNORE` against the (thread_id, to_provider)
            // UNIQUE index gives at-SQL dedup. sqlite3_changes == 0 after
            // a DONE step means the dedup index refused the row.
            let sql = """
                INSERT OR IGNORE INTO thread_handoff_event
                    (created_at, from_provider, to_provider, thread_id, accepted_by,
                     pre_handoff_event_count, post_handoff_event_count, override_reason,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .idempotencyHit }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (handoff.fromProvider as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (handoff.toProvider as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 4, (handoff.threadID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 5, (handoff.acceptedBy as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 6, Int64(handoff.preHandoffEventCount))
            sqlite3_bind_int64(stmt, 7, Int64(handoff.postHandoffEventCount))
            Self.bindOptionalText(stmt, 8, handoff.overrideReason)
            Self.bindOptionalText(stmt, 9, prevHash)
            sqlite3_bind_text(stmt, 10, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 11, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return .idempotencyHit }
            if sqlite3_changes(db) > 0 {
                self.threadHandoffChain.recordWrite(anchorId: anchorId, entryHash: entryHash)
                return .recorded
            }
            return .idempotencyHit
        }
    }

    /// V.17c — count of `thread_handoff_event` rows. Test affordance +
    /// dedup verification.
    func threadHandoffCount() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM thread_handoff_event;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// V.17c — read back the (pre, post, override_reason) of the latest
    /// `thread_handoff_event` row for a thread. Test affordance so the
    /// audit-row assertions don't re-implement a SELECT.
    func latestThreadHandoff(threadID: String) -> (pre: Int, post: Int, overrideReason: String?)? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT pre_handoff_event_count, post_handoff_event_count, override_reason
                  FROM thread_handoff_event
                 WHERE thread_id = ?
                 ORDER BY id DESC LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (threadID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let pre = Int(sqlite3_column_int64(stmt, 0))
            let post = Int(sqlite3_column_int64(stmt, 1))
            let override: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            return (pre, post, override)
        }
    }

    /// Bind a 16-byte UUID to a BLOB column. Helper used by U.11a-4
    /// `workstream_handoffs` writes; sibling helpers in
    /// `PaneSessionDriver.bindUUID` follow the same withUnsafeBytes
    /// + SQLITE_TRANSIENT pattern.
    fileprivate static func bindUUIDBlob(_ stmt: OpaquePointer?, _ idx: Int32, _ uuid: UUID) {
        var bytes = uuid.uuid
        withUnsafeBytes(of: &bytes) { raw in
            _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT_DESTRUCTOR)
        }
    }

    // MARK: - T.5 chain helpers (round 2; generalised in round 3)

    /// Coerce an optional string to a `ChainHasher.CanonicalValue` — empty
    /// strings count as text per SQLite semantics; nil becomes NULL.
    private static func canonical(_ value: String?) -> ChainHasher.CanonicalValue {
        guard let value else { return .null }
        return .text(value)
    }

    /// Coerce an optional Int to a `ChainHasher.CanonicalValue` — nil
    /// becomes NULL, populated values become `.integer`. Mirrors the
    /// SQLite bind path: `bindOptionalInt` binds `NULL` for nil,
    /// `Int64` for populated. Used by the V.19a-2 (v35) cached-token
    /// columns so the canonical map matches what the verifier reads
    /// back from `sqlite3_column_type == SQLITE_NULL`.
    private static func canonicalInt(_ value: Int?) -> ChainHasher.CanonicalValue {
        guard let value else { return .null }
        return .integer(Int64(value))
    }

    /// Record a hook event from the senkani-hook binary. Rows land in
    /// `token_events` with `source='hook'` — there is no separate
    /// `hook_events` table. Delegates to `recordTokenEvent`.
    func recordHookEvent(
        sessionId: String,
        toolName: String,
        eventType: String,
        projectRoot: String?
    ) {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        recordTokenEvent(
            sessionId: sessionId,
            paneId: nil,
            projectRoot: normalizedRoot,
            source: "hook",
            toolName: toolName,
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0,
            feature: eventType,
            command: nil
        )
    }

    // MARK: - Existence probes

    /// Returns true when at least one `token_events` row has the given
    /// `(source, feature)` pair. Used by `senkani doctor
    /// --install-validation-browser` to idempotently skip writing a
    /// second `validation.browser.install` audit row on re-invocation.
    func tokenEventExists(source: String, feature: String) -> Bool {
        return parent.queue.sync {
            guard let db = parent.db else { return false }
            let sql = """
                SELECT 1 FROM token_events
                WHERE source = ? AND feature = ?
                LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (feature as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: - Stats

    /// Aggregate stats for a project (sidebar display). Optionally scoped to a start date.
    func tokenStatsForProject(_ projectRoot: String, since: Date? = nil) -> PaneTokenStats {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return .zero }
            let hasSince = since != nil
            let sql = """
                SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0), COALESCE(SUM(cost_cents),0), COUNT(*)
                FROM token_events WHERE project_root = ?\(hasSince ? " AND timestamp >= ?" : "")
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let since {
                sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return PaneTokenStats(
                    inputTokens: Int(sqlite3_column_int64(stmt, 0)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    savedTokens: Int(sqlite3_column_int64(stmt, 2)),
                    costCents: Int(sqlite3_column_int64(stmt, 3)),
                    commandCount: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return .zero
        }
    }

    /// Aggregate stats across ALL projects (for app-level status bar).
    /// Windowed to the last 90 days to prevent full-table scans on large DBs.
    func tokenStatsAllProjects() -> PaneTokenStats {
        return parent.queue.sync {
            guard let db = parent.db else { return .zero }
            let cutoff = Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970
            let sql = """
                SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0), COALESCE(SUM(cost_cents),0), COUNT(*)
                FROM token_events
                WHERE timestamp >= ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .zero }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return PaneTokenStats(
                    inputTokens: Int(sqlite3_column_int64(stmt, 0)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    savedTokens: Int(sqlite3_column_int64(stmt, 2)),
                    costCents: Int(sqlite3_column_int64(stmt, 3)),
                    commandCount: Int(sqlite3_column_int64(stmt, 4))
                )
            }
            return .zero
        }
    }

    /// Per-feature token savings breakdown, sorted by savedTokens descending.
    func tokenStatsByFeature(projectRoot: String, since: Date? = nil) -> [SessionDatabase.FeatureSavings] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let hasSince = since != nil
            let sql = """
                SELECT COALESCE(feature, 'unknown'),
                       COALESCE(SUM(saved_tokens), 0),
                       COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0),
                       COUNT(*)
                FROM token_events
                WHERE project_root = ?\(hasSince ? " AND timestamp >= ?" : "")
                AND saved_tokens > 0
                GROUP BY feature
                ORDER BY SUM(saved_tokens) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let since {
                sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            }

            var results: [SessionDatabase.FeatureSavings] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let feature = String(cString: sqlite3_column_text(stmt, 0))
                let saved = Int(sqlite3_column_int64(stmt, 1))
                let input = Int(sqlite3_column_int64(stmt, 2))
                let output = Int(sqlite3_column_int64(stmt, 3))
                let count = Int(sqlite3_column_int64(stmt, 4))
                results.append(SessionDatabase.FeatureSavings(
                    feature: feature,
                    savedTokens: saved,
                    inputTokens: input,
                    outputTokens: output,
                    eventCount: count
                ))
            }
            return results
        }
    }

    /// Per-feature savings across ALL projects (no project filter).
    func tokenStatsByFeatureAllProjects(since: Date? = nil) -> [SessionDatabase.FeatureSavings] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT feature, COALESCE(SUM(saved_tokens),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COUNT(*)
                FROM token_events
                WHERE feature IS NOT NULL AND feature != ''
            """
            if since != nil { sql += " AND timestamp >= ?" }
            sql += " GROUP BY feature ORDER BY SUM(saved_tokens) DESC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var results: [SessionDatabase.FeatureSavings] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(SessionDatabase.FeatureSavings(
                    feature: String(cString: sqlite3_column_text(stmt, 0)),
                    savedTokens: Int(sqlite3_column_int64(stmt, 1)),
                    inputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 3)),
                    eventCount: Int(sqlite3_column_int64(stmt, 4))
                ))
            }
            return results
        }
    }

    /// Overall live-session compression multiplier for a project.
    /// Returns raw / compressed = (inputTokens + savedTokens) / inputTokens.
    /// Returns nil when no matching events exist.
    func liveSessionMultiplier(projectRoot: String, since: Date? = nil) -> Double? {
        let stats = tokenStatsByFeature(projectRoot: projectRoot, since: since)
        let totalInput = stats.reduce(0) { $0 + $1.inputTokens }
        let totalSaved = stats.reduce(0) { $0 + $1.savedTokens }
        guard totalInput > 0 else { return nil }
        return Double(totalInput + totalSaved) / Double(totalInput)
    }

    // MARK: - Analytics (chart + timeline)

    /// Time-series data for the savings-over-time chart.
    func savingsTimeSeries(projectRoot: String, since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT timestamp, input_tokens, saved_tokens
                FROM token_events
                WHERE project_root = ?
            """
            if since != nil { sql += " AND timestamp >= ?" }
            sql += " ORDER BY timestamp ASC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let since { sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970) }

            var results: [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] = []
            var cumRaw = 0
            var cumSaved = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let input = Int(sqlite3_column_int64(stmt, 1))
                let saved = Int(sqlite3_column_int64(stmt, 2))
                cumRaw += input * 4
                cumSaved += saved * 4
                results.append((timestamp: ts, cumulativeRaw: cumRaw, cumulativeSaved: cumSaved))
            }
            return results
        }
    }

    /// Time-series data across ALL projects (no project filter).
    func savingsTimeSeriesAllProjects(since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            var sql = """
                SELECT timestamp, input_tokens, saved_tokens
                FROM token_events
                WHERE 1=1
            """
            if since != nil { sql += " AND timestamp >= ?" }
            sql += " ORDER BY timestamp ASC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let since { sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970) }

            var results: [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] = []
            var cumRaw = 0
            var cumSaved = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                cumRaw += Int(sqlite3_column_int64(stmt, 1)) * 4
                cumSaved += Int(sqlite3_column_int64(stmt, 2)) * 4
                results.append((timestamp: ts, cumulativeRaw: cumRaw, cumulativeSaved: cumSaved))
            }
            return results
        }
    }

    /// Fetch the most recent token events for a project, newest first.
    func recentTokenEvents(projectRoot: String, limit: Int = 100) -> [SessionDatabase.TimelineEvent] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, timestamp, source, tool_name, feature, command,
                       input_tokens, output_tokens, saved_tokens, cost_cents,
                       session_id
                FROM token_events
                WHERE project_root = ?
                ORDER BY timestamp DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            return Self.parseTimelineRows(stmt)
        }
    }

    /// V.19a-4 — fetch recent token_events rows that carry cached-token
    /// observations (either `cache_origin IS NOT NULL` or
    /// `cached_prompt_tokens > 0`). Used by the Models/Inference
    /// dashboard tile to JOIN against `cache_lifecycle` spans on
    /// `session_id`. Narrow projection (no command, no feature) per
    /// V.18 metadata-only privacy default — the tile renders scalars
    /// + tier strings + enums only.
    func recentCachedTokenEvents(limit: Int = 200) -> [MLXInferenceTileCorrelator.TokenEventRow] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT timestamp, session_id, cached_prompt_tokens, cache_origin, model_tier
                FROM token_events
                WHERE cache_origin IS NOT NULL
                   OR (cached_prompt_tokens IS NOT NULL AND cached_prompt_tokens > 0)
                ORDER BY timestamp DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [MLXInferenceTileCorrelator.TokenEventRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_double(stmt, 0)
                let sessionId: String = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? "" : String(cString: sqlite3_column_text(stmt, 1))
                guard !sessionId.isEmpty else { continue }
                let cachedTokens: Int = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? 0 : Int(sqlite3_column_int64(stmt, 2))
                let originRaw: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 3))
                let origin: CacheOrigin? = originRaw.flatMap(CacheOrigin.init(rawValue:))
                let tier: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 4))
                rows.append(MLXInferenceTileCorrelator.TokenEventRow(
                    sessionId: sessionId,
                    cachedPromptTokens: cachedTokens,
                    cacheOrigin: origin,
                    modelTier: tier,
                    timestamp: Date(timeIntervalSince1970: ts)
                ))
            }
            return rows
        }
    }

    /// Fetch the most recent token events across ALL projects.
    func recentTokenEventsAllProjects(limit: Int = 100) -> [SessionDatabase.TimelineEvent] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, timestamp, source, tool_name, feature, command,
                       input_tokens, output_tokens, saved_tokens, cost_cents,
                       session_id
                FROM token_events
                ORDER BY timestamp DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            return Self.parseTimelineRows(stmt)
        }
    }

    // MARK: - Schedule-end reconcile (t6-schedule-end-cli-to-app-bridge LEG A)

    /// One `schedule_end` row reconstructed for the reconcile drain. The
    /// reconciler needs only the dedup key (`sessionId`) plus the banner
    /// fields (`scheduleId`, `summary`); the id is the cursor watermark.
    struct ScheduleEndRow: Equatable {
        let id: Int64
        let sessionId: String
        let scheduleId: String
        let summary: String
        /// Epoch seconds from `token_events.timestamp` (already written +
        /// indexed — NO migration). Surfaced for the cold-start recency floor
        /// in `ScheduleEndReconciler`. A NULL/absent stamp reads as 0 (epoch
        /// 1970) so an unstampable row is treated as old → floored (silent) on
        /// a cold start, never replayed as a stale relaunch banner.
        let timestamp: Double
    }

    /// Pull `schedule_end` `token_events` rows with `id > afterId`, oldest
    /// first, up to `limit`. id-ASC is MANDATORY: the reconciler advances a
    /// monotonic cursor to `rows.last.id` AFTER delivering the batch, so the
    /// pull order IS the cursor order.
    ///
    /// Filters on `ScheduleTelemetry.source` / `.featureEnd` (the SAME
    /// constants `recordEnd` writes) — never string literals — so a producer
    /// rename can't silently strand this consumer.
    ///
    /// Per-row reconstruction (the producer writes `command =
    /// "{taskName}: {result}"` and `session_id = "schedule:{taskName}:{runId}"`):
    ///   - `sessionId` = the `session_id` column verbatim (the dedup key).
    ///   - `scheduleId` = the `command` prefix before the FIRST `": "`
    ///     (so `"nightly backup: failed: exit 1"` → `"nightly backup"`).
    ///     Falls back to the whole command, then to the session_id's middle
    ///     segment, so a malformed row still yields a non-empty id.
    ///   - `summary` = the `command` suffix after `"{scheduleId}: "` (so the
    ///     example → `"failed: exit 1"`). Falls back to the whole command.
    func scheduleEndEventsSince(afterId: Int64, limit: Int) -> [ScheduleEndRow] {
        return parent.queue.sync { () -> [ScheduleEndRow] in
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, session_id, command, timestamp
                FROM token_events
                WHERE source = ? AND feature = ? AND id > ?
                ORDER BY id ASC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (ScheduleTelemetry.source as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (ScheduleTelemetry.featureEnd as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 3, afterId)
            sqlite3_bind_int(stmt, 4, Int32(limit))

            var rows: [ScheduleEndRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let sessionId: String = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? "" : String(cString: sqlite3_column_text(stmt, 1))
                let command: String = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? "" : String(cString: sqlite3_column_text(stmt, 2))
                // Epoch seconds; NULL → 0 (treated as old → floored on cold start).
                let timestamp = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? 0.0 : sqlite3_column_double(stmt, 3)
                let (scheduleId, summary) = Self.reconstructScheduleEnd(
                    command: command, sessionId: sessionId
                )
                rows.append(ScheduleEndRow(
                    id: id, sessionId: sessionId, scheduleId: scheduleId, summary: summary,
                    timestamp: timestamp
                ))
            }
            return rows
        }
    }

    /// Split the producer's `command` ("{taskName}: {result}") back into
    /// `(scheduleId, summary)`. Pure + total — every fallback yields a
    /// non-empty scheduleId so a malformed row still delivers.
    static func reconstructScheduleEnd(command: String, sessionId: String) -> (scheduleId: String, summary: String) {
        if let r = command.range(of: ": ") {
            let scheduleId = String(command[command.startIndex..<r.lowerBound])
            let summary = String(command[r.upperBound...])
            if !scheduleId.isEmpty {
                return (scheduleId, summary)
            }
        }
        // No "{name}: {result}" shape — fall back to the whole command as the
        // id, then to the session_id middle segment ("schedule:{name}:{runId}").
        if !command.isEmpty {
            return (command, command)
        }
        let segments = sessionId.split(separator: ":", omittingEmptySubsequences: false)
        if segments.count >= 2 {
            return (String(segments[1]), "")
        }
        return (sessionId, "")
    }

    /// Read the reconcile consumer's high-water cursor (the
    /// `session_event_stream_offsets` row for `consumerId`). Returns 0 when
    /// absent — fail-OPEN to a full re-scan, NEVER fail-closed to head. A
    /// reset/missing cursor re-scans and the sessionId ledger dedups, so it
    /// can only cost a re-scan, never a double-deliver. Inlined here (rather
    /// than widening `SessionEventStreamStore`) to keep the change surgical.
    func scheduleEndReconcileCursor(consumerId: String) -> Int64 {
        return parent.queue.sync { () -> Int64 in
            guard let db = parent.db else { return 0 }
            let sql = "SELECT last_processed_event_id FROM session_event_stream_offsets WHERE consumer_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (consumerId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Advance the reconcile cursor to `eventId` via the REUSED, monotonic +
    /// idempotent `commitOffset` (`ON CONFLICT … MAX(...)`). A lower value is
    /// a no-op; a crash before this call re-scans next run (ledger dedups).
    func advanceScheduleEndReconcileCursor(consumerId: String, to eventId: Int64) {
        parent.sessionEventStreamStore.commitOffset(consumerId: consumerId, upTo: eventId)
    }

    private static func parseTimelineRows(_ stmt: OpaquePointer?) -> [SessionDatabase.TimelineEvent] {
        var results: [SessionDatabase.TimelineEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let source = String(cString: sqlite3_column_text(stmt, 2))
            let toolName: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 3))
            let feature: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 4))
            let command: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 5))
            let input = Int(sqlite3_column_int64(stmt, 6))
            let output = Int(sqlite3_column_int64(stmt, 7))
            let saved = Int(sqlite3_column_int64(stmt, 8))
            let cost = Int(sqlite3_column_int64(stmt, 9))
            let sessionId: String? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 10))

            results.append(SessionDatabase.TimelineEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                source: source,
                toolName: toolName,
                feature: feature,
                command: command,
                inputTokens: input,
                outputTokens: output,
                savedTokens: saved,
                costCents: cost,
                sessionId: sessionId
            ))
        }
        return results
    }

    // MARK: - Re-read suppression + hot files + session summaries

    /// Return the timestamp of the most recent `senkani_read` of a specific file
    /// within a project. Returns nil if the file has never been read in this session.
    func lastReadTimestamp(filePath: String, projectRoot: String) -> Date? {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT MAX(timestamp) FROM token_events
                WHERE project_root = ? AND tool_name = 'read' AND source = 'mcp_tool'
                AND command LIKE ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            let sanitized = filePath.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "\\_")
            let pathPattern = "%" + sanitized
            sqlite3_bind_text(stmt, 2, (pathPattern as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            let ts = sqlite3_column_double(stmt, 0)
            return Date(timeIntervalSince1970: ts)
        }
    }

    /// Top N most-accessed file paths for a project, ranked by frequency.
    /// Backed by the composite `idx_token_events_project_tool_time` index.
    func hotFiles(projectRoot: String, limit: Int = 50, sinceDaysAgo: Int = 7) -> [(path: String, freq: Int)] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        let cutoff = Date().addingTimeInterval(-Double(sinceDaysAgo) * 86400).timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT command, COUNT(*) as freq
                FROM token_events
                WHERE project_root = ?
                AND timestamp >= ?
                AND command IS NOT NULL AND command != ''
                AND (tool_name IN ('read', 'outline_read', 'senkani_read') OR feature IN ('cache', 'reread_suppression'))
                GROUP BY command
                ORDER BY freq DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_double(stmt, 2, cutoff)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var results: [(path: String, freq: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { continue }
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let freq = Int(sqlite3_column_int(stmt, 1))
                results.append((path: path, freq: freq))
            }
            return results
        }
    }

    func sessionSummaries(projectRoot: String, limit: Int = 20) -> [SessionDatabase.SessionSummary] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT te.session_id,
                       MIN(te.timestamp) as started,
                       SUM(te.input_tokens + te.output_tokens + te.saved_tokens) as raw_total,
                       SUM(te.saved_tokens) as saved_total
                FROM token_events te
                WHERE te.project_root = ?
                AND te.source IN ('mcp_tool', 'intercept')
                GROUP BY te.session_id
                HAVING raw_total > 0
                ORDER BY started DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [SessionDatabase.SessionSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = String(cString: sqlite3_column_text(stmt, 0))
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let raw = Int(sqlite3_column_int64(stmt, 2))
                let saved = Int(sqlite3_column_int64(stmt, 3))
                results.append(SessionDatabase.SessionSummary(
                    sessionId: sid, startedAt: ts,
                    totalRawTokens: raw, totalSavedTokens: saved
                ))
            }
            return results
        }
    }

    // MARK: - Compound learning queries

    /// Query token_events for recurring exec commands with poor filter savings.
    func unfilteredExecCommands(
        projectRoot: String,
        minSessions: Int = 2,
        minInputTokens: Int = 100
    ) -> [SessionDatabase.UnfilteredCommandRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT command,
                       COUNT(DISTINCT session_id) AS session_count,
                       CAST(AVG(input_tokens) AS INTEGER) AS avg_input,
                       AVG(CAST(saved_tokens AS REAL) * 100.0 / NULLIF(input_tokens, 0)) AS avg_saved_pct
                FROM token_events
                WHERE tool_name = 'exec'
                  AND project_root = ?
                  AND command IS NOT NULL
                  AND command != ''
                  AND input_tokens > ?
                GROUP BY command
                HAVING avg_saved_pct < 15.0
                   AND session_count >= ?
                ORDER BY avg_input DESC
                LIMIT 20;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 2, Int32(minInputTokens))
            sqlite3_bind_int(stmt, 3, Int32(minSessions))

            var rows: [SessionDatabase.UnfilteredCommandRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let avgInput = Int(sqlite3_column_int64(stmt, 2))
                let avgPct = sqlite3_column_double(stmt, 3)
                rows.append(SessionDatabase.UnfilteredCommandRow(
                    command: cmd,
                    sessionCount: sessions,
                    avgInputTokens: avgInput,
                    avgSavedPct: avgPct
                ))
            }
            return rows
        }
    }

    func recurringFileMentions(
        projectRoot: String,
        minSessions: Int = 3,
        limit: Int = 20
    ) -> [SessionDatabase.RecurringFileRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT command,
                       COUNT(DISTINCT session_id) AS session_count,
                       COUNT(*) AS mention_count
                FROM token_events
                WHERE tool_name IN ('read', 'outline', 'fetch', 'parse', 'validate')
                  AND project_root = ?
                  AND command IS NOT NULL
                  AND command != ''
                GROUP BY command
                HAVING session_count >= ?
                ORDER BY session_count DESC, mention_count DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 2, Int32(minSessions))
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var rows: [SessionDatabase.RecurringFileRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cmd = String(cString: sqlite3_column_text(stmt, 0))
                let sessions = Int(sqlite3_column_int64(stmt, 1))
                let mentions = Int(sqlite3_column_int64(stmt, 2))
                rows.append(SessionDatabase.RecurringFileRow(
                    path: cmd,
                    sessionCount: sessions,
                    mentionCount: mentions
                ))
            }
            return rows
        }
    }

    func instructionRetryPatterns(
        projectRoot: String,
        minRetries: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [SessionDatabase.InstructionRetryRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT tool_name, command,
                       COUNT(DISTINCT session_id) AS session_count,
                       AVG(retries) AS avg_retries
                FROM (
                    SELECT tool_name, command, session_id, COUNT(*) AS retries
                    FROM token_events
                    WHERE project_root = ?
                      AND tool_name IS NOT NULL
                      AND command IS NOT NULL
                      AND command != ''
                    GROUP BY tool_name, command, session_id
                    HAVING retries >= ?
                ) AS per_session
                GROUP BY tool_name, command
                HAVING session_count >= ?
                ORDER BY avg_retries DESC, session_count DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 2, Int32(minRetries))
            sqlite3_bind_int(stmt, 3, Int32(minSessions))
            sqlite3_bind_int(stmt, 4, Int32(limit))

            var rows: [SessionDatabase.InstructionRetryRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tn = String(cString: sqlite3_column_text(stmt, 0))
                let cmd = String(cString: sqlite3_column_text(stmt, 1))
                let sessions = Int(sqlite3_column_int64(stmt, 2))
                let avg = sqlite3_column_double(stmt, 3)
                rows.append(SessionDatabase.InstructionRetryRow(
                    toolName: tn, command: cmd,
                    sessionCount: sessions, avgRetries: avg))
            }
            return rows
        }
    }

    func workflowPairPatterns(
        projectRoot: String,
        windowSeconds: Double = 60.0,
        minOccurrencesPerSession: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [SessionDatabase.WorkflowPairRow] {
        let normalized = SessionDatabase.normalizePath(projectRoot) ?? projectRoot
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT a.tool_name AS first_tool,
                       b.tool_name AS second_tool,
                       COUNT(DISTINCT a.session_id) AS session_count,
                       COUNT(*) AS total_occ
                FROM token_events a
                INNER JOIN token_events b
                    ON a.session_id = b.session_id
                   AND b.timestamp > a.timestamp
                   AND b.timestamp - a.timestamp <= ?
                WHERE a.project_root = ?
                  AND a.tool_name IS NOT NULL
                  AND b.tool_name IS NOT NULL
                  AND a.tool_name != b.tool_name
                GROUP BY first_tool, second_tool
                HAVING session_count >= ?
                ORDER BY total_occ DESC, session_count DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, windowSeconds)
            sqlite3_bind_text(stmt, 2, (normalized as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 3, Int32(minSessions))
            sqlite3_bind_int(stmt, 4, Int32(limit))

            var rows: [SessionDatabase.WorkflowPairRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let a = String(cString: sqlite3_column_text(stmt, 0))
                let b_ = String(cString: sqlite3_column_text(stmt, 1))
                let sessions = Int(sqlite3_column_int64(stmt, 2))
                let occ = Int(sqlite3_column_int64(stmt, 3))
                let perSession = Double(occ) / max(Double(sessions), 1)
                guard perSession >= Double(minOccurrencesPerSession) else { continue }
                rows.append(SessionDatabase.WorkflowPairRow(
                    firstTool: a, secondTool: b_,
                    sessionCount: sessions, totalOccurrences: occ))
            }
            return rows
        }
    }

    // MARK: - Session cursors (ClaudeSessionReader, AXI.3 Tier 1)

    /// Per-reader identity for the `claude_session_cursors` table. Migration 21
    /// (claude-session-cursor-turn-index-ownership-conflict-2026-05-15) split
    /// the PK to `(path, reader)` so the realtime watcher and the cursor-
    /// driven background reader stop colliding on `turn_index`. New reader
    /// identities require an INVARIANTS.md update + a new reader-identity
    /// string the call-site is expected to pass.
    ///
    /// Existing identities:
    ///   - `"watcher"` — `ClaudeSessionTail.tail`. Writes `turn_index=0`
    ///     because the watcher has no concept of turns.
    ///   - `"reader"` — `ClaudeSessionReader.readNew`. Writes `turn_index`
    ///     incrementally per assistant turn.

    /// Return the stored (byteOffset, turnIndex) for (path, reader), or (0, 0) if new.
    func getSessionCursor(path: String, reader: String) -> (byteOffset: Int, turnIndex: Int) {
        return parent.queue.sync {
            guard let db = parent.db else { return (0, 0) }
            let sql = "SELECT byte_offset, turn_index FROM claude_session_cursors WHERE path = ? AND reader = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (reader as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
            return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
    }

    /// Persist the cursor for (path, reader) after a successful read pass.
    func setSessionCursor(path: String, byteOffset: Int, turnIndex: Int, reader: String) {
        let now = Date().timeIntervalSince1970
        parent.queue.async { [weak parent] in
            guard let parent, let db = parent.db else { return }
            let sql = """
                INSERT INTO claude_session_cursors (path, byte_offset, turn_index, updated_at, reader)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path, reader) DO UPDATE SET
                    byte_offset = excluded.byte_offset,
                    turn_index  = excluded.turn_index,
                    updated_at  = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 2, Int64(byteOffset))
            sqlite3_bind_int64(stmt, 3, Int64(turnIndex))
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_bind_text(stmt, 5, (reader as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Prune

    /// Prune token_events older than N days (default: 90) to prevent unbounded growth.
    /// The index on (project_root, tool_name, timestamp) makes the WHERE clause efficient.
    @discardableResult
    func pruneTokenEvents(olderThanDays: Int = 90) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400).timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = "DELETE FROM token_events WHERE timestamp < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    /// Prune `claude_session_cursors` rows whose `updated_at` is older than N
    /// days (default: 90). Mirrors `pruneTokenEvents`; sibling so the
    /// RetentionScheduler can log a per-table delta. Cursor rows accumulate
    /// one-per-JSONL-file the watcher ever opens (keyed by absolute path),
    /// and Claude Code rotates JSONLs per conversation, so without this the
    /// table grows monotonically over an install's lifetime.
    @discardableResult
    func pruneSessionCursors(olderThanDays: Int = 90) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400).timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = "DELETE FROM claude_session_cursors WHERE updated_at < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// Dump token_events summary to console for debugging.
    func dumpTokenEvents() {
        parent.queue.sync {
            guard let db = parent.db else {
                print("📊 [DB-DUMP] Database not open")
                return
            }
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM token_events", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    print("📊 [DB-DUMP] token_events total rows: \(sqlite3_column_int64(countStmt, 0))")
                }
            }
            sqlite3_finalize(countStmt)

            let sql = """
                SELECT project_root, source, COUNT(*),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(saved_tokens),0)
                FROM token_events GROUP BY project_root, source ORDER BY COUNT(*) DESC LIMIT 20
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let root = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? "NULL" : String(cString: sqlite3_column_text(stmt, 0))
                let src = String(cString: sqlite3_column_text(stmt, 1))
                let count = sqlite3_column_int64(stmt, 2)
                let inTok = sqlite3_column_int64(stmt, 3)
                let outTok = sqlite3_column_int64(stmt, 4)
                let saved = sqlite3_column_int64(stmt, 5)
                print("📊 [DB-DUMP] root=\(root) src=\(src) rows=\(count) in=\(inTok) out=\(outTok) saved=\(saved)")
            }
        }
    }
    #endif

    // MARK: - Helpers

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let val = value {
            sqlite3_bind_int64(stmt, index, Int64(val))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) {
        dispatchPrecondition(condition: .onQueue(parent.queue))
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            Logger.log("token_event_store.sql_error", fields: ["error": .string(msg)])
            sqlite3_free(err)
        }
    }

    private func execSilent(_ sql: String) {
        dispatchPrecondition(condition: .onQueue(parent.queue))
        guard let db = parent.db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err { sqlite3_free(err) }
    }
}
