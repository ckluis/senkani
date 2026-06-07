import Foundation

/// V.13b-sse-a — Defensive parser for Anthropic `/v1/messages` Server-Sent
/// Events streams (`Accept: text/event-stream`).
///
/// Carve scope (Child A of the v13b-sse decomposition): this file provides
/// ONLY the byte-stream → typed-event seam. The engine driver
/// (`ClaudeAPIChatEngine.chatStream(...)`) lives in `ClaudeAPIChatEngine.swift`.
/// Translator (chunk-deltas → OpenAI SSE), listener wire, and the 501-lift
/// are children B / C / D.
///
/// Hardening (FIX-NOW from the v13b-followup-anthropic-sse-streaming r10
/// plan-audit panel — Karpathy / Schneier / Lauret):
///
/// * **Hard frame cap** — `maxFrameBytes` = 256 KiB. If the in-progress
///   frame buffer grows past the cap BEFORE a terminating blank line, the
///   stream throws `FrameError.frameTooLarge` and surfaces NO upstream
///   bytes in the error path. A hostile or malformed upstream cannot park
///   memory on a single oversized frame.
/// * **`event: ping` skip** — the SSE keepalive frame's data body is
///   dropped UNPARSED. We never JSON-decode a ping body, defending against
///   a malformed-body upstream poisoning the event stream. Note however
///   that line-level UTF-8 decoding runs BEFORE event-name classification
///   (`String(bytes:encoding:.utf8)` on every non-empty line — see the
///   field-classification switch below). A non-UTF-8 byte in a `data:`
///   line of a `ping` frame will therefore throw `FrameError.invalidUTF8`
///   rather than being silently skipped. This is the safer default (we
///   surface byte-level corruption regardless of which event the frame
///   carries); moving UTF-8 decoding inside the field-classification
///   switch would be a real behavior change requiring its own audit and
///   is NOT done here (Schneier r11 re-audit P3 — sse-A ping UTF-8 doc).
/// * **`event: error` redaction** — only the short `error.type` identifier
///   is surfaced (`overloaded_error`, `rate_limit_error`, …). The
///   `error.message` field — which can echo prompt content, key fragments,
///   or upstream guidance — is DROPPED at the parser boundary. Mirrors the
///   non-stream `chat()` info-leak guard.
/// * **`event:` is optional** — the SSE spec makes `event:` optional and
///   Anthropic's wire payload already carries an authoritative `type`
///   field in the JSON body. The parser uses `event:` when present, else
///   the JSON `type`. Either way the wire-level event-type seam is the
///   JSON payload — protecting against an upstream that drops `event:`.
/// * **Multi-line `data:`** — per the SSE spec, multiple `data:` lines in
///   one frame are joined with `\n`. Anthropic doesn't currently emit
///   multi-line bodies, but the parser tolerates them.
/// * **Comment / heartbeat lines** — lines starting with `:` are SSE
///   comments and are skipped (commonly used as keepalives).
/// * **CRLF and LF tolerance** — `\r\n\r\n` and `\n\n` both terminate a
///   frame; trailing `\r` on a line is stripped.
public enum AnthropicSSEFrameParser {

    /// Hard cap on accumulated frame buffer bytes between blank lines.
    /// 256 KiB is well above any realistic Anthropic chunk (single-token
    /// deltas, tool-use partial-json fragments) yet small enough to bound
    /// hostile-upstream memory growth. See Schneier panel rule.
    public static let maxFrameBytes: Int = 256 * 1024

    /// Errors surfaced into the `AsyncThrowingStream<AnthropicStreamEvent, Error>`.
    /// Each variant carries ONLY a short fixed identifier — NEVER any raw
    /// upstream bytes — so `String(describing:)` cannot echo prompt content
    /// or key fragments.
    public enum FrameError: Error, Equatable, Sendable {
        /// Accumulated frame exceeded `maxFrameBytes` before a blank line.
        case frameTooLarge
        /// A `data:` line could not be decoded as UTF-8. Should not occur
        /// on a well-formed Anthropic stream; kept as a defensive seam.
        case invalidUTF8
    }

    /// Parse a stream of upstream bytes (typically `URLSession.bytes(for:).0`)
    /// into typed Anthropic stream events.
    ///
    /// Cancellation: the returned stream propagates consumer-task
    /// cancellation by detecting `Task.isCancelled` in the producer loop
    /// AND by virtue of the source `AsyncSequence` (`URLSession.AsyncBytes`)
    /// itself observing cancellation — see the engine driver for the
    /// explicit `URLSessionDataTask.cancel()` seam.
    public static func parseFrames<S: AsyncSequence & Sendable>(
        _ bytes: S
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
        where S.Element == UInt8
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lineBuf: [UInt8] = []           // current physical line
                    var frameBytes: Int = 0             // accumulated frame size
                    var eventName: String? = nil        // last `event:` seen this frame
                    var dataLines: [String] = []        // accumulated `data:` payload lines
                    var iterator = bytes.makeAsyncIterator()

                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }

                        // Append byte to current line buffer until LF; CR
                        // is stripped at line-finalize time so both LF and
                        // CRLF terminations work.
                        if byte != 0x0A { // not '\n'
                            lineBuf.append(byte)
                            frameBytes += 1
                            if frameBytes > maxFrameBytes {
                                throw FrameError.frameTooLarge
                            }
                            continue
                        }

                        // We hit LF: finalize the line.
                        if lineBuf.last == 0x0D { lineBuf.removeLast() } // strip trailing CR

                        if lineBuf.isEmpty {
                            // Blank line → end of frame. Dispatch if we
                            // have accumulated content. Otherwise (back-to-
                            // back blank lines) this is a no-op.
                            if !dataLines.isEmpty || eventName != nil {
                                try emitFrame(
                                    eventName: eventName,
                                    dataLines: dataLines,
                                    continuation: continuation
                                )
                            }
                            // Reset frame state.
                            eventName = nil
                            dataLines.removeAll(keepingCapacity: true)
                            frameBytes = 0
                            lineBuf.removeAll(keepingCapacity: true)
                            continue
                        }

                        // Non-empty line. Classify.
                        guard let line = String(bytes: lineBuf, encoding: .utf8) else {
                            throw FrameError.invalidUTF8
                        }
                        lineBuf.removeAll(keepingCapacity: true)

                        if line.hasPrefix(":") {
                            // SSE comment / heartbeat — skip silently.
                            continue
                        }
                        if line.hasPrefix("event:") {
                            eventName = trimFieldValue(line.dropFirst("event:".count))
                            continue
                        }
                        if line.hasPrefix("data:") {
                            dataLines.append(trimFieldValue(line.dropFirst("data:".count)))
                            continue
                        }
                        // Unknown field (e.g. `id:`, `retry:`) — ignore.
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Frame dispatch

    /// Decode the accumulated frame body. Selects the event type by
    /// preferring the `event:` line when present, else falling back to the
    /// JSON payload's `type` field (the wire authority).
    private static func emitFrame(
        eventName: String?,
        dataLines: [String],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) throws {
        // Per SSE spec, multiple data: lines join with `\n`.
        let body = dataLines.joined(separator: "\n")

        // `event: ping` — drop the body UNPARSED. Defensive against
        // a malformed-body upstream poisoning the event stream.
        if eventName == "ping" { return }

        // `event: error` — extract ONLY error.type; drop error.message.
        if eventName == "error" {
            let type = extractErrorTypeOrUnknown(body: body)
            continuation.yield(.error(type: type))
            return
        }

        // Otherwise, JSON-decode and let the payload's `type` field route.
        guard let data = body.data(using: .utf8), !data.isEmpty else {
            // Empty data body (no payload) — treat as no-op.
            return
        }
        if let event = decodeEvent(from: data, eventName: eventName) {
            continuation.yield(event)
        }
    }

    /// Decode the JSON payload and dispatch by `type`. Unknown types are
    /// dropped (forward-compat). Returns nil for events we silently ignore
    /// (e.g. ping payloads that arrived without an `event:` line).
    ///
    /// Schneier P2 FOLD: every per-type `dec.decode` is guarded with `try?` so
    /// a malformed payload of a KNOWN type (e.g. `message_delta` with `delta`
    /// as a string instead of object, or NUL byte breaking a JSON string)
    /// drops silently instead of throwing into the AsyncThrowingStream and
    /// aborting the whole session. Matches the "forward-compat: unknown types
    /// drop silently" policy applied uniformly across known + unknown types.
    private static func decodeEvent(from data: Data, eventName: String?) -> AnthropicStreamEvent? {
        // First, sniff `type` — single source of truth.
        struct TypeSniff: Decodable { let type: String? }
        guard let sniff = try? JSONDecoder().decode(TypeSniff.self, from: data),
              let type = sniff.type else {
            // Unparseable — drop silently. (We never echo bytes.)
            return nil
        }

        // Defensive: if a body arrives without `event:` but `type == "ping"`
        // OR `type == "error"`, honor the same redaction rules.
        if type == "ping" { return nil }
        if type == "error" {
            // Re-extract via the same path that drops error.message.
            let body = String(data: data, encoding: .utf8) ?? ""
            return .error(type: extractErrorTypeOrUnknown(body: body))
        }

        let dec = JSONDecoder()
        switch type {
        case "message_start":
            struct Wire: Decodable {
                struct Msg: Decodable {
                    let id: String
                    struct Usage: Decodable { let input_tokens: Int? }
                    let usage: Usage?
                }
                let message: Msg
            }
            guard let w = try? dec.decode(Wire.self, from: data) else { return nil }
            return .messageStart(id: w.message.id, inputTokens: w.message.usage?.input_tokens)

        case "content_block_start":
            struct Wire: Decodable {
                let index: Int
                struct Block: Decodable {
                    let type: String
                    let id: String?
                    let name: String?
                }
                let content_block: Block
            }
            guard let w = try? dec.decode(Wire.self, from: data) else { return nil }
            switch w.content_block.type {
            case "text":
                return .contentBlockStart(index: w.index, block: .text)
            case "tool_use":
                guard let id = w.content_block.id, let name = w.content_block.name else {
                    return nil
                }
                return .contentBlockStart(index: w.index, block: .toolUse(id: id, name: name))
            default:
                // Forward-compat: unknown block type — drop silently.
                return nil
            }

        case "content_block_delta":
            struct Wire: Decodable {
                let index: Int
                struct Delta: Decodable {
                    let type: String
                    let text: String?
                    let partial_json: String?
                }
                let delta: Delta
            }
            guard let w = try? dec.decode(Wire.self, from: data) else { return nil }
            switch w.delta.type {
            case "text_delta":
                guard let t = w.delta.text else { return nil }
                return .contentBlockDelta(index: w.index, delta: .textDelta(t))
            case "input_json_delta":
                guard let pj = w.delta.partial_json else { return nil }
                return .contentBlockDelta(index: w.index, delta: .inputJsonDelta(pj))
            default:
                return nil
            }

        case "content_block_stop":
            struct Wire: Decodable { let index: Int }
            guard let w = try? dec.decode(Wire.self, from: data) else { return nil }
            return .contentBlockStop(index: w.index)

        case "message_delta":
            struct Wire: Decodable {
                struct Delta: Decodable { let stop_reason: String? }
                let delta: Delta?
                struct Usage: Decodable { let output_tokens: Int? }
                let usage: Usage?
            }
            guard let w = try? dec.decode(Wire.self, from: data) else { return nil }
            return .messageDelta(stopReason: w.delta?.stop_reason, outputTokens: w.usage?.output_tokens)

        case "message_stop":
            return .messageStop

        default:
            // Forward-compat: unknown top-level event type — drop silently.
            return nil
        }
    }

    /// Pull `error.type` out of an Anthropic error envelope while
    /// DISCARDING `error.message`. On any parse failure we return a fixed
    /// `"unknown"` sentinel — never an upstream byte.
    private static func extractErrorTypeOrUnknown(body: String) -> String {
        guard let data = body.data(using: .utf8) else { return "unknown" }
        struct Envelope: Decodable {
            struct Inner: Decodable { let type: String? }
            let error: Inner?
        }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let t = env.error?.type {
            return t
        }
        return "unknown"
    }

    /// Strip a SINGLE leading space after the `:` per SSE spec, then
    /// strip a trailing CR if any. Does NOT trim arbitrary whitespace —
    /// JSON payloads can legitimately start with `{`, never with leading
    /// ASCII space beyond the spec-mandated one.
    private static func trimFieldValue<S: StringProtocol>(_ s: S) -> String {
        var out = String(s)
        if out.first == " " { out.removeFirst() }
        if out.last == "\r" { out.removeLast() }
        return out
    }
}
