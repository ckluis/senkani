import Foundation

/// Phase V.17a-5 — OpenCode runtime adapter. Parses OpenCode's
/// JSONL event stream into `[ProviderRuntimeEvent]` per the V.17a-1
/// spine's `ProviderRuntimeAdapter` protocol.
///
/// **Pure parser.** No network, no auth probe, no provider-side
/// side-effect. Reusable: `ingest(_:)` may be called repeatedly;
/// trailing partial line after the last `\n` carries over via an
/// `NSLock`-guarded internal buffer. CRLF normalized at the line
/// boundary so the SHA-256 `raw_payload_hash` is independent of
/// transport CRLF translation.
///
/// **No provider-specific reuse seam.** Greenfield parser —
/// OpenCode has no pre-existing senkani-side scaffolding. Line-
/// buffer + CRLF + SHA-256 helpers delegate to V.17a-1's shared
/// `JSONLLineBuffer` / `ProviderRuntimeHash` (V.17a-7 extraction,
/// 2026-05-24).
///
/// **Fabricated-fixtures contract** (operator's decompose answer to
/// Q5, 2026-05-23). Wire vocabulary is plausible kebab-case shapes
/// matching the OpenCode TUI agent's documented event format.
public final class OpenCodeRuntimeAdapter: ProviderRuntimeAdapter, @unchecked Sendable {
    public let providerID: String = "opencode"

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
        case unknownEventKind(raw: String)
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
        guard let wireKind = WireEventKind(rawValue: wire.kind) else {
            throw ParseError.unknownEventKind(raw: wire.kind)
        }
        let canonical: ProviderRuntimeEvent.EventType
        var projectionStatus: ProviderRuntimeEvent.ProjectionStatus = .ineligible
        switch wireKind {
        case .messageStart:    canonical = .messageStarted
        case .messageChunk:    canonical = .messageDelta
        case .toolStart:       canonical = .toolCallStarted
        case .toolEnd:
            canonical = .toolCallFinished
            projectionStatus = .pending
        case .permissionPrompt: canonical = .approvalRequested
        case .permissionGrant:  canonical = .approvalGranted
        case .userPrompt:       canonical = .userInputRequested
        case .turnFinish:
            canonical = .turnCompleted
            projectionStatus = .pending
        case .turnAbort:        canonical = .turnAborted
        case .diagnostic:       canonical = .warning
        }

        let tokens: ProviderRuntimeEvent.TokenSnapshot?
        if let u = wire.usage {
            tokens = ProviderRuntimeEvent.TokenSnapshot(
                promptTokens: u.input,
                completionTokens: u.output,
                cachedTokens: u.cached
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
            toolCallID: wire.toolId,
            toolName: wire.toolName,
            toolResult: wire.outcome,
            approvalID: wire.permissionId,
            warnings: warnings,
            projectionStatus: projectionStatus,
            rawPayloadHash: rawHash
        )
    }

    // MARK: - Wire envelope

    /// OpenCode's event-format vocabulary. Adding a new kind
    /// requires a new case AND a new switch arm in
    /// `convert(_:rawHash:)` — single choke point.
    private enum WireEventKind: String {
        case messageStart     = "message-start"
        case messageChunk     = "message-chunk"
        case toolStart        = "tool-start"
        case toolEnd          = "tool-end"
        case permissionPrompt = "permission-prompt"
        case permissionGrant  = "permission-grant"
        case userPrompt       = "user-prompt"
        case turnFinish       = "turn-finish"
        case turnAbort        = "turn-abort"
        case diagnostic       = "diagnostic"
    }

    private struct WireEvent: Decodable {
        let kind: String
        let sessionId: String?
        let threadId: String?
        let turnId: String?
        let pane: String?
        let toolId: String?
        let toolName: String?
        let outcome: String?
        let permissionId: String?
        let message: String?
        let reason: String?
        let ts: Double?
        let usage: WireUsage?
    }

    private struct WireUsage: Decodable {
        let input: Int?
        let output: Int?
        let cached: Int?
    }
}
