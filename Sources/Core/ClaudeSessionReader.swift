import Foundation

/// Reads Claude Code session JSONL files incrementally, extracting actual API usage.
/// This is the Tier 1 exact tracking path — real token counts from Claude's JSONL log.
///
/// Files live at: ~/.claude/projects/<hash>/<sessionId>.jsonl
/// Each line is a JSON object; assistant messages carry a `usage` block with token counts.
/// Cursors (byte offsets) are persisted in SessionDatabase so reads are incremental
/// and survive app restarts without double-counting.
public enum ClaudeSessionReader {

    /// One assistant turn's worth of token usage extracted from a JSONL file.
    public struct TokenEvent: Sendable {
        /// Claude Code session ID (stem of the JSONL filename, e.g. UUID string).
        public let claudeSessionId: String
        /// Zero-based index of this turn within the file (used for dedup key).
        public let turnIndex: Int
        public let inputTokens: Int
        public let outputTokens: Int
        /// Tokens served from the prompt cache (already paid for; counts as free reads).
        public let cacheReadTokens: Int
        /// Tokens written to the prompt cache.
        public let cacheWriteTokens: Int
        public let model: String?
        public let timestamp: Date
    }

    /// Scan all JSONL files under `projectsDir` and return any new events
    /// since the stored cursor for each file. Updates cursors in the database.
    ///
    /// Designed to be called from a background timer (30–60 s interval) or at session open.
    /// Thread-safe: reads are purely additive; each file is processed sequentially.
    ///
    /// - Parameters:
    ///   - db: The session database for cursor persistence.
    ///   - projectsDir: Root directory to scan. Defaults to `~/.claude/projects`.
    ///     Inject a temp directory in tests to isolate from real sessions.
    @discardableResult
    public static func readNew(
        db: SessionDatabase,
        projectsDir: String = NSHomeDirectory() + "/.claude/projects"
    ) -> [TokenEvent] {
        guard FileManager.default.fileExists(atPath: projectsDir) else { return [] }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsDir, isDirectory: &isDir),
              isDir.boolValue else { return [] }

        guard let topLevel = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }

        var events: [TokenEvent] = []
        for entry in topLevel {
            let entryPath = projectsDir + "/" + entry
            var entryIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entryPath, isDirectory: &entryIsDir),
                  entryIsDir.boolValue else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(atPath: entryPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let sessionId = String(file.dropLast(6))  // strip ".jsonl"
                let filePath = entryPath + "/" + file
                events.append(contentsOf: readFile(path: filePath, sessionId: sessionId, db: db))
            }
        }
        return events
    }

    // MARK: - File Reader

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func readFile(path: String, sessionId: String, db: SessionDatabase) -> [TokenEvent] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { handle.closeFile() }

        let (byteOffset, turnIndex) = db.getSessionCursor(path: path)
        if byteOffset > 0 {
            handle.seek(toFileOffset: UInt64(byteOffset))
        }

        let newData = handle.readDataToEndOfFile()
        guard !newData.isEmpty else { return [] }

        let newCursor = byteOffset + newData.count
        let text = String(data: newData, encoding: .utf8) ?? ""
        var events: [TokenEvent] = []
        var currentTurn = turnIndex

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Only assistant messages carry real usage data.
            guard let msgType = obj["type"] as? String, msgType == "assistant" else { continue }

            // The message content is nested: { type: "assistant", message: { usage: ... } }
            // or directly: { type: "assistant", usage: ... }
            let usage: [String: Any]?
            if let msg = obj["message"] as? [String: Any] {
                usage = msg["usage"] as? [String: Any]
            } else {
                usage = obj["usage"] as? [String: Any]
            }
            guard let usageBlock = usage else { continue }

            let inputTokens  = (usageBlock["input_tokens"]  as? Int) ?? 0
            let outputTokens = (usageBlock["output_tokens"] as? Int) ?? 0
            let cacheRead    = (usageBlock["cache_read_input_tokens"]    as? Int) ?? 0
            let cacheWrite   = (usageBlock["cache_creation_input_tokens"] as? Int) ?? 0

            // Skip entries with no real usage (e.g., filtered or streaming partials).
            guard inputTokens > 0 || outputTokens > 0 else { continue }

            let model: String?
            if let msg = obj["message"] as? [String: Any] {
                model = msg["model"] as? String
            } else {
                model = obj["model"] as? String
            }

            let timestamp: Date
            if let tsStr = obj["timestamp"] as? String,
               let parsed = iso8601.date(from: tsStr) {
                timestamp = parsed
            } else {
                timestamp = Date()
            }

            events.append(TokenEvent(
                claudeSessionId: sessionId,
                turnIndex: currentTurn,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                model: model,
                timestamp: timestamp
            ))
            currentTurn += 1
        }

        // Always advance cursor even if no events (skips junk lines on next read).
        db.setSessionCursor(path: path, byteOffset: newCursor, turnIndex: currentTurn)

        return events
    }
}
