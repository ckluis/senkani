import Testing
import Foundation
import SQLite3
@testable import Core

/// Cavoukian C3 — data portability export. Seeds a temp DB with known rows,
/// invokes `SessionExporter.export(...)` into a temp file, then parses the
/// JSONL back and asserts shape + redaction.
@Suite("SessionExporter — JSONL portability (C3)")
struct SessionExporterTests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-export-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", ".migrating", ".schema.lock"] {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    /// Seed sessions + commands + token_events directly — avoids depending on
    /// SessionDatabase's own insert APIs for test isolation.
    private static func seed(path: String, projectRoot: String, command: String) {
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
            INSERT INTO sessions
              (id, started_at, ended_at, duration_seconds, total_raw_bytes,
               total_saved_bytes, command_count, pane_count, cost_saved_cents)
            VALUES
              ('s-1', 1700000000.0, 1700000060.0, 60.0, 1000, 400, 1, 1, 3);
            """, nil, nil, nil)

        var cmdStmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO commands
              (session_id, timestamp, tool_name, command, raw_bytes,
               compressed_bytes, feature, output_preview)
            VALUES ('s-1', 1700000030.0, 'read', ?, 1000, 400, 'filter', ?);
            """, -1, &cmdStmt, nil)
        sqlite3_bind_text(cmdStmt, 1, (command as NSString).utf8String, -1, nil)
        let preview = "read \(projectRoot)/x/y — 400 bytes"
        sqlite3_bind_text(cmdStmt, 2, (preview as NSString).utf8String, -1, nil)
        sqlite3_step(cmdStmt)
        sqlite3_finalize(cmdStmt)

        var teStmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO token_events
              (timestamp, session_id, pane_id, project_root, source, tool_name,
               model, input_tokens, output_tokens, saved_tokens, cost_cents,
               feature, command)
            VALUES (1700000040.0, 's-1', 'pane-A', ?, 'mcp_tool', 'read',
                    'opus', 100, 400, 600, 2, 'filter', ?);
            """, -1, &teStmt, nil)
        sqlite3_bind_text(teStmt, 1, (projectRoot as NSString).utf8String, -1, nil)
        sqlite3_bind_text(teStmt, 2, (command as NSString).utf8String, -1, nil)
        sqlite3_step(teStmt)
        sqlite3_finalize(teStmt)
    }

    /// Parse a JSONL stream into an array of `[table, row]` dictionaries.
    private static func parseJSONL(_ path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(data: data, encoding: .utf8) ?? ""
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> [String: Any] in
                let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return (obj as? [String: Any]) ?? [:]
            }
    }

    // MARK: - Tests

    @Test func exportWritesAllThreeTables() throws {
        let (db, dbPath) = Self.makeDB()
        defer { Self.cleanup(dbPath) }
        db.close()  // release file handle so we can seed via a fresh conn
        Self.seed(path: dbPath, projectRoot: "/Users/tester/proj", command: "ls /Users/tester/proj")

        let outPath = "/tmp/senkani-export-out-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        defer { try? handle.close() }

        let summary = try SessionExporter.export(dbPath: dbPath, to: handle)
        try handle.close()

        #expect(summary.sessions == 1)
        #expect(summary.commands == 1)
        #expect(summary.tokenEvents == 1)

        let rows = try Self.parseJSONL(outPath)
        #expect(rows.count == 3)
        let tables = Set(rows.compactMap { $0["table"] as? String })
        #expect(tables == ["sessions", "commands", "token_events"])
    }

    @Test func exportRowSchemaHasKnownColumns() throws {
        let (db, dbPath) = Self.makeDB()
        defer { Self.cleanup(dbPath) }
        db.close()
        Self.seed(path: dbPath, projectRoot: "/Users/tester/proj", command: "echo ok")

        let outPath = "/tmp/senkani-export-out-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        _ = try SessionExporter.export(dbPath: dbPath, to: handle)
        try handle.close()

        let rows = try Self.parseJSONL(outPath)
        // Each envelope: {"table": ..., "row": {...}}
        for env in rows {
            #expect(env["table"] is String)
            #expect(env["row"] is [String: Any])
        }
        let byTable = Dictionary(grouping: rows) { $0["table"] as? String ?? "" }

        let sessionRow = (byTable["sessions"]?.first?["row"] as? [String: Any]) ?? [:]
        for key in ["id", "started_at", "command_count"] {
            #expect(sessionRow[key] != nil, "sessions row missing \(key)")
        }
        let cmdRow = (byTable["commands"]?.first?["row"] as? [String: Any]) ?? [:]
        for key in ["id", "session_id", "tool_name", "raw_bytes"] {
            #expect(cmdRow[key] != nil, "commands row missing \(key)")
        }
        let teRow = (byTable["token_events"]?.first?["row"] as? [String: Any]) ?? [:]
        for key in ["id", "timestamp", "project_root", "input_tokens"] {
            #expect(teRow[key] != nil, "token_events row missing \(key)")
        }
    }

    @Test func exportRedactsProjectRootWithForeignUser() throws {
        let (db, dbPath) = Self.makeDB()
        defer { Self.cleanup(dbPath) }
        db.close()
        Self.seed(
            path: dbPath,
            projectRoot: "/Users/alice/secret-project",
            command: "ls /Users/alice/secret-project"
        )

        let outPath = "/tmp/senkani-export-out-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        _ = try SessionExporter.export(dbPath: dbPath, redact: true, to: handle)
        try handle.close()

        let body = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(!body.contains("alice"),
                "username `alice` must not appear in redacted export, got: \(body)")
        // JSONSerialization escapes forward slashes, so look for the
        // escape-form inside the raw body OR decode and check the row.
        #expect(body.contains("\\/Users\\/***") || body.contains("/Users/***"),
                "foreign user paths must collapse to /Users/***")
        // Sanity via parse path too.
        let rows = try Self.parseJSONL(outPath)
        let teRow = rows.first { $0["table"] as? String == "token_events" }?["row"] as? [String: Any]
        #expect((teRow?["project_root"] as? String) == "/Users/***/secret-project")
    }

    @Test func exportWithoutRedactPreservesPaths() throws {
        let (db, dbPath) = Self.makeDB()
        defer { Self.cleanup(dbPath) }
        db.close()
        Self.seed(
            path: dbPath,
            projectRoot: "/Users/bob/other-project",
            command: "cat /Users/bob/other-project/x"
        )

        let outPath = "/tmp/senkani-export-out-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        _ = try SessionExporter.export(dbPath: dbPath, redact: false, to: handle)
        try handle.close()

        let body = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(body.contains("bob"), "without --redact, paths are verbatim")
    }

    @Test func exportSinceFilterSkipsOlderRows() throws {
        let (db, dbPath) = Self.makeDB()
        defer { Self.cleanup(dbPath) }
        db.close()
        // Seed one row at timestamp 1700000000 (late 2023).
        Self.seed(path: dbPath, projectRoot: "/tmp/p", command: "ok")

        let outPath = "/tmp/senkani-export-out-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))

        // `since` in 2030 — nothing should match.
        let future = Date(timeIntervalSince1970: 1_900_000_000)
        let summary = try SessionExporter.export(
            dbPath: dbPath,
            since: future,
            to: handle
        )
        try handle.close()

        #expect(summary.total == 0, "future --since should filter out all rows, got \(summary)")

        let data = try Data(contentsOf: URL(fileURLWithPath: outPath))
        #expect(data.isEmpty)
    }

    @Test func exportFailsCleanlyOnMissingDB() throws {
        let outPath = "/tmp/senkani-export-missing-\(UUID().uuidString).jsonl"
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        defer { try? handle.close(); try? FileManager.default.removeItem(atPath: outPath) }

        // Open a read-only connection to a non-existent file. SQLite returns
        // SQLITE_CANTOPEN — exporter surfaces `openFailed`.
        var threw = false
        do {
            _ = try SessionExporter.export(
                dbPath: "/tmp/does-not-exist-\(UUID().uuidString).sqlite",
                to: handle
            )
        } catch SessionExporter.ExportError.openFailed {
            threw = true
        } catch {
            Issue.record("expected .openFailed, got \(error)")
        }
        #expect(threw)
    }
}
