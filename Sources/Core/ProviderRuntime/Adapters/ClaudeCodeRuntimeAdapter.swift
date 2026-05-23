import Foundation
import CryptoKit

/// Phase V.17a-3 — Claude Code runtime adapter. Parses Claude Code's
/// `--output-format=stream-json` JSONL stream into
/// `[ProviderRuntimeEvent]` per the V.17a-1 spine's
/// `ProviderRuntimeAdapter` protocol.
///
/// **Reuse seam.** Token snapshot extraction on `assistant`-typed
/// lines delegates to `ClaudeSessionReader.parseAssistantUsageLine(_:)`
/// — the single source of truth for the `usage` block shape that
/// production code (`ClaudeSessionTail`, `ClaudeSessionWatcher`, the
/// background `readNew` aggregator) already consumes. The 2026-05-12
/// drift incident (`ClaudeSessionWatcher` hardcoded
/// `savedTokens: 0` because it had its own copy of the parser that
/// didn't extract `cache_read_input_tokens`) is the durable
/// motivation; this adapter must not duplicate that parser.
///
/// **Line-buffering pattern** matches V.17a-2 (NSLock-guarded byte
/// buffer split on `\n`, CRLF normalized) so partial-buffer
/// carryover across successive `ingest(_:)` calls produces hash-
/// stable events independent of chunk boundaries. The Claude Code
/// session-file readers (`ClaudeSessionReader.readFile`,
/// `ClaudeSessionTail.tail`) use the same
/// `text.components(separatedBy: "\n")` discipline at a different
/// layer (cursor-driven file reads); this adapter sits on the
/// `Data` API the V.17a-1 protocol defines.
///
/// **Fabricated-fixtures contract** (per the operator's decompose
/// answer to Q5, 2026-05-23). The autonomous loop does not have
/// access to real Claude Code sessions, so fixtures are plausible
/// `stream-json` shapes consistent with Claude Code's documented
/// vocabulary. Wire vocabulary lives in `convert(_:rawHash:)` as a
/// (`type`, `subtype`, content-shape) switch — adding a new shape
/// requires one edit there.
public final class ClaudeCodeRuntimeAdapter: ProviderRuntimeAdapter, @unchecked Sendable {
    public let providerID: String = "claude-code"

    private var pendingBuffer: Data = Data()
    private let lock = NSLock()

    public init() {}

    public func ingest(_ raw: Data) async throws -> [ProviderRuntimeEvent] {
        let lines = appendAndSplit(raw)
        var out: [ProviderRuntimeEvent] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            // Skip blank lines silently — JSONL streams sometimes
            // emit an empty terminator after the final result.
            if line.isEmpty { continue }
            if let event = try parseLine(line) {
                out.append(event)
            }
        }
        return out
    }

    // MARK: - Errors

    public enum ParseError: Error, Equatable {
        case malformedJSON(line: String)
        case unknownEventShape(typeAndSubtype: String)
    }

    // MARK: - Buffer plumbing (mirrors V.17a-2's discipline)

    private func appendAndSplit(_ raw: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        pendingBuffer.append(raw)
        var lines: [Data] = []
        var lineStart = pendingBuffer.startIndex
        var idx = pendingBuffer.startIndex
        while idx < pendingBuffer.endIndex {
            if pendingBuffer[idx] == 0x0A {
                let line = pendingBuffer.subdata(in: lineStart..<idx)
                lines.append(stripCR(line))
                lineStart = pendingBuffer.index(after: idx)
            }
            idx = pendingBuffer.index(after: idx)
        }
        if lineStart < pendingBuffer.endIndex {
            pendingBuffer = pendingBuffer.subdata(in: lineStart..<pendingBuffer.endIndex)
        } else {
            pendingBuffer.removeAll(keepingCapacity: true)
        }
        return lines
    }

    private func stripCR(_ data: Data) -> Data {
        if let last = data.last, last == 0x0D {
            return data.subdata(in: data.startIndex..<data.index(before: data.endIndex))
        }
        return data
    }

    // MARK: - JSONL → ProviderRuntimeEvent

    /// Returns nil for lines that are valid JSON but carry no
    /// observable runtime moment (e.g. `system.init` session
    /// metadata). Throws for malformed JSON or unknown shapes so
    /// fixture drift surfaces.
    private func parseLine(_ line: Data) throws -> ProviderRuntimeEvent? {
        let rawHash = Self.sha256Hex(of: line)
        guard let lineString = String(data: line, encoding: .utf8) else {
            throw ParseError.malformedJSON(line: "<non-utf8 \(line.count)B>")
        }
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: line, options: []) as? [String: Any] else {
                throw ParseError.malformedJSON(line: lineString)
            }
            obj = parsed
        } catch let err as ParseError {
            throw err
        } catch {
            throw ParseError.malformedJSON(line: lineString)
        }
        return try convert(obj, lineString: lineString, rawHash: rawHash)
    }

    private func convert(_ obj: [String: Any], lineString: String, rawHash: String) throws -> ProviderRuntimeEvent? {
        let type = (obj["type"] as? String) ?? ""
        let subtype = obj["subtype"] as? String
        let sessionID = obj["session_id"] as? String ?? obj["sessionId"] as? String
        let threadID = obj["thread_id"] as? String ?? obj["threadId"] as? String
        let turnID = obj["turn_id"] as? String ?? obj["turnId"] as? String
        let pane = obj["pane"] as? String
        let observedAt = parseTimestamp(obj) ?? Date()

        switch (type, subtype) {
        case ("system", let s?) where s == "init":
            // session-init metadata — no canonical event maps; skip.
            return nil

        case ("system", let s?) where s == "warning":
            let msg = obj["message"] as? String ?? ""
            return ProviderRuntimeEvent(
                providerID: providerID,
                sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                type: .warning,
                observedAt: observedAt,
                warnings: msg.isEmpty ? [] : [msg],
                projectionStatus: .ineligible,
                rawPayloadHash: rawHash
            )

        case ("approval", let s?) where s == "requested":
            return ProviderRuntimeEvent(
                providerID: providerID,
                sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                type: .approvalRequested,
                observedAt: observedAt,
                toolCallID: obj["tool_use_id"] as? String,
                approvalID: obj["approval_id"] as? String,
                projectionStatus: .ineligible,
                rawPayloadHash: rawHash
            )

        case ("approval", let s?) where s == "granted":
            return ProviderRuntimeEvent(
                providerID: providerID,
                sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                type: .approvalGranted,
                observedAt: observedAt,
                toolCallID: obj["tool_use_id"] as? String,
                approvalID: obj["approval_id"] as? String,
                projectionStatus: .ineligible,
                rawPayloadHash: rawHash
            )

        case ("user", _):
            // Identify tool_result content blocks (tool-call
            // completion arrives via the user-typed message
            // carrying tool_result in Claude Code's stream-json).
            if let block = firstContentBlock(obj, ofType: "tool_result") {
                let toolUseID = block["tool_use_id"] as? String
                let isError = (block["is_error"] as? Bool) ?? false
                let resultText: String?
                if let s = block["content"] as? String {
                    resultText = isError ? "error: \(s.prefix(64))" : "success"
                } else {
                    resultText = isError ? "error" : "success"
                }
                return ProviderRuntimeEvent(
                    providerID: providerID,
                    sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                    type: .toolCallFinished,
                    observedAt: observedAt,
                    toolCallID: toolUseID,
                    toolResult: resultText,
                    projectionStatus: .pending,
                    rawPayloadHash: rawHash
                )
            }
            // Plain user-typed prompt: surface as userInputRequested
            // (operator-side input the agent will respond to).
            return ProviderRuntimeEvent(
                providerID: providerID,
                sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                type: .userInputRequested,
                observedAt: observedAt,
                projectionStatus: .ineligible,
                rawPayloadHash: rawHash
            )

        case ("assistant", _):
            // Reuse seam: token snapshot via the canonical parser.
            let usage = ClaudeSessionReader.parseAssistantUsageLine(lineString)
            let tokens: ProviderRuntimeEvent.TokenSnapshot?
            if let u = usage {
                tokens = ProviderRuntimeEvent.TokenSnapshot(
                    promptTokens: u.inputTokens,
                    completionTokens: u.outputTokens,
                    cachedTokens: u.cacheReadTokens
                )
            } else {
                tokens = nil
            }
            // tool_use content block → toolCallStarted; otherwise
            // assistant text → messageStarted (treat each line
            // emitted by stream-json as a discrete start, since
            // Claude Code does not always interleave deltas).
            if let block = firstContentBlock(obj, ofType: "tool_use") {
                return ProviderRuntimeEvent(
                    providerID: providerID,
                    sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                    type: .toolCallStarted,
                    observedAt: observedAt,
                    tokens: tokens,
                    toolCallID: block["id"] as? String,
                    toolName: block["name"] as? String,
                    projectionStatus: .ineligible,
                    rawPayloadHash: rawHash
                )
            }
            return ProviderRuntimeEvent(
                providerID: providerID,
                sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                type: .messageStarted,
                observedAt: observedAt,
                tokens: tokens,
                projectionStatus: .ineligible,
                rawPayloadHash: rawHash
            )

        case ("result", let s?):
            let usageDict = (obj["usage"] as? [String: Any]) ?? [:]
            let tokens = ProviderRuntimeEvent.TokenSnapshot(
                promptTokens: usageDict["input_tokens"] as? Int,
                completionTokens: usageDict["output_tokens"] as? Int,
                cachedTokens: usageDict["cache_read_input_tokens"] as? Int
            )
            // Distinguish success-shaped from abort-shaped results.
            // Anything starting with "error_" (Claude Code's
            // documented vocabulary: error_max_turns,
            // error_during_execution, etc.) maps to turnAborted.
            if s == "success" {
                return ProviderRuntimeEvent(
                    providerID: providerID,
                    sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                    type: .turnCompleted,
                    observedAt: observedAt,
                    tokens: hasAnyToken(tokens) ? tokens : nil,
                    projectionStatus: .pending,
                    rawPayloadHash: rawHash
                )
            }
            return ProviderRuntimeEvent(
                providerID: providerID,
                sessionID: sessionID, threadID: threadID, turnID: turnID, pane: pane,
                type: .turnAborted,
                observedAt: observedAt,
                tokens: hasAnyToken(tokens) ? tokens : nil,
                warnings: [s],
                projectionStatus: .ineligible,
                rawPayloadHash: rawHash
            )

        default:
            throw ParseError.unknownEventShape(typeAndSubtype: "\(type)/\(subtype ?? "-")")
        }
    }

    private func hasAnyToken(_ t: ProviderRuntimeEvent.TokenSnapshot) -> Bool {
        return t.promptTokens != nil || t.completionTokens != nil || t.cachedTokens != nil
    }

    private func firstContentBlock(_ obj: [String: Any], ofType blockType: String) -> [String: Any]? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content {
            if (block["type"] as? String) == blockType { return block }
        }
        return nil
    }

    private func parseTimestamp(_ obj: [String: Any]) -> Date? {
        if let d = obj["ts"] as? Double {
            return Date(timeIntervalSince1970: d)
        }
        if let s = obj["timestamp"] as? String, let d = Self.iso8601.date(from: s) {
            return d
        }
        return nil
    }

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func sha256Hex(of data: Data) -> String {
        var digest = SHA256()
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
