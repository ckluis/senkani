import Foundation

/// Synchronous "read one batch and persist the cursor" primitive for the
/// realtime Claude Code JSONL tail. `ClaudeSessionWatcher` (SenkaniApp)
/// delegates here so the restart-safe path is independent of dispatch
/// sources and FSEvents — and unit-testable from `Tests/SenkaniTests`
/// without pulling the executable target into test deps.
///
/// Invariant: cursor reads are `parent.queue.sync`; cursor writes are
/// `parent.queue.async`. The cursor write at end-of-batch is enqueued
/// AFTER all `recordTokenEvent` calls for that batch, so the serial
/// queue commits events before the cursor advances. On mid-batch crash
/// the next process restart re-reads the unflushed window (bounded
/// duplication), which is the safer failure mode vs. silent loss.
public enum ClaudeSessionTail {

    public struct ReadResult: Sendable, Equatable {
        public let eventsEmitted: Int
        public let newOffset: Int
        public let resetFromBeginning: Bool

        public init(eventsEmitted: Int, newOffset: Int, resetFromBeginning: Bool = false) {
            self.eventsEmitted = eventsEmitted
            self.newOffset = newOffset
            self.resetFromBeginning = resetFromBeginning
        }
    }

    /// Read `path` from its persisted cursor offset to EOF, emit one
    /// `token_events` row per assistant-usage line, then persist the
    /// new offset. Returns the emit count + new offset.
    ///
    /// Cursor semantics:
    /// - `cursor.byteOffset > 0` and `<= fileSize` → seek to it
    /// - `cursor.byteOffset > fileSize` → file rotated/truncated under
    ///   us; reset to 0 and log `claude_session_tail.cursor_beyond_eof`
    /// - otherwise (fresh file) → read from the beginning
    @discardableResult
    public static func tail(
        path: String,
        projectRoot: String,
        paneId: String,
        db: SessionDatabase
    ) -> ReadResult {
        let (cursorOffset, _) = db.getSessionCursor(path: path)
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return ReadResult(eventsEmitted: 0, newOffset: cursorOffset)
        }
        defer { fh.closeFile() }

        let fileSize: UInt64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber {
            fileSize = size.uint64Value
        } else {
            fileSize = 0
        }

        let seekTo: UInt64
        var resetFromBeginning = false
        if cursorOffset > 0 && UInt64(cursorOffset) <= fileSize {
            seekTo = UInt64(cursorOffset)
        } else if cursorOffset > 0 && UInt64(cursorOffset) > fileSize {
            Logger.log("claude_session_tail.cursor_beyond_eof",
                       fields: ["path": .path(path),
                                "cursor": .int(cursorOffset),
                                "file_size": .int(Int(fileSize))])
            seekTo = 0
            resetFromBeginning = true
        } else {
            seekTo = 0
        }

        fh.seek(toFileOffset: seekTo)
        let newData = fh.readDataToEndOfFile()
        let newOffset = fh.offsetInFile
        guard newOffset > seekTo, !newData.isEmpty,
              let text = String(data: newData, encoding: .utf8) else {
            return ReadResult(eventsEmitted: 0,
                              newOffset: Int(newOffset),
                              resetFromBeginning: resetFromBeginning)
        }

        var emitted = 0
        for line in text.components(separatedBy: "\n") {
            guard let parsed = ClaudeSessionReader.parseAssistantUsageLine(line) else { continue }

            db.recordTokenEvent(
                sessionId: parsed.sessionId ?? "unknown",
                paneId: paneId,
                projectRoot: projectRoot,
                source: "claude_session",
                toolName: nil,
                model: parsed.model,
                inputTokens: parsed.inputTokens,
                outputTokens: parsed.outputTokens,
                savedTokens: parsed.cacheReadTokens,
                costCents: estimateCost(input: parsed.inputTokens,
                                        output: parsed.outputTokens,
                                        model: parsed.model),
                feature: nil,
                command: nil
            )
            emitted += 1
        }

        // Persist new cursor AFTER emit batch — see invariant note above.
        db.setSessionCursor(path: path,
                            byteOffset: Int(newOffset),
                            turnIndex: 0)

        return ReadResult(eventsEmitted: emitted,
                          newOffset: Int(newOffset),
                          resetFromBeginning: resetFromBeginning)
    }

    private static func estimateCost(input: Int, output: Int, model: String?) -> Int {
        let pricing = ModelPricing.find(model ?? "sonnet")
        let dollars = Double(input) / 1_000_000.0 * pricing.inputPerMillion
                    + Double(output) / 1_000_000.0 * pricing.outputPerMillion
        return Int(dollars * 100.0)
    }
}
