import Foundation

/// Phase V.17a-4 — Gemini CLI runtime adapter. Parses Gemini CLI's
/// JSONL event stream into `[ProviderRuntimeEvent]` per the V.17a-1
/// spine's `ProviderRuntimeAdapter` protocol.
///
/// **Pure parser.** No network, no auth probe, no provider-side
/// side-effect. Reusable: `ingest(_:)` may be called repeatedly;
/// trailing partial line after the last `\n` carries over via an
/// `NSLock`-guarded internal buffer. CRLF normalized at the line
/// boundary so the SHA-256 `raw_payload_hash` is independent of
/// CRLF translation in the transport.
///
/// **No provider-specific reuse seam.** Unlike V.17a-3
/// (`ClaudeCodeRuntimeAdapter`) which delegates token extraction
/// to `ClaudeSessionReader.parseAssistantUsageLine`, the codebase
/// has no pre-existing Gemini CLI scaffolding. Line-buffer + CRLF
/// + SHA-256 helpers delegate to V.17a-1's shared
/// `JSONLLineBuffer` / `ProviderRuntimeHash` (V.17a-7 extraction,
/// 2026-05-24) per the operator's implicit answer to the V.17
/// decompose-round Q3 ("if they grow past trivial, file a 7th
/// sub-item").
///
/// **Fabricated-fixtures contract** (operator's decompose answer to
/// Q5, 2026-05-23). Wire vocabulary fabricated plausible from the
/// dp-code inspiration's notes on Gemini CLI's event-format.
public final class GeminiCLIRuntimeAdapter: ProviderRuntimeAdapter, @unchecked Sendable {
    public let providerID: String = "gemini-cli"

    private let buffer = JSONLLineBuffer()

    public init() {}

    public func ingest(_ raw: Data) async throws -> [ProviderRuntimeEvent] {
        let lines = buffer.append(raw)
        var out: [ProviderRuntimeEvent] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            out.append(try parseLine(line))
        }
        return out
    }

    // MARK: - Errors

    public enum ParseError: Error, Equatable {
        case malformedJSON(line: String)
        case unknownEventType(raw: String)
    }

    // MARK: - JSONL → ProviderRuntimeEvent

    private func parseLine(_ line: Data) throws -> ProviderRuntimeEvent {
        let rawHash = ProviderRuntimeHash.sha256Hex(of: line)
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
        guard let wireType = WireEventType(rawValue: wire.event_type) else {
            throw ParseError.unknownEventType(raw: wire.event_type)
        }
        let canonical: ProviderRuntimeEvent.EventType
        var projectionStatus: ProviderRuntimeEvent.ProjectionStatus = .ineligible
        switch wireType {
        case .contentStart:
            canonical = .messageStarted
        case .contentDelta:
            canonical = .messageDelta
        case .toolInvoke:
            canonical = .toolCallStarted
        case .toolResult:
            canonical = .toolCallFinished
            projectionStatus = .pending
        case .permissionRequest:
            canonical = .approvalRequested
        case .permissionResponse:
            // Gemini's permission_response carries a `granted: bool`
            // field; map true → granted, false → aborted (no first-
            // class "denied" canonical event today — surfacing as
            // .turnAborted with the reason is the least-lossy
            // mapping).
            canonical = (wire.granted == false) ? .turnAborted : .approvalGranted
        case .turnEnd:
            canonical = .turnCompleted
            projectionStatus = .pending
        case .turnCancelled:
            canonical = .turnAborted
        case .warning:
            canonical = .warning
        case .userInput:
            canonical = .userInputRequested
        }

        let tokens: ProviderRuntimeEvent.TokenSnapshot?
        if let u = wire.usage {
            tokens = ProviderRuntimeEvent.TokenSnapshot(
                promptTokens: u.promptTokenCount,
                completionTokens: u.candidatesTokenCount,
                cachedTokens: u.cachedContentTokenCount
            )
        } else {
            tokens = nil
        }

        let observedAt = wire.ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let warnings: [String]
        if canonical == .warning, let msg = wire.message {
            warnings = [msg]
        } else if canonical == .turnAborted, let reason = wire.reason {
            warnings = [reason]
        } else {
            warnings = []
        }

        return ProviderRuntimeEvent(
            providerID: providerID,
            sessionID: wire.sessionId,
            threadID: wire.threadId,
            turnID: wire.turnId,
            pane: wire.pane,
            type: canonical,
            observedAt: observedAt,
            tokens: tokens,
            toolCallID: wire.toolCallId,
            toolName: wire.toolName,
            toolResult: wire.status,
            approvalID: wire.approvalId,
            warnings: warnings,
            projectionStatus: projectionStatus,
            rawPayloadHash: rawHash
        )
    }

    // MARK: - Wire envelope

    /// Gemini CLI's event-format vocabulary. Adding a new wire
    /// event-type requires a new case AND a new switch arm in
    /// `convert(_:rawHash:)` — single choke point.
    private enum WireEventType: String {
        case contentStart       = "content_start"
        case contentDelta       = "content_delta"
        case toolInvoke         = "tool_invoke"
        case toolResult         = "tool_result"
        case permissionRequest  = "permission_request"
        case permissionResponse = "permission_response"
        case userInput          = "user_input"
        case turnEnd            = "turn_end"
        case turnCancelled      = "turn_cancelled"
        case warning            = "warning"
    }

    private struct WireEvent: Decodable {
        let event_type: String
        let sessionId: String?
        let threadId: String?
        let turnId: String?
        let pane: String?
        let toolCallId: String?
        let toolName: String?
        let status: String?
        let approvalId: String?
        let granted: Bool?
        let message: String?
        let reason: String?
        let ts: Double?
        let usage: WireUsage?
    }

    private struct WireUsage: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let cachedContentTokenCount: Int?
    }
}
