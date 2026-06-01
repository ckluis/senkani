import Testing
import Foundation
import SQLite3
@testable import Core

/// V.13e-1 — DB-backed OpenAI request log tests.
///
/// Covers the acceptance bullets from
/// `spec/autonomous/backlog/phase-v13e-1-audit-chain-persistence.md`:
///   1. Persisted store; raw API key NEVER written (only key_label).
///   2. Query API returns trailing-24h count + 429-rate, cross-process
///      (write rows, reopen a fresh handle at the same path, query
///      still returns them).
///   3. Retention: rows older than 30 days are pruned.
@Suite("OpenAIRequestLogStore (V.13e-1)")
struct OpenAIRequestLogStoreTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v13e-1-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "openai-request-log-\(UUID().uuidString).db"
    }

    /// Test 1 — persist-and-query-24h-429 + cross-process.
    ///
    /// Writes a mix of in-window and out-of-window rows through one DB
    /// handle, then opens a SECOND handle at the same path (simulating a
    /// process restart — a cold ChainState cache) and asserts the
    /// trailing-24h count + 429-rate are computed from the persisted
    /// rows, not from any in-process state.
    @Test("Trailing-24h count + 429-rate persist and query cross-process")
    func persistAndQueryTrailing24hAnd429RateCrossProcess() {
        let path = Self.tempDBPath()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        // --- Handle 1: write rows ---
        do {
            let db1 = SessionDatabase(path: path)

            // In the trailing-24h window: 4 requests, 1 of which is a 429.
            #expect(db1.recordOpenAIRequest(
                ts: now.addingTimeInterval(-60),
                surface: .chat, status: 200, keyLabel: "key-A"))
            #expect(db1.recordOpenAIRequest(
                ts: now.addingTimeInterval(-120),
                surface: .chatStream, status: 200, keyLabel: "key-A"))
            #expect(db1.recordOpenAIRequest(
                ts: now.addingTimeInterval(-3_600),
                surface: .embeddings, status: 429, keyLabel: "key-B"))
            #expect(db1.recordOpenAIRequest(
                ts: now.addingTimeInterval(-7_200),
                surface: .toolUse, status: 200, keyLabel: "key-A"))

            // OUTSIDE the trailing-24h window (older than 24h): must not
            // count, even though it is a 429.
            #expect(db1.recordOpenAIRequest(
                ts: now.addingTimeInterval(-90_000),
                surface: .chat, status: 429, keyLabel: "key-C"))

            #expect(db1.openAIRequestLogCount() == 5)
        }

        // --- Handle 2: fresh process, cold cache, same path ---
        let db2 = SessionDatabase(path: path)
        let stats = db2.openAIRequestTrailing24hStats(now: now)

        // 4 requests landed in the trailing 24h; 1 of them was a 429.
        #expect(stats.count24h == 4)
        #expect(stats.count429 == 1)
        #expect(abs(stats.rate429 - 0.25) < 1e-9)

        // All 5 rows are still persisted (the out-of-window row remains in
        // the table until pruned — it just doesn't count toward the window).
        #expect(db2.openAIRequestLogCount() == 5)

        // Empty-window sanity: a window far in the future sees nothing and
        // does not divide by zero.
        let future = db2.openAIRequestTrailing24hStats(
            now: now.addingTimeInterval(10 * 86_400))
        #expect(future.count24h == 0)
        #expect(future.count429 == 0)
        #expect(future.rate429 == 0)
    }

    /// Test 2 — retention-prune (>30d dropped, recent kept) AND
    /// key-label-not-raw (the raw API key never reaches any column).
    @Test("Retention prunes rows older than 30 days; raw key is never persisted")
    func retentionPrunesOlderThan30DaysAndNeverPersistsRawKey() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        // A row older than 30 days and a recent row.
        let rawKey = "sk-RAWSECRET-this-must-never-touch-disk-9f3a"
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(-31 * 86_400),
            surface: .chat, status: 200, keyLabel: "key-old"))
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(-1 * 86_400),
            surface: .embeddings, status: 200, keyLabel: "key-recent"))
        #expect(db.openAIRequestLogCount() == 2)

        // --- Retention: prune at 30 days ---
        let deleted = db.pruneOpenAIRequestLog(retentionDays: 30, now: now)
        #expect(deleted == 1)
        #expect(db.openAIRequestLogCount() == 1)

        let surviving = db.recentOpenAIRequests(limit: 10)
        #expect(surviving.count == 1)
        #expect(surviving.first?.keyLabel == "key-recent")
        #expect(surviving.first?.surface == "embeddings")

        // --- Raw-key-never-persisted: dump EVERY column value of EVERY
        // row and assert the raw key sentinel never appears anywhere. The
        // record() API has no raw-key parameter, so this is structurally
        // impossible — the test pins that the schema/writer never gains
        // one. ---
        let raw = scanAllColumnText(path: path, table: "openai_request_log")
        #expect(!raw.contains(rawKey),
                "raw API key bytes must never appear in any persisted column")
        // The label IS expected to be present — proving we wrote a row.
        #expect(raw.contains("key-recent"))
    }

    /// V.13e — gate-refusal recording. The auth gate emits 401 / 403 / 429
    /// BEFORE any surface handler runs, so refused requests never reach the
    /// success-path sink; `recordRefusal` is their single producer. Drives
    /// each refusal kind (the 429 through a REAL `decide` over an exhausted
    /// rate window, proving the producer wiring) and asserts:
    ///   - exactly one persisted row per refusal, none for `.ok` (no
    ///     double-count);
    ///   - correct status + path-derived surface;
    ///   - key-label policy: 401 → nil, 403/429 → matched label, raw key
    ///     never persisted;
    ///   - trailing-24h stats then report a NON-ZERO count429 / rate429, so
    ///     the doctor line reflects real rejected traffic.
    @Test("Gate refusals (401/403/429) record one persisted row each with the right surface + key label")
    func gateRefusalsRecordPersistedRowsAndDrive429Rate() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let rawKey = "sk-RAWSECRET-refusal-path-must-never-touch-disk-7b21"
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(rawKey),
            preset: "auto",
            scope: ["chat"],            // NOT embeddings → embeddings is a 403
            rateLimit: 1,               // one request per window → 2nd is 429
            createdAt: now,
            label: "team-prod"
        )
        let records = [record]
        let bearer = "Bearer \(rawKey)"

        // 401 — missing Authorization header. No matched record → label nil.
        // Surface derived from the chat path.
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: .unauthorized(reason: "missing or malformed Authorization header"),
            path: "/v1/chat/completions",
            authorizationHeader: nil,
            records: records,
            db: db, now: now))

        // 403 — valid key, but the embeddings surface is out of scope. The
        // matched record's label is attributed; surface is embeddings.
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: .forbidden(reason: "key scope does not include surface 'embeddings'"),
            path: "/v1/embeddings",
            authorizationHeader: bearer,
            records: records,
            db: db, now: now))

        // 429 — driven through the REAL gate: the first decide admits, the
        // second (same window, limit 1) returns `.rateLimited`. That genuine
        // refusal decision is what the producer records.
        let limiter = OpenAIRateLimiter()
        let admit = OpenAIAuthGate.decide(
            authorizationHeader: bearer, requestedSurface: "chat",
            now: now, records: records, rateLimiter: limiter)
        #expect(admit == .ok(label: "team-prod"))
        let throttled = OpenAIAuthGate.decide(
            authorizationHeader: bearer, requestedSurface: "chat",
            now: now, records: records, rateLimiter: limiter)
        guard case .rateLimited = throttled else {
            Issue.record("expected a .rateLimited decision on the 2nd request")
            return
        }
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: throttled,
            path: "/v1/chat/completions",
            authorizationHeader: bearer,
            records: records,
            db: db, now: now))

        // `.ok` is a no-op: the surface handler owns the admit. No row, and
        // the function reports it did not write.
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: .ok(label: "team-prod"),
            path: "/v1/chat/completions",
            authorizationHeader: bearer,
            records: records,
            db: db, now: now) == false)

        // Exactly three rows — one per refusal, none for the admit.
        #expect(db.openAIRequestLogCount() == 3)

        // Per-status assertions (rows come back newest-first; key by status).
        let byStatus = Dictionary(
            uniqueKeysWithValues: db.recentOpenAIRequests(limit: 10).map { ($0.status, $0) })
        #expect(byStatus[401]?.surface == "chat")
        #expect(byStatus[401]?.keyLabel == nil)          // 401 attributes no label
        #expect(byStatus[403]?.surface == "embeddings")
        #expect(byStatus[403]?.keyLabel == "team-prod")  // matched record's label
        #expect(byStatus[429]?.surface == "chat")
        #expect(byStatus[429]?.keyLabel == "team-prod")

        // The whole point: trailing-24h 429-rate is now non-zero.
        let stats = db.openAIRequestTrailing24hStats(now: now)
        #expect(stats.count24h == 3)
        #expect(stats.count429 == 1)
        #expect(abs(stats.rate429 - (1.0 / 3.0)) < 1e-9)

        // The raw key must never reach any persisted column.
        let raw = scanAllColumnText(path: path, table: "openai_request_log")
        #expect(!raw.contains(rawKey),
                "raw API key bytes must never appear in any persisted column")
        #expect(raw.contains("team-prod"))   // the label IS expected
    }

    /// V.13e — surface-less refusal attribution. A 401 on a `/v1/*` path
    /// that maps to no specific surface (the canonical example is
    /// `/v1/models` — an unauthenticated probe of the model list) must
    /// record under `.other`, NOT under `.chat`. Pre-change behavior
    /// disguised recon signal as chat traffic and slightly skewed
    /// per-surface attribution in `recentOpenAIRequests`; post-change the
    /// row carries honest data. Mirrors the existing 401/403/429
    /// chat/embeddings path coverage above without modifying it.
    @Test("Surface-less /v1/* refusal (e.g. /v1/models) records under .other, not .chat")
    func surfaceLessRefusalRecordsUnderOther() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        // 401 — missing Authorization header on a surface-less path.
        // Confirms `surface(forPath:)` returns nil (the path is neither
        // `/v1/chat*` nor `/v1/embeddings`) and the switch routes to
        // `.other` instead of falling through to `.chat`.
        #expect(OpenAIAuthGate.surface(forPath: "/v1/models") == nil)
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: .unauthorized(reason: "missing or malformed Authorization header"),
            path: "/v1/models",
            authorizationHeader: nil,
            records: [],
            db: db, now: now))

        // Exactly one row; status 401; surface attributed to "other", not "chat".
        #expect(db.openAIRequestLogCount() == 1)
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.status == 401)
        #expect(rows.first?.surface == "other")
        #expect(rows.first?.keyLabel == nil)
    }

    // MARK: - V.13e-7 — producer-metadata columns (Migration v42)

    /// V.13e-7 #1 — Migration v42 is idempotent: re-running the closure
    /// against an already-migrated DB does NOT throw, and the four new
    /// columns + the renamed `fresh-install-pre-v42` anchor remain
    /// intact. The `allowDuplicateColumn: true` block swallows
    /// "duplicate column name", the rename UPDATE is a WHERE-clause
    /// no-op, and the `migration-v42` anchor open guards on row count
    /// (no double-anchor on the second run).
    @Test("Migration v42 closure is idempotent against an already-migrated DB")
    func migrationV42IsIdempotent() throws {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        // First write — exercises the post-v42 lazy `fresh-install` anchor
        // path (no pre-v42 rows existed, so the rename UPDATE was a no-op
        // and `openOpenAIRequestLogV42Anchor` was a no-op).
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(db.recordOpenAIRequest(
            ts: now, surface: .chat, status: 200, keyLabel: "k",
            modelLogged: "gpt-4o-mini", resolvedTier: "cloud",
            inputTokens: 10, outputTokens: 20))

        // Re-run the v42 closure on top of itself. The first run is what
        // `MigrationRunner` already executed when `SessionDatabase` opened
        // the path. Re-running must not raise — that's the idempotency
        // contract the migration body codifies via `allowDuplicateColumn`.
        let migration = MigrationRegistry.all.first { $0.version == 42 }
        #expect(migration != nil)
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(path, &rawDB) == SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        try migration!.up(rawDB!)
        try migration!.up(rawDB!)

        // Schema introspection — the four new columns must still be on
        // the table after the second + third application.
        let columnNames = Self.columnNames(rawDB!, table: "openai_request_log")
        #expect(columnNames.contains("model_logged"))
        #expect(columnNames.contains("resolved_tier"))
        #expect(columnNames.contains("input_tokens"))
        #expect(columnNames.contains("output_tokens"))

        // The chain anchor for this table — created lazily by the first
        // write — must still verify after the repeated migrations
        // (re-running the rename + anchor-open did NOT corrupt it).
        let result = ChainVerifier.verifyOpenAIRequestLog(db)
        if case .ok = result {} else {
            Issue.record("expected .ok after re-running v42 idempotently, got \(result)")
        }
    }

    /// V.13e-7 #2 — write a row through the new `record(...)` with all
    /// four producer-metadata fields populated; read back via
    /// `recent(...)` and assert the persisted values round-trip
    /// faithfully. Pins both the writer (column binds + INSERT shape)
    /// and the reader (SELECT shape + `decodeRow` NULL handling).
    @Test("Write-then-read round-trip with all four producer-metadata fields populated")
    func roundTripPersistsProducerMetadataFields() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_100)

        #expect(db.recordOpenAIRequest(
            ts: now, surface: .chat, status: 200, keyLabel: "team-prod",
            modelLogged: "claude-3-7-sonnet", resolvedTier: "cloud",
            inputTokens: 42, outputTokens: 17))

        let rows = db.recentOpenAIRequests(limit: 1)
        #expect(rows.count == 1)
        let row = rows.first!
        #expect(row.modelLogged == "claude-3-7-sonnet")
        #expect(row.resolvedTier == "cloud")
        #expect(row.inputTokens == 42)
        #expect(row.outputTokens == 17)
        #expect(row.status == 200)
        #expect(row.keyLabel == "team-prod")
    }

    /// V.13e-7 #3 — producer-side regex sanitization. Strings failing
    /// `^[A-Za-z0-9._:/-]{1,64}$` persist as `<malformed>`, while the
    /// in-memory tamper-evident chain still records the raw bytes for
    /// forensics. Schneier: sanitize at the trust boundary; keep the
    /// attacker's exact bytes in the chain so a future incident-response
    /// pass can replay the truth.
    @Test("Malformed model_logged lands as <malformed> in the persisted store; raw value stays in the in-memory chain")
    func sanitizationDivergesPersistedFromInMemoryChain() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let chain = OpenAIAuditChain()
        let now = Date(timeIntervalSince1970: 1_900_000_200)

        // Three flavours of failure: emoji (out-of-class), length > 64,
        // an embedded space (out-of-class). The sentinel `<malformed>`
        // itself fails the regex (the angle brackets are not in the
        // character class) — that's fine; the persisted column carries
        // the sentinel, not the regex-sanitized self.
        let cases: [String] = [
            "💥nope💥",
            String(repeating: "a", count: 65),
            "model with space",
        ]
        for (i, badModel) in cases.enumerated() {
            let fields = OpenAIAuditChain.AuditFields(
                ts: now.addingTimeInterval(Double(i)),
                keyLabel: "key-\(i)",
                surface: OpenAIRequestLogStore.Surface.chat.rawValue,
                modelLogged: badModel,
                presetUsed: "balanced",
                resolvedTier: "local",
                promptTokenCount: 1,
                completionTokenCount: 2,
                status: "200"
            )
            #expect(OpenAIServedRequestSink.record(
                chain: chain, fields: fields, bodies: nil,
                db: db, surface: .chat, httpStatus: 200))
        }

        // Persisted store: every row's `model_logged` is the literal
        // `<malformed>` (rows come back newest-first).
        let rows = db.recentOpenAIRequests(limit: cases.count)
        #expect(rows.count == cases.count)
        for row in rows {
            #expect(row.modelLogged == "<malformed>",
                    "expected <malformed>, got \(String(describing: row.modelLogged))")
        }

        // In-memory chain: raw attacker bytes preserved per entry. Pair
        // entries to inputs by appended order.
        #expect(chain.count == cases.count)
        let recorded = chain.entries.map { $0.fields.modelLogged }
        #expect(recorded == cases,
                "in-memory chain must record raw model_logged for every entry")

        // A well-formed model name still round-trips clean — sanitization
        // is selective, not blanket.
        let fields = OpenAIAuditChain.AuditFields(
            ts: now.addingTimeInterval(100),
            keyLabel: "k", surface: "chat",
            modelLogged: "gpt-4o-mini",
            presetUsed: "fast", resolvedTier: "cloud",
            promptTokenCount: 7, completionTokenCount: 9,
            status: "200"
        )
        #expect(OpenAIServedRequestSink.record(
            chain: chain, fields: fields, bodies: nil,
            db: db, surface: .chat, httpStatus: 200))
        let newest = db.recentOpenAIRequests(limit: 1).first
        #expect(newest?.modelLogged == "gpt-4o-mini")
        #expect(newest?.resolvedTier == "cloud")
        #expect(newest?.inputTokens == 7)
        #expect(newest?.outputTokens == 9)
    }

    /// V.13e-7 #4 — refusals (`<refused>` for `model_logged`, NULL for
    /// the other three producer-metadata columns). The auth-gate refusal
    /// path has no resolved tier and no token counts, so the persisted
    /// row honestly records "we rejected before routing." 401 attributes
    /// no label; 403/429 attribute the matched record's label.
    @Test("Refusal path persists model_logged=<refused> and NULL for resolved_tier/input_tokens/output_tokens")
    func refusalPathPersistsRefusedSentinelAndNullMetadata() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_300)

        let rawKey = "sk-test-refusal-metadata-1f2a"
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(rawKey),
            preset: "auto",
            scope: ["chat"],
            rateLimit: 1,
            createdAt: now,
            label: "team-prod"
        )
        let records = [record]
        let bearer = "Bearer \(rawKey)"

        // 401 — missing header, no matched record.
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: .unauthorized(reason: "missing or malformed Authorization header"),
            path: "/v1/chat/completions",
            authorizationHeader: nil,
            records: records,
            db: db, now: now))

        // 403 — out-of-scope embeddings surface.
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: .forbidden(reason: "key scope does not include surface 'embeddings'"),
            path: "/v1/embeddings",
            authorizationHeader: bearer,
            records: records,
            db: db, now: now))

        // 429 — drive through the real gate so the decision is a genuine
        // .rateLimited (mirrors the existing 401/403/429 coverage shape).
        let limiter = OpenAIRateLimiter()
        _ = OpenAIAuthGate.decide(
            authorizationHeader: bearer, requestedSurface: "chat",
            now: now, records: records, rateLimiter: limiter)
        let throttled = OpenAIAuthGate.decide(
            authorizationHeader: bearer, requestedSurface: "chat",
            now: now, records: records, rateLimiter: limiter)
        #expect(OpenAIServedRequestSink.recordRefusal(
            decision: throttled,
            path: "/v1/chat/completions",
            authorizationHeader: bearer,
            records: records,
            db: db, now: now))

        // Every refusal row: model_logged = <refused>; the other three
        // are NULL (decodeRow surfaces them as nil).
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 3)
        for row in rows {
            #expect(row.modelLogged == "<refused>",
                    "expected <refused>, got \(String(describing: row.modelLogged))")
            #expect(row.resolvedTier == nil)
            #expect(row.inputTokens == nil)
            #expect(row.outputTokens == nil)
        }
    }

    /// V.13e-7 #5 — the chain entry_hash MUST cover the four producer-
    /// metadata columns. A tamper that flips `model_logged` post-write
    /// is caught by `ChainVerifier.verifyOpenAIRequestLog` because the
    /// recomputed canonical bytes diverge from the stored entry_hash.
    /// (Pre-v42 this was structurally impossible — the column didn't
    /// exist. Post-v42 the verifier MUST hash through the new bytes.)
    @Test("Tampered model_logged is caught by verifyOpenAIRequestLog (entry_hash covers v42 producer-metadata columns)")
    func chainEntryHashCoversProducerMetadataColumns() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_400)

        // Two clean rows under the post-v42 lazy `fresh-install` anchor.
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(0), surface: .chat, status: 200,
            keyLabel: "key-1",
            modelLogged: "gpt-4o-mini", resolvedTier: "cloud",
            inputTokens: 5, outputTokens: 6))
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(1), surface: .embeddings, status: 200,
            keyLabel: "key-2",
            modelLogged: "claude-3-7-sonnet", resolvedTier: "cloud",
            inputTokens: 7, outputTokens: 8))

        // Sanity — clean chain verifies.
        if case .ok = ChainVerifier.verifyOpenAIRequestLog(db) {} else {
            Issue.record("pre-tamper chain must verify .ok")
        }

        // Tamper directly in the table: flip `model_logged` on the first
        // row without recomputing its entry_hash. Migration v42 made this
        // column attacker-relevant; verification MUST detect the flip.
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(path, &rawDB) == SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        let tamperSQL = """
            UPDATE openai_request_log
               SET model_logged = 'flipped-by-attacker'
             WHERE id = 1;
        """
        var err: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(rawDB!, tamperSQL, nil, nil, &err) == SQLITE_OK)
        if let err { sqlite3_free(err) }

        // Re-open through a FRESH SessionDatabase handle to bust any
        // ChainState cache, then verify — the tamper must surface as a
        // `.brokenAt` result (recomputed hash diverges from stored).
        let db2 = SessionDatabase(path: path)
        let result = ChainVerifier.verifyOpenAIRequestLog(db2)
        switch result {
        case .brokenAt:
            break  // expected — entry_hash covers model_logged post-v42
        default:
            Issue.record(
                "expected .brokenAt after tampering model_logged, got \(result)")
        }
    }

    // MARK: - V.13b-3 — upstream_response_id column (Migration v44)

    /// V.13b-3 — the chain entry_hash MUST cover `upstream_response_id` for
    /// rows under a v44+ anchor. A tamper that flips the upstream id post-write
    /// is caught by `ChainVerifier.verifyOpenAIRequestLog`. Also pins the
    /// local-arm contract: a NULL upstream id (the OpenAI-compatible arm) still
    /// rides the chain — the writer hashes `.null` and the verifier includes the
    /// column, so a clean chain verifies and any later flip is detected.
    @Test("Tampered upstream_response_id is caught by verifyOpenAIRequestLog (entry_hash covers the v44 column)")
    func chainEntryHashCoversUpstreamResponseId() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_700)

        // Row 1 — Anthropic arm: a populated upstream id (the Anthropic-Request-Id
        // the v13b-2/b-4 serve path will thread). Row 2 — local arm: NULL upstream.
        // Both chain under the post-v44 anchor (migrations ran through v44 on init).
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(0), surface: .chat, status: 200,
            keyLabel: "anthropic-key", modelLogged: "claude-opus-4", resolvedTier: "cloud",
            inputTokens: 11, outputTokens: 22, upstreamResponseId: "req_anthropic_abc123"))
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(1), surface: .chat, status: 200,
            keyLabel: "openai-key", modelLogged: "gpt-4o-mini", resolvedTier: "cloud",
            inputTokens: 3, outputTokens: 4, upstreamResponseId: nil))

        // Clean chain (both the populated and the NULL row) verifies.
        if case .ok = ChainVerifier.verifyOpenAIRequestLog(db) {} else {
            Issue.record("pre-tamper chain (populated + NULL upstream) must verify .ok")
        }

        // Tamper directly: flip the populated upstream_response_id on row 1
        // without recomputing its entry_hash. v44 made this column
        // attacker-relevant; verification MUST detect the flip.
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(path, &rawDB) == SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        let tamperSQL = """
            UPDATE openai_request_log
               SET upstream_response_id = 'req_forged_by_attacker'
             WHERE id = 1;
        """
        var err: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(rawDB!, tamperSQL, nil, nil, &err) == SQLITE_OK)
        if let err { sqlite3_free(err) }

        // Fresh handle (bust ChainState cache), re-verify — must be `.brokenAt`.
        let db2 = SessionDatabase(path: path)
        let result = ChainVerifier.verifyOpenAIRequestLog(db2)
        switch result {
        case .brokenAt:
            break  // expected — entry_hash covers upstream_response_id post-v44
        default:
            Issue.record(
                "expected .brokenAt after tampering upstream_response_id, got \(result)")
        }
    }

    /// V.13b-3 — flipping a NULL upstream id to a populated value (forging an
    /// upstream provenance onto a local-arm row) is ALSO caught: the writer
    /// hashed `.null`, so any non-NULL value diverges from the stored entry_hash.
    @Test("Forging upstream_response_id onto a NULL local-arm row is caught by verifyOpenAIRequestLog")
    func chainCatchesForgedUpstreamOnNullRow() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_800)
        #expect(db.recordOpenAIRequest(
            ts: now, surface: .chat, status: 200,
            keyLabel: "openai-key", modelLogged: "gpt-4o", resolvedTier: "cloud",
            inputTokens: 1, outputTokens: 2, upstreamResponseId: nil))
        if case .ok = ChainVerifier.verifyOpenAIRequestLog(db) {} else {
            Issue.record("pre-tamper NULL-upstream chain must verify .ok")
        }

        var rawDB: OpaquePointer?
        #expect(sqlite3_open(path, &rawDB) == SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        var err: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(rawDB!,
            "UPDATE openai_request_log SET upstream_response_id = 'forged' WHERE id = 1;",
            nil, nil, &err) == SQLITE_OK)
        if let err { sqlite3_free(err) }

        let db2 = SessionDatabase(path: path)
        if case .brokenAt = ChainVerifier.verifyOpenAIRequestLog(db2) {} else {
            Issue.record("expected .brokenAt after forging upstream onto a NULL row")
        }
    }

    /// V.13b-3 forward-compat pin (re-audit P2). `verifyAnchorOpenAIRequestLog`'s
    /// `useV44Shape` is EXCLUSION-form, so any future `repair-*` anchor inherits
    /// the v44 shape (includes `upstream_response_id`). That is correct ONLY while
    /// `openai_request_log` is NOT repair-supported — if it is later added to
    /// `ChainRepairer.supportedTables`, the repair path's canonical shape must be
    /// re-confirmed against the writer/verifier (a repaired row re-hashed WITHOUT
    /// the column would falsely verify as tampered). This assertion fails the day
    /// the table gains repair support, forcing that re-confirmation rather than
    /// leaving the coupling implicit.
    @Test("openai_request_log is not repair-supported (pins the v44 exclusion-form useV44Shape coupling)")
    func openAIRequestLogNotRepairSupportedPinsV44Shape() {
        #expect(!ChainRepairer.supportedTables.contains("openai_request_log"),
                "openai_request_log was added to ChainRepairer.supportedTables — re-confirm the v44 useV44Shape canonical shape covers the repair-* anchor path (see ChainVerifier.verifyAnchorOpenAIRequestLog).")
    }

    /// V.13e-7 #6 — `trailing24hStats` reads `ts` + `status` only and
    /// must remain correct against rows that carry NULL in the four
    /// new producer-metadata columns (the legacy pre-v42 shape, plus
    /// the V.13e-5 burst-test path that writes without producer
    /// metadata). The SQL aggregate is unchanged by v42; this test
    /// pins that promise so a future migration that touches the count
    /// query doesn't regress doctor's `429-rate` against legacy rows.
    @Test("trailing24hStats stays correct against rows with NULL producer-metadata columns (legacy pre-v42 shape)")
    func trailing24hStatsToleratesNullProducerMetadataColumns() {
        let path = Self.tempDBPath()
        let db = SessionDatabase(path: path)
        let now = Date(timeIntervalSince1970: 1_900_000_500)

        // Three in-window rows (all four producer-metadata fields nil)
        // plus one out-of-window row. Mirrors the existing trailing-24h
        // test shape so the assertion semantics carry over.
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(-60),
            surface: .chat, status: 200, keyLabel: "key-A"))
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(-120),
            surface: .chatStream, status: 200, keyLabel: "key-A"))
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(-3_600),
            surface: .embeddings, status: 429, keyLabel: "key-B"))
        #expect(db.recordOpenAIRequest(
            ts: now.addingTimeInterval(-90_000),
            surface: .chat, status: 429, keyLabel: "key-C"))

        let stats = db.openAIRequestTrailing24hStats(now: now)
        #expect(stats.count24h == 3)
        #expect(stats.count429 == 1)
        #expect(abs(stats.rate429 - (1.0 / 3.0)) < 1e-9)

        // The persisted rows have nil producer-metadata — the SELECT
        // path tolerates this without crashing or attributing junk.
        let rows = db.recentOpenAIRequests(limit: 4)
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.modelLogged == nil)
            #expect(row.resolvedTier == nil)
            #expect(row.inputTokens == nil)
            #expect(row.outputTokens == nil)
        }
    }

    /// Introspect column names for `table`. Used by the migration-
    /// idempotency test to assert the four v42 ALTERs landed without
    /// referring to private migration internals.
    private static func columnNames(_ db: OpaquePointer, table: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                out.append(String(cString: cstr))
            }
        }
        return out
    }

    /// Read every TEXT/INTEGER/REAL column of every row of `table` into one
    /// concatenated string for substring scanning.
    private func scanAllColumnText(path: String, table: String) -> String {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return "" }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM \(table);", -1, &stmt, nil) == SQLITE_OK else {
            return ""
        }
        defer { sqlite3_finalize(stmt) }
        var out = ""
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cols = sqlite3_column_count(stmt)
            for i in 0..<cols {
                if let c = sqlite3_column_text(stmt, i) {
                    out += String(cString: c)
                    out += "\u{1F}"  // unit separator between values
                }
            }
        }
        return out
    }
}
