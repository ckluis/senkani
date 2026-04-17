import ArgumentParser
import Foundation
import Core

/// Cavoukian C3 — data-portability export. Streams `sessions`,
/// `commands`, and `token_events` from the session DB as JSONL.
///
/// Usage:
///   senkani export --output ~/senkani-backup.jsonl
///   senkani export --output ./last-week.jsonl --since 2026-04-10
///   senkani export --output ./safe.jsonl --redact
///
/// Output format: one JSON object per line,
///   {"row": {...columns...}, "table": "sessions|commands|token_events"}
///
/// With `--redact`: `project_root` and path occurrences in text columns
/// have `/Users/<name>` collapsed to `~` (current user) or `/Users/***`
/// (others). Row content already went through `SecretDetector.scan` at
/// insert time when C1 landed; this flag adds the path-level redaction.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export session data as JSONL (one row per line)."
    )

    @Option(name: .long, help: "Path to the output JSONL file. `-` writes to stdout.")
    var output: String

    @Option(name: .long, help: "Only export rows with timestamps on or after this ISO-8601 date (YYYY-MM-DD or full RFC 3339).")
    var since: String?

    @Flag(name: .long, help: "Redact user paths (/Users/<name>) in output.")
    var redact: Bool = false

    @Option(name: .long, help: "Override the DB path (default: ~/Library/Application Support/Senkani/senkani.db).")
    var db: String?

    mutating func run() throws {
        let dbPath = try resolvedDBPath()
        let sinceDate = try parsedSince()
        let handle = try openOutputHandle()
        // Close stdout at the end only if we opened a real file.
        let shouldClose = (output != "-")
        defer { if shouldClose { try? handle.close() } }

        let summary = try SessionExporter.export(
            dbPath: dbPath,
            since: sinceDate,
            redact: redact,
            to: handle
        )

        // Report on stderr so the JSONL stream on stdout is clean when
        // `--output -` is used.
        FileHandle.standardError.write(Data("""
        senkani export — \(summary.total) rows\
         (\(summary.sessions) sessions, \(summary.commands) commands, \(summary.tokenEvents) token_events)\
         → \(output == "-" ? "stdout" : output)\(redact ? " (redacted)" : "")

        """.utf8))
    }

    // MARK: - Helpers

    private func resolvedDBPath() throws -> String {
        if let db = db { return db }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Senkani", isDirectory: true)
            .appendingPathComponent("senkani.db")
            .path
    }

    private func parsedSince() throws -> Date? {
        guard let raw = since else { return nil }
        // Accept a bare `YYYY-MM-DD` or a full RFC 3339 / ISO-8601 stamp.
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withFullDate]
        if let d = iso.date(from: raw) { return d }
        // Last chance: bare date via DateFormatter.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        if let d = df.date(from: raw) { return d }
        throw ValidationError("--since must be ISO-8601 (YYYY-MM-DD or full RFC 3339), got: \(raw)")
    }

    private func openOutputHandle() throws -> FileHandle {
        if output == "-" {
            return FileHandle.standardOutput
        }
        let url = URL(fileURLWithPath: output)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        } else {
            // Overwrite: truncate to zero before writing.
            try Data().write(to: url)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw ValidationError("could not open output file for writing: \(output)")
        }
        return h
    }
}
