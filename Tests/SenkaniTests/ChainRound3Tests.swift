import Testing
import Foundation
import SQLite3
@testable import Core

@Suite("ChainVerifier round 3 — validation_results, sandboxed_results, commands")
struct ChainRound3Tests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-chain3-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    private static func tamper(_ path: String, table: String, where_: String, set: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "tamper", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = "UPDATE \(table) SET \(set) WHERE \(where_);"
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw NSError(domain: "tamper", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - validation_results

    @Test("validation_results — chain of three writes verifies OK")
    func validationOK() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<3 {
            db.insertValidationResult(
                sessionId: "vsession",
                filePath: "/tmp/file-\(i).swift",
                validatorName: "swiftc",
                category: "syntax",
                exitCode: 0,
                rawOutput: nil,
                advisory: "OK",
                durationMs: 5
            )
        }
        db.flushWrites()

        let result = ChainVerifier.verifyValidationResults(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("validation_results — single-byte tamper caught at the tampered row")
    func validationTamperCaught() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        for i in 0..<3 {
            db.insertValidationResult(
                sessionId: "vsession",
                filePath: "/tmp/file-\(i).swift",
                validatorName: "swiftc",
                category: "syntax",
                exitCode: 0,
                rawOutput: nil,
                advisory: "OK",
                durationMs: 5
            )
        }
        db.flushWrites()

        // Tamper row 2's advisory text.
        try Self.tamper(path, table: "validation_results", where_: "id = 2", set: "advisory = 'tampered'")

        let result = ChainVerifier.verifyValidationResults(db)
        guard case .brokenAt(let table, let rowid, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "validation_results")
        #expect(rowid == 2)
    }

    // MARK: - sandboxed_results

    @Test("sandboxed_results — chain of three writes verifies OK")
    func sandboxOK() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        _ = db.storeSandboxedResult(sessionId: "s1", command: "ls /tmp", output: "line\n")
        _ = db.storeSandboxedResult(sessionId: "s1", command: "ls /tmp", output: "more lines\n")
        _ = db.storeSandboxedResult(sessionId: "s1", command: "echo hello", output: "hello\n")
        db.flushWrites()

        let result = ChainVerifier.verifySandboxedResults(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("sandboxed_results — tamper on full_output is caught")
    func sandboxTamperCaught() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        _ = db.storeSandboxedResult(sessionId: "s1", command: "ls /tmp", output: "line\n")
        _ = db.storeSandboxedResult(sessionId: "s1", command: "echo hello", output: "hello\n")
        db.flushWrites()

        // Tamper the second row's full_output. Use ORDER BY created_at to
        // pick a deterministic row.
        try Self.tamper(
            path,
            table: "sandboxed_results",
            where_: "id IN (SELECT id FROM sandboxed_results ORDER BY created_at DESC LIMIT 1)",
            set: "full_output = 'tampered'"
        )

        let result = ChainVerifier.verifySandboxedResults(db)
        guard case .brokenAt(let table, _, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "sandboxed_results")
    }

    // MARK: - commands

    @Test("commands — chain of three writes verifies OK")
    func commandsOK() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let sid = db.createSession(paneCount: 1, projectRoot: "/tmp/proj", agentType: nil)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/a.swift",
                         rawBytes: 100, compressedBytes: 60)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/b.swift",
                         rawBytes: 200, compressedBytes: 120)
        db.recordBudgetDecision(sessionId: sid, toolName: "Bash", decision: "deny", rawBytes: 0, compressedBytes: 0)
        db.flushWrites()

        let result = ChainVerifier.verifyCommands(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("commands — tamper on tool_name caught at the right row")
    func commandsTamperCaught() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let sid = db.createSession(paneCount: 1, projectRoot: "/tmp/proj", agentType: nil)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/a.swift",
                         rawBytes: 100, compressedBytes: 60)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/b.swift",
                         rawBytes: 200, compressedBytes: 120)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/c.swift",
                         rawBytes: 300, compressedBytes: 180)
        db.flushWrites()

        // Tamper command #2's tool_name.
        try Self.tamper(path, table: "commands", where_: "id = 2", set: "tool_name = 'tampered'")

        let result = ChainVerifier.verifyCommands(db)
        guard case .brokenAt(let table, let rowid, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "commands")
        #expect(rowid == 2)
    }

    // MARK: - Cross-table integrity

    @Test("verifyAll returns one entry per table")
    func verifyAllShape() {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        // Write into all four tables.
        db.recordTokenEvent(
            sessionId: "s", paneId: nil, projectRoot: "/tmp", source: "mcp_tool",
            toolName: "read", model: nil,
            inputTokens: 10, outputTokens: 5, savedTokens: 5, costCents: 1,
            feature: nil, command: nil
        )
        db.insertValidationResult(
            sessionId: "s", filePath: "/tmp/a.swift", validatorName: "swiftc",
            category: "syntax", exitCode: 0, rawOutput: nil, advisory: "OK",
            durationMs: 5
        )
        _ = db.storeSandboxedResult(sessionId: "s", command: "ls", output: "ok")
        let sid = db.createSession(paneCount: 1, projectRoot: "/tmp", agentType: nil)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/a.swift",
                         rawBytes: 100, compressedBytes: 60)
        db.flushWrites()

        let perTable = ChainVerifier.verifyAll(db)
        // Five chain participants: token_events + 3 from T.5 round 3 + the
        // pane_refresh_state table added in V.1 round 2 (no rows yet, so its
        // entry comes back as .noChain — still counted in the map shape).
        #expect(perTable.count == 5)
        for table in ["token_events", "validation_results", "sandboxed_results", "commands"] {
            guard let r = perTable[table] else {
                Issue.record("missing result for \(table)")
                continue
            }
            guard case .ok = r else {
                Issue.record("\(table): expected .ok, got \(r)")
                continue
            }
        }
    }

    @Test("Anchors are independent: tampering token_events does not break commands")
    func tamperOneTableLeavesOthersOK() throws {
        let (db, path) = Self.makeDB()
        defer { db.close(); Self.cleanup(path) }

        let sid = db.createSession(paneCount: 1, projectRoot: "/tmp", agentType: nil)
        db.recordCommand(sessionId: sid, toolName: "Read", command: "/tmp/a.swift",
                         rawBytes: 100, compressedBytes: 60)
        db.recordTokenEvent(
            sessionId: "s", paneId: nil, projectRoot: "/tmp", source: "mcp_tool",
            toolName: "read", model: nil,
            inputTokens: 10, outputTokens: 5, savedTokens: 5, costCents: 1,
            feature: nil, command: nil
        )
        db.flushWrites()

        try Self.tamper(path, table: "token_events", where_: "id = 1", set: "tool_name = 'tampered'")

        let perTable = ChainVerifier.verifyAll(db)
        guard case .brokenAt = perTable["token_events"] else {
            Issue.record("expected token_events broken")
            return
        }
        guard case .ok = perTable["commands"] else {
            Issue.record("expected commands ok, got \(perTable["commands"] ?? .noChain)")
            return
        }
    }
}
