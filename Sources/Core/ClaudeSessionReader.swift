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

    /// Parsed `usage` block from a single Claude JSONL assistant line.
    /// Returned by `parseAssistantUsageLine`. Single source of truth for the
    /// JSONL schema — both `ClaudeSessionReader.readFile` and
    /// `ClaudeSessionWatcher.readNewMessages` (SenkaniApp) consume it so the
    /// `cache_read_input_tokens → savedTokens` mapping cannot drift between
    /// the two readers (parent_finding 2026-05-12: ClaudeSessionWatcher
    /// hardcoded `savedTokens: 0` because it had its own copy of the parser
    /// that didn't extract cacheRead).
    public struct ParsedUsage: Sendable, Equatable {
        public let sessionId: String?
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let model: String?
        public let timestamp: Date?

        public init(sessionId: String?, inputTokens: Int, outputTokens: Int,
                    cacheReadTokens: Int, cacheWriteTokens: Int,
                    model: String?, timestamp: Date?) {
            self.sessionId = sessionId
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.model = model
            self.timestamp = timestamp
        }
    }

    /// Parse a single JSONL line and extract the `usage` block if it is an
    /// assistant message with non-zero input/output tokens. Returns `nil`
    /// for non-assistant lines, malformed JSON, or lines missing `usage`.
    ///
    /// Lines with `input_tokens == 0 && output_tokens == 0` ARE returned —
    /// the file-context `readFile` caller filters those (they're streaming
    /// partials), but the realtime tail caller in SenkaniApp wants every
    /// recordable assistant message routed to the DB to keep the timeline
    /// pane truthful, including cache-read-only re-prompts (which can
    /// have zero `input_tokens` but a non-zero `cache_read_input_tokens`).
    public static func parseAssistantUsageLine(_ line: String) -> ParsedUsage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let msgType = obj["type"] as? String, msgType == "assistant" else { return nil }

        let usage: [String: Any]?
        let model: String?
        if let msg = obj["message"] as? [String: Any] {
            usage = msg["usage"] as? [String: Any]
            model = msg["model"] as? String
        } else {
            usage = obj["usage"] as? [String: Any]
            model = obj["model"] as? String
        }
        guard let usageBlock = usage else { return nil }

        let inputTokens  = (usageBlock["input_tokens"]  as? Int) ?? 0
        let outputTokens = (usageBlock["output_tokens"] as? Int) ?? 0
        let cacheRead    = (usageBlock["cache_read_input_tokens"]    as? Int) ?? 0
        let cacheWrite   = (usageBlock["cache_creation_input_tokens"] as? Int) ?? 0

        let timestamp: Date?
        if let tsStr = obj["timestamp"] as? String {
            timestamp = iso8601.date(from: tsStr)
        } else {
            timestamp = nil
        }

        return ParsedUsage(
            sessionId: obj["sessionId"] as? String,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            model: model,
            timestamp: timestamp
        )
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
            guard let parsed = parseAssistantUsageLine(line) else { continue }

            // Skip entries with no real usage (e.g., filtered or streaming partials).
            // Note: cache-read-only re-prompts (input==0, output==0, cacheRead>0)
            // are filtered here too — `readNew` is the cursor-driven background
            // path that aggregates per-session totals; the realtime
            // ClaudeSessionWatcher records every assistant message instead.
            guard parsed.inputTokens > 0 || parsed.outputTokens > 0 else { continue }

            events.append(TokenEvent(
                claudeSessionId: sessionId,
                turnIndex: currentTurn,
                inputTokens: parsed.inputTokens,
                outputTokens: parsed.outputTokens,
                cacheReadTokens: parsed.cacheReadTokens,
                cacheWriteTokens: parsed.cacheWriteTokens,
                model: parsed.model,
                timestamp: parsed.timestamp ?? Date()
            ))
            currentTurn += 1
        }

        // Always advance cursor even if no events (skips junk lines on next read).
        db.setSessionCursor(path: path, byteOffset: newCursor, turnIndex: currentTurn)

        return events
    }
}
