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
        let (cursorOffset, _) = db.getSessionCursor(path: path, reader: "watcher")
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
        // Byte offset of the current line WITHIN the file (not the batch),
        // so the V.3a derived idempotency key is stable across re-tails of
        // overlapping windows. Starts at `seekTo` (where this read began)
        // and advances by each line's UTF-8 byte length + 1 (the "\n"
        // separator stripped by `components(separatedBy:)`).
        var lineByteOffset = Int(seekTo)
        for line in text.components(separatedBy: "\n") {
            let lineStartOffset = lineByteOffset
            // Advance the cursor past this line + its separator BEFORE the
            // skip-`continue`, so non-assistant lines still move the offset.
            lineByteOffset += line.utf8.count + 1

            guard let parsed = ClaudeSessionReader.parseAssistantUsageLine(line) else { continue }

            let resolvedSessionId = parsed.sessionId ?? "unknown"

            db.recordTokenEvent(
                sessionId: resolvedSessionId,
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

            // V.3a — ALSO emit one canonical `agent_trace_event` row per
            // assistant line so the V.3 hover popover reads a single
            // source-of-truth. Additive (Allspaw): the `token_events`
            // write above is unchanged. Carmack: no new fd/thread — this
            // is a second SYNC store call on the SAME batch, reusing the
            // existing FileHandle. The idempotency_key is DERIVED
            // (Schneier: fingerprint sessionId + byteOffset + lineHash,
            // never caller-supplied), so a re-tailed window dedups via the
            // store's ON CONFLICT DO NOTHING (Kleppmann: no-loss/no-dup —
            // a mid-batch-crash re-read lands the same rows, not doubles).
            recordAssistantLineTrace(
                db: db,
                sessionId: resolvedSessionId,
                paneId: paneId,
                projectRoot: projectRoot,
                byteOffset: lineStartOffset,
                line: line,
                parsed: parsed
            )
            emitted += 1
        }

        // Persist new cursor AFTER emit batch — see invariant note above.
        // reader: "watcher" — the realtime tail has no concept of turns;
        // ClaudeSessionReader.readNew is the monotonic-turn-count writer
        // and scopes to reader: "reader". The split (migration 21) keeps
        // them from clobbering each other's row.
        db.setSessionCursor(path: path,
                            byteOffset: Int(newOffset),
                            turnIndex: 0,
                            reader: "watcher")

        return ReadResult(eventsEmitted: emitted,
                          newOffset: Int(newOffset),
                          resetFromBeginning: resetFromBeginning)
    }

    /// V.3a — write the canonical `agent_trace_event` row for one assistant
    /// JSONL line. The idempotency_key is DERIVED from `sessionId +
    /// byteOffset + lineHash` (Schneier: never caller-supplied) so a
    /// re-tail of the same byte window dedups via the store's ON CONFLICT
    /// DO NOTHING. Extracted as an internal static so a test can drive the
    /// exact key derivation if it needs to.
    static func recordAssistantLineTrace(
        db: SessionDatabase,
        sessionId: String,
        paneId: String,
        projectRoot: String,
        byteOffset: Int,
        line: String,
        parsed: ClaudeSessionReader.ParsedUsage
    ) {
        let lineHash = SHA256Hasher.hex(of: Data(line.utf8))
        let material = "v3a-tail:\(sessionId)|\(byteOffset)|\(lineHash)"
        let key = "v3a-tail:" + SHA256Hasher.hex(of: Data(material.utf8))
        let when = parsed.timestamp ?? Date()
        let row = AgentTraceEvent(
            idempotencyKey: key,
            pane: paneId,
            project: projectRoot,
            model: parsed.model,
            tier: nil,
            ladderPosition: nil,
            feature: nil,
            result: .success,
            startedAt: when,
            completedAt: when,
            latencyMs: 0,
            tokensIn: parsed.inputTokens,
            tokensOut: parsed.outputTokens,
            costCents: estimateCost(input: parsed.inputTokens,
                                    output: parsed.outputTokens,
                                    model: parsed.model),
            redactionCount: 0,
            validationStatus: nil,
            confirmationRequired: false,
            egressDecisions: 0,
            planId: nil,
            costLedgerVersion: nil,
            sessionId: sessionId,
            toolCallId: nil
        )
        db.recordAgentTraceEvent(row)
    }

    private static func estimateCost(input: Int, output: Int, model: String?) -> Int {
        let pricing = ModelPricing.find(model ?? "sonnet")
        let dollars = Double(input) / 1_000_000.0 * pricing.inputPerMillion
                    + Double(output) / 1_000_000.0 * pricing.outputPerMillion
        return Int(dollars * 100.0)
    }
}
