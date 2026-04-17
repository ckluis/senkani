import Foundation
import SQLite3

/// Cavoukian C3 — data portability. Opens a read-only SQLite connection to
/// the session DB and streams `sessions` + `commands` + `token_events` as
/// JSONL, one row per line, `{"table":..., "row": {...}}`. When `redact`
/// is true, the `project_root` column and any `/Users/<name>/...` path in
/// text columns goes through `ProjectSecurity.redactPath`.
///
/// Read-only connection (`SQLITE_OPEN_READONLY`) because:
///   1. Export is observational — writing would be a bug.
///   2. Side-steps the `SessionDatabase.queue` lock so a long export
///      doesn't block the live MCP server writing to the DB.
///   3. WAL mode means reader + writer don't block each other.
///
/// Errors: file open / query prep / JSON serialization problems throw; the
/// caller surfaces them. A partial write leaves the output file in the
/// state we reached before the failure (no atomic rename yet — fine for a
/// user-initiated export).
public enum SessionExporter {

    public enum ExportError: Error, CustomStringConvertible {
        case openFailed(String)
        case queryFailed(String)
        case writeFailed(String)
        case jsonFailed(String)

        public var description: String {
            switch self {
            case .openFailed(let m):  return "export: could not open DB — \(m)"
            case .queryFailed(let m): return "export: query failed — \(m)"
            case .writeFailed(let m): return "export: write failed — \(m)"
            case .jsonFailed(let m):  return "export: JSON encoding failed — \(m)"
            }
        }
    }

    public struct Summary: Sendable, Equatable {
        public let sessions: Int
        public let commands: Int
        public let tokenEvents: Int
        public var total: Int { sessions + commands + tokenEvents }
    }

    /// Export every row matching `since` (inclusive; nil = no filter) from
    /// `dbPath` into `handle` as JSONL.
    @discardableResult
    public static func export(
        dbPath: String,
        since: Date? = nil,
        redact: Bool = false,
        to handle: FileHandle
    ) throws -> Summary {
        var db: OpaquePointer?
        // Read-only open. SQLITE_OPEN_NOMUTEX is fine because we use the
        // connection only on the current thread.
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openRC = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard openRC == SQLITE_OK, let conn = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(openRC)"
            if let conn = db { sqlite3_close(conn) }
            throw ExportError.openFailed(msg)
        }
        defer { sqlite3_close(conn) }

        let sinceTS = since?.timeIntervalSince1970

        let sessionsCount = try exportSessions(conn: conn, sinceTS: sinceTS,
                                                redact: redact, to: handle)
        let commandsCount = try exportCommands(conn: conn, sinceTS: sinceTS,
                                                redact: redact, to: handle)
        let eventsCount = try exportTokenEvents(conn: conn, sinceTS: sinceTS,
                                                redact: redact, to: handle)

        return Summary(
            sessions: sessionsCount,
            commands: commandsCount,
            tokenEvents: eventsCount
        )
    }

    // MARK: - Per-table exporters

    private static func exportSessions(
        conn: OpaquePointer,
        sinceTS: Double?,
        redact: Bool,
        to handle: FileHandle
    ) throws -> Int {
        let base = """
            SELECT id, started_at, ended_at, duration_seconds,
                   total_raw_bytes, total_saved_bytes, command_count,
                   pane_count, cost_saved_cents
            FROM sessions
            """
        let sql = sinceTS == nil
            ? base + " ORDER BY started_at;"
            : base + " WHERE started_at >= ? ORDER BY started_at;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ExportError.queryFailed("sessions prepare: \(String(cString: sqlite3_errmsg(conn)))")
        }
        defer { sqlite3_finalize(stmt) }
        if let ts = sinceTS { sqlite3_bind_double(stmt, 1, ts) }

        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row: [String: Any] = [
                "id": columnString(stmt, 0) ?? NSNull(),
                "started_at": sqlite3_column_double(stmt, 1),
                "ended_at": columnDoubleOrNull(stmt, 2),
                "duration_seconds": columnDoubleOrNull(stmt, 3),
                "total_raw_bytes": sqlite3_column_int64(stmt, 4),
                "total_saved_bytes": sqlite3_column_int64(stmt, 5),
                "command_count": sqlite3_column_int64(stmt, 6),
                "pane_count": sqlite3_column_int64(stmt, 7),
                "cost_saved_cents": sqlite3_column_int64(stmt, 8)
            ]
            try writeRow(table: "sessions", row: row, redact: redact, to: handle)
            count += 1
        }
        return count
    }

    private static func exportCommands(
        conn: OpaquePointer,
        sinceTS: Double?,
        redact: Bool,
        to handle: FileHandle
    ) throws -> Int {
        let base = """
            SELECT id, session_id, timestamp, tool_name, command,
                   raw_bytes, compressed_bytes, feature, output_preview
            FROM commands
            """
        let sql = sinceTS == nil
            ? base + " ORDER BY timestamp;"
            : base + " WHERE timestamp >= ? ORDER BY timestamp;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ExportError.queryFailed("commands prepare: \(String(cString: sqlite3_errmsg(conn)))")
        }
        defer { sqlite3_finalize(stmt) }
        if let ts = sinceTS { sqlite3_bind_double(stmt, 1, ts) }

        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row: [String: Any] = [
                "id": sqlite3_column_int64(stmt, 0),
                "session_id": columnString(stmt, 1) ?? NSNull(),
                "timestamp": sqlite3_column_double(stmt, 2),
                "tool_name": columnString(stmt, 3) ?? NSNull(),
                "command": columnString(stmt, 4) ?? NSNull(),
                "raw_bytes": sqlite3_column_int64(stmt, 5),
                "compressed_bytes": sqlite3_column_int64(stmt, 6),
                "feature": columnString(stmt, 7) ?? NSNull(),
                "output_preview": columnString(stmt, 8) ?? NSNull()
            ]
            try writeRow(table: "commands", row: row, redact: redact, to: handle)
            count += 1
        }
        return count
    }

    private static func exportTokenEvents(
        conn: OpaquePointer,
        sinceTS: Double?,
        redact: Bool,
        to handle: FileHandle
    ) throws -> Int {
        let base = """
            SELECT id, timestamp, session_id, pane_id, project_root,
                   source, tool_name, model, input_tokens, output_tokens,
                   saved_tokens, cost_cents, feature, command
            FROM token_events
            """
        let sql = sinceTS == nil
            ? base + " ORDER BY timestamp;"
            : base + " WHERE timestamp >= ? ORDER BY timestamp;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ExportError.queryFailed("token_events prepare: \(String(cString: sqlite3_errmsg(conn)))")
        }
        defer { sqlite3_finalize(stmt) }
        if let ts = sinceTS { sqlite3_bind_double(stmt, 1, ts) }

        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row: [String: Any] = [
                "id": sqlite3_column_int64(stmt, 0),
                "timestamp": sqlite3_column_double(stmt, 1),
                "session_id": columnString(stmt, 2) ?? NSNull(),
                "pane_id": columnString(stmt, 3) ?? NSNull(),
                "project_root": columnString(stmt, 4) ?? NSNull(),
                "source": columnString(stmt, 5) ?? NSNull(),
                "tool_name": columnString(stmt, 6) ?? NSNull(),
                "model": columnString(stmt, 7) ?? NSNull(),
                "input_tokens": sqlite3_column_int64(stmt, 8),
                "output_tokens": sqlite3_column_int64(stmt, 9),
                "saved_tokens": sqlite3_column_int64(stmt, 10),
                "cost_cents": sqlite3_column_int64(stmt, 11),
                "feature": columnString(stmt, 12) ?? NSNull(),
                "command": columnString(stmt, 13) ?? NSNull()
            ]
            try writeRow(table: "token_events", row: row, redact: redact, to: handle)
            count += 1
        }
        return count
    }

    // MARK: - Row encoding

    /// Apply redaction rules and emit one `{"table":..., "row": {...}}` JSON
    /// object per line.
    private static func writeRow(
        table: String,
        row: [String: Any],
        redact: Bool,
        to handle: FileHandle
    ) throws {
        var rowOut = row
        if redact {
            if let pr = rowOut["project_root"] as? String {
                rowOut["project_root"] = ProjectSecurity.redactPath(pr)
            }
            // commands.command + token_events.command may embed absolute
            // paths. We don't full-text-redact here (SecretDetector already
            // ran at insert-time for C1), but we do collapse the user's
            // home and any /Users/<name> prefix for portability.
            if let cmd = rowOut["command"] as? String {
                rowOut["command"] = redactAbsolutePaths(in: cmd)
            }
            if let preview = rowOut["output_preview"] as? String {
                rowOut["output_preview"] = redactAbsolutePaths(in: preview)
            }
        }

        let envelope: [String: Any] = [
            "table": table,
            "row": rowOut
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]
            )
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch let e as ExportError {
            throw e
        } catch {
            throw ExportError.jsonFailed(String(describing: error))
        }
    }

    /// Mild path-redaction for free-text columns: replace the first
    /// `/Users/<name>` occurrence with `/Users/***` (or `~` if the name
    /// matches the current user). Single-shot — not an aggressive scan —
    /// because commands like `ls /Users/alice/...` are common and we want
    /// the result stable, not heavily mangled.
    private static func redactAbsolutePaths(in s: String) -> String {
        let home = NSHomeDirectory()
        if let range = s.range(of: home) {
            return s.replacingCharacters(in: range, with: "~")
        }
        // Generic /Users/<name> (non-greedy until next slash or whitespace).
        if let regex = try? NSRegularExpression(pattern: "/Users/[^/\\s]+") {
            let ns = s as NSString
            return regex.stringByReplacingMatches(
                in: s,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "/Users/***"
            )
        }
        return s
    }

    // MARK: - Column helpers

    private static func columnString(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    private static func columnDoubleOrNull(_ stmt: OpaquePointer?, _ col: Int32) -> Any {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return NSNull() }
        return sqlite3_column_double(stmt, col)
    }
}
