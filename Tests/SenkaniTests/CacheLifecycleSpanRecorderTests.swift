import Testing
import Foundation
import SQLite3
@testable import Core

/// V.19a-3 — `cache_lifecycle` telemetry spans on
/// `runtime_telemetry_span`. Four `@Test` methods cover the four
/// `## Acceptance` bullets:
///
///   1. `eachEventTypeEmitsOneDistinctSpanRow` — drives all four
///      `EventType` cases through the recorder and asserts each
///      lands as a distinct row with `span_kind=cache_lifecycle`
///      and the correct normalized `event_type` attribute.
///   2. `attributesPassUnmodifiedThroughOTLPPrivacyFilter` — runs
///      the recorder's attribute map through the V.18a-4
///      `OTLPPrivacyFilter` and asserts the filter returns the
///      attributes UNMODIFIED. Also asserts no sensitive key
///      prefix appears in our attribute set (privacy contract
///      enforced by attribute shape).
///   3. `sessionIdAndToolCallIdPropagateToSpanRow` — emits a span
///      with explicit session + tool_call IDs and asserts both
///      land in the persisted row exactly (V.19a-4 JOIN
///      requirement).
///   4. `recorderInvocableInsideMLXInferenceLockWithoutDeadlock` —
///      invokes the recorder from inside an `MLXInferenceLock.run`
///      closure (simulating a v19a-1 lifecycle-hook callback
///      reached from inside a Metal-call window), asserts the
///      span row writes successfully, and a SECOND `lock.run`
///      completes without contention — verifying the recorder
///      neither re-enters the Metal-call serialization boundary
///      nor blocks future inference calls.
@Suite("V.19a-3 — cache_lifecycle telemetry spans")
struct CacheLifecycleSpanRecorderTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v19a-3-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanupDB(_ path: String) {
        TempSessionDatabase.cleanup(path: path)
    }

    private static func makeRecorder(
        db: SessionDatabase,
        projectId: String = "v19a-3-test"
    ) -> (CacheLifecycleSpanRecorder, Int64) {
        let datasetId = db.runtimeTelemetryStore.createDataset(projectId: projectId)
        let recorder = CacheLifecycleSpanRecorder(
            store: db.runtimeTelemetryStore,
            datasetId: datasetId
        )
        return (recorder, datasetId)
    }

    /// Convenience — pull all `cache_lifecycle.*` spans for a
    /// dataset, sorted by row id ASC, returning the fields the
    /// tests assert against.
    private static func loadSpans(db: SessionDatabase, datasetId: Int64) -> [(name: String, attrs: String, sessionId: String?, toolCallId: String?, startNs: Int64, endNs: Int64)] {
        var rows: [(String, String, String?, String?, Int64, Int64)] = []
        db.unsafeQueueSync { rawDB in
            let sql = """
                SELECT name, attributes_json, session_id, tool_call_id,
                       start_unix_ns, end_unix_ns
                  FROM runtime_telemetry_span
                 WHERE dataset_id = ? AND name LIKE 'cache_lifecycle.%'
                 ORDER BY id ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, datasetId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let attrs = String(cString: sqlite3_column_text(stmt, 1))
                let sid: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 2))
                let tid: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 3))
                let startNs = sqlite3_column_int64(stmt, 4)
                let endNs = sqlite3_column_int64(stmt, 5)
                rows.append((name, attrs, sid, tid, startNs, endNs))
            }
        }
        return rows.map { (name: $0.0, attrs: $0.1, sessionId: $0.2, toolCallId: $0.3, startNs: $0.4, endNs: $0.5) }
    }

    @Test("each event type emits one distinct cache_lifecycle span row")
    func eachEventTypeEmitsOneDistinctSpanRow() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }

        let (recorder, datasetId) = Self.makeRecorder(db: db)
        let sessionID = UUID()

        // Drive all four event types — the order matches the
        // acceptance bullet (hit / cold_miss / evict /
        // corruption_recovery).
        for ev in CacheLifecycleSpanRecorder.EventType.allCases {
            let rowId = recorder.record(eventType: ev, sessionID: sessionID, toolCallID: "tc-\(ev.rawValue)")
            #expect(rowId > 0, "insertSpan returned 0 for event \(ev.rawValue)")
        }

        let rows = Self.loadSpans(db: db, datasetId: datasetId)
        #expect(rows.count == 4, "expected 4 distinct cache_lifecycle rows; got \(rows.count)")

        // Each row's name + attribute event_type matches its
        // EventType raw value, and the span_kind attribute is
        // always 'cache_lifecycle'.
        for (row, ev) in zip(rows, CacheLifecycleSpanRecorder.EventType.allCases) {
            #expect(row.name == "cache_lifecycle.\(ev.rawValue)",
                    "expected name 'cache_lifecycle.\(ev.rawValue)'; got '\(row.name)'")
            #expect(row.attrs.contains("\"event_type\":\"\(ev.rawValue)\""),
                    "expected event_type=\(ev.rawValue) in attrs; got \(row.attrs)")
            #expect(row.attrs.contains("\"span_kind\":\"cache_lifecycle\""),
                    "expected span_kind=cache_lifecycle in attrs; got \(row.attrs)")
        }
    }

    @Test("cache_lifecycle attributes pass unmodified through OTLPPrivacyFilter and carry no sensitive keys")
    func attributesPassUnmodifiedThroughOTLPPrivacyFilter() {
        // Reconstruct the recorder's attribute map (this is the
        // input the recorder feeds to OTLPPrivacyFilter.filter on
        // each emit). The filter contract says cache_lifecycle
        // attributes are pure metadata — no `http.request.body`,
        // no `process.env.*`, no `user.email`, etc. — and must
        // pass through .metadata mode unmodified.
        let rawAttributes: [String: String] = [
            "span_kind":    CacheLifecycleSpanRecorder.spanKindValue,
            "event_type":   CacheLifecycleSpanRecorder.EventType.hit.rawValue,
            "cache_origin": CacheOrigin.prefixCache.rawValue,
        ]

        // (a) No key in our attribute set matches a sensitive prefix.
        for key in rawAttributes.keys {
            #expect(!OTLPPrivacyFilter.isSensitiveKey(key),
                    "cache_lifecycle attribute key '\(key)' must not match any sensitive prefix")
        }

        // (b) The filter, in .metadata mode, returns the SAME map
        // (same keys, same values) — nothing dropped or rewritten.
        let filtered = OTLPPrivacyFilter.filter(attributes: rawAttributes, mode: .metadata)
        #expect(filtered == rawAttributes,
                "filter must pass cache_lifecycle attributes unmodified; got \(filtered)")

        // (c) End-to-end via the recorder: emit a span, read the
        // persisted attributes_json back, parse it, and assert it
        // contains EXACTLY the three keys we set — no extras
        // leaked in, no expected ones dropped, and no prompt /
        // body / payload key snuck in.
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }
        let (recorder, datasetId) = Self.makeRecorder(db: db)
        _ = recorder.record(eventType: .hit, sessionID: UUID(), toolCallID: "tc-1")

        let rows = Self.loadSpans(db: db, datasetId: datasetId)
        #expect(rows.count == 1)
        let attrsData = rows[0].attrs.data(using: .utf8) ?? Data()
        let parsed = (try? JSONSerialization.jsonObject(with: attrsData)) as? [String: String] ?? [:]
        #expect(Set(parsed.keys) == Set(["span_kind", "event_type", "cache_origin"]),
                "persisted attributes must be exactly the three metadata keys; got \(Set(parsed.keys))")
        // Belt-and-suspenders: confirm no body/payload/prompt key
        // exists at any layer.
        for forbidden in ["body", "payload", "prompt", "http.request.body", "rpc.request.body", "messaging.message.body"] {
            #expect(parsed[forbidden] == nil,
                    "forbidden attribute key '\(forbidden)' must not appear in cache_lifecycle span")
        }
    }

    @Test("session_id and tool_call_id propagate to the persisted span row")
    func sessionIdAndToolCallIdPropagateToSpanRow() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }
        let (recorder, datasetId) = Self.makeRecorder(db: db)

        let sessionID = UUID()
        let toolCallID = "tc-19a3-join-\(UUID().uuidString.prefix(8))"

        _ = recorder.record(
            eventType: .coldMiss,
            sessionID: sessionID,
            toolCallID: toolCallID
        )

        let rows = Self.loadSpans(db: db, datasetId: datasetId)
        #expect(rows.count == 1)
        let row = rows[0]
        // session_id is derived from sessionID.uuidString.lowercased()
        // (recorder contract) — assert it matches exactly so the
        // V.19a-4 JOIN against token_events.session_id is
        // deterministic.
        let expectedSessionId = sessionID.uuidString.lowercased()
        #expect(row.sessionId == expectedSessionId,
                "expected session_id '\(expectedSessionId)'; got '\(row.sessionId ?? "nil")'")
        #expect(row.toolCallId == toolCallID,
                "expected tool_call_id '\(toolCallID)'; got '\(row.toolCallId ?? "nil")'")
    }

    @Test("recorder is invocable from inside MLXInferenceLock.run without deadlock or Metal-call re-entry")
    func recorderInvocableInsideMLXInferenceLockWithoutDeadlock() async throws {
        // Simulates the V.19a-1 lifecycle-hook callback path: a
        // hook reached from inside an inference window calls the
        // recorder. Per V.19a-1's invariant ("hooks fire OUTSIDE
        // MLXInferenceLock.shared.run"), the hook callback path
        // MUST NOT issue Metal-call work — i.e. MUST NOT re-enter
        // `lock.run` from within. The recorder satisfies this by
        // doing pure-Swift + SQLite work; this test exercises the
        // contract from inside a held lock and asserts (a) the
        // span writes successfully, (b) a SECOND `lock.run`
        // completes after the first returns without contention.
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(path) }
        let (recorder, datasetId) = Self.makeRecorder(db: db)
        let lock = MLXInferenceLock()  // Not .shared — test isolation.

        let writtenRowId: Int64 = await lock.run {
            // Inside a held inference lock. Calling the recorder
            // here models a hook callback reached from inside a
            // Metal-call window. Recorder MUST NOT re-enter
            // `lock.run` (would deadlock or violate the V.19a-1
            // invariant). Recorder body is pure-Swift +
            // store.insertSpan — no Metal-call entry possible.
            return recorder.record(
                eventType: .evict,
                sessionID: UUID(),
                toolCallID: "tc-inside-lock"
            )
        }
        #expect(writtenRowId > 0,
                "recorder must successfully write the span from inside lock.run; got rowId \(writtenRowId)")

        // After the first lock.run returns, the lock is released.
        // A second run completes without deadlock — the recorder's
        // SQLite work did not poison the actor.
        let secondCompleted: Bool = await lock.run {
            return true
        }
        #expect(secondCompleted, "second lock.run did not complete; recorder leaked actor state")

        // Confirm the row landed in the DB.
        let rows = Self.loadSpans(db: db, datasetId: datasetId)
        #expect(rows.count == 1)
        #expect(rows[0].name == "cache_lifecycle.evict")
    }
}
