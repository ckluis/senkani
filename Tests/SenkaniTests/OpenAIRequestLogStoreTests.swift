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
