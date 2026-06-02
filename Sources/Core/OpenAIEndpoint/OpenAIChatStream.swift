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
            /// V.13d-1 — `tool_calls` delta fragments. Non-nil on a tool-use
            /// stream's call chunks; nil on the role chunk, content chunks,
            /// and the terminal chunk.
            public let toolCalls: [ToolCallFragment]?
            public init(
                role: String? = nil,
                content: String? = nil,
                toolCalls: [ToolCallFragment]? = nil
            ) {
                self.role = role
                self.content = content
                self.toolCalls = toolCalls
            }

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }

            // Emit only the keys that are set — the final chunk's delta is
            // an empty object `{}`, the role chunk carries `role`, a content
            // chunk carries `content`, and a tool-call chunk carries
            // `tool_calls`.
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(role, forKey: .role)
                try c.encodeIfPresent(content, forKey: .content)
                try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
            }
        }

        /// V.13d-1 — one streamed `tool_calls` fragment in the OpenAI shape.
        /// `index` is ALWAYS present (the client keys fragments by array
        /// index to reassemble the call); `id` / `type` / `function.name`
        /// appear only on the FIRST fragment for an index, and
        /// `function.arguments` carries one string slice per fragment.
        /// Sparse-encoded so a continuation fragment is just
        /// `{"index":0,"function":{"arguments":"…"}}`.
        public struct ToolCallFragment: Encodable, Sendable, Equatable {
            public struct FunctionFragment: Encodable, Sendable, Equatable {
                public let name: String?
                public let arguments: String?
                public init(name: String? = nil, arguments: String? = nil) {
                    self.name = name
                    self.arguments = arguments
                }

                enum CodingKeys: String, CodingKey { case name, arguments }

                public func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encodeIfPresent(name, forKey: .name)
                    try c.encodeIfPresent(arguments, forKey: .arguments)
                }
            }

            public let index: Int
            public let id: String?
            public let type: String?
            public let function: FunctionFragment?
            public init(
                index: Int,
                id: String? = nil,
                type: String? = nil,
                function: FunctionFragment? = nil
            ) {
                self.index = index
                self.id = id
                self.type = type
                self.function = function
            }

            enum CodingKeys: String, CodingKey { case index, id, type, function }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(index, forKey: .index)   // ALWAYS present
                try c.encodeIfPresent(id, forKey: .id)
                try c.encodeIfPresent(type, forKey: .type)
                try c.encodeIfPresent(function, forKey: .function)
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

    /// V.13d-1 — Build the ordered SSE event bytes for a TOOL-CALL
    /// completion: a leading role chunk (`delta: {role: "assistant"}`),
    /// then for each tool call a "header" fragment carrying
    /// `{index, id, type, function: {name, arguments: ""}}` followed by one
    /// `function.arguments` string fragment per `splitForStreaming` piece,
    /// and a terminal chunk (`delta: {}`, `finish_reason: "tool_calls"`).
    /// The `[DONE]` sentinel is sent separately by `run`.
    ///
    /// Reuses the same `Chunk` machinery + `splitForStreaming` splitter as
    /// the content path — no parallel streaming stack. The arguments-
    /// fragment invariant mirrors the content invariant:
    /// `header("") + fragments.joined() == call.function.arguments`.
    /// Multiple tool calls are emitted sequentially by array index (a
    /// single tool call per turn is the v13d-1 scope; sequential fan-out is
    /// the natural extension, NOT a parallel-streaming fork).
    public static func toolCallEvents(
        id: String, created: Int, model: String, toolCalls: [OpenAIToolCall]
    ) -> [Data] {
        var chunks: [Chunk] = []
        chunks.append(Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)]
        ))
        for (i, call) in toolCalls.enumerated() {
            // Header fragment: id + type + name + empty arguments string.
            chunks.append(Chunk(
                id: id, created: created, model: model,
                choices: [.init(
                    index: 0,
                    delta: .init(toolCalls: [
                        .init(
                            index: i, id: call.id, type: call.type,
                            function: .init(name: call.function.name, arguments: "")
                        )
                    ]),
                    finishReason: nil
                )]
            ))
            // Arguments string fragments — concatenate back to the full
            // arguments JSON string. Empty arguments yields zero fragments
            // (the header's `arguments: ""` already represents the empty
            // string).
            for piece in splitForStreaming(call.function.arguments) {
                chunks.append(Chunk(
                    id: id, created: created, model: model,
                    choices: [.init(
                        index: 0,
                        delta: .init(toolCalls: [
                            .init(index: i, function: .init(arguments: piece))
                        ]),
                        finishReason: nil
                    )]
                ))
            }
        }
        chunks.append(Chunk(
            id: id, created: created, model: model,
            choices: [.init(index: 0, delta: .init(), finishReason: "tool_calls")]
        ))
        return chunks.map { sseEvent(encodeChunk($0)) }
    }

    // MARK: - Drive

    /// Terminal state of a streamed response. The `auditStatus` computed
    /// property gives the stable audit-row `status` string: a completed
    /// stream reuses the non-streaming `ok`, a client-cancelled one is
    /// `client_cancel`, and an upstream-error termination is
    /// `upstream_error:<code>` carrying ONLY the short Anthropic
    /// `error.type` identifier (Schneier sse-d r10 P0 info-leak guard —
    /// no upstream message bytes ever land here).
    ///
    /// V.13b-sse-d FOLD: was a `String`-raw enum; converted to a regular
    /// enum so the `.upstreamError(code:)` case can carry the short type
    /// identifier. Equatable is preserved so existing `==` comparisons in
    /// tests against `.completed` / `.clientCancel` continue to work.
    public enum FinishStatus: Sendable, Equatable {
        case completed
        case clientCancel
        case upstreamError(code: String)

        /// V.13b-sse-d Schneier re-audit P3 FOLD: SINGLE-SOURCE-OF-TRUTH
        /// sanitizer applied to upstream-controlled error codes BEFORE they
        /// reach the wire OR the audit-row `status` column. The wire path
        /// (`ClaudeAPIServeDispatch.streamErrorLine`) also calls this, so a
        /// hostile / MITM upstream cannot inject control chars, quotes, or
        /// newlines into EITHER surface — defense-in-depth against
        /// log-injection in audit-DB readers + JSON-injection on the wire.
        /// Whitelist: ASCII letter / number / underscore only. Anthropic's
        /// documented error vocabulary uses underscores (`overloaded_error`,
        /// `rate_limit_error`, `authentication_error`, `invalid_request_error`)
        /// so the strict filter passes all known shapes; an empty result
        /// falls back to `"unknown"` matching the parser's existing
        /// `extractErrorTypeOrUnknown` sentinel.
        public static func sanitizeCode(_ code: String) -> String {
            let safe = code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            return safe.isEmpty ? "unknown" : safe
        }

        /// Audit-row `status` string. Stable across versions.
        ///   - `.completed` → `"ok"`
        ///   - `.clientCancel` → `"client_cancel"`
        ///   - `.upstreamError(code: X)` → `"upstream_error:<sanitized(X)>"`
        ///     — the short Anthropic `error.type` identifier with the
        ///     same `sanitizeCode` whitelist the wire applies; NEVER
        ///     `error.message` (Schneier r10 P0 info-leak guard) and
        ///     NEVER raw upstream bytes (Schneier sse-D re-audit P3
        ///     defense-in-depth — protects audit-DB readers from log-
        ///     injection on a hostile / MITM upstream).
        public var auditStatus: String {
            switch self {
            case .completed: return "ok"
            case .clientCancel: return "client_cancel"
            case .upstreamError(let code):
                return "upstream_error:\(Self.sanitizeCode(code))"
            }
        }
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

    /// Everything the listener needs to stream one response. `head` and
    /// `done` are pre-encoded byte blobs; `onFinish` fires once with the
    /// terminal status so the caller can append the single audit entry.
    ///
    /// The Plan carries the event sequence in one of two shapes — the v13b
    /// PRE-BAKED `events: [Data]` (one-shot completion split into SSE
    /// chunks) or the V.13 sub-item 2 STREAMING `streamingEvents` async
    /// source (real token-by-token deltas, driven through the sink as MLX
    /// produces them). The two are mutually exclusive in practice: the
    /// streaming init leaves `events` empty and the pre-baked init leaves
    /// `streamingEvents` nil.
    public struct Plan: Sendable {
        public let head: Data
        public let events: [Data]
        /// V.13 real-chat (sub-item 2) — when non-nil, `run(plan:, sink:)`
        /// drives each event from this async source instead of iterating
        /// the pre-baked `events`. The closure is invoked ONCE per `run`;
        /// returning a fresh `AsyncThrowingStream` per call keeps the
        /// listener's retry/reconnect semantics composable with future
        /// hot-path resumption logic.
        public let streamingEvents: (@Sendable () -> AsyncThrowingStream<Data, Error>)?
        public let done: Data
        public let onFinish: @Sendable (_ status: FinishStatus) -> Void
        /// V.13b-sse-d — when set, classifies a producer-thrown error into
        /// a stable short identifier (e.g. `"overloaded_error"`,
        /// `"tool_arguments_malformed"`). nil means "not an upstream
        /// error" and the drive collapses to `.clientCancel` as before.
        /// The local-MLX streaming path leaves this nil (the MLX adapter
        /// has no upstream channel).
        public let errorTypeExtractor: (@Sendable (Error) -> String?)?
        /// V.13b-sse-d — when set, builds the wire-level error terminator
        /// `Data` for a given short code; written best-effort to the sink
        /// before close on the `.upstreamError(code:)` path. NO `[DONE]`
        /// is written after (Schneier r10 P0 — the OpenAI error line is
        /// terminal; `[DONE]` after error confuses SDK clients).
        public let errorTerminatorBuilder: (@Sendable (String) -> Data)?
        public init(
            head: Data,
            events: [Data],
            done: Data,
            onFinish: @escaping @Sendable (_ status: FinishStatus) -> Void
        ) {
            self.head = head
            self.events = events
            self.streamingEvents = nil
            self.done = done
            self.onFinish = onFinish
            self.errorTypeExtractor = nil
            self.errorTerminatorBuilder = nil
        }
        /// V.13 real-chat (sub-item 2) — streaming variant. `streamingEvents`
        /// returns a fresh `AsyncThrowingStream<Data, Error>` per `run`
        /// call. The drive loop iterates it synchronously via a bounded
        /// channel pump (`driveStreaming` below) so the listener's existing
        /// sync `Sink` contract is preserved.
        ///
        /// V.13b-sse-d — adds optional `errorTypeExtractor` +
        /// `errorTerminatorBuilder` so the Anthropic serve-path can
        /// surface a typed upstream error as `.upstreamError(code:)`
        /// + write an OpenAI-shaped error line on the wire. Both nil
        /// preserves the pre-sse-d behavior (any producer throw collapses
        /// to `.clientCancel`).
        public init(
            head: Data,
            streamingEvents: @escaping @Sendable () -> AsyncThrowingStream<Data, Error>,
            done: Data,
            onFinish: @escaping @Sendable (_ status: FinishStatus) -> Void,
            errorTypeExtractor: (@Sendable (Error) -> String?)? = nil,
            errorTerminatorBuilder: (@Sendable (String) -> Data)? = nil
        ) {
            self.head = head
            self.events = []
            self.streamingEvents = streamingEvents
            self.done = done
            self.onFinish = onFinish
            self.errorTypeExtractor = errorTypeExtractor
            self.errorTerminatorBuilder = errorTerminatorBuilder
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
    ///
    /// Dispatches on the plan's shape: a `streamingEvents` source goes
    /// through `driveStreaming` (V.13 sub-item 2 real token-by-token path);
    /// otherwise the pre-baked `events: [Data]` rides the v13b drive.
    @discardableResult
    public static func run(plan: Plan, sink: Sink) -> FinishStatus {
        if let source = plan.streamingEvents {
            let status = driveStreaming(
                head: plan.head,
                source: source,
                done: plan.done,
                sink: sink,
                errorTypeExtractor: plan.errorTypeExtractor,
                errorTerminatorBuilder: plan.errorTerminatorBuilder
            )
            plan.onFinish(status)
            sink.close()
            return status
        }
        return run(head: plan.head, events: plan.events, done: plan.done, sink: sink, onFinish: plan.onFinish)
    }

    /// V.13 real-chat (sub-item 2) — drive an async event source through a
    /// synchronous `Sink`. Bridges the listener's sync write contract to
    /// the registered `StreamingChatEngine`'s `AsyncThrowingStream<Data,
    /// Error>` via a bounded channel pump: a producer Task pulls deltas
    /// from the source and pushes them to a lock-protected queue, while
    /// this loop drains the queue and writes each event. Cancellation
    /// propagates either way — a peer disconnect surfaces as a sink-write
    /// throw which cancels the producer; a producer throw surfaces here as
    /// a `clientCancel` status so the run loop tears the connection down
    /// exactly once.
    ///
    /// The channel is unbounded because MLX produces tokens slower than the
    /// loopback network drains them; backpressure beyond this V1 pump is a
    /// later round if a future engine inverts that asymmetry.
    ///
    /// Cooperative-pool sweep (2026-06-01, sibling fix of phase-t1d-6 P0):
    /// the producer `Task` is hosted on `ServeBridge.executor` (the dedicated
    /// `TaskExecutor` whose threads are OUTSIDE Swift Concurrency's
    /// cooperative pool) on macOS 15+; the macOS-14 `else` branch falls to
    /// the legacy default `Task` (v14 production callers block a GCD/NWListener
    /// thread, never a cooperative thread, so cannot self-starve there).
    /// This is the SAME shape as `ServeBridge.runBlocking`'s fix — the
    /// channel's consumer below blocks the calling sink thread on an
    /// unbounded `sem.wait()`, and under `swift test`'s parallel runner that
    /// calling thread is a cooperative-pool thread; hosting the producer
    /// off-pool lets it START to push items + `.end` regardless of pool
    /// saturation.
    ///
    /// Scope of the guarantee (mirrors the documented scope on
    /// `ServeBridge.runBlocking`): the `executorPreference` keeps the
    /// producer's nonisolated entry/exit hops on the dedicated executor.
    /// The UNDERLYING `AsyncThrowingStream`'s source-side Task — created
    /// by whoever constructed the stream (MLX adapter, test stub) — runs
    /// wherever its constructor placed it. `continuation.yield(_:)` itself
    /// is synchronous and non-blocking, so the source Task only needs a
    /// thread to do its OWN work between yields; in production the source
    /// is the MLX actor (its own executor, not the cooperative pool), and
    /// in tests stubs may inline-yield without ever suspending. Neither
    /// path needs a free cooperative thread to RUN, so this consumer-side
    /// fix alone closes the deadlock class.
    private static func driveStreaming(
        head: Data,
        source: @Sendable () -> AsyncThrowingStream<Data, Error>,
        done: Data,
        sink: Sink,
        errorTypeExtractor: (@Sendable (Error) -> String?)? = nil,
        errorTerminatorBuilder: (@Sendable (String) -> Data)? = nil
    ) -> FinishStatus {
        if sink.isCancelled() { return .clientCancel }
        do { try sink.write(head) } catch { return .clientCancel }

        final class Channel: @unchecked Sendable {
            enum Item { case data(Data); case error(Error); case end }
            var queue: [Item] = []
            let lock = NSLock()
            let sem = DispatchSemaphore(value: 0)
            func push(_ item: Item) {
                lock.lock(); queue.append(item); lock.unlock()
                sem.signal()
            }
            func pop() -> Item {
                sem.wait()
                lock.lock(); let item = queue.removeFirst(); lock.unlock()
                return item
            }
        }
        let channel = Channel()
        let stream = source()
        let producerBody: @Sendable () async -> Void = {
            do {
                for try await data in stream {
                    if Task.isCancelled { break }
                    channel.push(.data(data))
                }
                channel.push(.end)
            } catch {
                channel.push(.error(error))
            }
        }
        let producer: Task<Void, Never>
        if #available(macOS 15.0, *) {
            producer = Task(executorPreference: ServeBridge.executor, operation: producerBody)
        } else {
            producer = Task(operation: producerBody)
        }

        loop: while true {
            if sink.isCancelled() {
                producer.cancel()
                return .clientCancel
            }
            switch channel.pop() {
            case .data(let chunk):
                do { try sink.write(chunk) } catch {
                    producer.cancel()
                    return .clientCancel
                }
            case .error(let err):
                producer.cancel()
                // V.13b-sse-d — typed upstream-error path. When the Plan
                // provides an `errorTypeExtractor` and the thrown error
                // resolves to a non-nil short code, write the wire-level
                // error terminator (best-effort — if the peer is gone the
                // write throws and we still return .upstreamError so the
                // audit row reflects the upstream cause, not a peer-close
                // false-positive `.clientCancel`) and return
                // `.upstreamError(code:)`. No `[DONE]` follows — Schneier
                // r10 P0 (OpenAI's real behavior; `[DONE]` after error
                // confuses SDK clients).
                if let extractor = errorTypeExtractor, let code = extractor(err) {
                    if let builder = errorTerminatorBuilder {
                        try? sink.write(builder(code))
                    }
                    return .upstreamError(code: code)
                }
                return .clientCancel
            case .end:
                break loop
            }
        }

        if sink.isCancelled() { return .clientCancel }
        do { try sink.write(done) } catch { return .clientCancel }
        return .completed
    }
}
