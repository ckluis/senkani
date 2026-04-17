import Testing
import Foundation
import SQLite3
@testable import Core

/// C1 (Cavoukian privacy pass 2026-04-16): `commands.command` used to
/// persist raw shell text. A user or prompt-injected LLM running
/// `senkani_exec "curl -H 'Authorization: Bearer sk-ant-…' …"` left the
/// literal API key in the DB for the unbounded lifetime of that row.
/// `recordCommand` now runs every command string through
/// `SecretDetector.scan` before persistence.
@Suite("Cavoukian — command redaction")
struct CommandRedactionTests {

    /// Query the raw `command` column for a given session_id.
    /// Bypasses any Swift-level filtering — we want to see EXACTLY
    /// what's on disk.
    private static func rawCommandsFor(
        dbPath: String,
        sessionId: String
    ) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT command FROM commands WHERE session_id = ? ORDER BY id;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)

        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                out.append(String(cString: cstr))
            } else {
                out.append("<NULL>")
            }
        }
        return out
    }

    /// Drain the DB's async write queue by running a sync read.
    private static func flush(_ db: SessionDatabase) {
        _ = db.tokenStatsForProject("/tmp/flush-marker-for-sync-queue-drain")
    }

    @Test func anthropicKeyInCommandRedactedInDB() {
        let path = "/tmp/senkani-cavoukian-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let sid = db.createSession(projectRoot: "/tmp/redact-test-proj")

        // Build the command text with concat to avoid tripping GitHub's
        // push-protection scanner.
        let keyPrefix = "sk" + "-ant-"
        let command = "curl -H \"Authorization: Bearer \(keyPrefix)api03-abcdefghijklmnopqrstuvwxyz\""
        db.recordCommand(
            sessionId: sid,
            toolName: "exec",
            command: command,
            rawBytes: 1000,
            compressedBytes: 100,
            feature: "test",
            outputPreview: nil
        )
        Self.flush(db)

        let stored = Self.rawCommandsFor(dbPath: path, sessionId: sid)
        #expect(stored.count == 1)
        let row = stored.first ?? ""
        #expect(row.contains("[REDACTED:ANTHROPIC_API_KEY]"),
                "command text must contain the redaction marker, got: \(row)")
        #expect(!row.contains("api03-abcdefghijklmnopqrstuvwxyz"),
                "raw key body must not appear in the DB, got: \(row)")
    }

    @Test func stripeKeyInCommandRedactedInDB() {
        let path = "/tmp/senkani-cavoukian-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let sid = db.createSession(projectRoot: "/tmp/stripe-test-proj")

        let prefix = "sk" + "_live_"
        let body = "abcdef0123456789abcdef0123"
        let command = "STRIPE_KEY=\(prefix)\(body) ./deploy.sh"
        db.recordCommand(
            sessionId: sid,
            toolName: "exec",
            command: command,
            rawBytes: 100,
            compressedBytes: 100
        )
        Self.flush(db)

        let stored = Self.rawCommandsFor(dbPath: path, sessionId: sid)
        let row = stored.first ?? ""
        #expect(row.contains("[REDACTED:STRIPE_SECRET_KEY]"))
        #expect(!row.contains(body))
    }

    @Test func benignCommandStoredAsIs() {
        // Safety check: non-sensitive commands must round-trip intact.
        // If SecretDetector false-positives on normal commands, users
        // lose data-portability on `senkani stats --search`.
        let path = "/tmp/senkani-cavoukian-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let sid = db.createSession(projectRoot: "/tmp/benign-test-proj")

        let command = "git status --short --branch"
        db.recordCommand(
            sessionId: sid,
            toolName: "exec",
            command: command,
            rawBytes: 100,
            compressedBytes: 100
        )
        Self.flush(db)

        let stored = Self.rawCommandsFor(dbPath: path, sessionId: sid)
        #expect(stored.first == command,
                "benign command must store verbatim, got: \(stored.first ?? "<empty>")")
    }

    @Test func nilCommandStoresAsNull() {
        // `command` is optional — nil should NOT be converted to the empty
        // string or a REDACTED marker.
        let path = "/tmp/senkani-cavoukian-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let sid = db.createSession(projectRoot: "/tmp/nil-test-proj")

        db.recordCommand(
            sessionId: sid,
            toolName: "session",
            command: nil,
            rawBytes: 0,
            compressedBytes: 0
        )
        Self.flush(db)

        let stored = Self.rawCommandsFor(dbPath: path, sessionId: sid)
        #expect(stored == ["<NULL>"], "nil command must bind SQL NULL")
    }
}
