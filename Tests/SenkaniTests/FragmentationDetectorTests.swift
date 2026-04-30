import Testing
import Foundation
import SQLite3
@testable import Core

// MARK: - Test helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-trustaudit-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

@Suite("U.4a — FragmentationDetector + TrustScorer + trust_audits", .serialized)
struct FragmentationDetectorTests {

    // MARK: - Schema (acceptance: chained trust_audits)

    @Test("Migration v12 creates trust_audits table with chain columns")
    func schemaShape() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        #expect(db.currentSchemaVersion() >= 12)

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(trust_audits);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        let expected: Set<String> = [
            "id", "kind", "created_at", "session_id", "pane_id",
            "tool_name", "reason", "score", "correlation_count",
            "flag_id", "label", "labeled_by",
            "prev_hash", "entry_hash", "chain_anchor_id",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")
    }

    // MARK: - Detector unit tests

    @Test("Tool burst: 3 same-tool calls in window emit a toolBurst flag")
    func toolBurstFires() {
        let det = FragmentationDetector()
        let now = Date()
        let session = "S1"
        var allFlags: [FragmentationDetector.Flag] = []
        for i in 0..<3 {
            let obs = FragmentationDetector.Observation(
                timestamp: now.addingTimeInterval(Double(i)),
                sessionId: session,
                toolName: "Edit"
            )
            allFlags.append(contentsOf: det.record(obs))
        }
        let bursts = allFlags.filter { $0.reason == .toolBurst }
        #expect(bursts.count == 1, "Exactly one burst on the third hit")
        #expect(bursts.first?.correlationCount == 3)
    }

    @Test("Burst does NOT fire across different tool names")
    func burstScopedByTool() {
        let det = FragmentationDetector()
        let now = Date()
        var flags: [FragmentationDetector.Flag] = []
        for (i, tool) in ["Edit", "Read", "Bash"].enumerated() {
            flags.append(contentsOf: det.record(.init(
                timestamp: now.addingTimeInterval(Double(i)),
                sessionId: "S",
                toolName: tool
            )))
        }
        #expect(flags.allSatisfy { $0.reason != .toolBurst })
    }

    @Test("Burst does NOT fire when calls span past the burst window")
    func burstWindowed() {
        let det = FragmentationDetector(config: .init(burstThreshold: 3, burstWindow: 5))
        let now = Date()
        var flags: [FragmentationDetector.Flag] = []
        for i in 0..<3 {
            // 10s apart > 5s burst window
            flags.append(contentsOf: det.record(.init(
                timestamp: now.addingTimeInterval(Double(i) * 10),
                sessionId: "S",
                toolName: "Edit"
            )))
        }
        #expect(flags.allSatisfy { $0.reason != .toolBurst })
    }

    @Test("Fragment stitch: overlapping prompt fragments emit a fragmentStitch flag")
    func fragmentStitchFires() {
        let det = FragmentationDetector()
        let now = Date()
        // First obs primes the buffer.
        _ = det.record(.init(
            timestamp: now,
            sessionId: "S",
            toolName: "Edit",
            fragment: "rotate the AWS root key"
        ))
        // Second obs's fragment is a substring → stitch.
        let flags = det.record(.init(
            timestamp: now.addingTimeInterval(2),
            sessionId: "S",
            toolName: "Bash",
            fragment: "rotate the AWS root key now"
        ))
        #expect(flags.contains { $0.reason == .fragmentStitch })
    }

    @Test("Cross-pane: same tool in two panes inside one session flags crossPane")
    func crossPaneFires() {
        let det = FragmentationDetector()
        let now = Date()
        _ = det.record(.init(timestamp: now, sessionId: "S", paneId: "P1", toolName: "Bash"))
        let flags = det.record(.init(
            timestamp: now.addingTimeInterval(1),
            sessionId: "S",
            paneId: "P2",
            toolName: "Bash"
        ))
        #expect(flags.contains { $0.reason == .crossPane })
    }

    @Test("Sessions are isolated — events in S1 don't trigger flags in S2")
    func sessionIsolation() {
        let det = FragmentationDetector()
        let now = Date()
        // 3 Edits in S1 → burst.
        var s1Flags: [FragmentationDetector.Flag] = []
        for i in 0..<3 {
            s1Flags.append(contentsOf: det.record(.init(
                timestamp: now.addingTimeInterval(Double(i)),
                sessionId: "S1",
                toolName: "Edit"
            )))
        }
        // Single Edit in S2 → no flag.
        let s2Flags = det.record(.init(
            timestamp: now.addingTimeInterval(1),
            sessionId: "S2",
            toolName: "Edit"
        ))
        #expect(s1Flags.contains { $0.reason == .toolBurst })
        #expect(s2Flags.isEmpty)
    }

    // MARK: - TrustScorer unit tests

    @Test("Empty flag list scores at the ceiling (100)")
    func scoreEmptyAtCeiling() {
        #expect(TrustScorer.score(flags: []) == 100)
    }

    @Test("Each flag reason subtracts its weight; multiple flags compound")
    func scorePenalties() {
        let burst = FragmentationDetector.Flag(
            createdAt: Date(), sessionId: "S", paneId: nil,
            toolName: "Edit", reason: .toolBurst, correlationCount: 3
        )
        let stitch = FragmentationDetector.Flag(
            createdAt: Date(), sessionId: "S", paneId: nil,
            toolName: "Bash", reason: .fragmentStitch, correlationCount: 2
        )
        let cross = FragmentationDetector.Flag(
            createdAt: Date(), sessionId: "S", paneId: "P", toolName: "Bash",
            reason: .crossPane, correlationCount: 2
        )
        // Defaults: 100 - 8 - 12 - 6 = 74
        #expect(TrustScorer.score(flags: [burst, stitch, cross]) == 74)
    }

    @Test("Score never drops below the floor")
    func scoreFloor() {
        let stitch = FragmentationDetector.Flag(
            createdAt: Date(), sessionId: "S", paneId: nil,
            toolName: "Bash", reason: .fragmentStitch, correlationCount: 2
        )
        // 100 - 12 * 100 = -1100, clamp to 0.
        let many = Array(repeating: stitch, count: 100)
        #expect(TrustScorer.score(flags: many) == 0)
    }

    // MARK: - Store + chain (acceptance: trust_audits chained, FP/TP round-trips)

    @Test("Flag rows are chained — each row's prev_hash equals the previous row's entry_hash")
    func flagsAreChained() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()
        let f1 = FragmentationDetector.Flag(
            createdAt: now, sessionId: "S", paneId: nil,
            toolName: "Edit", reason: .toolBurst, correlationCount: 3
        )
        let f2 = FragmentationDetector.Flag(
            createdAt: now.addingTimeInterval(1), sessionId: "S", paneId: nil,
            toolName: "Bash", reason: .fragmentStitch, correlationCount: 2
        )
        let id1 = db.recordTrustFlag(f1, score: 92)
        let id2 = db.recordTrustFlag(f2, score: 80)
        #expect(id1 > 0 && id2 > 0)

        let rows = db.queue.sync { () -> [(prev: String?, entry: String?, anchor: Int64)] in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT prev_hash, entry_hash, chain_anchor_id FROM trust_audits ORDER BY id;"
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [(String?, String?, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let prev: String? = sqlite3_column_type(stmt, 0) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 0))
                let entry: String? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 1))
                out.append((prev, entry, sqlite3_column_int64(stmt, 2)))
            }
            return out
        }
        #expect(rows.count == 2)
        #expect(rows[0].prev == nil)
        #expect(rows[0].entry != nil)
        #expect(rows[1].prev == rows[0].entry)
        #expect(rows[1].entry != rows[0].entry)
        #expect(rows[0].anchor > 0 && rows[0].anchor == rows[1].anchor)
    }

    @Test("FP/TP labels round-trip through trust_audits + flip in stats")
    func labelRoundTrip() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        let now = Date()
        let flagA = FragmentationDetector.Flag(
            createdAt: now, sessionId: "S", paneId: nil,
            toolName: "Edit", reason: .toolBurst, correlationCount: 3
        )
        let flagB = FragmentationDetector.Flag(
            createdAt: now.addingTimeInterval(1), sessionId: "S", paneId: "P",
            toolName: "Bash", reason: .crossPane, correlationCount: 2
        )
        let idA = db.recordTrustFlag(flagA, score: 92)
        let idB = db.recordTrustFlag(flagB, score: 94)

        // Two flags, no labels yet.
        var stats = db.trustFlagStats(since: now.addingTimeInterval(-60))
        #expect(stats.softFlags == 2)
        #expect(stats.confirmedFP == 0)
        #expect(stats.confirmedTP == 0)

        // Operator labels A as FP, B as TP.
        _ = db.recordTrustLabel(flagId: idA, label: .fp, labeledBy: "ck")
        _ = db.recordTrustLabel(flagId: idB, label: .tp, labeledBy: "ck")
        stats = db.trustFlagStats(since: now.addingTimeInterval(-60))
        #expect(stats.softFlags == 2)
        #expect(stats.confirmedFP == 1)
        #expect(stats.confirmedTP == 1)

        // Re-label A from FP→TP. Append-only: a NEW row, latest wins.
        _ = db.recordTrustLabel(flagId: idA, label: .tp, labeledBy: "ck")
        stats = db.trustFlagStats(since: now.addingTimeInterval(-60))
        #expect(stats.confirmedFP == 0)
        #expect(stats.confirmedTP == 2)

        // Latest label for A is .tp; full history is 2 rows, newest first.
        let history = db.trustLabelsForFlag(idA)
        #expect(history.count == 2)
        #expect(history.first?.label == .tp)
        #expect(history.last?.label == .fp)
    }

    // MARK: - Doctor line (acceptance: senkani doctor shows FP-rate)

    @Test("Doctor-line stats render the canonical 'soft flags last 30d' summary")
    func doctorLineFormat() {
        let stats = TrustFlagStats(softFlags: 7, confirmedFP: 2, confirmedTP: 4)
        #expect(stats.doctorLine == "soft flags last 30d: 7 | confirmed FP: 2 | confirmed TP: 4")
    }

    // MARK: - Hook integration (acceptance: detection is non-blocking)

    @Test("HookRouter detector is wired and never produces a deny response")
    func hookRouterNonBlocking() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        // Use the test seam so the hook path persists into our temp DB.
        let prevSink = HookRouter.trustFlagSink
        HookRouter.trustFlagSink = { flag, score in
            _ = db.recordTrustFlag(flag, score: score)
        }
        defer { HookRouter.trustFlagSink = prevSink }
        HookRouter.fragmentationDetector.reset()

        // Three Edit PostToolUse events in the same session — should
        // burst on the third, NEVER deny (PostToolUse is always
        // passthrough, but the detector itself should fire too).
        for _ in 0..<3 {
            let event: [String: Any] = [
                "tool_name": "Edit",
                "tool_input": ["file_path": "/tmp/x.swift"],
                "hook_event_name": "PostToolUse",
                "session_id": "S-fragmenttest",
            ]
            let data = try! JSONSerialization.data(withJSONObject: event)
            let resp = HookRouter.handle(eventJSON: data)
            // Passthrough response is always `{}`.
            let s = String(data: resp, encoding: .utf8) ?? ""
            #expect(s == "{}", "PostToolUse must be passthrough; got \(s)")
        }

        // Detector + sink fired at least once for the burst.
        let flags = db.recentTrustFlags(limit: 10)
        #expect(flags.contains { $0.reason == .toolBurst && $0.toolName == "Edit" })
    }
}
