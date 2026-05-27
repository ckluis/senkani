import Foundation

/// V.13b — SSE streaming for `POST /v1/chat/completions` (`stream: true`).
///
/// Two concerns live here, both `Network`-free so every acceptance bullet
/// is unit-testable without binding a socket:
///
///   1. **Framing** — the OpenAI `chat.completion.chunk` delta shape, the
///      `text/event-stream` HTTP head, the `data: …\n\n` event wrapper, and
///      the terminal `data: [DONE]\n\n` sentinel.
///   2. **Drive** — `run(…)`, a synchronous loop that writes `head →
///      events → [DONE]` through an injectable `Sink`, checking
///      cancellation before every write and tearing the connection down
///      exactly once. The live `OpenAIListener` wires the `Sink` to an
///      `NWConnection`; tests wire an in-memory sink.
///
/// Contract notes (carried from the v13b acceptance):
///   - **Cancellation.** A client disconnect surfaces as a write error on
///     the next chunk send (the peer closed its read side). `run` reacts
///     before the following chunk — with no inter-chunk pacing the window
///     is one send, well under the 100 ms bound. The structure also
///     supports a pre-write `isCancelled` flag for a lazy engine.
///   - **Rate-limit interaction.** Rate limiting is enforced by the auth
///     gate BEFORE the stream opens (the listener applies auth ahead of
///     the surface). A `429` is therefore a complete framed JSON response
///     emitted before any SSE byte — there is no mid-stream `429` and no
///     half-open connection. Once a stream opens it runs to completion or
///     client-cancel.
///   - **Audit.** `Plan.onFinish` fires exactly once with the terminal
///     `FinishStatus`; the caller appends exactly one audit entry whose
///     `status` distinguishes completion (`ok`) from client-cancel
///     (`client_cancel`).
public enum OpenAIChatStream {

    // MARK: - Chunk model (chat.completion.chunk)

    /// One streamed chunk. Hand-encoded so `finish_reason` is always
    /// present (explicit `null` on non-terminal chunks, per OpenAI) and the
    /// `delta` carries only the keys that are set (`{}` on the final
    /// chunk). `sortedKeys` gives byte-stable output.
    public struct Chunk: Encodable, Sendable, Equatable {
        public struct Delta: Encodable, Sendable, Equatable {
            public let role: String?
            public let content: String?
            public init(role: String? = nil, content: String? = nil) {
                self.role = role
                self.content = content
            }

            enum CodingKeys: String, CodingKey { case role, content }

            // Emit only the keys that are set — the final chunk's delta is
            // an empty object `{}`, the role chunk carries `role`, and a
            // content chunk carries `content`.
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(role, forKey: .role)
                try c.encodeIfPresent(content, forKey: .content)
            }
        }

        public struct Choice: Encodable, Sendable, Equatable {
            public let index: Int
            public let delta: Delta
            public let finishReason: String?
            public init(index: Int, delta: Delta, finishReason: String?) {
                self.index = index
                self.delta = delta
                self.finishReason = finishReason
            }

            enum CodingKeys: String, CodingKey {
                case index, delta
                case finishReason = "finish_reason"
            }

            // `finish_reason` is ALWAYS present per OpenAI: explicit `null`
            // on non-terminal chunks, `"stop"` on the final chunk.
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(index, forKey: .index)
                try c.encode(delta, forKey: .delta)
                if let finishReason {
                    try c.encode(finishReason, forKey: .finishReason)
                } else {
                    try c.encodeNil(forKey: .finishReason)
                }
            }
        }

        public let id: String
        public let object: String   // always "chat.completion.chunk"
        public let created: Int
        public let model: String
        public let choices: [Choice]

        public init(id: String, created: Int, model: String, choices: [Choice]) {
            self.id = id
            self.object = "chat.completion.chunk"
            self.created = created
            self.model = model
            self.choices = choices
        }

        enum CodingKeys: String, CodingKey {
            case id, object, created, model, choices
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(object, forKey: .object)
            try c.encode(created, forKey: .created)
            try c.encode(model, forKey: .model)
            try c.encode(choices, forKey: .choices)
        }
    }

    // MARK: - Encoding helpers (pure)

    /// SSE response head for a streamed completion: `text/event-stream`,
    /// no `Content-Length` (the body is chunked), `Connection: close`
    /// (we close after `[DONE]`).
    public static func head() -> Data {
        var s = "HTTP/1.1 200 OK\r\n"
        s += "Content-Type: text/event-stream\r\n"
        s += "Cache-Control: no-cache\r\n"
        s += "Connection: close\r\n"
        s += "\r\n"
        return Data(s.utf8)
    }

    /// Encode one chunk to a JSON string with stable key order.
    public static func encodeChunk(_ chunk: Chunk) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(chunk)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Wrap a chunk JSON string as one SSE event: `data: <json>\n\n`.
    public static func sseEvent(_ json: String) -> Data {
        Data("data: \(json)\n\n".utf8)
    }

    /// The terminal SSE sentinel: `data: [DONE]\n\n`.
    public static func doneSentinel() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    /// Split a completion content string into streamed pieces such that
    /// `pieces.joined() == content` exactly (the "accumulates to the full
    /// message" invariant). Each whitespace-delimited word keeps its
    /// trailing space; the final run flushes whatever remains. Empty
    /// content yields zero content pieces (the stream still carries the
    /// role chunk + final chunk).
    public static func splitForStreaming(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var pieces: [String] = []
        var current = ""
        for ch in content {
            current.append(ch)
            if ch == " " {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Build the ordered SSE event bytes for a completion: a leading role
    /// chunk (`delta: {role: "assistant"}`), one content chunk per piece
    /// (`delta: {content: …}`), and a terminal chunk (`delta: {}`,
    /// `finish_reason: "stop"`). The `[DONE]` sentinel is sent separately
    /// by `run`.
    public static func events(id: String, created: Int, model: String, content: String) -> [Data] {
        var chunks: [Chunk] = []
        chunks.append(Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)]
        ))
        for piece in splitForStreaming(content) {
            chunks.append(Chunk(
                id: id, created: created, model: model,
                choices: [.init(index: 0, delta: .init(content: piece), finishReason: nil)]
            ))
        }
        chunks.append(Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(), finishReason: "stop")]
        ))
        return chunks.map { sseEvent(encodeChunk($0)) }
    }

    // MARK: - Drive

    /// Terminal state of a streamed response. The raw values are the audit
    /// `status` strings: a completed stream reuses the non-streaming `ok`,
    /// a client-cancelled one is `client_cancel`.
    public enum FinishStatus: String, Sendable, Equatable {
        case completed = "ok"
        case clientCancel = "client_cancel"
    }

    /// Byte sink for the streamer. `write` throws when the peer is gone
    /// (a closed read side surfaces as a send error on the next chunk);
    /// `isCancelled` is a cheap pre-write guard; `close` tears the
    /// connection down and is invoked exactly once by `run`.
    public struct Sink: Sendable {
        public let write: @Sendable (Data) throws -> Void
        public let isCancelled: @Sendable () -> Bool
        public let close: @Sendable () -> Void
        public init(
            write: @escaping @Sendable (Data) throws -> Void,
            isCancelled: @escaping @Sendable () -> Bool = { false },
            close: @escaping @Sendable () -> Void
        ) {
            self.write = write
            self.isCancelled = isCancelled
            self.close = close
        }
    }

    /// Everything the listener needs to stream one response. `head`,
    /// `events`, and `done` are pre-encoded byte blobs; `onFinish` fires
    /// once with the terminal status so the caller can append the single
    /// audit entry.
    public struct Plan: Sendable {
        public let head: Data
        public let events: [Data]
        public let done: Data
        public let onFinish: @Sendable (_ status: FinishStatus) -> Void
        public init(
            head: Data,
            events: [Data],
            done: Data,
            onFinish: @escaping @Sendable (_ status: FinishStatus) -> Void
        ) {
            self.head = head
            self.events = events
            self.done = done
            self.onFinish = onFinish
        }
    }

    /// Drive a stream through `sink`: head → each event → `[DONE]`,
    /// checking cancellation before every write. Returns `.completed` only
    /// if every byte was written; any cancellation or write error returns
    /// `.clientCancel`.
    ///
    /// `onFinish` (when supplied) fires with the terminal status BEFORE the
    /// connection is torn down — so the single audit entry is durably
    /// recorded ahead of the client's EOF. `sink.close()` is then called
    /// EXACTLY once on every path (the no-fd-leak guarantee).
    @discardableResult
    public static func run(
        head: Data,
        events: [Data],
        done: Data,
        sink: Sink,
        onFinish: (@Sendable (FinishStatus) -> Void)? = nil
    ) -> FinishStatus {
        let status = drive(head: head, events: events, done: done, sink: sink)
        onFinish?(status)
        sink.close()
        return status
    }

    /// The write loop. Never closes and never throws — a cancellation or
    /// write error is folded into a `.clientCancel` return so `run` owns
    /// the single close + finish callback.
    private static func drive(head: Data, events: [Data], done: Data, sink: Sink) -> FinishStatus {
        if sink.isCancelled() { return .clientCancel }
        do { try sink.write(head) } catch { return .clientCancel }

        for event in events {
            if sink.isCancelled() { return .clientCancel }
            do { try sink.write(event) } catch { return .clientCancel }
        }

        if sink.isCancelled() { return .clientCancel }
        do { try sink.write(done) } catch { return .clientCancel }

        return .completed
    }

    /// Convenience: drive a `Plan`, firing its `onFinish` with the terminal
    /// status before close. Used by the live listener.
    @discardableResult
    public static func run(plan: Plan, sink: Sink) -> FinishStatus {
        run(head: plan.head, events: plan.events, done: plan.done, sink: sink, onFinish: plan.onFinish)
    }
}
