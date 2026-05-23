import Foundation
import CryptoKit

/// Phase V.17a-2 — Codex CLI runtime adapter. Parses Codex CLI's
/// JSONL transcript stream into `[ProviderRuntimeEvent]` per the
/// V.17a-1 spine's `ProviderRuntimeAdapter` protocol.
///
/// **Pure parser.** No network, no auth probe, no provider-side
/// side-effect. The adapter is reusable: `ingest(_:)` may be called
/// repeatedly with successive byte chunks; any trailing partial
/// line (bytes after the last newline) stays in the adapter's
/// internal buffer and is prepended to the next call. A complete
/// line is "a JSON object terminated by `\n`."
///
/// **`raw_payload_hash` derivation.** Hex-encoded SHA-256 of the
/// canonical JSONL line bytes — terminating newline excluded so the
/// hash is independent of whether the upstream stream uses `\n` or
/// `\r\n`. The hash is what V.17a-1's `provider_runtime_event`
/// table dedupes on; a replay of identical bytes produces an
/// identical hash and the store's UNIQUE constraint elides the
/// second insert.
///
/// **Fabricated-fixtures contract** (per the operator's decompose
/// answer to Q5, 2026-05-23). The autonomous loop does not have
/// access to real Codex CLI credentials, so test fixtures are
/// fabricated plausible JSONL shapes that match the Codex CLI
/// event vocabulary documented in
/// `spec/inspirations/native-app-ux/codex-plusplus.md` and the
/// 10-case canonical enum the V.17a-1 spine ratified. The wire
/// vocabulary below is intentionally small — adding a new wire
/// event-type requires extending both `WireEventType` and the
/// `convert(_:rawHash:)` mapping in one edit.
public final class CodexCLIRuntimeAdapter: ProviderRuntimeAdapter, @unchecked Sendable {
    public let providerID: String = "codex-cli"

    /// Trailing partial line carried between successive `ingest`
    /// calls. Bounded by the upstream's pipe buffer; the adapter
    /// itself imposes no cap (a 1 MB single-line JSONL is legal,
    /// rare in practice).
    private var pendingBuffer: Data = Data()
    private let lock = NSLock()

    public init() {}

    /// Translate raw bytes into zero or more events. Newline-delimited
    /// (`\n`); a trailing partial line is buffered for the next call.
    /// Throws `CodexCLIRuntimeAdapter.ParseError` on a malformed
    /// JSONL line — partial buffers do NOT throw, they wait.
    public func ingest(_ raw: Data) async throws -> [ProviderRuntimeEvent] {
        let lines = appendAndSplit(raw)
        var out: [ProviderRuntimeEvent] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let event = try parseLine(line)
            out.append(event)
        }
        return out
    }

    // MARK: - Errors

    public enum ParseError: Error, Equatable {
        /// JSONL line bytes were not valid JSON, or did not decode
        /// to the wire envelope shape. Carries the offending bytes
        /// (utf-8 best-effort) for caller diagnostics.
        case malformedJSON(line: String)
        /// The `type` field on the wire envelope was not a known
        /// Codex CLI event-type string. Carries the unknown value
        /// so a future vocabulary drift is observable from the
        /// caller's logs.
        case unknownEventType(raw: String)
    }

    // MARK: - Buffer plumbing

    /// Append `raw` to the pending buffer, split on `\n`, keep any
    /// trailing partial line in the buffer, and return the complete
    /// lines (without their newline terminators).
    private func appendAndSplit(_ raw: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        pendingBuffer.append(raw)
        var lines: [Data] = []
        var lineStart = pendingBuffer.startIndex
        var idx = pendingBuffer.startIndex
        while idx < pendingBuffer.endIndex {
            if pendingBuffer[idx] == 0x0A {  // '\n'
                let line = pendingBuffer.subdata(in: lineStart..<idx)
                lines.append(stripCR(line))
                lineStart = pendingBuffer.index(after: idx)
            }
            idx = pendingBuffer.index(after: idx)
        }
        // Anything past the last newline stays in the buffer.
        if lineStart < pendingBuffer.endIndex {
            pendingBuffer = pendingBuffer.subdata(in: lineStart..<pendingBuffer.endIndex)
        } else {
            pendingBuffer.removeAll(keepingCapacity: true)
        }
        // Drop empty lines (consecutive newlines, trailing newline
        // after a flush). The wire format does not use them.
        return lines.filter { !$0.isEmpty }
    }

    /// Strip a single trailing `\r` if present (CRLF normalization).
    /// The hash is computed on the CR-stripped bytes so streams
    /// crossing a CRLF-translating tty produce identical hashes.
    private func stripCR(_ data: Data) -> Data {
        if let last = data.last, last == 0x0D {
            return data.subdata(in: data.startIndex..<data.index(before: data.endIndex))
        }
        return data
    }

    // MARK: - JSONL → ProviderRuntimeEvent

    private func parseLine(_ line: Data) throws -> ProviderRuntimeEvent {
        let rawHash = Self.sha256Hex(of: line)
        let wire: WireEvent
        do {
            wire = try JSONDecoder().decode(WireEvent.self, from: line)
        } catch {
            let preview = String(data: line, encoding: .utf8) ?? "<non-utf8 \(line.count)B>"
            throw ParseError.malformedJSON(line: preview)
        }
        return try convert(wire, rawHash: rawHash)
    }

    private func convert(_ wire: WireEvent, rawHash: String) throws -> ProviderRuntimeEvent {
        guard let wireType = WireEventType(rawValue: wire.type) else {
            throw ParseError.unknownEventType(raw: wire.type)
        }
        let canonical: ProviderRuntimeEvent.EventType
        var projectionStatus: ProviderRuntimeEvent.ProjectionStatus = .ineligible
        switch wireType {
        case .messageStarted:
            canonical = .messageStarted
        case .messageDelta:
            canonical = .messageDelta
        case .toolCallStarted:
            canonical = .toolCallStarted
        case .toolCallCompleted:
            canonical = .toolCallFinished
            projectionStatus = .pending
        case .approvalRequested:
            canonical = .approvalRequested
        case .approvalGranted:
            canonical = .approvalGranted
        case .userInputRequested:
            canonical = .userInputRequested
        case .turnCompleted:
            canonical = .turnCompleted
            projectionStatus = .pending
        case .turnAborted:
            canonical = .turnAborted
        case .warning:
            canonical = .warning
        }

        let tokens: ProviderRuntimeEvent.TokenSnapshot? = wire.usage.map { u in
            ProviderRuntimeEvent.TokenSnapshot(
                promptTokens: u.prompt_tokens,
                completionTokens: u.completion_tokens,
                cachedTokens: u.cached_tokens
            )
        }

        let observedAt = wire.ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let warnings: [String]
        if let single = wire.message, canonical == .warning {
            warnings = [single]
        } else {
            warnings = []
        }

        return ProviderRuntimeEvent(
            providerID: providerID,
            sessionID: wire.session_id,
            threadID: wire.thread_id,
            turnID: wire.turn_id,
            pane: wire.pane,
            type: canonical,
            observedAt: observedAt,
            tokens: tokens,
            toolCallID: wire.tool_call_id,
            toolName: wire.tool,
            toolResult: wire.result,
            approvalID: wire.approval_id,
            warnings: warnings,
            projectionStatus: projectionStatus,
            rawPayloadHash: rawHash
        )
    }

    // MARK: - SHA-256 helper (hex-encoded)

    /// Hex-encoded SHA-256 of `data`. Stable across Apple platforms;
    /// matches what `provider_runtime_event.raw_payload_hash` UNIQUE
    /// constraint dedupes on.
    static func sha256Hex(of data: Data) -> String {
        var digest = SHA256()
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Wire envelope (private — adapters' impl detail)

    /// Codex CLI's wire vocabulary. Mapped 1:1 onto the canonical
    /// 10-case enum in `convert(_:rawHash:)`. Adding a new wire
    /// type requires a new case AND a new switch arm in `convert`
    /// — `WireEventType` is the choke point.
    private enum WireEventType: String {
        case messageStarted     = "message.started"
        case messageDelta       = "message.delta"
        case toolCallStarted    = "tool_call.started"
        case toolCallCompleted  = "tool_call.completed"
        case approvalRequested  = "approval.requested"
        case approvalGranted    = "approval.granted"
        case userInputRequested = "user_input.requested"
        case turnCompleted      = "turn.completed"
        case turnAborted        = "turn.aborted"
        case warning            = "warning"
    }

    /// JSONL envelope decoded from each line. Every field optional
    /// except `type` — Codex CLI's wire shape varies per event and
    /// the adapter tolerates absent fields (e.g. token snapshots
    /// only appear on `message.delta` + `turn.completed`).
    private struct WireEvent: Decodable {
        let type: String
        let session_id: String?
        let thread_id: String?
        let turn_id: String?
        let pane: String?
        let tool_call_id: String?
        let tool: String?
        let result: String?
        let approval_id: String?
        let message: String?
        let ts: Double?
        let usage: WireUsage?
    }

    private struct WireUsage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let cached_tokens: Int?
    }
}
