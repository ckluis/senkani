import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17a-1 acceptance tests for the ProviderRuntimeEvent spine.
///
/// Covers the four acceptance bullets from
/// `spec/autonomous/backlog/phase-v17a-1-runtime-event-spine.md`:
///   1. `ProviderRuntimeEvent` value type + 10-case enum + conformed
///      dimensions + `raw_payload_hash` compile and round-trip
///      through the store. (`schemaShape` + `roundtripCoreDimensions`.)
///   2. Migration v36 creates `provider_runtime_event` with
///      `raw_payload_hash UNIQUE`, conformed dimensions, projection-
///      query covering index, and is idempotent (second pass writes
///      nothing new); `ChainVerifier` is unaffected (table not in
///      chain). (`schemaShape` covers columns + UNIQUE; idempotency
///      proven by `idempotencyHitOnReplay`; chain absence asserted
///      in `chainVerifierIgnoresProviderRuntimeEvent`.)
///   3. Projection skeleton: a `toolCallFinished` event projects to
///      one `agent_trace_event` row; replay writes zero new rows;
///      `ModelRouter` allowlist invariant test asserts no change.
///      (`projectionRoundTripAndReplay` + `modelRouterAllowlistUnchanged`.)
///
/// Tests-target: 4. Adapters in v17a-2..5 ship their own per-CLI
/// fixtures + parser tests against `ProviderRuntimeAdapter`.
@Suite("ProviderRuntimeEventStore (V.17a-1)")
struct ProviderRuntimeEventStoreTests {

    // MARK: - Helpers

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17a-1-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func makeToolCallFinishedEvent(
        payloadHash: String = UUID().uuidString,
        providerID: String = "codex",
        sessionID: String? = "sess-1",
        toolCallID: String? = "tool-call-7f3a",
        toolResult: String? = "success"
    ) -> ProviderRuntimeEvent {
        ProviderRuntimeEvent(
            providerID: providerID,
            sessionID: sessionID,
            threadID: "thread-a",
            turnID: "turn-1",
            pane: "kb",
            type: .toolCallFinished,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100),
            tokens: ProviderRuntimeEvent.TokenSnapshot(
                promptTokens: 120, completionTokens: 80, cachedTokens: 40
            ),
            toolCallID: toolCallID,
            toolName: "shell.exec",
            toolResult: toolResult,
            warnings: [],
            projectionStatus: .pending,
            rawPayloadHash: payloadHash
        )
    }

    // MARK: - Test 1 — schema shape + UNIQUE constraint

    @Test("Migration v36 creates provider_runtime_event with the expected columns and UNIQUE(raw_payload_hash)")
    func schemaShape() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        #expect(db.currentSchemaVersion() >= 36, "schema must reach v36")

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(provider_runtime_event);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        let expected: Set<String> = [
            "id", "raw_payload_hash", "provider_id",
            "session_id", "thread_id", "turn_id", "pane",
            "event_type", "observed_at",
            "prompt_tokens", "completion_tokens", "cached_tokens",
            "tool_call_id", "tool_name", "tool_result", "approval_id",
            "warnings_json", "projection_status",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")

        // Verify the covering projection-query index exists.
        let indexes = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='provider_runtime_event';", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return set
        }
        #expect(indexes.contains("idx_provider_runtime_event_provider_session_time"),
                "covering projection-query index missing: \(indexes.sorted())")

        // Verify UNIQUE constraint enforced at SQL layer — bypass the
        // store's ON CONFLICT DO NOTHING and try a raw INSERT of the
        // same hash twice.
        let hash = "raw-unique-test-v17a"
        let r1 = db.providerRuntimeEventStore.insert(event: Self.makeToolCallFinishedEvent(payloadHash: hash))
        #expect(r1 == .insertedRow)

        let rc = db.queue.sync { () -> Int32 in
            guard let h = db.db else { return -1 }
            let sql = """
                INSERT INTO provider_runtime_event
                    (raw_payload_hash, provider_id, event_type, observed_at)
                VALUES (?, 'codex', 'message_delta', 0);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
            return sqlite3_step(stmt)
        }
        #expect(rc == SQLITE_CONSTRAINT,
                "expected UNIQUE constraint failure on raw_payload_hash, got rc=\(rc)")
    }

    // MARK: - Test 2 — projection round-trip + replay

    @Test("toolCallFinished projects to one agent_trace_event row; replay writes zero new rows")
    func projectionRoundTripAndReplay() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let event = Self.makeToolCallFinishedEvent(payloadHash: "replay-fixture-1")

        // Pre-insert the event so projection_status can be observed.
        let insertOutcome = db.providerRuntimeEventStore.insert(event: event)
        #expect(insertOutcome == .insertedRow)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: event.rawPayloadHash) == .pending,
                "projection_status should be .pending pre-projection")

        // First projection lands one agent_trace_event row.
        let firstInserted = db.providerRuntimeEventStore.projectIntoAgentTrace(event)
        #expect(firstInserted, "first projection must insert one canonical trace row")
        #expect(db.agentTraceEventCount() == 1, "exactly one canonical trace row after first projection")
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: event.rawPayloadHash) == .projected,
                "projection_status should flip to .projected on first projection")

        // Replay: project the same event again. Zero new canonical
        // rows, status flips to .dedup.
        let secondInserted = db.providerRuntimeEventStore.projectIntoAgentTrace(event)
        #expect(!secondInserted, "replay must not insert a second canonical trace row")
        #expect(db.agentTraceEventCount() == 1, "still exactly one canonical trace row after replay")
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: event.rawPayloadHash) == .dedup,
                "projection_status should flip to .dedup on replay idempotency hit")

        // Verify the stored canonical row carries the conformed
        // dimensions we projected (session_id + tool_call_id).
        let key = "v17a:\(event.rawPayloadHash)"
        let row = db.agentTraceEventStore.fetchByIdempotencyKey(key)
        #expect(row != nil)
        #expect(row?.sessionId == "sess-1")
        #expect(row?.toolCallId == "tool-call-7f3a")
        #expect(row?.pane == "kb")
        #expect(row?.tokensIn == 120)
        #expect(row?.tokensOut == 80)
        #expect(row?.result == .success)
    }

    // MARK: - Test 3 — store-level idempotency hit on duplicate hash

    @Test("Inserting the same raw_payload_hash twice via insert(event:) returns idempotencyHit on the second pass")
    func idempotencyHitOnReplay() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let event = Self.makeToolCallFinishedEvent(payloadHash: "dup-test-1")

        let r1 = db.providerRuntimeEventStore.insert(event: event)
        let r2 = db.providerRuntimeEventStore.insert(event: event)
        let r3 = db.providerRuntimeEventStore.insert(event: event)

        #expect(r1 == .insertedRow)
        #expect(r2 == .idempotencyHit)
        #expect(r3 == .idempotencyHit)
        #expect(db.providerRuntimeEventStore.countAll() == 1)

        // Sanity: ineligible events get auto-stamped to .ineligible
        // even when the caller passes a different status (the column
        // should reflect derived state, not caller intent).
        let warning = ProviderRuntimeEvent(
            providerID: "codex",
            sessionID: "sess-1",
            type: .warning,
            observedAt: Date(timeIntervalSince1970: 1_700_000_200),
            warnings: ["context window 80% full"],
            projectionStatus: .pending,  // caller error — warning is not projectable
            rawPayloadHash: "warning-hash-1"
        )
        #expect(db.providerRuntimeEventStore.insert(event: warning) == .insertedRow)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: "warning-hash-1") == .ineligible,
                "ineligible event types must be auto-stamped .ineligible regardless of caller-passed status")
    }

    // MARK: - Test 4 — ModelRouter allowlist invariant + ChainVerifier ignores new table

    @Test("V.17a-1 does not change ModelRouter's routable tier set; ChainVerifier ignores provider_runtime_event")
    func modelRouterAllowlistUnchangedAndChainVerifierIgnoresTable() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // ModelRouter allowlist invariant — the four routable
        // `ModelTier` cases are the V.2-era surface. V.17a's spine
        // (events + projection) MUST NOT extend this set; provider-
        // adapter wiring lives in adapter rounds (v17a-2..5) which
        // also must not touch the router.
        let knownTiers: Set<String> = ["local", "quick", "balanced", "frontier"]
        let auto = ModelRouter.resolve(prompt: "list files in cwd", preset: .auto)
        let build = ModelRouter.resolve(prompt: "anything", preset: .build)
        let research = ModelRouter.resolve(prompt: "anything", preset: .research)
        let quick = ModelRouter.resolve(prompt: "anything", preset: .quick)
        let local = ModelRouter.resolve(prompt: "anything", preset: .local, gemma4Downloaded: true)
        for decision in [auto, build, research, quick, local] {
            #expect(knownTiers.contains(decision.tier.rawValue),
                    "ModelRouter resolved to an unexpected tier: \(decision.tier.rawValue)")
        }
        // Resolve via every TaskTier (intent path) too — same invariant.
        for taskTier in TaskTier.allCases {
            let d = ModelRouter.resolve(taskTier: taskTier, gemma4Downloaded: true)
            #expect(knownTiers.contains(d.tier.rawValue),
                    "ModelRouter resolved \(taskTier.rawValue) → unexpected tier \(d.tier.rawValue)")
        }

        // Chain note: provider_runtime_event is NOT in the T.5 audit
        // chain (accepted-risk per V.2 precedent). Asserts
        // `ChainVerifier.verifyAll(...)` returns a dictionary that
        // does NOT mention the new table — proving the migration
        // didn't accidentally wire it in.
        let chainResults = ChainVerifier.verifyAll(db)
        #expect(!chainResults.keys.contains("provider_runtime_event"),
                "provider_runtime_event must NOT appear in the chain verifier's table set; got keys \(chainResults.keys.sorted())")

        // Also verify the migration is idempotent — re-opening the
        // DB doesn't re-run v36 (the schema_migrations table tracks
        // applied versions). Construct a second SessionDatabase on
        // the same path and re-check the row count of the seeded
        // event is unchanged.
        let seedHash = "idempotent-migration-seed"
        _ = db.providerRuntimeEventStore.insert(event: Self.makeToolCallFinishedEvent(payloadHash: seedHash))
        let firstCount = db.providerRuntimeEventStore.countAll()
        db.close()

        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        #expect(db2.currentSchemaVersion() >= 36)
        #expect(db2.providerRuntimeEventStore.countAll() == firstCount,
                "re-opening DB after migration must not duplicate rows or wipe the table")
    }
}
