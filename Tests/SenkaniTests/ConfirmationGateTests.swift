import Testing
import Foundation
import SQLite3
@testable import Core

// MARK: - Test helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-confirmation-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

@Suite("T.6a — ConfirmationGate + ConfirmationStore + NotificationSink", .serialized)
struct ConfirmationGateTests {

    // MARK: - Schema (acceptance #1)

    @Test("Migration v11 creates confirmations table with chain columns")
    func schemaShape() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        #expect(db.currentSchemaVersion() >= 11)

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(confirmations);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        let expected: Set<String> = [
            "id", "tool_name", "requested_at", "decided_at",
            "decision", "decided_by", "reason",
            "prev_hash", "entry_hash", "chain_anchor_id",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")
    }

    // MARK: - Chain integration (acceptance #1 — chains via t5)

    @Test("Confirmation rows participate in the T.5 audit chain")
    func chainsViaT5() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        ConfirmationGate.database = db
        defer { ConfirmationGate.resetToDefaults() }

        // Force a write-tagged tool so the gate writes a row.
        let r1 = ConfirmationGate.evaluate(toolName: "Edit")
        let r2 = ConfirmationGate.evaluate(toolName: "Write")
        #expect(r1.rowid > 0 && r2.rowid > 0)

        let rows = db.queue.sync { () -> [(prev: String?, entry: String?, anchor: Int64)] in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT prev_hash, entry_hash, chain_anchor_id FROM confirmations ORDER BY id;"
            guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [(String?, String?, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let prev: String? = sqlite3_column_type(stmt, 0) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 0))
                let entry: String? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 1))
                let anchor = sqlite3_column_int64(stmt, 2)
                out.append((prev, entry, anchor))
            }
            return out
        }

        #expect(rows.count == 2)
        // Row 0: prev_hash is NULL (first row in chain), entry_hash is set.
        #expect(rows[0].prev == nil)
        #expect(rows[0].entry != nil && !rows[0].entry!.isEmpty)
        // Row 1: prev_hash equals row 0's entry_hash.
        #expect(rows[1].prev == rows[0].entry)
        #expect(rows[1].entry != nil && rows[1].entry != rows[0].entry)
        // Both rows share an anchor id > 0 (lazy-create on first write).
        #expect(rows[0].anchor > 0)
        #expect(rows[0].anchor == rows[1].anchor)
    }

    // MARK: - Tool tagging (acceptance #2)

    @Test("Default catalog tags Edit/Write/Bash as confirmation-required")
    func defaultCatalogTags() {
        #expect(MCPToolCatalog.shared.requiresConfirmation(for: "Edit"))
        #expect(MCPToolCatalog.shared.requiresConfirmation(for: "Write"))
        #expect(MCPToolCatalog.shared.requiresConfirmation(for: "Bash"))
        #expect(MCPToolCatalog.shared.requiresConfirmation(for: "senkani_exec"))
        #expect(!MCPToolCatalog.shared.requiresConfirmation(for: "Read"))
        #expect(!MCPToolCatalog.shared.requiresConfirmation(for: "senkani_read"))
        // Unknown tool: not confirmation-required (gate skips).
        #expect(!MCPToolCatalog.shared.requiresConfirmation(for: "made_up_tool"))
    }

    @Test("Operator override flips a tool's requires_confirmation")
    func operatorOverride() {
        let cat = MCPToolCatalog(entries: MCPToolCatalog.defaults)
        #expect(cat.requiresConfirmation(for: "senkani_read") == false)
        cat.setOverride(toolName: "senkani_read", requiresConfirmation: true)
        #expect(cat.requiresConfirmation(for: "senkani_read") == true)
        cat.setOverride(toolName: "senkani_read", requiresConfirmation: nil)
        // Reverts to tag-derived default.
        #expect(cat.requiresConfirmation(for: "senkani_read") == false)
    }

    // MARK: - Gate decisions (acceptance #2 — every write/exec call produces a row)

    @Test("Every write/exec-tagged call writes a chained confirmation row")
    func writeExecAlwaysAudits() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        ConfirmationGate.database = db
        defer { ConfirmationGate.resetToDefaults() }

        for tool in ["Edit", "Write", "Bash", "senkani_exec"] {
            _ = ConfirmationGate.evaluate(toolName: tool)
        }
        #expect(db.confirmationCount() == 4)

        // Read-tagged + unknown tools do NOT write rows — chain stays
        // dense with rows that represent actual confirmation decisions.
        for tool in ["Read", "senkani_read", "Grep", "made_up_tool"] {
            let outcome = ConfirmationGate.evaluate(toolName: tool)
            #expect(outcome.rowid == -1)
            #expect(outcome.allows)
        }
        #expect(db.confirmationCount() == 4)
    }

    // MARK: - Deny path (acceptance #3 — structured error)

    @Test("Operator-deny path returns a structured error reason")
    func denyPathStructuredError() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        ConfirmationGate.database = db
        ConfirmationGate.resolver = { _, _ in
            (.deny, .operator, "operator says no")
        }
        defer { ConfirmationGate.resetToDefaults() }

        let outcome = ConfirmationGate.evaluate(toolName: "Edit")
        #expect(outcome.decision == .deny)
        #expect(outcome.decidedBy == .operator)
        #expect(outcome.allows == false)
        #expect(outcome.rowid > 0)

        let reason = ConfirmationGate.denyReason(toolName: "Edit", reason: outcome.reason)
        #expect(reason.contains("Edit"))
        #expect(reason.contains("operator says no"))

        // Empty reason still produces a non-empty deny string.
        let fallback = ConfirmationGate.denyReason(toolName: "Bash", reason: nil)
        #expect(fallback.contains("Bash"))
        #expect(fallback.lowercased().contains("denied"))
    }

    @Test("Default policy auto-approves but still writes an audit row")
    func defaultPolicyAuditsAutoApprove() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        ConfirmationGate.database = db
        defer { ConfirmationGate.resetToDefaults() }

        let outcome = ConfirmationGate.evaluate(toolName: "Edit")
        #expect(outcome.decision == .auto)
        #expect(outcome.decidedBy == .auto)
        #expect(outcome.allows)
        #expect(outcome.rowid > 0)

        // The audit row is recoverable.
        let rows = db.recentConfirmations(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].toolName == "Edit")
        #expect(rows[0].decision == .auto)
        #expect(rows[0].decidedBy == .auto)
    }

    // MARK: - HookRouter integration (acceptance #2 + #3)

    @Test("HookRouter PreToolUse on a denied Edit returns a structured deny")
    func hookRouterDeniesEdit() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }
        ConfirmationGate.database = db
        ConfirmationGate.resolver = { _, _ in (.deny, .policy, "policy disallows Edit") }
        defer { ConfirmationGate.resetToDefaults() }

        let event: [String: Any] = [
            "tool_name": "Edit",
            "hook_event_name": "PreToolUse",
            "tool_input": ["file_path": "/tmp/example.swift"],
        ]
        let json = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: json)
        let parsed = try! JSONSerialization.jsonObject(with: response) as! [String: Any]
        let hookOutput = parsed["hookSpecificOutput"] as! [String: Any]
        #expect(hookOutput["permissionDecision"] as? String == "deny")
        let reason = hookOutput["permissionDecisionReason"] as! String
        #expect(reason.contains("Edit"))
        #expect(reason.contains("policy disallows Edit"))
    }

    // MARK: - NotificationSink (acceptance #4)

    @Test("NullNotificationSink swallows every event without throwing")
    func nullSinkNoOps() throws {
        let sink = NullNotificationSink()
        // None of these throw — the contract is no-op.
        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))
        try sink.notify(.notifyFailure(toolName: "Edit", reason: "boom"))
        try sink.notify(.scheduleEnd(scheduleId: "nightly", summary: "done"))
    }

    @Test("MockNotificationSink records events and surfaces a fan-out throw")
    func mockSinkRecordsAndThrows() {
        let mock = MockNotificationSink()
        let throwing = MockNotificationSink(errorToThrow: NSError(domain: "test", code: 1))
        let recorder = MockNotificationSink()

        let event = NotifyEvent.notifyDone(toolName: "Edit", summary: "patched 1 file")
        NotificationFanout.deliver(event, to: [mock, throwing, recorder])

        // The throwing sink does NOT block recorder — the round's
        // contract is "fan-out swallows throws."
        #expect(mock.delivered == [event])
        #expect(throwing.delivered == [event])
        #expect(recorder.delivered == [event])
    }
}
