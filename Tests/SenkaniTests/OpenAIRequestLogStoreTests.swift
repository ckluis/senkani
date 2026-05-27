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
